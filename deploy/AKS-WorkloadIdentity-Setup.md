# RDA on AKS — Kubernetes Job + Workload Identity Setup

This guide stands up Resource Discovery for Azure (RDA) as a set of worker pods
on AKS, run as a native **Kubernetes indexed Job**. The pods authenticate with
**workload identity** — a user-assigned managed identity (UAMI) federated to a
Kubernetes ServiceAccount — so **no client secret is stored, mounted, or handed
to anyone**. Each pod signs itself in, processes its shard of the tenant's
subscriptions, and produces a self-contained report.

> **Running RDA from an Azure DevOps pipeline instead?** If your agents are
> **KEDA-scaled self-hosted Azure DevOps agents on AKS** and RDA runs as a
> pipeline step under **`AzurePowerShell@5`** against an **ARM service
> connection**, that is a *different*
> execution model — RDA runs on the pipeline agent, not as this Kubernetes Job,
> and it authenticates via the service connection rather than a pod-federated
> UAMI. Use [`agent-pool/keda/README.md`](agent-pool/keda/README.md) for that
> route; this document is the pod-native / workload-identity path.

If you only need a single machine (laptop, VM, or Cloud Shell) rather than a
cluster, you do not need any of this — see the top-level `README.md`. This guide
is specifically the containerised / multi-node path.

For the theory of how the tenant is split across pods (deterministic hash
sharding, why nothing is done twice or skipped), see
[`../docs/horizontal-sharding.md`](../docs/horizontal-sharding.md). This guide is
the operational checklist.

---

## 1. What you are standing up

| Component | Purpose |
|-----------|---------|
| AKS cluster with OIDC issuer + workload identity | hosts the worker pods and issues the federated tokens |
| Azure Container Registry (ACR) | holds the `rda` worker image |
| User-assigned managed identity (`rda-uami`) | the Azure identity the pods authenticate as |
| Federated identity credential | trusts the Kubernetes ServiceAccount `system:serviceaccount:rda:rda-sa` |
| RBAC role assignments on the UAMI | authorize the inventory / consumption / metrics reads |
| ServiceAccount `rda-sa` (namespace `rda`) | the in-cluster identity the pods run as |
| Indexed Job `rda-shards` | runs one shard per pod |

There is exactly **one secret-less identity** in this design. The only
per-environment values are the resource names, the UAMI client id, the RBAC scope,
the shard count, and (optionally) an output blob container.

---

## 2. Access you need

**To do this setup**, the operator needs, in the target subscription/tenant:

- Rights to create AKS + ACR (Contributor or Owner on the resource group).
- Rights to create role assignments and federated credentials
  (Owner or User Access Administrator on the RBAC scope).

**The worker identity (`rda-uami`)** needs these roles. **Scope Reader at the
tenant-root management group — not per subscription.** The tool discovers
subscriptions with `Get-AzSubscription`, which returns only the subscriptions the
identity holds a role on; if you grant Reader per subscription and miss some, those
subscriptions are **silently absent** from the report (at scale, potentially
hundreds). A single Reader assignment at the **tenant-root management group**
(`GroupId` = your tenant id) inherits to every current and future subscription, so
nothing is silently missed, and it also grants the management-group read used to
*confirm* full coverage. This scope is effectively **required**: the wrapper
(`Run-AllSubscriptions.ps1`, which the pod runs) performs an up-front coverage gate
that compares the subscriptions the identity can enumerate against the true set
under the tenant-root management group and **hard-stops** if any are missing — or
if that true set cannot be read because the identity lacks management-group read.
Pass `-AllowPartialAccess` to consciously downgrade that to a warning and proceed
with only what the identity can see. The in-pod preflight (section 5) checks the
same gap before you fan out.

