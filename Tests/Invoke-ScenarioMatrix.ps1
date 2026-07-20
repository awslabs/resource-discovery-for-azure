# Scenario Matrix Runner
# =============================================================================
# Generates a fresh output zip for each supported flag combination against a
# live Azure subscription, then runs the Pester suite against each zip with the
# CORRECT expectations per scenario. This is the standing regression protocol:
# run it after any change that could affect output (metrics, consumption,
# obfuscation, schema, packaging).
#
# Scenarios:
#   1. default          - metrics + consumption, NO obfuscation (compat baseline)
#   2. obfuscate        - metrics + consumption, -Obfuscate (server-bound shape)
#   3. skipboth         - -SkipMetrics -SkipConsumption
#   4. skipmetrics      - -SkipMetrics only
#   5. skipconsumption  - -SkipConsumption only
#   6. service          - -Service VirtualMachines (collector scoping): asserts the
#                         inventory contains ONLY the requested service(s)
#
# IMPORTANT - obfuscation vs PII tests:
#   The PII-leak / obfuscation tests (DataIntegrity PII scan, OutputCompleteness
#   "no transcript/dictionary", Obfuscation, ProdNonprodPrefix, DictionaryValidation)
#   ONLY make sense on an -Obfuscate run. On a non-obfuscated zip the raw
#   subscription paths/transcript ARE present by design, so those tests are
#   EXPECTED to fail and are therefore NOT run for non-obfuscated scenarios.
#   Only obfuscated zips are ever shared server-side, so this matches reality.
#
# This script contains NO customer data. Tenant/subscription are supplied as
# parameters or auto-discovered from the current Az context at runtime.
#
# Usage:
#   pwsh ./Tests/Invoke-ScenarioMatrix.ps1                      # auto-discover sub
#   pwsh ./Tests/Invoke-ScenarioMatrix.ps1 -SubscriptionID <id> -TenantID <id>
#   pwsh ./Tests/Invoke-ScenarioMatrix.ps1 -Scenarios default,obfuscate
#   pwsh ./Tests/Invoke-ScenarioMatrix.ps1 -KeepOutput        # don't auto-clean zips
# =============================================================================

[CmdletBinding()]
param(
    [string]   $SubscriptionID,
    [string]   $TenantID,
    [string[]] $Scenarios = @('default', 'obfuscate', 'skipboth', 'skipmetrics', 'skipconsumption', 'service'),
    [int]      $MetricsLookbackDays = 2,
    [int]      $ConcurrencyLimit = 6,
    [switch]   $KeepOutput
)

$ErrorActionPreference = 'Stop'

