# Running RDA from an Azure DevOps Pipeline

This guide shows how to deploy the Resource Discovery for Azure horizontal shards
onto AKS **from an Azure DevOps (ADO) pipeline** and collect the output as
pipeline artifacts. For the manual/`kubectl` version see
[`AKS-Kubectl-Manual.md`](AKS-Kubectl-Manual.md); for the concepts see
[`AKS-WorkloadIdentity-Setup.md`](AKS-WorkloadIdentity-Setup.md). To run RDA
directly on **KEDA-scaled Azure DevOps agents** (`AzurePowerShell@5` + service
connection), see
[`agent-pool/keda/README.md`](agent-pool/keda/README.md).

## How it works — two identities, two execution contexts

The single most important thing to understand:

| | Who | Runs where | Used for |
|---|---|---|---|
| **ADO service connection** | an Entra app/UAMI behind an ARM service connection | on the **pipeline agent** | build the image, create the worker identity + roles, `kubectl apply` the Job |
| **Worker UAMI** (`rda-uami`) | user-assigned managed identity, federated to the pod ServiceAccount | **inside the AKS pods** | actually read Azure (inventory / metrics / consumption) |

The pipeline only **deploys** the Job. The inventory itself is collected **inside
the cluster by the pods under the UAMI's workload identity** — the ADO service
connection is *not* involved in reading Azure data, and **no service-principal
secret is ever injected into the pods**. Keep the manifests passwordless.

## Running RDA as a pipeline step: use `AzurePowerShell@5` only

If you run `Run-AllSubscriptions.ps1` **as a pipeline step** — either directly on
the agent, or on a self-hosted / KEDA-scaled agent, rather than inside the pod —
run it **only** from the **`AzurePowerShell@5`** task, with **`pwsh: true`**, and
pass **`-TenantID`** equal to the service connection's tenant:

- **Use `AzurePowerShell@5` (task version 5), NOT `AzureCLI@2`.** RDA reads its
  identity from the **Az PowerShell** context (`Get-AzContext`). `AzurePowerShell@5`
  establishes that context from the service connection; `AzureCLI@2` only signs in
  the `az` CLI, leaving `Get-AzContext` empty — RDA then has no usable session and,
  on a headless agent, now **fails fast with a clear error** (exit 1) instead of
  hanging on an interactive sign-in prompt.
- **`pwsh: true`** selects PowerShell 7, which RDA requires (`#Requires -Version 7.0`).
- On a **self-hosted** agent (e.g. a KEDA agent pod), the Az PowerShell modules must
  already be in the agent image — `AzurePowerShell@5` does not install them.

```yaml
- task: AzurePowerShell@5
  inputs:
    azureSubscription: <your-service-connection>
    azurePowerShellVersion: 'LatestVersion'
    pwsh: true
    ScriptType: 'InlineScript'
    Inline: |
      ./Run-AllSubscriptions.ps1 -TenantID <service-connection-tenant-id> -ParallelStreams 1 -Obfuscate
```

## Prerequisites

1. **An ARM service connection** in the ADO project (Project settings → Service
   connections → Azure Resource Manager; prefer **workload identity federation**,
   not a stored secret). Note its name — it's the `azureSubscription:` value below.
2. **Permissions for that service connection** — this is the usual friction point:
   - **Owner** or **User Access Administrator** at the scope where you assign
     Reader. If you scope at the **tenant-root management group** (recommended, so
     no subscription is silently missed), the service-connection identity must have
     that right **at the MG root** — a default project-scoped connection usually
     does **not**. Either grant it, or have a platform team run the one-time
     bootstrap (stage 1) out-of-band and let the pipeline do only build+deploy.
   - Rights to `--attach-acr` and to apply to the cluster (cluster-admin, or the
     appropriate Azure-RBAC-for-Kubernetes role if the cluster uses that).
3. **The RDA repo** available to the pipeline (this repo, checked out via
   `checkout: self`, or referenced as a repository resource).
4. **An existing AKS cluster** with **workload identity enabled** (stage 1 enables
   it if missing) and a **namespace** to run in. Review "Namespace fit" in
   `AKS-Kubectl-Manual.md` (PodSecurity/`restricted` rejects the root image; NetworkPolicy
   egress to Azure; ResourceQuota).

## Restricted networking (no public internet egress)

If your environment has **no public internet access**, read this first —
it changes the agent, the image, and how the pipeline reaches the cluster.

**Reality check (state this up front).** The tool signs in with
**workload identity** and reads Azure, which *requires* reaching Microsoft Entra
(`login.microsoftonline.com`) and Azure Resource Manager (`management.azure.com`).
**Neither supports Private Link** — they are global public endpoints. So this
cannot run in a truly air-gapped network with zero external reachability. What it
*can* run in is an **egress-controlled** network: outbound denied by default, with
a firewall/NVA **FQDN allowlist** for the few Azure endpoints below, and **Private
Endpoints** for the services that support them.