> **Quick first test (before tenant-root Reader is in place).** If you just want
> to prove the pipeline end-to-end today and the UAMI only has Reader on a subset
> of subscriptions, set `ALLOW_PARTIAL_ACCESS: "true"` in `deploy/k8s/job.yaml`
> (it is a commented knob in the manifest — it maps to the wrapper's
> `-AllowPartialAccess`). Each shard then warns about unverifiable coverage and
> proceeds with the subscriptions it *can* see, so you still get output to review
> and ingest. This is a **test-only** shortcut: for a real run, grant Reader at
> the tenant-root management group instead so coverage is guaranteed and the gate
> passes cleanly. Remember each shard emits **one** zip covering all subscriptions
> in *its* slice — so the number of zips equals the number of non-empty shards,
> not the number of subscriptions.

| Role | Needed for | Omit if |
|------|-----------|---------|
| **Reader** | inventory (Resource Graph / ARM reads) — always required | never |
| **Cost Management Reader** | consumption / cost data | `SKIP_CONSUMPTION=true` |
| **Monitoring Reader** | metrics (Azure Monitor) | `SKIP_METRICS=true` |
| **Storage Blob Data Contributor** | centralized upload of each pod's zip | not using blob upload |

A missing Reader assignment is not reported as an error by Azure Resource Graph
— an unreadable subscription just returns 0 rows, so on its own it would drop out
of the report unnoticed. To prevent that, the wrapper runs an up-front access
check and by **default hard-stops** the run (exit 1) if any in-scope subscription
is unreadable — whether the identity has no role on it or the probe stays
inconclusive after retries — listing the offending subscriptions so you can grant
Reader and re-run. (Pass `-AllowPartialAccess` to instead skip the unreadable
subscriptions and inventory only the rest.) The probe covers the subscriptions a
run will actually process — the shard's slice in a sharded run, and only the
not-yet-completed ones on `-Resume`. So grant Reader broadly before you fan out.
See the README "Subscription access check".

---

## 3. One-time Azure setup

Run the operator-side readiness check first — it is read-only and prints a
PASS/WARN/FAIL table (CLI present, region has an x64 node size, etc.):

```powershell
./deploy/Test-MultiNodeReadiness.ps1 -Location <region>
```

Then provision. Replace the placeholders; the GUID shown is the Azure
documentation placeholder, not a real value.

```bash
RG=rda-inventory-rg
LOC=<region>                     # e.g. eastus
ACR=<globally-unique-name>       # lowercase alphanumeric
CLUSTER=rda-aks
TENANT_ID=12345678-1234-1234-1234-123456789012   # your tenant id (= tenant-root management-group id)

# 0. Providers (no-op if already registered)
az provider register -n Microsoft.ContainerService
az provider register -n Microsoft.ContainerRegistry

# 1. Resource group + registry
az group create -n "$RG" -l "$LOC"
az acr create -g "$RG" -n "$ACR" --sku Basic

# 2. Build the worker image server-side (no local Docker needed).
#    Run from the REPO ROOT: the trailing '.' is the build context (the whole
#    product), and the Dockerfile lives at deploy/Dockerfile.
#    --image rda:latest is the repository:tag this build CREATES and pushes into
#    YOUR registry (nothing pre-exists — there is no shared/public rda image).
#    It becomes $ACR.azurecr.io/rda:latest, which MUST match the image: line in
#    job.yaml. Pick a different name if you like, but change it in both places.
az acr build --registry "$ACR" --image rda:latest --file deploy/Dockerfile .

# 3. Cluster. Pick an x64 node size AVAILABLE in your region (some subscriptions
#    only offer Arm64 B-series; the readiness check flags this). Standard_D2s_v3
#    is a safe x64 default. Two small nodes suffice for a handful of subscriptions.
az aks create -g "$RG" -n "$CLUSTER" --node-count 2 --node-vm-size Standard_D2s_v3 \
  --tier free --generate-ssh-keys

# 4. Let the cluster pull from the registry.
az aks update -g "$RG" -n "$CLUSTER" --attach-acr "$ACR"

# 5. Enable workload identity (OIDC issuer + webhook).
az aks update -g "$RG" -n "$CLUSTER" --enable-oidc-issuer --enable-workload-identity
ISSUER=$(az aks show -g "$RG" -n "$CLUSTER" --query oidcIssuerProfile.issuerUrl -o tsv)

# 6. Worker identity + its RBAC (Reader shown; add the others from the table in
#    section 2 as needed for consumption/metrics/upload).
#    Scope Reader at the TENANT-ROOT MANAGEMENT GROUP (its id = your tenant id),
#    NOT per subscription: it inherits Reader to every current and future
#    subscription (so none is silently missed) AND grants the management-group
#    read the wrapper's up-front coverage gate needs to CONFIRM it is seeing every
#    subscription. A per-subscription grant makes the run hard-fail the coverage
#    gate (or require -AllowPartialAccess). Granting at this scope requires you to
#    be Owner or User Access Administrator at the tenant-root management group.
az identity create -g "$RG" -n rda-uami
CLIENT_ID=$(az identity show -g "$RG" -n rda-uami --query clientId -o tsv)
PRINCIPAL_ID=$(az identity show -g "$RG" -n rda-uami --query principalId -o tsv)
az role assignment create --assignee-object-id "$PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal --role Reader \
  --scope /providers/Microsoft.Management/managementGroups/$TENANT_ID

# 7. Federate the identity to the pod's Kubernetes ServiceAccount.
#    Subject MUST be system:serviceaccount:<namespace>:<serviceaccount>.
az identity federated-credential create --name rda-fic --identity-name rda-uami -g "$RG" \
  --issuer "$ISSUER" --subject system:serviceaccount:rda:rda-sa \
  --audience api://AzureADTokenExchange

# 8. Get cluster credentials for kubectl.
az aks get-credentials -g "$RG" -n "$CLUSTER"

echo "UAMI client id (put this in serviceaccount.yaml): $CLIENT_ID"
```

