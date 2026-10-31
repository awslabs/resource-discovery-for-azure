# A subscription that keeps failing is on the retry list (FailedAttempts in the
# resume state), and every -Resume or -ResumeFailedOnly run collected it again,
# however many runs in a row it had failed. After 3 failed runs in a row, -Resume
# and -ResumeFailedOnly skip it, name it with its last reason before the work
# starts, and the summary and RunSummary.log keep it as incomplete. A run without
# -Resume still collects it. The exit code does not change.
#
# The wrapper code is lifted from its AST and run as written: the startup reads of
# the resume state, the -Resume and -ResumeFailedOnly blocks, the sequential loop,
# the parallel branch (its streams run the real Run-AllSubscriptions.Stream.ps1 in
# this process one after the other, with the Az context import, Save-AzContext and
# the job commands stood in), the resume-state cleanup, the summary, the
# RunSummary.log content and the exit code. The access check is a stand-in that
# finds every subscription readable. A stand-in ResourceInventory.ps1 writes one
# report folder and zip per call, throws for the ids in $Global:RdaRlFailIds, and
# records a metrics gap for the ids in $Global:RdaRlIncompleteIds.
#
# Run with: Invoke-Pester ./Tests/RetryLimit.Tests.ps1 -Output Detailed

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:RepoRoot 'Functions/Common.Functions.ps1')
    . (Join-Path $script:RepoRoot 'Functions/RunAllSubscriptions.Functions.ps1')

    $TmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { '/tmp' }
    $script:TestBase = Join-Path $TmpBase ('RetryLimitTest_' + [guid]::NewGuid().ToString().Substring(0, 8))
    New-Item -ItemType Directory -Path $script:TestBase -Force | Out-Null

    # The stand-in tool folder: a stand-in ResourceInventory.ps1 next to copies of the
    # real stream worker and functions, so both paths call the stand-in.
    $script:FakeRoot = Join-Path $script:TestBase 'fake-tool'
    New-Item -ItemType Directory -Path (Join-Path $script:FakeRoot 'Functions') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'Run-AllSubscriptions.Stream.ps1') -Destination $script:FakeRoot
    Copy-Item -Path (Join-Path $script:RepoRoot 'Functions/*.ps1') -Destination (Join-Path $script:FakeRoot 'Functions')
    $FakeInner = @'
