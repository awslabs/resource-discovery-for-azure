# Metrics and consumption parameters — what they do and why

This document explains the parameters that control the two most expensive
phases of a Resource Discovery for Azure (RDA) run: **metrics collection**
(Azure Monitor) and **consumption collection** (billing/usage). For each
parameter it gives the type, which script(s) declare it, its default and
validation, what it does in the code, and **why** it exists / when you would
reach for it.

Every behavioral claim below cites the file and approximate line it was read
from. Line numbers are approximate and drift as the scripts change; treat them
as "look near here", not exact offsets.

Related reading:

- [Consumption (billing/usage) data — how it works](../consumption-data.md) —
  the detailed companion for the consumption phase that `-SkipConsumption`
  turns off.
- [Fast multi-subscription discovery with batched metrics](../metrics-batch-trial.md)
  — the companion for `-UseMetricsBatch`.
- The index of all variable docs lives at `docs/variables/README.md` (owned by
  a sibling doc task).

> **Scope note.** This file documents the **metrics and consumption** group
> only. Authentication/execution parameters (e.g. `-TenantID`, `-DeviceLogin`,
> `-RunAllSubs`) and scaling/sharding/output/obfuscation parameters (e.g.
> `-ParallelStreams`, `-ConcurrencyLimit`, `-Obfuscate`) are documented
> separately by sibling docs.

---

## At a glance

| Parameter | Type | Declared on | Default / validation |
|---|---|---|---|
| `-SkipMetrics` | `[switch]` | `ResourceInventory.ps1`, `Run-AllSubscriptions.ps1` | off (present = skip) |
| `-SkipConsumption` | `[switch]` | `ResourceInventory.ps1`, `Run-AllSubscriptions.ps1` | off (present = skip) |
| `-SkipMarketplace` | `[switch]` | `ResourceInventory.ps1`, `Run-AllSubscriptions.ps1` | off (present = skip Marketplace collector only) |
| `-SkipDiskMetrics` | `[switch]` | `ResourceInventory.ps1`, `Run-AllSubscriptions.ps1` | off (present = skip disk I/O metrics) |
| `-IncludeStorageMetrics` | `[switch]` | `ResourceInventory.ps1`, `Run-AllSubscriptions.ps1` | off (opt-in) |
| `-MetricsDetailed` | `[switch]` | `ResourceInventory.ps1`, `Run-AllSubscriptions.ps1` | off (present = native cadences) |
| `-UseMetricsBatch` | `[switch]` | `ResourceInventory.ps1`, `Run-AllSubscriptions.ps1` | off (opt-in `metrics:getBatch`) |
| `-MetricsIntervalMinutes` | `[int]` | `ResourceInventory.ps1`, `Run-AllSubscriptions.ps1` | `0`; `ValidateSet(0,5,15,30,60)` |
| `-MetricsLookbackDays` | `[int]` | `ResourceInventory.ps1`, `Run-AllSubscriptions.ps1` | `31` on inner script; **no default** + `ValidateRange(1,93)` on wrapper |

All eight are also parameters of the metrics collector `Extension/Metrics.ps1`
(`param()` block, `Extension/Metrics.ps1` ~lines 2–19), except `-SkipConsumption`
(the consumption phase lives in `ResourceInventory.ps1`, not the metrics
extension). `Run-AllSubscriptions.ps1` declares all eight in its own `param()`
block (~lines 7–17) and forwards them to the inner `ResourceInventory.ps1`.

### How the wrapper forwards these to the inner script

`Run-AllSubscriptions.ps1` runs the inner `ResourceInventory.ps1` once per
subscription. Every parameter in this group is forwarded on **both** the
sequential path and the parallel-stream worker path:

- Sequential: `$InventoryPassthrough[...]` construction
  (`Run-AllSubscriptions.ps1` ~lines 1133–1141).
- Parallel streams: `$WorkerArgs.*` construction
  (`Run-AllSubscriptions.ps1` ~lines 1456–1464).

The two `[int]` parameters are forwarded only when they carry a non-default
value: `-MetricsIntervalMinutes` is forwarded only `if ($MetricsIntervalMinutes
-gt 0)` (~lines 1140, 1463) and `-MetricsLookbackDays` only `if
($PSBoundParameters.ContainsKey('MetricsLookbackDays'))` (~lines 1141, 1464).
The five switches are forwarded when present. As a result, a parameter you do
not pass to the wrapper falls through to the inner script's own default.

