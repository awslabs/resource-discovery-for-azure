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
#   7. skipstorage      - -SkipStorageMetrics: asserts no Storage Account metrics
#   8. skipdisk         - -SkipDiskMetrics: asserts no Managed Disk metrics
#   9. metricinterval   - -MetricsIntervalMinutes 60: asserts the VM/SQL sampled
#                         series carry the 60-min grain
#  10. recovery         - LIVE end-to-end recovery workflow: generate an obfuscated
#                         scoped "gap" bundle, re-collect one populated service
#                         seeded with the gap dictionary, splice with
#                         Merge-RecoveryData, then run the structural + obfuscation
#                         suite against the merged bundle. Proves the operator
#                         recovery path yields a server-valid, PII-clean zip against
#                         REAL collector output (RecoveryMerge.Tests.ps1 covers the
#                         splice mechanics offline; this covers it live). Self-skips
#                         if the subscription has no records in the scoped services.
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
    [string[]] $Scenarios = @('default', 'obfuscate', 'skipboth', 'skipmetrics', 'skipconsumption', 'service', 'skipstorage', 'skipdisk', 'metricinterval', 'recovery'),
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
    # Opt-in metric-volume controls. Each runs the structural suite (proving the
    # flag produces a valid, schema-correct zip) plus MetricsVolumeControls.Tests.ps1,
    # which reads the per-scenario TEST_EXPECT_* env vars set below to assert the
    # flag's specific effect (no Storage Account / no Managed Disk metrics, or the
    # VM/SQL sampled series at the requested grain).
    'skipstorage'     = @{ Args = @{ SkipStorageMetrics = $true }; Tests = ($StructuralTests + @('MetricsVolumeControls.Tests.ps1')) }
    'skipdisk'        = @{ Args = @{ SkipDiskMetrics = $true }; Tests = ($StructuralTests + @('MetricsVolumeControls.Tests.ps1')) }
    'metricinterval'  = @{ Args = @{ MetricsIntervalMinutes = 60 }; Tests = ($StructuralTests + @('MetricsVolumeControls.Tests.ps1')) }
    # Live recovery workflow. It does NOT fit the one-generation-per-scenario
    # shape (it needs two generations + a Merge-RecoveryData splice), so it is
    # handled by a dedicated self-contained branch at the top of the loop rather
    # than the shared generation path below. The merged bundle is obfuscated, so
    # it is validated with the same structural + obfuscation suite as 'obfuscate'.
    'recovery'        = @{ Recovery = $true; Tests = ($StructuralTests + $ObfuscationTests) }
}

