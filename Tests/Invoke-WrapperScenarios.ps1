# Wrapper Scenario Runner: the sibling of Invoke-ScenarioMatrix.ps1 for Run-AllSubscriptions.ps1.
# The matrix exercises the per-subscription script and asserts the zip it produced.
# This runner exercises the WRAPPER and asserts what the wrapper decided: its exit code, the reconciliation it reported, and whether it kept or cleared the resume state.
# Those decisions have no artifact to inspect, so each case states them as expectations and the run fails when one is not met.
#
# Every run is read-only against the tenant and skips every billed phase (metrics, consumption, Marketplace, Foundry), so a full pass costs nothing but Resource Graph and control-plane reads.
# Collection is confined to the subscription named by -SubscriptionName, which defaults to the sandbox subscription every live gate uses.
# Two cases list a second subscription without ever collecting it: 'notlisted' needs the end-of-run listing to name a different subscription, and 'resumefailedonly' needs a second eligible subscription for -ResumeFailedOnly to leave uncollected.
# One case, 'parallel', genuinely has to collect a second subscription, because a stream is sized per subscription and two streams cannot start against one.
# Pass -SingleSubscriptionOnly to skip that case and keep collection inside the named subscription.
#
# Faults are injected the way the live-run kit injects them: Get-AzSubscription and Search-AzGraph are shadowed by functions in the driver's own process, so the real wrapper runs unmodified and the real tenant answers everything that is not injected.
# Each case runs in its own child pwsh process, so a shim cannot reach the next case and a wrapper that exits cannot take this runner with it.
#
# The wrapper writes to the inventory root it resolves for itself and has no output-directory parameter, so this runner cannot redirect it.
# Instead it snapshots the root's entries, and after each case deletes exactly the entries that are new against that snapshot AND newer than the case's own start marker, then checks the root matches the snapshot again.
# It refuses to start when the root already holds a resume-state file, because a case seeds that file and would overwrite the state of an interrupted real run.
#
# Output is counts and yes/no only: the wrapper's own lines name subscriptions, so no captured line is ever printed.
# The captured transcripts stay in the work directory when a case fails or -KeepOutput is passed, and they carry real identifiers.
#
# Usage: pwsh ./Tests/Invoke-WrapperScenarios.ps1 [-Cases narrow,obfuscate] [-SingleSubscriptionOnly] [-KeepOutput]

[CmdletBinding()]
param(
    [string]   $TenantID,
    [string]   $SubscriptionName = 'Visual Studio Enterprise Subscription',
    [string[]] $Cases = @('narrow', 'notlisted', 'endlisting', 'corruptstate', 'resumefailedonly', 'parallel', 'obfuscate'),
    [int]      $TimeoutMinutes = 60,
    [switch]   $SingleSubscriptionOnly,
    [switch]   $KeepOutput
)

$ErrorActionPreference = 'Stop'