param([string]$TenantID, [string]$SubscriptionID, [switch]$RunAllSubs, [switch]$Obfuscate, [switch]$SkipMetrics, [switch]$SkipConsumption, [switch]$DeviceLogin, [int]$ConcurrencyLimit)
$Global:RdaRlCalls = @(@($Global:RdaRlCalls | Where-Object { $_ }) + $SubscriptionID)
if (@($Global:RdaRlFailIds) -contains $SubscriptionID) { throw 'stand-in failure for this subscription' }
if (@($Global:RdaRlIncompleteIds) -contains $SubscriptionID)
{
    $Global:MetricsFailedSubs = @(@($Global:MetricsFailedSubs | Where-Object { $null -ne $_ }) + [pscustomobject]@{ Name = $SubscriptionID; Id = $SubscriptionID; Message = 'stand-in metrics gap' })
}
$Root = $Global:RdaRlRoot
$Stamp = (Get-Date -Format 'yyyyMMddHHmmssfff') + $SubscriptionID
$Folder = Join-Path $Root ('ResourcesReport' + $Stamp)
New-Item -ItemType Directory -Path $Folder -Force | Out-Null
$Zip = Join-Path $Folder ('ResourcesReport_{0}.zip' -f $Stamp)
$Html = Join-Path $Folder ('ResourcesReport_{0}.html' -f $Stamp)
Set-Content -LiteralPath $Html -Value '<html></html>' -Encoding utf8
Compress-Archive -Path $Html -DestinationPath $Zip -Force
$Global:ZipOutputFile = $Zip
$Global:Resources = @(1)
$Global:ResourceCount = 1
'@
    Set-Content -LiteralPath (Join-Path $script:FakeRoot 'ResourceInventory.ps1') -Value $FakeInner -Encoding utf8

    # --- Wrapper code lifted from its AST and run as written ------------------
    $Tokens = $null
    $ParseErrors = $null
    $script:WrapperPath = Join-Path $script:RepoRoot 'Run-AllSubscriptions.ps1'
    $Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:WrapperPath, [ref]$Tokens, [ref]$ParseErrors)
    $Top = @($Ast.EndBlock.Statements)
    function script:Find-TopIndex
    {
        param([scriptblock]$Match, [int]$After = -1, [string]$What)
        for ($i = $After + 1; $i -lt $Top.Count; $i++) { if (& $Match $Top[$i]) { return $i } }
        throw "Expected $What in Run-AllSubscriptions.ps1."
    }
    function script:Join-Top { param([int]$From, [int]$To) (@($Top[$From..$To] | ForEach-Object { $_.Extent.Text }) -join "`n") }
    # Every lifted piece calls the stand-in tool folder instead of the repository's,
    # and the sequential catch's inventory root ($HOME/InventoryReports, or
    # C:\InventoryReports on Windows) points at the test's home.
    function script:Set-TestPaths
    {
        param([string]$Text)
        (($Text -replace '\$PSScriptRoot', '$FakeScriptRoot') -replace '\$HOME\b', '$Global:RdaRlHome') -replace '"C:\\InventoryReports"', '"$Global:RdaRlHome/InventoryReports"'
    }

    # Startup: from the first read of the resume state to the up-front access check.
    # This holds the stranded-stream fold, the -Resume block, the -ResumeFailedOnly
    # filter and everything else the wrapper does before the check.
    $SeedAt = script:Find-TopIndex -What 'the startup read of the completed ids' -Match { param($s) $s.Extent.Text -match '^\$CompletedIds = (@\()?Get-CompletedSubscriptionIds ' }
    $ScopeAt = script:Find-TopIndex -After $SeedAt -What 'the access-check scope' -Match { param($s) $s.Extent.Text.StartsWith('$ScopeForProbe = ') }
    # The completed ids are read as an array: an empty or one-id list comes back
    # from Get-CompletedSubscriptionIds as $null or a bare string, and `+=` would
    # then join the next id onto it. A wrapper that already reads it this way is
    # left as written.
    $StartText = (script:Join-Top -From $SeedAt -To ($ScopeAt - 1)).Replace(
        '$CompletedIds = Get-CompletedSubscriptionIds -Path $ResumeStateFile -Tenant $TenantID' + "`n",
        '$CompletedIds = @(Get-CompletedSubscriptionIds -Path $ResumeStateFile -Tenant $TenantID | Where-Object { $_ })' + "`n")

    # The access check: its scope as written, then a stand-in that finds every
    # subscription readable; then the record of what it skipped, as written.
    $GateText = $Top[$ScopeAt].Extent.Text + "`n`$AccessDecision = [pscustomobject]@{ InaccessibleIds = @() }`n"
    $RecordText = @($Top | Where-Object { $_ -is [System.Management.Automation.Language.IfStatementAst] -and $_.Clauses[0].Item1.Extent.Text -eq '$ScopeForProbe.Count -gt 0' -and $_.Extent.Text.Contains('-NotReadable $NotReadableIds') } | ForEach-Object { $_.Extent.Text }) -join "`n"

    # The sequential loop: the body of `if ($ParallelStreams -le 1)`.
    $SeqIf = @($Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.IfStatementAst] -and $args[0].Clauses[0].Item1.Extent.Text -eq '$ParallelStreams -le 1' }, $true))
    if ($SeqIf.Count -ne 1) { throw "Expected one 'if (`$ParallelStreams -le 1)' in the wrapper, found $($SeqIf.Count)." }
    $SeqText = script:Set-TestPaths -Text $SeqIf[0].Clauses[0].Item2.Extent.Text

    # The parallel path: the else branch of `if ($ParallelStreams -le 1)`, as written,
    # with its one-subscription path. Start-Job runs the job's script block in this
    # process, so the streams run the real worker one after the other; the other job
    # commands and Save-AzContext are stand-ins.
    $ParText = script:Set-TestPaths -Text $SeqIf[0].ElseClause.Extent.Text
    $JobShims = "function Save-AzContext { [CmdletBinding()] param([string]`$Path, [switch]`$Force) }`n" +
    "function Start-Job { [CmdletBinding()] param([scriptblock]`$ScriptBlock, [object[]]`$ArgumentList) `$null = & `$ScriptBlock @ArgumentList; [pscustomobject]@{ State = 'Completed'; Id = 0 } }`n" +
    "function Receive-Job { [CmdletBinding()] param([Parameter(ValueFromPipeline = `$true)]`$InputObject) process { } }`n" +
    "function Stop-Job { [CmdletBinding()] param(`$Job) }`n" +
    "function Remove-Job { [CmdletBinding()] param([Parameter(ValueFromPipeline = `$true)]`$InputObject, [switch]`$Force) process { } }`n"
    # The orchestration's try body up to its aggregation: the streams ran and wrote
    # their state, and the session ended before the parent merged it.
    $Orch = @($Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.TryStatementAst] -and $args[0].Body.Extent.Text -match [regex]::Escape("`$WorkerScript = Join-Path `$PSScriptRoot 'Run-AllSubscriptions.Stream.ps1'") }, $true))
    if ($Orch.Count -ne 1) { throw "Expected one stream-orchestration try block in the wrapper, found $($Orch.Count)." }
    $Body = @($Orch[0].Body.Statements)
    $AggAt = -1
    for ($i = 0; $i -lt $Body.Count; $i++)
    {
        if ($Body[$i] -is [System.Management.Automation.Language.ForEachStatementAst] -and $Body[$i].Condition.Extent.Text -eq '$StreamSummaries' -and $Body[$i].Body.Extent.Text -match 'ResourceCounts') { $AggAt = $i; break }
    }
    if ($AggAt -lt 0) { throw 'Expected the stream-summary aggregation loop in the wrapper.' }
    $ParLaunchPrelude = "`$StreamCount = [Math]::Min(`$ParallelStreams, `$Subscriptions.Count); `$AzContextSnapshot = Join-Path `$InventoryRoot 'ctx.json'; `$Jobs = @(); `$StreamSummaries = @()`n"
    $ParLaunchText = script:Set-TestPaths -Text (@($Body[0..($AggAt - 1)] | ForEach-Object { $_.Extent.Text }) -join "`n")

    # The resume-state cleanup: every statement after the main-summary build up to
    # and including the clean-run clear.
    $MainSummaryAt = script:Find-TopIndex -What 'the main-summary build' -Match { param($s) $s -is [System.Management.Automation.Language.IfStatementAst] -and $s.Extent.Text -match 'New-RdaAllSubHtmlSummary -RunOutputDirectory' }
    $ClearAt = script:Find-TopIndex -After $MainSummaryAt -What 'the clean-run resume-state clear' -Match { param($s) $s -is [System.Management.Automation.Language.IfStatementAst] -and $s.Extent.Text.Contains('Resume state cleared (clean run).') }
    $CleanupText = script:Join-Top -From ($MainSummaryAt + 1) -To $ClearAt

    # The summary: from the failed-subscriptions block to the execution time.
    $AdviceAt = script:Find-TopIndex -After $ClearAt -What 'the failed-subscriptions summary' -Match { param($s) $s -is [System.Management.Automation.Language.IfStatementAst] -and $s.Clauses[0].Item1.Extent.Text -eq '$FailedSubscriptions.Count -gt 0' -and $s.Extent.Text.Contains('Subscriptions Failed:') }
    $TimeAt = script:Find-TopIndex -After $AdviceAt -What 'the execution-time line' -Match { param($s) $s.Extent.Text.StartsWith('Write-Host ("Execution Time:') }
    $AdviceText = script:Join-Top -From $AdviceAt -To $TimeAt

    # The RunSummary.log content, as the wrapper builds it for the bundle.
    $RunSummaryAst = @($Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] -and $args[0].Left.Extent.Text -eq '$RunSummaryLines' }, $true))
    if ($RunSummaryAst.Count -ne 1) { throw "Expected one '`$RunSummaryLines = ...' in the wrapper, found $($RunSummaryAst.Count)." }
    $RunSummaryText = $RunSummaryAst[0].Extent.Text

    # The exit code, as the wrapper computes it at the end.
    $ExitAt = script:Find-TopIndex -After $TimeAt -What 'the exit-code computation' -Match { param($s) $s.Extent.Text.StartsWith('$WrapperExitCode = Get-WrapperExitCode') }
    $ExitText = @($Top[($ExitAt - 2)..$ExitAt] | ForEach-Object { $_.Extent.Text }) -join "`n"

    # Each run starts the way a new wrapper process does: run-wide totals empty.
    $Prologue = "function Exit-Wrapper { param([int]`$Code) throw ('Exit-Wrapper ' + `$Code) }`n" +
    "`$Global:MetricsFailedSubs = @(); `$Global:ConsumptionFailedSubs = @(); `$Global:CollectorFailures = @(); `$Global:ConsumptionRecordCount = 0`n" +
    "`$Obfuscate = [bool]`$ObfuscateRun; `$SkippedCount = 0; `$SkippedSubscriptions = @(); `$SubResourceCounts = @(); `$FailedSubscriptions = @(); `$DiagFile = `$null`n" +
    "`$InventoryPassthrough = @{ ConcurrencyLimit = 6 }; `$WrapperTranscriptStarted = `$false; `$Elapsed = [timespan]::Zero`n" +
    "`$ConcurrencyLimit = 6; `$DeviceLogin = `$false; `$SkipMetrics = `$false; `$SkipConsumption = `$false; `$AllowPartialAccess = `$false`n" +
    "`$AllSubscriptions = @(`$Subscriptions); `$Excluded = @(); `$RunStartTime = Get-Date; `$BundleVer = 'test'`n" +
    "`$NoAccessSubs = @(); `$GenuinelyEmptySubs = @(); `$UnknownSubs = @(); `$ConsumptionRecordTotal = 0`n" +
    "`$AutoTune = [pscustomobject]@{ VCpu = 2; RamGB = 4 }; `$StreamsSrc = 'explicit'; `$ConcurrencySrc = 'auto'; `$AuthSkippedPhases = @(); `$UncarriedSkipped = @()`n"
    $Params = "param(`$FakeScriptRoot, `$Subscriptions, `$InventoryRoot, `$ResumeStateFile, `$TenantID, `$Resume, `$ResumeFailedOnly, `$ParallelStreams, `$ObfuscateRun)`n"
    $Result = "`n[pscustomobject]@{ Kind = 'run-result'; SubResourceCounts = @(`$SubResourceCounts); FailedSubscriptions = @(`$FailedSubscriptions); RunSummary = @(`$RunSummaryLines); WrapperExitCode = `$WrapperExitCode }"
    $Tail = "`n" + $CleanupText + "`n" + $AdviceText + "`n" + $RunSummaryText + "`n" + $ExitText + $Result

    $Start = $Params + $Prologue + $StartText + "`n" + $GateText + $RecordText + "`n"
    $script:SequentialBlock = [scriptblock]::Create($Start + ". " + $SeqText + $Tail)
    $script:ParallelBlock = [scriptblock]::Create($Start + $JobShims + ". " + $ParText + $Tail)
    $script:InterruptedParallelBlock = [scriptblock]::Create($Start + $JobShims + $ParLaunchPrelude + ". {`n" + $ParLaunchText + "`n}" + "`n[pscustomobject]@{ Kind = 'run-result' }")

    # Runs one wrapper run and returns its result, the lines it printed, the exit
    # code of a run that ended through Exit-Wrapper ($null when it ran to the end),
    # and the ids the stand-in was called for.
    function script:Invoke-Run
    {
        param([object[]]$Subs, [switch]$Resume, [switch]$ResumeFailedOnly, [int]$Streams = 1, [switch]$Interrupted, [switch]$Obfuscate)
        $Block = if ($Interrupted) { $script:InterruptedParallelBlock } elseif ($Streams -gt 1) { $script:ParallelBlock } else { $script:SequentialBlock }
        $Global:RdaRlCalls = @()
        $global:LASTEXITCODE = 0
        $Lines = [System.Collections.Generic.List[string]]::new()
        $Results = [System.Collections.Generic.List[object]]::new()
        $Code = $null
        try
        {
            & $Block $script:FakeRoot @($Subs) $script:Root $script:State 't' ([bool]$Resume) ([bool]$ResumeFailedOnly) $Streams ([bool]$Obfuscate) 6>&1 | ForEach-Object {
                if ($_ -is [System.Management.Automation.InformationRecord]) { $Lines.Add([string]$_.MessageData) }
                elseif ($_ -is [pscustomobject] -and $_.PSObject.Properties['Kind'] -and $_.Kind -eq 'run-result') { $Results.Add($_) }
            }
        }
        catch
        {
            if ($_.Exception.Message -match '^Exit-Wrapper (\d+)$') { $Code = [int]$Matches[1] } else { throw }
        }
        return [pscustomobject]@{ Result = ($Results | Select-Object -Last 1); Text = @($Lines); ExitCode = $Code; Calls = @($Global:RdaRlCalls | Where-Object { $_ }) }
    }

    # The retry-list entry of one subscription, read straight from the state file.
    function script:Get-Entry
    {
        param([string]$Id)
        if (-not (Test-Path -LiteralPath $script:State)) { return $null }
        return @((Get-Content -LiteralPath $script:State -Raw | ConvertFrom-Json).FailedAttempts | Where-Object { $null -ne $_ -and $_.Id -eq $Id }) | Select-Object -First 1
    }

    function script:Get-Lines
    {
        param([object]$Run, [string]$Like)
        return @($Run.Text | Where-Object { $_ -like $Like })
    }

    $script:A = [pscustomobject]@{ Id = 'sub-a'; Name = 'Sub A' }
    $script:B = [pscustomobject]@{ Id = 'sub-b'; Name = 'Sub B' }
    $script:C = [pscustomobject]@{ Id = 'sub-c'; Name = 'Sub C' }
    $script:X = [pscustomobject]@{ Id = 'sub-x'; Name = 'Sub X' }
    $script:Y = [pscustomobject]@{ Id = 'sub-y'; Name = 'Sub Y' }
    $script:NotRetriedX = 'Not retried: Sub X (sub-x) failed 3 runs in a row; last reason: stand-in failure for this subscription. To try it again, run ./ResourceInventory.ps1 -TenantID t -SubscriptionID sub-x on its own, or start a run without -Resume.'

    # A fresh home, inventory root and resume-state path for each test. The root is
    # <home>/InventoryReports, the path the wrapper's sequential catch also uses.
    function script:New-Case
    {
        $Global:RdaRlHome = Join-Path $script:TestBase ([guid]::NewGuid().ToString().Substring(0, 8))
        $script:Root = Join-Path $Global:RdaRlHome 'InventoryReports'
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        $Global:RdaRlRoot = $script:Root
        $Global:RdaRlFailIds = @()
        $Global:RdaRlIncompleteIds = @()
        $script:State = Join-Path $script:Root '.resume-state-t.json'
    }
}

