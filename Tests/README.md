# Obfuscation Tests

Pester tests to validate that the obfuscation feature works correctly and no PII leaks into output files.

## Prerequisites

- PowerShell 7+
- Pester module (v5+)

```powershell
Install-Module -Name Pester -Force -Scope CurrentUser
```

## How to Run

### 1. Generate a test report with obfuscation enabled

```powershell
pwsh ./ResourceInventory.ps1 -SubscriptionID <your-sub-id> -Obfuscate -Debug
```

### 2. Copy the output zip to the Tests folder

```powershell
cp /path/to/ResourcesReport_*.zip ./Tests/
```

### 3. Run the tests

```powershell
pwsh -Command "Invoke-Pester ./Tests/Obfuscation.Tests.ps1 -Output Detailed"
```

Or set environment variables to avoid editing the test file:

```powershell
$env:TEST_ZIP_PATH = "./Tests/ResourcesReport_202603301824.zip"
$env:TEST_SUBSCRIPTION_ID = "<your-subscription-id>"
$env:TEST_USER_EMAIL = "user@example.com"
pwsh -Command "Invoke-Pester ./Tests/Obfuscation.Tests.ps1 -Output Detailed"
```

### 4. Run skip-mode tests (no Azure needed)

Generate skip-mode output:
```powershell
pwsh ./ResourceInventory.ps1 -SubscriptionID <your-sub-id> -SkipMetrics -SkipConsumption -Obfuscate
```

Then run:
```powershell
$env:TEST_ZIP_PATH = "./Tests/ResourcesReport_skip.zip"
pwsh -Command "Invoke-Pester ./Tests/Obfuscation.Tests.ps1 -Output Detailed"
```

## Outer Bundle Membership Tests

`OuterBundleMembership.Tests.ps1` pins the member set of the consolidated
`AllSubscriptions_ResourcesReport_<timestamp>.zip` - the one file an operator sends.
Every other suite inspects an INNER per-subscription zip, so nothing else asserts
what the outer bundle may and may not contain.

Its most important assertions are the negative ones. The bundle must NEVER contain
the obfuscation dictionary (the de-obfuscation key), a transcript, a debug/error
log, resume state, a support-log bundle, or a nested `AllSubscriptions_*` bundle.
Those are the tell-tales of a hand-zipped `InventoryReports` folder, which is what
arrives when an operator cannot tell which file to send.

This is a **human/wrapper-run-only** suite: it is not part of
`Invoke-ScenarioMatrix.ps1`, because the matrix generates per-subscription zips via
`ResourceInventory.ps1` rather than full wrapper bundles.

```powershell
pwsh ./Run-AllSubscriptions.ps1 -TenantID <tenant> -Obfuscate
$env:TEST_ALLSUB_BUNDLE = "~/InventoryReports/AllSubscriptions_<timestamp>.zip"
pwsh -Command "Invoke-Pester ./Tests/OuterBundleMembership.Tests.ps1 -Output Detailed"
```

If `TEST_ALLSUB_BUNDLE` is unset the whole suite is **skipped** (not failed), so it
is safe inside a bare `Invoke-Pester ./Tests/` run. The VM-placement assertions
additionally skip when the tenant has no virtual machines, since no CSV is produced
in that case.

## Parallel-Streams Aggregation Tests

`ParallelStreamsAggregation.Tests.ps1` proves a parallel run produces structurally
equivalent output to a sequential run. It is the drift-prevention guard for the
`-ParallelStreams` feature.

### Generate the two-bundle fixture

Run the wrapper twice against the same tenant — once sequential, once parallel:

```powershell
# 1. Sequential reference
pwsh ./Run-AllSubscriptions.ps1 -TenantID <tenant> -Obfuscate -ParallelStreams 1

# 2. Parallel run (any N >= 2)
pwsh ./Run-AllSubscriptions.ps1 -TenantID <tenant> -Obfuscate -ParallelStreams 2
```

Both runs land an `AllSubscriptions_*.zip` bundle under `~/InventoryReports/`.

