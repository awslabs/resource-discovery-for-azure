#
# A subscription whose report was written but whose metrics or consumption were
# skipped or left incomplete (ResourceInventory.ps1 appended an entry to
# $Global:MetricsFailedSubs or $Global:ConsumptionFailedSubs during its call) is
# not recorded as completed. It goes into the retry list (FailedAttempts), so
# -Resume does not skip it and -ResumeFailedOnly retries it; an earlier run's
# completion of it ends. It is not a failed subscription.
#
#   - Get-IncompleteDataReason counts only what the call appended.
#   - The sequential loop, the one-subscription fallback and the parallel
#     parent's aggregation are lifted from the wrapper's AST and run as written;
#     the parallel path runs the real stream worker with its Az context import
#     mocked. A stand-in ResourceInventory.ps1 writes one report per call and
#     appends the same entries the real script appends when a phase is skipped.
#
# Run with: Invoke-Pester ./Tests/IncompleteDataRetry.Tests.ps1 -Output Detailed

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:RepoRoot 'Functions/Common.Functions.ps1')
    . (Join-Path $script:RepoRoot 'Functions/RunAllSubscriptions.Functions.ps1')

    $TmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { '/tmp' }
    $script:TestBase = Join-Path $TmpBase ('IncompleteDataRetryTest_' + [guid]::NewGuid().ToString().Substring(0, 8))
    New-Item -ItemType Directory -Path $script:TestBase -Force | Out-Null

    $script:MetricsMsg = 'Metrics phase skipped: no usable Azure context/token after one reconnect attempt.'
    $script:ConsumptionMsg = 'Consumption phase skipped: no usable Azure context/token after one reconnect attempt.'

    # Stand-in for ResourceInventory.ps1: one report per call, and for the ids
    # in the knobs the entries the real script appends when the metrics phase or
    # the consumption phase is skipped for sign-in (the consumption one is
    # '(auth)', not the subscription id).
    $script:FakeRoot = Join-Path $script:TestBase 'fake-tool'
    New-Item -ItemType Directory -Path $script:FakeRoot -Force | Out-Null
    @'