AfterAll {
    Remove-Variable -Name RdaRlRoot, RdaRlFailIds, RdaRlIncompleteIds, RdaRlHome, RdaRlCalls -Scope Global -ErrorAction SilentlyContinue
    if ($script:TestBase -and (Test-Path $script:TestBase)) { Remove-Item -Path $script:TestBase -Recurse -Force }
}

Describe 'Retry limit on the sequential path' {
    BeforeEach { script:New-Case }

    It 'counts each failed run, and the fourth -Resume run does not collect a subscription that failed three runs in a row' {
        $Global:RdaRlFailIds = @('sub-x')
        $Subs = @($script:A, $script:B, $script:X)
        $Attempts = @()
        $XCalls = 0
        $Run = script:Invoke-Run -Subs $Subs
        $XCalls += @($Run.Calls | Where-Object { $_ -eq 'sub-x' }).Count
        $Attempts += [int](script:Get-Entry -Id 'sub-x').Attempts
        foreach ($n in 2..3)
        {
            $Run = script:Invoke-Run -Subs $Subs -Resume
            $XCalls += @($Run.Calls | Where-Object { $_ -eq 'sub-x' }).Count
            $Attempts += [int](script:Get-Entry -Id 'sub-x').Attempts
        }
        $Run4 = script:Invoke-Run -Subs $Subs -Resume
        $XCalls += @($Run4.Calls | Where-Object { $_ -eq 'sub-x' }).Count

        $Attempts | Should -Be @(1, 2, 3)
        $XCalls | Should -Be 3 -Because 'the fourth -Resume run must not collect a subscription that failed three runs in a row'
        @($Run4.Calls | Sort-Object -Unique) | Should -Not -Contain 'sub-x'
        @(script:Get-Lines -Run $Run4 -Like 'Not retried:*') | Should -Be @($script:NotRetriedX)
        $Run4.ExitCode | Should -BeNullOrEmpty -Because 'the run goes on with the other subscriptions'
        $Run4.Result.WrapperExitCode | Should -Be 2 -Because 'its report is missing from the consolidated zip'
    }

    It '-ResumeFailedOnly skips it too and still retries a subscription below the limit' {
        $Global:RdaRlFailIds = @('sub-x')
        $Subs = @($script:A, $script:X, $script:Y)
        $null = script:Invoke-Run -Subs $Subs
        $null = script:Invoke-Run -Subs $Subs -ResumeFailedOnly
        # Run 3 collects every subscription; Sub Y fails for the first time.
        $Global:RdaRlFailIds = @('sub-x', 'sub-y')
        $null = script:Invoke-Run -Subs $Subs
        $Run4 = script:Invoke-Run -Subs $Subs -ResumeFailedOnly

        @($Run4.Calls) | Should -Be @('sub-y')
        @(script:Get-Lines -Run $Run4 -Like 'Not retried:*') | Should -Be @($script:NotRetriedX)
        [int](script:Get-Entry -Id 'sub-y').Attempts | Should -Be 2
        [int](script:Get-Entry -Id 'sub-x').Attempts | Should -Be 3 -Because 'a skipped run is not a failed run'
        $Run4.ExitCode | Should -BeNullOrEmpty
        $Run4.Result.WrapperExitCode | Should -Be 2 -Because 'the report of Sub X, skipped for the retry limit, is missing from the consolidated zip'
    }

    It '-ResumeFailedOnly with only skipped subscriptions left says nothing is left to retry, names them and exits 2' {
        $Global:RdaRlFailIds = @('sub-x')
        $Subs = @($script:A, $script:B, $script:X)
        $null = script:Invoke-Run -Subs $Subs
        $null = script:Invoke-Run -Subs $Subs -ResumeFailedOnly
        $null = script:Invoke-Run -Subs $Subs -ResumeFailedOnly
        $Run4 = script:Invoke-Run -Subs $Subs -ResumeFailedOnly

        @($Run4.Calls) | Should -BeNullOrEmpty
        $Run4.ExitCode | Should -Be 2 -Because 'their reports are missing, so the run is not a success'
        @(script:Get-Lines -Run $Run4 -Like 'Not retried:*') | Should -Be @($script:NotRetriedX)
        @(script:Get-Lines -Run $Run4 -Like 'ResumeFailedOnly: nothing left to retry*').Count | Should -Be 1
        @(script:Get-Lines -Run $Run4 -Like 'Not Collected:*').Count | Should -Be 0 -Because 'a subscription past the limit is not one no run reached'
        [int](script:Get-Entry -Id 'sub-x').Attempts | Should -Be 3 -Because 'this exit leaves the state file as it was'
    }

    It 'names only the never-reached subscription under Not Collected, not the one past the limit' {
        $Global:RdaRlFailIds = @('sub-x')
        $null = script:Invoke-Run -Subs @($script:A, $script:B, $script:X)
        $null = script:Invoke-Run -Subs @($script:A, $script:B, $script:X) -ResumeFailedOnly
        $null = script:Invoke-Run -Subs @($script:A, $script:B, $script:X) -ResumeFailedOnly
        # Sub C is new: no run has reached it.
        $Run4 = script:Invoke-Run -Subs @($script:A, $script:B, $script:C, $script:X) -ResumeFailedOnly

        $Run4.ExitCode | Should -Be 2
        @(script:Get-Lines -Run $Run4 -Like 'Not Collected:*') | Should -Be @('Not Collected:           1 (Sub C) - no run has completed these and -ResumeFailedOnly retries only the retry list')
        Test-Path -LiteralPath $script:State | Should -BeTrue
    }

    It 'a completed run resets the count' {
        $Global:RdaRlFailIds = @('sub-x')
        $Subs = @($script:A, $script:B, $script:X)
        $null = script:Invoke-Run -Subs $Subs
        $null = script:Invoke-Run -Subs $Subs -Resume
        $Global:RdaRlFailIds = @()
        $null = script:Invoke-Run -Subs $Subs -Resume
        script:Get-Entry -Id 'sub-x' | Should -BeNullOrEmpty
        $Global:RdaRlFailIds = @('sub-x')
        $null = script:Invoke-Run -Subs $Subs
        $null = script:Invoke-Run -Subs $Subs -Resume
        $Run = script:Invoke-Run -Subs $Subs -Resume

        @($Run.Calls) | Should -Contain 'sub-x' -Because 'two failed runs since it last completed are below the limit'
        [int](script:Get-Entry -Id 'sub-x').Attempts | Should -Be 3
    }

    It 'keeps the resume state once every other subscription is done, lists the skipped one as incomplete, and the next two -Resume runs skip it too' {
        $Global:RdaRlFailIds = @('sub-x')
        $Subs = @($script:A, $script:B, $script:X)
        $null = script:Invoke-Run -Subs $Subs
        $null = script:Invoke-Run -Subs $Subs -Resume
        $null = script:Invoke-Run -Subs $Subs -Resume
        $Run4 = script:Invoke-Run -Subs $Subs -Resume

        # The state holds the count, so clearing it would start the count again
        # and the limit would never end the cycle.
        @(script:Get-Lines -Run $Run4 -Like 'Resume state cleared*') | Should -BeNullOrEmpty
        Test-Path -LiteralPath $script:State | Should -BeTrue
        @(script:Get-Lines -Run $Run4 -Like 'Retry Limit Reached:*') | Should -Be @('Retry Limit Reached:     1 (Sub X) - incomplete; -Resume and -ResumeFailedOnly do not collect these')
        @(script:Get-Lines -Run $Run4 -Like '  - Sub X (sub-x):*') | Should -Be @('  - Sub X (sub-x): failed 3 runs in a row; last reason: stand-in failure for this subscription')
        @(script:Get-Lines -Run $Run4 -Like '    ./ResourceInventory.ps1 -TenantID t -SubscriptionID sub-x') | Should -HaveCount 1
        @(script:Get-Lines -Run $Run4 -Like 'Pending Retries:*') | Should -BeNullOrEmpty -Because '-ResumeFailedOnly would not retry it'
        $Run4.Result.WrapperExitCode | Should -Be 2
        foreach ($n in 5..6)
        {
            $Next = script:Invoke-Run -Subs $Subs -Resume
            @($Next.Calls) | Should -Not -Contain 'sub-x'
            $Next.Result.WrapperExitCode | Should -Be 2
            [int](script:Get-Entry -Id 'sub-x').Attempts | Should -Be 3 -Because 'a skipped run neither counts nor forgets'
        }
    }

    It 'RunSummary.log keeps the skipped subscription as incomplete with its count and reason, and an obfuscated run gives the count only' {
        $Global:RdaRlFailIds = @('sub-x')
        $Subs = @($script:A, $script:B, $script:X)
        $null = script:Invoke-Run -Subs $Subs
        $null = script:Invoke-Run -Subs $Subs -Resume
        $Run3 = script:Invoke-Run -Subs $Subs -Resume
        $Clear = @($Run3.Result.RunSummary)
        $Obf = @((script:Invoke-Run -Subs $Subs -Resume -Obfuscate).Result.RunSummary)

        @($Clear | Where-Object { $_ -like '  Retry limit reached*' }) | Should -Be @('  Retry limit reached : 1 (incomplete; -Resume and -ResumeFailedOnly do not collect these)')
        @($Clear | Where-Object { $_ -like '  - Sub X (sub-x):*' }) | Should -Be @('  - Sub X (sub-x): failed 3 runs in a row; last reason: stand-in failure for this subscription')
        @($Obf | Where-Object { $_ -like '  Retry limit reached*' }) | Should -Be @('  Retry limit reached : 1 (incomplete; -Resume and -ResumeFailedOnly do not collect these)')
        ($Obf -join "`n") | Should -Not -Match 'sub-x|Sub X|stand-in failure'
    }

    It 'a run without -Resume still collects it and keeps counting' {
        $Global:RdaRlFailIds = @('sub-x')
        $Subs = @($script:A, $script:B, $script:X)
        $null = script:Invoke-Run -Subs $Subs
        $null = script:Invoke-Run -Subs $Subs -Resume
        $null = script:Invoke-Run -Subs $Subs -Resume
        $Run4 = script:Invoke-Run -Subs $Subs

        @($Run4.Calls) | Should -Contain 'sub-x'
        @(script:Get-Lines -Run $Run4 -Like 'Not retried:*') | Should -BeNullOrEmpty
        [int](script:Get-Entry -Id 'sub-x').Attempts | Should -Be 4
        Test-Path -LiteralPath $script:State | Should -BeTrue -Because 'it failed again in this run'
        $Run4.Result.WrapperExitCode | Should -Be 0
        $Global:RdaRlFailIds = @()
        $Run5 = script:Invoke-Run -Subs $Subs
        @($Run5.Calls) | Should -Contain 'sub-x'
        Test-Path -LiteralPath $script:State | Should -BeFalse -Because 'everything completed'
    }

    It 'treats a missing or unreadable Attempts value as one failed run' {
        Save-CompletedSubscriptionIds -Path $script:State -Tenant 't' -Ids @() -FailedAttempts @(
            [pscustomobject]@{ Id = 'sub-x'; Name = 'Sub X'; LastFailedAt = (Get-Date).ToString('o'); Reason = 'r'; Attempts = 'many' },
            [pscustomobject]@{ Id = 'sub-y'; Name = 'Sub Y'; LastFailedAt = (Get-Date).ToString('o'); Reason = 'r' },
            [pscustomobject]@{ Id = 'sub-a'; Name = 'Sub A'; LastFailedAt = (Get-Date).ToString('o'); Reason = 'r'; Attempts = -5 })
        $Global:RdaRlFailIds = @('sub-x', 'sub-y', 'sub-a')
        $Run = script:Invoke-Run -Subs @($script:A, $script:X, $script:Y) -Resume

        @($Run.Calls | Sort-Object) | Should -Be @('sub-a', 'sub-x', 'sub-y')
        [int](script:Get-Entry -Id 'sub-x').Attempts | Should -Be 2
        [int](script:Get-Entry -Id 'sub-y').Attempts | Should -Be 2
        [int](script:Get-Entry -Id 'sub-a').Attempts | Should -Be 2
    }
}

