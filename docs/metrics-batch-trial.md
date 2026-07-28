# Fast multi-subscription discovery with batched metrics (experimental)

This guide covers an experimental option that collects Azure Monitor metrics
using the `metrics:getBatch` data-plane API, which gathers VM / disk / storage
metrics in far fewer requests than the default per-metric path. It also reports
how many metric-query API calls a run issued, so you can gauge the run's
footprint against the Azure Monitor "metric queries" free tier.

> This is a pre-release, experimental capability (default OFF). Try it against a
> non-production / sandbox subscription first.

## Prerequisites

- PowerShell 7+ (`pwsh`)
- The `Az` PowerShell modules. The tool checks for and can install the ones it
  needs: `Az.Accounts`, `Az.Compute`, `Az.Monitor`, `Az.Billing`,
  `Az.ResourceGraph`.
- Reader (or higher) on the subscription(s) you want to inventory.

## Get the branch

```bash
git clone -b experiment/metrics-dataplane-batch \
  https://github.com/pmorgenrood/resource-discovery-for-azure.git
cd resource-discovery-for-azure
```

## Run all subscriptions with the fast metrics path

```powershell
pwsh ./Run-AllSubscriptions.ps1 -TenantID <your-tenant-id> -UseMetricsBatch
```

- `-UseMetricsBatch` collects VM / disk / storage metrics in batched requests
  (one request per up to 50 resources) instead of one call per
  resource-and-metric. It is faster and issues fewer billable metric-query
  calls. It applies to every subscription, in both the sequential and the
  parallel-streams execution paths.
- It is **OFF by default**. On any problem (provider not registered, narrow
  RBAC, a regional issue) it automatically falls back to the standard per-call
  path, so metrics are never lost.
- Parallelism auto-tunes to the host. Force it with `-ParallelStreams <n>`
  (for example `-ParallelStreams 4`) to process several subscriptions at once.
- The first run per subscription may register the `Microsoft.Insights` resource
  provider (a one-time, low-privilege operation). If your identity cannot
  register it, batch simply falls back to the per-call path.

Single subscription instead of the whole tenant:

```powershell
pwsh ./ResourceInventory.ps1 -SubscriptionID <your-subscription-id> -UseMetricsBatch
```

> Note on interactive sign-in: when you sign in interactively (for example with
> `-DeviceLogin`), recent versions of the Az PowerShell modules ask you to pick a
> subscription once, right after authentication. This choice only sets the default
> context; the tool still discovers and processes **all** of your subscriptions
> regardless of which one you pick, so any selection is fine. (This one-time prompt
> only appears in an interactive session — it is not a data or security setting.)

## See the metric-query API-call footprint

Open the `RunSummary_*.log` written to the output folder
(`~/InventoryReports` on Linux/macOS, `C:\InventoryReports` on Windows). In the
**Health** section:

```
Health:
  Consumption records collected : 0
  Metric-query API calls issued : 13
  Failed subscriptions          : 0
  ...
```

`Metric-query API calls issued` is the run-wide total across all subscriptions.
Per-subscription detail (a per-call vs getBatch breakdown) is written to each
subscription's local `DebugLog_*.log`.

## Cost note

Collecting standard platform metrics is free to ingest; **reading** them via the
API counts toward the Azure Monitor "metric queries" meter, which has a large
monthly free tier (10,000,000 calls per billing account per month; see the
Azure Monitor pricing page for current details). A single discovery run is
typically far below that.

Levers:

- `-UseMetricsBatch` lowers the number of metric-query calls versus the default
  per-call path.
- `-SkipMetrics` skips the metrics phase entirely and issues zero metric-query
  calls.