# Normalize $Scenarios. Invoking via `pwsh -File ... -Scenarios a,b` passes the
# whole thing as the single string 'a,b' (unlike -Command / interactive, which
# bind it as a 2-element array), which previously caused "Unknown scenario
# 'a,b'". Split any comma-containing element, trim, and drop empties so the
# runner behaves identically regardless of how it's launched.
$Scenarios = @($Scenarios | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

$RepoRoot = Split-Path $PSScriptRoot -Parent
$InventoryPs1 = Join-Path $RepoRoot 'ResourceInventory.ps1'
$WorkRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ScenarioMatrix_" + (Get-Date -Format 'yyyyMMdd_HHmmss'))

if (-not (Test-Path $InventoryPs1)) { throw "Cannot find ResourceInventory.ps1 at $InventoryPs1" }
if (-not (Get-Module -ListAvailable Pester | Where-Object { $_.Version.Major -ge 5 }))
{
    throw "Pester v5+ is required. Install-Module Pester -Force -Scope CurrentUser"
}

# -------------------------------------------------------------------------
# Resolve subscription + tenant (auto-discover the first enabled sub that has
# metric-eligible resources, so the schema tests actually see metric data).
# -------------------------------------------------------------------------
$Ctx = Get-AzContext -ErrorAction SilentlyContinue
if ($null -eq $Ctx -or $null -eq $Ctx.Account)
{
    throw "No Azure context. Run Connect-AzAccount first."
}
if ([string]::IsNullOrEmpty($TenantID)) { $TenantID = $Ctx.Tenant.Id }

if ([string]::IsNullOrEmpty($SubscriptionID))
{
    Write-Host "Auto-discovering a subscription with metric-eligible resources..." -ForegroundColor Cyan
    $MetricTypes = @(
        'microsoft.compute/virtualmachines'
        'microsoft.storage/storageaccounts'
        'microsoft.sql/servers/databases'
        'microsoft.compute/virtualmachinescalesets'
        'microsoft.documentdb/databaseaccounts'
        'microsoft.web/sites'
    )
    $Best = $null; $BestCount = -1
    foreach ($s in @(Get-AzSubscription -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Enabled' }))
    {
        $null = Set-AzContext -Subscription $s.Id -ErrorAction SilentlyContinue
        $C = 0
        foreach ($t in $MetricTypes) { try { $C += @(Get-AzResource -ResourceType $t -ErrorAction SilentlyContinue).Count } catch {} }
        if ($C -gt $BestCount) { $BestCount = $C; $Best = $s }
        if ($C -gt 0) { break }
    }
    if ($null -eq $Best) { throw "No enabled subscription found in the current context." }
    $SubscriptionID = $Best.Id
    Write-Host ("Selected a subscription with {0} metric-eligible resource(s) (id withheld)." -f $BestCount) -ForegroundColor Cyan
}

# -------------------------------------------------------------------------
# Scenario definitions: inventory flags + which test files apply.
# -------------------------------------------------------------------------
$StructuralTests = @(
    'ReportSchema.Tests.ps1'
    'OutputCompleteness.Tests.ps1'
    'Frontdoor.Tests.ps1'
)
# Two assertions inside OutputCompleteness.Tests.ps1 are actually PII/obfuscation
# safety checks, NOT structural ones: a non-obfuscated zip deliberately includes
# the transcript .txt (see ResourceInventory.ps1 ~line 1514), so these correctly
# fail on non-obfuscated output. Exclude them by name for non-obfuscated
# scenarios; they still run (and must pass) under the obfuscate scenario.
$NonObfuscatedExcludedTests = @(
    'Should not contain any unexpected file types'
    'Should not contain dictionary or transcript files'
)
# PII / obfuscation tests only valid for -Obfuscate runs.
$ObfuscationTests = @(
    'DataIntegrity.Tests.ps1'
    'ReferentialIntegrity.Tests.ps1'
    'Obfuscation.Tests.ps1'
    'ProdNonprodPrefix.Tests.ps1'
    'DictionaryValidation.Tests.ps1'
)

$Catalog = @{
    'default'         = @{ Args = @{}; Tests = $StructuralTests }
    'obfuscate'       = @{ Args = @{ Obfuscate = $true }; Tests = ($StructuralTests + $ObfuscationTests) }
    'skipboth'        = @{ Args = @{ SkipMetrics = $true; SkipConsumption = $true }; Tests = $StructuralTests }
    'skipmetrics'     = @{ Args = @{ SkipMetrics = $true }; Tests = $StructuralTests }
    'skipconsumption' = @{ Args = @{ SkipConsumption = $true }; Tests = $StructuralTests }
    # Collector scoping. -SkipMetrics/-SkipConsumption keep it fast (the assertion
    # is purely about WHICH resource types appear, not metrics/consumption). The
    # ServiceScope suite reads $env:TEST_EXPECTED_SERVICES (set below) and asserts
    # the inventory contains ONLY the requested collector(s) + metadata.
    'service'         = @{ Args = @{ Service = @('VirtualMachines'); SkipMetrics = $true; SkipConsumption = $true }; Tests = @('ServiceScope.Tests.ps1') }
}

New-Item -ItemType Directory -Path $WorkRoot -Force | Out-Null
$Summary = @()

try
{
    foreach ($name in $Scenarios)
    {
        if (-not $Catalog.ContainsKey($name))
        {
            Write-Host ("Unknown scenario '{0}' - skipping. Valid: {1}" -f $name, ($Catalog.Keys -join ', ')) -ForegroundColor Yellow
            continue
        }

        $Scenario = $Catalog[$name]
        $OutDir = Join-Path $WorkRoot $name
        Write-Host ""
        Write-Host ("======== SCENARIO: {0} ========" -f $name) -ForegroundColor Magenta

        $Splat = @{
            TenantID            = $TenantID
            SubscriptionID      = $SubscriptionID
            OutputDirectory     = $OutDir
            MetricsLookbackDays = $MetricsLookbackDays
            ConcurrencyLimit    = $ConcurrencyLimit
        }
        foreach ($k in $Scenario.Args.Keys) { $Splat[$k] = $Scenario.Args[$k] }

        try { & $InventoryPs1 @Splat *>&1 | Out-Null }
        catch { Write-Host ("  generation error: {0}" -f $_.Exception.Message) -ForegroundColor Red }

        $Zip = Get-ChildItem $OutDir -Filter 'ResourcesReport_*.zip' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1

        if (-not $Zip)
        {
            Write-Host "  FAILED: no output zip produced." -ForegroundColor Red
            $Summary += [pscustomobject]@{ Scenario = $name; ZipProduced = $false; Passed = 0; Failed = -1; Skipped = 0 }
            continue
        }
        Write-Host ("  zip produced: {0:N0} bytes" -f $Zip.Length) -ForegroundColor Green

        # Run the applicable tests against this zip.
        $env:TEST_ZIP_PATH = $Zip.FullName
        if ($name -eq 'obfuscate')
        {
            $env:TEST_SUBSCRIPTION_ID = $SubscriptionID
            $env:TEST_USER_EMAIL = $Ctx.Account.Id
            $Dict = Get-ChildItem $OutDir -Filter 'ObfuscationDictionary_*.json' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($Dict) { $env:TEST_DICT_PATH = $Dict.FullName } else { Remove-Item Env:TEST_DICT_PATH -ErrorAction SilentlyContinue }
        }
        else
        {
            Remove-Item Env:TEST_SUBSCRIPTION_ID -ErrorAction SilentlyContinue
            Remove-Item Env:TEST_USER_EMAIL      -ErrorAction SilentlyContinue
            Remove-Item Env:TEST_DICT_PATH       -ErrorAction SilentlyContinue
        }

        # The service scenario drives ServiceScope.Tests.ps1 with the exact
        # collector(s) it requested; clear it otherwise so the suite stays inert.
        if ($name -eq 'service')
        {
            $env:TEST_EXPECTED_SERVICES = ($Scenario.Args.Service -join ',')
        }
        else
        {
            Remove-Item Env:TEST_EXPECTED_SERVICES -ErrorAction SilentlyContinue
        }

        $TestPaths = $Scenario.Tests | ForEach-Object { Join-Path $PSScriptRoot $_ }
        $Cfg = New-PesterConfiguration
        $Cfg.Run.Path = $TestPaths
        $Cfg.Run.PassThru = $true
        $Cfg.Output.Verbosity = 'None'
        $Res = Invoke-Pester -Configuration $Cfg

        $Passed = $Res.PassedCount
        $Failed = $Res.FailedCount
        $Skipped = $Res.SkippedCount
        $RealFailures = @($Res.Failed)

        # A container (test file) can fail at DISCOVERY time - e.g. code in a
        # Describe body throwing before any It runs. The assertions in that
        # block never execute, so FailedCount stays 0 and the scenario would
        # otherwise look green while a whole block is silently broken.
        #
        # The reliable signal for a discovery problem is a non-empty
        # $container.ErrorRecord. This is distinct from a RUNTIME test failure:
        #   - runtime failure  -> Container.Result='Failed', ErrorRecord empty
        #                         (already counted in FailedCount / handled by
        #                          the reclassification below)
        #   - discovery crash  -> ErrorRecord populated, even when other blocks
        #                         in the same file ran and the container's own
        #                         Result reports 'Passed' (a partial crash)
        # So we key off ErrorRecord, NOT Result, and NOT TotalCount (a partial
        # crash still executes some tests, so TotalCount > 0).
        $DiscoveryFailures = @($Res.Containers | Where-Object { @($_.ErrorRecord).Count -gt 0 })
        if ($DiscoveryFailures.Count -gt 0)
        {
            $Failed = $Failed + $DiscoveryFailures.Count
            foreach ($C in $DiscoveryFailures)
            {
                $ItemName = if ($C.Item) { $C.Item.ToString() } else { 'unknown container' }
                $ErrText = ($C.ErrorRecord | Select-Object -First 1)
                Write-Host ("    CONTAINER FAILED (discovery): {0} - {1}" -f $ItemName, $ErrText) -ForegroundColor Red
            }
        }

        # On non-obfuscated scenarios, two assertions in OutputCompleteness are
        # actually obfuscation-safety checks (a non-obfuscated zip deliberately
        # includes the transcript .txt - see ResourceInventory.ps1 ~line 1514).
        # Pester 5.7 has no ExcludeFullName, so reclassify them post-run: they
        # are EXPECTED to fail here and must not count against the scenario.
        if ($name -ne 'obfuscate')
        {
            $Reclassified = @($RealFailures | Where-Object { $_.Name -in $NonObfuscatedExcludedTests })
            if ($Reclassified.Count -gt 0)
            {
                $Failed = $Failed - $Reclassified.Count
                $Skipped = $Skipped + $Reclassified.Count
                $RealFailures = @($RealFailures | Where-Object { $_.Name -notin $NonObfuscatedExcludedTests })
                Write-Host ("  (reclassified {0} obfuscation-only assertion(s) as expected-skip for non-obfuscated scenario)" -f $Reclassified.Count) -ForegroundColor DarkGray
            }
        }

        $Color = if ($Failed -eq 0) { 'Green' } else { 'Red' }
        Write-Host ("  Pester: Passed={0} Failed={1} Skipped={2}" -f $Passed, $Failed, $Skipped) -ForegroundColor $Color
        foreach ($t in $RealFailures) { Write-Host ("    FAIL: {0}" -f $t.ExpandedName) -ForegroundColor Red }

        $Summary += [pscustomobject]@{
            Scenario    = $name
            ZipProduced = $true
            Passed      = $Passed
            Failed      = $Failed
            Skipped     = $Skipped
        }
    }
}
finally
{
    Remove-Item Env:TEST_ZIP_PATH            -ErrorAction SilentlyContinue
    Remove-Item Env:TEST_SUBSCRIPTION_ID     -ErrorAction SilentlyContinue
    Remove-Item Env:TEST_USER_EMAIL          -ErrorAction SilentlyContinue
    Remove-Item Env:TEST_DICT_PATH           -ErrorAction SilentlyContinue
    Remove-Item Env:TEST_EXPECTED_SERVICES   -ErrorAction SilentlyContinue

    if (-not $KeepOutput)
    {
        # The generated zips contain REAL subscription identifiers (non-obfuscated
        # scenarios especially). Remove them unless the caller asked to keep them.
        try { Remove-Item -Path $WorkRoot -Recurse -Force -ErrorAction SilentlyContinue }
        catch { Write-Host ("  cleanup warning: {0}" -f $_.Exception.Message) -ForegroundColor Yellow }
    }
    else
    {
        Write-Host ("`nOutput kept at: {0} (contains real identifiers - delete when done)." -f $WorkRoot) -ForegroundColor Yellow
    }
}

# -------------------------------------------------------------------------
# Final report + exit code.
# -------------------------------------------------------------------------
Write-Host ""
Write-Host "================ SCENARIO MATRIX SUMMARY ================" -ForegroundColor Cyan
$Summary | Format-Table -AutoSize | Out-String | Write-Host

# Guard against a vacuous "pass": if every requested scenario name was invalid
# (e.g. -Scenarios was passed as a single unsplit "a,b,c" string by a caller's
# shell), the loop above skips all of them via `continue` and $summary is never
# populated. An empty collection has zero failures by definition, which would
# otherwise print "All scenarios passed" and exit 0 despite nothing running.
if ($Summary.Count -eq 0)
{
    Write-Host ("No scenarios were executed (requested: {0}). Valid names: {1}" -f ($Scenarios -join ', '), ($Catalog.Keys -join ', ')) -ForegroundColor Red
    exit 1
}

$TotalFailed = ($Summary | Where-Object { $_.Failed -ne 0 }).Count
if ($TotalFailed -eq 0)
{
    Write-Host ("All {0} scenario(s) passed their applicable tests." -f $Summary.Count) -ForegroundColor Green
    exit 0
}
else
{
    Write-Host ("{0} scenario(s) had failures - review above." -f $TotalFailed) -ForegroundColor Red
    exit 1
}
