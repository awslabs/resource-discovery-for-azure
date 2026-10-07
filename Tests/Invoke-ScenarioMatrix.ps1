# Scenario Matrix Runner: generates a fresh output zip for each supported flag combination against a LIVE Azure subscription, then runs the Pester suite against each zip with the correct per-scenario expectations. Standing regression protocol - run after any change affecting output (metrics, consumption, obfuscation, schema, packaging). Contains NO customer data; tenant/subscription come from parameters or the current Az context. Usage: pwsh ./Tests/Invoke-ScenarioMatrix.ps1 [-SubscriptionID <id> -TenantID <id>] [-Scenarios ...] [-KeepOutput].
# The PII-leak / obfuscation tests only make sense on an -Obfuscate run: a non-obfuscated zip carries raw subscription paths/transcript by design, so those tests are EXPECTED to fail and are NOT attached to non-obfuscated scenarios. Only obfuscated zips are ever shared downstream, so this matches reality.
# A scenario also fails when its inventory run exits non-zero, throws, or leaves an entry in a phase-health list (a skipped or failed phase can still leave a valid zip), when a test file attached to it checked nothing because every test skipped, and when the 'default' scenario's live tenant reconciliation group did not run. Two files may skip everything for a data reason (Frontdoor.Tests.ps1, MetricsVolumeControls.Tests.ps1; see $DataDependentFiles). Skipped tests are listed with their reasons.

