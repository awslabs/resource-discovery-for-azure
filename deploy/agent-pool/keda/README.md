# RDA on Azure DevOps + KEDA-scaled AKS agents (AzurePowerShell@5)

This is the **end-to-end setup guide**: run Resource Discovery for Azure
(RDA) from an **Azure DevOps pipeline**, on **self-hosted Azure DevOps agents that
run as pods on AKS**, **scaled by KEDA** (0 → N) from the pool's pending-job queue
(`azure-pipelines` scaler). RDA runs as a pipeline job on an agent pod and
authenticates to Azure via an **ARM service connection** using the
**`AzurePowerShell@5`** task — the agent pod is just compute.

This mirrors a common restricted-enterprise setup (Red Hat base image, service
connection, `AzurePowerShell@5` / PowerShell 7, KEDA-scaled agents). The sibling
`../` VMSS elastic-pool setup is a simpler alternative if you don't need KEDA. The
pod-native Kubernetes-Job + workload-identity model (RDA runs *inside* pods under a
federated UAMI, no service connection) is a different route documented in
[`../../AKS-WorkloadIdentity-Setup.md`](../../AKS-WorkloadIdentity-Setup.md).

---

## Auth model (read this first — it is where the hard-to-see bugs live)

Three separate auth planes — don't conflate them:

| Plane | How it authenticates |
|-------|----------------------|
| KEDA controller reading the pool queue | PAT in `trigger-auth.yaml` (`personalAccessToken`) |
| Agent pod registering with the pool | PAT in the Secret (`AZP_URL` / `AZP_TOKEN`), via `start.sh` |
| **RDA step reading Azure** | **ARM service connection, through `AzurePowerShell@5`** |

Only the third plane reads Azure. Two things about it are non-negotiable:

- **Use `AzurePowerShell@5` (task version 5), with `pwsh: true` — NOT `AzureCLI@2`.**
  RDA reads its identity from the **Az PowerShell** context (`Get-AzContext`).
  `AzurePowerShell@5` establishes that context on the agent from the service
  connection; `AzureCLI@2` (or a plain `script:`/`pwsh:` step) only signs in the
  `az` CLI, leaving `Get-AzContext` **empty**. RDA then has no usable session and,
  on a headless agent, **fails fast with a clear error (exit 1)** instead of hanging
  on an interactive `Connect-AzAccount` prompt. `pwsh: true` selects PowerShell 7,
  which RDA requires (`#Requires -Version 7.0`).
- **Pass `-TenantID` equal to the service connection's tenant.** Otherwise the
  wrapper's gate re-authenticates.