---

## `-SkipMetrics`

- **Type:** `[switch]`
- **Declared on:** `ResourceInventory.ps1` (param block, ~line 12) and
  `Run-AllSubscriptions.ps1` (param block, ~line 7).
- **Default:** off. When absent, the metrics phase runs. When present, it is
  skipped.

### What it does

`-SkipMetrics` turns off the **Azure Monitor metrics collection phase** — the
per-resource `Get-AzMetric` calls that produce the trend/utilization data in
`Metrics_<ReportName>_<timestamp>.json`.

In `ResourceInventory.ps1` the switch gates the metrics job at its source: the
`CreateMetricsJob` function only dispatches `Extension/Metrics.ps1` when
`!$SkipMetrics.IsPresent` (`ResourceInventory.ps1` ~line 775). When the switch
is present, that whole block — including the auth pre-check
(`Test-DataPlaneAuthReady -Phase 'Metrics'`, ~line 777) and the call into the
metrics collector (~line 827) — is never entered, so no Azure Monitor calls are
made.

The switch is also honored at three later points so the run stays consistent:

- The post-collection garbage-collection pass in `ProcessMetricsResult` only
  runs when metrics ran (`!$SkipMetrics.IsPresent`, ~line 833).
- The "Metrics collection (Azure Monitor)" phase timer is only recorded when
  metrics ran (~line 1416), so a skipped run does not report a misleading
  0-second metrics phase.
- At finalization, a **valid but empty** metrics JSON is still written when
  metrics were skipped: `@{ Metrics = @() } | ConvertTo-Json | Out-File`
  (~line 1710). This matters — the output bundle always contains a well-formed
  `Metrics_*.json` so downstream ingestion does not choke on a missing file; it
  just sees zero metric records.

In `Run-AllSubscriptions.ps1` the switch is a **passthrough** to the inner
script (`$InventoryPassthrough['SkipMetrics'] = $true`, ~line 1133; parallel
worker `$WorkerArgs.SkipMetrics = $true`, ~line 1456). It therefore behaves
identically whether you run one subscription directly or the whole tenant
through the wrapper.

### Why it exists / when to use it

Metrics collection is the **slowest** part of a run. Each `Get-AzMetric` call is
a round-trip to Azure Monitor (hundreds of milliseconds), and a metric-heavy
subscription (many VMs, SQL DBs, disks, database servers) generates thousands of
them. On a large tenant this phase dominates wall-clock time and is the main
consumer of the ARM read quota.

Skip metrics when you want a **fast structural inventory** — the list of
resources, their SKUs, locations, and configuration — without waiting on
utilization data. Typical cases:

- A quick "what exists here" pass before a deeper run.
- Working around a metrics phase that is timing out or hitting HTTP 429 on a
  very large estate, when you still need the rest of the report now.

The tradeoff: without metrics you lose all the utilization/right-sizing signal
(CPU %, memory, DTU, IOPS, etc.), which is the primary input for migration
sizing. For a migration assessment you normally want metrics **on**.

---

## `-SkipConsumption`

- **Type:** `[switch]`
- **Declared on:** `ResourceInventory.ps1` (param block, ~line 13) and
  `Run-AllSubscriptions.ps1` (param block, ~line 8).
- **Default:** off. When absent, the consumption phase runs. When present, it is
  skipped.

### What it does

`-SkipConsumption` turns off the **consumption (billing/usage) collection
phase** — the `Get-UsageAggregates` calls that populate
`Consumption_<ReportName>_<timestamp>.csv`. The full mechanics of that phase
(time window, columns, paging, retries) are documented in
[consumption-data.md](../consumption-data.md); this section only covers the
switch that turns it off.

In `ResourceInventory.ps1`:

- The consumption phase is gated on `!$SkipConsumption.IsPresent` (~line 1422).
  When absent, `GetResourceConsumption` runs inside a phase timer (~line 1425);
  when present, the whole phase — timer, auth check, and paging — is skipped.