[CmdletBinding()]
param(
    [string]   $SubscriptionID,
    [string]   $TenantID,
    [string[]] $Scenarios = @('default', 'obfuscate', 'skipboth', 'skipmetrics', 'skipconsumption', 'service', 'includestorage', 'skipdisk', 'metricinterval', 'recovery'),
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
# Get-InventoryExitCodeMeaning owns the wording of the inventory script's exit codes.
. (Join-Path $RepoRoot 'Functions/RunAllSubscriptions.Functions.ps1')
if (-not (Get-Module -ListAvailable Pester | Where-Object { $_.Version.Major -ge 5 }))
{
    throw "Pester v5+ is required. Install-Module Pester -Force -Scope CurrentUser"
}

# -------------------------------------------------------------------------
# Resolve subscription + tenant. The default target is the sandbox's main
# subscription, resolved BY NAME at runtime, so every live gate runs against the
# same subscription and no subscription id is written into this file. Pass
# -SubscriptionID to override it. When this context cannot see a subscription of
# that name (another operator, another tenant), fall back to auto-discovering
# the first enabled sub that has metric-eligible resources, so the schema tests
# still see metric data.
# -------------------------------------------------------------------------
$Ctx = Get-AzContext -ErrorAction SilentlyContinue
if ($null -eq $Ctx -or $null -eq $Ctx.Account)
{
    throw "No Azure context. Run Connect-AzAccount first."
}
if ([string]::IsNullOrEmpty($TenantID)) { $TenantID = $Ctx.Tenant.Id }

# A NAME, never an id: the id of the sandbox subscription must not appear in a
# tracked file. Resolved against the live tenant a few lines below.
$DefaultSubscriptionName = 'Visual Studio Enterprise Subscription'

if ([string]::IsNullOrEmpty($SubscriptionID))
{
    $MetricTypes = @(
        'microsoft.compute/virtualmachines'
        'microsoft.storage/storageaccounts'
        'microsoft.sql/servers/databases'
        'microsoft.compute/virtualmachinescalesets'
        'microsoft.documentdb/databaseaccounts'
        'microsoft.web/sites'
    )
    $Pinned = @(Get-AzSubscription -SubscriptionName $DefaultSubscriptionName -TenantId $TenantID -ErrorAction SilentlyContinue |
            Where-Object { $_.State -eq 'Enabled' })
    if ($Pinned.Count -gt 0)
    {
        $Candidates = @($Pinned[0])
        Write-Host "Using the default subscription, resolved by name at runtime." -ForegroundColor Cyan
    }
    else
    {
        $Candidates = @(Get-AzSubscription -TenantId $TenantID -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Enabled' })
        Write-Host "Auto-discovering a subscription with metric-eligible resources..." -ForegroundColor Cyan
    }
    # Counting a subscription's resources needs the context pointed at it, and
    # moving the context is shared state: without -Scope Process it also rewrites
    # the saved default subscription the operator's NEXT session starts on, and
    # the probe would otherwise leave the context on whichever candidate it
    # stopped at. -Scope Process keeps the move inside this process and the
    # finally puts it back, the same restore the wrapper's preflight does.
    $OriginalContext = $Ctx
    # First-match selection: stop at the first candidate that has any
    # metric-eligible resource. If none do, fall back to the first one.
    $Best = $null; $BestCount = 0
    try
    {
        foreach ($s in $Candidates)
        {
            $null = Set-AzContext -Subscription $s.Id -Scope Process -ErrorAction SilentlyContinue
            $C = 0
            foreach ($t in $MetricTypes) { try { $C += @(Get-AzResource -ResourceType $t -ErrorAction SilentlyContinue).Count } catch {} }
            if ($null -eq $Best) { $Best = $s; $BestCount = $C }
            if ($C -gt 0) { $Best = $s; $BestCount = $C; break }
        }
    }
    finally
    {
        if ($OriginalContext)
        {
            try { $null = Set-AzContext -Context $OriginalContext -Scope Process -ErrorAction Stop }
            catch { Write-Warning "Could not restore the Az context this run started with." }
        }
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
# Live tenant reconciliation - only meaningful on a NON-obfuscated zip (real ARM
# IDs) with a live Az session for the run's subscription. The suite self-skips
# when the zip is obfuscated or no matching live context is available, so it is
# only attached to the 'default' scenario (which sets TEST_SUBSCRIPTION_ID below).
$ReconciliationTests = @(
    'TenantReconciliation.Tests.ps1'
)
# Schema-contract + cross-dataset-linkage gate: PURE-OUTPUT (no Azure), drift-immune, valid in BOTH obfuscated and non-obfuscated modes (join keys must correlate whether raw ARM paths or prod_/nonprod_ tokens), so attached to both 'default' and 'obfuscate' as a hard gate. Self-skips when a phase was suppressed by a -Skip* switch, so it stays inert on the skip* scenarios and is not attached there.
$SchemaContractTests = @(
    'SchemaContract.Tests.ps1'
)
# Assertions in OutputCompleteness.Tests.ps1 to reclassify as expected-skips for NON-obfuscated scenarios. Deliberately EMPTY: the two former entries are now MODE-AWARE inside the test itself ($script:IsObfuscatedBundle from the Diagnostics_*.log header) and must PASS in every scenario - the old exclusion was stale (transcript is now excluded from both branches) and silently disarmed two real gates. Keep the reclassification machinery below as the seam for a genuinely obfuscate-only assertion; add a name only with a justification verified against CURRENT packaging code.
$NonObfuscatedExcludedTests = @()
# PII / obfuscation tests only valid for -Obfuscate runs.
$ObfuscationTests = @(
    'DataIntegrity.Tests.ps1'
    'ReferentialIntegrity.Tests.ps1'
    'Obfuscation.Tests.ps1'
    'ProdNonprodPrefix.Tests.ps1'
    'DictionaryValidation.Tests.ps1'
)

$Catalog = @{
    # MetricsVolumeControls is attached here too: 'default' passes no metric flags,
    # so it is the scenario that proves the Storage Account UsedCapacity metric is
    # genuinely opt-in (see TEST_EXPECT_NO_STORAGE_METRICS below).
    # The live half of TenantReconciliation self-skips without a live session that can see the run's subscription, so 'default' must show at least one of its tests running (MustPass), or the live gate proved nothing.
    'default'         = @{ Args = @{}; Tests = ($StructuralTests + $ReconciliationTests + $SchemaContractTests + @('MetricsVolumeControls.Tests.ps1')); MustPass = @(@{ File = 'TenantReconciliation.Tests.ps1'; Describe = 'Live tenant reconciliation' }) }
    'obfuscate'       = @{ Args = @{ Obfuscate = $true }; Tests = ($StructuralTests + $ObfuscationTests + $SchemaContractTests) }
    'skipboth'        = @{ Args = @{ SkipMetrics = $true; SkipConsumption = $true }; Tests = $StructuralTests }
    'skipmetrics'     = @{ Args = @{ SkipMetrics = $true }; Tests = $StructuralTests }
    'skipconsumption' = @{ Args = @{ SkipConsumption = $true }; Tests = $StructuralTests }
    # Collector scoping. -SkipMetrics/-SkipConsumption keep it fast (the assertion
    # is purely about WHICH resource types appear, not metrics/consumption). The
    # ServiceScope suite reads $env:TEST_EXPECTED_SERVICES (set below) and asserts
    # the inventory contains ONLY the requested collector(s) + metadata.
    'service'         = @{ Args = @{ Service = @('VirtualMachines'); SkipMetrics = $true; SkipConsumption = $true }; Tests = @('ServiceScope.Tests.ps1') }
    # Opt-in metric-volume controls: each runs the structural suite (proving a valid, schema-correct zip) plus MetricsVolumeControls.Tests.ps1, which reads the per-scenario TEST_EXPECT_* env vars set below to assert the flag's effect (no Storage Account / no Managed Disk metrics, or the VM/SQL sampled series at the requested grain). Storage Account UsedCapacity is OPT-IN, so 'includestorage' proves the gate OPENS and 'default' proves it stays shut.
    'includestorage'  = @{ Args = @{ IncludeStorageMetrics = $true }; Tests = ($StructuralTests + @('MetricsVolumeControls.Tests.ps1')) }
    'skipdisk'        = @{ Args = @{ SkipDiskMetrics = $true }; Tests = ($StructuralTests + @('MetricsVolumeControls.Tests.ps1')) }
    'metricinterval'  = @{ Args = @{ MetricsIntervalMinutes = 60 }; Tests = ($StructuralTests + @('MetricsVolumeControls.Tests.ps1')) }
    # Live recovery workflow. It does NOT fit the one-generation-per-scenario
    # shape (it needs two generations + a Merge-RecoveryData splice), so it is
    # handled by a dedicated self-contained branch at the top of the loop rather
    # than the shared generation path below. The merged bundle is obfuscated, so
    # it is validated with the same structural + obfuscation suite as 'obfuscate'.
    'recovery'        = @{ Recovery = $true; Tests = ($StructuralTests + $ObfuscationTests) }
}

# Health of the run that just finished, read from its exit code and from the phase-health lists the inventory script fills when a phase could not run (no usable token or context) or failed (collectors, metrics, consumption, Marketplace, Foundry). A -Skip* switch leaves them empty. A zip can look fine while a phase was silently left out, so a scenario fails on any of these. The lists are process-wide, so every run starts from empty ones. Only counts are printed: the matrix output is shared, so no names, ids or messages.
$HealthLists = @('CollectorFailures', 'MetricsFailedSubs', 'ConsumptionFailedSubs', 'MarketplaceFailedSubs', 'FoundryTokenFailedSubs', 'FoundryCoverageFailedSubs')
# Test files that may skip every test because the subscription has nothing of the kind to check. A file listed here passes the "checked nothing" rule only when at least one of its tests skipped for the named data reason (a regex on the skip reason); a skip for any other reason, for example the matrix not setting an expectation variable, still fails the scenario. Add a file only after reading its tests.
$DataDependentFiles = @{
    'Frontdoor.Tests.ps1'             = @{ Why = 'every test needs a Front Door resource in the subscription'; Reason = 'no Front Door' }
    'MetricsVolumeControls.Tests.ps1' = @{ Why = 'the one check a scenario turns on needs a storage account, or a VM, SQL or open-source database metric series, in the subscription'; Reason = 'owns no storage account|produced no VM/SQL/OSS-DB sampled-series' }
}

function Reset-RunHealth
{
    # A script that ends without an exit statement leaves the previous value in $LASTEXITCODE, so it is cleared before every run.
    $global:LASTEXITCODE = 0
    foreach ($Name in $script:HealthLists) { Set-Variable -Name $Name -Scope Global -Value @() }
}

function Get-RunHealthProblems
{
    param([int]$ExitCode, [bool]$Threw = $false)
    $Problems = @()
    if ($Threw) { $Problems += 'the run threw an error' }
    if ($ExitCode -ne 0) { $Problems += ('exit code {0} ({1})' -f $ExitCode, (Get-InventoryExitCodeMeaning -Code $ExitCode)) }
    foreach ($Name in $script:HealthLists)
    {
        # Get-Variable hands the whole array over as one object, so the value is read into a variable first and enumerated from there.
        $Entries = Get-Variable -Name $Name -Scope Global -ValueOnly -ErrorAction SilentlyContinue
        $Count = @($Entries | Where-Object { $null -ne $_ }).Count
        if ($Count -gt 0) { $Problems += ('{0}: {1} entr{2}' -f $Name, $Count, $(if ($Count -eq 1) { 'y' } else { 'ies' })) }
    }
    return $Problems
}

function Get-SkipReason
{
    # Set-ItResult -Skipped keeps its reason in the test's error record. A test skipped by a -Skip condition has none.
    param($Test)
    if (@($Test.ErrorRecord).Count -gt 0) { return (([string]$Test.ErrorRecord[0].Exception.Message) -replace '^is skipped, because\s*', '') }
    return 'a -Skip condition (on the test or its block) was true'
}

function Write-ScenarioTestReport
{
    # Prints, per test file, which tests skipped and why, and returns the problems that make the scenario fail even though no test failed: a file whose tests all skipped or that ran no tests, and a MustPass group (a Describe whose tests have to run, because it is the only check of something) with no test that ran. A skip is still normal when a fixture has nothing to check, so one skip alone is not a problem.
    param($Result, [string[]]$Files, $MustPass = @())
    $Problems = @()
    $ByFile = @{}
    foreach ($Test in @($Result.Tests))
    {
        $Leaf = if ($Test.ScriptBlock.File) { Split-Path -Path $Test.ScriptBlock.File -Leaf } else { '(no file)' }
        if (-not $ByFile.ContainsKey($Leaf)) { $ByFile[$Leaf] = @() }
        $ByFile[$Leaf] += $Test
    }
    foreach ($File in $Files)
    {
        $Tests = if ($ByFile.ContainsKey($File)) { @($ByFile[$File]) } else { @() }
        if ($Tests.Count -eq 0)
        {
            $Problems += ('no tests ran from {0}' -f $File)
            continue
        }
        $Passed = @($Tests | Where-Object { $_.Result -eq 'Passed' }).Count
        $Failed = @($Tests | Where-Object { $_.Result -eq 'Failed' }).Count
        $Skipped = @($Tests | Where-Object { $_.Result -eq 'Skipped' })
        if ($Skipped.Count -gt 0)
        {
            Write-Host ('  skipped in {0}: {1} of {2}' -f $File, $Skipped.Count, $Tests.Count) -ForegroundColor DarkYellow
            foreach ($Group in @($Skipped | Group-Object -Property { Get-SkipReason $_ }))
            {
                $Names = @($Group.Group | ForEach-Object { $_.ExpandedName })
                $More = if ($Names.Count -gt 8) { '; and {0} more' -f ($Names.Count - 8) } else { '' }
                Write-Host ('    because {0} ({1}): {2}{3}' -f $Group.Name, $Names.Count, (($Names | Select-Object -First 8) -join '; '), $More) -ForegroundColor DarkYellow
            }
        }
        if ($Passed -eq 0 -and $Failed -eq 0)
        {
            $Allowance = $script:DataDependentFiles[$File]
            $DataSkips = if ($Allowance) { @($Skipped | Where-Object { (Get-SkipReason $_) -match $Allowance.Reason }).Count } else { 0 }
            if ($DataSkips -gt 0) { Write-Host ('    (allowed: {0})' -f $Allowance.Why) -ForegroundColor DarkYellow }
            else { $Problems += ('every test in {0} was skipped or did not run, so it checked nothing' -f $File) }
        }
    }
    foreach ($Rule in @($MustPass | Where-Object { $_ }))
    {
        $Group = if ($ByFile.ContainsKey($Rule.File)) { @($ByFile[$Rule.File] | Where-Object { $_.Path[0] -eq $Rule.Describe }) } else { @() }
        if (@($Group | Where-Object { $_.Result -in 'Passed', 'Failed' }).Count -eq 0)
        {
            $Problems += ("none of the {0} test(s) under '{1}' in {2} ran, so that check did not run" -f $Group.Count, $Rule.Describe, $Rule.File)
        }
    }
    return $Problems
}

# Recovery-scenario generator: produces the LIVE gap + seeded-recovery bundles and splices them with Merge-RecoveryData, returning the merged (obfuscated) bundle for the loop. Returns @{ Skip=$true; Reason } when nothing to recover, else @{ Skip=$false; Zip; Dict; Recovered }. Both generations are collector-scoped and skip metrics/consumption (the workflow is about the INVENTORY splice). The recovery run is seeded with the gap bundle's dictionary (-ObfuscationDictionary) so its tokens match exactly - the guarantee Merge-RecoveryData relies on. Fails loud if the splice does not land the key.
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
    Reset-RunHealth
    & $InventoryPs1 -TenantID $TenantID -SubscriptionID $SubscriptionID -OutputDirectory $GapDir `
        -Service $GapServices -Obfuscate -SkipMetrics -SkipConsumption `
        -MetricsLookbackDays $MetricsLookbackDays -ConcurrencyLimit $ConcurrencyLimit *>&1 | Out-Null
    $GapProblems = @(Get-RunHealthProblems -ExitCode $LASTEXITCODE)
    if ($GapProblems.Count -gt 0) { throw ('recovery scenario: the gap generation had problems: {0}.' -f ($GapProblems -join '; ')) }

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
    Reset-RunHealth
    & $InventoryPs1 -TenantID $TenantID -SubscriptionID $SubscriptionID -OutputDirectory $RecoveryDir `
        -Service $Recovered -Obfuscate -ObfuscationDictionary $GapDictFile.FullName -SkipMetrics -SkipConsumption `
        -MetricsLookbackDays $MetricsLookbackDays -ConcurrencyLimit $ConcurrencyLimit *>&1 | Out-Null
    $RecoveryProblems = @(Get-RunHealthProblems -ExitCode $LASTEXITCODE)
    if ($RecoveryProblems.Count -gt 0) { throw ('recovery scenario: the recovery generation had problems: {0}.' -f ($RecoveryProblems -join '; ')) }

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
                $Summary += [pscustomobject]@{ Scenario = $name; ZipProduced = $false; Passed = 0; Failed = 1; Skipped = 0; Problems = 0 }
                continue
            }

            if ($Rec.Skip)
            {
                Write-Host ("  SKIPPED: {0}." -f $Rec.Reason) -ForegroundColor Yellow
                $Summary += [pscustomobject]@{ Scenario = $name; ZipProduced = $false; Passed = 0; Failed = 0; Skipped = 1; Problems = 0 }
                continue
            }
            if (-not $Rec.Zip)
            {
                # No usable zip: mirror the shared path's "no zip produced" sentinel (-1).
                Write-Host "  FAILED: recovery merge produced no zip." -ForegroundColor Red
                $Summary += [pscustomobject]@{ Scenario = $name; ZipProduced = $false; Passed = 0; Failed = -1; Skipped = 0; Problems = 0 }
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
            Remove-Item Env:TEST_EXPECT_STORAGE_METRICS      -ErrorAction SilentlyContinue
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
            $Problems = @(Write-ScenarioTestReport -Result $Res -Files $Scenario.Tests -MustPass $Scenario.MustPass)
            foreach ($Problem in $Problems) { Write-Host ("    PROBLEM: {0}" -f $Problem) -ForegroundColor Red }

            $Summary += [pscustomobject]@{ Scenario = $name; ZipProduced = $true; Passed = $Passed; Failed = $Failed; Skipped = $Skipped; Problems = $Problems.Count }
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

        Reset-RunHealth
        $GenerationThrew = $false
        try { & $InventoryPs1 @Splat *>&1 | Out-Null }
        catch
        {
            $GenerationThrew = $true
            Write-Host ("  generation error: {0}" -f $_.Exception.Message) -ForegroundColor Red
        }
        # Read before Pester runs: the tests may touch the same globals.
        $RunProblems = @(Get-RunHealthProblems -ExitCode $LASTEXITCODE -Threw $GenerationThrew)

        $Zip = Get-ChildItem $OutDir -Filter 'ResourcesReport_*.zip' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1

        if (-not $Zip)
        {
            Write-Host "  FAILED: no output zip produced." -ForegroundColor Red
            foreach ($Problem in $RunProblems) { Write-Host ("    PROBLEM: {0}" -f $Problem) -ForegroundColor Red }
            $Summary += [pscustomobject]@{ Scenario = $name; ZipProduced = $false; Passed = 0; Failed = -1; Skipped = 0; Problems = @($RunProblems).Count }
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
        elseif ($name -eq 'default')
        {
            # Non-obfuscated baseline: TenantReconciliation.Tests.ps1 needs the
            # run's subscription to cross-check the (real) inventory IDs against
            # the live tenant. No dictionary/user-email needed (not obfuscated).
            $env:TEST_SUBSCRIPTION_ID = $SubscriptionID
            Remove-Item Env:TEST_USER_EMAIL -ErrorAction SilentlyContinue
            Remove-Item Env:TEST_DICT_PATH  -ErrorAction SilentlyContinue
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
        Remove-Item Env:TEST_EXPECT_STORAGE_METRICS      -ErrorAction SilentlyContinue
        Remove-Item Env:TEST_EXPECT_NO_DISK_METRICS      -ErrorAction SilentlyContinue
        Remove-Item Env:TEST_EXPECT_METRIC_GRAIN_MINUTES -ErrorAction SilentlyContinue
        switch ($name)
        {
            # 'default' passes no metric flags, so it is what proves the storage
            # capacity metric is genuinely OPT-IN (absent unless asked for).
            'default' { $env:TEST_EXPECT_NO_STORAGE_METRICS = '1' }
            'includestorage' { $env:TEST_EXPECT_STORAGE_METRICS = '1' }
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

        # Detect a DISCOVERY-time crash: a container (test file) can fail before any It runs (code in a Describe body throwing), leaving FailedCount 0 so the scenario looks green while a whole block is silently broken. Key off a non-empty $container.ErrorRecord, NOT Result (a partial crash still reports 'Passed') and NOT TotalCount (some tests still ran); a runtime failure instead has Result='Failed' with ErrorRecord empty (handled by the reclassification below).
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
        $Problems = @($RunProblems) + @(Write-ScenarioTestReport -Result $Res -Files $Scenario.Tests -MustPass $Scenario.MustPass)
        foreach ($Problem in $Problems) { Write-Host ("    PROBLEM: {0}" -f $Problem) -ForegroundColor Red }

        $Summary += [pscustomobject]@{
            Scenario    = $name
            ZipProduced = $true
            Passed      = $Passed
            Failed      = $Failed
            Skipped     = $Skipped
            Problems    = $Problems.Count
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
    Remove-Item Env:TEST_EXPECT_STORAGE_METRICS      -ErrorAction SilentlyContinue
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

$TotalFailed = ($Summary | Where-Object { $_.Failed -ne 0 -or [int]$_.Problems -ne 0 }).Count
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
