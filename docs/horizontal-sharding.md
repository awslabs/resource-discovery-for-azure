# Horizontal sharding — splitting a tenant across many machines

When a tenant has thousands of subscriptions, one machine can take a long time
to inventory all of them. Horizontal sharding lets you run the same tool on
several machines at once, with each machine responsible for a slice of the
subscriptions — no central coordinator, no shared database, and no risk of two
machines doing the same subscription or of a subscription being missed.

This document explains how it works in plain terms and how to use it.

## The problem it solves

Say you have 10 machines and a very large tenant. You want each machine to do a
roughly equal share of the subscriptions (about a tenth each), with two hard
rules:

- **No subscription is done twice** (that would waste time).
- **No subscription is skipped** (that would leave gaps in the report).

The catch: you don't want the machines talking to each other or sharing a
database to divide the work. Each machine should simply *know* which
subscriptions are its job. That is exactly what hash sharding does.

## The one idea: a repeatable fingerprint

Every Azure subscription has an ID that looks like a GUID
(`4a1f9c2b-....-............`). A **hash function** (SHA-256) takes that ID and
turns it into a large, scrambled number. The key property is that it is
**repeatable**: the same subscription ID always produces the same number — on
every machine, every time. Feed in the ID, always get the same fingerprint out.

We then take that big number and compute `number mod ShardCount` (the remainder
after dividing by the number of machines). With 10 machines that always yields a
result from 0 to 9 — a **bucket number**. So every subscription is permanently
assigned to one bucket, based purely on its own ID.

That is the whole trick. In the code this is the function
`Get-ShardKeyForSubscription` in `Functions/RunAllSubscriptions.Functions.ps1`:

```powershell
Get-ShardKeyForSubscription -SubscriptionId <the GUID> -ShardCount 10
# -> returns a bucket number 0..9
```

(If `ShardCount` is 1, it simply returns 0 — the "no sharding" case, which is
the normal single-machine behaviour.)

### Why SHA-256 and not a simpler hash

The bucket must be identical on every machine and every OS. `[string].GetHashCode()`
is *randomized per process* in modern .NET, so two machines would disagree.
SHA-256 of the lowercased ID is stable across processes, operating systems, and
CPU architectures. The first 4 bytes of the hash are assembled big-endian into a
number before the `mod`, so an x64 host and an ARM host compute the same bucket
for the same ID.

## How each machine uses it

Every machine runs the same command, changing only **which bucket is mine**:

```powershell
# Machine 0
./Run-AllSubscriptions.ps1 -ShardIndex 0 -ShardCount 10
# Machine 1
./Run-AllSubscriptions.ps1 -ShardIndex 1 -ShardCount 10
# ...
# Machine 9
./Run-AllSubscriptions.ps1 -ShardIndex 9 -ShardCount 10
```

Inside, each machine does three things:

1. Asks Azure for the **full list** of all subscriptions (every machine sees the
   same list).
2. For each subscription, computes its bucket number (0–9).
3. **Keeps only the subscriptions whose bucket matches its own `-ShardIndex`**
   and ignores the rest.

Steps 2 and 3 are the function `Select-ShardSubscriptions`. Machine 3 keeps only
subscriptions that hash to bucket 3; machine 7 keeps only bucket 7; and so on.

## A worked example

Four subscriptions, 10 machines:

| Subscription ID | Hash → bucket (mod 10) | Handled by |
|-----------------|------------------------|------------|
| `aaaa…`         | 7                      | Machine 7  |
| `bbbb…`         | 2                      | Machine 2  |
| `cccc…`         | 7                      | Machine 7  |
| `dddd…`         | 0                      | Machine 0  |

Machine 7 looks at all four, sees `aaaa` and `cccc` land in bucket 7, and does
those two. Machine 2 does `bbbb`. Machine 0 does `dddd`. Machines 1, 3, 4, 5, 6,
8, and 9 look at the same four subscriptions and keep none of them. Every
subscription is done exactly once, and no machine coordinated with any other.

## Why the two hard rules hold automatically

- **Nothing is done twice:** a subscription has exactly one hash, so it lands in
  exactly one bucket, so exactly one machine claims it.
- **Nothing is skipped:** every subscription lands in *some* bucket from 0 to
  `ShardCount-1`, and there is a machine for every bucket, so all of them are
  covered.
- **No coordination is needed:** the bucket depends *only* on the subscription's
  own ID — not on what other subscriptions exist, and not on what the other
  machines are doing — so all machines independently reach the same conclusions.
  They never have to talk to each other.