- As with metrics, finalization still guarantees a well-formed output: when
  consumption is skipped (or the CSV was never created, or is empty), RDA writes
  a **header-only** consumption CSV with the full 15-column header row
  (guarded by `if ($SkipConsumption.IsPresent -or !$ConsumptionCreated -or
  $ConsumptionEmpty)`, ~lines 1739–1743). Downstream tooling therefore always
  finds a schema-valid CSV, just with no data rows.

In `Run-AllSubscriptions.ps1` the switch does two things:

1. **Passthrough** to the inner script, exactly like `-SkipMetrics`
   (`$InventoryPassthrough['SkipConsumption'] = $true`, ~line 1134; parallel
   worker `$WorkerArgs.SkipConsumption = $true`, ~line 1457).
2. **Suppresses the up-front consumption access pre-check.** The wrapper only
   verifies billing read access when consumption is requested — the whole check
   is guarded by `if (-not $SkipConsumption -and $Subscriptions.Count -gt 0)`
   (~line 981). When the identity cannot read consumption data, that check
   **hard-fails the run** with an explicit error and a pointer to grant
   `Cost Management Reader` / `Billing Reader` or re-run with `-SkipConsumption`
   (~lines 989–995). Passing `-SkipConsumption` therefore also skips that gate,
   which is the intended escape hatch for an operator who genuinely has mixed
   per-subscription billing access.

### Why it exists / when to use it

Consumption collection pages through Azure Billing usage records and can be slow
on subscriptions with a lot of metered activity. Skipping it speeds up a run and
sidesteps billing-permission requirements (Cost Management Reader / Billing
Reader).

However, skipping consumption **greatly reduces the usefulness of the report**
for cost/migration analysis — there is no usage-quantity data to reason about
spend or reserved-instance coverage. Use `-SkipConsumption` when:

- You only need the resource inventory and/or metrics, not billing.
- The signed-in identity lacks billing access and you want the run to proceed
  anyway rather than hard-stopping (see the wrapper pre-check above).
- You are iterating on inventory/metrics and want to shave the consumption phase
  off each cycle.

Prefer leaving it **on** for any run whose purpose is cost or right-sizing
analysis.

---

## `-SkipMarketplace`

- **Type:** `[switch]`
- **Declared on:** `ResourceInventory.ps1` (param block) and
  `Run-AllSubscriptions.ps1` (param block).
- **Default:** off. When absent, the **additive Marketplace consumption
  collector** runs (as part of the consumption phase). When present, only the
  Marketplace collector is skipped; the first-party consumption phase is
  unaffected.

### What it does

