# Run-AllSubscriptions.ps1 Reconciliation Logic Tests
#
# Unit-tests small, self-contained functions in Run-AllSubscriptions.ps1 in
# isolation, without running the wrapper itself (which requires a live Azure
# session, a tenant, and spins up real -Resume state / background jobs).
#
#   - Get-StreamResumeStateFiles: discovers every per-stream resume-state
#     file on disk for a tenant (fixes the "orphaned resume files when
#     -ParallelStreams shrinks across -Resume" bug: iterating 0..StreamCount-1
#     missed files left behind by an earlier, larger-StreamCount run).
#   - Merge-FailedAttempts: reconciles FailedAttempts entries gathered from
#     multiple streams against the unified CompletedIds list, keeping the
#     MOST RECENT LastFailedAt when the same sub Id appears more than once
#     (fixes the "stale failure metadata won reconciliation" bug: the old
#     inline code sorted by Attempts count instead of LastFailedAt recency).
#   - Get-WrapperExitCode: decides the wrapper's machine-facing exit code
#     (0/3/4/5) from two independent health signals - auth-skip (Metrics
#     and/or Consumption skipped for lack of a usable Azure token) and
#     collector failures (#22, a Services/*/*.ps1 collector threw). Guards
#     against one problem masking the other in the exit code when both occur
#     in the same run.
#
# Run with: Invoke-Pester ./Tests/RunAllSubscriptionsReconciliation.Tests.ps1 -Output Detailed
#
# The functions under test used to be defined inline in Run-AllSubscriptions.ps1,
# whose body executes side-effecting code immediately after its param() block
# (pre-flight checks, tenant resolution, az/Az PowerShell auth) - so this test
# had to AST-parse the script and dot-source only the target functions. They
# now live in Functions/RunAllSubscriptions.Functions.ps1, a definitions-only
# file with NO top-level side effects, so we can dot-source it wholesale here.
# The same file is dot-sourced at runtime by both Run-AllSubscriptions.ps1 and
# its stream worker, so this test exercises the exact code that ships.

BeforeAll {
    $script:FunctionsPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Functions/RunAllSubscriptions.Functions.ps1'
    if (-not (Test-Path $script:FunctionsPath))
    {
        throw "Could not find shared functions file at $script:FunctionsPath"
    }
    . $script:FunctionsPath

    # Guard: the functions under test must be defined by the shared file. If a
    # future change renames or removes one, fail loudly here rather than with a
    # confusing "command not found" mid-test.
    $TargetFunctions = @('Get-StreamResumeStateFiles', 'Merge-FailedAttempts', 'Get-WrapperExitCode', 'Add-FailedAttempt', 'Remove-FailedAttempt', 'Get-ConsumptionAccessOutcome', 'Resolve-AccessPreflight', 'Test-SubscriptionAccessAll')
    foreach ($Fn in $TargetFunctions)
    {
        if (-not (Get-Command $Fn -CommandType Function -ErrorAction SilentlyContinue))
        {
            throw "Expected function '$Fn' to be defined by $script:FunctionsPath, but it was not. Has it been renamed or removed?"
        }
    }

    $TmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { '/tmp' }
    $script:TestRoot = Join-Path $TmpBase ("RunAllSubsReconTest_" + [guid]::NewGuid().ToString().Substring(0, 8))
    New-Item -ItemType Directory -Path $script:TestRoot -Force | Out-Null
}

AfterAll {
    if ($script:TestRoot -and (Test-Path $script:TestRoot))
    {
        Remove-Item -Path $script:TestRoot -Recurse -Force
    }
}

Describe 'Get-StreamResumeStateFiles' {
    BeforeEach {
        # Isolate each test in its own subdirectory so file listings never
        # bleed between tests.
        $script:CaseDir = Join-Path $script:TestRoot ([guid]::NewGuid().ToString().Substring(0, 8))
        New-Item -ItemType Directory -Path $script:CaseDir -Force | Out-Null
    }

    AfterEach {
        if (Test-Path $script:CaseDir) { Remove-Item -Path $script:CaseDir -Recurse -Force }
    }

    It 'Finds every per-stream resume file for the tenant, including stream numbers beyond the current run''s StreamCount' {
        $Tenant = 'tenant-abc'
        # Simulate an earlier run that used -ParallelStreams 4 (streams 0-3),
        # then a later run using -ParallelStreams 2. All four files must still
        # be discovered so their data is not silently dropped/orphaned.
        0..3 | ForEach-Object {
            Set-Content -Path (Join-Path $script:CaseDir (".resume-state-$Tenant-stream-$_.json")) -Value '{}'
        }
        $Files = Get-StreamResumeStateFiles -InventoryRoot $script:CaseDir -Tenant $Tenant
        $Files.Count | Should -Be 4 -Because 'all four per-stream files (0-3) must be discovered regardless of the current run''s -ParallelStreams value'
    }

    It 'Does not return resume files belonging to a different tenant' {
        $Tenant = 'tenant-abc'
        Set-Content -Path (Join-Path $script:CaseDir ".resume-state-$Tenant-stream-0.json") -Value '{}'
        Set-Content -Path (Join-Path $script:CaseDir ".resume-state-other-tenant-stream-0.json") -Value '{}'
        $Files = Get-StreamResumeStateFiles -InventoryRoot $script:CaseDir -Tenant $Tenant
        $Files.Count | Should -Be 1
        $Files[0].Name | Should -Be ".resume-state-$Tenant-stream-0.json"
    }

    It 'Does not return the unified (non-stream) resume-state file' {
        $Tenant = 'tenant-abc'
        Set-Content -Path (Join-Path $script:CaseDir ".resume-state-$Tenant.json") -Value '{}'
        Set-Content -Path (Join-Path $script:CaseDir ".resume-state-$Tenant-stream-0.json") -Value '{}'
        $Files = Get-StreamResumeStateFiles -InventoryRoot $script:CaseDir -Tenant $Tenant
        $Files.Count | Should -Be 1
        $Files[0].Name | Should -Be ".resume-state-$Tenant-stream-0.json"
    }

    It 'Returns an empty array (not $null / an error) when no per-stream files exist' {
        $Files = @(Get-StreamResumeStateFiles -InventoryRoot $script:CaseDir -Tenant 'tenant-with-no-files')
        $Files.Count | Should -Be 0
    }
}

