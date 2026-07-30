# RDA on AKS — One-Page Run Sheet

A condensed checklist for running the Resource Discovery for Azure horizontal
shards on AKS and collecting the output. Full detail and rationale live in
[`CUSTOMER-SETUP.md`](CUSTOMER-SETUP.md).

Fill these in first:

| Var | Meaning |
|-----|---------|
| `RG` | resource group for the cluster (e.g. `rda-inventory-rg`) |
| `LOC` | region (e.g. `eastus`) |
| `ACR` | globally-unique registry name (lowercase alphanumeric) |
| `CLUSTER` | AKS cluster name (e.g. `rda-aks`) |
| `TENANT_ID` | your tenant id = tenant-root management-group id |

## 1. Build cluster + registry + identity (one-time)

```bash
az group create -n $RG -l $LOC
az acr create -g $RG -n $ACR --sku Basic
az acr build --registry $ACR --image rda:latest --file deploy/Dockerfile .    # builds YOUR image
az aks create -g $RG -n $CLUSTER --node-count 2 --node-vm-size Standard_D2s_v3 --tier free --generate-ssh-keys
az aks update -g $RG -n $CLUSTER --attach-acr $ACR
az aks update -g $RG -n $CLUSTER --enable-oidc-issuer --enable-workload-identity
ISSUER=$(az aks show -g $RG -n $CLUSTER --query oidcIssuerProfile.issuerUrl -o tsv)

az identity create -g $RG -n rda-uami
CLIENT_ID=$(az identity show -g $RG -n rda-uami --query clientId -o tsv)
PRINCIPAL_ID=$(az identity show -g $RG -n rda-uami --query principalId -o tsv)

# RBAC — grant Reader at the TENANT-ROOT MANAGEMENT GROUP (not per-subscription)
az role assignment create --assignee-object-id $PRINCIPAL_ID --assignee-principal-type ServicePrincipal \
  --role Reader --scope /providers/Microsoft.Management/managementGroups/$TENANT_ID
# plus, as needed: "Cost Management Reader" + "Monitoring Reader" (same scope),
# and "Storage Blob Data Contributor" on the collection storage account.

az identity federated-credential create --name rda-fic --identity-name rda-uami -g $RG \
  --issuer $ISSUER --subject system:serviceaccount:rda:rda-sa --audience api://AzureADTokenExchange

az aks get-credentials -g $RG -n $CLUSTER
echo "CLIENT_ID = $CLIENT_ID"   # goes into serviceaccount.yaml
```

## 2. Configure the two manifests

- `deploy/k8s/serviceaccount.yaml` → set `azure.workload.identity/client-id` to `$CLIENT_ID`.
- `deploy/k8s/job.yaml`:
  - `image:` → `$ACR.azurecr.io/rda:latest`
  - `completions` = `parallelism` = `SHARD_COUNT` env → **all the same number** (= number of shards/pods).
  - `UPLOAD_BLOB_URI` → `https://<account>.blob.core.windows.net/<container>` (so every shard's zip lands in one place).
  - First test only, if you don't yet have tenant-root MG Reader: `ALLOW_PARTIAL_ACCESS: "true"`.

## 3. Preflight one pod (recommended)

Run `Test-NodeReadiness.ps1` as a throwaway pod (same ServiceAccount + `azure.workload.identity/use: "true"` label):

```yaml
command: ["pwsh","-NoProfile","-File","/rda/deploy/Test-NodeReadiness.ps1"]
# args: ["-UploadToBlobContainerUri","https://<account>.blob.core.windows.net/<container>"]
```

Exit **0** = ready · **1** = a role is missing (it names which) · **2** = workload-identity env not injected (SA annotation / pod label wrong).

## 4. Run

```bash
kubectl create namespace rda
kubectl apply -f deploy/k8s/serviceaccount.yaml
kubectl apply -f deploy/k8s/job.yaml
kubectl -n rda logs -f job/rda-shards
```

Each pod reads `JOB_COMPLETION_INDEX`, signs in via workload identity (no secret), and processes **only its shard's subscriptions**.

## 5. Collect

With `UPLOAD_BLOB_URI` set, each pod uploads its own zip (named `shard-<i>of<n>-<zip>`) to the container:

```bash
az storage blob download-batch --account-name <account> --source <container> \
  --destination ./collected --pattern "*.zip"
```

- You get **one zip per non-empty shard**; shards are disjoint, so together they cover the tenant once — **ingest each separately, no merge needed**.
- Each zip → inner `ResourcesReport_*.zip` → `Inventory_*.json`, `Metrics_*.json`, `Consumption_*.csv` (+ HTML reports).
- Optional single rolled-up view: `Build-MainSummaryFromZip.ps1` (see `docs/horizontal-sharding.md`).

## 6. Tear down

```bash
az group delete -n $RG --yes
# remove role assignments separately if scoped at the management group.
```

## Quick troubleshooting

| Symptom | Fix |
|---|---|
| Run hard-stops on subscription **coverage** | Grant Reader at the tenant-root MG; or set `ALLOW_PARTIAL_ACCESS: "true"` for a test |
| "N subscription(s) are NOT readable" | UAMI missing Reader on them — grant it, or `ALLOW_PARTIAL_ACCESS` to skip |
| Hard-fail on **consumption** access | Grant Cost Management Reader, or `SKIP_CONSUMPTION: "true"` |
| Metrics missing for some subs | Grant Monitoring Reader, or `SKIP_METRICS: "true"` |
| Sign-in fails in `Connect-AzAccount` | Federated subject must be exactly `system:serviceaccount:rda:rda-sa` |
| "SHARD_COUNT is N but JOB_COMPLETION_INDEX not set" | Job must be `completionMode: Indexed` (use the shipped `job.yaml`) |
| Upload fails | Grant Storage Blob Data Contributor (pod still succeeds; zip stays node-local) |

> **Coverage reminder:** number of zips = number of **non-empty shards**, not number of subscriptions. Each shard's zip bundles every subscription in *its* slice.
