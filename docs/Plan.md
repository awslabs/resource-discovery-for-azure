# Sizing a run: what drives per-subscription time (`-Plan`)

This document records the empirical basis for how long the tool takes per
subscription, so that shard sizing (`-Plan` and
[horizontal sharding](horizontal-sharding.md)) can be grounded in real data
rather than a flat guess. The figures below are aggregate ratios and
correlations by Azure service type, drawn from a representative run.

> The `-Plan` flag implements the model below: it counts each subscription's
> metric-eligible resources live via Resource Graph, converts that to a
> projected metric-query weight, and sizes shards by simulating the tool's real
> hash partition (see "A usable sizing model" and "How `-Plan` applies this").

## TL;DR

- Runtime per subscription is **dominated by the metrics phase** (Azure Monitor),
  not by inventory collection or consumption.
- Metrics time does **not** track the total resource count. It tracks the
  **number of Azure Monitor metric queries** the subscription triggers (one per
  resource-metric the tool requests).
- Metric query volume is dominated by **Managed Disks and Virtual Machines**
  (together ~85–90% of all metric queries in a representative sample).
- Therefore a good time estimate is
  `per_query_cost × (metric queries)`, where the query count is derivable up
  front from a Resource Graph count of the metric-eligible resource types.
- The single biggest runtime levers are, in order: **`-SkipDiskMetrics`**
  (disks are ~two-thirds of all metric queries), **`-UseMetricsBatch`**
  (collapses the per-query cost), and **`-MetricsIntervalMinutes 60`**
  (shrinks each response).

## The three phases, and which one matters

Each run's per-subscription `Diagnostics_*.log` records three phase timings:

- **Metrics collection (Azure Monitor)**
- **Resource detail collection (service collectors)**
- **Consumption / cost collection (billing)**

In a representative multi-subscription sample run, the aggregate split was
roughly:

| Phase | Share of total phase time |
|---|---|
| Metrics (Azure Monitor) | **~80%** |
| Inventory collectors | ~14% |
| Consumption | ~4% |

Inventory collectors were typically well under a minute per subscription, though
the largest subscriptions in the sample reached roughly 4–5 minutes; consumption
was near-zero for most. The metrics phase is where the minutes go, and it is
where a few subscriptions ran for tens of minutes each.

## The real driver: metric *query count*, not resource count

Correlating each subscription's metrics-phase seconds against candidate
predictors (same sample):

| Predictor | Correlation with metrics time |
|---|---|
| Total inventory resource count | **r ≈ −0.03 (none)** |
| Number of metric queries issued | **r ≈ +0.99** |
| Total metric datapoints returned | r ≈ +0.96 |

Raw resource count is actively misleading — the single largest subscription by
resource count (thousands of resources) spent **zero** time in metrics, because
its resources were not metric-eligible types. Meanwhile small subscriptions with
many disks/VMs ran for the better part of an hour. The number of *metric
queries* is the near-perfect predictor.

## Query volume by service

Where the metric queries come from (share of all metric queries, representative
sample; ratios are set by the tool's own metric definitions and are the durable,
tenant-independent part):

| Service | Share of metric queries | Metrics queried per resource | Notes |
|---|---|---|---|
| **Managed Disk** | **~67%** | ~4 | Composite Disk Read/Write Operations/sec + Read/Write Bytes/sec. Disks vastly outnumber other resource types, so this dominates. |
| **Virtual Machines** | ~19% | ~2 | Percentage CPU, Available Memory Bytes. |
| **Storage Account** | ~10% | ~1 | |
| **SQL Database** | ~3% | 8–9 | Higher per-resource query count; serverless vCore DBs add one more (`app_cpu_billed`). |
| VMSS / OSS databases / Container Registry | ~1% | few | Negligible contribution. |

**Managed Disk + Virtual Machines alone are ~85–90% of every metric query.**
Because each disk is queried for ~4 metrics and disks are the most numerous
resource type, disk metrics are the largest single component of run time.

## The per-query cost is a throttling tax

In the sample (15-minute grain, per-call — i.e. batch effectively off), each
metric query cost **~9.5 seconds**, and this was near-constant (~8–10 s) across
every heavy subscription. An Azure Monitor metric query should return in a few
hundred milliseconds, so ~9.5 s means the queries are being **throttled
(HTTP 429 → backoff) and effectively serialised**. The per-query cost — not the
resource mix — is the multiplier on everything, which is why it is the highest-
value thing to attack.

Note the distinction between a *metric query* (one logical resource-metric
request) and an *HTTP call*: on the per-call path they are one and the same, but
`-UseMetricsBatch` packs many resources into a single `metrics:getBatch` HTTP
call, so the same logical query count costs far fewer round-trips.

Because the tax is per *query*, the two ways to cut metrics time are:

1. **Issue fewer queries** (skip a whole resource type's metrics).
2. **Amortise the per-query cost** (put many resources in one HTTP call via
   `metrics:getBatch`).

## A usable sizing model

Unlike raw resource count, metric-query count is predictable up front from a
Resource Graph count of the metric-eligible resource types, weighted by their
metrics-per-resource:

```
est_metric_queries(sub) ≈ 4·#Disks + 2·#VMs + w_storage·#StorageAccounts
                          + w_sql·#SqlDatabases + …   (only for ENABLED metric types)

est_metrics_time(sub)   ≈ per_query_cost × est_metric_queries(sub)

est_sub_time(sub)       ≈ est_metrics_time(sub) + small_fixed_overhead
```

Notes for using this:

- Drop the terms for any metric type disabled by a `-Skip*` switch (e.g. with
  `-SkipDiskMetrics` the `4·#Disks` term — the largest one — disappears).
- `per_query_cost` is **config- and tenant-specific**. The ~9.5 s above is a
  near-worst-case (throttled, per-call). Measure it from a bundle produced with
  the **same flags you will run in production** (batch on, 60-minute grain)
  before trusting an absolute number.

## How `-Plan` applies this

`-Plan` is assessment-only (it authenticates, sizes, prints a recommendation,
and exits without inventorying anything). Concretely it:

1. **Counts weight live.** It sends one aggregate Resource Graph query per chunk
   of subscriptions (chunked to the ARG per-query cap of 1,000) that sums,
   per subscription, the projected metric-query weight over the metric-eligible
   types — honoring the same `-SkipDiskMetrics` / `-SkipStorageMetrics` gating
   the real run uses. It also returns the batchable portion of that weight
   separately, so under `-UseMetricsBatch` only the batchable types get the
   cheaper batched per-query cost.
2. **Converts weight to seconds** with a deliberately conservative model: a
   fixed per-subscription base overhead (inventory + consumption + packaging +
   startup) plus `per_query_cost × weight`, times a safety margin. The
   per-query cost defaults to a rough per-call/batched figure and is overridable
   with `-PlanPerQuerySeconds` measured from a prior run.
3. **Sizes shards by simulating the REAL partition.** Sharding here is
   coordination-free: each machine runs the same command with a different
   `-ShardIndex`, and subscriptions are assigned to shards by a deterministic
   hash of the subscription id (so the shards are disjoint and exhaustive with
   no central assignment). `-Plan` therefore does **not** compute a custom
   bin-pack assignment; instead it simulates that hash partition across
   candidate shard counts and picks the smallest count whose **busiest** shard
   (under the real hash assignment, accounting for heavy subscriptions clumping
   together) fits under the wall-time ceiling. It never recommends more shards
   than there are subscriptions, and when even that cannot fit it says so
   explicitly rather than claiming a fit.

Because sizing is done from the real hash partition rather than an idealised
even split, the recommendation is a conservative lower bound, not a guarantee;
keep margin under the ceiling and re-calibrate `per_query_cost` from a
production-config bundle.

## Runtime levers, in order of impact

| Lever | Effect on the sample's query load | Mechanism |
|---|---|---|
| `-SkipDiskMetrics` | removes **~67%** of metric queries | disks are ~4 queries each and by far the most numerous |
| `-SkipStorageMetrics` | removes **~10%** | |
| `-UseMetricsBatch` | collapses the **per-query cost** | many resources per `metrics:getBatch` HTTP call instead of one call each; falls back to per-call on batch failure |
| `-MetricsIntervalMinutes 60` | shrinks each response ~4× vs 15-min grain | fewer datapoints per series |

With disks and storage metrics skipped, the remaining query load is dominated by
**Virtual Machines** (~2 queries each), so on VM-dense tenants VM count becomes
the driver — and it is worth confirming that `-UseMetricsBatch` is actually
batching (not silently falling back to per-call), because that determines the
per-query cost that multiplies the whole VM query count.

## How to reproduce this analysis

Every report bundle carries the inputs, so this can be recomputed for any run —
including a production one — with no Azure calls:

1. **Phase timings** — parse each `Diagnostics_*.log`'s "Phase timings" block
   (Metrics / Resource detail / Consumption).
2. **Query volume by service** — read each `Metrics_*.json` (a `{ "Metrics": [ … ] }`
   object); each record is one resource-metric query and carries a `Service`
   field. Group by `Service` for the volume breakdown, and by distinct resource
   `ID` for per-resource metric counts.
3. **Correlate** metrics-phase seconds against (a) inventory resource count and
   (b) metric-query count to confirm which predicts time for that tenant/config.

Run this against a production-config bundle to calibrate `per_query_cost` and to
confirm the service mix before sizing a large run.

## Caveats

- The percentages and the ~9.5 s/query figure come from one representative
  sample run and one flag configuration; treat the **method and the service
  ranking** as transferable, but **re-measure the magnitudes** for the actual
  tenant and production flags.
- Throttling introduces run-to-run variance that no static count model captures,
  so always size with margin under the wall-time ceiling.
- Subscriptions with no metric-eligible resources visible to the identity return
  no Resource Graph row and are sized at base overhead only; if metrics are
  expected there, the identity may lack Resource Graph visibility into them
  (`-Plan` prints a note when this happens).

## See also

- [Horizontal sharding](horizontal-sharding.md) — how the shard count is applied
  across machines once you have chosen it.
- [Metrics batch trial](metrics-batch-trial.md) — the `-UseMetricsBatch`
  data-plane fast path referenced above.