# Invoking via `pwsh -File ... -Cases a,b` binds the whole thing as the single
# string 'a,b', unlike -Command which binds a 2-element array. Split, trim and
# drop empties so the runner behaves the same however it was launched - the same
# normalization Invoke-ScenarioMatrix.ps1 does.
$Cases = @($Cases | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

$RepoRoot = Split-Path $PSScriptRoot -Parent
$WrapperPath = Join-Path $RepoRoot 'Run-AllSubscriptions.ps1'
if (-not (Test-Path -LiteralPath $WrapperPath -PathType Leaf)) { throw "Cannot find Run-AllSubscriptions.ps1 at $WrapperPath" }
if (-not (Get-Module -ListAvailable Pester | Where-Object { $_.Version.Major -ge 5 }))
{
    throw "Pester v5+ is required. Install-Module Pester -RequiredVersion 5.7.1 -Force -Scope CurrentUser"
}

# Get-RdaInventoryRoot is the single resolver for the output root, and the only
# way to learn where the wrapper will write without duplicating its rules.
. (Join-Path $RepoRoot 'Functions/Common.Functions.ps1')

# -------------------------------------------------------------------------
# Case catalog. Mode is the driver's injection mode; Expect is matched against
# the captured transcript, and each entry's key is what gets reported, never the
# line it matched.
# -------------------------------------------------------------------------
$Catalog = [ordered]@{
    'narrow'           = @{
        Mode     = 'narrow'
        ExitCode = 0
        Expect   = [ordered]@{ 'processed every subscription it listed' = 'All subscriptions processed!' }
        Needs    = @()
    }
    'notlisted'        = @{
        Mode     = 'notlisted'
        ExitCode = 2
        Expect   = [ordered]@{
            'reported the failed subscription as not listed at the end' = 'Not listed at the end of the run \(1\)'
        }
        Needs    = @('SecondSubscription')
    }
    'endlisting'       = @{
        Mode     = 'endlisting'
        ExitCode = 0
        Expect   = [ordered]@{
            'skipped reconciliation instead of acting on an empty listing' = 'subscription reconciliation skipped \(re-enumeration failed\)'
            'still ended with warnings'                                    = 'WITH WARNINGS'
        }
        Needs    = @()
    }
    'corruptstate'     = @{
        Mode     = 'corruptstate'
        ExitCode = 0
        Expect   = [ordered]@{
            'started fresh from an unreadable resume state' = 'Could not read resume state file'
        }
        Needs    = @()
    }
    'resumefailedonly' = @{
        Mode       = 'resumefailedonly'
        ExitCode   = 0
        Expect     = [ordered]@{
            'named the subscription it never collected' = 'Never collected, and not retried by -ResumeFailedOnly \(1\)'
            'said the resume state was kept'            = 'Resume state kept at'
            'ended with warnings'                       = 'WITH WARNINGS'
        }
        Needs      = @('SecondSubscription')
        # The run must NOT clear the state file: the never-collected subscription
        # is still owed and the next -Resume needs the record to collect it.
        StateKept  = $true
    }
    'parallel'         = @{
        Mode     = 'parallel'
        ExitCode = 0
        Expect   = [ordered]@{
            'started one stream per subscription' = 'Parallel-streams mode: 2 streams across 2 subscription\(s\)'
            'processed every subscription'        = 'All subscriptions processed!'
        }
        Needs    = @('SecondSubscription', 'SecondSubscriptionCollected')
    }
    'obfuscate'        = @{
        Mode      = 'obfuscate'
        ExitCode  = 0
        Expect    = [ordered]@{ 'processed every subscription it listed' = 'All subscriptions processed!' }
        Needs     = @()
        # The outer bundle is the one file an operator sends, and only an
        # obfuscated one is ever shared, so this is the case that asserts it.
        BundleTests = @(
            'OuterBundleMembership.Tests.ps1'
            'Obfuscation.Tests.ps1'
            'ProdNonprodPrefix.Tests.ps1'
            'DictionaryValidation.Tests.ps1'
            'DataIntegrity.Tests.ps1'
            'ReferentialIntegrity.Tests.ps1'
        )
    }
}

foreach ($Name in $Cases)
{
    if (-not $Catalog.Contains($Name)) { throw ("Unknown case '{0}'. Known: {1}" -f $Name, ($Catalog.Keys -join ', ')) }
}

# -------------------------------------------------------------------------
# Pre-flight: context, the named subscription, a second subscription, the
# inventory root and its snapshot.
# -------------------------------------------------------------------------
$Ctx = Get-AzContext -ErrorAction SilentlyContinue
if ($null -eq $Ctx -or $null -eq $Ctx.Account) { throw "No Azure context. Run Connect-AzAccount first." }
if ([string]::IsNullOrEmpty($TenantID)) { $TenantID = $Ctx.Tenant.Id }

# A NAME, never an id: the sandbox subscription's id must not appear in a tracked
# file, so it is resolved against the live tenant here.
$Pinned = @(Get-AzSubscription -SubscriptionName $SubscriptionName -TenantId $TenantID -ErrorAction SilentlyContinue |
        Where-Object { $_.State -eq 'Enabled' })
if ($Pinned.Count -eq 0) { throw ("No enabled subscription named '{0}' is visible in tenant from the current context." -f $SubscriptionName) }
$Others = @(Get-AzSubscription -TenantId $TenantID -ErrorAction SilentlyContinue |
        Where-Object { $_.State -eq 'Enabled' -and $_.Id -ne $Pinned[0].Id })
$HaveSecond = $Others.Count -gt 0

$RootResult = Get-RdaInventoryRoot -NoInherit
if (-not $RootResult.Ok) { throw ("Cannot resolve the inventory root: {0}" -f $RootResult.Message) }
$InventoryRoot = $RootResult.Path

$ExistingState = @(Get-ChildItem -LiteralPath $InventoryRoot -Filter '.resume-state-*.json' -Force -ErrorAction SilentlyContinue)
if ($ExistingState.Count -gt 0)
{
    throw ("The inventory root already holds {0} resume-state file(s). A case seeds that file, which would overwrite the state of an interrupted run. Finish or remove that run's state first." -f $ExistingState.Count)
}

$Snapshot = @(Get-ChildItem -LiteralPath $InventoryRoot -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name } | Sort-Object)
$WorkRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("WrapperScenarios_" + (Get-Date -Format 'yyyyMMdd_HHmmss'))
New-Item -ItemType Directory -Path $WorkRoot -Force | Out-Null

