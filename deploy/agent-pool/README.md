# RDA repro: self-hosted RHEL agent on an Azure DevOps VMSS pool

This folder stands up a **representative** Azure DevOps environment to reproduce
RDA running **directly on a self-hosted Red Hat (RHEL 9) agent** from a
VMSS-backed agent pool, authenticated by an ARM service connection. It is the
**agent-direct** path (see [`../AZURE-DEVOPS-PIPELINE.md`](../AZURE-DEVOPS-PIPELINE.md)),
used to observe/fix how `Run-AllSubscriptions.ps1` behaves under a pre-authed,
non-interactive pipeline session — not the pod-native AKS route (that's `../AKS-WorkloadIdentity-Setup.md`). For the KEDA-scaled ADO-agent-on-AKS route, see [`keda/README.md`](keda/README.md).

## Files

| File | Purpose |
|------|---------|
| `provision-vmss.sh` | Creates the RHEL 9 VMSS in your Azure sandbox, wired for an ADO elastic pool. |
| `cloud-init.yaml` | Per-node install of PowerShell 7 + Az submodules + az CLI (RHEL 9). |
| `azure-pipelines.yml` | The `AzurePowerShell@5` agent-direct run of `Run-AllSubscriptions.ps1`. |

## Why RHEL 9

Enterprises commonly run Red Hat, so this defaults to first-party **RHEL 9**
(`RedHat:RHEL:9-lvm-gen2:latest`, PAYG). CentOS Linux is EOL — avoid it. For a
free RHEL-compatible clone, swap `IMAGE` in `provision-vmss.sh` to a Rocky/Alma 9
Marketplace offer (publishers `resf` / `procomputers` / `perforce`); those need
`az vm image terms accept` first.

## Steps

### 1. Create the VMSS (Azure sandbox — costs money while running)

```bash
cd deploy/agent-pool
./provision-vmss.sh rda-ado-repro-rg eastus rda-rhel-vmss Standard_D2s_v5 2
```

Keep the size/count small; RHEL adds a PAYG license charge on top of compute.

### 2. Register it as an ADO agent pool

Azure DevOps → **Project settings → Agent pools → Add pool →
Azure virtual machine scale set** → select the VMSS created above → name it
**`rda-rhel-vmss`** (must match `pool.name` in `azure-pipelines.yml`).
Leave ADO to manage scaling — do **not** add Azure autoscale rules to the VMSS.

### 3. Create the ARM service connection

Azure DevOps → **Project settings → Service connections → New → Azure Resource
Manager** → prefer **workload identity federation** (no stored secret). Name it
**`rda-arm`** (must match `serviceConnection` in `azure-pipelines.yml`). Grant its
identity **Reader at the tenant-root management group** (see `../AKS-WorkloadIdentity-Setup.md`
§2 for why MG-root, not per-subscription), plus Cost Management Reader /
Monitoring Reader if you exercise consumption / metrics.

### 4. Run

Create a pipeline from `deploy/agent-pool/azure-pipelines.yml`, set `TENANT_ID`
to the service connection's tenant, and run it manually. Expected: the diagnostic
step shows PS7 + Az present, and the run prints
`Existing session detected ... skipping interactive login` (no interactive prompt).

### 5. Teardown

```bash
az group delete -n rda-ado-repro-rg --yes --no-wait
```

Then remove the ADO agent pool and (optionally) the service connection. Remove any
management-group-scoped role assignment separately if you added one.

## Notes

- **`-ParallelStreams 1`** is set in the pipeline on purpose: it forces the
  sequential path and avoids the `Save-AzContext`/`Import-AzContext` fork, whose
  token-refresh behavior under a federated service connection is unverified. Drop
  it (or raise it) once that path is validated on this pool.
- **`AzurePowerShell@5` needs Az already installed** on self-hosted agents — that's
  what `cloud-init.yaml` guarantees. `AzureCLI@2` would only pre-auth the az CLI,
  leaving `Get-AzContext` empty and sending the wrapper's gate into an interactive
  `Connect-AzAccount` hang.
- No real subscription/tenant IDs, org or account names, or secrets belong in any
  file here — use the documentation placeholder GUID and generic names only.