param([string]$TenantID, [string]$SubscriptionID, [switch]$RunAllSubs, [switch]$Obfuscate, [switch]$SkipMetrics, [switch]$SkipConsumption, [switch]$DeviceLogin, [int]$ConcurrencyLimit)
if (@($Global:RdaIncompleteTestFailIds) -contains $SubscriptionID) { throw 'stand-in failure for this subscription' }
$Root = $Global:RdaIncompleteTestRoot
$Stamp = (Get-Date -Format 'yyyyMMddHHmmssfff') + $SubscriptionID
$Folder = Join-Path $Root ('ResourcesReport' + $Stamp)
New-Item -ItemType Directory -Path $Folder -Force | Out-Null
$Stage = Join-Path $Root ('.stage-' + $Stamp)
New-Item -ItemType Directory -Path $Stage -Force | Out-Null
Set-Content -LiteralPath (Join-Path $Stage ('ResourcesReport_{0}.html' -f $Stamp)) -Value '<html></html>' -Encoding utf8
$Zip = Join-Path $Folder ('ResourcesReport_{0}.zip' -f $Stamp)
Compress-Archive -Path (Join-Path $Stage '*') -DestinationPath $Zip -Force
Remove-Item -LiteralPath $Stage -Recurse -Force
if (@($Global:RdaIncompleteTestMetricsIds) -contains $SubscriptionID)
{
    if ($null -eq $Global:MetricsFailedSubs) { $Global:MetricsFailedSubs = @() }
    $Global:MetricsFailedSubs += [pscustomobject]@{ Name = 'Sub'; Id = $SubscriptionID; Message = 'Metrics phase skipped: no usable Azure context/token after one reconnect attempt.' }
}
if ($null -eq $Global:ConsumptionFailedSubs) { $Global:ConsumptionFailedSubs = @() }
if (@($Global:RdaIncompleteTestConsumptionIds) -contains $SubscriptionID)
{
    $Global:ConsumptionFailedSubs += [pscustomobject]@{ Name = '(all subscriptions)'; Id = '(auth)'; Message = 'Consumption phase skipped: no usable Azure context/token after one reconnect attempt.' }
}
$Global:ZipOutputFile = $Zip
$Global:Resources = @(1)
$Global:ResourceCount = 1
'@ | Set-Content -LiteralPath (Join-Path $script:FakeRoot 'ResourceInventory.ps1') -Encoding utf8

    # --- Wrapper code lifted from its AST and run as written ------------------
    $Tokens = $null
    $ParseErrors = $null
    $WrapperPath = Join-Path $script:RepoRoot 'Run-AllSubscriptions.ps1'
    $Ast = [System.Management.Automation.Language.Parser]::ParseFile($WrapperPath, [ref]$Tokens, [ref]$ParseErrors)
    $Top = @($Ast.EndBlock.Statements)

    # The sequential failure log goes under $HOME/InventoryReports; point it at scratch.
    $Global:RdaIncompleteTestHome = Join-Path $script:TestBase 'home'
    New-Item -ItemType Directory -Path $Global:RdaIncompleteTestHome -Force | Out-Null

    $SeqIf = @($Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.IfStatementAst] -and $args[0].Clauses[0].Item1.Extent.Text -eq '$ParallelStreams -le 1' }, $true))
    if ($SeqIf.Count -ne 1) { throw "Expected one 'if (`$ParallelStreams -le 1)' in the wrapper, found $($SeqIf.Count)." }
    $SeqText = $SeqIf[0].Clauses[0].Item2.Extent.Text -replace '\$PSScriptRoot', '$FakeScriptRoot' -replace '\$HOME\b', '$Global:RdaIncompleteTestHome'
    $script:SeqBlock = [scriptblock]::Create(
        "param(`$FakeScriptRoot, `$Subscriptions, `$Resume, `$CompletedIds, `$FailedAttempts, `$CompletedReports, `$InventoryRoot, `$ResumeStateFile, `$TenantID)`n" +
        "`$Obfuscate = `$false; `$SkippedCount = 0; `$SkippedSubscriptions = @(); `$SubResourceCounts = @(); `$FailedSubscriptions = @(); `$DiagFile = `$null; `$InventoryPassthrough = @{ ConcurrencyLimit = 6 }`n" +
        ". " + $SeqText + "`n" +
        "[pscustomobject]@{ SkippedSubscriptions = @(`$SkippedSubscriptions); SubResourceCounts = @(`$SubResourceCounts); FailedSubscriptions = @(`$FailedSubscriptions) }")

    $OneIf = @($Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.IfStatementAst] -and $args[0].Clauses[0].Item1.Extent.Text -eq '$StreamCount -le 1' }, $true))
    if ($OneIf.Count -ne 1) { throw "Expected one 'if (`$StreamCount -le 1)' in the wrapper, found $($OneIf.Count)." }
    $script:FallbackBlock = [scriptblock]::Create(
        "param(`$FakeScriptRoot, `$Subscriptions, `$CompletedIds, `$FailedAttempts, `$CompletedReports, `$InventoryRoot, `$ResumeStateFile, `$TenantID)`n" +
        "`$StreamCount = 1; `$Obfuscate = `$false; `$SubResourceCounts = @(); `$FailedSubscriptions = @(); `$DiagFile = `$null; `$InventoryPassthrough = @{ ConcurrencyLimit = 6 }`n" +
        # The parallel path builds the list it slices before this block; these runs are not -Resume runs, so it is every subscription.
        "`$PendingSubscriptions = @(`$Subscriptions)`n" +
        ($OneIf[0].Extent.Text -replace '\$PSScriptRoot', '$FakeScriptRoot') + "`n" +
        "[pscustomobject]@{ FailedSubscriptions = @(`$FailedSubscriptions) }")

    $Orch = @($Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.TryStatementAst] -and $args[0].Body.Extent.Text -match [regex]::Escape("`$WorkerScript = Join-Path `$PSScriptRoot 'Run-AllSubscriptions.Stream.ps1'") }, $true))
    if ($Orch.Count -ne 1) { throw "Expected one stream-orchestration try block in the wrapper, found $($Orch.Count)." }
    $Body = @($Orch[0].Body.Statements)
    $AggStart = -1
    for ($i = 0; $i -lt $Body.Count; $i++)
    {
        if ($Body[$i] -is [System.Management.Automation.Language.ForEachStatementAst] -and $Body[$i].Condition.Extent.Text -eq '$StreamSummaries' -and $Body[$i].Body.Extent.Text -match 'ResourceCounts') { $AggStart = $i; break }
    }
    if ($AggStart -lt 0) { throw 'Expected the stream-summary aggregation loop in the wrapper.' }
    $script:AggregateBlock = [scriptblock]::Create(
        "param(`$StreamSummaries, `$InventoryRoot, `$TenantID, `$ResumeStateFile, `$CompletedIds, `$FailedAttempts, `$CompletedReports)`n" +
        "`$SkippedSubscriptions = @(); `$SubResourceCounts = @(); `$FailedSubscriptions = @(); `$DiagFile = `$null`n" +
        (@($Body[$AggStart..($Body.Count - 1)] | ForEach-Object { $_.Extent.Text }) -join "`n") + "`n" +
        "[pscustomobject]@{ FailedSubscriptions = @(`$FailedSubscriptions) }")

    # The -ResumeFailedOnly filter at startup, as written.
    $FailedOnly = @($Top | Where-Object { $_ -is [System.Management.Automation.Language.IfStatementAst] -and $_.Clauses[0].Item1.Extent.Text -eq '$ResumeFailedOnly' } | Select-Object -First 1)
    if ($FailedOnly.Count -ne 1) { throw "Expected a top-level 'if (`$ResumeFailedOnly)' in the wrapper." }
    $script:FailedOnlyBlock = [scriptblock]::Create(
        "param(`$Subscriptions, `$FailedAttempts, `$ResumeStateFile)`n`$ResumeFailedOnly = `$true`n" +
        "function Exit-Wrapper { param([int]`$Code) throw ('Exit-Wrapper ' + `$Code) }`n" +
        $FailedOnly[0].Extent.Text + "`n@(`$Subscriptions | ForEach-Object { `$_.Id })")

    function script:Invoke-Worker
    {
        param($Root, [string[]]$Ids, [string[]]$Names)
        $WorkerArgs = @{
            TenantID           = 't'
            StreamId           = '0'
            InventoryRoot      = $Root
            ScriptRoot         = $script:FakeRoot
            AzContextPath      = (Join-Path $Root 'ctx.json')
            StreamSummaryPath  = (Join-Path $Root '.rda-stream-0-summary.json')
            StreamFailuresPath = (Join-Path $Root 'failures-stream-0.log')
            SubscriptionIds    = $Ids
            SubscriptionNames  = $Names
            ConcurrencyLimit   = 6
        }
        & (Join-Path $script:RepoRoot 'Run-AllSubscriptions.Stream.ps1') @WorkerArgs 6>$null
    }

    function script:Read-State
    {
        param([string]$Path)
        $Failed = @(Get-FailedAttempts -Path $Path -Tenant 't' | Where-Object { $null -ne $_ })
        $Reports = if (Test-Path -LiteralPath $Path) { @((Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json).CompletedReports | Where-Object { $null -ne $_ }) } else { @() }
        return [pscustomobject]@{
            Completed = @(Get-CompletedSubscriptionIds -Path $Path -Tenant 't')
            Failed    = @($Failed | ForEach-Object Id)
            Reasons   = @($Failed | ForEach-Object { [string]$_.Reason })
            Reports   = @($Reports | ForEach-Object { [string]$_.Id })
        }
    }

    function script:Invoke-Seq
    {
        param([object[]]$Subs, [bool]$Resume = $false)
        $S = script:Read-State -Path $script:State
        $Reports = if (Test-Path -LiteralPath $script:State) { @((Get-Content -LiteralPath $script:State -Raw | ConvertFrom-Json).CompletedReports | Where-Object { $null -ne $_ }) } else { @() }
        return (& $script:SeqBlock $script:FakeRoot @($Subs) $Resume $S.Completed @(Get-FailedAttempts -Path $script:State -Tenant 't') $Reports $script:Root $script:State 't' 6>$null)
    }
}