Write-Host ""
Write-Host "Wrapper scenario runner" -ForegroundColor Cyan
Write-Host ("  cases:          {0}" -f ($Cases -join ', '))
Write-Host ("  inventory root: {0} entries at the start" -f $Snapshot.Count)
Write-Host ("  work directory: {0}" -f $WorkRoot)
Write-Host ("  second subscription visible: {0}" -f $(if ($HaveSecond) { 'yes' } else { 'no' }))

# -------------------------------------------------------------------------
# The driver. Written once to the work directory and run per case in its own
# child process. It shadows two Az cmdlets with functions so the real wrapper
# runs unmodified; everything not injected is answered by the real tenant.
# -------------------------------------------------------------------------
$DriverSource = @'
param(
    [Parameter(Mandatory)][string]$Repo,
    [Parameter(Mandatory)][string]$PinnedName,
    [Parameter(Mandatory)][ValidateSet('narrow', 'notlisted', 'endlisting', 'corruptstate', 'resumefailedonly', 'parallel', 'obfuscate')][string]$Mode
)
# Continue, not Stop: the wrapper reports failures through its exit code and its
# own banners, and stopping on the first injected error would hide them.
$ErrorActionPreference = 'Continue'
Import-Module Az.Accounts, Az.ResourceGraph -ErrorAction Stop

$Tenant = (Get-AzContext).Tenant.Id
$Enabled = @(Az.Accounts\Get-AzSubscription -TenantId $Tenant -WarningAction SilentlyContinue | Where-Object { $_.State -eq 'Enabled' })
$PinnedSub = @($Enabled | Where-Object { $_.Name -eq $PinnedName })
if ($PinnedSub.Count -eq 0) { throw 'the named subscription is not enabled in this tenant' }
$Global:RdaPinnedId = $PinnedSub[0].Id
$OtherSub = @($Enabled | Where-Object { $_.Id -ne $Global:RdaPinnedId })
$Global:RdaOtherId = if ($OtherSub.Count -gt 0) { $OtherSub[0].Id } else { $null }
$Global:RdaMode = $Mode

$WrapperPath = Join-Path $Repo 'Run-AllSubscriptions.ps1'
# The end-of-run listing is told apart from the start-of-run one by the line it
# is called from, so the shim can narrow one and not the other.
$Global:RdaEndListingLine = (Select-String -LiteralPath $WrapperPath -Pattern '^\s*\$EndSubs = @\(Get-AzSubscription' | Select-Object -First 1).LineNumber
if (-not $Global:RdaEndListingLine) { throw 'end-of-run Get-AzSubscription line not found in the wrapper' }

# Which subscriptions the START listing may name. Only 'resumefailedonly' and
# 'parallel' need a second one, and only 'parallel' ever collects it.
$Global:RdaStartIds = switch ($Mode)
{
    'resumefailedonly' { @($Global:RdaPinnedId, $Global:RdaOtherId) }
    'parallel' { @($Global:RdaPinnedId, $Global:RdaOtherId) }
    default { @($Global:RdaPinnedId) }
}

