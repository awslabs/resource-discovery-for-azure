# A subscription that keeps failing is on the retry list (FailedAttempts in the
# resume state), and every -Resume or -ResumeFailedOnly run collected it again,
# however many runs in a row it had failed. After 3 failed runs in a row, -Resume
# and -ResumeFailedOnly skip it, name it with its last reason before the work
# starts, and the summary and RunSummary.log keep it as incomplete. A run without
# -Resume still collects it. The run ends with exit 2, since its report is missing.
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
    # Run as written: the completed ids are read as the wrapper reads them.
    $StartText = script:Join-Top -From $SeedAt -To ($ScopeAt - 1)

    # The access check: its scope as written, then a stand-in that finds the ids in
    # $Global:RdaRlUnreadableIds not readable and every other readable (under
    # -AllowPartialAccess the run then leaves them out, as the check does); then
    # the list of retry-limited subscriptions this run does not collect, as
    # written (built after the check), and the record of what it skipped.
    $GateText = $Top[$ScopeAt].Extent.Text + "`n`$AccessDecision = [pscustomobject]@{ InaccessibleIds = @(@(`$Global:RdaRlUnreadableIds) | Where-Object { `$_ -and @(`$ScopeForProbe | ForEach-Object { [string]`$_.Id }) -contains `$_ }) }`n"
    $GateText += "if (`$AllowPartialAccess) { `$Subscriptions = @(`$Subscriptions | Where-Object { `$AccessDecision.InaccessibleIds -notcontains `$_.Id }) }`n"
    $OwedAt = script:Find-TopIndex -After $ScopeAt -What 'the retry-limited ids this run does not collect' -Match { param($s) $s.Extent.Text.StartsWith('$RetryLimitedNotInRunIds = ') }
    # The run's subscription ids, every retry entry it leaves out, and those past the limit.
    $GateText += (script:Join-Top -From ($OwedAt - 2) -To $OwedAt) + "`n"
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
    # The pending list as the parallel path builds it before it slices (lifted below),
    # and the run id the wrapper makes just before the orchestration's try.
    $PendingAt = @($SeqIf[0].ElseClause.Statements | Where-Object { $_ -is [System.Management.Automation.Language.ForEachStatementAst] -and $_.Body.Extent.Text.Contains('$PendingSubscriptions += $Sub') })
    if ($PendingAt.Count -ne 1) { throw 'Expected the pending-subscription list of the parallel path in the wrapper.' }
    $ParLaunchPrelude = "`$PendingSubscriptions = @()`n" + $PendingAt[0].Extent.Text + "`n`$StreamCount = [Math]::Min(`$ParallelStreams, `$PendingSubscriptions.Count); `$AzContextSnapshot = Join-Path `$InventoryRoot 'ctx.json'; `$Jobs = @(); `$StreamSummaries = @(); `$StreamRunId = [guid]::NewGuid().ToString('N')`n"
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
    "`$ConcurrencyLimit = 6; `$DeviceLogin = `$false; `$SkipMetrics = `$false; `$SkipConsumption = `$false; `$AllowPartialAccess = [bool]`$Global:RdaRlAllowPartialAccess`n" +
    "`$AllSubscriptions = @(@(`$Subscriptions) + @(`$Global:RdaRlAlsoVisible | Where-Object { `$_ })); `$Excluded = @(`$Global:RdaRlAlsoVisible | Where-Object { `$_ }); `$RunStartTime = Get-Date; `$BundleVer = 'test'`n" +
    "`$SubWarnings = @(`$Global:RdaRlListWarnings | Where-Object { `$_ }); `$SubErrors = @(`$Global:RdaRlListErrors | Where-Object { `$_ })`n" +
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
    $script:NotRetriedX = 'Not retried: Sub X (sub-x) failed 3 runs in a row; last reason: stand-in failure for this subscription. To try it again, start a run without -Resume or -ResumeFailedOnly.'

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
        # Subscriptions Azure lists that are not in the run's set (for example
        # disabled ones without -IncludeDisabled).
        $Global:RdaRlAlsoVisible = @()
        # Warnings and errors the subscription listing came back with.
        $Global:RdaRlListWarnings = @()
        $Global:RdaRlListErrors = @()
        # Subscriptions the access check's stand-in finds not readable, and
        # whether the run has -AllowPartialAccess.
        $Global:RdaRlUnreadableIds = @()
        $Global:RdaRlAllowPartialAccess = $false
        $script:State = Join-Path $script:Root '.resume-state-t.json'
    }
}