AfterAll {
    Remove-Variable -Name RdaIncompleteTestRoot, RdaIncompleteTestHome, RdaIncompleteTestFailIds, RdaIncompleteTestMetricsIds, RdaIncompleteTestConsumptionIds, MetricsFailedSubs, ConsumptionFailedSubs -Scope Global -ErrorAction SilentlyContinue
    if ($script:TestBase -and (Test-Path $script:TestBase)) { Remove-Item -Path $script:TestBase -Recurse -Force }
}

Describe 'Get-IncompleteDataReason' {
    It 'is $null when the call appended nothing, whatever the lists held before it' {
        $Before = @([pscustomobject]@{ Id = 'sub-x'; Message = 'm' })
        Get-IncompleteDataReason -MetricsEntries $Before -MetricsBefore 1 -ConsumptionEntries $Before -ConsumptionBefore 1 | Should -BeNullOrEmpty
        Get-IncompleteDataReason -MetricsEntries $null -ConsumptionEntries @() | Should -BeNullOrEmpty
    }

    It 'names the metrics gap the call appended' {
        $Entries = @([pscustomobject]@{ Id = 'sub-x'; Message = 'old' }, [pscustomobject]@{ Id = 'sub-a'; Message = $script:MetricsMsg })
        Get-IncompleteDataReason -MetricsEntries $Entries -MetricsBefore 1 -ConsumptionEntries @() | Should -Be ('Metrics incomplete: ' + $script:MetricsMsg)
    }

    It 'names a consumption sign-in skip, which carries no subscription id, and a lone entry that is not in an array' {
        $Lone = [pscustomobject]@{ Name = '(all subscriptions)'; Id = '(auth)'; Message = $script:ConsumptionMsg }
        Get-IncompleteDataReason -MetricsEntries @() -ConsumptionEntries $Lone -ConsumptionBefore 0 | Should -Be ('Consumption incomplete: ' + $script:ConsumptionMsg)
    }

    It 'names both phases, each message once' {
        $M = @([pscustomobject]@{ Id = 'sub-a'; Message = $script:MetricsMsg }, [pscustomobject]@{ Id = 'sub-a'; Message = $script:MetricsMsg })
        $C = @([pscustomobject]@{ Id = '(auth)'; Message = $script:ConsumptionMsg })
        Get-IncompleteDataReason -MetricsEntries $M -ConsumptionEntries $C | Should -Be ('Metrics and Consumption incomplete: {0} {1}' -f $script:MetricsMsg, $script:ConsumptionMsg)
        Get-IncompleteDataReason -MetricsEntries @([pscustomobject]@{ Id = 'sub-a'; Message = '' }) | Should -Be 'Metrics incomplete.'
    }
}