### Run the test

```powershell
$env:TEST_SEQUENTIAL_BUNDLE = "~/InventoryReports/AllSubscriptions_<seq-timestamp>.zip"
$env:TEST_PARALLEL_BUNDLE   = "~/InventoryReports/AllSubscriptions_<par-timestamp>.zip"
pwsh -Command "Invoke-Pester ./Tests/ParallelStreamsAggregation.Tests.ps1 -Output Detailed"
```

If either env var is unset the entire suite is **skipped** (not failed) so the
file is safe to include in `Invoke-Pester ./Tests/` runs that don't have a
fixture pair available.

### What it asserts

- Both bundles unpack to the same number of inner per-sub ZIPs
- Each inner ZIP contains HTML, Inventory JSON, Metrics JSON, Consumption CSV
- Total resource count matches between modes (no resource dropping)
- Per-sub set of populated resource types is identical
- Per-sub HTML service-section set is identical (one `service-section` per populated resource type)
- Inventory JSON top-level key set is identical
- Consumption record count matches exactly (queries are sub-scoped)
- Metrics record count matches within 5% (time-window queries can drift slightly)
- Obfuscation namespace is consistent across modes (catches a regression that
  silently disables `-Obfuscate` in one path)


## Scenario Matrix (standing regression protocol)

`Invoke-ScenarioMatrix.ps1` is the required regression run after **any** change
that could affect output (metrics, consumption, obfuscation, schema, packaging,
auth gating). It generates a fresh zip for each supported flag combination
against a live subscription and runs the applicable Pester tests against each.

### Scenarios

| Scenario | Flags | Tests run |
|---|---|---|
| `default` | metrics + consumption, no obfuscation | structural (schema, completeness, frontdoor) **+ live tenant reconciliation + schema-contract & linkage + metric-volume controls** (proves the storage capacity metric is absent unless opted into) |
| `obfuscate` | `-Obfuscate` (+ metrics + consumption) | structural **+** PII/obfuscation/prefix/dictionary **+ schema-contract & linkage** |
| `skipboth` | `-SkipMetrics -SkipConsumption` | structural |
| `skipmetrics` | `-SkipMetrics` | structural |
| `skipconsumption` | `-SkipConsumption` | structural |
| `service` | `-Service VirtualMachines -SkipMetrics -SkipConsumption` | collector scoping |
| `includestorage` | `-IncludeStorageMetrics` | structural **+** metric-volume controls (proves the opt-in turns the storage capacity metric ON) |
| `skipstorage` | `-SkipStorageMetrics` | structural **+** metric-volume controls |
| `skipdisk` | `-SkipDiskMetrics` | structural **+** metric-volume controls |
| `metricinterval` | `-MetricsIntervalMinutes 60` | structural **+** metric-volume controls |
| `recovery` | live recovery workflow (gap bundle, re-collect, `Merge-RecoveryData` splice) | structural **+** obfuscation **+** recovery-merge |

### Why PII tests only run on `obfuscate`

The PII-leak / obfuscation tests (DataIntegrity PII scan, OutputCompleteness
"no transcript/dictionary", Obfuscation, ProdNonprodPrefix, DictionaryValidation)
assume obfuscated input. On a **non-obfuscated** zip the raw subscription paths
and transcript are present *by design*, so those tests are EXPECTED to fail and
are therefore not run for non-obfuscated scenarios. Only obfuscated zips are ever
shared server-side, so this matches real usage.

### Live tenant reconciliation (`default` scenario)

`TenantReconciliation.Tests.ps1` cross-checks the **non-obfuscated** `default`
zip against the **live tenant** it was generated from, to catch a future change
that silently drops, duplicates, mangles, or mis-attributes resources. It
asserts:

- every inventory resource ID resolves to a real resource in the tenant
  (`Get-AzResource`) - no orphans/phantoms;
- all inventory IDs (and all consumption `ResourceId`s) belong to the run's
  subscription - no cross-subscription contamination;