AfterAll {
    Remove-Variable -Name RdaRlRoot, RdaRlFailIds, RdaRlIncompleteIds, RdaRlNoZipIds, RdaRlHome, RdaRlCalls, RdaRlAlsoVisible, RdaRlListWarnings, RdaRlListErrors, RdaRlUnreadableIds, RdaRlAllowPartialAccess -Scope Global -ErrorAction SilentlyContinue
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
        @(script:Get-Lines -Run $Run4 -Like '  To try them again, start a run without -Resume or -ResumeFailedOnly*') | Should -HaveCount 1
        @(script:Get-Lines -Run $Run4 -Like '    ./Run-AllSubscriptions.ps1 -TenantID t') | Should -HaveCount 1
        @(script:Get-Lines -Run $Run4 -Like '*ResourceInventory.ps1*') | Should -BeNullOrEmpty -Because 'a direct run does not change the resume state, so it does not end the skip'
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
        $Run4.Result.WrapperExitCode | Should -Be 2 -Because 'Sub X failed in this run'
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

Describe 'Following the retry-limit advice' {
    BeforeAll {
        Mock Import-Module -ParameterFilter { $Name -eq 'Az.Accounts' } -MockWith { }
        Mock Disable-AzContextAutosave -MockWith { }
        Mock Import-AzContext -MockWith { }
    }
    BeforeEach { script:New-Case }

    # The advice printed for a subscription past the limit must end the skip:
    # after the run it names, the next -Resume collects the subscription again.
    It 'a run without -Resume, as printed, collects it, and the next -Resume no longer skips it (<Streams> stream(s))' -ForEach @(@{ Streams = 1 }, @{ Streams = 2 }) {
        $Global:RdaRlFailIds = @('sub-x')
        $Subs = @($script:A, $script:B, $script:X)
        $null = script:Invoke-Run -Subs $Subs -Streams $Streams
        $null = script:Invoke-Run -Subs $Subs -Streams $Streams -Resume
        $null = script:Invoke-Run -Subs $Subs -Streams $Streams -Resume
        $Run4 = script:Invoke-Run -Subs $Subs -Streams $Streams -Resume
        @($Run4.Calls) | Should -Not -Contain 'sub-x'
        $Run4.Result.WrapperExitCode | Should -Be 2

        # The advice: the start-up line and the end-of-run command.
        $Advice = @(script:Get-Lines -Run $Run4 -Like 'Not retried: Sub X (sub-x)*')
        $Advice | Should -HaveCount 1
        $Advice[0] | Should -BeLike '*To try it again, start a run without -Resume or -ResumeFailedOnly.'
        $Command = @(script:Get-Lines -Run $Run4 -Like '    ./Run-AllSubscriptions.ps1 *')
        $Command | Should -HaveCount 1
        $Command[0] | Should -Not -Match '-Resume'
        @($Run4.Result.RunSummary | Where-Object { $_ -like 'Retry limit reached (detail;*' }) | Should -Be @('Retry limit reached (detail; to try them again, start a run without -Resume or -ResumeFailedOnly):')

        # The cause is gone. Follow the advice: the same run without -Resume.
        $Global:RdaRlFailIds = @()
        $Run5 = script:Invoke-Run -Subs $Subs -Streams $Streams
        @($Run5.Calls) | Should -Contain 'sub-x'
        script:Get-Entry -Id 'sub-x' | Should -BeNullOrEmpty -Because 'a run that completes it takes it off the retry list'
        $Run5.Result.WrapperExitCode | Should -Be 0

        $Run6 = script:Invoke-Run -Subs $Subs -Streams $Streams -Resume
        @(script:Get-Lines -Run $Run6 -Like 'Not retried:*') | Should -BeNullOrEmpty
        @(script:Get-Lines -Run $Run6 -Like 'Retry Limit Reached:*') | Should -BeNullOrEmpty
        @($Run6.Calls) | Should -Contain 'sub-x' -Because 'the skip ended with the run without -Resume'
        $Run6.Result.WrapperExitCode | Should -Be 0
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
        # A run without -Resume, so it collects Sub B again (a -Resume skips it:
        # an earlier run completed it) and Sub B fails.
        $null = script:Invoke-Run -Subs $Subs -Streams 2
        [int](script:Get-Entry -Id 'sub-x').Attempts | Should -Be 3
        $Run4 = script:Invoke-Run -Subs $Subs -Streams 2 -ResumeFailedOnly

        @($Run4.Calls) | Should -Be @('sub-b')
        @(script:Get-Lines -Run $Run4 -Like 'Not retried:*') | Should -Be @($script:NotRetriedX)
    }

    It 'a run in which a subscription fails exits 2, not 0 (<Label>)' -ForEach @(@{ Label = 'sequential'; Streams = 1 }, @{ Label = 'parallel'; Streams = 2 }) {
        $Global:RdaRlFailIds = @('sub-x')
        $R = script:Invoke-Run -Subs @($script:A, $script:B, $script:X) -Streams $Streams
        @($R.Result.FailedSubscriptions).Count | Should -BeGreaterThan 0
        $R.Result.WrapperExitCode | Should -Be 2
    }

    It 'a parallel -Resume after a merged run collects only what is left, not the completed subscriptions again' {
        $Global:RdaRlFailIds = @('sub-x')
        $Subs = @($script:A, $script:B, $script:X)
        $null = script:Invoke-Run -Subs $Subs -Streams 2
        @(Get-StreamResumeStateFiles -InventoryRoot $script:Root -Tenant 't') | Should -BeNullOrEmpty -Because 'the merge removed the per-stream files'
        $R = script:Invoke-Run -Subs $Subs -Streams 2 -Resume
        @($R.Calls | Sort-Object -Unique) | Should -Be @('sub-x')
        @(script:Get-Lines -Run $R -Like 'Skipping (already completed):*').Count | Should -Be 2
    }

    It 'after an interrupted parallel run, a sequential -Resume removes the per-stream files, so the next -Resume folds nothing old back in' {
        $Global:RdaRlFailIds = @('sub-x')
        $Subs = @($script:A, $script:B, $script:X)
        $null = script:Invoke-Run -Subs $Subs -Streams 2 -Interrupted
        @(Get-StreamResumeStateFiles -InventoryRoot $script:Root -Tenant 't').Count | Should -BeGreaterThan 0
        $Global:RdaRlFailIds = @()
        $R = script:Invoke-Run -Subs $Subs -Resume
        @(script:Get-Lines -Run $R -Like 'Recovered per-stream state*').Count | Should -Be 1
        @(Get-StreamResumeStateFiles -InventoryRoot $script:Root -Tenant 't') | Should -BeNullOrEmpty
        $R.Result.WrapperExitCode | Should -Be 0
        Test-Path -LiteralPath $script:State | Should -BeFalse
        $R2 = script:Invoke-Run -Subs $Subs -Resume
        @(script:Get-Lines -Run $R2 -Like 'Recovered per-stream state*') | Should -BeNullOrEmpty
        @($R2.Calls | Sort-Object -Unique) | Should -Be @('sub-a', 'sub-b', 'sub-x')
    }

    It 'a parallel run whose streams cannot save their state collects nothing and names each sub; the next -Resume collects each once, runs clean and clears the state' {
        $Global:RdaRlFailIds = @()
        $Global:RdaRlBreakStreamSave = $true
        Mock Set-Content -ParameterFilter { $Global:RdaRlBreakStreamSave -and [string]$LiteralPath -like '*.resume-state-t-stream-*.json.tmp' } -MockWith { throw 'stand-in: disk full' }
        $R1 = script:Invoke-Run -Subs @($script:A, $script:B) -Streams 2
        $Global:RdaRlBreakStreamSave = $false
        @($R1.Calls) | Should -BeNullOrEmpty -Because 'no stream could save the write-ahead count, so none collected'
        @($R1.Result.FailedSubscriptions | Where-Object { $_ -like '*could not save its state before collecting it*' }).Count | Should -Be 2
        $R1.Result.WrapperExitCode | Should -Not -Be 0
        @(Get-FailedAttempts -Path $script:State -Tenant 't' | Where-Object { $null -ne $_ }) | Should -BeNullOrEmpty -Because 'nothing was attempted, so nothing is counted'
        $R2 = script:Invoke-Run -Subs @($script:A, $script:B) -Streams 2 -Resume
        @($R2.Calls | Sort-Object) | Should -Be @('sub-a', 'sub-b') -Because 'each is collected, once'
        @($R2.Result.FailedSubscriptions) | Should -BeNullOrEmpty
        Test-Path -LiteralPath $script:State | Should -BeFalse -Because 'the run is clean, so the clean-run rule clears the state and nothing is left to loop on'
        Remove-Variable -Name RdaRlBreakStreamSave -Scope Global -ErrorAction SilentlyContinue
    }

    It 'stream saves that fail and a parent cut off before the merge never dodge the retry limit (<Case>)' -ForEach @(
        @{ Case = 'every stream save fails: nothing is collected or counted'; AfterFirst = $false }
        @{ Case = 'saves fail after the write-ahead count: the count stands'; AfterFirst = $true }
    ) {
        Save-CompletedSubscriptionIds -Path $script:State -Tenant 't' -Ids @() -FailedAttempts @([pscustomobject]@{ Id = 'sub-x'; Name = 'Sub X'; LastFailedAt = '2026-01-01T00:00:00Z'; Reason = 'earlier'; Attempts = 2 }) -Reports @()
        $Global:RdaRlFailIds = @('sub-x')
        $Global:RdaRlBreakStreamSave = $true
        $Global:RdaRlAfterFirst = $AfterFirst
        # With AfterFirst, a stream's first save (the write-ahead count of its first sub) reaches the disk.
        Mock Set-Content -ParameterFilter { $Global:RdaRlBreakStreamSave -and [string]$LiteralPath -like '*.resume-state-t-stream-*.json.tmp' -and (-not $Global:RdaRlAfterFirst -or (Test-Path -LiteralPath ([string]$LiteralPath -replace '\.tmp$', ''))) } -MockWith { throw 'stand-in: disk full' }
        $R1 = script:Invoke-Run -Subs @($script:A, $script:X) -Streams 2 -Resume -Interrupted
        $Global:RdaRlBreakStreamSave = $false
        $Global:RdaRlFailIds = @()
        $R2 = script:Invoke-Run -Subs @($script:A, $script:X) -Streams 2 -Resume
        if ($AfterFirst)
        {
            @($R1.Calls | Sort-Object) | Should -Be @('sub-a', 'sub-x')
            # The next -Resume folds in the cut-off run's write-ahead counts:
            # sub-x is at 3 and not retried; sub-a is not proven done, so it is
            # collected again.
            [int](script:Get-Entry -Id 'sub-x').Attempts | Should -Be 3
            @($R2.Calls) | Should -Be @('sub-a')
            @(script:Get-Lines -Run $R2 -Like 'Not retried:*Sub X*').Count | Should -BeGreaterThan 0
        }
        else
        {
            @($R1.Calls) | Should -BeNullOrEmpty -Because 'no stream could save the write-ahead count, so nothing was collected and no failed run happened'
            # The next -Resume collects both; sub-x succeeds now and leaves the list.
            @($R2.Calls | Sort-Object) | Should -Be @('sub-a', 'sub-x')
            script:Get-Entry -Id 'sub-x' | Should -BeNullOrEmpty
        }
        Remove-Variable -Name RdaRlBreakStreamSave, RdaRlAfterFirst -Scope Global -ErrorAction SilentlyContinue
    }

    It 'a parallel -Resume with nothing left says so, and does not call it one eligible subscription' {
        $Subs = @($script:A, $script:B)
        $Global:RdaRlFailIds = @()
        $null = script:Invoke-Run -Subs $Subs -Streams 2 -Interrupted
        # Fail-safe rule: the cut-off run never proved its results saved, so the
        # first -Resume collects both again, once each (sub-x fails, so the
        # state is kept for the next -Resume).
        $Global:RdaRlFailIds = @('sub-x')
        $R1 = script:Invoke-Run -Subs @($script:A, $script:B, $script:X) -Streams 2 -Resume
        @($R1.Calls | Sort-Object) | Should -Be @('sub-a', 'sub-b', 'sub-x')
        $Global:RdaRlFailIds = @()
        $R = script:Invoke-Run -Subs $Subs -Streams 2 -Resume
        @($R.Calls) | Should -BeNullOrEmpty
        @(script:Get-Lines -Run $R -Like 'No subscription left to process.').Count | Should -Be 1
        @(script:Get-Lines -Run $R -Like 'Only one*') | Should -BeNullOrEmpty
        @(script:Get-Lines -Run $R -Like 'Note: -ParallelStreams * clamped to 0*') | Should -BeNullOrEmpty
        @(Get-StreamResumeStateFiles -InventoryRoot $script:Root -Tenant 't') | Should -BeNullOrEmpty
    }

    It 'keeps the per-stream files of a parallel run when the resume state does not hold their records afterwards' {
        $Global:RdaRlFailIds = @('sub-x')
        Mock Save-CompletedSubscriptionIds { }
        $R = script:Invoke-Run -Subs @($script:A, $script:B, $script:X) -Streams 2
        @(Get-StreamResumeStateFiles -InventoryRoot $script:Root -Tenant 't').Count | Should -BeGreaterThan 0
        @(script:Get-Lines -Run $R -Like "WARNING: The resume state file * does not hold every record of this run's per-stream files*").Count | Should -Be 1
    }

    It 'with a per-stream file it cannot read, -ResumeFailedOnly names it and ends with exit 2, not a clean exit 0' {
        $Global:RdaRlFailIds = @()
        $null = script:Invoke-Run -Subs @($script:A, $script:B)
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        $Bad = Join-Path $script:Root '.resume-state-t-stream-0.json'
        Set-Content -LiteralPath $Bad -Value '{ not json' -NoNewline
        $R = script:Invoke-Run -Subs @($script:A, $script:B) -ResumeFailedOnly
        @(script:Get-Lines -Run $R -Like ('WARNING: Could not read the per-stream resume state file {0}*' -f $Bad)).Count | Should -Be 1
        $R.ExitCode | Should -Be 2
        # Renamed aside, kept for the user; the next -ResumeFailedOnly does not see it.
        Test-Path -LiteralPath $Bad | Should -BeFalse
        @(Get-ChildItem -LiteralPath $script:Root -Force -Filter '.resume-state-t-stream-0.json.unreadable-*').Count | Should -Be 1
        # The file put aside is named again, with exit 2, until it is fixed or deleted.
        $R3 = script:Invoke-Run -Subs @($script:A, $script:B) -ResumeFailedOnly
        $R3.ExitCode | Should -Be 2
        @(script:Get-Lines -Run $R3 -Like 'WARNING: The per-stream resume state file *put aside by an earlier run*').Count | Should -Be 1
        Get-ChildItem -LiteralPath $script:Root -Force -Filter '.resume-state-t-stream-0.json.unreadable-*' | Remove-Item -Force
        $R4 = script:Invoke-Run -Subs @($script:A, $script:B) -ResumeFailedOnly
        $R4.ExitCode | Should -Be 0
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

Describe 'A gone subscription''s entry left in a per-stream file of an interrupted run' {
    BeforeAll {
        Mock Import-Module -ParameterFilter { $Name -eq 'Az.Accounts' } -MockWith { }
        Mock Disable-AzContextAutosave -MockWith { }
        Mock Import-AzContext -MockWith { }
    }
    BeforeEach { script:New-Case }

    It 'is dropped for good by the next parallel -Resume, not merged back from the stream''s file' {
        $Global:RdaRlFailIds = @('sub-x')
        $Subs = @($script:A, $script:B, $script:X)
        $null = script:Invoke-Run -Subs $Subs -Streams 2
        # The streams fail Sub X again and the session ends before the merge.
        $null = script:Invoke-Run -Subs $Subs -Streams 2 -Resume -Interrupted
        @(Get-StreamResumeStateFiles -InventoryRoot $script:Root -Tenant 't').Count | Should -BeGreaterThan 0
        $Global:RdaRlFailIds = @()
        # Sub X is gone now.
        $R = script:Invoke-Run -Subs @($script:A, $script:B) -Streams 2 -Resume
        @(script:Get-Lines -Run $R -Like 'Dropped from the retry list:*').Count | Should -Be 1
        script:Get-Entry -Id 'sub-x' | Should -BeNullOrEmpty
        @(script:Get-Lines -Run $R -Like 'Retry Limit Reached:*') | Should -BeNullOrEmpty
    }

    It 'is not folded back in after -ResumeFailedOnly drops the last entry and removes the state' {
        $Global:RdaRlFailIds = @('sub-x')
        $Subs = @($script:A, $script:B, $script:X)
        $null = script:Invoke-Run -Subs $Subs -Streams 2
        $null = script:Invoke-Run -Subs $Subs -Streams 2 -Resume -Interrupted
        $Global:RdaRlFailIds = @()
        $null = script:Invoke-Run -Subs @($script:A, $script:B) -ResumeFailedOnly
        @(Get-StreamResumeStateFiles -InventoryRoot $script:Root -Tenant 't') | Should -BeNullOrEmpty
        $R = script:Invoke-Run -Subs @($script:A, $script:B) -Resume
        @(script:Get-Lines -Run $R -Like 'Recovered per-stream state*') | Should -BeNullOrEmpty
        script:Get-Entry -Id 'sub-x' | Should -BeNullOrEmpty
    }
}

Describe 'A retry-list entry for a subscription outside the current subscription set' {
    BeforeEach { script:New-Case }

    It '-ResumeFailedOnly whose retry list holds only a disabled subscription says none are visible and exits 2' {
        $Global:RdaRlFailIds = @('sub-x')
        $null = script:Invoke-Run -Subs @($script:A, $script:X)
        $Global:RdaRlFailIds = @()
        # Sub X is disabled now: Azure still lists it, but it is not in the run's set.
        $Global:RdaRlAlsoVisible = @($script:X)
        $R = script:Invoke-Run -Subs @($script:A) -ResumeFailedOnly

        $R.ExitCode | Should -Be 2 -Because 'the retry list still holds it, so the run is not a success'
        @(script:Get-Lines -Run $R -Like 'WARNING: FailedAttempts list contained IDs but none are visible in the current subscription set*').Count | Should -Be 1
        @(script:Get-Lines -Run $R -Like 'Dropped from the retry list:*') | Should -BeNullOrEmpty -Because 'a disabled subscription is still listed by Azure'
        @($R.Calls) | Should -BeNullOrEmpty
        [int](script:Get-Entry -Id 'sub-x').Attempts | Should -Be 1
    }
}

Describe 'A subscription past the retry limit that is outside the run''s subscription set' {
    BeforeAll {
        Mock Import-Module -ParameterFilter { $Name -eq 'Az.Accounts' } -MockWith { }
        Mock Disable-AzContextAutosave -MockWith { }
        Mock Import-AzContext -MockWith { }
    }
    BeforeEach { script:New-Case }

    It 'keeps the state, names -IncludeDisabled, and every run that leaves it out exits 2 until a run collects it' {
        $Global:RdaRlFailIds = @('sub-x')
        $Subs = @($script:A, $script:B, $script:X)
        $null = script:Invoke-Run -Subs $Subs
        $null = script:Invoke-Run -Subs $Subs -Resume
        $null = script:Invoke-Run -Subs $Subs -Resume
        [int](script:Get-Entry -Id 'sub-x').Attempts | Should -Be 3
        $Global:RdaRlFailIds = @()
        # Sub X is disabled now: Azure still lists it, but it is not in the run's set.
        $Global:RdaRlAlsoVisible = @($script:X)
        foreach ($n in 1..2)
        {
            $R = script:Invoke-Run -Subs @($script:A, $script:B) -Resume
            @($R.Calls) | Should -Not -Contain 'sub-x'
            $R.ExitCode | Should -BeNullOrEmpty
            $R.Result.WrapperExitCode | Should -Be 2 -Because 'Retry Limit Reached lists Sub X as incomplete, so its report is missing'
            @(script:Get-Lines -Run $R -Like 'Retry Limit Reached:*') | Should -Be @('Retry Limit Reached:     1 (Sub X) - incomplete; -Resume and -ResumeFailedOnly do not collect these')
            @(script:Get-Lines -Run $R -Like '  To try them again*') | Should -Be @('  To try them again, start a run without -Resume or -ResumeFailedOnly; Sub X is not Enabled, so add -IncludeDisabled, for example:')
            @(script:Get-Lines -Run $R -Like '    ./Run-AllSubscriptions.ps1 *') | Should -Be @('    ./Run-AllSubscriptions.ps1 -TenantID t -IncludeDisabled')
            Test-Path -LiteralPath $script:State | Should -BeTrue
            [int](script:Get-Entry -Id 'sub-x').Attempts | Should -Be 3
        }
        # A run without -Resume, but without -IncludeDisabled, leaves it out too.
        $R3 = script:Invoke-Run -Subs @($script:A, $script:B)
        @($R3.Calls) | Should -Not -Contain 'sub-x'
        $R3.Result.WrapperExitCode | Should -Be 2
        Test-Path -LiteralPath $script:State | Should -BeTrue
        # The advice followed: -IncludeDisabled puts Sub X back in the run's set.
        $Global:RdaRlAlsoVisible = @()
        $R4 = script:Invoke-Run -Subs $Subs
        @($R4.Calls) | Should -Contain 'sub-x'
        script:Get-Entry -Id 'sub-x' | Should -BeNullOrEmpty
        $R4.Result.WrapperExitCode | Should -Be 0
        Test-Path -LiteralPath $script:State | Should -BeFalse
        $R5 = script:Invoke-Run -Subs $Subs -Resume
        @(script:Get-Lines -Run $R5 -Like 'Retry Limit Reached:*') | Should -BeNullOrEmpty
        $R5.Result.WrapperExitCode | Should -Be 0
    }
}

Describe '-ResumeFailedOnly that drops the last retry-list entry' {
    BeforeAll {
        Mock Import-Module -ParameterFilter { $Name -eq 'Az.Accounts' } -MockWith { }
        Mock Disable-AzContextAutosave -MockWith { }
        Mock Import-AzContext -MockWith { }
    }
    BeforeEach { script:New-Case }

    It 'removes the state when nothing is owed, and the next -ResumeFailedOnly starts with no state' {
        $Global:RdaRlFailIds = @('sub-x')
        $null = script:Invoke-Run -Subs @($script:A, $script:X)
        $Global:RdaRlFailIds = @()
        # Sub X is gone; Sub A is completed.
        $R1 = script:Invoke-Run -Subs @($script:A) -ResumeFailedOnly
        @(script:Get-Lines -Run $R1 -Like 'Dropped from the retry list:*').Count | Should -Be 1
        @(script:Get-Lines -Run $R1 -Like 'Resume state cleared (clean run).').Count | Should -Be 1
        $R1.ExitCode | Should -Be 0
        Test-Path -LiteralPath $script:State | Should -BeFalse
        $R2 = script:Invoke-Run -Subs @($script:A) -ResumeFailedOnly
        @(script:Get-Lines -Run $R2 -Like 'ResumeFailedOnly: no failed subscriptions in resume state. Nothing to retry.').Count | Should -Be 1
        @(script:Get-Lines -Run $R2 -Like 'Dropped from the retry list:*') | Should -BeNullOrEmpty
        $R2.ExitCode | Should -Be 0
        Test-Path -LiteralPath $script:State | Should -BeFalse
    }

    It 'keeps the state and exits 2 while a subscription no run has completed remains' {
        $Global:RdaRlFailIds = @('sub-x')
        $null = script:Invoke-Run -Subs @($script:A, $script:X)
        $Global:RdaRlFailIds = @()
        # Sub X is gone; Sub C is new, so no run has reached it.
        $R1 = script:Invoke-Run -Subs @($script:A, $script:C) -ResumeFailedOnly
        @(script:Get-Lines -Run $R1 -Like 'Dropped from the retry list:*').Count | Should -Be 1
        @(script:Get-Lines -Run $R1 -Like 'Resume state cleared*') | Should -BeNullOrEmpty
        $R1.ExitCode | Should -Be 2
        Test-Path -LiteralPath $script:State | Should -BeTrue
    }
}

Describe 'A subscription listing that came back with warnings or errors' {
    BeforeAll {
        Mock Import-Module -ParameterFilter { $Name -eq 'Az.Accounts' } -MockWith { }
        Mock Disable-AzContextAutosave -MockWith { }
        Mock Import-AzContext -MockWith { }
    }
    BeforeEach { script:New-Case }

    # A subscription missing from such a listing may only be hidden for now, so
    # its failures and count are not forgotten.
    It 'keeps the retry entry of a subscription it left out (<Kind>), and a complete listing drops it' -ForEach @(@{ Kind = 'warnings' }, @{ Kind = 'errors' }) {
        $Global:RdaRlFailIds = @('sub-x')
        $null = script:Invoke-Run -Subs @($script:A, $script:B, $script:X)
        $Global:RdaRlFailIds = @()
        if ($Kind -eq 'warnings') { $Global:RdaRlListWarnings = @('stand-in: unable to acquire a token for part of the tenant') }
        else { $Global:RdaRlListErrors = @('stand-in: a page of the subscription list could not be read') }
        $R2 = script:Invoke-Run -Subs @($script:A, $script:B) -Resume
        @(script:Get-Lines -Run $R2 -Like 'Dropped from the retry list:*') | Should -BeNullOrEmpty
        @(script:Get-Lines -Run $R2 -Like 'Kept on the retry list:*') | Should -Be @('Kept on the retry list: 1 subscription(s) not in the subscription list (Sub X (sub-x)), because Get-AzSubscription returned warnings or errors, so the list may be incomplete:')
        # What the listing said, so the user can see what to fix.
        $Said = if ($Kind -eq 'warnings') { '  - stand-in: unable to acquire a token for part of the tenant' } else { '  - stand-in: a page of the subscription list could not be read' }
        @(script:Get-Lines -Run $R2 -Like '  - stand-in:*') | Should -Be @($Said)
        [int](script:Get-Entry -Id 'sub-x').Attempts | Should -Be 1
        Test-Path -LiteralPath $script:State | Should -BeTrue
        $Global:RdaRlListWarnings = @()
        $Global:RdaRlListErrors = @()
        $R3 = script:Invoke-Run -Subs @($script:A, $script:B) -Resume
        @(script:Get-Lines -Run $R3 -Like 'Dropped from the retry list:*').Count | Should -Be 1
        script:Get-Entry -Id 'sub-x' | Should -BeNullOrEmpty
        Test-Path -LiteralPath $script:State | Should -BeFalse
    }
}

Describe 'An Az notice of a coming breaking change from the subscription listing' {
    BeforeEach { script:New-Case }

    It 'does not keep a gone subscription on the retry list' {
        $Global:RdaRlFailIds = @('sub-x')
        $null = script:Invoke-Run -Subs @($script:A, $script:X)
        $Global:RdaRlFailIds = @()
        $Global:RdaRlListWarnings = @('Upcoming breaking changes in the cmdlet ''Get-AzSubscription'': the output type will change.')
        $R = script:Invoke-Run -Subs @($script:A) -Resume
        @(script:Get-Lines -Run $R -Like 'Dropped from the retry list:*').Count | Should -Be 1
        @(script:Get-Lines -Run $R -Like 'Kept on the retry list:*') | Should -BeNullOrEmpty
    }
}

Describe 'The access check''s result when nothing is left to check' {
    It 'is set to $null before the check, as the end of the run reads it' {
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $PSScriptRoot -Parent) 'Run-AllSubscriptions.ps1'), [ref]$null, [ref]$null)
        $Top = @($Ast.EndBlock.Statements)
        $Init = @(for ($i = 0; $i -lt $Top.Count; $i++) { if ($Top[$i].Extent.Text -eq '$AccessDecision = $null') { $i } })
        $Scope = @(for ($i = 0; $i -lt $Top.Count; $i++) { if ($Top[$i].Extent.Text.StartsWith('$ScopeForProbe = ')) { $i } })
        $Init.Count | Should -Be 1
        $Init[0] | Should -BeLessThan $Scope[0]
    }
}