There is also a useful safety property: if a subscription is created or deleted,
it only affects its *own* bucket. It never reshuffles where the other
subscriptions go. That stability is why the split cannot be computed "per
machine" for the weighted variant — see the limitation below.

## The one limitation: balanced by count, not by size

Buckets are balanced by **number of subscriptions**, not by how big each
subscription is. Each machine gets roughly the same *count* of subscriptions,
but if one of them happens to be a very large subscription (say 40,000
resources), the machine that draws it will take longer than the others. Hash
sharding spreads the *number* of subscriptions evenly; it cannot see that one
subscription is a "whale".

For most tenants, with thousands of subscriptions, this evens out well enough in
practice. If subscription size is very uneven and wall-clock balance matters,
two other approaches address it:

- **Weighted plan:** do one cheap pre-pass that counts resources per
  subscription, then split so each machine's *total resource count* is roughly
  equal. This must be computed **once** and shared with all machines (evenness is
  a global property — it depends on all subscriptions together — so it cannot be
  computed independently per machine without risking overlaps or gaps).
- **Dynamic work-queue:** workers claim subscriptions from a shared store (e.g.
  Azure Table Storage) as they finish, so a machine that draws a whale simply
  claims fewer subscriptions. This balances by actual wall-clock and recovers
  from a crashed worker, at the cost of an external dependency and a claim
  protocol.

## Parameters reference

| Parameter      | Meaning                                                        | Default |
|----------------|----------------------------------------------------------------|---------|
| `-ShardCount`  | Total number of machines (buckets) splitting the tenant        | `1` (no sharding) |
| `-ShardIndex`  | Which bucket *this* machine handles, from `0` to `ShardCount-1` | `0`     |

Notes:

- `ShardCount = 1` (the default) means no sharding — the machine processes every
  eligible subscription, exactly as before.
- `ShardIndex` must be in the range `0 .. ShardCount-1`; the wrapper validates
  this up front and stops with a clear message otherwise.
- Run **one shard per machine**. Each machine should use its own inventory
  output folder. The resume-state file is scoped per shard, so `-Resume` on a
  machine only resumes that machine's own slice.

## Collecting the results

Each machine runs its own copy of `Run-AllSubscriptions.ps1`, so each one
produces its **own** consolidated outer zip
(`AllSubscriptions_ResourcesReport_<timestamp>.zip`) covering **only its slice**
of subscriptions. After 10 machines you therefore have **10 separate outer
zips**.

### Recommended: upload the shard zips separately

Each shard zip is a complete, self-contained report artifact — identical in
shape to what an ordinary single-machine run produces, just covering fewer
subscriptions. So the ingestion server accepts each one exactly like any normal
run's output: uploading the 10 shard zips is simply 10 normal ingestions.

Uploading them separately is usually the better choice:

- It spreads the ingestion load across 10 smaller uploads instead of one large
  merged archive.
- Because the shards are disjoint by construction, the 10 uploads together cover
  the whole tenant exactly once, with no duplicates and no gaps — no local merge
  step is required.

### Optional: merge locally into one MainSummary

You only need to merge locally if you want a single combined `MainSummary.html`
on your own machine (rather than one summary per shard). Note the tooling here:

- `Build-MainSummaryFromZip.ps1` rebuilds the aggregate `MainSummary.html` from
  **one** already-consolidated outer zip (via `-InputZip`). It does **not**
  combine multiple outer zips, and there is currently no single built-in command
  that merges the per-machine shard zips into one.

Merging is still straightforward, because each outer zip is just a flat
container holding one inner zip per subscription, and the shard slices are
disjoint (no two machines produce a zip for the same subscription, so there are
no name collisions). Gather the shard zips into a folder and run:

```powershell
# 1. Extract the inner per-subscription zips out of every shard's outer zip
#    into one staging folder.
$staging = New-Item -ItemType Directory -Path ./tenant-merge -Force
Get-ChildItem ./shard-zips -Filter 'AllSubscriptions_ResourcesReport_*.zip' |
    ForEach-Object { Expand-Archive -Path $_.FullName -DestinationPath $staging -Force }

# 2. Re-zip the collected per-subscription zips into one tenant-wide outer zip
#    (the same shape a single run produces).
$merged = './AllSubscriptions_ResourcesReport_tenant.zip'
Compress-Archive -Path (Join-Path $staging '*.zip') -DestinationPath $merged -Force

# 3. Build the aggregate MainSummary from the merged zip.
./Build-MainSummaryFromZip.ps1 -InputZip $merged
```

## Running the shards on AKS (containers / CI-CD)