- per-type **distinct** resource counts match the tenant for one-row-per-resource
  collectors (VMs, disks, storage accounts, public IPs, key vaults, SQL servers,
  Service Bus), and SQL user databases match with the system `master` DB excluded;
- those same sections contain no duplicate IDs.

Expected values are read **live from the tenant at runtime** (never hardcoded),
so it is tenant-portable. Because it needs a live Az session and real IDs, it is
the one suite that talks to Azure - and it **skips itself** (never fails) when
the zip is obfuscated, no live context exists, or the context can't see the
run's subscription. That keeps it safe inside an offline `Invoke-Pester ./Tests/`
or CI run; it only actually reconciles inside the `default` scenario (or when you
point `$env:TEST_ZIP_PATH` at a non-obfuscated zip with a matching live session).

### Schema contract & cross-dataset linkage (`default` + `obfuscate`)

`SchemaContract.Tests.ps1` is a **pure-output, drift-immune** gate (no Azure
calls) that protects the **server ingestion contract** and - above all - the
**cross-dataset linkage** that makes the three datasets usable together. The
owner's rule: Inventory, Metrics, and Consumption are *useless on their own*
unless they stay joinable via a common identity key
(`Inventory.ID` ↔ `Metrics.ID` ↔ `Consumption.ResourceId`). A field
rename/removal/emptying that breaks that join is silently dropped by the server
(`System.Text.Json` ignores unmapped members), so a parse-check or report render
won't catch it - only asserting the emitted zip against the contract does.

The pinned contract lives in `schema-contract.json` (data, separate from logic)
so the server-side owner can see/adjust the bound keys. It is deliberately
**narrow**: it pins only the identity/join-key fields of the server-bound
inventory sections (VirtualMachines, VMDisk, Databricks, PostgreSQLflexible,
MySQLflexible, SQLVM, SQLDB, SQLPOOL, SQLMI), the `AzureMetricRecord` identity
fields, and the Consumption CSV columns - **not** the long tail of descriptive
fields (many aren't server-bound yet), which stay free to evolve.

It asserts:

- **Tier 1 (schema):** every present server-bound inventory section carries the
  identity field *names* on every row (a per-row rename/removal guard) and a
  non-empty `ID`; metric rows carry their required field names and a non-empty
  `ID`; the consumption header carries every required column;
- **Tier 2 (linkage):** `Metrics.ID` resolves to `Inventory.ID` (the
  metrics↔inventory join), `Consumption.ResourceId` overlaps the inventory id
  space (the consumption↔inventory join), and under `-Obfuscate` the shared join
  keys are deterministic `prod_`/`nonprod_` tokens (same real resource → same
  token across all three datasets), never a raw ARM path.

Because it needs no Azure and is valid whether IDs are raw paths or tokens, it
runs as a hard gate in **both** the `default` and `obfuscate` scenarios. It
self-skips only when there is genuinely nothing to check (no zip, or a phase
suppressed by a `-Skip*` switch). Output-only limitation: it cannot distinguish
a *whole-section* rename from a subscription that legitimately has none of that
type, so an absent section is skipped, not failed - but Tier 2 stays
name-agnostic and still linkage-checks a renamed section's rows by their IDs.

### Run it

```powershell
# Auto-discover a subscription (prefers one with metric-eligible resources):
pwsh ./Tests/Invoke-ScenarioMatrix.ps1

# Pin a specific subscription / tenant:
pwsh ./Tests/Invoke-ScenarioMatrix.ps1 -SubscriptionID <id> -TenantID <id>

# Subset of scenarios:
pwsh ./Tests/Invoke-ScenarioMatrix.ps1 -Scenarios default,obfuscate

# Keep the generated zips for inspection (they contain REAL identifiers):
pwsh ./Tests/Invoke-ScenarioMatrix.ps1 -KeepOutput
```

Exit code is `0` only if every scenario passed its applicable tests, else `1`
(suitable for CI / a pre-merge gate). Generated zips are deleted automatically
unless `-KeepOutput` is passed, because non-obfuscated zips contain real
subscription identifiers.