function global:Get-AzSubscription
{
    [CmdletBinding()]
    param([string]$SubscriptionId, [string]$SubscriptionName, [string]$TenantId)
    $Caller = (Get-PSCallStack)[1]
    $IsEndOfRun = $Caller.ScriptName -and
    $Caller.ScriptName.EndsWith('Run-AllSubscriptions.ps1') -and
    $Caller.ScriptLineNumber -eq $Global:RdaEndListingLine
    $Real = @(Az.Accounts\Get-AzSubscription @PSBoundParameters)

    if ($IsEndOfRun)
    {
        switch ($Global:RdaMode)
        {
            'notlisted'
            {
                # The subscription this run collected is no longer listed, and a
                # different one is: the shape of a subscription moved to another
                # directory or hidden from this identity mid-run.
                return @($Real | Where-Object { $_.Id -eq $Global:RdaOtherId })
            }
            'endlisting'
            {
                # Az.Accounts reports a token it cannot acquire as a warning and an
                # empty listing, never as an error. That is the case the wrapper has
                # to refuse to act on.
                Write-Warning ("Unable to acquire token for tenant '{0}' with error 'SharedTokenCacheCredential authentication failed: ' (injected by the wrapper scenario runner)" -f $Tenant)
                return
            }
        }
    }
    @($Real | Where-Object { $Global:RdaStartIds -contains $_.Id })
}

function global:Search-AzGraph
{
    [CmdletBinding()]
    param([string]$Query, [int]$First, [int]$Skip, [string[]]$Subscription, [string[]]$ManagementGroup,
        [switch]$UseTenantScope, [string]$SkipToken, [switch]$AllowPartialScope)
    $UnderInventory = @(Get-PSCallStack | Where-Object { $_.ScriptName -and $_.ScriptName.EndsWith('ResourceInventory.ps1') }).Count -gt 0
    $Subs = @($Subscription | Where-Object { $_ })
    if ($Global:RdaMode -eq 'notlisted' -and $UnderInventory -and $Subs.Count -eq 1 -and $Subs[0] -eq $Global:RdaPinnedId)
    {
        throw 'Please provide a valid tenant or a valid subscription. (injected by the wrapper scenario runner)'
    }
    Az.ResourceGraph\Search-AzGraph @PSBoundParameters
}

# The wrapper resolves its own output root and has no parameter to override it,
# so the state file this case seeds has to be placed where the wrapper looks.
. (Join-Path $Repo 'Functions/Common.Functions.ps1')
$RootResult = Get-RdaInventoryRoot -NoInherit
if (-not $RootResult.Ok) { throw 'cannot resolve the inventory root' }
$StatePath = Join-Path $RootResult.Path ('.resume-state-{0}.json' -f $Tenant)

if ($Mode -eq 'corruptstate')
{
    # A state file the JSON parser stops on at a brace, as a truncated write leaves one.
    Set-Content -LiteralPath $StatePath -Value '{ "TenantID": }' -Encoding utf8
    '[driver] wrote an unreadable resume state file'
}
if ($Mode -eq 'resumefailedonly')
{
    # An interrupted run's state: the named subscription failed and is owed a
    # retry, and the second listed one was never reached at all. -ResumeFailedOnly
    # retries only the first, so the second stays owed and the state must survive.
    $Seeded = [pscustomobject]@{
        Id           = $Global:RdaPinnedId
        Name         = $PinnedName
        LastFailedAt = (Get-Date).AddHours(-1).ToString('o')
        Reason       = 'seeded by the wrapper scenario runner'
        Attempts     = 1
    }
    [ordered]@{
        TenantID                 = $Tenant
        CompletedSubscriptionIds = @()
        FailedAttempts           = @($Seeded)
        LastUpdated              = (Get-Date).ToString('o')
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $StatePath -Encoding utf8
    '[driver] seeded a resume state with 1 failed and 1 never-reached subscription'
}

# Read-only against the tenant: every billed phase is skipped, so the run issues
# Resource Graph and control-plane reads only. -AllowPartialAccess keeps a
# subscription the identity cannot fully read from aborting the run.
$Switches = @{
    SkipMetrics         = $true
    SkipConsumption     = $true
    SkipMarketplace     = $true
    SkipFoundryCoverage = $true
    SkipFoundryTokens   = $true
    AllowPartialAccess  = $true
}
if ($Mode -eq 'obfuscate') { $Switches.Obfuscate = $true }
if ($Mode -eq 'resumefailedonly') { $Switches.ResumeFailedOnly = $true }
# One stream per subscription. Left at 1 everywhere else because an auto-sized
# run puts each stream in its own pwsh process, which these shims cannot reach.
$Streams = if ($Mode -eq 'parallel') { 2 } else { 1 }

& $WrapperPath -TenantID $Tenant -ParallelStreams $Streams @Switches
"[driver] WRAPPER_EXIT=$LASTEXITCODE"
'@

$DriverPath = Join-Path $WorkRoot 'driver.ps1'
Set-Content -LiteralPath $DriverPath -Value $DriverSource -Encoding utf8

# -------------------------------------------------------------------------
# Restore the inventory root to its snapshot: delete exactly the entries that
# are new against it AND were written after this case started. An entry that
# predates the marker is left alone and named, because it is not this run's.
# -------------------------------------------------------------------------
function Restore-InventoryRoot
{
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Before,
        [Parameter(Mandatory)][datetime]$StartedAt
    )
    $Now = @(Get-ChildItem -LiteralPath $Root -Force -ErrorAction SilentlyContinue)
    $New = @($Now | Where-Object { $Before -notcontains $_.Name })
    $Deleted = 0
    $Left = 0
    foreach ($Entry in $New)
    {
        if ($Entry.LastWriteTime -lt $StartedAt) { $Left++; continue }
        try { Remove-Item -LiteralPath $Entry.FullName -Recurse -Force -ErrorAction Stop; $Deleted++ }
        catch { $Left++; Write-Host ("    could not remove one entry this case created: {0}" -f $_.Exception.Message) -ForegroundColor Yellow }
    }
    $After = @(Get-ChildItem -LiteralPath $Root -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name } | Sort-Object)
    $Missing = @($Before | Where-Object { $After -notcontains $_ })
    [pscustomobject]@{
        Deleted   = $Deleted
        Left      = $Left
        Matches   = ($Missing.Count -eq 0 -and $After.Count -eq $Before.Count)
        Removed   = $Missing.Count
        NowCount  = $After.Count
    }
}