---

## 4. Apply the Kubernetes manifests

1. Edit `deploy/k8s/serviceaccount.yaml` — replace `<UAMI-client-id>` with the
   `$CLIENT_ID` printed above.
2. Edit `deploy/k8s/job.yaml` — set `image:` to `<acr>.azurecr.io/rda:latest`
   and set `completions`, `parallelism`, and the `SHARD_COUNT` env value **all to
   the same number** (they are the shard count; the file comment stresses this).

```bash
kubectl create namespace rda
kubectl apply -f deploy/k8s/serviceaccount.yaml
```

Optional Job env knobs (uncomment in `job.yaml`):

- `HEAD_ROOM` — leave N% of API concurrency in reserve (competes less with your
  production Azure workloads).
- `SKIP_METRICS` = `"true"` — skip the metrics phase (drop Monitoring Reader).
- `SKIP_CONSUMPTION` = `"true"` — skip consumption (drop Cost Management Reader).
- `USE_METRICS_BATCH` = `"true"` — use the Azure Monitor `metrics:getBatch`
  data-plane fast-path (VMs, managed disks, storage accounts, SQL databases, VM
  scale sets, Cosmos DB; anything else stays per-call, and any batch failure falls
  back to per-call). Cuts the metrics phase's Azure Monitor call volume on large
  tenants. The tool attempts to register the `Microsoft.Insights` provider.
- `INCLUDE_STORAGE_METRICS` = `"true"` - also collect the Storage Account
  `UsedCapacity` metric. This is opt-in: it costs one metric-query call per storage
  account, so it is off by default and a tenant with a large storage estate would
  otherwise spend much of its metrics phase on that one capacity figure. Set it when
  storage capacity is actually wanted.
- `PARALLEL_STREAMS` — per-pod concurrency across this pod's cores (distinct from
  sharding across pods). Omit to auto-tune from the pod's CPU/RAM; capped at ~6 by
  the tenant-wide Resource Graph limit (~15 req/sec). Give the node ~0.7 GB RAM
  headroom per stream at metrics-phase peak.
- `UPLOAD_BLOB_URI` — a blob container URL
  (`https://<account>.blob.core.windows.net/<container>[/<prefix>]`). When set, the
  entrypoint passes it to the wrapper and each pod uploads its finalized zip there
  (see section 7). Requires Storage Blob Data Contributor on the UAMI. Omit to keep
  each zip node-local.

