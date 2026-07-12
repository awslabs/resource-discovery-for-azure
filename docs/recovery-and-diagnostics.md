# Recovery & diagnostics features

This document covers the targeted-collection, recovery, and diagnostics features
that are **not** described in the main README. They exist so that when a large
multi-subscription run has a partial failure (one collector errors, or a
subscription's consumption/metrics pull is interrupted), you can repair just the
missing piece instead of re-running the whole tenant.

Applies to build **3.2.2** and later.

Contents:
- [The problem these solve](#the-problem-these-solve)
- [`-Service` — targeted collector selection](#-service--targeted-collector-selection)
- [`-ObfuscationDictionary` — seed tokens from a prior run](#-obfuscationdictionary--seed-tokens-from-a-prior-run)
- [`Merge-RecoveryData` — splice a recovery run back in](#merge-recoverydata--splice-a-recovery-run-back-in)
- [Recovery recipes](#recovery-recipes)
- [Diagnostics logs](#diagnostics-logs)
- [Reveal.ps1 — resilient un-masking](#revealps1--resilient-un-masking)

## The problem these solve

A full run can be long. When one part fails partway — a single collector throws
on a bad record, or a subscription's consumption/metrics pull hits a transient —
the report is produced but is **missing** that slice. Re-running the entire
tenant to recover one service or one subscription's billing is wasteful. These
features let you re-collect only the missing slice and splice it back into the
original bundle so the result looks like a clean first run.

## `-Service` — targeted collector selection

`ResourceInventory.ps1 -Service <name[,name...]>` runs **only** the named
service collectors instead of all of them. Names are the collector file base
names (e.g. `VirtualMachines`, `Streamanalytics`, `AKS`, `StorageAcc`); matching
is case-insensitive.

- Multiple names are accepted: `-Service Streamanalytics,AKS`.
- **Fail-loud:** if any explicitly named `-Service` value is not a real
  collector (a typo, or absent from a recovery inventory), the run stops with a
  clear error listing the unmatched name(s) and the valid ones — rather than
  silently collecting a subset.
- `-Service` scopes **inventory collection only**. The metrics and consumption
  phases are independent and still run for the whole subscription (governed by
  `-SkipMetrics` / `-SkipConsumption`).

This is the mechanism used to re-collect a single failed collector for recovery.

## `-ObfuscationDictionary` — seed tokens from a prior run

`ResourceInventory.ps1 -Obfuscate -ObfuscationDictionary <path>` preloads the
obfuscation maps from a previous run's `ObfuscationDictionary_*.json` so that
identical real values yield the **same** `prod_`/`nonprod_` tokens as that
earlier run.

This is what makes a scoped recovery run's output splice cleanly into the
earlier bundle: without it, each run mints fresh random tokens and the recovered
rows would not line up. New real values not present in the seed still get fresh
tokens, so determinism is *extended*, never broken.

The obfuscation pass runs over the **full** Resource Graph result set up front,
so a resource's token is present in the dictionary even if the collector that
would have processed it failed. That is why seeding a recovery run reproduces the
original tokens for the failed service's resources.

> The dictionary is **local-only** and never included in the shared ZIP. The
> recovery flow needs the copy from the original run's output folder on your
> machine.

## `Merge-RecoveryData` — splice a recovery run back in

Defined in `Functions/RecoveryMerge.Functions.ps1`. Dot-source the file, then
call the function. It takes an incomplete ("gap") bundle and a scoped recovery
run's bundle and produces one clean rebuilt bundle (inventory JSON, consumption
CSV, metrics JSON, regenerated HTML, fresh ZIP).

```powershell
. ./Functions/RecoveryMerge.Functions.ps1
Merge-RecoveryData `
    -GapBundlePath      "<incomplete run's folder>" `
    -RecoveryBundlePath "<scoped recovery run's folder>" `
    -OutputPath         "<new empty folder>" `
    [-Service <name[,name...]>] `
    [-RecoverConsumption] `
    [-RecoverMetrics]
```

It recovers **three independent dimensions**, each from the recovery bundle:

| Dimension | Control | Default |
|-----------|---------|---------|
| Inventory service key(s) | `-Service` (default: every service key the recovery inventory contains) | spliced in |
| Consumption CSV | `-RecoverConsumption` | **carried forward from the gap bundle** unless the switch is set |
| Metrics file(s) | `-RecoverMetrics` | **carried forward from the gap bundle** unless the switch is set |

Behaviour:

- **Inventory splice** adds/replaces the recovered service keys in the gap
  inventory. If `-Service` explicitly names a key that is not in the recovery
  inventory (total or partial miss), it **fails loud** rather than silently
  dropping it.
- **`-RecoverConsumption` / `-RecoverMetrics`** whole-file replace those files
  with the recovery bundle's copies (metrics are rebased to the output bundle
  name, batch suffixes preserved). Each fails loud if the recovery bundle lacks
  the file. Without the switch, the gap bundle's copy is carried forward
  byte-for-byte (the default, unchanged behaviour).
- The return object reports `MergedServiceKeys`, `ConsumptionSource`
  (`gap`/`recovery`), and `MetricsSource` (`gap`/`recovery`) for confirmation.
- The obfuscation dictionaries are merged (local-only, never zipped).

## Recovery recipes

### A single inventory collector failed on a subscription

Symptom: the run summary shows a collector failure for a subscription; that
service's key is present but **empty** in the report.

```powershell
# 1. Re-collect just that service, seeded from the original dictionary
./ResourceInventory.ps1 -TenantID <t> -SubscriptionID <s> -Obfuscate `
    -ObfuscationDictionary "<original dict for that sub>" `
    -Service <FailedService> -SkipMetrics -SkipConsumption

# 2. Splice it back in
. ./Functions/RecoveryMerge.Functions.ps1
Merge-RecoveryData -GapBundlePath "<original folder>" `
    -RecoveryBundlePath "<step 1 folder>" -OutputPath "<new folder>"
```

### A subscription's consumption pull was interrupted

See [consumption-data.md → Recovering from a consumption
crash](consumption-data.md#recovering-from-a-consumption-crash). In short:
re-run the subscription with consumption enabled (drop `-SkipConsumption`), then
`Merge-RecoveryData … -RecoverConsumption`.

### Both at once

Re-run the subscription with the failed inventory service collected **and**
consumption/metrics enabled, then merge with the matching switches, e.g.
`Merge-RecoveryData -Service <FailedService> -RecoverConsumption -RecoverMetrics …`.

## Diagnostics logs

Two logs help diagnose partial failures (also summarised in the README):

- **`DebugLog_<ReportName>_<timestamp>.log`** — consolidated **local** debug log:
  per-collector heartbeat (start/finish/failure) plus metrics-phase diagnostics
  that previously scrolled past on the terminal. **Local-only**, never added to
  the ZIP (it can contain real names and raw exception text).
- **`Diagnostics_<ReportName>_<timestamp>.log`** — **shareable**, human-readable,
  scrubbed diagnostics. Built on `-Obfuscate` runs and **included in the ZIP**.
  Subscriptions appear as obfuscated tokens; identifiers are masked. It lists
  phase timings and one-line health entries for collector failures, metrics
  auth-skips, and **consumption failures — including exactly where a consumption
  pull stopped** (`PageAtFailure` / `RecordsCollected`), so a truncated billing
  sheet is obvious rather than inferred. It is a plain `.log` (not `.json`) on
  purpose so the ingestion pipeline treats it as an attachment, not report data.

If a subscription is **not** listed under a failure heading, that dimension
completed cleanly.

## Reveal.ps1 — resilient un-masking

`Reveal.ps1` turns an obfuscated report back into real values for the fields you
choose. It runs in two modes:

- **Single report:** `./Reveal.ps1 -InputZip <zip> [-DictionaryPath <json>]
  [-Fields ResourceGroup,Subscription,...] [-All]`
- **All subscriptions:** `./Reveal.ps1 [-InventoryRoot <dir>] [-Resume]` — walks
  every per-subscription folder, pairs each obfuscated report with the
  dictionary next to it, reveals each, and consolidates them into one outer ZIP.

Large-run resilience (relevant to recovery):

- **Per-folder 20-minute timeout.** A pathological folder (huge or malformed
  zip) that would otherwise stall the batch is abandoned after 20 minutes,
  recorded as a timeout failure, and the run continues with the next folder.
- **`-Resume`.** Re-runs against the same staging directory and skips folders
  already revealed — so a resumed run doesn't redo completed work and advances
  past a folder that previously stalled.

To diagnose a folder that timed out, reveal it on its own in single-report mode
to surface the underlying error.

---

Related: [Consumption data](consumption-data.md) · main [README](../README.md).
