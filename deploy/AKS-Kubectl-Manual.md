# RDA on an EXISTING AKS cluster — Manual kubectl Guide

For an operator who already has an AKS cluster and a namespace and just wants to
run the Resource Discovery for Azure horizontal shards inside it and collect the
output. (Building a cluster from scratch is covered in
[`AKS-WorkloadIdentity-Setup.md`](AKS-WorkloadIdentity-Setup.md); this sheet assumes the cluster exists.)

## Assumptions

- You already have: an **AKS cluster**, a **namespace** you want to run in, and
  `kubectl` access to it.
- You can create an Azure **user-assigned managed identity** + role assignments
  (Owner / User Access Administrator at the scope you grant).

**Set your values once, in the shell you'll run the rest of this sheet in.** Edit
the right-hand sides, then paste this block into your terminal; every `$VAR` in
the commands below resolves from it (stay in the same shell session, or re-paste
if you open a new one). These are shell variables only — you do **not** edit the
YAML manifests until step 4.

```bash
RG=<resource group of the existing cluster>
CLUSTER=<existing AKS cluster name>
NS=<namespace you will run in>
SA=rda-sa                                   # keep unless you have a reason not to
TENANT_ID=<your tenant id = tenant-root management-group id>
ACR=<registry the cluster can pull from>    # lowercase alphanumeric, globally unique if new
```

| Var | Meaning |
|-----|---------|
| `RG` | resource group of the **existing** cluster |
| `CLUSTER` | existing AKS cluster name |
| `NS` | existing namespace you will run in |
| `SA` | ServiceAccount name (use `rda-sa` unless you have a reason not to) |
| `TENANT_ID` | your tenant id = tenant-root management-group id |
| `ACR` | a registry the cluster can pull from (existing or new) |

> `CLIENT_ID`, `PRINCIPAL_ID`, and `ISSUER` are **captured by the commands below**
> (steps 0 and 2) into the same shell — you don't set those by hand.

## 0. Prereqs on the existing cluster (check, enable only if missing)

```bash
# Is workload identity already enabled? (empty issuer = not enabled)
az aks show -g $RG -n $CLUSTER --query oidcIssuerProfile.issuerUrl -o tsv

# If empty, enable it (cluster-scoped, one-time, does NOT disrupt existing workloads):
az aks update -g $RG -n $CLUSTER --enable-oidc-issuer --enable-workload-identity

ISSUER=$(az aks show -g $RG -n $CLUSTER --query oidcIssuerProfile.issuerUrl -o tsv)
az aks get-credentials -g $RG -n $CLUSTER          # if you don't already have the context
```

Confirm the namespace will accept the workload (see **Namespace fit** below before you run).

## 1. Make the image pullable by the cluster

```bash
# Build YOUR image into a registry (nothing pre-exists — this creates rda:latest):
az acr build --registry $ACR --image rda:latest --file deploy/Dockerfile .

# Let the existing cluster pull from that registry:
az aks update -g $RG -n $CLUSTER --attach-acr $ACR
# (Alternatively, if you can't attach the ACR, add an imagePullSecret to the SA.)
```

## 2. Worker identity + RBAC

```bash
az identity create -g $RG -n rda-uami
CLIENT_ID=$(az identity show -g $RG -n rda-uami --query clientId -o tsv)
PRINCIPAL_ID=$(az identity show -g $RG -n rda-uami --query principalId -o tsv)

# Reader at the TENANT-ROOT MANAGEMENT GROUP so every sub is covered AND coverage
# is verifiable (per-subscription Reader instead => the coverage gate hard-stops
# unless you set ALLOW_PARTIAL_ACCESS for a test):
az role assignment create --assignee-object-id $PRINCIPAL_ID --assignee-principal-type ServicePrincipal \
  --role Reader --scope /providers/Microsoft.Management/managementGroups/$TENANT_ID
# plus, as needed (same MG scope): "Cost Management Reader", "Monitoring Reader"
# and "Storage Blob Data Contributor" on the collection storage account.
```

## 3. Federate to YOUR namespace + ServiceAccount

The federated subject MUST match the namespace + SA you run in:

```bash
az identity federated-credential create --name rda-fic --identity-name rda-uami -g $RG \
  --issuer $ISSUER --subject system:serviceaccount:$NS:$SA \
  --audience api://AzureADTokenExchange
```

## 4. Point the manifests at YOUR namespace

Edit both shipped manifests so **namespace + SA + federated subject all agree**:

- `deploy/k8s/serviceaccount.yaml` → `metadata.namespace: $NS`, `metadata.name: $SA`,
  set the `azure.workload.identity/client-id` annotation to `$CLIENT_ID`.
