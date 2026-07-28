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

## Trimming metric volume at very large scale

On a very large tenant (thousands of subscriptions) three additional opt-in
switches let you cut the metric footprint further. All three are **OFF by
default** and default to each metric's native cadence, so a run that omits them
behaves exactly as before.

- `-SkipStorageMetrics` skips the Storage Account `UsedCapacity` metric
  (one metric-query call per storage account).
- `-SkipDiskMetrics` skips the four Managed Disk composite I/O metrics
  (four calls per attached disk, usually the single largest metric source).
- `-MetricsIntervalMinutes <0|5|15|30|60>` overrides the sampling grain of the
  high-frequency VM / Azure SQL DB / OSS-DB (MariaDB, MySQL, PostgreSQL and
  their Flexible variants) utilization series. `0` keeps each family's native
  cadence (15 min VM, 30 min SQL, 60 min OSS-DB); `60` gives one data point per
  hour.

Two different levers, two different effects:

- **API-call count** (what the Azure Monitor "metric queries" meter counts, and
  what the per-subscription read ceiling limits) is reduced by `-UseMetricsBatch`
  and by the two `-Skip*` switches. This is the lever that matters most for the
  read ceiling.
- **Data-point volume** (report memory, JSON size, post-processing time) is
  reduced by `-MetricsIntervalMinutes`. It does **not** change the number of API
  calls, only how many samples each call returns. Because the aggregation stays
  `Maximum`, a coarser grain still captures each bucket's peak (for example
  `60` = the hourly peak), just at lower time resolution.

### Best-case footprint for a very large tenant (without obfuscation)

This combines every volume lever: batched reads, no storage or disk metrics,
and hourly VM/SQL/OSS-DB utilization.

```powershell
pwsh ./Run-AllSubscriptions.ps1 -TenantID <your-tenant-id> `
  -UseMetricsBatch `
  -SkipStorageMetrics `
  -SkipDiskMetrics `
  -MetricsIntervalMinutes 60
```

> Without `-Obfuscate` the output contains **real** subscription, resource, and
> resource-group identifiers. Keep the resulting zip on a private/secure channel
> and do not send it anywhere that expects obfuscated input. Add `-Obfuscate` if
> the output will be shared for analysis.

Tune throughput for the host by adding `-ParallelStreams <n>` (each stream is a
separate process handling a slice of subscriptions); omit it to let the tool
auto-size to the machine.

Single subscription instead of the whole tenant:

```powershell
pwsh ./ResourceInventory.ps1 -SubscriptionID <your-subscription-id> `
  -UseMetricsBatch -SkipStorageMetrics -SkipDiskMetrics -MetricsIntervalMinutes 60
```

Each subscription also writes a `[Memory] Post-metrics GC:` line (managed heap
and process working set) to its local `DebugLog_*.log`, so you can watch the
per-subscription footprint across a long run. That log stays local and is never
included in the output zip.

## Cost note

Collecting standard platform metrics is free to ingest; **reading** them via the
API counts toward the Azure Monitor "metric queries" meter, which has a large
monthly free tier (10,000,000 calls per billing account per month; see the
Azure Monitor pricing page for current details). A single discovery run is
typically far below that.

Levers:

- `-UseMetricsBatch` lowers the number of metric-query calls versus the default
  per-call path.
- `-SkipStorageMetrics` / `-SkipDiskMetrics` drop those services' metrics, each
  removing their calls from the total (see "Trimming metric volume" above).
- `-MetricsIntervalMinutes` reduces data-point volume per call (memory / JSON),
  not the call count.
- `-SkipMetrics` skips the metrics phase entirely and issues zero metric-query
  calls.