The sharding above is transport-agnostic: each shard is just
`Run-AllSubscriptions.ps1` with a distinct `-ShardIndex`, so you can run the
shards as VMs, as CI/CD jobs, or as pods on AKS. This section shows the AKS
path, because it is the most common "spin up N cheap workers, run, tear down"
pattern — and it is the one verified end-to-end for this guide.

> **Just want the step-by-step?** See the copy-paste runbook
> [`deploy/CUSTOMER-SETUP.md`](../deploy/CUSTOMER-SETUP.md) — it walks through the
> readiness checks, cluster + identity setup, running the Job, collecting output,
> and troubleshooting. The rest of this section is the same material with more of
> the "why".

### The access trade-off — read this first

Single-machine and multi-node runs need **different levels of access**:

- A **single-machine** run typically uses the operator's own signed-in identity
  (`Connect-AzAccount` on a laptop / Cloud Shell). It only needs **Reader** on
  the subscriptions (plus Cost Management Reader / Monitoring Reader if
  collecting consumption / metrics).
- A **multi-node** run trades *more setup and more access* for *far less
  wall-clock time*. The worker pods are non-interactive, so they authenticate as
  a **workload identity** (a managed identity federated to the cluster), and
  someone has to **stand up the cluster** and **grant that identity its roles**.

So multi-node is faster, but it needs an identity with broader, pre-granted
access and the rights to create the infrastructure. Budget for that before you
start. Run the readiness check first:

```powershell
./deploy/Test-MultiNodeReadiness.ps1 -Location <region>
```

It is read-only and prints a PASS/WARN/FAIL table of everything below.

### RBAC the worker identity (UAMI) needs

Grant these to the user-assigned managed identity the pods federate to. Scope
Reader at the tenant-root management group to cover the whole tenant in one
grant, or per subscription for a smaller blast radius:

| Role | Why | Scope |
|------|-----|-------|
| **Reader** | inventory (Resource Graph / ARM reads) | tenant-root MG or per subscription |
| **Cost Management Reader** | consumption (omit if `-SkipConsumption`) | billing / subscription |
| **Monitoring Reader** | metrics (omit if `-SkipMetrics`) | subscription |
| **Storage Blob Data Contributor** | upload each node's output zip | the collection storage account |

The person doing the setup also needs rights to **create AKS/ACR**
(Contributor or Owner) and to **create role assignments + federated credentials**
(Owner or User Access Administrator).

### One-time setup (verified commands)

All commands below were run end-to-end against a live subscription for this
guide. Replace the placeholders; the GUID shown is the Azure documentation
placeholder, not a real value.

```bash
RG=rda-inventory-rg
LOC=<region>                     # e.g. eastus
ACR=<globally-unique-name>       # lowercase alphanumeric
CLUSTER=rda-aks

# 0. Providers (no-op if already registered)
az provider register -n Microsoft.ContainerService
az provider register -n Microsoft.ContainerRegistry

# 1. Resource group + registry
az group create -n "$RG" -l "$LOC"
az acr create -g "$RG" -n "$ACR" --sku Basic

# 2. Build the worker image server-side (no local Docker needed). The
#    Dockerfile ships at deploy/Dockerfile; build from the REPO ROOT (the
#    trailing '.') so the product files - INCLUDING Version.json - are in the
#    build context. .dockerignore keeps local/dev content out of the image.
az acr build --registry "$ACR" --image rda:latest --file deploy/Dockerfile .

# 3. Cluster. Pick an x64 node size that is AVAILABLE in your region — some
#    subscriptions only offer Arm64 B-series (Standard_B2s was rejected in
#    testing); the readiness check flags this. Standard_D2s_v3 is a safe x64
#    default. Two small nodes are enough for a handful of subscriptions.
az aks create -g "$RG" -n "$CLUSTER" --node-count 2 --node-vm-size Standard_D2s_v3 \
  --tier free --generate-ssh-keys

# 4. Let the cluster pull from the registry.
az aks update -g "$RG" -n "$CLUSTER" --attach-acr "$ACR"

# 5. Enable workload identity (OIDC issuer + the webhook).
az aks update -g "$RG" -n "$CLUSTER" --enable-oidc-issuer --enable-workload-identity
ISSUER=$(az aks show -g "$RG" -n "$CLUSTER" --query oidcIssuerProfile.issuerUrl -o tsv)

# 6. Worker identity + its RBAC (Reader shown; add the others from the table).
az identity create -g "$RG" -n rda-uami
CLIENT_ID=$(az identity show -g "$RG" -n rda-uami --query clientId -o tsv)
PRINCIPAL_ID=$(az identity show -g "$RG" -n rda-uami --query principalId -o tsv)
az role assignment create --assignee-object-id "$PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal --role Reader \
  --scope /subscriptions/12345678-1234-1234-1234-123456789012

# 7. Federate the identity to the pod's Kubernetes service account.
#    Subject MUST be system:serviceaccount:<namespace>:<serviceaccount>.
az identity federated-credential create --name rda-fic --identity-name rda-uami -g "$RG" \
  --issuer "$ISSUER" --subject system:serviceaccount:rda:rda-sa \
  --audience api://AzureADTokenExchange
```