Describe 'A subscription past the retry limit that is no longer listed' {
    BeforeAll {
        Mock Import-Module -ParameterFilter { $Name -eq 'Az.Accounts' } -MockWith { }
        Mock Disable-AzContextAutosave -MockWith { }
        Mock Import-AzContext -MockWith { }
    }
    BeforeEach { script:New-Case }

    # A -ResumeFailedOnly run that drops the last gone entry while the state can
    # be neither written nor removed leaves the entry for the next run: exit 2
    # with the way out, not a success that repeats.
    It 'drops the last gone entry while the state can be neither written nor removed: exit 2 and the way out, on this run and the next' {
        $Global:RdaRlFailIds = @('sub-x')
        $null = script:Invoke-Run -Subs @($script:A, $script:B, $script:X)
        $Global:RdaRlFailIds = @()
        Mock Set-Content -ParameterFilter { [string]$LiteralPath -like '*.resume-state-*.tmp' } -MockWith { throw 'stand-in: disk full' }
        Mock Remove-Item -ParameterFilter { [string]$LiteralPath -eq $script:State } -MockWith { throw 'stand-in: read-only' }
        # Sub X is deleted: a complete listing no longer has it.
        $R1 = script:Invoke-Run -Subs @($script:A, $script:B) -ResumeFailedOnly
        $R1.ExitCode | Should -Be 2
        @(script:Get-Lines -Run $R1 -Like 'ERROR: The resume state file * could not be written or removed, so it still lists the retry entries dropped above*').Count | Should -Be 1
        @((script:Get-Entry -Id 'sub-x')) | Should -Not -BeNullOrEmpty -Because 'the drop did not reach the disk'
        $R2 = script:Invoke-Run -Subs @($script:A, $script:B) -ResumeFailedOnly
        $R2.ExitCode | Should -Be 2 -Because 'the cause is not fixed yet'
    }

    It 'drops the last gone entry once the state can be written again, and ends with exit 0' {
        $Global:RdaRlFailIds = @('sub-x')
        $null = script:Invoke-Run -Subs @($script:A, $script:B, $script:X)
        $Global:RdaRlFailIds = @()
        $R = script:Invoke-Run -Subs @($script:A, $script:B) -ResumeFailedOnly
        $R.ExitCode | Should -Be 0
        @(script:Get-Lines -Run $R -Like 'ERROR: The resume state file * could not be written or removed*') | Should -BeNullOrEmpty
        Test-Path -LiteralPath $script:State | Should -BeFalse
    }

    # A run without -Resume reads and writes the same retry list, so it drops the
    # entry of a subscription a complete listing no longer has; else that entry
    # would end every such run with exit 2 and advise the same run again.
    It 'is dropped by the next run without -Resume, which exits 0, and the run after it starts clean (<Streams> stream(s))' -ForEach @(@{ Streams = 1 }, @{ Streams = 2 }) {
        $Global:RdaRlFailIds = @('sub-x')
        $Subs = @($script:A, $script:B, $script:X)
        $null = script:Invoke-Run -Subs $Subs -Streams $Streams
        $null = script:Invoke-Run -Subs $Subs -Streams $Streams -Resume
        $null = script:Invoke-Run -Subs $Subs -Streams $Streams -Resume
        [int](script:Get-Entry -Id 'sub-x').Attempts | Should -Be 3
        $Global:RdaRlFailIds = @()
        # Sub X is deleted: a complete listing no longer has it.
        $R1 = script:Invoke-Run -Subs @($script:A, $script:B) -Streams $Streams
        @(script:Get-Lines -Run $R1 -Like 'Dropped from the retry list:*') | Should -Be @('Dropped from the retry list: Sub X (sub-x) is no longer visible to the signed-in identity, so no run can retry it.')
        @(script:Get-Lines -Run $R1 -Like 'Retry Limit Reached:*') | Should -BeNullOrEmpty
        @(script:Get-Lines -Run $R1 -Like 'Resume state cleared (clean run).').Count | Should -Be 1
        $R1.ExitCode | Should -BeNullOrEmpty
        $R1.Result.WrapperExitCode | Should -Be 0
        Test-Path -LiteralPath $script:State | Should -BeFalse
        $R2 = script:Invoke-Run -Subs @($script:A, $script:B) -Streams $Streams
        @(script:Get-Lines -Run $R2 -Like 'Dropped from the retry list:*') | Should -BeNullOrEmpty
        @(script:Get-Lines -Run $R2 -Like 'Retry Limit Reached:*') | Should -BeNullOrEmpty
        @($R2.Calls | Sort-Object -Unique) | Should -Be @('sub-a', 'sub-b')
        $R2.Result.WrapperExitCode | Should -Be 0
        Test-Path -LiteralPath $script:State | Should -BeFalse
    }

    It 'is kept while the listing warns, with the warning shown, exit 2 and advice to fix the listing and run again; the run named then drops it' {
        $Global:RdaRlFailIds = @('sub-x')
        $Subs = @($script:A, $script:B, $script:X)
        $null = script:Invoke-Run -Subs $Subs
        $null = script:Invoke-Run -Subs $Subs -Resume
        $null = script:Invoke-Run -Subs $Subs -Resume
        $Global:RdaRlFailIds = @()
        # Sub X is not in the listing, and the listing came back with a warning.
        $Global:RdaRlListWarnings = @('stand-in: unable to acquire a token for part of the tenant')
        $R1 = script:Invoke-Run -Subs @($script:A, $script:B)
        @(script:Get-Lines -Run $R1 -Like 'Kept on the retry list:*') | Should -Be @('Kept on the retry list: 1 subscription(s) not in the subscription list (Sub X (sub-x)), because Get-AzSubscription returned warnings or errors, so the list may be incomplete:')
        @(script:Get-Lines -Run $R1 -Like '  - stand-in:*') | Should -Be @('  - stand-in: unable to acquire a token for part of the tenant')
        @(script:Get-Lines -Run $R1 -Like 'Dropped from the retry list:*') | Should -BeNullOrEmpty
        @(script:Get-Lines -Run $R1 -Like 'Retry Limit Reached:*') | Should -Be @('Retry Limit Reached:     1 (Sub X) - incomplete; -Resume and -ResumeFailedOnly do not collect these')
        @(script:Get-Lines -Run $R1 -Like '  Sub X is not in the subscription list*') | Should -Be @("  Sub X is not in the subscription list, which came back with warnings or errors (printed at the start of the run). Fix those until 'Get-AzSubscription -TenantId t' lists the tenant without them, then run again: the run drops a subscription that is gone from the retry list, and collects one that is listed again, for example:")
        @(script:Get-Lines -Run $R1 -Like '    ./Run-AllSubscriptions.ps1 *') | Should -Be @('    ./Run-AllSubscriptions.ps1 -TenantID t')
        @(script:Get-Lines -Run $R1 -Like '*start a run without -Resume or -ResumeFailedOnly*') | Should -BeNullOrEmpty -Because 'that run alone would leave it as it is while the listing warns'
        $R1.Result.WrapperExitCode | Should -Be 2 -Because 'its report is missing and its entry is kept'
        Test-Path -LiteralPath $script:State | Should -BeTrue
        [int](script:Get-Entry -Id 'sub-x').Attempts | Should -Be 3
        # The listing is complete again; the run the advice names.
        $Global:RdaRlListWarnings = @()
        $R2 = script:Invoke-Run -Subs @($script:A, $script:B)
        @(script:Get-Lines -Run $R2 -Like 'Dropped from the retry list:*').Count | Should -Be 1
        @(script:Get-Lines -Run $R2 -Like 'Retry Limit Reached:*') | Should -BeNullOrEmpty
        $R2.Result.WrapperExitCode | Should -Be 0
        Test-Path -LiteralPath $script:State | Should -BeFalse
        $R3 = script:Invoke-Run -Subs @($script:A, $script:B)
        @(script:Get-Lines -Run $R3 -Like 'Dropped from the retry list:*') | Should -BeNullOrEmpty
        $R3.Result.WrapperExitCode | Should -Be 0
        Test-Path -LiteralPath $script:State | Should -BeFalse
    }
}