Describe 'Merge-FailedAttempts' {
    It 'Keeps the entry with the MOST RECENT LastFailedAt when the same sub Id fails in multiple streams (regression guard for the stale-failure-wins bug)' {
        # This is the exact shape of the original bug: a sub with a HIGH
        # Attempts count but an OLD LastFailedAt must NOT beat a sub entry
        # with a LOW Attempts count but a NEWER LastFailedAt. Recency must
        # win, not attempt count.
        $Stale = [pscustomobject]@{ Id = 'sub-1'; Name = 'Sub One'; LastFailedAt = '2026-01-01T00:00:00Z'; Reason = 'stale-old-failure'; Attempts = 5 }
        $Fresh = [pscustomobject]@{ Id = 'sub-1'; Name = 'Sub One'; LastFailedAt = '2026-06-01T00:00:00Z'; Reason = 'fresh-new-failure'; Attempts = 1 }

        $Result = Merge-FailedAttempts -ExistingFailedAttempts @($Stale) -StreamFailedAttempts @($Fresh) -CompletedIds @()

        $Result.Count | Should -Be 1
        $Result[0].Reason | Should -Be 'fresh-new-failure' -Because 'the most recent LastFailedAt must win regardless of Attempts count'
    }

    It 'Drops a failed attempt entirely once its sub Id appears in CompletedIds' {
        $Failure = [pscustomobject]@{ Id = 'sub-2'; Name = 'Sub Two'; LastFailedAt = '2026-06-01T00:00:00Z'; Reason = 'transient'; Attempts = 1 }
        $Result = Merge-FailedAttempts -ExistingFailedAttempts @($Failure) -StreamFailedAttempts @() -CompletedIds @('sub-2')
        $Result.Count | Should -Be 0 -Because 'a sub that later completed successfully must not remain in FailedAttempts'
    }

    It 'Drops a failed attempt from CompletedIds even when there are zero new stream failures (pure prune path)' {
        $StaleFailure = [pscustomobject]@{ Id = 'sub-3'; Name = 'Sub Three'; LastFailedAt = '2026-01-01T00:00:00Z'; Reason = 'old'; Attempts = 2 }
        $StillFailing = [pscustomobject]@{ Id = 'sub-4'; Name = 'Sub Four'; LastFailedAt = '2026-01-01T00:00:00Z'; Reason = 'old'; Attempts = 2 }
        $Result = Merge-FailedAttempts -ExistingFailedAttempts @($StaleFailure, $StillFailing) -StreamFailedAttempts @() -CompletedIds @('sub-3')
        $Result.Count | Should -Be 1
        $Result[0].Id | Should -Be 'sub-4' -Because 'only the completed sub should be pruned; the still-failing sub must remain'
    }

    It 'Preserves failures for subs not present in CompletedIds and not touched by any stream' {
        $Untouched = [pscustomobject]@{ Id = 'sub-5'; Name = 'Sub Five'; LastFailedAt = '2026-01-01T00:00:00Z'; Reason = 'unrelated'; Attempts = 1 }
        $NewFailure = [pscustomobject]@{ Id = 'sub-6'; Name = 'Sub Six'; LastFailedAt = '2026-06-01T00:00:00Z'; Reason = 'new'; Attempts = 1 }
        $Result = Merge-FailedAttempts -ExistingFailedAttempts @($Untouched) -StreamFailedAttempts @($NewFailure) -CompletedIds @()
        $Result.Count | Should -Be 2
        ($Result | Where-Object { $_.Id -eq 'sub-5' }) | Should -Not -BeNullOrEmpty
        ($Result | Where-Object { $_.Id -eq 'sub-6' }) | Should -Not -BeNullOrEmpty
    }

    It 'Returns an empty array when there are no existing failures and no stream failures' {
        $Result = @(Merge-FailedAttempts -ExistingFailedAttempts @() -StreamFailedAttempts @() -CompletedIds @())
        $Result.Count | Should -Be 0
    }
}

Describe 'Get-WrapperExitCode' {
    It 'Returns 0 when neither auth-skip nor collector failures occurred' {
        Get-WrapperExitCode -AuthSkipped $false -CollectorsFailed $false | Should -Be 0
    }

    It 'Returns 3 when only auth-skip occurred' {
        Get-WrapperExitCode -AuthSkipped $true -CollectorsFailed $false | Should -Be 3
    }

    It 'Returns 4 when only collector failures occurred' {
        Get-WrapperExitCode -AuthSkipped $false -CollectorsFailed $true | Should -Be 4
    }

    It 'Returns 5 when BOTH auth-skip and collector failures occurred (regression guard for the masking bug)' {
        # This is the exact case the fix addresses: a plain if/elseif chain
        # ordered by which code was added first would let 3 mask 4 (or vice
        # versa) and silently drop one signal from the exit code. Both
        # problems occurring together must be distinctly detectable by
        # anything that only checks the exit code.
        Get-WrapperExitCode -AuthSkipped $true -CollectorsFailed $true | Should -Be 5 -Because 'neither failure signal may be silently dropped when both occur in the same run'
    }

    It 'Returns 2 when a subscription failed, whatever else happened (a failed run is never reported as clean)' -ForEach @(
        @{ Auth = $false; Collectors = $false }
        @{ Auth = $true; Collectors = $false }
        @{ Auth = $false; Collectors = $true }
        @{ Auth = $true; Collectors = $true }
    ) {
        Get-WrapperExitCode -AuthSkipped $Auth -CollectorsFailed $Collectors -SubscriptionsFailed $true | Should -Be 2
    }

    It 'Get-WrapperExitCodeSummary says what exit <Code> means (auth <Auth>, collectors <Collectors>, failed <Failed>, zip <Zip>)' -ForEach @(
        @{ Auth = $false; Collectors = $false; Failed = $false; Zip = $true; Code = 0; First = 'Exit code 0: clean run, no failures of any kind.'; Also = $null }
        @{ Auth = $true; Collectors = $false; Failed = $false; Zip = $true; Code = 3; First = 'Exit code 3: Metrics and/or Consumption were skipped for a sign-in problem (see FAILED (auth)); the rest of the report was made.'; Also = $null }
        @{ Auth = $false; Collectors = $true; Failed = $false; Zip = $true; Code = 4; First = 'Exit code 4: one or more collectors failed (see FAILED (collectors)); the rest of the report was made.'; Also = $null }
        @{ Auth = $true; Collectors = $true; Failed = $false; Zip = $true; Code = 5; First = 'Exit code 5: Metrics and/or Consumption were skipped for a sign-in problem and one or more collectors failed (see FAILED (auth) and FAILED (collectors)); the rest of the report was made.'; Also = $null }
        @{ Auth = $false; Collectors = $false; Failed = $true; Zip = $true; Code = 2; First = 'Exit code 2: one or more subscriptions failed (see Subscriptions Failed); the consolidated zip holds the reports of the subscriptions that worked.'; Also = $null }
        @{ Auth = $false; Collectors = $false; Failed = $true; Zip = $false; Code = 2; First = 'Exit code 2: one or more subscriptions failed (see Subscriptions Failed); no consolidated zip was made.'; Also = $null }
        @{ Auth = $true; Collectors = $false; Failed = $true; Zip = $true; Code = 2; First = 'Exit code 2: one or more subscriptions failed (see Subscriptions Failed); the consolidated zip holds the reports of the subscriptions that worked.'; Also = 'Exit code 2 takes priority over exit code 3, which this run also has: Metrics and/or Consumption were skipped for a sign-in problem.' }
        @{ Auth = $false; Collectors = $true; Failed = $true; Zip = $true; Code = 2; First = 'Exit code 2: one or more subscriptions failed (see Subscriptions Failed); the consolidated zip holds the reports of the subscriptions that worked.'; Also = 'Exit code 2 takes priority over exit code 4, which this run also has: one or more collectors failed.' }
        @{ Auth = $true; Collectors = $true; Failed = $true; Zip = $false; Code = 2; First = 'Exit code 2: one or more subscriptions failed (see Subscriptions Failed); no consolidated zip was made.'; Also = 'Exit code 2 takes priority over exit code 5, which this run also has: Metrics and/or Consumption were skipped for a sign-in problem and one or more collectors failed.' }
    ) {
        Get-WrapperExitCode -AuthSkipped $Auth -CollectorsFailed $Collectors -SubscriptionsFailed $Failed | Should -Be $Code
        $Lines = @(Get-WrapperExitCodeSummary -AuthSkipped $Auth -CollectorsFailed $Collectors -SubscriptionsFailed $Failed -ReportMade $Zip)
        $Lines[0] | Should -BeExactly $First
        if ($null -eq $Also) { $Lines.Count | Should -Be 1 } else { $Lines.Count | Should -Be 2; $Lines[1] | Should -BeExactly $Also }
    }

    It 'Get-WrapperExitCodeSummary names a stream summary that could not be read, not as failed subscriptions (zip <Zip>)' -ForEach @(
        @{ Zip = $true; Tail = 'check the consolidated zip for their reports' }
        @{ Zip = $false; Tail = 'no consolidated zip was made' }
    ) {
        $Streams = @([pscustomobject]@{ StreamId = 1; SubCount = 3 })
        $Lines = @(Get-WrapperExitCodeSummary -AuthSkipped $false -CollectorsFailed $true -UnreadableStreams $Streams -ReportMade $Zip)
        $Lines | Should -Be @(
            ('Exit code 2: the summary of stream 1 could not be read; its 3 subscription(s) are not confirmed; {0}.' -f $Tail)
            'Exit code 2 takes priority over exit code 4, which this run also has: one or more collectors failed.'
        )
        $Both = @(Get-WrapperExitCodeSummary -AuthSkipped $false -CollectorsFailed $false -SubscriptionsFailed $true -UnreadableStreams $Streams -ReportMade $Zip)
        $Both.Count | Should -Be 2
        $Both[0] | Should -Match '^Exit code 2: one or more subscriptions failed \(see Subscriptions Failed\)'
        $Both[1] | Should -Match '^Exit code 2: the summary of stream 1 could not be read'
    }

    It 'Get-WrapperExitCodeSummary says a stream summary that is missing is missing, not that it could not be read (zip <Zip>)' -ForEach @(
        @{ Zip = $true; Tail = 'check the consolidated zip for their reports' }
        @{ Zip = $false; Tail = 'no consolidated zip was made' }
    ) {
        $Streams = @(
            [pscustomobject]@{ StreamId = 0; SubCount = 2; Reason = 'Missing' }
            [pscustomobject]@{ StreamId = 1; SubCount = 3; Reason = 'Unreadable' }
        )
        $Lines = @(Get-WrapperExitCodeSummary -AuthSkipped $false -CollectorsFailed $false -UnreadableStreams $Streams -ReportMade $Zip)
        $Lines | Should -Be @(
            ('Exit code 2: the summary of stream 0 is missing; its 2 subscription(s) are not confirmed; {0}.' -f $Tail)
            ('Exit code 2: the summary of stream 1 could not be read; its 3 subscription(s) are not confirmed; {0}.' -f $Tail)
        )
    }

    It 'Get-WrapperExitCodeSummary describes the verification-gap stop (auth <Auth>, collectors <Collectors>, failed <Failed>)' -ForEach @(
        @{ Auth = $false; Collectors = $false; Failed = $false; Also = @() }
        @{ Auth = $true; Collectors = $false; Failed = $false; Also = @('Exit code 2 takes priority over exit code 3, which this run also has: Metrics and/or Consumption were skipped for a sign-in problem.') }
        @{ Auth = $true; Collectors = $true; Failed = $true; Also = @('Exit code 2: one or more subscriptions failed (see Subscriptions Failed); no consolidated zip was made.', 'Exit code 2 takes priority over exit code 5, which this run also has: Metrics and/or Consumption were skipped for a sign-in problem and one or more collectors failed.') }
    ) {
        $Lines = @(Get-WrapperExitCodeSummary -AuthSkipped $Auth -CollectorsFailed $Collectors -SubscriptionsFailed $Failed -VerificationGap $true -ReportMade $false)
        $Lines | Should -Be (@('Exit code 2: a report is missing (verification gap, see Per-subscription output verification failed); no consolidated zip was made.') + $Also)
    }

    # That the wrapper passes its failed subscriptions in is tested by running
    # it, in Tests/ExitCodeCarryOver.Tests.ps1: sequential, one subscription
    # with -ParallelStreams, a failed subscription in a stream, and a stream
    # summary the wrapper cannot read.
}

