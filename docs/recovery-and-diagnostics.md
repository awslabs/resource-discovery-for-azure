# Recovery and diagnostics

This guide covers the targeted-collection, recovery, and diagnostics features
that are not in the main README. They exist for one job: when a long
multi-subscription run partly fails (one collector errors, or a subscription's
metrics or consumption pull is interrupted), you can repair just the missing
piece instead of re-running the whole tenant.

Applies to build 3.2.2 and later.

## Contents
- [When you need this](#when-you-need-this)
- [How a run is built (three phases)](#how-a-run-is-built-three-phases)
- [-Service, re-run specific collectors](#-service-re-run-specific-collectors)
- [What -Service can and cannot scope](#what--service-can-and-cannot-scope)
- [-ObfuscationDictionary, reuse tokens from a prior run](#-obfuscationdictionary-reuse-tokens-from-a-prior-run)
- [Merge-RecoveryData, splice a repair run back in](#merge-recoverydata-splice-a-repair-run-back-in)
- [Worked recovery examples](#worked-recovery-examples)
- [Diagnostics logs](#diagnostics-logs)
- [Reveal.ps1, turn masked reports back into real values](#revealps1-turn-masked-reports-back-into-real-values)

## When you need this

A full tenant run can take a while. If something fails partway, the run still
finishes and still produces a report, but that report is quietly missing a
slice: maybe one service came back empty, or a subscription's billing sheet is
cut short. Re-running the entire tenant to recover one service, or one
subscription's billing, wastes time. The features below let you re-collect only
the missing slice and merge it back into the original bundle, so the final
result looks like a clean first run.

## How a run is built (three phases)

Every subscription goes through three independent phases. Knowing which phase
failed tells you how to repair it.

1. Inventory. One collector per resource type (the files under `Services/`).
   This produces the resource list in the report.
2. Metrics. Azure Monitor metrics such as CPU, memory, and disk, for a fixed set
   of resource types. Controlled by `-SkipMetrics`.
3. Consumption. Subscription billing from `Get-UsageAggregates`. Controlled by
   `-SkipConsumption`.

The three phases fail and recover separately, so the rest of this guide is
organised around them.

## -Service, re-run specific collectors

`ResourceInventory.ps1 -Service <name>` runs only the collectors you name,
instead of all of them. Names are the collector file base names, for example
`VirtualMachines`, `StorageAcc`, `AKS`, `Streamanalytics`. Matching is
case-insensitive, and you can pass several, separated by commas.

```powershell
# Re-run just the Virtual Machines collector for one subscription
./ResourceInventory.ps1 -TenantID <tenant-id> -SubscriptionID <sub-id> -Service VirtualMachines

# Re-run two collectors
./ResourceInventory.ps1 -TenantID <tenant-id> -SubscriptionID <sub-id> -Service Streamanalytics,AKS
```

If you name a collector that does not exist (a typo, or a service that is not in
the recovery inventory), the run stops right away with an error that lists the
bad name and the valid ones. It does not silently collect a smaller set.

This is the main tool for recovering a single failed collector.

## What -Service can and cannot scope

`-Service` only scopes the inventory phase. It does not change metrics or
consumption. Here is the full picture:

| Phase | Can -Service scope it? | Why |
|-------|------------------------|-----|
| Inventory | Yes, per collector. `-Service VirtualMachines` re-runs only that collector. | Each collector under `Services/` is picked by name. |
| Metrics | No. Metrics still cover the whole subscription, grouped by resource type. | `Extension/Metrics.ps1` takes the full resource list and filters it by type on its own (for example, `$Resources | Where-Object { $_.TYPE -eq 'microsoft.compute/virtualmachines' }`), so the collector selection never reaches it. |
| Consumption | No, and it cannot be split by service at all. | Consumption is whole-subscription billing from `Get-UsageAggregates`. There is no per-service breakdown to select. |

So you can re-collect one failed inventory collector with `-Service`, but to
repair metrics or consumption you re-run that subscription's metrics or
consumption phase (drop `-SkipMetrics` or `-SkipConsumption`) and merge the
result back with `Merge-RecoveryData -RecoverMetrics` or `-RecoverConsumption`.

`-RecoverMetrics` and `-RecoverConsumption` are switches on `Merge-RecoveryData`
that tell it to take the metrics or consumption files from the repair run
instead of keeping the original (empty or partial) ones. They are covered in
detail in the [Merge-RecoveryData](#merge-recoverydata-splice-a-repair-run-back-in)
section below.

### Targeted collection (not recovery): use -ResourceGroup

`-Service` is a recovery tool, not a general workload filter. If your goal is to
collect only part of a subscription up front (for example, only the VMs in a
tenant with poor resource-group hygiene), scope by resource group instead:

```powershell
./ResourceInventory.ps1 -TenantID <tenant-id> -SubscriptionID <sub-id> -ResourceGroup <rg-name>
```

Unlike `-Service`, `-ResourceGroup` narrows the Resource Graph query itself, so it
scopes both inventory and metrics (the metrics phase reads the same narrowed
resource list). Consumption is the exception: `Get-UsageAggregates` is
whole-subscription billing with no resource-group or resource-type filter, so it
still covers the entire subscription. Add `-SkipConsumption` if you do not want
that, or accept a consumption sheet that is broader than the resources you
collected. There is no built-in way to collect only one service's metrics or only
one service's consumption; `-Service` on its own leaves both phases
subscription-wide (which is why a clean `-Service` recovery run pairs it with
`-SkipMetrics -SkipConsumption`).

## -ObfuscationDictionary, reuse tokens from a prior run

You only need this when you re-collect a slice for recovery on an obfuscated
run. You add `-ObfuscationDictionary <path>` to the recovery command, alongside
`-Obfuscate` and whatever you are re-collecting (for example `-Service`), pointing
it at the original run's `ObfuscationDictionary_*.json`:

```powershell
./ResourceInventory.ps1 -TenantID <tenant-id> -SubscriptionID <sub-id> -Obfuscate `
    -ObfuscationDictionary "<original run folder>\ObfuscationDictionary_<stamp>.json" `
    -Service <FailedService> -SkipMetrics -SkipConsumption
```

Why it matters: obfuscation tokens are random per run. If a recovery run made
fresh tokens, the recovered rows would not line up with the rest of the original
bundle when you merge them back. Seeding from the original dictionary makes the
same real value produce the same `prod_` or `nonprod_` token it had before, so
the merged result stays consistent. New values that were not in the seed still
get fresh tokens, so you are extending the map, not breaking it.

You do not need this on a normal first full run (there is nothing to line up with
yet), and you do not need it at all on non-obfuscated runs.

Note: the dictionary is local only and is never put in the shared ZIP. Use the
copy in the original run's output folder on your machine.

## Merge-RecoveryData, splice a repair run back in

`Merge-RecoveryData` lives in `Functions/RecoveryMerge.Functions.ps1`.
Dot-source the file, then call the function. It takes the incomplete bundle (the
"gap" bundle) and the repair run's bundle, and produces one clean rebuilt
bundle: inventory JSON, consumption CSV, metrics JSON, a regenerated HTML report,
and a fresh ZIP.

```powershell
. ./Functions/RecoveryMerge.Functions.ps1
Merge-RecoveryData `
    -GapBundlePath      "<incomplete run's folder>" `
    -RecoveryBundlePath "<repair run's folder>" `
    -OutputPath         "<new empty folder>" `
    [-Service <name[,name...]>] `
    [-RecoverConsumption] `
    [-RecoverMetrics]
```

It repairs three independent things, each taken from the repair bundle:

| What | Switch | If you omit the switch |
|------|--------|------------------------|
| Inventory service(s) | `-Service` (default: every service in the repair inventory) | spliced in |
| Consumption CSV | `-RecoverConsumption` | kept from the gap bundle |
| Metrics file(s) | `-RecoverMetrics` | kept from the gap bundle |

How it behaves:

- The inventory splice adds or replaces the named service(s) in the gap
  inventory. If you name a service with `-Service` that is not in the repair
  inventory, it stops with an error instead of quietly dropping it.
- `-RecoverConsumption` and `-RecoverMetrics` replace those whole files with the
  repair bundle's copies (metrics files are renamed to match the output bundle,
  keeping their batch suffixes). Each stops with an error if the repair bundle
  does not have the file. Without the switch, the gap bundle's copy is carried
  forward unchanged.
- The result object reports `MergedServiceKeys`, `ConsumptionSource` (gap or
  recovery), and `MetricsSource` (gap or recovery), so you can confirm what
  happened.
- The obfuscation dictionaries are merged too (local only, never zipped).

## Worked recovery examples

The pattern is always the same: re-collect the missing slice with the original
dictionary as the seed, then merge it back.

### One inventory collector failed

Symptom: the run summary shows a collector failure, and that service is present
but empty in the report.

```powershell
# 1. Re-collect just that service, seeded from the original run's dictionary
./ResourceInventory.ps1 -TenantID <tenant-id> -SubscriptionID <sub-id> -Obfuscate `
    -ObfuscationDictionary "<original run folder>\ObfuscationDictionary_<stamp>.json" `
    -Service <FailedService> -SkipMetrics -SkipConsumption

# 2. Splice it back into the original bundle
. ./Functions/RecoveryMerge.Functions.ps1
Merge-RecoveryData `
    -GapBundlePath      "<original run folder>" `
    -RecoveryBundlePath "<step 1 folder>" `
    -OutputPath         "<new folder>"
```

### A subscription's consumption pull was interrupted

Symptom: the billing sheet is short, and the diagnostics log shows where the
consumption pull stopped.

```powershell
# 1. Re-run the subscription with consumption on (no -SkipConsumption)
./ResourceInventory.ps1 -TenantID <tenant-id> -SubscriptionID <sub-id> -Obfuscate `
    -ObfuscationDictionary "<original run folder>\ObfuscationDictionary_<stamp>.json" `
    -SkipMetrics

# 2. Merge only the consumption back in
. ./Functions/RecoveryMerge.Functions.ps1
Merge-RecoveryData `
    -GapBundlePath      "<original run folder>" `
    -RecoveryBundlePath "<step 1 folder>" `
    -OutputPath         "<new folder>" `
    -RecoverConsumption
```

See also consumption-data.md, "Recovering from a consumption crash".

### A failed collector and interrupted billing together

```powershell
# 1. Re-run with the failed service collected, and consumption and metrics on
./ResourceInventory.ps1 -TenantID <tenant-id> -SubscriptionID <sub-id> -Obfuscate `
    -ObfuscationDictionary "<original run folder>\ObfuscationDictionary_<stamp>.json" `
    -Service <FailedService>

# 2. Merge all three back in
. ./Functions/RecoveryMerge.Functions.ps1
Merge-RecoveryData `
    -GapBundlePath      "<original run folder>" `
    -RecoveryBundlePath "<step 1 folder>" `
    -OutputPath         "<new folder>" `
    -Service <FailedService> -RecoverConsumption -RecoverMetrics
```

## Diagnostics logs

Two logs help you see what failed and where.

`DebugLog_<ReportName>_<timestamp>.log`
- The full local debug log: per-collector start, finish, and failure lines, plus
  the metrics-phase detail that used to scroll past on the terminal.
- Local only. It is never added to the ZIP, because it can contain real names and
  raw error text.

`Diagnostics_<ReportName>_<timestamp>.log`
- A shareable, scrubbed, readable log. It is built on `-Obfuscate` runs and is
  included in the ZIP.
- Subscriptions appear as tokens and identifiers are masked. It lists phase
  timings and one line per health issue: collector failures, metrics auth skips,
  and consumption failures. For consumption it records exactly where a pull
  stopped (`PageAtFailure` and `RecordsCollected`), so a short billing sheet is
  obvious instead of something you have to guess at.
- It is a plain `.log`, not `.json`, on purpose, so the ingestion pipeline treats
  it as an attachment and not as report data.

If a subscription is not listed under any failure heading, that phase finished
cleanly for it.

## Reveal.ps1, turn masked reports back into real values

`Reveal.ps1` converts an obfuscated report back to real values for the fields you
choose. It has two modes.

```powershell
# Single report
./Reveal.ps1 -InputZip <zip> [-DictionaryPath <json>] [-Fields ResourceGroup,Subscription] [-All]

# Every subscription under a folder
./Reveal.ps1 [-InventoryRoot <dir>] [-Resume]
```

The all-subscriptions mode walks each per-subscription folder, pairs each masked
report with the dictionary next to it, reveals them, and consolidates the results
into one outer ZIP.

Two features matter when you are recovering a large run:

- Per-folder 20-minute timeout. A folder that would otherwise stall the whole
  batch (a huge or malformed zip) is abandoned after 20 minutes, recorded as a
  timeout, and the run moves on to the next folder.
- `-Resume`. Re-running against the same staging folder skips the folders already
  revealed, so you do not redo finished work, and you move past a folder that
  stalled before.

To diagnose a folder that timed out, reveal it on its own in single-report mode
to see the underlying error.

---

Related: consumption-data.md, and the main README.