**1. Egress allowlist (Azure Firewall / NVA / proxy).** Permit outbound HTTPS to:
- `login.microsoftonline.com`, `login.windows.net` — Entra token exchange (workload identity).
- `management.azure.com` — ARM, Resource Graph, Azure Monitor (metrics/consumption).
- `*.blob.core.windows.net` — the upload target (or use a Storage Private Endpoint instead).
- `*.azurecr.io`, `*.blob.core.windows.net`, and `mcr.microsoft.com` + `*.data.mcr.microsoft.com` — pulling the worker image and its base (or use an ACR Private Endpoint + imported base, below).
- If the AKS API server is reached directly: the cluster's API FQDN.
- These are the same egress rules AKS workload identity + the Az modules need generally; there are no RDA-specific hosts.

**2. Image with no MCR access.** The Dockerfile bases on
`mcr.microsoft.com/azure-powershell`. If ACR can't reach MCR at build time:
- Import the base once into your private ACR:
  `az acr import --name $(ACR) --source mcr.microsoft.com/azure-powershell:latest --image azure-powershell:latest`
  (runs server-side; needs the ACR to have an MCR path, or pre-stage the tar), **then** point the Dockerfile `FROM` at `$(ACR).azurecr.io/azure-powershell:latest` — or configure **ACR Artifact Cache** for MCR so the existing `FROM mcr.microsoft.com/...` resolves transparently.
- Give the ACR a **Private Endpoint** so the cluster pulls over the private network. `az acr build` still runs on ACR's server-side build compute; if that compute can't reach the base image, build the image on a self-hosted agent (Docker) and `az acr import` the finished `rda:latest` instead.

**3. Private AKS API server.** With a **private cluster**, a Microsoft-hosted agent
cannot reach the API server. Two options:
- **`az aks command invoke`** (recommended, no VNet line-of-sight needed): it runs
  your `kubectl`/`apply` **inside the cluster**, brokered through ARM. Replace the
  `az aks get-credentials` + `kubectl` lines in the Deploy/Collect stages with:
  ```bash
  az aks command invoke -g $(RG) -n $(CLUSTER) \
    --command "kubectl apply -f job.rendered.yaml -n $(NS)" --file job.rendered.yaml
  ```
  The service connection needs `Microsoft.ContainerService/managedClusters/runcommand/action`
  and `.../commandResults/read` (the **Azure Kubernetes Service Cluster User** +
  RBAC-admin roles cover it). `command invoke` reaches ARM only — no private DNS on
  the agent required.
- **Self-hosted agent inside the VNet** — then `get-credentials` + `kubectl` work
  as written. Use this if you also need private-DNS line-of-sight for other steps.

**4. Storage for collection.** Give the storage account a **Private Endpoint** so
the pods upload over the private network. The **Collect** stage's
`az storage blob download-batch` must run somewhere that can reach that endpoint —
a **self-hosted agent in the VNet**, or fetch the zips with `az aks command invoke`
(`kubectl cp` from a pod). `--auth-mode login` needs the *pipeline* identity to
have a Storage **data** role on the account.

**5. Microsoft-hosted vs self-hosted agent — decision:** if you can do everything
server-side (`az acr build`, `az aks command invoke`, and either blob PE reachable
from Azure or `command invoke` for collection) a Microsoft-hosted agent may still
work, because those calls go to ARM (public) not into the private VNet. The moment
you need direct line-of-sight to the private API server, a private blob endpoint,
or private ACR from the agent itself, use a **self-hosted agent in the VNet**.

## Recommended split: one-time bootstrap vs repeatable run

- **Stage 1 (bootstrap)** — create the UAMI, its RBAC, and the federated
  credential; enable workload identity on the cluster. This is **run-once** and
  often needs elevated (MG-scope) rights, so many teams do it manually or as a
  separate, tightly-permissioned pipeline. It is idempotent, so leaving it in is
  fine too.
- **Stages 2–3 (build → deploy → collect)** — the repeatable part the team runs
  each time they want an inventory.

## Sample `azure-pipelines.yml`

> **Why this example uses `AzureCLI@2`, not `AzurePowerShell@5`.** In this
> pod-native model RDA runs *inside* the AKS pods and authenticates via **workload
> identity** — the pipeline never runs `Run-AllSubscriptions.ps1` itself. Its
> stages only provision, build/deploy, and collect using `az` and `kubectl`, so
> `AzureCLI@2` is the correct task here. The "use `AzurePowerShell@5` only" rule
> above applies to the *other* model, where RDA runs **as a pipeline step** on the
> agent (see [`agent-pool/keda/README.md`](agent-pool/keda/README.md)) and needs an
> `Az` PowerShell context (`Get-AzContext`) that only `AzurePowerShell@5` sets up.