Describe 'Resolve-StreamSummary (the one reader of a stream summary)' {
    # The summaries are JSON text, parsed as the wrapper parses the file, so
    # the values have the types ConvertFrom-Json gives them.
    BeforeAll {
        $script:GoodRow = '{"Id":"sub-a","Name":"Sub A","Count":3,"Zip":"/reports/a/ResourcesReport_a.zip"}'
        $script:RunId = '11111111-2222-3333-4444-555555555555'
        # The summary names this run (as the worker writes it) unless the
        # case names its own RunId.
        function script:Read-Case
        {
            param([string]$Json, [string[]]$Expected = @('sub-a'))
            if ($Json -like '{*' -and $Json -notlike '*"RunId"*') { $Json = '{"RunId":"' + $script:RunId + '",' + $Json.Substring(1) }
            Resolve-StreamSummary -Summary ($Json | ConvertFrom-Json) -RunId $script:RunId -StreamId '0' -ExpectedIds $Expected
        }
    }

    It 'accepts a good summary and gives back its values with their types' {
        $Json = '{"StreamId":"0","Status":"partial-failure","ResourceCounts":[' + $script:GoodRow + '],"Failed":[{"Id":"sub-b","Name":"Sub B","Reason":"it failed"}],"ConsumptionRecords":7,"ConsumptionFailedSubs":[{"Id":"(auth)","Name":"(all subscriptions)","Message":"m"}],"MetricsFailedSubs":[{"Id":"sub-a","Name":"Sub A","Message":"m"}],"CollectorFailures":[{"Id":"sub-a","Module":"VM","Message":"m"}]}'
        $Read = Read-Case -Json $Json -Expected @('sub-a', 'sub-b')
        $Read.Accepted | Should -BeTrue -Because $Read.Reason
        $Read.Status | Should -Be 'partial-failure'
        @($Read.ResourceCounts).Count | Should -Be 1
        $Read.ResourceCounts[0].Count | Should -BeOfType [int]
        $Read.ResourceCounts[0].Count | Should -Be 3
        $Read.ResourceCounts[0].Zip | Should -Be '/reports/a/ResourcesReport_a.zip'
        $Read.Failed[0].Reason | Should -Be 'it failed'
        $Read.ConsumptionRecords | Should -BeOfType [int]
        $Read.ConsumptionRecords | Should -Be 7
        @($Read.ConsumptionFailedSubs).Count | Should -Be 1
        @($Read.MetricsFailedSubs).Count | Should -Be 1
        @($Read.CollectorFailures).Count | Should -Be 1
    }

    It 'accepts a summary whose lists and record count are absent, when the stream ran nothing' {
        $Read = Read-Case -Json '{"StreamId":"0","Status":"ok"}' -Expected @()
        $Read.Accepted | Should -BeTrue -Because $Read.Reason
        @($Read.ResourceCounts).Count | Should -Be 0
        $Read.ConsumptionRecords | Should -BeNullOrEmpty
    }

    It 'does not confirm a summary whose <Case>' -ForEach @(
        @{ Case = 'success row has no Count'; Json = '{"StreamId":"0","ResourceCounts":[{"Id":"sub-a","Name":"Sub A","Zip":"/r/a.zip"}]}'; Reason = 'success row' }
        @{ Case = 'success row Count is text'; Json = '{"StreamId":"0","ResourceCounts":[{"Id":"sub-a","Count":"abc"}]}'; Reason = 'success row' }
        @{ Case = 'success row Count is below 0'; Json = '{"StreamId":"0","ResourceCounts":[{"Id":"sub-a","Count":-1}]}'; Reason = 'success row' }
        @{ Case = 'success row Count is not a whole number'; Json = '{"StreamId":"0","ResourceCounts":[{"Id":"sub-a","Count":1.5}]}'; Reason = 'success row' }
        @{ Case = 'success row Count is too big'; Json = '{"StreamId":"0","ResourceCounts":[{"Id":"sub-a","Count":3000000000}]}'; Reason = 'success row' }
        @{ Case = 'success row has no Id'; Json = '{"StreamId":"0","ResourceCounts":[{"Name":"Sub A","Count":1}],"Failed":[{"Id":"sub-a","Name":"Sub A","Reason":"r"}]}'; Reason = 'success row' }
        @{ Case = 'success row Id is a number'; Json = '{"StreamId":"0","ResourceCounts":[{"Id":5,"Count":1}],"Failed":[{"Id":"sub-a","Name":"Sub A","Reason":"r"}]}'; Reason = 'success row' }
        @{ Case = 'success row Name is a number'; Json = '{"StreamId":"0","ResourceCounts":[{"Id":"sub-a","Name":5,"Count":1}]}'; Reason = 'success row' }
        @{ Case = 'success row Zip is a number'; Json = '{"StreamId":"0","ResourceCounts":[{"Id":"sub-a","Count":1,"Zip":5}]}'; Reason = 'success row' }
        @{ Case = 'success row is not an object'; Json = '{"StreamId":"0","ResourceCounts":["sub-a"],"Failed":[{"Id":"sub-a","Name":"Sub A","Reason":"r"}]}'; Reason = 'success row' }
        @{ Case = 'ResourceCounts is one object, not a list'; Json = '{"StreamId":"0","ResourceCounts":{"Id":"sub-a","Count":1}}'; Reason = 'ResourceCounts is not a list' }
        @{ Case = 'failed row has no Reason'; Json = '{"StreamId":"0","Failed":[{"Id":"sub-a","Name":"Sub A"}]}'; Reason = 'failed row' }
        @{ Case = 'failed row Reason is a number'; Json = '{"StreamId":"0","Failed":[{"Id":"sub-a","Name":"Sub A","Reason":5}]}'; Reason = 'failed row' }
        @{ Case = 'failed row has no Id'; Json = '{"StreamId":"0","ResourceCounts":[{"Id":"sub-a","Count":1}],"Failed":[{"Name":"Sub X","Reason":"r"}]}'; Reason = 'failed row' }
        @{ Case = 'Failed is text, not a list'; Json = '{"StreamId":"0","ResourceCounts":[{"Id":"sub-a","Count":1}],"Failed":"none"}'; Reason = 'Failed is not a list' }
        @{ Case = 'ConsumptionRecords is text'; Json = '{"StreamId":"0","ResourceCounts":[{"Id":"sub-a","Count":1}],"ConsumptionRecords":"abc"}'; Reason = 'ConsumptionRecords' }
        @{ Case = 'ConsumptionRecords is below 0'; Json = '{"StreamId":"0","ResourceCounts":[{"Id":"sub-a","Count":1}],"ConsumptionRecords":-1}'; Reason = 'ConsumptionRecords' }
        @{ Case = 'ConsumptionRecords is not a whole number'; Json = '{"StreamId":"0","ResourceCounts":[{"Id":"sub-a","Count":1}],"ConsumptionRecords":1.5}'; Reason = 'ConsumptionRecords' }
        @{ Case = 'ConsumptionFailedSubs is one object, not a list'; Json = '{"StreamId":"0","ResourceCounts":[{"Id":"sub-a","Count":1}],"ConsumptionFailedSubs":{"Id":"sub-a"}}'; Reason = 'ConsumptionFailedSubs is not a list' }
        @{ Case = 'MetricsFailedSubs is text, not a list'; Json = '{"StreamId":"0","ResourceCounts":[{"Id":"sub-a","Count":1}],"MetricsFailedSubs":"sub-a"}'; Reason = 'MetricsFailedSubs is not a list' }
        @{ Case = 'CollectorFailures is a number, not a list'; Json = '{"StreamId":"0","ResourceCounts":[{"Id":"sub-a","Count":1}],"CollectorFailures":3}'; Reason = 'CollectorFailures is not a list' }
        @{ Case = 'CollectorFailures row has no Id'; Json = '{"StreamId":"0","ResourceCounts":[{"Id":"sub-a","Count":1}],"CollectorFailures":[{"Module":"VM","Message":"m"}]}'; Reason = 'CollectorFailures row' }
        @{ Case = 'MetricsFailedSubs row Message is a list'; Json = '{"StreamId":"0","ResourceCounts":[{"Id":"sub-a","Count":1}],"MetricsFailedSubs":[{"Id":"sub-a","Message":["m"]}]}'; Reason = 'MetricsFailedSubs row' }
        @{ Case = 'ConsumptionFailedSubs row is text'; Json = '{"StreamId":"0","ResourceCounts":[{"Id":"sub-a","Count":1}],"ConsumptionFailedSubs":["sub-a"]}'; Reason = 'ConsumptionFailedSubs row' }
        @{ Case = 'Status is a number'; Json = '{"StreamId":"0","Status":1,"ResourceCounts":[{"Id":"sub-a","Count":1}]}'; Reason = 'Status is not text' }
        @{ Case = 'StreamId names another stream'; Json = '{"StreamId":"1","ResourceCounts":[{"Id":"sub-a","Count":1}]}'; Reason = 'names stream' }
        @{ Case = 'StreamId is missing'; Json = '{"ResourceCounts":[{"Id":"sub-a","Count":1}]}'; Reason = 'names stream' }
        @{ Case = 'rows miss a subscription the stream ran'; Json = '{"StreamId":"0","ResourceCounts":[],"Failed":[]}'; Reason = 'no row for 1 of the 1' }
        @{ Case = 'text is a list'; Json = '[]'; Reason = 'not a JSON object' }
        @{ Case = 'RunId names another run'; Json = '{"RunId":"99999999-2222-3333-4444-555555555555","StreamId":"0","ResourceCounts":[{"Id":"sub-a","Count":1}]}'; Reason = 'it is not from this run' }
        @{ Case = 'RunId is missing'; Json = '{"RunId":null,"StreamId":"0","ResourceCounts":[{"Id":"sub-a","Count":1}]}'; Reason = 'it is not from this run' }
        @{ Case = 'RunId is a number'; Json = '{"RunId":5,"StreamId":"0","ResourceCounts":[{"Id":"sub-a","Count":1}]}'; Reason = 'it is not from this run' }
    ) {
        $Read = Read-Case -Json $Json
        $Read.Accepted | Should -BeFalse
        $Read.Reason | Should -Match ([regex]::Escape($Reason))
    }

    It 'does not confirm a summary with no RunId, as an older worker or another tool writes it' {
        $Read = Resolve-StreamSummary -Summary ('{"StreamId":"0","ResourceCounts":[{"Id":"sub-a","Count":1}]}' | ConvertFrom-Json) -RunId $script:RunId -StreamId '0' -ExpectedIds @('sub-a')
        $Read.Accepted | Should -BeFalse
        $Read.Reason | Should -Be 'it is not from this run'
    }

    It 'never throws on a bad value' {
        { Read-Case -Json '{"StreamId":"0","ResourceCounts":[{"Id":"sub-a","Count":{"a":1},"Zip":{"b":2}}],"ConsumptionRecords":[1,2]}' } | Should -Not -Throw
    }
}