### The Kubernetes manifests

Two manifests ship in the repo at `deploy/k8s/`:

- `deploy/k8s/serviceaccount.yaml` — the ServiceAccount, annotated with the UAMI
  client id, that the pods federate to.
- `deploy/k8s/job.yaml` — the indexed Job. Each pod opts in to workload identity
  with the `azure.workload.identity/use: "true"` label and derives its shard
  from the indexed-Job completion index (`JOB_COMPLETION_INDEX`).

Edit the two placeholders, then apply:

```bash
# 1. Set the UAMI client id in the ServiceAccount annotation.
#    (CLIENT_ID was captured in setup step 6.)
sed -i "s|<UAMI-client-id>|$CLIENT_ID|" deploy/k8s/serviceaccount.yaml
# 2. Set your registry in the Job's image reference.
sed -i "s|<acr>|$ACR|" deploy/k8s/job.yaml

kubectl create namespace rda --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f deploy/k8s/serviceaccount.yaml
kubectl apply -f deploy/k8s/job.yaml
```

In `deploy/k8s/job.yaml`, `completions`, `parallelism`, and the `SHARD_COUNT`
env value MUST all equal the number of shards — change all three together. The
`HEAD_ROOM`, `SKIP_METRICS`, and `SKIP_CONSUMPTION` env vars are optional knobs,
commented in the manifest.

The pod entrypoint ships at `deploy/entrypoint.ps1` and is baked in as the
image `ENTRYPOINT`, so each pod runs it automatically — you don't author it. It
signs in with **no secret** (the webhook injects the federated token and the
identity env vars, and the tool exchanges them via the Az module), derives this
pod's shard from `JOB_COMPLETION_INDEX`, honours the `SHARD_COUNT` / `HEAD_ROOM`
/ `SKIP_METRICS` / `SKIP_CONSUMPTION` env vars, and runs the wrapper for THIS
shard only. The no-secret sign-in it performs is:

```powershell
Connect-AzAccount -ServicePrincipal `
  -ApplicationId $env:AZURE_CLIENT_ID `
  -Tenant       $env:AZURE_TENANT_ID `
  -FederatedToken (Get-Content -Raw $env:AZURE_FEDERATED_TOKEN_FILE).Trim() | Out-Null
```

### Output: write local, upload once

Each pod writes its report to the node's **local ephemeral disk** first (fast,
no per-object network round-trips), builds its one consolidated shard zip, and
then uploads that single artifact to blob storage before it exits. Do **not**
stream individual JSON files to blob — local-first then one upload is both
faster and simpler.

You don't hand-roll this: the wrapper has a built-in uploader. Set the
`UPLOAD_BLOB_URI` env in the Job to a blob container URL and each pod ships its
finalized zip there automatically. `entrypoint.ps1` forwards it to the wrapper's
`-UploadToBlobContainerUri`, which uploads over the **same workload-identity
sign-in the pod already did** — `New-AzStorageContext -UseConnectedAccount`, no
account key, no SAS, and no second `Connect-AzAccount`. The blob name is made
unique per shard (`shard-<i>of<n>-...`) so concurrent pods never collide.

```yaml
        # in deploy/k8s/job.yaml, alongside SHARD_COUNT:
        - name: UPLOAD_BLOB_URI
          value: "https://<account>.blob.core.windows.net/reports"
```

This requires the worker identity to have **Storage Blob Data Contributor** on
the target storage account (the data-plane role in the RBAC table above —
control-plane Contributor is not enough for `-UseConnectedAccount`). Upload is
best-effort: if it fails, the run still succeeds and the zip remains on the
node's local disk with a loud warning.

Because the shard slices are disjoint, the uploaded zips together cover the
whole tenant exactly once. Ingest them separately, or merge locally into one
`MainSummary.html` as in "Collecting the results" above.

### Cost note

Worker nodes only need to live for the length of the run, so this is a good fit
for **spot / evictable** node pools — often ~4-5x cheaper than pay-as-you-go for
short batch runs. Size the nodes to your subscriptions (small nodes are fine for
sparse subscriptions) and delete the resource group when done:

```bash
az group delete -n "$RG" --yes --no-wait
```