```yaml
trigger: none            # run manually / scheduled; this is not a code CI pipeline

variables:
  serviceConnection: 'rda-arm'          # your ARM service connection name
  RG: 'rda-inventory-rg'                # resource group of the EXISTING cluster
  CLUSTER: 'rda-aks'                    # existing AKS cluster
  NS: 'rda'                             # namespace to run in
  SA: 'rda-sa'                          # ServiceAccount name
  ACR: 'myrdaacr'                       # registry the cluster can pull from
  TENANT_ID: '00000000-0000-0000-0000-000000000000'   # = tenant-root MG id
  SHARD_COUNT: '4'                      # pods = shards; tune to tenant size
  UPLOAD_ACCOUNT: 'myrdaoutput'         # storage account for collected zips
  UPLOAD_CONTAINER: 'rda-output'
  ALLOW_PARTIAL_ACCESS: 'false'         # 'true' only for a first test w/o MG Reader

pool:
  vmImage: 'ubuntu-latest'              # Microsoft-hosted; no Docker needed (ACR builds server-side)

stages:
# ---------------------------------------------------------------------------
- stage: Bootstrap                      # run-once; safe to re-run (idempotent)
  jobs:
  - job: identity
    steps:
    - checkout: self
    - task: AzureCLI@2
      inputs:
        azureSubscription: $(serviceConnection)
        scriptType: bash
        scriptLocation: inlineScript
        inlineScript: |
          set -euo pipefail
          # Enable workload identity on the cluster if not already on
          if [ -z "$(az aks show -g $(RG) -n $(CLUSTER) --query oidcIssuerProfile.issuerUrl -o tsv)" ]; then
            az aks update -g $(RG) -n $(CLUSTER) --enable-oidc-issuer --enable-workload-identity
          fi
          ISSUER=$(az aks show -g $(RG) -n $(CLUSTER) --query oidcIssuerProfile.issuerUrl -o tsv)

          # UAMI (idempotent)
          az identity create -g $(RG) -n rda-uami -o none
          PRINCIPAL_ID=$(az identity show -g $(RG) -n rda-uami --query principalId -o tsv)

          # RBAC at the tenant-root management group (needs Owner/UAA at MG root)
          for ROLE in "Reader" "Cost Management Reader" "Monitoring Reader"; do
            az role assignment create --assignee-object-id "$PRINCIPAL_ID" \
              --assignee-principal-type ServicePrincipal --role "$ROLE" \
              --scope /providers/Microsoft.Management/managementGroups/$(TENANT_ID) -o none || true
          done
          # Storage Blob Data Contributor on the collection account (for upload)
          STID=$(az storage account show -g $(RG) -n $(UPLOAD_ACCOUNT) --query id -o tsv)
          az role assignment create --assignee-object-id "$PRINCIPAL_ID" \
            --assignee-principal-type ServicePrincipal --role "Storage Blob Data Contributor" \
            --scope "$STID" -o none || true

          # Federate the UAMI to the pod ServiceAccount (subject MUST match NS:SA)
          az identity federated-credential create --name rda-fic --identity-name rda-uami -g $(RG) \
            --issuer "$ISSUER" --subject system:serviceaccount:$(NS):$(SA) \
            --audience api://AzureADTokenExchange -o none || true

# ---------------------------------------------------------------------------
- stage: Deploy
  dependsOn: Bootstrap
  jobs:
  - job: build_and_apply
    steps:
    - checkout: self
    - task: AzureCLI@2
      inputs:
        azureSubscription: $(serviceConnection)
        scriptType: bash
        scriptLocation: inlineScript
        inlineScript: |
          set -euo pipefail
          # Build YOUR image server-side (creates $(ACR).azurecr.io/rda:latest)
          az acr build --registry $(ACR) --image rda:latest --file deploy/Dockerfile .
          # Ensure the cluster can pull from it
          az aks update -g $(RG) -n $(CLUSTER) --attach-acr $(ACR) -o none || true

          az aks get-credentials -g $(RG) -n $(CLUSTER) --overwrite-existing
          CLIENT_ID=$(az identity show -g $(RG) -n rda-uami --query clientId -o tsv)

          kubectl create namespace $(NS) --dry-run=client -o yaml | kubectl apply -f -

          # Render the ServiceAccount (inject namespace + SA + client id)
          sed -e "s/namespace: rda/namespace: $(NS)/" \
              -e "s/name: rda-sa/name: $(SA)/" \
              -e "s|<UAMI-client-id>|$CLIENT_ID|" \
              deploy/k8s/serviceaccount.yaml | kubectl apply -f -

          # Render the Job (namespace, SA, image, shard count, env knobs)
          sed -e "s/namespace: rda/namespace: $(NS)/" \
              -e "s/serviceAccountName: rda-sa/serviceAccountName: $(SA)/" \
              -e "s|<acr>|$(ACR)|" \
              -e "s/completions: 10/completions: $(SHARD_COUNT)/" \
              -e "s/parallelism: 10/parallelism: $(SHARD_COUNT)/" \
              -e "s/value: \"10\"/value: \"$(SHARD_COUNT)\"/" \
              deploy/k8s/job.yaml > /tmp/job.rendered.yaml
          # Append env knobs the sheet documents (upload + optional partial access)
          # (edit deploy/k8s/job.yaml directly for anything more elaborate)
          kubectl -n $(NS) apply -f /tmp/job.rendered.yaml

# ---------------------------------------------------------------------------
- stage: Collect
  dependsOn: Deploy
  jobs:
  - job: gather
    timeoutInMinutes: 240
    steps:
    - task: AzureCLI@2
      inputs:
        azureSubscription: $(serviceConnection)
        scriptType: bash
        scriptLocation: inlineScript
        inlineScript: |
          set -euo pipefail
          az aks get-credentials -g $(RG) -n $(CLUSTER) --overwrite-existing
          # Wait for all shards to finish before downloading
          kubectl -n $(NS) wait --for=condition=complete job/rda-shards --timeout=3h
          mkdir -p "$(Build.ArtifactStagingDirectory)/rda"
          az storage blob download-batch --account-name $(UPLOAD_ACCOUNT) \
            --source $(UPLOAD_CONTAINER) \
            --destination "$(Build.ArtifactStagingDirectory)/rda" \
            --auth-mode login --pattern "*.zip"
    - publish: '$(Build.ArtifactStagingDirectory)/rda'
      artifact: rda-reports
```