Describe 'Resume state messages whose error text holds braces' {
    # The error text goes in as a value, not into the format string, so
    # braces in it (a path, or the bad JSON) cannot break the message.
    It 'Save-CompletedSubscriptionIds warns and does not throw when the write fails under a folder named with braces' {
        Mock Write-Host -MockWith { }
        $Path = Join-Path $script:TestRoot 'gone-{folder}/state.json'
        { Save-CompletedSubscriptionIds -Path $Path -Tenant 't' -Ids @('a') -ErrorAction SilentlyContinue } | Should -Not -Throw
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { ([string]$Object) -like ('WARNING: Failed to persist resume state to {0}: *gone-{{folder}}*' -f $Path) }
    }

    It 'Get-CompletedSubscriptionIds starts fresh and does not throw on a resume state file whose bad JSON holds braces' {
        Mock Write-Host -MockWith { }
        $Path = Join-Path $script:TestRoot 'bad-braces.json'
        Set-Content -LiteralPath $Path -Value '{"TenantID": {x}' -Encoding utf8
        { $script:Ids = Get-CompletedSubscriptionIds -Path $Path -Tenant 't' } | Should -Not -Throw
        @($script:Ids).Count | Should -Be 0
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { ([string]$Object) -like ('Could not read resume state file ({0}); starting fresh. *' -f $Path) }
    }
}