Describe 'A subscription past the retry limit that the access check finds not readable' {
    BeforeEach { script:New-Case }

    It 'keeps its entry, exits 2 under -AllowPartialAccess with advice that names the access problem, and the run after access is fixed collects it' {
        $Global:RdaRlFailIds = @('sub-x')
        $Subs = @($script:A, $script:X)
        $null = script:Invoke-Run -Subs $Subs
        $null = script:Invoke-Run -Subs $Subs -Resume
        $null = script:Invoke-Run -Subs $Subs -Resume
        [int](script:Get-Entry -Id 'sub-x').Attempts | Should -Be 3
        $Global:RdaRlFailIds = @()
        $Global:RdaRlUnreadableIds = @('sub-x')
        $Global:RdaRlAllowPartialAccess = $true

        # The run the advice names, without -Resume: the access check skips Sub X.
        $R = script:Invoke-Run -Subs $Subs
        @($R.Calls) | Should -Not -Contain 'sub-x'
        @($R.Calls) | Should -Contain 'sub-a'
        script:Get-Entry -Id 'sub-x' | Should -Not -BeNullOrEmpty
        $R.Result.WrapperExitCode | Should -Be 2 -Because 'Sub X stays on the retry list and its report is missing'
        @(script:Get-Lines -Run $R -Like 'Retry Limit Reached:*').Count | Should -Be 1
        @(script:Get-Lines -Run $R -Like '  Sub X was skipped by the access check at the start of this run*') | Should -Be @('  Sub X was skipped by the access check at the start of this run (the reason and the fix are printed there). Once the check can read it, start a run without -Resume or -ResumeFailedOnly, for example:')
        @(script:Get-Lines -Run $R -Like '  To start over with an empty retry list instead*') | Should -Be @('  To start over with an empty retry list instead, delete the resume state files .resume-state-t.json and .resume-state-t-stream-*.json in the inventory folder: the next run collects every subscription.')
        @($R.Text | Where-Object { $_ -match 'IncludeDisabled' }) | Should -BeNullOrEmpty
        Test-Path -LiteralPath $script:State | Should -BeTrue

        # Access fixed: the same run collects it and ends clean.
        $Global:RdaRlUnreadableIds = @()
        $R2 = script:Invoke-Run -Subs $Subs
        @($R2.Calls) | Should -Contain 'sub-x'
        script:Get-Entry -Id 'sub-x' | Should -BeNullOrEmpty
        $R2.Result.WrapperExitCode | Should -Be 0
    }
}