Describe 'A subscription with metrics or consumption left incomplete stays in the retry list' {
    BeforeAll {
        Mock Import-Module -ParameterFilter { $Name -eq 'Az.Accounts' } -MockWith { }
        Mock Disable-AzContextAutosave -MockWith { }
        Mock Import-AzContext -MockWith { }
    }

    BeforeEach {
        $script:Root = Join-Path $script:TestBase ([guid]::NewGuid().ToString().Substring(0, 8))
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        $script:State = Join-Path $script:Root '.resume-state-t.json'
        $Global:RdaIncompleteTestRoot = $script:Root
        $Global:RdaIncompleteTestFailIds = @()
        $Global:RdaIncompleteTestMetricsIds = @()
        $Global:RdaIncompleteTestConsumptionIds = @()
        $Global:MetricsFailedSubs = @()
        $Global:ConsumptionFailedSubs = @()
        $global:LASTEXITCODE = 0
        $script:A = [pscustomobject]@{ Id = 'sub-a'; Name = 'Sub A' }
        $script:B = [pscustomobject]@{ Id = 'sub-b'; Name = 'Sub B' }
    }

    It 'sequential, <Phase> skipped for sub-a while sub-b fails: sub-a is in the retry list, and -Resume collects it again' -TestCases @(
        @{ Phase = 'metrics'; Prefix = 'Metrics incomplete: ' },
        @{ Phase = 'consumption'; Prefix = 'Consumption incomplete: ' }
    ) {
        if ($Phase -eq 'metrics') { $Global:RdaIncompleteTestMetricsIds = @('sub-a') } else { $Global:RdaIncompleteTestConsumptionIds = @('sub-a') }
        $Global:RdaIncompleteTestFailIds = @('sub-b')
        $Run1 = script:Invoke-Seq -Subs @($script:A, $script:B)
        $After1 = script:Read-State -Path $script:State

        $After1.Completed | Should -BeNullOrEmpty -Because 'sub-a''s report is missing its data'
        $After1.Reports | Should -BeNullOrEmpty
        $After1.Failed | Should -Be @('sub-a', 'sub-b')
        $After1.Reasons[0] | Should -BeLike ($Prefix + '*')
        @($Run1.FailedSubscriptions) | Should -Be @('Sub B') -Because 'a subscription with incomplete data is not a failed subscription'

        $Global:RdaIncompleteTestMetricsIds = @()
        $Global:RdaIncompleteTestConsumptionIds = @()
        $Global:RdaIncompleteTestFailIds = @()
        $Run2 = script:Invoke-Seq -Subs @($script:A, $script:B) -Resume $true
        $After2 = script:Read-State -Path $script:State

        @($Run2.SkippedSubscriptions) | Should -BeNullOrEmpty -Because '-Resume must not skip sub-a'
        @($Run2.SubResourceCounts | ForEach-Object Id) | Should -Be @('sub-a', 'sub-b')
        $After2.Completed | Should -Be @('sub-a', 'sub-b')
        $After2.Failed | Should -BeNullOrEmpty -Because 'both were collected in full'
    }

    It 'sequential: an earlier run''s completion of sub-a ends when a later run leaves its metrics incomplete' {
        $null = script:Invoke-Seq -Subs @($script:A, $script:B)
        (script:Read-State -Path $script:State).Completed | Should -Be @('sub-a', 'sub-b')

        $Global:RdaIncompleteTestMetricsIds = @('sub-a')
        $null = script:Invoke-Seq -Subs @($script:A)
        $After = script:Read-State -Path $script:State

        $After.Completed | Should -Be @('sub-b')
        $After.Reports | Should -Be @('sub-b')
        $After.Failed | Should -Be @('sub-a')
    }

    It 'sequential: an entry a previous subscription appended does not mark the next one incomplete' {
        $Global:RdaIncompleteTestConsumptionIds = @('sub-a')
        $null = script:Invoke-Seq -Subs @($script:A, $script:B)
        $After = script:Read-State -Path $script:State

        $After.Completed | Should -Be @('sub-b')
        $After.Failed | Should -Be @('sub-a')
        @($Global:ConsumptionFailedSubs).Count | Should -Be 1 -Because 'the run-wide list the summary reads is left as the inner script wrote it'
    }

    It '-ResumeFailedOnly after a run whose only problem was a skipped phase retries that subscription' {
        $Global:RdaIncompleteTestMetricsIds = @('sub-a')
        $Global:RdaIncompleteTestConsumptionIds = @('sub-a')
        $null = script:Invoke-Seq -Subs @($script:A, $script:B)

        $Retried = @(& $script:FailedOnlyBlock @($script:A, $script:B) @(Get-FailedAttempts -Path $script:State -Tenant 't') $script:State 6>$null)
        $Retried | Should -Be @('sub-a') -Because 'the run printed FAILED (auth) for sub-a, so there is something to retry'
    }

    It 'one-subscription fallback: metrics skipped for sub-a puts it in the retry list and ends an earlier completion' {
        $null = script:Invoke-Seq -Subs @($script:A)
        $Global:RdaIncompleteTestMetricsIds = @('sub-a')
        $S = script:Read-State -Path $script:State
        $Reports = @((Get-Content -LiteralPath $script:State -Raw | ConvertFrom-Json).CompletedReports | Where-Object { $null -ne $_ })
        $Out = & $script:FallbackBlock $script:FakeRoot @($script:A) $S.Completed @() $Reports $script:Root $script:State 't' 6>$null
        $After = script:Read-State -Path $script:State

        $After.Completed | Should -BeNullOrEmpty
        $After.Reports | Should -BeNullOrEmpty
        $After.Failed | Should -Be @('sub-a')
        $After.Reasons[0] | Should -BeLike 'Metrics incomplete: *'
        @($Out.FailedSubscriptions) | Should -BeNullOrEmpty
    }

    It 'parallel: the stream keeps sub-a out of its completed set and names it, and the merge ends an earlier completion' {
        $null = script:Invoke-Seq -Subs @($script:A, $script:B)
        $S = script:Read-State -Path $script:State
        $Reports = @((Get-Content -LiteralPath $script:State -Raw | ConvertFrom-Json).CompletedReports | Where-Object { $null -ne $_ })

        $Global:RdaIncompleteTestConsumptionIds = @('sub-a')
        script:Invoke-Worker -Root $script:Root -Ids @('sub-a', 'sub-b') -Names @('Sub A', 'Sub B')
        $StreamState = Get-Content -LiteralPath (Join-Path $script:Root '.resume-state-t-stream-0.json') -Raw | ConvertFrom-Json
        $Summary = Get-Content -LiteralPath (Join-Path $script:Root '.rda-stream-0-summary.json') -Raw | ConvertFrom-Json

        @($StreamState.Completed) | Should -Be @('sub-b')
        @($StreamState.FailedAttempts | ForEach-Object Id) | Should -Be @('sub-a')
        @($StreamState.Reports | ForEach-Object Id) | Should -Be @('sub-b')
        @($Summary.Incomplete | ForEach-Object Id) | Should -Be @('sub-a')
        @($Summary.Failed) | Should -BeNullOrEmpty
        $Summary.Status | Should -Be 'ok'

        $Streams = @([pscustomobject]@{ StreamId = 0; SummaryPath = (Join-Path $script:Root '.rda-stream-0-summary.json'); FailuresPath = (Join-Path $script:Root 'failures-stream-0.log'); SubCount = 2 })
        $Agg = & $script:AggregateBlock $Streams $script:Root 't' $script:State $S.Completed @() $Reports 6>$null
        $After = script:Read-State -Path $script:State

        $After.Completed | Should -Be @('sub-b') -Because 'the earlier completion of sub-a ends'
        $After.Reports | Should -Be @('sub-b')
        $After.Failed | Should -Be @('sub-a') -Because 'the merge keeps the retry entry'
        $After.Reasons[0] | Should -BeLike 'Consumption incomplete: *'
        @($Agg.FailedSubscriptions) | Should -BeNullOrEmpty
    }
}