> The `sed` lines render the shipped manifests (which carry placeholders like
> `<acr>`, `<UAMI-client-id>`, `namespace: rda`, `SHARD_COUNT "10"`). If you'd
> rather keep pre-edited manifests in your own repo, drop the `sed` and just
> `kubectl apply -f` your copies. To add `UPLOAD_BLOB_URI` / `ALLOW_PARTIAL_ACCESS`
> / `USE_METRICS_BATCH` env vars, either bake them into your `job.yaml` or extend
> the render step — they map 1:1 to the knobs in `job.yaml`'s comments.

## Notes & gotchas

- **The pods authenticate themselves** via workload identity. Do **not** pass the
  ADO service-connection secret into the Job — the design is passwordless.
- **MG-scope role assignment** (the Reader-at-tenant-root grant) frequently exceeds
  a default service connection's rights. If stage 1 fails on the role assignment,
  have a platform admin create the UAMI + MG Reader once, then run only Deploy +
  Collect.
- **Blob download auth:** `--auth-mode login` needs the *pipeline* identity to have
  a Storage **data** role (e.g. Storage Blob Data Reader) on the account — that is
  separate from the UAMI's upload permission. Grant it to the service connection,
  or download with an account key from Key Vault.
- **`kubectl wait` is required** before Collect, or you'll download an empty/partial
  container before the shards finish.
- **Namespace fit** (PodSecurity `restricted` rejects the root image; egress
  NetworkPolicy; ResourceQuota) applies exactly as in `AKS-Kubectl-Manual.md`.
- **Self-hosted agents:** work the same; only needed if the agent must sit inside a
  private network to reach a private AKS API server.

## Simpler alternative — no AKS

If the tenant is small enough that one machine can finish in your wall-clock
window, skip AKS entirely: run `Run-AllSubscriptions.ps1` **directly in an
`AzurePowerShell@5` task** (with `pwsh: true`) using the service connection's
identity, then publish the produced zip as an artifact. Use `AzurePowerShell@5`,
**not** `AzureCLI@2`, for this step: the wrapper reads its identity from the Az
PowerShell context (`Get-AzContext`), which `AzurePowerShell@5` establishes from
the service connection. An `AzureCLI@2` task only pre-auths the `az` CLI, leaving
`Get-AzContext` empty — so the wrapper's auth gate falls through to an interactive
`Connect-AzAccount` and hangs on the non-interactive agent. Pass `-TenantID` equal
to the service connection's tenant (otherwise the gate re-authenticates), and
`-ParallelStreams 1` to keep a single Az context (avoiding the
`Save`/`Import-AzContext` fork across child processes). AKS sharding is only worth
the extra moving parts for very large (thousands-of-subscriptions) tenants.
Confirm the subscription count before choosing the AKS path.