Describe 'Save-CompletedSubscriptionIds keeps the old state when its write fails' {
    BeforeEach {
        $script:KeepDir = Join-Path $script:TestRoot ('keep_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:KeepDir -Force | Out-Null
        $script:KeepPath = Join-Path $script:KeepDir 'state.json'
        Save-CompletedSubscriptionIds -Path $script:KeepPath -Tenant 't' -Ids @('done-1') -FailedAttempts @([pscustomobject]@{ Id = 'failed-1'; Name = 'F'; LastFailedAt = '2026-01-01T00:00:00Z'; Reason = 'r'; Attempts = 1 })
        $script:KeepBefore = Get-Content -LiteralPath $script:KeepPath -Raw
    }

    It 'a write that stops part-way (a full disk) leaves the old state, warns, and leaks no error' {
        # The write leaves a cut temp file and a non-terminating error, as
        # Set-Content does when the disk fills.
        Mock Set-Content -MockWith {
            [System.IO.File]::WriteAllText([string]$PesterBoundParameters['Path'], '{"TenantID": "t", "Compl')
            Write-Error 'stand-in: no space left on the disk'
        }
        Mock Write-Host -MockWith { }
        $Out = @(Save-CompletedSubscriptionIds -Path $script:KeepPath -Tenant 't' -Ids @('done-1', 'done-2') 2>&1)
        @($Out | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }).Count | Should -Be 0
        Get-Content -LiteralPath $script:KeepPath -Raw | Should -Be $script:KeepBefore
        @(Get-CompletedSubscriptionIds -Path $script:KeepPath -Tenant 't') | Should -Be @('done-1')
        @(Get-FailedAttempts -Path $script:KeepPath -Tenant 't').Id | Should -Be @('failed-1')
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { ([string]$Object) -like '*WARNING: Failed to persist resume state to *no space left on the disk*' }
        Test-Path -LiteralPath "$script:KeepPath.tmp" | Should -BeFalse
    }

    It 'a temp path that cannot be written (a folder is there) leaves the old state, warns about the write, and leaks no error' {
        New-Item -ItemType Directory -Path "$script:KeepPath.tmp" -Force | Out-Null
        Mock Write-Host -MockWith { }
        $Out = @(Save-CompletedSubscriptionIds -Path $script:KeepPath -Tenant 't' -Ids @('done-1', 'done-2') 2>&1)
        @($Out | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }).Count | Should -Be 0
        Get-Content -LiteralPath $script:KeepPath -Raw | Should -Be $script:KeepBefore
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { ([string]$Object) -like ('WARNING: Failed to persist resume state to {0}: *' -f $script:KeepPath) }
    }
}

Describe 'A resume state warning that cannot be written' {
    # Both state writes run inside a subscription's try, after its success
    # row is added. When the inventory folder is gone the console or
    # transcript can be gone too, so the warning itself can fail to write;
    # that must not reach the subscription's catch and list it as failed.
    It 'Save-CompletedSubscriptionIds does not throw when its warning cannot be written' {
        Mock Write-Host -MockWith { throw 'stand-in: the console cannot be written' }
        $Path = Join-Path $script:TestRoot 'gone-sequential/state.json'
        { Save-CompletedSubscriptionIds -Path $Path -Tenant 't' -Ids @('a') } | Should -Not -Throw
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { ([string]$Object) -like 'WARNING: Failed to persist resume state to *' }
        Test-Path -LiteralPath "$Path.tmp" | Should -BeFalse
    }

    It 'Write-StreamState does not throw when its warning cannot be written' {
        # The worker's line prefix, which Write-Stream reads from its caller.
        Set-Variable -Name Tag -Value '[stream-0]'
        Mock Set-Content -MockWith { throw 'stand-in: the folder is gone' }
        Mock Write-Host -MockWith { throw 'stand-in: the console cannot be written' }
        $Path = Join-Path $script:TestRoot 'gone-stream/state.json'
        { Write-StreamState -Path $Path -Completed @('a') -FailedAttempts @() } | Should -Not -Throw
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { ([string]$Object) -like '`[stream-0`] WARNING: failed to persist stream state to *' }
    }

    It 'Write-StreamState warns and does not fail when its folder is gone' {
        # No Set-Content mock: the real write into a missing folder must
        # reach the catch, so the warning is printed and no error leaks out.
        Set-Variable -Name Tag -Value '[stream-0]'
        Mock Write-Host -MockWith { }
        $Path = Join-Path $script:TestRoot 'gone-stream-real/state.json'
        { $script:StreamWriteOut = @(Write-StreamState -Path $Path -Completed @('a') -FailedAttempts @() 2>&1) } | Should -Not -Throw
        @($script:StreamWriteOut | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }).Count | Should -Be 0
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { ([string]$Object) -like '`[stream-0`] WARNING: failed to persist stream state to *' }
        Test-Path -LiteralPath $Path | Should -BeFalse
    }

    It 'Read-StreamState starts fresh and does not throw when its warning cannot be written' {
        # It runs at stream start; a warning that cannot be written must not
        # end the stream before its loop.
        Set-Variable -Name Tag -Value '[stream-0]'
        Mock Write-Host -MockWith { throw 'stand-in: the console cannot be written' }
        $Path = Join-Path $script:TestRoot 'bad-stream-state.json'
        Set-Content -LiteralPath $Path -Value '{"Completed": [' -Encoding utf8
        { $script:StreamRead = Read-StreamState -Path $Path } | Should -Not -Throw
        @($script:StreamRead.Completed).Count | Should -Be 0
        @($script:StreamRead.Failed).Count | Should -Be 0
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { ([string]$Object) -like '`[stream-0`] WARNING: could not read stream state at *' }
    }
}

Describe 'Add-FailedAttempt / Remove-FailedAttempt single-element handling' {
    # Regression: -Existing was typed [System.Collections.IEnumerable], but when
    # the list holds exactly one prior failure PowerShell collapses it to a lone
    # PSCustomObject at the call site (e.g. $FailedAttempts = Add-FailedAttempt ...).
    # A PSCustomObject is not IEnumerable, so the second failure threw:
    # "Cannot process argument transformation on parameter 'Existing'".
    # The parameter is now [object] and normalized with @(...) internally.

    It 'Add-FailedAttempt accepts a single (scalar) prior entry without throwing' {
        $First = Add-FailedAttempt -Existing @() -Id 'sub-1' -Name 'Sub One' -Reason 'first failure'
        # $First is now a single PSCustomObject (one-element result collapsed).
        $First -is [System.Collections.IEnumerable] -and -not ($First -is [string]) | Should -BeFalse -Because 'a one-element result collapses to a scalar PSCustomObject - the exact shape that triggered the bug'

        { Add-FailedAttempt -Existing $First -Id 'sub-2' -Name 'Sub Two' -Reason 'second failure' } | Should -Not -Throw

        $Second = Add-FailedAttempt -Existing $First -Id 'sub-2' -Name 'Sub Two' -Reason 'second failure'
        @($Second).Count | Should -Be 2 -Because 'both failures must be retained'
    }

    It 'Add-FailedAttempt increments Attempts when the same sub fails again (scalar input)' {
        $First = Add-FailedAttempt -Existing @() -Id 'sub-1' -Name 'Sub One' -Reason 'first'
        $Second = Add-FailedAttempt -Existing $First -Id 'sub-1' -Name 'Sub One' -Reason 'again'
        @($Second).Count | Should -Be 1 -Because 'the same sub Id must not be duplicated'
        @($Second)[0].Attempts | Should -Be 2
    }

    It 'Remove-FailedAttempt accepts a single (scalar) entry without throwing' {
        $Only = Add-FailedAttempt -Existing @() -Id 'sub-1' -Name 'Sub One' -Reason 'failure'
        { Remove-FailedAttempt -Existing $Only -Id 'sub-1' } | Should -Not -Throw
        @(Remove-FailedAttempt -Existing $Only -Id 'sub-1').Count | Should -Be 0 -Because 'removing the only entry yields an empty list'
    }

    It 'Add-FailedAttempt handles a null existing list' {
        { Add-FailedAttempt -Existing $null -Id 'sub-1' -Name 'Sub One' -Reason 'failure' } | Should -Not -Throw
        @(Add-FailedAttempt -Existing $null -Id 'sub-1' -Name 'Sub One' -Reason 'failure').Count | Should -Be 1
    }
}