- `deploy/k8s/job.yaml` → `metadata.namespace: $NS`, `spec.template.spec.serviceAccountName: $SA`,
  `image:` → `$ACR.azurecr.io/rda:latest`, and `completions` = `parallelism` =
  `SHARD_COUNT` env (all the same number). Optionally set `UPLOAD_BLOB_URI` and,
  for a first test without tenant-root Reader, `ALLOW_PARTIAL_ACCESS: "true"`.

```bash
kubectl apply -f deploy/k8s/serviceaccount.yaml    # into your existing namespace
```

## 5. Namespace fit — check BEFORE you run (governed clusters)

The RDA image runs as **root** (PowerShell base image, no non-root `USER`). In an
existing, governed namespace this is the usual blocker:

- **Pod Security Admission:** if the namespace enforces `restricted`, the Job pods
  are **rejected** (root / capabilities). Run RDA in a `baseline`-labelled
  namespace, relax PSA for it, or ask us to harden the image (non-root `USER` +
  `securityContext`).
- **NetworkPolicy:** pods need egress to `login.microsoftonline.com`,
  `management.azure.com`, and (if uploading) `*.blob.core.windows.net`. A
  default-deny egress policy will break sign-in/collection — allow that egress.
- **ResourceQuota / LimitRange:** the Job launches `parallelism` pods; ensure the
  quota allows them and budget ~1–1.5 GB RAM per pod at metrics peak.

## 6. Preflight one pod (recommended)

Run `Test-NodeReadiness.ps1` as a throwaway pod in `$NS` with the same `$SA` and
the `azure.workload.identity/use: "true"` label:

```yaml
command: ["pwsh","-NoProfile","-File","/rda/deploy/Test-NodeReadiness.ps1"]
# args: ["-UploadToBlobContainerUri","https://<account>.blob.core.windows.net/<container>"]
```

Exit **0** = ready · **1** = a role is missing (it names which) · **2** = workload-identity env not injected (SA annotation / pod label / federated subject wrong).

## 7. Run

```bash
kubectl apply -f deploy/k8s/job.yaml
kubectl -n $NS logs -f job/rda-shards
```

Each pod reads `JOB_COMPLETION_INDEX`, signs in via workload identity (no secret), and processes **only its shard's subscriptions**.

## 8. Collect

With `UPLOAD_BLOB_URI` set, each pod uploads its own zip (`shard-<i>of<n>-<zip>`) to the container:

```bash
az storage blob download-batch --account-name <account> --source <container> \
  --destination ./collected --pattern "*.zip"
```

- **One zip per non-empty shard**; shards are disjoint, so together they cover the tenant once — **ingest each separately, no merge needed**.
- Each zip → inner `ResourcesReport_*.zip` → `Inventory_*.json`, `Metrics_*.json`, `Consumption_*.csv` (+ HTML).
- Optional single rolled-up view: `Build-MainSummaryFromZip.ps1` (see `docs/horizontal-sharding.md`).

## 9. Tear down (leave the existing cluster intact)

Remove only what you added — do **not** delete the existing cluster:

```bash
kubectl -n $NS delete -f deploy/k8s/job.yaml
kubectl -n $NS delete -f deploy/k8s/serviceaccount.yaml
az identity delete -g $RG -n rda-uami           # also removes its federated credential
# remove the role assignments you created (Reader/Cost/Monitoring/Storage) if no longer needed
```

## Quick troubleshooting

| Symptom | Fix |
|---|---|
| Pods **rejected** on admission (`violates PodSecurity "restricted"`) | image runs as root — use a `baseline` namespace, relax PSA, or harden the image |
| Sign-in fails in `Connect-AzAccount` | federated subject must equal `system:serviceaccount:$NS:$SA` |
| "Workload-identity environment not present" (exit 2) | SA annotation or `azure.workload.identity/use: "true"` pod label missing |
| Run hard-stops on subscription **coverage** | grant Reader at tenant-root MG; or `ALLOW_PARTIAL_ACCESS: "true"` for a test |
| Hard-fail on **consumption** access | grant Cost Management Reader, or `SKIP_CONSUMPTION: "true"` |
| Metrics missing for some subs | grant Monitoring Reader, or `SKIP_METRICS: "true"` |
| Sign-in/collection times out | NetworkPolicy egress to Azure endpoints is blocked |
| "SHARD_COUNT is N but JOB_COMPLETION_INDEX not set" | Job must be `completionMode: Indexed` (use the shipped `job.yaml`) |
| Upload fails | grant Storage Blob Data Contributor (pod still succeeds; zip stays node-local) |

> **Coverage reminder:** number of zips = number of **non-empty shards**, not number of subscriptions. Each shard's zip bundles every subscription in *its* slice.
