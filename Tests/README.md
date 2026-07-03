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
- Each inner ZIP contains XLSX, Inventory JSON, Metrics JSON, Consumption CSV
- Total resource count matches between modes (no resource dropping)
- Per-sub set of populated resource types is identical
- Per-sub XLSX worksheet name set is identical (Overview always present)
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
| `default` | metrics + consumption, no obfuscation | structural (schema, completeness, frontdoor) |
| `obfuscate` | `-Obfuscate` (+ metrics + consumption) | structural **+** PII/obfuscation/prefix/dictionary |
| `skipboth` | `-SkipMetrics -SkipConsumption` | structural |
| `skipmetrics` | `-SkipMetrics` | structural |
| `skipconsumption` | `-SkipConsumption` | structural |

### Why PII tests only run on `obfuscate`

The PII-leak / obfuscation tests (DataIntegrity PII scan, OutputCompleteness
"no transcript/dictionary", Obfuscation, ProdNonprodPrefix, DictionaryValidation)
assume obfuscated input. On a **non-obfuscated** zip the raw subscription paths
and transcript are present *by design*, so those tests are EXPECTED to fail and
are therefore not run for non-obfuscated scenarios. Only obfuscated zips are ever
shared server-side, so this matches real usage.

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