- On a **self-hosted** agent the Az PowerShell modules must already be in the agent
  **image** — `AzurePowerShell@5` does not install them on a self-hosted agent (see
  the module list under [Files](#files)).

---

## The subscription-coverage requirement (the root cause of "missing subscriptions")

The service-connection identity must be able to **read every subscription you want
inventoried**. This is the single most common failure and the reason a run can
come back "missing subscriptions":

- RDA discovers subscriptions with `Get-AzSubscription`, which returns only the
  ones the identity holds a role on. A subscription the identity cannot read is
  **silently absent** — Azure Resource Graph returns 0 rows for it, not an error.
- To prevent that, `Run-AllSubscriptions.ps1` runs an **up-front access gate** and
  by **default HARD-STOPS (exit non-zero)** if any in-scope subscription is
  unreadable, or if it cannot confirm it is seeing *all* of them (the confirmation
  needs read on the **tenant-root management group**). It lists the offending
  subscriptions so you fix RBAC and re-run — rather than producing a report that is
  quietly incomplete.

**Fix:** grant the service-connection identity **Reader at the tenant-root
management group** (its `GroupId` = your tenant id). One assignment inherits Reader
to every current and future subscription **and** lets the gate confirm full
coverage. A per-subscription grant that misses some subs will hard-fail the gate
(by design). Add **Cost Management Reader** and **Monitoring Reader** at the same
scope if you run consumption/metrics.

| Role | Needed for | Omit if |
|------|-----------|---------|
| **Reader** (tenant-root MG) | inventory + coverage confirmation — always | never |
| **Cost Management Reader** | consumption / cost data | `-SkipConsumption` |
| **Monitoring Reader** | metrics (Azure Monitor) | `-SkipMetrics` |
| **Storage Blob Data Contributor** | uploading each run's zip to blob | not using blob upload |

> **Fail-loud actually fails the pipeline.** Under `AzurePowerShell@5` a called
> script's `exit N` does **not** by itself set the task's process exit code, so a
> hard-stop used to show the pipeline **green**. The pipeline step now re-raises a
> non-zero RDA exit as a terminating error, so a coverage/access hard-stop **fails
> the pipeline** and the operator must fix RBAC and re-run. (`allowPartialAccess`
> below is the conscious override.)

---

## Files

| File | Purpose |
|------|---------|
| `Dockerfile` | RHEL UBI 9 agent image + PowerShell 7 + `az` CLI + the Az submodules RDA needs: **Az.Accounts, Az.Compute, Az.Monitor, Az.Billing, Az.ResourceGraph, Az.Storage**. `Az.Storage` is required for blob upload; all are baked in because `AzurePowerShell@5` does not install modules on a self-hosted agent. |
| `start.sh` | Registers the agent and runs one job (`--once`), then de-registers. |
| `agent-scaledjob.yaml` | KEDA `ScaledJob` — one agent pod per queued job. |
| `trigger-auth.yaml` | Secret (AZP_URL/PAT) + `TriggerAuthentication` for the scaler. |
| `pipeline.yml` | The pipeline RDA runs from. Parameterized (see below); default is a single-agent, fail-loud, no-upload run. |

---

## Steps

### 1. Cluster with KEDA + an ACR (Azure sandbox — costs money while running)

```bash
RG=rda-keda-repro-rg
LOC=eastus
ACR=<globally-unique-name>
CLUSTER=rda-keda-aks

az group create -n "$RG" -l "$LOC"
az acr create -g "$RG" -n "$ACR" --sku Basic
az aks create -g "$RG" -n "$CLUSTER" --node-count 2 --node-vm-size Standard_D2s_v5 \
  --enable-keda --attach-acr "$ACR" --tier free --generate-ssh-keys
az aks get-credentials -g "$RG" -n "$CLUSTER"
kubectl create namespace ado
```

### 2. Create the self-hosted ADO pool + a PAT

- Azure DevOps → **Organization settings → Agent pools → Add pool → Self-hosted**,
  name it **`keda-pool`**, tick "Grant access permissions to all pipelines".
- Create a **PAT** with **Agent Pools (Read & manage)**.
- Get the numeric **poolID**:
  ```bash
  az pipelines pool list --organization https://dev.azure.com/<org> \
    --pool-name keda-pool --query "[0].id" -o tsv
  ```

### 3. Build the agent image (includes Az.Storage)

```bash
az acr build --registry "$ACR" --image azp-agent:latest \
  --file deploy/agent-pool/keda/Dockerfile deploy/agent-pool/keda
```

The ScaledJob uses `imagePullPolicy: Always`, so re-running this and re-queuing
picks up a new image. (If you rebuild to add a module, allow a moment for the tag
to settle before queuing, or a freshly-scheduled pod can race the old digest.)

### 4. Create the ARM service connection + grant it coverage

- Azure DevOps → **Project settings → Service connections → New → Azure Resource
  Manager** → prefer **workload identity federation** (no stored secret). Note its
  name — it is the `serviceConnection` value in `pipeline.yml`.
- Grant the service connection's identity **Reader at the tenant-root management
  group** (see [the coverage requirement](#the-subscription-coverage-requirement-the-root-cause-of-missing-subscriptions)),
  plus **Cost Management Reader** / **Monitoring Reader** if you run consumption /
  metrics, and **Storage Blob Data Contributor** on the storage account if you use
  blob upload (step 7).

### 5. Deploy the scaler

- Edit `trigger-auth.yaml` — set `AZP_URL`, `AZP_TOKEN`, `personalAccessToken`
  (do **not** commit real values).
- Edit `agent-scaledjob.yaml` — set `<acr>` and `poolID`.

```bash
kubectl apply -f deploy/agent-pool/keda/trigger-auth.yaml
kubectl apply -f deploy/agent-pool/keda/agent-scaledjob.yaml
```

### 6. Create the pipeline and run RDA

Create a pipeline from `deploy/agent-pool/keda/pipeline.yml` (its `pool.name` is
`keda-pool` and `serviceConnection` is your ARM connection). Queue it, supplying
the parameters at queue time. KEDA sees the pending job, spawns an agent pod, RDA
runs under `AzurePowerShell@5`, the pod exits, and KEDA scales back to zero.

**Queue-time parameters** (all optional except `tenantId`; defaults give a
single-agent, fail-loud, no-upload run):

| Parameter | Default | Meaning |
|-----------|---------|---------|
| `tenantId` | `''` | Tenant id (= tenant-root MG id). Must equal the service connection's tenant. **Set this.** |
| `parallelStreams` | `0` | Concurrency **within one agent**. `0` = RDA auto-tunes from the agent's CPU/RAM (`Get-RecommendedParallelism`); set a positive number to force it. |
| `shardCount` | `1` | Number of **parallel agents** to fan out across (see [Sharding](#sharding-across-multiple-agents)). `1` = a single agent covers the whole tenant. Each agent's shard **index is assigned automatically** — you do not set it. |
| `uploadContainerUri` | `''` | Blob container URL to upload this run's zip to (see [Blob upload](#centralized-blob-upload)). Empty = keep the zip on the agent as a pipeline artifact only. |
| `allowPartialAccess` | `false` | `true` consciously downgrades the coverage hard-stop to a warning (for an environment that genuinely cannot read the tenant-root MG). Leave `false` for real runs. |
| `collectMetrics` | `true` | Collect resource metrics. `false` = `-SkipMetrics` (inventory only). Requires **Monitoring Reader** on the scope. |
| `collectConsumption` | `true` | Collect consumption/billing data. `false` = `-SkipConsumption`. Requires **Cost Management Reader**; access is gated up front (a hard authorization denial fails the run). |
| `useMetricsBatch` | `true` | Use the Azure Monitor `metrics:getBatch` data-plane API (one REST call per ≤50 resources instead of one `Get-AzMetric` per resource-per-metric). **Recommended at scale**; falls back to the per-call path on any batch failure (no data lost). |
| `headRoom` | `0` | Leave this **percentage** of metrics concurrency in reserve so RDA competes less with the tenant's production workloads. `0` = full concurrency; **~20 is a good starting point on a live production tenant**. |

The step builds these into a splatted argument set for `Run-AllSubscriptions.ps1`.
The report is always obfuscated. **Metrics and consumption are collected by
default** (`collectMetrics`/`collectConsumption` = `true`) with `useMetricsBatch`
on — so grant the matching roles from step 4 (Monitoring Reader, Cost Management
Reader). Set either `collect*` to `false` for an inventory-only run.

### 7. Centralized blob upload

Set `uploadContainerUri` to a container URL
(`https://<account>.blob.core.windows.net/<container>[/<prefix>]`). After the run,
the agent uploads its finalized report zip there — passwordless, via the service
connection identity (so it needs **Storage Blob Data Contributor** on the account/
container), and via the **Az.Storage** module baked into the agent image. The blob
name is made unique per shard (`shard-<i>of<N>-<zip>`), and the run's support-log
bundle (`RdaSupportLogs_*.zip`) is uploaded alongside it.

A malformed URL or a missing `Az.Storage` module **fails the run up front**; a
transient/RBAC failure during the upload itself is **best-effort** — the run still
succeeds and the zip stays on the agent (as a published pipeline artifact) with a
warning.

One-time storage prep (in the tenant you are inventorying, or any account the
service connection can reach):

```bash
az storage account create -g "$RG" -n <account> -l "$LOC" --sku Standard_LRS \
  --min-tls-version TLS1_2 --allow-blob-public-access false
az storage container create --account-name <account> --name reports --auth-mode login
# Grant the service-connection identity data-plane write:
az role assignment create --assignee-object-id <sc-identity-objectId> \
  --assignee-principal-type ServicePrincipal --role "Storage Blob Data Contributor" \
  --scope $(az storage account show -g "$RG" -n <account> --query id -o tsv)
```

### 8. Sharding across multiple agents

`shardCount > 1` splits the tenant's subscriptions across N agents by a
deterministic per-subscription-id hash, so the shards are disjoint and together
cover every subscription exactly once.

**You do NOT assign shard indices yourself, and you do NOT queue the pipeline N
times.** Queue the pipeline **once** with `shardCount = N`. The job uses a
`strategy: parallel: N`, so Azure DevOps fans that one run out into N parallel
jobs and injects `System.JobPositionInPhase` (1…N) into each. Every agent derives
its own 0-based `ShardIndex` from that variable (`ShardIndex = JobPositionInPhase
- 1`) and passes it to `Run-AllSubscriptions.ps1`. KEDA sees N pending jobs in the
pool and spawns N agent pods — one per shard. This is the ADO analogue of a
Kubernetes `completionMode: Indexed` Job's `JOB_COMPLETION_INDEX`.

> **Sizing `shardCount`.** Pick it from tenant size (rule of thumb: a few hundred
> subscriptions per agent finishes comfortably). Optionally run
> `./Run-AllSubscriptions.ps1 -TenantID <t> -Plan` once (locally or as a one-off
> `AzurePowerShell@5` step) — it counts eligible subscriptions and prints a
> recommended shard count, then exits without inventorying. It is guidance only;
> you never have to run it.

Each shard produces its **own** `AllSubscriptions_ResourcesReport_*.zip` covering
only its slice — uploaded as `shard-<i>of<N>-…` when `uploadContainerUri` is set,
and published as the per-shard pipeline artifact `rda-reports-shard<n>`. Ingest the
N zips separately — no merge needed — or rebuild one aggregate `MainSummary.html`
per [`../../../docs/horizontal-sharding.md`](../../../docs/horizontal-sharding.md)
("Collecting the results").

> **Fail-loud shard guard.** If `shardCount > 1` but the parallel strategy did not
> inject a valid distinct index, the step throws rather than letting every agent
> silently run shard 0 and drop the other slices (mirrors the k8s entrypoint's
> `JOB_COMPLETION_INDEX` guard). Make sure the AKS node pool / ScaledJob has room
> for N pods, or KEDA will queue them and the run waits.

### 9. Teardown

```bash
az group delete -n rda-keda-repro-rg --yes --no-wait
```

Then delete the `keda-pool` agent pool and revoke the PATs.

---

## Notes / gotchas

- **`parallelStreams` and RAM.** Each stream is a separate pwsh process (~0.7–1 GB
  resident at metrics-phase peak). The ScaledJob requests 1Gi / limits 2Gi — raise
  for large tenants or the pod risks OOMKill. `0` (auto-tune) picks a safe stream
  count for the pod's CPU/RAM; on a 2-vCPU agent that is typically 1.
- **One shard per node (guaranteed).** `agent-scaledjob.yaml` carries a
  `podAntiAffinity` (topologyKey `kubernetes.io/hostname`) so no two shard agent
  pods share a node — each memory-hungry RDA run gets its own hardware. It ships as
  a **hard** `required` rule on purpose: a *soft* `preferred` spread does NOT
  guarantee it (verified — when N shard pods are queued together they are scheduled
  before any is Running, so none sees the others and they can all land on one node).
  The trade-off: `required` needs **at least as many schedulable nodes as shards**,
  or surplus shard pods sit **Pending** until a node frees/scales. Enable the
  **cluster autoscaler** so nodes scale up to the fan-out
  (`az aks nodepool update -g <rg> --cluster-name <aks> -n <pool>
  --enable-cluster-autoscaler --min-count 1 --max-count <maxShardCount>`). If you'd
  rather never wait on capacity and accept possible co-location, switch to the
  `preferred` block noted in the manifest.
- **Fail-loud on missing coverage.** A run that stops with "N subscription(s) are
  NOT readable" or "could not verify full subscription coverage" means the service
  connection lacks Reader on some subscriptions (or on the tenant-root MG). Grant it
  and re-run; the pipeline correctly goes **red** until then. Use
  `allowPartialAccess: true` only for a conscious partial run.
- **No secrets in tracked files.** No real PAT, subscription/tenant IDs, org names,
  storage account names, or other real identifiers belong in any file here —
  `tenantId` and `uploadContainerUri` are supplied at queue time; the PATs live in
  Kubernetes Secrets you edit locally and never commit.