---

## 5. Preflight one pod (recommended)

Before fanning out to N pods, prove one node actually works end-to-end. Run
`deploy/Test-NodeReadiness.ps1` as a one-off pod using the **same** image,
ServiceAccount, and workload-identity label as the real Job, but pointing the
container command at the readiness script:

```yaml
# a throwaway pod spec — same SA + label as job.yaml, different command:
command: ["pwsh","-NoProfile","-File","/rda/deploy/Test-NodeReadiness.ps1"]
# add, if you will use centralized upload:
#   args: ["-UploadToBlobContainerUri","https://<account>.blob.core.windows.net/<container>"]
```

It verifies, in order: workload-identity env injected → federated sign-in works →
Resource Graph read authorized → (optional) blob write+delete. Exit codes:

- **0** — this node can run a shard.
- **1** — a specific capability failed (usually a missing UAMI role; it names it).
- **2** — no workload-identity env at all (the SA annotation or the
  `azure.workload.identity/use: "true"` pod label is missing/wrong).

---

## 6. Run the shards

```bash
kubectl apply -f deploy/k8s/job.yaml
kubectl -n rda get pods -w
kubectl -n rda logs -f job/rda-shards
```

Each pod reads `JOB_COMPLETION_INDEX`, signs in via workload identity, and
processes only its shard's subscriptions. `backoffLimit: 0` means a shard failure
is surfaced, not silently retried.

---

## 7. Collect the output

Each shard produces its **own** `AllSubscriptions_ResourcesReport_<timestamp>.zip`
covering only its slice — a complete, self-contained report identical in shape to
a single-machine run.

- **Centralized upload (recommended for a cluster):** set the `UPLOAD_BLOB_URI`
  env on the Job to a container URL
  (`https://<account>.blob.core.windows.net/<container>[/<prefix>]`). The entrypoint
  forwards it to the wrapper as `-UploadToBlobContainerUri`, and after the run each
  pod uploads its finalized zip there — passwordless, via the same workload identity
  (so the UAMI needs Storage Blob Data Contributor), with the blob name made unique
  per shard (`shard-<i>of<n>-<zip>`). The shards are disjoint, so the N zips together
  cover the tenant exactly once — ingest them separately, no merge needed. A
  malformed URL or a missing `Az.Storage` module fails the pod up front; but a
  transient/RBAC failure during the upload itself is **best-effort** — the pod still
  succeeds and the zip stays on the node's local disk with a warning.
- **One combined MainSummary (optional):** gather the shard zips and rebuild a
  single aggregate summary. See the command sequence in
  [`../docs/horizontal-sharding.md`](../docs/horizontal-sharding.md)
  ("Collecting the results") — extract the inner per-subscription zips, re-zip
  into one outer zip, then run `Build-MainSummaryFromZip.ps1 -InputZip <zip>`.

---

## 8. Tear down

Worker nodes only need to live for the length of the run — a good fit for
spot/evictable node pools. When done:

```bash
az group delete -n "$RG" --yes --no-wait
```

This removes the cluster, ACR, and UAMI. Remove the role assignments separately
if you scoped them outside the resource group (e.g. at a management group).

---