Describe 'Retry limit on the parallel path' {
    BeforeAll {
        Mock Import-Module -ParameterFilter { $Name -eq 'Az.Accounts' } -MockWith { }
        Mock Disable-AzContextAutosave -MockWith { }
        Mock Import-AzContext -MockWith { }
    }
    BeforeEach { script:New-Case }

    It 'counts each failed parallel run, and the fourth -Resume run does not collect it' {
        $Global:RdaRlFailIds = @('sub-x')
        $Subs = @($script:A, $script:B, $script:C, $script:X)
        $Attempts = @()
        $null = script:Invoke-Run -Subs $Subs -Streams 2
        $Attempts += [int](script:Get-Entry -Id 'sub-x').Attempts
        foreach ($n in 2..3)
        {
            $null = script:Invoke-Run -Subs $Subs -Streams 2 -Resume
            $Attempts += [int](script:Get-Entry -Id 'sub-x').Attempts
        }
        $Run4 = script:Invoke-Run -Subs $Subs -Streams 2 -Resume

        $Attempts | Should -Be @(1, 2, 3) -Because 'each parallel run that fails the subscription is one more failed run'
        @($Run4.Calls) | Should -Not -Contain 'sub-x'
        @(script:Get-Lines -Run $Run4 -Like 'Not retried:*') | Should -Be @($script:NotRetriedX)
        $Run4.ExitCode | Should -BeNullOrEmpty
        $Run4.Result.WrapperExitCode | Should -Be 2
    }

    It 'keeps counting across sequential and parallel runs, and -ResumeFailedOnly skips it' {
        $Global:RdaRlFailIds = @('sub-x')
        $Subs = @($script:A, $script:B, $script:X)
        $null = script:Invoke-Run -Subs $Subs
        $null = script:Invoke-Run -Subs $Subs -Streams 2 -ResumeFailedOnly
        $Global:RdaRlFailIds = @('sub-x', 'sub-b')
        $null = script:Invoke-Run -Subs $Subs -Streams 2 -Resume
        [int](script:Get-Entry -Id 'sub-x').Attempts | Should -Be 3
        $Run4 = script:Invoke-Run -Subs $Subs -Streams 2 -ResumeFailedOnly

        @($Run4.Calls) | Should -Be @('sub-b')
        @(script:Get-Lines -Run $Run4 -Like 'Not retried:*') | Should -Be @($script:NotRetriedX)
    }

    It 'counts a run whose streams failed it before the session ended once, not twice' {
        $Global:RdaRlFailIds = @('sub-x')
        $Subs = @($script:A, $script:B, $script:X)
        $null = script:Invoke-Run -Subs $Subs -Streams 2
        # Run 2: the streams fail Sub X again, and the session ends before the merge.
        $null = script:Invoke-Run -Subs $Subs -Streams 2 -Resume -Interrupted
        @(Get-StreamResumeStateFiles -InventoryRoot $script:Root -Tenant 't').Count | Should -BeGreaterThan 0
        # Run 3 folds the streams' state at startup and fails Sub X a third time.
        $null = script:Invoke-Run -Subs $Subs -Streams 2 -Resume
        [int](script:Get-Entry -Id 'sub-x').Attempts | Should -Be 3
        $Run4 = script:Invoke-Run -Subs $Subs -Streams 2 -Resume

        @($Run4.Calls) | Should -Not -Contain 'sub-x'
    }
}