The Marketplace collector calls `Get-AzConsumptionMarketplace` (Az.Billing) to
capture **Azure Marketplace / third-party SaaS** charges — the offers the
first-party `Get-UsageAggregates` path does not report — into a separate
`Marketplace_<ReportName>_<timestamp>.csv`. Its full mechanics (endpoint,
api-version, columns, obfuscation, confirmed-zero behaviour) are documented in
[consumption-data.md](../consumption-data.md#marketplace-consumption-azure-marketplace--third-party-saas).

- The Marketplace phase is gated on
  `!$SkipConsumption.IsPresent -and !$SkipMarketplace.IsPresent` — it needs the
  same billing access and Azure context as the first-party phase, so
  `-SkipConsumption` implies it is skipped too, and `-SkipMarketplace` turns off
  **only** the Marketplace collector while leaving first-party consumption on.
- As with the other phases, finalization guarantees a well-formed output: when
  the Marketplace phase is skipped (or produced no rows), RDA writes a
  **header-only** `Marketplace_*.csv` so downstream tooling always finds a
  schema-valid file.

In `Run-AllSubscriptions.ps1` the switch is forwarded to the inner script exactly
like `-SkipConsumption` (`$InventoryPassthrough['SkipMarketplace'] = $true`), on
both the sequential and parallel-stream paths.

### Why it exists / when to use it

The Marketplace collector adds one billing API call per subscription. It reuses
the existing Cost Management Reader / Billing Reader requirement, so it needs no
extra role. Use `-SkipMarketplace` when you want the first-party consumption CSV
but not the Marketplace one — for example when you already know the tenant has no
Marketplace purchases and want to shave the extra call. Leave it **on** (the
default) for any run where third-party/Marketplace spend could matter (e.g. an ISV
offer purchased through Azure Marketplace / Azure AI Foundry).

---

## `-SkipDiskMetrics`

- **Type:** `[switch]`
- **Declared on:** `ResourceInventory.ps1` (param block, ~line 19),
  `Run-AllSubscriptions.ps1` (param block, ~line 13), and `Extension/Metrics.ps1`
  (param block, ~line 15).
- **Default:** off. When absent, managed-disk I/O metrics are collected.

### What it does

`-SkipDiskMetrics` excludes **only** the Managed Disk composite I/O metric
definitions, leaving every other metric family intact.

In `Extension/Metrics.ps1`, the managed-disk metric definitions are only added
when the switch is absent: the loop is guarded by
`if ($ManagedDisks -and -not $SkipDiskMetrics)` (`Extension/Metrics.ps1`
~line 356). For each **attached** managed disk (the set is pre-filtered to
`microsoft.compute/disks` with a non-empty `ManagedBy`, ~line 354) it adds
**four** series metrics: `Composite Disk Read Operations/sec`, `Composite Disk
Write Operations/sec`, `Composite Disk Read Bytes/sec`, and `Composite Disk
Write Bytes/sec` (~lines 360–365). With the switch present, none of those
definitions are created, so no disk-metric queries are issued.

The wrapper forwards it as a passthrough on both paths
(`Run-AllSubscriptions.ps1` ~lines 1137, 1460). It is also consulted by the
`-Plan` sizing estimate, which drops the disk-query weight when the switch is
set (`Get-PlanSubscriptionWeights ... -SkipDiskMetrics:$SkipDiskMetrics`,
`Run-AllSubscriptions.ps1` ~line 547).

### Why it exists / when to use it

At four calls per attached disk, disk metrics are often the **largest single
source** of metric queries in the whole run — the wrapper's own warnings call
out `-SkipDiskMetrics` as the first lever to pull when one subscription's
metrics load is too heavy to fit the time budget (`Run-AllSubscriptions.ps1`
~lines 614, 618). Skip disk metrics when the disk-level IOPS/throughput detail
is not needed for the assessment but you still want VM/DB/other utilization —
it is a targeted trim rather than the all-or-nothing `-SkipMetrics`.

---

## `-IncludeStorageMetrics`

- **Type:** `[switch]`
- **Declared on:** `ResourceInventory.ps1` (param block, ~line 18),
  `Run-AllSubscriptions.ps1` (param block, ~line 12), and `Extension/Metrics.ps1`
  (param block, ~line 14).
- **Default:** off. It is an **opt-in** — storage capacity is **not** collected
  unless this switch is present.

### What it does

`-IncludeStorageMetrics` opts the Storage Account `UsedCapacity` metric **in**.
By default it is not collected.

In `Extension/Metrics.ps1`, when storage accounts exist the collector logs
whether it is collecting or skipping the capacity metric based on the switch
(~lines 375–382), and the `UsedCapacity` metric definition is added **only**
under `if ($StorageAccounts -and $IncludeStorageMetrics)` (~line 384). That
definition is a single point-in-time value per account: it uses the fixed
1-day window (`StartTime = $MetricTimeOneDay`), hourly interval, and
`Series = 'false'` (~line 388). With the switch absent, no storage-metric query
is issued at all.

The wrapper forwards it as a passthrough on both paths
(`Run-AllSubscriptions.ps1` ~lines 1136, 1459). The `-Plan` sizing estimate also
mirrors the default-off behavior: it computes `$PlanSkipStorage = -not
$IncludeStorageMetrics` and passes that to the weight estimator
(`Run-AllSubscriptions.ps1` ~lines 546–547).

### Why it exists / when to use it

The `UsedCapacity` metric costs **one** metric-query call per storage account.
On a tenant with a very large storage estate that single capacity figure can
dominate the metrics phase, so it is off by default and you opt in only when
storage capacity is actually wanted (e.g. sizing a storage migration). It is the
mirror image of `-SkipDiskMetrics`: disk I/O is on-by-default and can be turned
off, storage capacity is off-by-default and can be turned on.

---

## `-MetricsDetailed`

- **Type:** `[switch]`
- **Declared on:** `ResourceInventory.ps1` (param block, ~line 22),
  `Run-AllSubscriptions.ps1` (param block, ~line 14), and `Extension/Metrics.ps1`
  (param block, ~line 17).
- **Default:** off. When absent, the sampled utilization series are collected at
  an **hourly** grain.

### What it does

`-MetricsDetailed` changes the **sampling grain** (the `Interval` on each
Azure Monitor query) of the high-frequency utilization series, moving them from
the default hourly cadence to each family's finer native cadence.

The grain is computed centrally by the `Get-RdaMetricGrainPlan` helper
(`Extension/Metrics.ps1` ~lines 38–48). Its logic:

```
$Effective = if ($MetricsIntervalMinutes -gt 0) { $MetricsIntervalMinutes }
             elseif ($MetricsDetailed) { 0 } else { 60 }
```

- With neither switch, `$Effective = 60` → every sampled family gets an hourly
  (`01:00:00`) grain.
- With `-MetricsDetailed` (and no `-MetricsIntervalMinutes`), `$Effective = 0` →
  the helper returns each family's **native** cadence: VM `00:15:00`
  (15 min), SQL `00:30:00` (30 min), OSS-DB `01:00:00` (hourly), and Disk
  `00:15:00` (15 min) (~lines 43–47).
- The `Disk` grain is driven **directly** by `-MetricsDetailed`
  (`if ($MetricsDetailed) { '00:15:00' } else { '01:00:00' }`, ~line 46), so it
  is not affected by `-MetricsIntervalMinutes` (unlike VM/SQL/OSS-DB).

These grains are stamped onto the trend metric definitions as they are built —
e.g. `$VmMetricInterval` on VM `Percentage CPU` / `Available Memory Bytes`
(~lines 323, 339), `$SqlMetricInterval` on SQL `cpu_used` / `dtu_used` /
`cpu_percent` (~lines 407, 417, 420), `$DbMetricInterval` on the OSS-DB
`cpu_percent` / `memory_percent` series (MariaDB/MySQL/PostgreSQL, ~lines
460–508), and `$DiskMetricInterval` on the four managed-disk composites
(~lines 362–365).

The switch does **not** change the metric API-call count — it only changes how
many data points each response carries — and it does not affect VMSS, the daily
capacity metrics, or the point-in-time snapshots (those carry hardcoded
`Interval` strings independent of the grain plan).

The wrapper forwards it as a passthrough on both paths
(`Run-AllSubscriptions.ps1` ~lines 1138, 1461).

### Why it exists / when to use it

The upstream default is hourly, which cuts VM data-point volume ~4× versus the
15-minute native cadence. `-MetricsDetailed` restores the finer cadences when
you need higher-fidelity utilization curves (e.g. to catch short CPU spikes a
hourly-max would still capture but a finer trend would show in context). The
cost is a larger `Metrics_*.json` and more memory during the metrics phase. For
very large tenants prefer the default hourly grain, or override selectively with
`-MetricsIntervalMinutes`.

---

## `-MetricsIntervalMinutes`

- **Type:** `[int]`
- **Declared on:** `ResourceInventory.ps1` (param block, ~line 21),
  `Run-AllSubscriptions.ps1` (param block, ~line 16), and `Extension/Metrics.ps1`
  (param block, ~line 16).
- **Default / validation:** default `0`; `ValidateSet(0, 5, 15, 30, 60)` on all
  three declarations — only those five values are accepted.

### What it does

`-MetricsIntervalMinutes` overrides the sampling grain of the VM, Azure SQL DB,
and OSS-DB sampled series to a single **uniform** value, taking precedence over
`-MetricsDetailed`.

In `Get-RdaMetricGrainPlan` (`Extension/Metrics.ps1` ~lines 38–48):

- `0` (the default) means "no override" — the grain then falls to
  `-MetricsDetailed` (native cadences) or, if that is also off, hourly.
- A non-zero value sets `$Effective` to that value, and the helper builds a
  single `$Uniform = ([TimeSpan]::FromMinutes($Effective)).ToString()` that is
  applied to VM, SQL, **and** OSS-DB alike (~lines 40–45). It is honored as-is:
  coarser than a family's native cadence shrinks that family's data-point volume;
  finer increases it.
- The `Disk` grain is **not** affected — it keys off `-MetricsDetailed` only
  (~line 46).

Because it only changes the `Interval` stamped on each query, it does **not**
change the metric API-call count, only the number of data points returned.

The wrapper declares the same `ValidateSet` and forwards the value only when
non-zero: `if ($MetricsIntervalMinutes -gt 0) { ... }`
(`Run-AllSubscriptions.ps1` ~lines 1140, 1463). A `0` is therefore never
forwarded and the inner script uses its own default.

### Why it exists / when to use it

It is a per-run volume/fidelity dial for the sampled utilization series. On a
very large tenant that is memory- or size-constrained, `-MetricsIntervalMinutes
60` collapses the sampled families to one hourly (peak) point to cut data-point
volume. Conversely, a value finer than a family's default raises fidelity for
that family (e.g. `30` gives finer OSS-DB detail than its 60-minute default).
Because the value is applied uniformly to all three families, use it when a
single grain is acceptable across VM/SQL/OSS-DB; use `-MetricsDetailed` when you
want each family at its own native cadence instead.

---

## `-UseMetricsBatch`

- **Type:** `[switch]`
- **Declared on:** `ResourceInventory.ps1` (param block, ~line 17),
  `Run-AllSubscriptions.ps1` (param block, ~line 10), and `Extension/Metrics.ps1`
  (param block, ~line 18).
- **Default:** off. Opt-in / experimental. See
  [metrics-batch-trial.md](../metrics-batch-trial.md).

### What it does

`-UseMetricsBatch` routes eligible metrics through the Azure Monitor
`metrics:getBatch` data-plane API (one request per ≤50 resources) instead of the
default one-call-per-metric path, cutting the request count.

In `Extension/Metrics.ps1`, the batch path is entered under `if
($UseMetricsBatch)` (~line 580). It:

- Partitions the already-built `$MetricDefs` into a batchable set and a
  remainder using a fixed namespace map — only Virtual Machines, Managed Disk,
  Storage Account, SQL Database, VM Scale Sets, and CosmosDB are batch-eligible
  (`$BatchNamespaceMap`, ~lines 582–589). Everything else stays on the per-call
  path.
- Calls `Invoke-RdaMetricsBatch` per eligible service namespace (~line 616) and
  records which `(resource id, metric)` keys were satisfied; any definition the
  batch did not return is pushed back onto the per-call remainder (~lines
  622–632), so **no metric is lost**.
- On any batch error it logs a warning (with an auth-specific hint for
  403/AuthorizationFailed) and **falls back** the whole service group to the
  per-call path (~lines 638–652). The comment on the batch call notes it "falls
  back to the per-call path on any failure."
- Writes the batch results to a `<FilePath>_0.json` shard (~line 660), then the
  remaining `$MetricDefs` continue through the normal per-call runspace loop.

The wrapper forwards it as a passthrough on both paths
(`Run-AllSubscriptions.ps1` ~lines 1135, 1458) and also uses it to adjust the
`-Plan` per-query cost estimate (`if ($UseMetricsBatch)` branches, ~lines 564,
590, 598).

### Why it exists / when to use it

The default per-metric path issues one Azure Monitor query per metric per
resource, which is the phase that hits the metric-query rate limit first on
large estates. Batching collapses up to 50 resources' worth of a metric into one
request, lowering the API-call count (and the associated free-tier
"metric queries" footprint the batch doc describes). Because it is pre-release
and silently falls back on failure, try it against a sandbox subscription first
per [metrics-batch-trial.md](../metrics-batch-trial.md).

---

## `-MetricsLookbackDays`

- **Type:** `[int]`
- **Declared on:** `ResourceInventory.ps1` (param block, ~line 24, **default
  `31`**, no validation attribute); `Run-AllSubscriptions.ps1` (param block,
  ~line 17, **no default**, `ValidateRange(1, 93)`); and `Extension/Metrics.ps1`
  (param block, ~line 13, default `31`).
- **Default / validation:** the inner `ResourceInventory.ps1` defaults to `31`
  and accepts any integer (it takes the absolute value — see below). The wrapper
  `Run-AllSubscriptions.ps1` has **no default** and enforces
  `ValidateRange(1, 93)`; when you do not pass it, the wrapper does not forward
  it and the inner script's `31` default applies.

> **Why the split default.** Only the wrapper carries `ValidateRange(1, 93)` —
> 93 days is Azure Monitor's platform-metric retention ceiling, so a
> whole-tenant run is bounded to a value Azure can actually satisfy. The inner
> script keeps the historical `31`-day default and no range attribute; it clamps
> nothing but normalises the sign (below). The wrapper's lack of a default is
> deliberate: it lets `if ($PSBoundParameters.ContainsKey('MetricsLookbackDays'))`
> distinguish "operator set a value" from "leave the inner default alone"
> (`Run-AllSubscriptions.ps1` ~lines 1141, 1464).

### What it does

`-MetricsLookbackDays` sets **how far back the trend metrics reach** — the size
of the history window for the time-series ("trend") metrics only.

`ResourceInventory.ps1` forwards the value into the metrics collector when it
dispatches the job (`-MetricsLookbackDays $MetricsLookbackDays` on the
`& $MetricPath ...` call, ~line 827). Inside `Extension/Metrics.ps1`:

- The incoming value is normalised to a negative day count regardless of sign:
  `$MetricsLookbackPeriodDays = -1 * [math]::Abs([int]$MetricsLookbackDays)`
  (~line 288). So `14` and `-14` behave the same.
- That becomes the window start:
  `$MetricStartTime = (Get-Date).AddDays($MetricsLookbackPeriodDays)`
  (~line 290), with the end fixed at "now" (`$MetricEndTime = (Get-Date)`,
  ~line 292).
- `$MetricStartTime` is then stamped as the `StartTime` on the **trend** metric
  definitions — the ones marked `Series = 'true'` (e.g. VM `Percentage CPU` and
  `Available Memory Bytes`, managed-disk composite IOPS/throughput, SQL
  `cpu_used`/`dtu_used`/`cpu_percent`, and the OSS-DB
  `cpu_percent`/`memory_percent` series).

Capacity and point-in-time metrics use a **separate, fixed 1-day window**
instead. Those definitions are stamped with `$MetricTimeOneDay =
(Get-Date).AddDays(-1)` (`Extension/Metrics.ps1` ~line 293) — for example SQL
`storage`, `storage_percent`, `dtu_limit`/`cpu_limit`, serverless
`app_cpu_billed`, the OSS-DB `storage_percent` rows, Storage Account
`UsedCapacity`, CosmosDB throughput, and ContainerRegistry `StorageUsed`.
Lowering `-MetricsLookbackDays` does **not** shrink those; they are always a
1-day snapshot.

`-MetricsLookbackDays` also does **not**:

- change which resources are discovered (that is the inventory phase, unaffected
  by the metrics window), or
- affect consumption/cost data — the consumption phase uses its own hardcoded
  31-day window (`ResourceInventory.ps1` ~line 1086:
  `$ReportedStartTime = (Get-Date).AddDays(-31)`), independent of this
  parameter.

### Why it exists / when to use it

A shorter lookback window makes the metrics phase **faster and lighter on
memory**, because each trend metric returns fewer data points. On large estates
that time out or hit out-of-memory errors during the metrics phase, dropping the
window (e.g. `31` → `14` or `7`) is a direct lever on run time and peak memory,
and the wrapper's sizing warnings list `-MetricsLookbackDays 14` among the
levers to bring an over-budget shard down (`Run-AllSubscriptions.ps1` ~lines
614, 618).

The tradeoff is right-sizing accuracy: a shorter window samples fewer
peaks/business cycles, so utilization-based sizing rests on a smaller sample.
For migration assessments prefer **14 over 7**, so at least one full weekly cycle
is captured.

---

## How these parameters compose

- `-SkipMetrics` is the master off-switch for the whole metrics phase; when it
  is set, none of the other metrics parameters below do anything (the collector
  is never dispatched).
- Within an active metrics phase, `-SkipDiskMetrics` and `-IncludeStorageMetrics`
  change **which** metric families are collected; `-MetricsDetailed` and
  `-MetricsIntervalMinutes` change the **grain** of the sampled series; and
  `-MetricsLookbackDays` changes the **window** of the trend series.
- `-MetricsIntervalMinutes` (non-zero) overrides `-MetricsDetailed` for VM / SQL
  / OSS-DB grain; disk grain follows `-MetricsDetailed` regardless.
- `-UseMetricsBatch` changes **how** the metric queries are issued (batched vs.
  per-call), not which metrics or what grain — and silently falls back to
  per-call on failure.
- `-SkipConsumption` is independent of every metrics parameter; it gates the
  separate billing/usage phase.
