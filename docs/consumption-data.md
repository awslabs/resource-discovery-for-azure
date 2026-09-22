# Consumption (billing/usage) data — how it works

This document explains how Resource Discovery for Azure (RDA) collects the
consumption data that lands in `Consumption_<ReportName>_<timestamp>.csv`, what
each column means, what is deliberately **not** included, how it is obfuscated,
and how to recover a subscription whose consumption pull failed partway through.

The consumption phase runs unless you pass `-SkipConsumption`.

## Where the data comes from

RDA calls the Azure Billing cmdlet **`Get-UsageAggregates`** (from the
`Az.Billing` module). This returns metered **usage quantities**, not billed
cost (see [What is NOT included](#what-is-not-included)).

Per subscription, the collector:

- Sets the time window to the **last 31 days, ending at the start of yesterday**
  (`ReportedStartTime = today − 31 days`, `ReportedEndTime = yesterday`, both
  floored to midnight).
- Requests **`Daily`** aggregation granularity with **`ShowDetails = $true`**
  (so per-resource instance data is included).
- Pages through the results using the API's **`ContinuationToken`** until there
  are no more pages.
- Writes each page to the CSV as it goes (`Export-Csv -Append`), so rows are
  flushed incrementally rather than held in memory to the end.

### Authentication pre-check

Before paging, the phase verifies a usable Azure context/token exists
(`Test-DataPlaneAuthReady`). `Get-UsageAggregates` silently returns **zero**
records when the token is missing, which would otherwise leave an empty
consumption sheet that looks like "this tenant has no billing data." If the
check fails, RDA attempts **one** reconnect; if that still fails it logs a loud
error, records the subscription in the run health, and skips only the
consumption phase (the rest of the inventory continues).

### Transient-failure retry

Each page request is wrapped in a bounded retry (**3 attempts, exponential
backoff**). A single transient HTTP error — e.g. `Error while copying content to
a stream`, a timeout, or 429/503 throttling — retries the **same** page (the
previous page's `ContinuationToken` is preserved), so no rows are duplicated or
skipped. A permanent error exhausts the retries and is handled by the
per-subscription failure path (see [Recovering from a consumption
crash](#recovering-from-a-consumption-crash)).

## The columns

The CSV has 15 columns. Ten come straight from each usage-aggregation record;
five are derived from the `InstanceData` JSON on each record.

| Column | Source | Meaning |
|--------|--------|---------|
| `InstanceData` | usage record (re-serialized) | JSON blob describing the resource the usage belongs to (`Microsoft.Resources.resourceUri`, `location`, `additionalInfo`). Under `-Obfuscate` this is the obfuscated form. |
| `MeterCategory` | usage record | Top-level meter grouping, e.g. `Virtual Machines`, `Storage`, `Stream Analytics`. |
| `MeterId` | usage record | Azure's global meter GUID. Same for every customer using that meter — **not** customer-specific. |
| `MeterName` | usage record | Specific meter, e.g. `Standard Streaming Unit`, `P10 Disks`. |
| `MeterRegion` | usage record | Region the meter applies to. |
| `MeterSubCategory` | usage record | Meter sub-grouping, e.g. `Dv2 Series`. |
| `Quantity` | usage record | **Amount of usage** in the meter's unit (not a cost). |
| `Unit` | usage record | Unit for `Quantity`, e.g. `1 Hour`, `10000 GB`. |
| `UsageStartTime` | usage record | Start of the aggregation interval. |
| `UsageEndTime` | usage record | End of the aggregation interval. |
| `ResourceId` | `InstanceData.Microsoft.Resources.resourceUri` | ARM resource URI the usage is attributed to. Under `-Obfuscate`, identifying segments are masked but the ARM path *structure* is preserved (see below). |
| `ResourceLocation` | `InstanceData.Microsoft.Resources.location` | Location of the resource. |
| `ConsumptionMeter` | `InstanceData.Microsoft.Resources.additionalInfo.ConsumptionMeter` | Meter identifier from the resource's additional info (may be empty). |
| `ReservationId` | `additionalInfo.ReservationId` | Reservation the usage was applied to, if any. Masked to `obfuscated` under `-Obfuscate`. |
| `ReservationOrderId` | `additionalInfo.ReservationOrderId` | Reservation order, if any. Masked to `obfuscated` under `-Obfuscate`. |

## What is NOT included

- **Cost / dollar amount.** `Get-UsageAggregates` returns *usage quantity*
  (`Quantity` + `Unit`), not billed cost. There is no price or spend column.
  Deriving spend requires the rate card / Cost Management APIs, which RDA does
  not call. Use `Quantity` × your negotiated rates, or Cost Management, for money
  figures.
- **A dedicated `Subscription` column.** The subscription is embedded in
  `ResourceId` (`/subscriptions/<id>/…`). In a multi-subscription run each
  subscription has its own folder/CSV, so the owning subscription is implicit.
- **Every `additionalInfo` key as its own column.** Only `ConsumptionMeter`,
  `ReservationId`, and `ReservationOrderId` are broken out. Any other
  `additionalInfo` keys remain inside the raw `InstanceData` JSON (column 1) —
  not lost, just not columnarised.

## Obfuscation of consumption data

When `-Obfuscate` is used, consumption is masked with a scheme **separate** from
the inventory obfuscation dictionary:

- `ResourceId` / `resourceUri` is rebuilt segment-by-segment. The subscription
  id, resource group name, and resource name segments are replaced with
  `prod_`/`nonprod_` tokens, but the **ARM path structure is preserved**
  (`/subscriptions/<tok>/resourcegroups/<tok>/providers/<rp>/<type>/<tok>`),
  including the resource provider and type and the `mc_` AKS-managed-RG marker.
  This lets the ingestion dashboard categorise rows (AKS, VMSS, etc.) without
  seeing real identifiers.
- The tokens use per-run caches keyed by the real value, so the same real
  sub/RG/name always maps to the same token **within a run** (deterministic).
- These caches are **independent of** the inventory `ObfuscationDictionary`.
  Consumption tokens are therefore internally consistent but do **not** equal the
  inventory tokens for the same resource — categorisation relies on the path
  structure, not an ID-to-inventory join.
- `ReservationId` and `ReservationOrderId` are flattened to `obfuscated`.

## Per-subscription health and failure-point reporting

Consumption is tracked per subscription. A subscription whose pull fails is
recorded (in `$Global:ConsumptionFailedSubs`) with:

- `Complete = $false`
- `PageAtFailure` — the paged `Get-UsageAggregates` call it stopped on
- `RecordsCollected` — how many rows were written before it stopped
- a message ending `… this subscription's consumption is INCOMPLETE`

On an obfuscated run this is surfaced in the shareable
`Diagnostics_<ReportName>_<timestamp>.log` under **"Consumption
failed/incomplete subscriptions"**, so a truncated billing sheet is obvious in
the shared bundle rather than something you have to infer from a suspiciously
round row count. Subscriptions **not** listed there collected consumption
cleanly (the loop exited because the `ContinuationToken` was exhausted).

## Recovering from a consumption crash

If a subscription's consumption is incomplete (see the diagnostics log, or a
`Complete = $false` health entry), you do not need to re-run the whole tenant.
The rows already written to the CSV up to the failed page are valid and kept —
you re-collect that subscription's consumption and splice the fresh copy back in.

**Step 1 — re-collect the subscription with consumption enabled.** Seed with the
original run's obfuscation dictionary so the recovered data lines up with the
rest of the bundle. (You can also narrow inventory with `-Service` to keep it
fast; the consumption phase runs for the whole subscription regardless of
`-Service`.)

```powershell
./ResourceInventory.ps1 `
    -TenantID <tenant> `
    -SubscriptionID <the-failed-subscription> `
    -Obfuscate `
    -ObfuscationDictionary "<original ObfuscationDictionary_*.json for that subscription>" `
    -SkipMetrics
```

On the current build the per-page retry makes the fresh pull far more likely to
complete through the transient that truncated the first attempt.

**Step 2 — splice the fresh consumption into the original bundle** with
`Merge-RecoveryData -RecoverConsumption`, which whole-file replaces the
(truncated) consumption CSV with the recovery run's copy:

```powershell
. ./Functions/RecoveryMerge.Functions.ps1
Merge-RecoveryData `
    -GapBundlePath      "<the original subscription's report folder>" `
    -RecoveryBundlePath "<the folder Step 1 produced>" `
    -OutputPath         "<a new empty folder>" `
    -RecoverConsumption
```

The rebuilt bundle has complete consumption; inventory and metrics are carried
over from the original run unchanged, the HTML report is regenerated, and a
fresh ZIP is written. `Merge-RecoveryData` returns `ConsumptionSource = recovery`
so you can confirm the replacement happened.

> Note: consumption uses the per-run token scheme described above, so the
> replaced consumption file is internally consistent and categorises correctly
> even though its tokens differ from the original run's — nothing downstream
> joins consumption tokens to inventory tokens.

See also: [Recovery and diagnostics features](recovery-and-diagnostics.md).

## Marketplace consumption (Azure Marketplace / third-party SaaS)

`Get-UsageAggregates` above returns **first-party Azure** metered usage only — it
carries no `PublisherType` and never reports Azure Marketplace / third-party SaaS
charges (for example an ISV offer sold through Azure Marketplace, such as an
Anthropic/Claude offer surfaced via Azure AI Foundry). Those charges live behind a
**different** endpoint. To close that coverage gap, RDA runs a second, **additive**
collector that emits a separate `Marketplace_<ReportName>_<timestamp>.csv`. The
first-party `Consumption_*` schema and code path are untouched.

The Marketplace phase runs whenever consumption runs (it needs the same billing
access and Azure context), and can be turned off on its own with `-SkipMarketplace`
(or implicitly with `-SkipConsumption`).

### Where the data comes from

RDA calls **`Get-AzConsumptionMarketplace`** (also in `Az.Billing`, already
imported — **no new module dependency**). Its raw REST equivalent is
`GET .../providers/Microsoft.Consumption/marketplaces?api-version=2023-05-01`
([docs](https://learn.microsoft.com/en-us/rest/api/consumption/marketplaces/list);
[cmdlet docs](https://learn.microsoft.com/en-us/powershell/module/az.billing/get-azconsumptionmarketplace)).
It uses the **same** window as the first-party phase (last 31 days ending at the
start of yesterday) and reuses the **same** Cost Management Reader / Billing Reader
requirement — **no new role**. It is wrapped in the same auth pre-check, denial
short-circuit, mid-run token-refresh + subscription re-pin, and Retry-After/backoff
envelope as the first-party consumption loop.

**Discriminator.** On the modern usageDetails / Cost Management dimension the
`PublisherType` value distinguishes `Azure` (first-party) from `Marketplace`
(third-party). The Marketplace endpoint returns **only** Marketplace rows (its
`PSMarketplace` output type has no `PublisherType` property at all), so **no
client-side filtering is needed** — every row it returns is a Marketplace row.
The "is this Anthropic?" question is answered by `PublisherName` / `OfferName`;
RDA does **not** hardcode any publisher/offer literal — the field is the contract.

### The columns

The CSV columns are the documented `PSMarketplace` fields (verified against the
installed `Az.Billing` cmdlet's output type):

| Column | Meaning |
|--------|---------|
| `PublisherName` | ISV / publisher of the Marketplace offer (readable). |
| `OfferName` | The Marketplace offer (readable). |
| `PlanName` | Purchased plan/SKU within the offer (readable). |
| `OrderNumber` | Marketplace order number. |
| `ConsumedService` | The service the usage was consumed through. |
| `ConsumedQuantity` | Amount of usage in `UnitOfMeasure`. |
| `UnitOfMeasure` | Unit for `ConsumedQuantity`. |
| `PretaxCost` | Pre-tax charge for the row. |
| `Currency` | Currency of `PretaxCost`. |
| `IsEstimated` | Whether the charge is an estimate. |
| `MeterId` | Azure meter GUID (not customer-specific). |
| `UsageStart` / `UsageEnd` | Aggregation interval. |
| `SubscriptionGuid` | Subscription the usage is billed to. |
| `SubscriptionName` | Subscription display name (masked under `-Obfuscate`). |
| `ResourceGroup` | Resource group (masked under `-Obfuscate`). |
| `InstanceId` | ARM resource id of the consuming resource (masked under `-Obfuscate`, ARM path structure preserved). |
| `InstanceName` | Resource name (masked under `-Obfuscate`). |

### Obfuscation

`PublisherName` / `OfferName` / `PlanName` are **third-party product identifiers**,
not customer secrets, so they are left **readable** (the "which ISV / which offer"
signal must survive). `InstanceId`, `ResourceGroup`, `SubscriptionName`, and
`InstanceName` flow through RDA's existing consumption obfuscation exactly like the
first-party fields — deterministic per-run tokens, ARM path structure preserved on
`InstanceId`.

### Honest negatives (confirmed zero)

The Marketplace endpoint returns only Marketplace rows, so a successful call with
**zero** rows is a *confirmed absence* of Marketplace/third-party SaaS charges, not
a silently-missing section. When that happens, RDA logs an explicit
`0 rows … CONFIRMED ZERO` line, writes a header-only `Marketplace_*.csv`, and (on
obfuscated runs) records the confirmed-zero note in the shareable diagnostics log —
mirroring the first-party consumption zero-record warning.

See also: [Recovery and diagnostics features](recovery-and-diagnostics.md).

For the parameters that turn these phases off (`-SkipConsumption`,
`-SkipMarketplace`) and the other data-collection switches, see
[variables/metrics-and-consumption.md](variables/metrics-and-consumption.md).
