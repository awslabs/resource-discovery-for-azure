# Azure Resource Discovery Tool

## Overview

The Azure Resource Discovery Tool is a PowerShell script that generates comprehensive inventory reports of your Azure environment. This AWS-provided script creates detailed reports including resource metrics, usage statistics, and performance data from the previous 31 days.

This tool leverages read-only integrations with Azure APIs and Azure Monitor. Our goal is to deliver a reliable and efficient solution for Azure environment reporting, empowering you with comprehensive insights into your cloud resources and their utilization.

**Key Features:**
- Read-only Azure API integration
- Automated Excel and JSON report generation
- 31-day historical metrics collection
- Parallel processing for improved performance
- Support for [Azure Cloud Shell](https://shell.azure.com "Open Azure Cloud Shell") and local PowerShell environments

## Quick Start

For most users, this is everything you need.

**1. Open Azure Cloud Shell** at [shell.azure.com](https://shell.azure.com), or run a local PowerShell 7 prompt with the [prerequisites](#prerequisites) installed.

**2. Download the script:**

```powershell
git clone https://github.com/awslabs/resource-discovery-for-azure.git
cd resource-discovery-for-azure
```

**3. Run it:**

```powershell
./Run-AllSubscriptions.ps1 -TenantID "contoso.onmicrosoft.com" -Obfuscate -ParallelStreams 2
```

This:
- Inventories every enabled subscription in the tenant.
- Obfuscates resource IDs, names, and other identifying details so the report is safe to share.
- Runs 2 subscriptions at a time (works in both Cloud Shell and on a typical laptop).

The script tracks progress automatically as it goes. If anything interrupts the run (network drop, Cloud Shell session timeout, accidental Ctrl+C), re-run the same command with `-Resume` added and it will skip the subscriptions that already finished and pick up the rest:

```powershell
./Run-AllSubscriptions.ps1 -TenantID "contoso.onmicrosoft.com" -Obfuscate -ParallelStreams 2 -Resume
```

You'll find the consolidated report at `InventoryReports/AllSubscriptions_ResourcesReport_<timestamp>.zip`. Send that ZIP to the AWS team.

For larger tenants (100+ subscriptions), see [Choosing where to run](#choosing-where-to-run-for-large-tenants-cloud-shell-vs-local) for sizing guidance. For all available options, see the [Run-AllSubscriptions Wrapper Parameters](#run-allsubscriptions-wrapper-parameters).

## Table of Contents

- [Quick Start](#quick-start)
- [Prerequisites](#prerequisites)
- [Getting Started](#getting-started)
- [Usage](#usage)
- [Output Files](#output-files)
- [Parameters Reference](#parameters-reference)
- [Troubleshooting](#troubleshooting)

## Prerequisites

### Required Azure Roles

Before running the script, ensure your Azure user account has the following roles assigned:

- **✅ Reader Role** - Access to view Azure resources
- **✅ Billing Reader Role** - Access to billing and cost data
- **✅ Monitoring Reader Role** - Access to Azure Monitor metrics
- **✅ Cost Management Reader Role** - Access to cost management data

### Environment Options

The script runs in either Azure Cloud Shell or a local PowerShell 7 install. Pick based on the size of the tenant you're inventorying:

| Tenant size | Use | Why |
|---|---|---|
| Up to ~30 subscriptions | **Cloud Shell** | Fastest to start. No setup, pre-authenticated, all dependencies included. |
| 30–100+ subscriptions | **Either**, with `-ParallelStreams 2 -Resume` on Cloud Shell | Cloud Shell still works, but session timeouts and the 3.5 GB RAM cap start to matter. `-Resume` lets a timed-out session pick up where it left off. |
| 100+ subscriptions, or metric-heavy tenants | **Local PowerShell 7** | Cloud Shell caps at `-ParallelStreams 2` (only 3.5 GB RAM / 2 vCPU). A local 16 GB / 8-core machine runs at `-ParallelStreams 6`, about 3× faster. Microsoft also warns that long-running parallel work in Cloud Shell can trigger anti-abuse blocking. See [Choosing where to run](#choosing-where-to-run-for-large-tenants-cloud-shell-vs-local) below for the full details. |

#### Option 1: Azure Cloud Shell

- Browser-based, no setup
- Pre-authenticated to your Azure tenant
- `Az` and `ImportExcel` modules pre-installed by Microsoft
- Access at [Azure Cloud Shell](https://shell.azure.com "Open Azure Cloud Shell")
- Sessions are ephemeral by default. Mount a storage account (Cloud Shell Settings > Reset User Settings > Mount storage account) if you need outputs to persist across sessions or want to use `-Resume` on a follow-up session.

#### Option 2: Local Environment
- [PowerShell 7 or later](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell)
- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli)
- [Azure CLI Account Extension](https://learn.microsoft.com/en-us/cli/azure/azure-cli-extensions-overview)
- Azure CLI Resource-Graph Extension (auto-installed by script)
- **Az PowerShell module** and **ImportExcel module** (install before running — see below)

> **Note:** Install the Account Extension before running the script:
> ```powershell
> az extension add --name account
> ```

##### Installing the required PowerShell modules

> **Cloud Shell users:** Both `Az` and `ImportExcel` are pre-installed by Microsoft. Skip this section entirely.

The script needs both `Az` and `ImportExcel` modules. Install them once before the first run from a **PowerShell 7** prompt (`pwsh`). Use `-Scope CurrentUser` so no administrator elevation is needed:

```powershell
Install-Module -Name Az -Repository PSGallery -Force -AllowClobber -SkipPublisherCheck -Scope CurrentUser
Install-Module -Name ImportExcel -Repository PSGallery -Force -AllowClobber -SkipPublisherCheck -Scope CurrentUser
```

The script no longer installs these modules for you while it runs. Doing the install inside a script that's already loading the same module is unreliable. You can end up with a half-installed module that looks fine to PowerShell but fails much later in the run with confusing errors like "no consumption records" or "Cannot find type [OfficeOpenXml.ExcelPackage]". Installing the modules once, by hand, before the first run avoids the whole class of problem.

If a previous run left a broken `Az` install behind, remove it and reinstall:

```powershell
Get-Module Az* -ListAvailable | Uninstall-Module -Force
Install-Module -Name Az -Repository PSGallery -Force -AllowClobber -SkipPublisherCheck -Scope CurrentUser
```
  


## Getting Started

### Step 1: Access Your Environment

**For Azure Cloud Shell:**
1. Navigate to [Azure Cloud Shell](https://shell.azure.com "Open Azure Cloud Shell")
2. Ensure you're in PowerShell mode (not Bash)
3. You're automatically authenticated

![CloudShell](./docs/cloudshell.png)

**For Local Environment:**
1. Open PowerShell 7 as Administrator
2. Ensure Azure CLI is installed and configured

### Step 2: Download the Script

**Option A: Git Clone**
```bash
git clone https://github.com/awslabs/resource-discovery-for-azure.git
```

**Option B: Direct Download**
1. Click the green **Code** button on this repository
2. Select **Download ZIP**
3. Extract to your desired directory

![Zip](./docs/zip_download.png)

## Usage

### Authentication Notes

- **Azure Cloud Shell:** Authentication is automatic
- **Local PowerShell:** Run `az login` and `Connect-AzAccount` before executing the script. If you plan to scan all subscriptions in a tenant, use `Run-AllSubscriptions.ps1`, which prompts you to sign in once and then reuses the session for every subscription.

You might get more than one authentication request due to different collector processes running in parallel.

### Basic Execution

1. **Navigate to the script directory:**
   ```powershell
   cd resource-discovery-for-azure
   ```

2. **Run the script with your organization name:**
   ```powershell
   ./ResourceInventory.ps1 -ReportName "YourCompanyName" -ConcurrencyLimit 6
   ```

### Advanced Usage Examples

**Scan specific subscription:**
```powershell
./ResourceInventory.ps1 -ReportName "CompanyName" -SubscriptionID "12345678-1234-1234-1234-123456789012"
```

**Scan specific resource group:**
```powershell
./ResourceInventory.ps1 -ReportName "CompanyName" -ResourceGroup "MyResourceGroup"
```

**Adjust performance settings:**
```powershell
./ResourceInventory.ps1 -ReportName "CompanyName" -ConcurrencyLimit 8
```

**Skip consumption:**
```powershell
./ResourceInventory.ps1 -ReportName "CompanyName" -SkipConsumption
```

**Skip metrics:**
```powershell
./ResourceInventory.ps1 -ReportName "CompanyName" -SkipMetrics
```

**Generate obfuscated report (mask sensitive data before sharing):**
```powershell
./ResourceInventory.ps1 -ReportName "CompanyName" -Obfuscate
```

### Running Across All Subscriptions

Use `Run-AllSubscriptions.ps1` to generate a separate inventory report for each subscription in a tenant, instead of the default single consolidated report. The wrapper prompts you to sign in once, then invokes `ResourceInventory.ps1` for each subscription. By default subscriptions are processed sequentially (one at a time); use `-ParallelStreams` to process several concurrently.

```powershell
./Run-AllSubscriptions.ps1 -TenantID "12345678-1234-1234-1234-123456789012"
```

`-TenantID` accepts either a tenant GUID or a verified domain. When a domain is passed (for example `contoso.onmicrosoft.com`), the wrapper resolves it to the GUID via Microsoft's anonymous OIDC discovery endpoint before doing anything else, so this also works:

```powershell
./Run-AllSubscriptions.ps1 -TenantID "contoso.onmicrosoft.com"
```

Each subscription produces its own set of timestamped reports in `InventoryReports/`. After all subscriptions are processed, the wrapper bundles the per-subscription ZIPs into a single `AllSubscriptions_ResourcesReport_<timestamp>.zip` in the same folder for easy delivery.

#### Subscription state filter

By default, `Run-AllSubscriptions.ps1` only inventories subscriptions whose `State` is `Enabled`. Subscriptions in any other state (`Disabled`, `Warned`, `PastDue`, `Deleted`) are skipped because they return little or no data from Resource Graph and most ARM data-plane calls, so processing them produces near-empty reports while still costing wall-clock time.

To include every subscription regardless of state, pass `-IncludeDisabled`:

```powershell
./Run-AllSubscriptions.ps1 -TenantID "12345678-1234-1234-1234-123456789012" -IncludeDisabled
```

The wrapper prints the count of excluded subscriptions and a per-state breakdown so the filter is transparent.

#### Resuming an interrupted run

For tenants with many subscriptions, the run can be cut short by environment-level limits — for example, an Azure Cloud Shell session that ends when a Conditional Access policy enforces a maximum session lifetime. The wrapper supports resuming:

```powershell
./Run-AllSubscriptions.ps1 -TenantID "12345678-1234-1234-1234-123456789012" -Resume
```

After each subscription is fully processed (its per-subscription ZIP has been written), the wrapper records the subscription ID in a state file at `InventoryReports/.resume-state-<TenantID>.json`. Re-running with `-Resume` reads that file and skips subscriptions that are already complete; the partially processed subscription (the one that was running when the session ended) is re-run from the start. The state file is cleared automatically after a clean run with no failures.

`-Resume` is opt-in. Without it, the wrapper processes every subscription returned by `Get-AzSubscription`, and existing state is left untouched.

#### Parallel subscription processing

For large tenants, the slowest part of the run is collecting metrics. Each call to Azure Monitor takes 200–500 ms over the network, and a typical subscription with VMs, SQL DBs, and storage accounts produces thousands of these calls. Done one subscription at a time, that adds up to many hours.

Pass `-ParallelStreams N` to process N subscriptions concurrently in separate `pwsh` background processes:

```powershell
./Run-AllSubscriptions.ps1 -TenantID "12345678-1234-1234-1234-123456789012" -ParallelStreams 6
```

Each stream is a separate background process. They don't share state with each other. Each has its own Azure session, its own progress tracking file, and its own output folder. The wrapper splits your subscription list across the streams in round-robin order so the workload stays balanced even when subscriptions vary in size.

The default is `-ParallelStreams 1` (existing sequential behavior, fully preserved). Pick a higher value based on the environment you're running in. See the table in [Choosing where to run for large tenants](#choosing-where-to-run-for-large-tenants-cloud-shell-vs-local) below.

`-ParallelStreams` and `-ConcurrencyLimit` compose. `-ConcurrencyLimit` throttles the metrics-collection runspace pool *within* one subscription; `-ParallelStreams` is the count of subscriptions running concurrently. Useful combinations:

| ParallelStreams | ConcurrencyLimit | Concurrent ARM calls (in flight at once) | Verdict |
|---|---|---|---|
| 1 | 6 | 6 | Existing default. |
| 6 | 6 | 36 | Recommended for metric-heavy estates on a 16 GB / 8-core local machine. |
| 8 | 6 | 48 | Watch for HTTP 429s in per-stream logs. |
| 6 | 12 | 72 | Aggressive. Expect retry-backoff to eat the gain. |

When you run with `-ParallelStreams`, several things change in the output:

- Every line in the transcript starts with `[stream-N]` so you can tell which subscription's stream produced it.
- Each stream writes its own failure log to `InventoryReports/RunAllSubscriptions_failures_<timestamp>_stream-<N>.log`. At the end of the run, the wrapper merges those into a single combined failure log so you only have one file to read.
- Each stream tracks its own progress in a separate resume-state file. When the run finishes, those are merged into the main resume-state file. This means `-Resume` works the same way regardless of whether the previous run was sequential or parallel, so you don't need to remember which mode you used.

Authentication only happens once. The wrapper saves the parent process's Az PowerShell context to a file and each stream loads it, so you don't get prompted to sign in again for each parallel worker. The wrapper deletes that snapshot file when the run ends, including if you cancel with Ctrl+C or a stream crashes during startup.

#### Choosing where to run for large tenants: Cloud Shell vs local

Three things constrain how many parallel streams you can usefully run:

- **Azure Resource Manager (ARM) request quota.** ARM is Azure's control-plane API that the script calls to read resource details and metrics. Each subscription is rate-limited to roughly 12,000 read requests per hour. The script's `-ConcurrencyLimit` and `-ParallelStreams` together control how many ARM requests are in flight at once. Stay under about 50 concurrent requests per tenant, or you'll start seeing HTTP 429 ("Too Many Requests") in the per-stream logs and the script will spend more time backing off than working.
- **CPU cores.** The script is mostly waiting on network responses, not crunching numbers, so it doesn't need many cores. Roughly one core per stream is plenty. Running more streams than cores doesn't make the script faster, the CPU just spends time switching between tasks.
- **RAM.** Each stream loads the Azure PowerShell modules and holds resource and metric data in memory before writing the output files. Plan for around 500-700 MB peak per stream. Running more streams than your RAM can hold makes the OS swap to disk and slows everything down.

For small to medium tenants (up to a few dozen subscriptions), Cloud Shell is the easiest place to run. For large tenants the resource ceilings on Cloud Shell start to matter.

Verified Cloud Shell limits (measured 2026-05; Microsoft can change these silently):

| Resource | Cloud Shell | Notes |
|---|---|---|
| RAM | ~3.5 GB total, ~2.7 GB usable at idle | Each `pwsh` worker peaks at ~500–700 MB during the metrics phase |
| CPU | 2 vCPUs (Intel Xeon Platinum @ 2.8 GHz) | Shared, so effective throughput is lower under load |
| Storage | ~50 GB overlay filesystem | Ephemeral by default. See below. |
| Idle timeout | 20 minutes | Sessions are terminated without warning when this elapses |
| Concurrent sessions per tenant | 20 | Tenant-wide cap |
| Sudo / elevation | Not available | Module installs must use `-Scope CurrentUser` |

References: [Cloud Shell features](https://learn.microsoft.com/en-us/azure/cloud-shell/features), [Cloud Shell FAQ](https://learn.microsoft.com/en-us/azure/cloud-shell/faq-troubleshooting).

Recommended `-ParallelStreams` per environment:

| Environment | Recommended | Why |
|---|---|---|
| Cloud Shell (ephemeral or with mounted storage) | **2** | Saturates both vCPUs without OOM-killing workers on the 3.5 GB RAM cap |
| Local PowerShell 7, 8 GB RAM | **2** | RAM is the bottleneck |
| Local PowerShell 7, 16 GB RAM, 8+ cores | **6** | Recommended for metric-heavy estates |
| Local PowerShell 7, 32 GB RAM, 12+ cores | **8** | Watch HTTP 429s in per-stream logs. |

**Persistence in Cloud Shell:** Cloud Shell sessions are ephemeral by default. When your session ends, anything in your home directory is deleted, including the script's output and the resume-state file. The wrapper detects this at startup and warns you. To keep outputs across sessions (and to make `-Resume` work after a session times out), attach a storage account: in Cloud Shell, click Settings (the gear icon) > Reset User Settings > Mount storage account.

**Cloud Shell anti-abuse limits:** Microsoft warns that Cloud Shell is "not a general purpose computing platform" and that excessive usage can result in your tenant being blocked from Cloud Shell ([source](https://learn.microsoft.com/en-us/azure/cloud-shell/faq-troubleshooting#terminal-output---sorry-your-cloud-shell-failed-to-provision-codetenantdisabled-)). Long parallel runs against large tenants can trigger this. If you're running RDA across many subscriptions for a few hours at a time, use a local PowerShell 7 install instead. It avoids the risk and is usually faster anyway.

#### Run transcript and failure diagnostics

Every time you run `Run-AllSubscriptions.ps1`, it writes a transcript of the whole run to `InventoryReports/RunAllSubscriptions_transcript_<timestamp>.txt`. This is different from the per-subscription transcripts that the inner script `ResourceInventory.ps1` writes inside each subscription folder. The wrapper transcript covers the run end-to-end: which tenant was resolved, how authentication was handled, any resume-state messages, which subscription is being processed at each step, the final consolidation, and the run summary. You get this file every run, whether you process one subscription or many.

If a subscription fails, the wrapper also writes a structured failure log to `InventoryReports/RunAllSubscriptions_failures_<timestamp>.log`. This file captures the full exception type, the error message, up to five levels of inner exceptions, the script line number, the stack trace, and a snapshot of how much memory and free disk space the machine had when the failure happened. The final summary points at both files when failures occur.

When reporting an issue, attach both files. They contain enough context to diagnose most failures without a follow-up round trip.

## Output Files

Upon completion, the script generates reports in the `InventoryReports` folder:

### Generated Files

| File | Description |
|------|-------------|
| `Consumption_ResourcesReport_(date).csv` | Cost and billing data |
| `Inventory_ResourcesReport_(date).json` | Complete resource inventory |
| `Metrics_ResourcesReport_(date).json` | Performance metrics data |
| `ResourcesReport_(date).xlsx` | Consolidated Excel report |
| `Transcript_Log_<ReportName>_(date).txt` | Plaintext transcript of script activity (excluded from the zip when `-Obfuscate` is used) |
| `ResourcesReport_(date).zip` | All files compressed |

### File Delivery

1. **Locate the output:** Check the `InventoryReports` folder
2. **Rename the ZIP file:** Include your company name (e.g., `CompanyName_ResourcesReport_2024-01-15.zip`)
3. **Deliver to AWS team:** Send the renamed ZIP file for analysis

### Obfuscation Mode

When using `-Obfuscate`, the following data is masked in all output files:

| Category | What is masked | Masked Format |
|----------|---------------|---------------|
| Resource ID | All resource IDs across inventory, metrics, and consumption | `prod_<guid>` or `nonprod_<guid>` |
| Resource Name | All resource names | `prod_<guid>` or `nonprod_<guid>` |
| Subscription | Subscription names (deterministic — same real sub always maps to the same value) | `prod_<guid>` or `nonprod_<guid>` |
| Resource Group | Resource group names (deterministic — same real RG always maps to the same value) | `prod_<guid>` or `nonprod_<guid>` |
| Tags | All resource tags stripped | `null` |
| Cross-references | Fields that reference other resources by name or ID (e.g. DatabaseServer, ManagedInstance, HostId, StorageAccount, KeyVault, WAF policy) | Dictionary lookup or `obfuscated` |
| Consumption IDs | ReservationId and ReservationOrderId in billing data | `obfuscated` |
| User identity | Fields containing user emails or identity (e.g. Purview CreatedBy) | `obfuscated` |

Resources with names matching dev/test/qa patterns (including short prefixes like `d-`, `t-`, `s-`) get a `nonprod_` prefix; all others get `prod_`. This preserves environment classification without exposing real names.

**Deterministic mapping:** The same real subscription or resource group always maps to the same obfuscated value within a run. This means pivot tables, grouping, and cross-referencing all work correctly in the obfuscated output.

**Reverse-lookup dictionary:** A local `ObfuscationDictionary_*.json` file maps every obfuscated value back to the real resource. This file stays with the customer and is never included in the ZIP. When the receiving party asks about a specific obfuscated name, the customer looks it up in the dictionary and responds.

**What is preserved:** Location, SKU, VM size, OS type, disk type, metrics values, consumption quantities, and all technical configuration data needed for analysis.

**What is excluded from the ZIP:**
- Transcript log (contains raw console output with emails, subscription IDs, file paths)
- Obfuscation dictionary (contains the real-to-obfuscated mapping)

### Manual Compression (If Needed)

If automatic compression fails:
```powershell
cd InventoryReports
Compress-Archive -Path ./* -DestinationPath "CompanyName_ResourcesReport_$(Get-Date -Format 'yyyy-MM-dd').zip"
```
## Parameters Reference

### Core Parameters

| Parameter | Type | Description | Example |
|-----------|------|-------------|----------|
| `ReportName` | String | **Required.** Company/customer name for file naming | `-ReportName "AcmeCorp"` |
| `TenantID` | String | Target specific Azure tenant | `-TenantID "12345678-1234-1234-1234-123456789012"` |
| `SubscriptionID` | String | Scan single subscription only | `-SubscriptionID "87654321-4321-4321-4321-210987654321"` |
| `ResourceGroup` | String | Scan specific resource group only | `-ResourceGroup "Production-RG"` |

### Performance Parameters

| Parameter | Type | Description | Default | Example |
|-----------|------|-------------|---------|----------|
| `ConcurrencyLimit` | Integer | Parallel execution limit | 6 | `-ConcurrencyLimit 8` |
| `SkipConsumption` | Switch | Skip cost/billing data collection | False | `-SkipConsumption` |
| `SkipMetrics` | Switch | Skip Azure Monitor metrics collection | False | `-SkipMetrics` |

### Privacy & Obfuscation Parameters

| Parameter | Type | Description | Example |
|-----------|------|-------------|----------|
| `Obfuscate` | Switch | Replace resource IDs, names, subscriptions, resource groups, and tags with masked values. A reverse-lookup dictionary is saved locally. Reports can be safely shared externally without exposing sensitive Azure environment details. | `-Obfuscate` |

### Authentication Parameters

| Parameter | Type | Description | Example |
|-----------|------|-------------|----------|
| `Appid` | String | Service Principal application ID | `-Appid "app-id-here"` |
| `Secret` | String | Service Principal client secret | `-Secret "secret-here"` |
| `DeviceLogin` | Switch | Use device code authentication | `-DeviceLogin` |

### Debugging Parameters

| Parameter | Type | Description | Example |
|-----------|------|-------------|----------|
| `Debug` | Switch | Enable debug mode output | `-Debug` |

### Run-AllSubscriptions Wrapper Parameters

These are the parameters specific to `Run-AllSubscriptions.ps1`. The wrapper forwards `-DeviceLogin`, `-Obfuscate`, `-SkipMetrics`, `-SkipConsumption`, and `-ConcurrencyLimit` to the inner `ResourceInventory.ps1`, so they behave the same in both contexts.

| Parameter | Type | Description | Default | Example |
|-----------|------|-------------|---------|---------|
| `TenantID` | String | **Required.** Azure tenant GUID or verified domain. The wrapper resolves a domain to its GUID via OIDC discovery before authenticating. | — | `-TenantID "contoso.onmicrosoft.com"` |
| `Resume` | Switch | Skip subscriptions already completed in a prior run. Reads from `InventoryReports/.resume-state-<TenantID>.json`. State is cleared automatically after a clean run. | False | `-Resume` |
| `IncludeDisabled` | Switch | Include subscriptions whose state is not `Enabled` (e.g. `Disabled`, `Warned`, `PastDue`). By default these are skipped because they return little or no data. | False | `-IncludeDisabled` |
| `ParallelStreams` | Integer | Number of subscriptions to process concurrently. `1` (default) is the existing sequential behavior. See [Parallel subscription processing](#parallel-subscription-processing) for sizing guidance. | 1 | `-ParallelStreams 6` |
| `ConcurrencyLimit` | Integer | Forwarded to the inner script's metrics-collection throttle. Controls how many `Get-AzMetric` calls run in parallel within one subscription. | 6 | `-ConcurrencyLimit 12` |
| `Obfuscate` | Switch | Forwarded. Replace resource IDs, names, subscriptions, resource groups, and tags with masked values. | False | `-Obfuscate` |
| `SkipMetrics` | Switch | Forwarded. Skip Azure Monitor metrics collection. | False | `-SkipMetrics` |
| `SkipConsumption` | Switch | Forwarded. Skip cost/billing data collection. | False | `-SkipConsumption` |
| `DeviceLogin` | Switch | Forwarded. Use device-code authentication (browser flow with a code). | False | `-DeviceLogin` |

## Troubleshooting

### Common Issues

**Downloaded ZIP File:**
- If you download the ZIP file, Windows may mark the files as blocked for security reasons which is a known issue from GitHub
- Run the following PowerShell command to unblock all files in Resource Discovery in Azure folder  
   `Get-ChildItem -Path . -Recurse | Unblock-File`
- After unblocking, you can execute the script from the folder

**Authentication Errors:**
- Ensure you have the required Azure roles assigned
- For local environments, run `az login` before executing the script
- Multiple authentication prompts may appear due to parallel processing

**Performance Issues:**
- Reduce `ConcurrencyLimit` if experiencing timeouts
- Use `SkipConsumption` to speed up execution. This is not recommended, as it greatly reduces the usefulness of the report.
- Consider targeting specific subscriptions or resource groups

**Excel Formatting (Azure Cloud Shell):**
- Auto-fit columns may not work in Cloud Shell
- Warning messages are expected and don't affect data accuracy
- Download and open locally for proper formatting

### Important Notes

- The script does not upgrade existing PowerShell modules
- Resource-Graph extension installs automatically if missing
- All operations are read-only and safe to execute
- Historical data covers the previous 31 days