Describe 'Merge-FailedAttempts single-element handling' {
    # Same bug class as Add-/Remove-FailedAttempt: params were typed
    # [System.Collections.IEnumerable]. A single existing failure and/or a single
    # stream failure arrive as scalar PSCustomObjects (not IEnumerable). Params
    # are now [object]; every use is @()-wrapped internally.

    It 'Accepts single (scalar) existing and stream failures without throwing' {
        $ExistingScalar = [pscustomobject]@{ Id = 'sub-1'; Name = 'Sub One'; LastFailedAt = '2026-01-01T00:00:00Z'; Reason = 'old'; Attempts = 1 }
        $StreamScalar = [pscustomobject]@{ Id = 'sub-2'; Name = 'Sub Two'; LastFailedAt = '2026-06-01T00:00:00Z'; Reason = 'new'; Attempts = 1 }

        { Merge-FailedAttempts -ExistingFailedAttempts $ExistingScalar -StreamFailedAttempts $StreamScalar -CompletedIds @() } | Should -Not -Throw

        $Result = Merge-FailedAttempts -ExistingFailedAttempts $ExistingScalar -StreamFailedAttempts $StreamScalar -CompletedIds @()
        @($Result).Count | Should -Be 2 -Because 'both distinct failures must be retained'
    }

    It 'Accepts a scalar CompletedId and prunes the matching failure (no stream failures)' {
        $ExistingScalar = [pscustomobject]@{ Id = 'sub-3'; Name = 'Sub Three'; LastFailedAt = '2026-01-01T00:00:00Z'; Reason = 'x'; Attempts = 1 }
        { Merge-FailedAttempts -ExistingFailedAttempts $ExistingScalar -StreamFailedAttempts @() -CompletedIds 'sub-3' } | Should -Not -Throw
        @(Merge-FailedAttempts -ExistingFailedAttempts $ExistingScalar -StreamFailedAttempts @() -CompletedIds 'sub-3').Count | Should -Be 0 -Because 'the completed sub must be pruned'
    }
}

Describe 'Get-ConsumptionAccessOutcome classification' {
    # Drives the up-front consumption (billing) access gate in Run-AllSubscriptions.ps1.
    # 'Denied' -> hard fail (consumption was requested but the identity lacks access).
    # 'Unavailable' -> transient/token class; NOT a hard failure (warn + continue).
    # 'Ok' -> access confirmed.

    It 'Returns Ok for a null/empty message (successful probe)' {
        Get-ConsumptionAccessOutcome -ErrorMessage $null | Should -Be 'Ok'
        Get-ConsumptionAccessOutcome -ErrorMessage ''   | Should -Be 'Ok'
    }

    It 'Classifies authorization / RBAC denials as Denied' {
        Get-ConsumptionAccessOutcome -ErrorMessage "The client 'x' does not have authorization to perform action 'Microsoft.Commerce/UsageAggregates/read'" | Should -Be 'Denied'
        Get-ConsumptionAccessOutcome -ErrorMessage 'AuthorizationFailed' | Should -Be 'Denied'
        Get-ConsumptionAccessOutcome -ErrorMessage 'Response status code 403 (Forbidden)' | Should -Be 'Denied'
        Get-ConsumptionAccessOutcome -ErrorMessage 'The user is not authorized to access this resource' | Should -Be 'Denied'
        Get-ConsumptionAccessOutcome -ErrorMessage 'Access is denied' | Should -Be 'Denied'
    }

    It 'Classifies transient / token / throttle errors as Unavailable (not a hard fail)' {
        Get-ConsumptionAccessOutcome -ErrorMessage 'Unable to acquire token for tenant; user interaction is required' | Should -Be 'Unavailable'
        Get-ConsumptionAccessOutcome -ErrorMessage 'Response status code 429 (TooManyRequests)' | Should -Be 'Unavailable'
        Get-ConsumptionAccessOutcome -ErrorMessage 'A task was canceled (timeout)' | Should -Be 'Unavailable'
        Get-ConsumptionAccessOutcome -ErrorMessage 'The remote name could not be resolved' | Should -Be 'Unavailable'
    }
}

Describe 'Interrupted-parallel-run stream-state fold-in (F2)' {
    # Reproduces the exact startup fold-in Run-AllSubscriptions.ps1 performs when
    # -Resume/-ResumeFailedOnly runs after a PARALLEL run was killed before its
    # end-of-run merge: discover per-stream files, read their Completed /
    # FailedAttempts (the same keys Write-StreamState persists), union the
    # completed ids, and reconcile failures via Merge-FailedAttempts. Guards the
    # "-ResumeFailedOnly wrongly reports Nothing to retry" bug at the helper level
    # (the wrapper body itself needs a live Azure session to run end to end).
    BeforeEach {
        $script:F2Dir = Join-Path $script:TestRoot ("f2_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:F2Dir -Force | Out-Null
    }

    AfterEach {
        if (Test-Path $script:F2Dir) { Remove-Item -Path $script:F2Dir -Recurse -Force }
    }

    It 'recovers a failure that lives only in an unmerged per-stream file' {
        $Tenant = 'tenant-f2a'
        @{ Tenant = $Tenant; StreamId = 0; Completed = @('sub-ok'); FailedAttempts = @() } |
            ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $script:F2Dir ".resume-state-$Tenant-stream-0.json")
        @{ Tenant = $Tenant; StreamId = 1; Completed = @(); FailedAttempts = @(
                [pscustomobject]@{ Id = 'sub-fail'; Name = 'Sub Fail'; LastFailedAt = '2026-06-01T00:00:00Z'; Reason = 'throttled'; Attempts = 1 }
            )
        } | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $script:F2Dir ".resume-state-$Tenant-stream-1.json")

        $StrandedCompleted = @()
        $StrandedFailed = @()
        foreach ($StreamFile in Get-StreamResumeStateFiles -InventoryRoot $script:F2Dir -Tenant $Tenant)
        {
            $Obj = Get-Content -Path $StreamFile.FullName -Raw | ConvertFrom-Json
            if ($null -ne $Obj.Completed) { $StrandedCompleted += @($Obj.Completed) }
            if ($null -ne $Obj.FailedAttempts) { $StrandedFailed += @($Obj.FailedAttempts) }
        }
        $CompletedIds = @($StrandedCompleted | Sort-Object -Unique)
        $Failed = Merge-FailedAttempts -ExistingFailedAttempts @() -StreamFailedAttempts $StrandedFailed -CompletedIds $CompletedIds

        @($Failed).Count | Should -Be 1 -Because 'the failure stranded in the per-stream file must be recovered, not reported as Nothing to retry'
        $Failed[0].Id | Should -Be 'sub-fail'
        $CompletedIds | Should -Contain 'sub-ok' -Because 'completed ids from a per-stream file are folded in too'
    }

    It 'prunes a stranded failure when the same sub completed in another stream' {
        $Tenant = 'tenant-f2b'
        @{ Tenant = $Tenant; StreamId = 0; Completed = @('sub-x'); FailedAttempts = @() } |
            ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $script:F2Dir ".resume-state-$Tenant-stream-0.json")
        @{ Tenant = $Tenant; StreamId = 1; Completed = @(); FailedAttempts = @(
                [pscustomobject]@{ Id = 'sub-x'; Name = 'Sub X'; LastFailedAt = '2026-05-01T00:00:00Z'; Reason = 'transient'; Attempts = 1 }
            )
        } | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $script:F2Dir ".resume-state-$Tenant-stream-1.json")

        $StrandedCompleted = @()
        $StrandedFailed = @()
        foreach ($StreamFile in Get-StreamResumeStateFiles -InventoryRoot $script:F2Dir -Tenant $Tenant)
        {
            $Obj = Get-Content -Path $StreamFile.FullName -Raw | ConvertFrom-Json
            if ($null -ne $Obj.Completed) { $StrandedCompleted += @($Obj.Completed) }
            if ($null -ne $Obj.FailedAttempts) { $StrandedFailed += @($Obj.FailedAttempts) }
        }
        $CompletedIds = @($StrandedCompleted | Sort-Object -Unique)
        $Failed = Merge-FailedAttempts -ExistingFailedAttempts @() -StreamFailedAttempts $StrandedFailed -CompletedIds $CompletedIds

        @($Failed).Count | Should -Be 0 -Because 'a sub that completed in one stream must not be retried just because another stream logged an earlier failure'
    }
}