# -------------------------------------------------------------------------
# Run the cases.
# -------------------------------------------------------------------------
$Summary = @()
$AnyFailed = $false

foreach ($Name in $Cases)
{
    $Case = $Catalog[$Name]
    Write-Host ""
    Write-Host ("=== $Name ===") -ForegroundColor Cyan

    $SkipReason = $null
    if ($Case.Needs -contains 'SecondSubscription' -and -not $HaveSecond)
    {
        $SkipReason = 'the tenant lists only one enabled subscription, and this case needs a second one listed'
    }
    elseif ($Case.Needs -contains 'SecondSubscriptionCollected' -and $SingleSubscriptionOnly)
    {
        $SkipReason = '-SingleSubscriptionOnly was passed, and this case has to collect a second subscription'
    }
    if ($SkipReason)
    {
        Write-Host ("  SKIPPED: {0}" -f $SkipReason) -ForegroundColor Yellow
        $Summary += [pscustomobject]@{ Case = $Name; Exit = 'n/a'; Met = 0; Unmet = 0; Tests = 'n/a'; Root = 'untouched'; Result = 'SKIPPED' }
        continue
    }

    $StartedAt = Get-Date
    $LogPath = Join-Path $WorkRoot ("$Name.txt")
    Write-Host "  running the wrapper..." -ForegroundColor DarkGray

    $Proc = Start-Process -FilePath (Get-Process -Id $PID).Path `
        -ArgumentList @('-NoProfile', '-File', $DriverPath, '-Repo', $RepoRoot, '-PinnedName', $SubscriptionName, '-Mode', $Case.Mode) `
        -RedirectStandardOutput $LogPath -RedirectStandardError (Join-Path $WorkRoot "$Name.err.txt") `
        -NoNewWindow -PassThru
    if (-not $Proc.WaitForExit($TimeoutMinutes * 60 * 1000))
    {
        try { $Proc.Kill($true) } catch { Write-Host ("    could not stop the timed-out driver: {0}" -f $_.Exception.Message) -ForegroundColor Yellow }
        Write-Host ("  TIMED OUT after {0} minute(s)" -f $TimeoutMinutes) -ForegroundColor Red
    }

    $Captured = ''
    foreach ($Part in @($LogPath, (Join-Path $WorkRoot "$Name.err.txt")))
    {
        if (Test-Path -LiteralPath $Part) { $Captured += (Get-Content -LiteralPath $Part -Raw -ErrorAction SilentlyContinue) }
    }

    # The state file is part of the root's contents, so whether the run kept it
    # has to be read before the root is restored.
    $StateFile = Join-Path $InventoryRoot ('.resume-state-{0}.json' -f $TenantID)
    $StatePresent = Test-Path -LiteralPath $StateFile -PathType Leaf

    # The outer bundle and one inner report are copied out before the root is
    # restored, so the bundle tests run against a stable input.
    $BundleCopy = $null
    $InnerCopy = $null
    if ($Case.BundleTests)
    {
        $Bundle = @(Get-ChildItem -LiteralPath $InventoryRoot -Filter 'AllSubscriptions_ResourcesReport_*.zip' -File -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -ge $StartedAt } | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
        if ($Bundle.Count -gt 0)
        {
            $BundleCopy = Join-Path $WorkRoot $Bundle[0].Name
            Copy-Item -LiteralPath $Bundle[0].FullName -Destination $BundleCopy -Force
            # The obfuscation suites inspect an INNER per-subscription zip, which
            # only exists inside the bundle.
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $Archive = [System.IO.Compression.ZipFile]::OpenRead($BundleCopy)
            try
            {
                $Member = @($Archive.Entries | Where-Object { $_.FullName -like 'ResourcesReport_*.zip' } | Select-Object -First 1)
                if ($Member.Count -gt 0)
                {
                    $InnerCopy = Join-Path $WorkRoot $Member[0].Name
                    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($Member[0], $InnerCopy, $true)
                }
            }
            finally { $Archive.Dispose() }
        }
    }

    $Restore = Restore-InventoryRoot -Root $InventoryRoot -Before $Snapshot -StartedAt $StartedAt
    $RootLabel = if ($Restore.Matches) { 'restored' } else { 'MISMATCH' }
    Write-Host ("  inventory root: deleted {0}, left {1}, now {2} entries, {3}" -f $Restore.Deleted, $Restore.Left, $Restore.NowCount, $RootLabel) `
        -ForegroundColor $(if ($Restore.Matches) { 'DarkGray' } else { 'Red' })
    if ($Restore.Removed -gt 0)
    {
        Write-Host ("  WARNING: {0} entry/entries present before the case are gone now" -f $Restore.Removed) -ForegroundColor Red
    }

    # ---- expectations ----
    $ExitMatch = [regex]::Match($Captured, 'WRAPPER_EXIT=(?<Code>-?\d+)')
    $ActualExit = if ($ExitMatch.Success) { [int]$ExitMatch.Groups['Code'].Value } else { $null }
    $ExitOk = ($null -ne $ActualExit -and $ActualExit -eq $Case.ExitCode)
    Write-Host ("  exit code: expected {0}, got {1} - {2}" -f $Case.ExitCode, $(if ($null -eq $ActualExit) { 'none' } else { $ActualExit }), $(if ($ExitOk) { 'ok' } else { 'WRONG' })) `
        -ForegroundColor $(if ($ExitOk) { 'Green' } else { 'Red' })

    $Met = 0
    $Unmet = @()
    foreach ($Label in $Case.Expect.Keys)
    {
        if ($Captured -match $Case.Expect[$Label]) { $Met++ }
        else { $Unmet += $Label }
    }
    Write-Host ("  expectations: {0} met, {1} unmet" -f $Met, $Unmet.Count) -ForegroundColor $(if ($Unmet.Count -eq 0) { 'Green' } else { 'Red' })
    foreach ($Label in $Unmet) { Write-Host ("    NOT MET: the run never {0}" -f $Label) -ForegroundColor Red }

    $StateOk = $true
    if ($Case.ContainsKey('StateKept'))
    {
        $StateOk = ($StatePresent -eq $Case.StateKept)
        Write-Host ("  resume state: expected {0}, found {1} - {2}" -f $(if ($Case.StateKept) { 'kept' } else { 'cleared' }), $(if ($StatePresent) { 'kept' } else { 'cleared' }), $(if ($StateOk) { 'ok' } else { 'WRONG' })) `
            -ForegroundColor $(if ($StateOk) { 'Green' } else { 'Red' })
    }

    # ---- bundle tests ----
    $TestsLabel = 'n/a'
    $TestsOk = $true
    if ($Case.BundleTests)
    {
        if ($null -eq $BundleCopy -or $null -eq $InnerCopy)
        {
            $TestsOk = $false
            $TestsLabel = 'no bundle'
            Write-Host "  bundle tests: the run produced no outer bundle with an inner report, so nothing was checked" -ForegroundColor Red
        }
        else
        {
            $env:TEST_ALLSUB_BUNDLE = $BundleCopy
            $env:TEST_ZIP_PATH = $InnerCopy
            $env:TEST_USER_EMAIL = $Ctx.Account.Id
            Remove-Item Env:TEST_SUBSCRIPTION_ID -ErrorAction SilentlyContinue
            Remove-Item Env:TEST_DICT_PATH -ErrorAction SilentlyContinue
            try
            {
                $Cfg = New-PesterConfiguration
                $Cfg.Run.Path = @($Case.BundleTests | ForEach-Object { Join-Path $PSScriptRoot $_ })
                $Cfg.Run.PassThru = $true
                $Cfg.Output.Verbosity = 'None'
                $Res = Invoke-Pester -Configuration $Cfg
                $Failed = $Res.FailedCount
                # A container whose body throws before any It runs leaves
                # FailedCount at 0, so a non-empty ErrorRecord counts as a failure -
                # the same detection Invoke-ScenarioMatrix.ps1 uses.
                $Crashed = @($Res.Containers | Where-Object { @($_.ErrorRecord).Count -gt 0 })
                $Failed += $Crashed.Count
                $TestsOk = ($Failed -eq 0 -and $Res.PassedCount -gt 0)
                $TestsLabel = ("{0}/{1}/{2}" -f $Res.PassedCount, $Failed, $Res.SkippedCount)
                Write-Host ("  bundle tests: passed {0}, failed {1}, skipped {2}" -f $Res.PassedCount, $Failed, $Res.SkippedCount) `
                    -ForegroundColor $(if ($TestsOk) { 'Green' } else { 'Red' })
                foreach ($Test in @($Res.Failed)) { Write-Host ("    FAIL: {0}" -f $Test.ExpandedName) -ForegroundColor Red }
                foreach ($Container in $Crashed) { Write-Host ("    FAIL (discovery): {0}" -f ($Container.ErrorRecord | Select-Object -First 1)) -ForegroundColor Red }
                if ($Res.PassedCount -eq 0)
                {
                    Write-Host "    PROBLEM: every bundle test skipped, so the bundle was not actually checked" -ForegroundColor Red
                }
            }
            finally
            {
                Remove-Item Env:TEST_ALLSUB_BUNDLE -ErrorAction SilentlyContinue
                Remove-Item Env:TEST_ZIP_PATH -ErrorAction SilentlyContinue
                Remove-Item Env:TEST_USER_EMAIL -ErrorAction SilentlyContinue
            }
        }
    }

    $Passed = $ExitOk -and ($Unmet.Count -eq 0) -and $StateOk -and $TestsOk -and $Restore.Matches
    if (-not $Passed) { $AnyFailed = $true }
    Write-Host ("  {0}" -f $(if ($Passed) { 'PASS' } else { 'FAIL' })) -ForegroundColor $(if ($Passed) { 'Green' } else { 'Red' })

    $Summary += [pscustomobject]@{
        Case   = $Name
        Exit   = $(if ($null -eq $ActualExit) { 'none' } else { [string]$ActualExit })
        Met    = $Met
        Unmet  = $Unmet.Count
        Tests  = $TestsLabel
        Root   = $RootLabel
        Result = $(if ($Passed) { 'PASS' } else { 'FAIL' })
    }
}

# -------------------------------------------------------------------------
# Summary.
# -------------------------------------------------------------------------
Write-Host ""
Write-Host "Summary (bundle tests are passed/failed/skipped)" -ForegroundColor Cyan
$Summary | Format-Table -AutoSize | Out-String -Width 200 | Write-Host

$Final = @(Get-ChildItem -LiteralPath $InventoryRoot -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name } | Sort-Object)
$RootClean = (@($Snapshot | Where-Object { $Final -notcontains $_ }).Count -eq 0 -and $Final.Count -eq $Snapshot.Count)
Write-Host ("Inventory root: {0} entries at the start, {1} now - {2}" -f $Snapshot.Count, $Final.Count, $(if ($RootClean) { 'restored' } else { 'NOT restored' })) `
    -ForegroundColor $(if ($RootClean) { 'Green' } else { 'Red' })

if ($KeepOutput -or $AnyFailed -or -not $RootClean)
{
    Write-Host ("Transcripts kept in {0} - they carry REAL subscription and resource names, so do not share them." -f $WorkRoot) -ForegroundColor Yellow
}
else
{
    Remove-Item -LiteralPath $WorkRoot -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Work directory removed." -ForegroundColor DarkGray
}

if ($AnyFailed -or -not $RootClean) { exit 1 }
exit 0