## 9. Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Pod throws "Workload-identity environment not present" | SA annotation or `azure.workload.identity/use` label missing | re-check `serviceaccount.yaml` client id + the pod label in `job.yaml`; readiness check exits 2 |
| Sign-in fails in `Connect-AzAccount` | federated credential subject mismatch | subject must be exactly `system:serviceaccount:rda:rda-sa` |
| Run stops at "N subscription(s) are NOT readable" | UAMI lacks Reader on them (default hard-stop) | grant Reader at MG or per-subscription scope and re-run, or pass `-AllowPartialAccess` to skip them |
| Run hard-fails up front on consumption access | UAMI lacks Cost Management Reader (a clear billing denial stops the run) | grant Cost Management Reader, or set `SKIP_CONSUMPTION=true` |
| Metrics missing for some subscriptions | UAMI lacks Monitoring Reader (the metrics phase soft-skips and reports it) | grant Monitoring Reader, or set `SKIP_METRICS=true` |
| Pod throws "SHARD_COUNT is N but JOB_COMPLETION_INDEX is not set" | Job is not `completionMode: Indexed` | use the shipped `job.yaml` (Indexed); the guard prevents silent shard collapse |
| Upload fails | UAMI lacks Storage Blob Data Contributor | grant it on the storage account/container — note the pod still succeeds and the zip stays node-local |
| `az acr build` can't find the Dockerfile | wrong path/context | run from the repo root with `--file deploy/Dockerfile .` |
| Shard signs in fine, then fails with an auth error PARTWAY through a long run | projected federated token expired mid-run (see the section below) | raise `SHARD_COUNT` so each shard is shorter, raise the SA token `expirationSeconds`, or re-run that shard with `RESUME=true` |

---

## 10. Known limitation: token lifetime on long shards

`deploy/entrypoint.ps1` reads the projected federated token **once**, at sign-in.
Kubernetes gives that token a bounded lifetime (commonly about one hour) and rewrites the file when it rotates, so the value the process captured goes stale even though the file on disk is fresh.
A shard whose wall time exceeds the token lifetime can therefore fail on refresh partway through the run.

The confusing part is *where* it surfaces: sign-in succeeds, the run gets going, and the failure appears later as an authentication error in the middle of a subscription.
That looks like a permissions problem and is not one.

This sign-in follows Microsoft's official workload-identity sample, so the pattern is correct - the gap is that the sample assumes a short-lived process.

**Not yet measured.** The one-hour figure is the projected default, not an observed failure point.
Confirming the real boundary needs a deliberate AKS run longer than the token lifetime, which has not been done.

### Mitigations, in order of preference

1. **Keep each shard shorter than the token lifetime.**
   Raise `SHARD_COUNT` so each node owns fewer subscriptions.
   Size it first with `Run-AllSubscriptions.ps1 -Plan`, which reports the projected busiest-shard wall time.
2. **Raise the projected token expiry, up to 24 hours.**
   The webhook injects the projected volume, so this is set with an annotation rather than by editing a volume block in `job.yaml`.
   Add it to `deploy/k8s/serviceaccount.yaml` alongside the existing `client-id` annotation:

   ```yaml
   metadata:
     annotations:
       azure.workload.identity/client-id: <UAMI-client-id>
       azure.workload.identity/service-account-token-expiration: "86400"
   ```

   The default is 3600 seconds and the accepted range is 3600 to 86400, so 86400 buys a 24 hour ceiling.
   The same annotation can go on the pod template instead, where it takes precedence over the ServiceAccount.
   Per the [Azure Workload Identity annotation reference](https://azure.github.io/azure-workload-identity/docs/topics/service-account-labels-and-annotations.html). Content was rephrased for compliance with licensing restrictions.

   Worth knowing which token is which: the Kubernetes service-account token expiry is **not** tied to the Entra token expiry.
   The Entra access token `Connect-AzAccount` obtains lasts 24 hours, and it is the Kubernetes token - 1 hour by default - that governs whether a refresh can succeed.
   That is why raising this annotation is the lever that matters for a long shard.
3. **Re-run the affected shard with `RESUME=true`.**
   Completed subscriptions are skipped, so an expiry costs only the unfinished remainder rather than the whole slice.

A code mitigation - re-reading the token file and re-authenticating when it expires - would change the auth flow and is deliberately not in place without that longer-than-an-hour verification run behind it.

---

## Related docs

- [`../README.md`](../README.md) — roles, single-machine usage, access check,
  Horizontal-scaling overview.
- [`../docs/horizontal-sharding.md`](../docs/horizontal-sharding.md) — how
  sharding works and the full result-merge command sequence.
- `deploy/Test-MultiNodeReadiness.ps1` — operator-side preflight.
- `deploy/Test-NodeReadiness.ps1` — in-pod preflight.