Describe 'Resolve-AccessPreflight (up-front access gate decision)' {
    # Pure decision function behind the wrapper's up-front access gate. Given the
    # per-sub probe results (State in Empty/NoAccess/Unknown), it decides whether
    # the run must STOP (default) or may proceed skipping the inaccessible subs
    # (-AllowPartialAccess). 'Empty' means the identity CAN read the sub.
    It 'does not block when every subscription is readable (all Empty)' {
        $Probed = @(
            [pscustomobject]@{ Id = 's1'; Name = 'One'; State = 'Empty' }
            [pscustomobject]@{ Id = 's2'; Name = 'Two'; State = 'Empty' }
        )
        $D = Resolve-AccessPreflight -Probed $Probed
        $D.ShouldBlock | Should -BeFalse
        @($D.Inaccessible).Count | Should -Be 0
    }

    It 'blocks by default when any subscription is NoAccess' {
        $Probed = @(
            [pscustomobject]@{ Id = 's1'; Name = 'One'; State = 'Empty' }
            [pscustomobject]@{ Id = 's2'; Name = 'Two'; State = 'NoAccess' }
        )
        $D = Resolve-AccessPreflight -Probed $Probed
        $D.ShouldBlock | Should -BeTrue -Because 'the default gate must stop the run when the identity cannot read a sub'
        @($D.Inaccessible).Count | Should -Be 1
        $D.InaccessibleIds | Should -Contain 's2'
    }

    It 'treats a persistent Unknown as inaccessible (never silently skipped)' {
        $Probed = @([pscustomobject]@{ Id = 's1'; Name = 'One'; State = 'Unknown' })
        $D = Resolve-AccessPreflight -Probed $Probed
        $D.ShouldBlock | Should -BeTrue
        $D.InaccessibleIds | Should -Contain 's1'
    }

    It 'does NOT block when -AllowPartialAccess is set, but still reports the inaccessible subs to skip' {
        $Probed = @(
            [pscustomobject]@{ Id = 's1'; Name = 'One'; State = 'Empty' }
            [pscustomobject]@{ Id = 's2'; Name = 'Two'; State = 'NoAccess' }
            [pscustomobject]@{ Id = 's3'; Name = 'Three'; State = 'Unknown' }
        )
        $D = Resolve-AccessPreflight -Probed $Probed -AllowPartialAccess
        $D.ShouldBlock | Should -BeFalse -Because '-AllowPartialAccess lets the run proceed with the accessible subs'
        @($D.Inaccessible).Count | Should -Be 2
        $D.InaccessibleIds | Should -Contain 's2'
        $D.InaccessibleIds | Should -Contain 's3'
    }

    It 'returns a clean no-block result for an empty probe set' {
        $D = Resolve-AccessPreflight -Probed @()
        $D.ShouldBlock | Should -BeFalse
        @($D.Inaccessible).Count | Should -Be 0
        @($D.InaccessibleIds).Count | Should -Be 0
    }
}