# -------------------------------------------------------------------------
# Recovery-scenario generator. Produces the LIVE gap + seeded-recovery bundles
# and splices them with Merge-RecoveryData, returning the merged (obfuscated)
# bundle so the loop can run the obfuscation/structural suite against it.
#
# Returns a hashtable:
#   @{ Skip = $true;  Reason = <string> }                      # nothing to recover
#   @{ Skip = $false; Zip = <FileInfo>; Dict = <FileInfo>; Recovered = <key> }
#
# Both generations are collector-scoped and skip metrics/consumption: the
# recovery workflow is about the INVENTORY splice, so this keeps the two extra
# generations fast. The recovery run is seeded with the gap bundle's dictionary
# (-ObfuscationDictionary) so its tokens match the gap exactly - the guarantee
# Merge-RecoveryData relies on. Fails loud if the splice does not land the key.
# -------------------------------------------------------------------------
function New-RecoveryMergedBundle
{
    param(
        [Parameter(Mandatory)][string]$InventoryPs1,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$TenantID,
        [Parameter(Mandatory)][string]$SubscriptionID,
        [Parameter(Mandatory)][string]$OutDir,
        [int]$MetricsLookbackDays = 2,
        [int]$ConcurrencyLimit = 6,
        [string[]]$GapServices = @('VirtualMachines', 'StorageAcc', 'VMDisk', 'PublicIP', 'AppServices')
    )

    $GapDir = Join-Path $OutDir 'gap'
    $RecoveryDir = Join-Path $OutDir 'recovery'
    $MergedDir = Join-Path $OutDir 'merged'

    # 1. Gap bundle: scoped, obfuscated. Metrics/consumption skipped for speed.
    & $InventoryPs1 -TenantID $TenantID -SubscriptionID $SubscriptionID -OutputDirectory $GapDir `
        -Service $GapServices -Obfuscate -SkipMetrics -SkipConsumption `
        -MetricsLookbackDays $MetricsLookbackDays -ConcurrencyLimit $ConcurrencyLimit *>&1 | Out-Null

    $GapInvFile = Get-ChildItem $GapDir -Filter 'Inventory_*.json' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $GapDictFile = Get-ChildItem $GapDir -Filter 'ObfuscationDictionary_*.json' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $GapInvFile -or -not $GapDictFile)
    {
        # An empty subscription still emits an Inventory_*.json + dictionary, so a
        # MISSING one means the gap generation itself failed - a real failure, not
        # a legitimate "nothing to recover" skip. Fail loud (the caller's catch
        # records it as a failure); reserve Skip for the genuine no-records case.
        throw 'recovery scenario: gap generation produced no Inventory_*.json / ObfuscationDictionary_*.json (generation likely failed).'
    }

    # 2. Pick the recovery target: the first scoped service key that actually has
    #    records in the gap inventory. None -> nothing to recover here, so skip.
    $GapInv = Get-Content -Path $GapInvFile.FullName -Raw | ConvertFrom-Json
    $Populated = @($GapServices | Where-Object { ($GapInv.PSObject.Properties.Name -contains $_) -and (@($GapInv.$_).Count -gt 0) })
    if (@($Populated).Count -eq 0)
    {
        return @{ Skip = $true; Reason = 'no scoped service returned records in this subscription' }
    }
    $Recovered = $Populated[0]

    # 3. Recovery bundle: re-collect ONLY the target service, seeded with the gap
    #    dictionary so obfuscation tokens match exactly (the splice guarantee).
    & $InventoryPs1 -TenantID $TenantID -SubscriptionID $SubscriptionID -OutputDirectory $RecoveryDir `
        -Service $Recovered -Obfuscate -ObfuscationDictionary $GapDictFile.FullName -SkipMetrics -SkipConsumption `
        -MetricsLookbackDays $MetricsLookbackDays -ConcurrencyLimit $ConcurrencyLimit *>&1 | Out-Null

    # 4. Splice recovery -> gap and re-package.
    . (Join-Path $RepoRoot 'Functions/RecoveryMerge.Functions.ps1')
    $Merge = Merge-RecoveryData -GapBundlePath $GapDir -RecoveryBundlePath $RecoveryDir -OutputPath $MergedDir -Service $Recovered -WarningAction SilentlyContinue

    # 5. Splice guard (the offline suite covers this exhaustively; here we only
    #    fail loud if the LIVE splice did not land the recovered key).
    $MergedInv = Get-Content -Path $Merge.OutputInventory -Raw | ConvertFrom-Json
    if ($MergedInv.PSObject.Properties.Name -notcontains $Recovered)
    {
        throw ("recovery scenario: merged inventory is missing the recovered service key '{0}'." -f $Recovered)
    }

    $Zip = Get-ChildItem $MergedDir -Filter '*.zip' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $Dict = Get-ChildItem $MergedDir -Filter 'ObfuscationDictionary_*.json' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    return @{ Skip = $false; Zip = $Zip; Dict = $Dict; Recovered = $Recovered }
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

        # Recovery is a two-generation + Merge-RecoveryData workflow that does not
        # fit the shared single-generation path below, so handle it self-contained
        # and move on. The merged bundle is obfuscated, so it is validated with the
        # same structural + obfuscation suite as the 'obfuscate' scenario.
        if ($Scenario.Recovery)
        {
            New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
            $Rec = $null
            try
            {
                $Rec = New-RecoveryMergedBundle -InventoryPs1 $InventoryPs1 -RepoRoot $RepoRoot `
                    -TenantID $TenantID -SubscriptionID $SubscriptionID -OutDir $OutDir `
                    -MetricsLookbackDays $MetricsLookbackDays -ConcurrencyLimit $ConcurrencyLimit
            }
            catch
            {
                Write-Host ("  recovery generation error: {0}" -f $_.Exception.Message) -ForegroundColor Red
                $Summary += [pscustomobject]@{ Scenario = $name; ZipProduced = $false; Passed = 0; Failed = 1; Skipped = 0 }
                continue
            }

            if ($Rec.Skip)
            {
                Write-Host ("  SKIPPED: {0}." -f $Rec.Reason) -ForegroundColor Yellow
                $Summary += [pscustomobject]@{ Scenario = $name; ZipProduced = $false; Passed = 0; Failed = 0; Skipped = 1 }
                continue
            }
            if (-not $Rec.Zip)
            {
                # No usable zip: mirror the shared path's "no zip produced" sentinel (-1).
                Write-Host "  FAILED: recovery merge produced no zip." -ForegroundColor Red
                $Summary += [pscustomobject]@{ Scenario = $name; ZipProduced = $false; Passed = 0; Failed = -1; Skipped = 0 }
                continue
            }
            Write-Host ("  merged bundle produced (recovered '{0}'): {1:N0} bytes" -f $Rec.Recovered, $Rec.Zip.Length) -ForegroundColor Green

            # Point the obfuscation suite at the merged (obfuscated) bundle exactly
            # like the 'obfuscate' scenario: real sub id + user email for the
            # PII-leak scans, merged dictionary for the dictionary checks.
            $env:TEST_ZIP_PATH = $Rec.Zip.FullName
            $env:TEST_SUBSCRIPTION_ID = $SubscriptionID
            $env:TEST_USER_EMAIL = $Ctx.Account.Id
            if ($Rec.Dict) { $env:TEST_DICT_PATH = $Rec.Dict.FullName } else { Remove-Item Env:TEST_DICT_PATH -ErrorAction SilentlyContinue }
            Remove-Item Env:TEST_EXPECTED_SERVICES -ErrorAction SilentlyContinue
            # Recovery does not run MetricsVolumeControls, but clear its expectation
            # env vars anyway so no value left over from a prior scenario leaks in.
            Remove-Item Env:TEST_EXPECT_NO_STORAGE_METRICS   -ErrorAction SilentlyContinue
            Remove-Item Env:TEST_EXPECT_NO_DISK_METRICS      -ErrorAction SilentlyContinue
            Remove-Item Env:TEST_EXPECT_METRIC_GRAIN_MINUTES -ErrorAction SilentlyContinue

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

            # Same discovery-crash detection as the shared path: a container whose
            # body throws before any It runs leaves FailedCount at 0, so key off a
            # non-empty ErrorRecord instead.
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

            $Color = if ($Failed -eq 0) { 'Green' } else { 'Red' }
            Write-Host ("  Pester: Passed={0} Failed={1} Skipped={2}" -f $Passed, $Failed, $Skipped) -ForegroundColor $Color
            foreach ($t in $RealFailures) { Write-Host ("    FAIL: {0}" -f $t.ExpandedName) -ForegroundColor Red }

            $Summary += [pscustomobject]@{ Scenario = $name; ZipProduced = $true; Passed = $Passed; Failed = $Failed; Skipped = $Skipped }
            continue
        }

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

        # Metric-volume-control expectations consumed by MetricsVolumeControls.Tests.ps1.
        # Cleared first, then set only for the scenario that exercises each flag, so
        # the suite stays inert (all Skipped) for every other scenario.
        Remove-Item Env:TEST_EXPECT_NO_STORAGE_METRICS   -ErrorAction SilentlyContinue
        Remove-Item Env:TEST_EXPECT_NO_DISK_METRICS      -ErrorAction SilentlyContinue
        Remove-Item Env:TEST_EXPECT_METRIC_GRAIN_MINUTES -ErrorAction SilentlyContinue
        switch ($name)
        {
            'skipstorage' { $env:TEST_EXPECT_NO_STORAGE_METRICS = '1' }
            'skipdisk' { $env:TEST_EXPECT_NO_DISK_METRICS = '1' }
            'metricinterval' { $env:TEST_EXPECT_METRIC_GRAIN_MINUTES = [string]$Scenario.Args.MetricsIntervalMinutes }
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
    Remove-Item Env:TEST_EXPECT_NO_STORAGE_METRICS   -ErrorAction SilentlyContinue
    Remove-Item Env:TEST_EXPECT_NO_DISK_METRICS      -ErrorAction SilentlyContinue
    Remove-Item Env:TEST_EXPECT_METRIC_GRAIN_MINUTES -ErrorAction SilentlyContinue

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