Describe 'The Pending Retries line' {
    BeforeEach { script:New-Case }

    It 'counts only the retry-list entries below the limit' {
        $Global:RdaRlFailIds = @('sub-x', 'sub-y')
        $null = script:Invoke-Run -Subs @($script:A, $script:X, $script:Y)
        # Sub Y is left out of a subscription listing that came back with
        # warnings now, so it stays on the retry list with one failed run.
        $Global:RdaRlFailIds = @('sub-x')
        $Global:RdaRlListWarnings = @('stand-in: unable to acquire a token for part of the tenant')
        $null = script:Invoke-Run -Subs @($script:A, $script:X) -Resume
        $null = script:Invoke-Run -Subs @($script:A, $script:X) -Resume
        [int](script:Get-Entry -Id 'sub-x').Attempts | Should -Be 3
        [int](script:Get-Entry -Id 'sub-y').Attempts | Should -Be 1

        $Global:RdaRlFailIds = @()
        $R = script:Invoke-Run -Subs @($script:A, $script:X) -Resume
        @($R.Result.FailedSubscriptions) | Should -BeNullOrEmpty
        # Sub Y is not in this run's subscription set, so -ResumeFailedOnly could
        # not collect it: it is named under Not In This Run, not Pending Retries.
        @(script:Get-Lines -Run $R -Like 'Pending Retries:*') | Should -BeNullOrEmpty
        @(script:Get-Lines -Run $R -Like 'Not In This Run:         1 (Sub Y (sub-y))*').Count | Should -Be 1
    }
}

Describe 'Get-FailedAttemptCount under Set-StrictMode' {
    It 'counts an entry without Attempts as one failed run' {
        $Count = & {
            Set-StrictMode -Version Latest
            Get-FailedAttemptCount -Entry ([pscustomobject]@{ Id = 'sub-x'; Name = 'Sub X' })
        }
        $Count | Should -Be 1
    }
}