Describe 'Get-RunSummaryLogContent run-level shareable log' {

    BeforeAll {
        # Representative health collections carrying REAL-looking names/ids/messages,
        # so the obfuscated-mode leak guard is exercised against concrete strings.
        $script:Failed = @([pscustomobject]@{ Name = 'Contoso-Prod-Sub'; Id = '11111111-1111-1111-1111-111111111111' })
        $script:NoAccess = @([pscustomobject]@{ Name = 'Fabrikam-Locked'; Id = '22222222-2222-2222-2222-222222222222' })
        $script:CollectorFails = @([pscustomobject]@{ Id = '33333333-3333-3333-3333-333333333333'; Module = 'StreamAnalytics'; Message = 'threw on Contoso-Prod-Sub resource' })
        $script:MetricsSkips = @([pscustomobject]@{ Name = 'Fabrikam-Locked'; Id = '22222222-2222-2222-2222-222222222222'; Message = 'no usable token' })
    }

    It 'obfuscated run emits counts only - no names, ids, or raw messages' {
        $Lines = Get-RunSummaryLogContent -Obfuscated `
            -Visible 5 -Excluded 1 -Eligible 4 -Processed 3 -Skipped 0 `
            -FailedSubscriptions $script:Failed -EmptyNoAccess $script:NoAccess `
            -CollectorFailures $script:CollectorFails -MetricsFailedSubs $script:MetricsSkips
        $Text = ($Lines -join "`n")

        # No identifiers of any kind leak into an obfuscated bundle.
        $Text | Should -Not -Match 'Contoso'
        $Text | Should -Not -Match 'Fabrikam'
        $Text | Should -Not -Match 'StreamAnalytics'
        $Text | Should -Not -Match '11111111-1111-1111-1111-111111111111'
        $Text | Should -Not -Match '22222222-2222-2222-2222-222222222222'
        $Text | Should -Not -Match '33333333-3333-3333-3333-333333333333'
        $Text | Should -Not -Match 'no usable token'
        # But the counts ARE present.
        $Text | Should -Match 'Failed subscriptions\s+:\s+1'
        $Text | Should -Match 'Collector failures\s+:\s+1'
        $Text | Should -Match 'Metrics auth-skipped subs\s+:\s+1'
    }

    It 'non-obfuscated run includes per-subscription detail' {
        $Lines = Get-RunSummaryLogContent `
            -Visible 5 -Excluded 1 -Eligible 4 -Processed 3 -Skipped 0 `
            -FailedSubscriptions $script:Failed -EmptyNoAccess $script:NoAccess `
            -CollectorFailures $script:CollectorFails -MetricsFailedSubs $script:MetricsSkips
        $Text = ($Lines -join "`n")

        $Text | Should -Match 'Contoso-Prod-Sub'
        $Text | Should -Match 'Fabrikam-Locked'
        $Text | Should -Match 'StreamAnalytics'
        $Text | Should -Match 'no usable token'
    }

    It 'non-obfuscated run prints a failed subscription given as text as given, and one given as an object by name and id' {
        # The wrapper passes text for a stream it could not read and objects
        # with Name and Id for a subscription that failed.
        $Lines = Get-RunSummaryLogContent `
            -Visible 3 -Excluded 0 -Eligible 3 -Processed 3 -Skipped 0 `
            -FailedSubscriptions @([pscustomobject]@{ Name = 'Contoso-Prod-Sub'; Id = '11111111-1111-1111-1111-111111111111' }, 'stream-0 (corrupt summary)')
        $Detail = @($Lines | Where-Object { $_ -like '  - *' })
        $Detail | Should -Be @('  - Contoso-Prod-Sub (11111111-1111-1111-1111-111111111111)', '  - stream-0 (corrupt summary)')
    }

    It 'obfuscated run prints no failed subscription given as text' {
        $Text = (Get-RunSummaryLogContent -Obfuscated -Visible 1 -Excluded 0 -Eligible 1 -Processed 1 -Skipped 0 `
                -FailedSubscriptions @('Contoso-Prod-Sub (stream-0: boom)')) -join "`n"
        $Text | Should -Not -Match 'Contoso'
        $Text | Should -Match 'Failed subscriptions\s+:\s+1'
    }

    It 'drops TenantID / SubscriptionID / InventoryRoot from the parameter list' {
        $Params = @{
            TenantID        = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
            SubscriptionID  = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
            InventoryRoot   = '/home/someone/InventoryReports'
            SkipConsumption = [switch]$true
            ParallelStreams = 4
        }
        $Text = (Get-RunSummaryLogContent -InvocationParameters $Params -Obfuscated) -join "`n"

        $Text | Should -Not -Match 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        $Text | Should -Not -Match 'bbbbbbbb-bbbb'
        $Text | Should -Not -Match '/home/someone'
        $Text | Should -Match '-SkipConsumption'
        # Allowlisted tuning knob keeps its value even under obfuscation.
        $Text | Should -Match '-ParallelStreams 4'
    }

    It 'omits a non-allowlisted valued parameter value under obfuscation but keeps it otherwise' {
        $Params = @{ SomeFutureValuedParam = 'secret-value-123' }

        $Obf = (Get-RunSummaryLogContent -InvocationParameters $Params -Obfuscated) -join "`n"
        $Obf | Should -Not -Match 'secret-value-123'
        $Obf | Should -Match '-SomeFutureValuedParam <value omitted>'

        $Clear = (Get-RunSummaryLogContent -InvocationParameters $Params) -join "`n"
        $Clear | Should -Match '-SomeFutureValuedParam secret-value-123'
    }

    It 'renders a duration when start/end are supplied' {
        $Start = [datetime]'2026-01-01T00:00:00'
        $End = $Start.AddSeconds(125)
        $Text = (Get-RunSummaryLogContent -StartTime $Start -EndTime $End) -join "`n"
        $Text | Should -Match 'Total duration  : 2m 05s'
    }

    It 'renders the host / parallelism section in both modes when values are supplied' {
        foreach ($Obf in @($true, $false))
        {
            $Text = (Get-RunSummaryLogContent -Obfuscated:$Obf `
                    -HostVCpu 8 -HostRamGB 32 `
                    -Streams 4 -StreamsSource 'auto' `
                    -Concurrency 16 -ConcurrencySource 'explicit') -join "`n"

            $Text | Should -Match 'Host / parallelism:'
            $Text | Should -Match 'Host vCPU\s+:\s+8'
            $Text | Should -Match 'Host RAM \(GB\)\s+:\s+32'
            $Text | Should -Match 'Parallel streams\s+:\s+4 \(auto\)'
            $Text | Should -Match 'Concurrency limit\s+:\s+16 \(explicit\)'
        }
    }

    It 'omits the host / parallelism section entirely when no host values are supplied' {
        $Text = (Get-RunSummaryLogContent -Visible 1 -Eligible 1 -Processed 1) -join "`n"
        $Text | Should -Not -Match 'Host / parallelism:'
    }

    It 'names the exit code and what exit code 2 hides, in both modes' {
        $ExitLines = @(Get-WrapperExitCodeSummary -AuthSkipped $false -CollectorsFailed $true -SubscriptionsFailed $true -ReportMade $true)
        foreach ($Obf in @($true, $false))
        {
            $Lines = @(Get-RunSummaryLogContent -Obfuscated:$Obf -Visible 2 -Eligible 2 -Processed 2 -ExitCodeLines $ExitLines)
            $At = [array]::IndexOf($Lines, 'Exit code:')
            $At | Should -BeGreaterThan -1
            $Lines[$At + 1] | Should -BeExactly ('  ' + $ExitLines[0])
            $Lines[$At + 2] | Should -BeExactly ('  ' + $ExitLines[1])
        }
    }

    It 'handles null/empty health collections without throwing (standalone-run safety)' {
        { Get-RunSummaryLogContent -Visible 0 -Eligible 0 -Processed 0 `
                -FailedSubscriptions $null -CollectorFailures $null `
                -MetricsFailedSubs $null -ConsumptionFailedSubs $null } | Should -Not -Throw
    }
}

Describe 'Consumption failures: one rule for the count, the list and the sign-in skips' {

    BeforeAll {
        # Contoso-Billing twice (two of its pages failed), a twin with the same
        # name, and the '(auth)' sign-in rows of two subscriptions (one twice,
        # as an older stream left it) and of a direct run with no
        # SubscriptionId.
        $script:ConsumptionRows = @(
            [pscustomobject]@{ Name = 'Contoso-Billing'; Id = '44444444-4444-4444-4444-444444444444'; Message = 'page 2 failed' }
            [pscustomobject]@{ Name = 'Contoso-Billing'; Id = '44444444-4444-4444-4444-444444444444'; Message = 'page 3 failed' }
            [pscustomobject]@{ Name = 'Contoso-Billing'; Id = '55555555-5555-5555-5555-555555555555'; Message = 'page 2 failed' }
            [pscustomobject]@{ Name = '(all subscriptions)'; Id = '(auth)'; Message = 'skipped'; SubscriptionId = '66666666-6666-6666-6666-666666666666' }
            [pscustomobject]@{ Name = '(all subscriptions)'; Id = '(auth)'; Message = 'skipped'; SubscriptionId = '66666666-6666-6666-6666-666666666666' }
            [pscustomobject]@{ Name = '(all subscriptions)'; Id = '(auth)'; Message = 'skipped'; SubscriptionId = '77777777-7777-7777-7777-777777777777' }
        )
    }

    It 'Get-ConsumptionFailureView names each real subscription once by name and id and counts the sign-in skips per subscription' {
        $View = Get-ConsumptionFailureView -ConsumptionFailedSubs $script:ConsumptionRows
        @($View.Subscriptions | ForEach-Object { $_.Id }) | Should -Be @('44444444-4444-4444-4444-444444444444', '55555555-5555-5555-5555-555555555555')
        $View.SignInSkipped | Should -Be 2
    }

    It 'Get-ConsumptionFailureView counts a sign-in row with no SubscriptionId once, and an empty list as none' {
        $Direct = @([pscustomobject]@{ Name = '(all subscriptions)'; Id = '(auth)'; Message = 'skipped' })
        $View = Get-ConsumptionFailureView -ConsumptionFailedSubs $Direct
        @($View.Subscriptions).Count | Should -Be 0
        $View.SignInSkipped | Should -Be 1
        (Get-ConsumptionFailureView -ConsumptionFailedSubs $null).SignInSkipped | Should -Be 0
    }

    It 'RunSummary.log counts by the same rule, and <Case>' -ForEach @(
        @{ Case = 'without -Obfuscated lists each real subscription once and no sign-in row'; Obfuscated = $false }
        @{ Case = 'with -Obfuscated names none'; Obfuscated = $true }
    ) {
        $Lines = Get-RunSummaryLogContent -Visible 4 -Eligible 4 -Processed 4 -ConsumptionFailedSubs $script:ConsumptionRows -Obfuscated:$Obfuscated
        $Text = $Lines -join "`n"
        $Text | Should -Match 'Consumption failed subs\s+: 2(\r?\n|$)'
        $Text | Should -Match 'Consumption sign-in skipped\s+: 2 subscription\(s\)'
        $Text | Should -Not -Match '66666666|77777777' -Because 'the sign-in rows are counted, not named'
        if ($Obfuscated)
        {
            $Text | Should -Not -Match 'Contoso|44444444|55555555'
        }
        else
        {
            @($Lines | Where-Object { $_ -like '  - Contoso-Billing (*' }).Count | Should -Be 2
            $Text | Should -Not -Match '\(auth\)'
        }
    }
}