Describe 'Retry limit for a subscription whose metrics stay incomplete' {
    BeforeAll {
        Mock Import-Module -ParameterFilter { $Name -eq 'Az.Accounts' } -MockWith { }
        Mock Disable-AzContextAutosave -MockWith { }
        Mock Import-AzContext -MockWith { }
    }
    BeforeEach { script:New-Case }

    It 'is not collected by the fourth -Resume run after three incomplete runs, on either path' -ForEach @(@{ Streams = 1 }, @{ Streams = 2 }) {
        if (-not (Get-Command -Name Get-IncompleteDataReason -ErrorAction SilentlyContinue))
        {
            Set-ItResult -Skipped -Because 'this version does not keep a subscription with incomplete metrics on the retry list'
            return
        }
        $Global:RdaRlIncompleteIds = @('sub-x')
        $Subs = @($script:A, $script:B, $script:X)
        $null = script:Invoke-Run -Subs $Subs -Streams $Streams
        $null = script:Invoke-Run -Subs $Subs -Streams $Streams -Resume
        $null = script:Invoke-Run -Subs $Subs -Streams $Streams -Resume
        [int](script:Get-Entry -Id 'sub-x').Attempts | Should -Be 3
        $Run4 = script:Invoke-Run -Subs $Subs -Streams $Streams -Resume

        @($Run4.Calls) | Should -Not -Contain 'sub-x'
        @(script:Get-Lines -Run $Run4 -Like 'Not retried: Sub X (sub-x) failed 3 runs in a row; last reason: Metrics incomplete*').Count | Should -Be 1
    }
}

Describe 'A retry-list entry for a subscription that is no longer visible' {
    BeforeAll {
        Mock Import-Module -ParameterFilter { $Name -eq 'Az.Accounts' } -MockWith { }
        Mock Disable-AzContextAutosave -MockWith { }
        Mock Import-AzContext -MockWith { }
    }
    BeforeEach { script:New-Case }

    # No run could retry or count it, so it used to keep the resume state forever.
    It 'is dropped with a line naming it, and the state clears once everything else is done (<Mode>)' -ForEach @(@{ Mode = '-Resume' }, @{ Mode = '-ResumeFailedOnly' }) {
        $Global:RdaRlFailIds = @('sub-x')
        $null = script:Invoke-Run -Subs @($script:A, $script:B, $script:X)
        $Global:RdaRlFailIds = @()
        # Sub X is gone (deleted or moved to another tenant).
        $R2 = if ($Mode -eq '-Resume') { script:Invoke-Run -Subs @($script:A, $script:B) -Resume } else { script:Invoke-Run -Subs @($script:A, $script:B) -ResumeFailedOnly }
        @(script:Get-Lines -Run $R2 -Like 'Dropped from the retry list:*') | Should -Be @('Dropped from the retry list: Sub X (sub-x) is no longer visible to the signed-in identity, so no run can retry it.')
        script:Get-Entry -Id 'sub-x' | Should -BeNullOrEmpty
        $R3 = script:Invoke-Run -Subs @($script:A, $script:B) -Resume
        @(script:Get-Lines -Run $R3 -Like 'Dropped from the retry list:*') | Should -BeNullOrEmpty
        Test-Path -LiteralPath $script:State | Should -BeFalse -Because 'nothing is owed any more'
    }
}
