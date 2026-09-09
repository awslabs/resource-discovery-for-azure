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

    # Test-ReportArchiveUsable lives in Common.Functions.ps1 (the cross-cutting
    # helper file BOTH entry points dot-source), not in the wrapper's own functions
    # file, because ResourceInventory.ps1 has to apply the identical standard to its
    # own archive. Dot-source it here for the same reason.
    $script:CommonFunctionsPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Functions/Common.Functions.ps1'
    if (-not (Test-Path $script:CommonFunctionsPath))
    {
        throw "Could not find shared common functions file at $script:CommonFunctionsPath"
    }
    . $script:CommonFunctionsPath

    # Guard: the functions under test must be defined by the shared file. If a
    # future change renames or removes one, fail loudly here rather than with a
    # confusing "command not found" mid-test.
    $TargetFunctions = @('Get-StreamResumeStateFiles', 'Merge-FailedAttempts', 'Get-WrapperExitCode', 'Add-FailedAttempt', 'Remove-FailedAttempt', 'Get-ConsumptionAccessOutcome', 'Resolve-AccessPreflight', 'Test-SubscriptionAccessAll', 'Expand-ServiceFilter', 'Test-BackgroundJobSupport', 'Save-CompletedSubscriptionIds', 'Get-FailedAttempts', 'Test-ReportArchiveUsable',
        'Split-BlobContainerUri', 'Get-CompletedSubscriptionIds', 'Get-StartSnapshot', 'Resolve-ResumeState', 'Get-ResumeStateObject')
    foreach ($Fn in $TargetFunctions)
    {
        if (-not (Get-Command $Fn -CommandType Function -ErrorAction SilentlyContinue))
        {
            throw "Expected function '$Fn' to be defined by $script:FunctionsPath or $script:CommonFunctionsPath, but it was not. Has it been renamed or removed?"
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

    It 'handles null/empty health collections without throwing (standalone-run safety)' {
        { Get-RunSummaryLogContent -Visible 0 -Eligible 0 -Processed 0 `
                -FailedSubscriptions $null -CollectorFailures $null `
                -MetricsFailedSubs $null -ConsumptionFailedSubs $null } | Should -Not -Throw
    }
}

Describe 'Expand-ServiceFilter' {
    It 'returns an empty array for $null / no input' {
        @(Expand-ServiceFilter -Service $null).Count | Should -Be 0
        @(Expand-ServiceFilter).Count | Should -Be 0
    }

    It 'passes a clean single-element array through unchanged' {
        $Result = @(Expand-ServiceFilter -Service @('VirtualMachines'))
        $Result.Count | Should -Be 1
        $Result[0] | Should -Be 'VirtualMachines'
    }

    It 'passes a clean multi-element array through unchanged' {
        $Result = @(Expand-ServiceFilter -Service @('VirtualMachines', 'Streamanalytics'))
        $Result | Should -Be @('VirtualMachines', 'Streamanalytics')
    }

    It 'splits a single comma-joined token (the pwsh -File binding case) into elements' {
        # `pwsh -File wrapper.ps1 -Service a,b` binds @('VirtualMachines,Streamanalytics')
        # as ONE element; the helper must split it so both invocation forms match.
        $Result = @(Expand-ServiceFilter -Service @('VirtualMachines,Streamanalytics'))
        $Result | Should -Be @('VirtualMachines', 'Streamanalytics')
    }

    It 'trims surrounding whitespace around comma-separated names' {
        $Result = @(Expand-ServiceFilter -Service @('VirtualMachines, Streamanalytics , AKS'))
        $Result | Should -Be @('VirtualMachines', 'Streamanalytics', 'AKS')
    }

    It 'drops empty tokens produced by stray/trailing commas' {
        $Result = @(Expand-ServiceFilter -Service @('VirtualMachines,,', '', 'AKS'))
        $Result | Should -Be @('VirtualMachines', 'AKS')
    }

    It 'de-duplicates repeated names' {
        $Result = @(Expand-ServiceFilter -Service @('VirtualMachines', 'VirtualMachines,AKS'))
        $Result | Should -Be @('VirtualMachines', 'AKS')
    }
}

Describe 'Test-BackgroundJobSupport' {
    # Backs the wrapper's "fall back to sequential when Start-Job is unavailable"
    # guard. The real trigger it defends against - Start-Job throwing
    # synchronously on a Windows host under a WDAC/AppLocker system-wide
    # ConstrainedLanguage policy - is Windows-only and cannot be reproduced on
    # the Linux/macOS runner (which takes the early -not $IsWindows return). So
    # these tests cover the platform-agnostic contract only: it returns a real
    # boolean, reports $true when jobs ARE usable in the current session, and
    # never leaks its probe job. The Windows failure path is exercised
    # out-of-band per windows-cross-os-testing.md.
    It 'returns a boolean' {
        Test-BackgroundJobSupport | Should -BeOfType [bool]
    }

    It 'reports $true in a session where jobs are usable (early-return path on non-Windows)' {
        # On the non-Windows CI runner this exercises the early -not $IsWindows
        # return; on unrestricted Windows it exercises a successful probe. Either
        # way the helper must not report a false negative. The Windows LOCKED-DOWN
        # ($false) path is covered out-of-band per windows-cross-os-testing.md.
        Test-BackgroundJobSupport | Should -BeTrue
    }

    It 'leaves no probe job behind in the caller''s job table' {
        # Invariant on both platforms: non-Windows never creates a probe job
        # (early return, delta 0); Windows creates one and removes it in the
        # finally block (delta 0). Either way the caller's job table is untouched.
        $Before = @(Get-Job).Count
        $null = Test-BackgroundJobSupport
        @(Get-Job).Count | Should -Be $Before -Because 'the probe job must never pollute the caller''s job table'
    }
}

Describe 'FailedAttempts null-serialization regression' {
    BeforeEach {
        $script:StatePath = Join-Path $script:TestRoot ((([guid]::NewGuid()).ToString('N')) + '.json')
    }
    AfterEach {
        if (Test-Path $script:StatePath) { Remove-Item -Path $script:StatePath -Force }
    }

    # Each test reads the FailedAttempts token back off the freshly-written state
    # file inline (a helper defined in the Describe body is not in scope inside
    # It under Pester v5). The bug serialised an EMPTY list as `[ null ]` (Count
    # 1, one null element) instead of `[]` (Count 0).

    It 'serialises an explicitly empty FailedAttempts list as [] (no null element)' {
        Save-CompletedSubscriptionIds -Path $script:StatePath -Tenant 't' -Ids @('s1') -FailedAttempts @()
        $Parsed = Get-Content -Path $script:StatePath -Raw | ConvertFrom-Json
        @($Parsed.FailedAttempts).Count | Should -Be 0
        @($Parsed.FailedAttempts | Where-Object { $null -eq $_ }).Count | Should -Be 0
    }

    It 'serialises a $null FailedAttempts (empty-array collapse) as [] (no null element)' {
        # This is the exact clean-run shape: `$FailedAttempts = Merge-FailedAttempts ...`
        # returns an empty array that PowerShell collapses to $null on assignment.
        Save-CompletedSubscriptionIds -Path $script:StatePath -Tenant 't' -Ids @('s1') -FailedAttempts $null
        $Parsed = Get-Content -Path $script:StatePath -Raw | ConvertFrom-Json
        @($Parsed.FailedAttempts).Count | Should -Be 0
        @($Parsed.FailedAttempts | Where-Object { $null -eq $_ }).Count | Should -Be 0
    }

    It 'a clean-run Merge-FailedAttempts result round-trips through Save as [] (not [ null ])' {
        # Drive the REAL root-cause path end to end: an all-clean merge (no stream
        # failures) yields an empty array that collapses to $null at the call
        # site, which the bug then wrote as `[ null ]`.
        $Merged = Merge-FailedAttempts -ExistingFailedAttempts @() -StreamFailedAttempts @() -CompletedIds @('s1')
        Save-CompletedSubscriptionIds -Path $script:StatePath -Tenant 't' -Ids @('s1') -FailedAttempts $Merged
        $Parsed = Get-Content -Path $script:StatePath -Raw | ConvertFrom-Json
        @($Parsed.FailedAttempts).Count | Should -Be 0
        @($Parsed.FailedAttempts | Where-Object { $null -eq $_ }).Count | Should -Be 0
    }

    It 'preserves a real FailedAttempts entry (no over-stripping)' {
        $Entry = [pscustomobject]@{ Id = 's2'; Name = 'Sub Two'; LastFailedAt = (Get-Date).ToString('o'); Reason = 'boom'; Attempts = 1 }
        Save-CompletedSubscriptionIds -Path $script:StatePath -Tenant 't' -Ids @('s1') -FailedAttempts @($Entry)
        $Parsed = Get-Content -Path $script:StatePath -Raw | ConvertFrom-Json
        @($Parsed.FailedAttempts).Count | Should -Be 1
        @($Parsed.FailedAttempts)[0].Id | Should -Be 's2'
    }

    It 'Get-FailedAttempts self-heals a legacy [ null ] file to an empty list' {
        # Hand-craft the exact bad shape a pre-fix version wrote.
        $Bad = [ordered]@{
            TenantID                 = 't'
            CompletedSubscriptionIds = @('s1')
            FailedAttempts           = @($null)
            LastUpdated              = (Get-Date).ToString('o')
        }
        ($Bad | ConvertTo-Json -Depth 5) | Set-Content -Path $script:StatePath -Encoding utf8
        $Read = @(Get-FailedAttempts -Path $script:StatePath -Tenant 't')
        $Read.Count | Should -Be 0
        @($Read | Where-Object { $null -eq $_ }).Count | Should -Be 0
    }
}

# ---------------------------------------------------------------------------
# Read-once projection of the resume state
#
# Get-CompletedSubscriptionIds, Get-FailedAttempts and Get-StartSnapshot are
# three thin projections over ONE resume-state object, and each reads that state
# for itself. A caller wanting two or three of them would therefore download the
# same state blob two or three times, one network round trip apiece. The -State
# parameter lets a caller read once and project many.
#
# Honest scope: no SHIPPED caller does that today. All three readers have call
# sites only under Tests/ - Run-AllSubscriptions.ps1 reads once via
# Get-ResumeStateObject and projects inline, which is the same read-once discipline
# expressed by hand. So these tests pin an API contract, not a live hot path.
#
# The bypass is proven two ways. WITHOUT a mock, by pointing -Path at a file that
# does not exist: if a reader consulted the path it would see no state and return
# empty, so a correct projection can only have come from -State. That covers the
# LOCAL-file path only. The mock-based Its then pin the read count at exactly zero
# and carry a positive control proving the mock is reachable, which is what covers
# the blob round trip the -Path trick cannot reach.
# ---------------------------------------------------------------------------
Describe 'Resume-state readers: read-once projection via -State' {

    BeforeAll {
        $script:OneState = [pscustomobject]@{
            TenantID                 = 't'
            CompletedSubscriptionIds = @('s1', 's2')
            FailedAttempts           = @([pscustomobject]@{ Id = 's3'; Name = 'Sub Three'; Reason = 'boom'; Attempts = 2 })
            EnumeratedAtStart        = [pscustomobject]@{ CapturedUtc = '2026-01-01T00:00:00Z'; SubscriptionIds = @('s1', 's2', 's3') }
        }

        $script:NoSuchPath = Join-Path ([System.IO.Path]::GetTempPath()) ('rda-no-such-state-{0}.json' -f [guid]::NewGuid().ToString('N'))
        $script:RealPath = Join-Path ([System.IO.Path]::GetTempPath()) ('rda-real-state-{0}.json' -f [guid]::NewGuid().ToString('N'))
        ($script:OneState | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $script:RealPath -Encoding utf8
    }

    AfterAll {
        if (Test-Path -LiteralPath $script:RealPath) { Remove-Item -LiteralPath $script:RealPath -Force }
    }

    It 'the unreadable path really is absent, so an accidental read would yield empty' {
        Test-Path -LiteralPath $script:NoSuchPath | Should -BeFalse -Because 'the whole bypass proof rests on this path being unreadable'
    }

    It 'Get-CompletedSubscriptionIds projects from -State without consulting the path' {
        @(Get-CompletedSubscriptionIds -Path $script:NoSuchPath -Tenant 't' -State $script:OneState) | Should -Be @('s1', 's2')
    }

    It 'Get-FailedAttempts projects from -State without consulting the path' {
        $F = @(Get-FailedAttempts -Path $script:NoSuchPath -Tenant 't' -State $script:OneState)

        $F.Count | Should -Be 1
        $F[0].Id | Should -Be 's3'
    }

    It 'Get-StartSnapshot projects from -State without consulting the path' {
        $S = Get-StartSnapshot -Path $script:NoSuchPath -Tenant 't' -State $script:OneState

        @($S.SubscriptionIds).Count | Should -Be 3
        $S.CapturedUtc | Should -Be '2026-01-01T00:00:00Z'
    }

    It 'reads the state EXACTLY ZERO times across all three readers when -State is supplied' {
        Mock Get-ResumeStateObject { throw 'a reader must not read the state when -State was supplied' }

        { Get-CompletedSubscriptionIds -Path $script:NoSuchPath -Tenant 't' -State $script:OneState } | Should -Not -Throw
        { Get-FailedAttempts -Path $script:NoSuchPath -Tenant 't' -State $script:OneState } | Should -Not -Throw
        { Get-StartSnapshot -Path $script:NoSuchPath -Tenant 't' -State $script:OneState } | Should -Not -Throw

        # -Exactly is REQUIRED. Without it Pester's -Times means "at least N", so a
        # bare '-Times 0' is trivially satisfied and can NEVER fail - the whole
        # no-read claim would be unverified. Same trap documented in
        # Tests/AzGraphQueryRetry.Tests.ps1.
        Should -Invoke Get-ResumeStateObject -Exactly -Times 0 -Because 'one read must serve all three projections'

        # POSITIVE CONTROL, in this same It. A -Times 0 assertion is only meaningful
        # if the mock is reachable at all: if interception silently stopped working,
        # the mock would never be hit, nothing would throw, and -Times 0 would pass
        # on a registered-but-unreachable mock. Proving the mock DOES fire when
        # -State is omitted is what makes the zero above mean something.
        { Get-CompletedSubscriptionIds -Path $script:NoSuchPath -Tenant 't' } |
            Should -Throw -Because 'the mock must be reachable from inside Resolve-ResumeState, or the zero above proves nothing'
    }

    It 'still reads for itself when -State is OMITTED, so existing call sites are unchanged' {
        @(Get-CompletedSubscriptionIds -Path $script:RealPath -Tenant 't') | Should -Be @('s1', 's2')
        @(Get-FailedAttempts -Path $script:RealPath -Tenant 't').Count | Should -Be 1
        @((Get-StartSnapshot -Path $script:RealPath -Tenant 't').SubscriptionIds).Count | Should -Be 3
    }

    It 'reads once PER READER when -State is omitted - the behaviour -State exists to avoid' {
        Mock Get-ResumeStateObject { return $script:OneState }

        $null = Get-CompletedSubscriptionIds -Path $script:RealPath -Tenant 't'
        $null = Get-FailedAttempts -Path $script:RealPath -Tenant 't'
        $null = Get-StartSnapshot -Path $script:RealPath -Tenant 't'

        Should -Invoke Get-ResumeStateObject -Times 3 -Exactly -Because 'this is the 3x read the -State parameter lets a caller collapse to 1'
    }

    It 'honours the tenant guard on the path it did read when -State is omitted' {
        @(Get-CompletedSubscriptionIds -Path $script:RealPath -Tenant 'other-tenant') | Should -BeNullOrEmpty -Because 'state for a different tenant must be ignored, not projected'
    }

    It 'ALSO enforces the tenant guard on a SUPPLIED state, so -Tenant is never silently ignored' {
        # The value being guarded is CompletedSubscriptionIds, which is used to SKIP
        # subscriptions. Wrong-tenant state must never cause a skip, no matter whether
        # the state was read here or handed in.
        @(Get-CompletedSubscriptionIds -Path $script:NoSuchPath -Tenant 'other-tenant' -State $script:OneState) |
            Should -BeNullOrEmpty -Because 'a supplied state can come from anywhere and must still be tenant-checked'

        @(Get-FailedAttempts -Path $script:NoSuchPath -Tenant 'other-tenant' -State $script:OneState) | Should -BeNullOrEmpty
        Get-StartSnapshot -Path $script:NoSuchPath -Tenant 'other-tenant' -State $script:OneState | Should -BeNullOrEmpty
    }

    It 'treats -State $null as SUPPLIED, not as omitted, so it does not fall back to the blob' {
        # $SeedState is legitimately $null on a fresh run, a tenant mismatch and an
        # unreadable blob. If an explicit $null were read as "omitted", all three
        # readers would go back to the blob on exactly the recovery path -State exists
        # to spare - re-running the retry and re-emitting its warning three times.
        Mock Get-ResumeStateObject { throw 'an explicit -State $null must not trigger a read' }

        { @(Get-CompletedSubscriptionIds -Path $script:RealPath -Tenant 't' -State $null) } | Should -Not -Throw
        { @(Get-FailedAttempts -Path $script:RealPath -Tenant 't' -State $null) } | Should -Not -Throw
        { Get-StartSnapshot -Path $script:RealPath -Tenant 't' -State $null } | Should -Not -Throw

        # -Exactly required, as above: a bare -Times 0 cannot fail.
        Should -Invoke Get-ResumeStateObject -Exactly -Times 0 -Because 'an explicit null is a supplied value, not an absent one'

        # Positive control (see the sibling It): prove the mock is reachable here too.
        { Get-CompletedSubscriptionIds -Path $script:RealPath -Tenant 't' } |
            Should -Throw -Because 'omitting -State must reach the mock, or the zero above proves nothing'
    }

    It 'projects empty/null from an explicit -State $null rather than inventing data' {
        @(Get-CompletedSubscriptionIds -Path $script:NoSuchPath -Tenant 't' -State $null) | Should -BeNullOrEmpty
        @(Get-FailedAttempts -Path $script:NoSuchPath -Tenant 't' -State $null) | Should -BeNullOrEmpty
        Get-StartSnapshot -Path $script:NoSuchPath -Tenant 't' -State $null | Should -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
# Report-archive loss detection
#
# Covers the packaging/verification seam that previously let a whole
# subscription's report vanish while the run reported success:
# ResourceInventory.ps1 swallowed a Compress-Archive failure (the run-wide
# 'SilentlyContinue' discarded non-terminating errors, the catch used
# Write-Error which neither rethrows nor sets an exit code) and then logged
# 'Reporting Data File' unconditionally, so the wrapper counted the sub
# complete and consolidated a bundle one report short.
#
# Two of the three regressions in this area were invisible to parse, review and
# pure-helper unit tests, and only a live run caught them - so the guards below
# assert against the wrapper/inner SOURCE as well as the behaviour:
#
#   1. $LASTEXITCODE is SHARED and STICKY. Adding a real `exit` to the inner
#      script's tail meant one failing subscription made every LATER
#      subscription in the same runspace look like it exited non-zero, failing
#      subs whose reports were written correctly. Each `&` invocation must reset
#      it first.
#   2. A failed sub is correctly EXCLUDED from the expected-archive count, so
#      the per-subscription output verification gate has nothing to compare and
#      stays silent. Without the exit-code override the run would exit 0 with a
#      report missing from the bundle - visible to a human, invisible to
#      automation.
# ---------------------------------------------------------------------------

Describe 'Report-archive loss detection: source guards' {
    BeforeAll {
        $script:RepoRoot = Split-Path $PSScriptRoot -Parent
        $script:WrapperSrc = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'Run-AllSubscriptions.ps1')
        $script:StreamSrc = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'Run-AllSubscriptions.Stream.ps1')
        $script:InnerSrc = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'ResourceInventory.ps1')

        # Index of every line that invokes the inner script with the call
        # operator, in both files that do so.
        function script:Get-InnerInvocationIndexes
        {
            param([string[]]$Lines)
            $Result = @()
            for ($i = 0; $i -lt $Lines.Count; $i++)
            {
                if ($Lines[$i] -match '^\s*&\s*\(Join-Path\s+\$\w+\s+[''"]ResourceInventory\.ps1[''"]\)')
                {
                    $Result += $i
                }
            }
            return $Result
        }

        # Lines matching $Pattern, EXCLUDING comments. The explanatory comments
        # around this change quote the very constructs being asserted on, so a
        # naive match would count them and pass for the wrong reason.
        function script:Select-CodeLines
        {
            param([string[]]$Lines, [string]$Pattern)
            return @($Lines | Where-Object { -not $_.Trim().StartsWith('#') -and $_.Trim() -match $Pattern })
        }

        # The $Count nearest preceding lines that are neither blank nor comments,
        # nearest first.
        function script:Get-PrecedingCodeLines
        {
            param([string[]]$Lines, [int]$Index, [int]$Count = 2)
            $Found = @()
            for ($j = $Index - 1; $j -ge 0 -and $Found.Count -lt $Count; $j--)
            {
                $Text = $Lines[$j].Trim()
                if ($Text -eq '' -or $Text.StartsWith('#')) { continue }
                $Found += $Text
            }
            return $Found
        }
    }

    It 'the wrapper invokes the inner script in exactly the two places this suite knows about' {
        # If a third call site appears, the reset guard below must cover it too -
        # fail here rather than silently leaving a new site unguarded.
        @(script:Get-InnerInvocationIndexes -Lines $script:WrapperSrc).Count | Should -Be 2
        @(script:Get-InnerInvocationIndexes -Lines $script:StreamSrc).Count | Should -Be 1
    }

    It 'every inner-script invocation resets both sticky globals immediately before it' {
        # THE regression guard. $LASTEXITCODE: without the reset, one subscription
        # exiting non-zero poisons the exit-code check for every later subscription
        # in the same runspace. $Global:ZipOutputFile: without the reset, a sub that
        # left via a bare `Exit` records the previous sub's archive path.
        foreach ($Pair in @(
                @{ Name = 'Run-AllSubscriptions.ps1'; Lines = $script:WrapperSrc },
                @{ Name = 'Run-AllSubscriptions.Stream.ps1'; Lines = $script:StreamSrc }))
        {
            foreach ($Idx in @(script:Get-InnerInvocationIndexes -Lines $Pair.Lines))
            {
                $Preceding = @(script:Get-PrecedingCodeLines -Lines $Pair.Lines -Index $Idx -Count 2)
                $Where = ("{0} line {1}" -f $Pair.Name, ($Idx + 1))
                @($Preceding | Where-Object { $_ -match '^\$global:LASTEXITCODE\s*=\s*0$' }).Count |
                    Should -Be 1 -Because ("the invocation at $Where must reset the sticky " + '$LASTEXITCODE' + ' first')
                @($Preceding | Where-Object { $_ -match '^\$Global:ZipOutputFile\s*=\s*\$null$' }).Count |
                    Should -Be 1 -Because ("the invocation at $Where must reset the sticky " + '$Global:ZipOutputFile' + ' first')
            }
        }
    }

    It 'both callers map inner exit code 2 to an archive-write failure record' {
        # Count CODE lines only - the explanatory comments in both files also
        # mention exit code 2, which would make these counts pass for the wrong
        # reason.
        @(script:Select-CodeLines -Lines $script:WrapperSrc -Pattern '\$LASTEXITCODE\s+-eq\s+2').Count | Should -Be 2
        @(script:Select-CodeLines -Lines $script:StreamSrc -Pattern '\$LASTEXITCODE\s+-eq\s+2').Count | Should -Be 1
    }

    It 'every inner-script invocation also clears the sticky $Global:ZipOutputFile' {
        # Without this the archive path recorded for a sub that left via a bare
        # `Exit` (code 0, before any archive path exists) is the PREVIOUS sub's,
        # which then passes verification "by exact path" against another
        # subscription's file.
        @(script:Select-CodeLines -Lines $script:WrapperSrc -Pattern '^\$Global:ZipOutputFile = \$null$').Count | Should -Be 2
        @(script:Select-CodeLines -Lines $script:StreamSrc -Pattern '^\$Global:ZipOutputFile = \$null$').Count | Should -Be 1
    }

    It 'the stream worker relays archive-write failures in its summary' {
        # Cross-process contract: the parent cannot set its exit code from a
        # failure it never hears about.
        @(script:Select-CodeLines -Lines $script:StreamSrc -Pattern 'ArchiveWriteFailures\s+=\s+@\(\$ArchiveWriteFailures\)').Count | Should -Be 1
        @(script:Select-CodeLines -Lines $script:WrapperSrc -Pattern '\$StreamSummary\.ArchiveWriteFailures').Count | Should -BeGreaterThan 0
    }

    It 'the inner script forces the packaging compress to be terminating' {
        # Without -ErrorAction Stop a NON-terminating Compress-Archive error is
        # discarded by the run-wide SilentlyContinue and the catch never fires.
        @(script:Select-CodeLines -Lines $script:InnerSrc -Pattern 'Compress-Archive\s+@CompressionOutput').Count | Should -Be 1
        ($script:InnerSrc -join "`n") | Should -Match 'Compress-Archive\s+@CompressionOutput\s+-ErrorAction\s+Stop'
    }

    It 'the inner script removes an unusable archive before it leaves' {
        # The wrapper consolidates by globbing *.zip and does not consult the
        # inner script's verdict, so a truncated archive left behind would ship as
        # a corrupt bundle member AND inflate the wrapper's archive count.
        ($script:InnerSrc -join "`n") | Should -Match '(?s)if \(-not \$ZipVerified\).*?Remove-Item -LiteralPath \$Global:ZipOutputFile.*?exit 2'
    }

    It 'both sides of the seam use the one shared usable-archive predicate' {
        # Two definitions of "usable archive" would drift, and the failure mode of
        # that drift is the wrapper consolidating an archive the inner script
        # would have rejected.
        @(script:Select-CodeLines -Lines $script:InnerSrc -Pattern 'Test-ReportArchiveUsable').Count | Should -BeGreaterThan 0
        @(script:Select-CodeLines -Lines $script:WrapperSrc -Pattern 'Test-ReportArchiveUsable').Count | Should -BeGreaterThan 0
        $CommonSrc = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'Functions/Common.Functions.ps1')
        @(script:Select-CodeLines -Lines $CommonSrc -Pattern '^function Test-ReportArchiveUsable$').Count | Should -Be 1
        # And nowhere else, so the definition stays single-owner.
        @(script:Select-CodeLines -Lines (Get-Content -LiteralPath (Join-Path $script:RepoRoot 'Functions/RunAllSubscriptions.Functions.ps1')) -Pattern 'function Test-ReportArchiveUsable').Count | Should -Be 0
    }

    It 'the inner script no longer uses the Write-Error swallow handler for packaging' {
        # Write-Error under 'SilentlyContinue' prints nothing, does not rethrow,
        # and leaves the exit code at 0.
        ($script:InnerSrc -join "`n") | Should -Not -Match 'Write-Error\s*\(\s*"Error Compressing Output File'
    }

    It 'the inner script logs the archive as a Success only AFTER verifying it' {
        # Match the STATEMENT, not the string: the explanatory comment above the
        # packaging block also mentions 'Reporting Data File'.
        $CodeLineNumber = {
            param([string]$Pattern)
            for ($i = 0; $i -lt $script:InnerSrc.Count; $i++)
            {
                $Text = $script:InnerSrc[$i].Trim()
                if ($Text.StartsWith('#')) { continue }
                if ($Text -match $Pattern) { return $i + 1 }
            }
            return $null
        }
        $VerifyIdx = & $CodeLineNumber '^if \(-not \$ZipVerified\)'
        $SuccessIdx = & $CodeLineNumber 'Write-Log\s+-Message\s+\("Reporting Data File'
        $VerifyIdx | Should -Not -BeNullOrEmpty
        $SuccessIdx | Should -Not -BeNullOrEmpty
        $SuccessIdx | Should -BeGreaterThan $VerifyIdx -Because 'the success line claimed an archive that was never written when it ran unconditionally'
        # Exactly one Success claim in code, and the failure branch leaves before it.
        @($script:InnerSrc | Where-Object { -not $_.Trim().StartsWith('#') -and $_ -match 'Reporting Data File' }).Count | Should -Be 1
        ($script:InnerSrc -join "`n") | Should -Match '(?s)if \(-not \$ZipVerified\).*?exit 2'
    }
}

Describe 'Report-archive loss detection: verification classification' {
    # Faithful copy of the gate's two classification expressions from
    # Run-AllSubscriptions.ps1. The gate is inline in the wrapper body (which
    # cannot be dot-sourced), so this mirrors the production expressions the same
    # way Tests/ResumeCycle.Tests.ps1 mirrors the wrapper's resume expressions,
    # with the source guard above covering drift in the real file.
    BeforeAll {
        $TmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { '/tmp' }
        $script:ZipRoot = Join-Path $TmpBase ("ArchiveVerifyTest_" + [guid]::NewGuid().ToString().Substring(0, 8))
        New-Item -ItemType Directory -Path $script:ZipRoot -Force | Out-Null
        $script:PresentZip = Join-Path $script:ZipRoot 'ResourcesReport_present.zip'
        Set-Content -LiteralPath $script:PresentZip -Value 'x' -Encoding utf8
        $script:AbsentZip = Join-Path $script:ZipRoot 'ResourcesReport_absent.zip'

        # Calls the REAL shared predicate (Test-ReportArchiveUsable, dot-sourced by
        # the BeforeAll at the top of this file and by both the wrapper and the
        # stream worker at runtime); only the two Where-Object shapes around it are
        # mirrored from the wrapper body, which cannot be dot-sourced.
        function script:Split-VerificationRows
        {
            param($Rows)
            $Missing = @($Rows | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Zip) -and -not (Test-ReportArchiveUsable -Path $_.Zip) })
            $Unverifiable = @($Rows | Where-Object { [string]::IsNullOrWhiteSpace($_.Zip) })
            return @{ Missing = $Missing; Unverifiable = $Unverifiable }
        }
    }
    AfterAll {
        if ($script:ZipRoot -and (Test-Path $script:ZipRoot)) { Remove-Item -Path $script:ZipRoot -Recurse -Force }
    }

    It 'classifies a recorded-but-absent archive as missing, and names the subscription' {
        $Rows = @(
            [pscustomobject]@{ Name = 'Good'; Id = 'g1'; Count = 3; Zip = $script:PresentZip },
            [pscustomobject]@{ Name = 'Lost'; Id = 'l1'; Count = 7; Zip = $script:AbsentZip }
        )
        $Split = script:Split-VerificationRows -Rows $Rows
        $Split.Missing.Count | Should -Be 1
        $Split.Missing[0].Name | Should -Be 'Lost'
        $Split.Missing[0].Id | Should -Be 'l1'
        $Split.Unverifiable.Count | Should -Be 0
    }

    It 'treats a row with no recorded path as unverifiable, never as missing' {
        # A per-stream summary written by an older build carries no Zip. It must
        # not produce a false accusation against a specific subscription.
        foreach ($Empty in @($null, '', '   '))
        {
            $Rows = @([pscustomobject]@{ Name = 'OldBuild'; Id = 'o1'; Count = 1; Zip = $Empty })
            $Split = script:Split-VerificationRows -Rows $Rows
            $Split.Missing.Count | Should -Be 0
            $Split.Unverifiable.Count | Should -Be 1
        }
    }

    It 'reports neither when every recorded archive is present' {
        $Rows = @(
            [pscustomobject]@{ Name = 'A'; Id = 'a1'; Count = 1; Zip = $script:PresentZip },
            [pscustomobject]@{ Name = 'B'; Id = 'b1'; Count = 2; Zip = $script:PresentZip }
        )
        $Split = script:Split-VerificationRows -Rows $Rows
        $Split.Missing.Count | Should -Be 0
        $Split.Unverifiable.Count | Should -Be 0
        # The OK line's "verified by exact path" total must not overstate what was
        # actually checked.
        (@($Rows).Count - $Split.Unverifiable.Count) | Should -Be 2
    }

    It 'does not count an unverifiable row as verified by path' {
        $Rows = @(
            [pscustomobject]@{ Name = 'A'; Id = 'a1'; Count = 1; Zip = $script:PresentZip },
            [pscustomobject]@{ Name = 'Old'; Id = 'o1'; Count = 1; Zip = $null }
        )
        $Split = script:Split-VerificationRows -Rows $Rows
        (@($Rows).Count - $Split.Unverifiable.Count) | Should -Be 1
    }

    It 'a directory at the archive path does not satisfy the check' {
        # -PathType Leaf matters: the forced-failure reproduction occupies the
        # destination with a directory, and Compress-Archive then cannot write a
        # file there.
        $DirAtZipPath = Join-Path $script:ZipRoot 'ResourcesReport_dir.zip'
        New-Item -ItemType Directory -Path $DirAtZipPath -Force | Out-Null
        $Rows = @([pscustomobject]@{ Name = 'DirNotFile'; Id = 'd1'; Count = 1; Zip = $DirAtZipPath })
        $Split = script:Split-VerificationRows -Rows $Rows
        $Split.Missing.Count | Should -Be 1
    }

    It 'a present-but-EMPTY archive counts as missing, not as present' {
        # A 0-byte file is what a truncating quarantine or a write cut off
        # mid-flush leaves. The inner script already rejects it before reporting
        # success, so the wrapper must apply the same standard or the two halves
        # disagree about what a usable report is.
        $EmptyZip = Join-Path $script:ZipRoot 'ResourcesReport_empty.zip'
        New-Item -ItemType File -Path $EmptyZip -Force | Out-Null
        (Get-Item -LiteralPath $EmptyZip).Length | Should -Be 0
        $Rows = @([pscustomobject]@{ Name = 'Truncated'; Id = 't1'; Count = 4; Zip = $EmptyZip })
        $Split = script:Split-VerificationRows -Rows $Rows
        $Split.Missing.Count | Should -Be 1
        $Split.Missing[0].Name | Should -Be 'Truncated'
    }
}

Describe 'Test-ReportArchiveUsable' {
    BeforeAll {
        $TmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { '/tmp' }
        $script:UsableRoot = Join-Path $TmpBase ("ArchiveUsableTest_" + [guid]::NewGuid().ToString().Substring(0, 8))
        New-Item -ItemType Directory -Path $script:UsableRoot -Force | Out-Null
    }
    AfterAll {
        if ($script:UsableRoot -and (Test-Path $script:UsableRoot)) { Remove-Item -Path $script:UsableRoot -Recurse -Force }
    }

    It 'accepts a non-empty file' {
        $P = Join-Path $script:UsableRoot 'real.zip'
        Set-Content -LiteralPath $P -Value 'content' -Encoding utf8
        Test-ReportArchiveUsable -Path $P | Should -BeTrue
    }
    It 'rejects a 0-byte file' {
        $P = Join-Path $script:UsableRoot 'empty.zip'
        New-Item -ItemType File -Path $P -Force | Out-Null
        Test-ReportArchiveUsable -Path $P | Should -BeFalse
    }
    It 'rejects a path that does not exist' {
        Test-ReportArchiveUsable -Path (Join-Path $script:UsableRoot 'nope.zip') | Should -BeFalse
    }
    It 'rejects a directory' {
        $P = Join-Path $script:UsableRoot 'dir.zip'
        New-Item -ItemType Directory -Path $P -Force | Out-Null
        Test-ReportArchiveUsable -Path $P | Should -BeFalse
    }
    It 'rejects null, empty and whitespace without throwing' {
        foreach ($Bad in @($null, '', '   '))
        {
            Test-ReportArchiveUsable -Path $Bad | Should -BeFalse
        }
    }
    It 'handles a path containing square brackets (not treated as a wildcard)' {
        # -LiteralPath throughout: a report folder name with [ ] would otherwise be
        # read as a glob and silently match nothing, reporting a present archive as
        # missing.
        $P = Join-Path $script:UsableRoot 'Resources[1].zip'
        Set-Content -LiteralPath $P -Value 'content' -Encoding utf8
        Test-ReportArchiveUsable -Path $P | Should -BeTrue
    }
}

Describe 'Report-archive loss detection: exit code' {
    # Mirrors the wrapper's override: an archive-write failure means a report is
    # MISSING, which is what exit code 2 already signals, and it must not mask a
    # higher-signal code from Get-WrapperExitCode.
    BeforeAll {
        function script:Resolve-ExitCode
        {
            param([bool]$AuthSkipped, [bool]$CollectorsFailed, [int]$ArchiveFailureCount)
            $Code = Get-WrapperExitCode -AuthSkipped $AuthSkipped -CollectorsFailed $CollectorsFailed
            if ($ArchiveFailureCount -gt 0) { $Code = 2 }
            return $Code
        }
    }

    It 'an otherwise-clean run with a lost archive exits 2, not 0' {
        script:Resolve-ExitCode -AuthSkipped $false -CollectorsFailed $false -ArchiveFailureCount 1 | Should -Be 2
    }

    It 'a clean run with no lost archive still exits 0' {
        script:Resolve-ExitCode -AuthSkipped $false -CollectorsFailed $false -ArchiveFailureCount 0 | Should -Be 0
    }

    It 'a lost archive takes precedence over an auth skip and a collector failure' {
        # 3/4/5 all mean "the report was produced but is incomplete". A lost
        # archive means a subscription's report is NOT IN THE BUNDLE - strictly
        # worse - so it must not be masked. All conditions still print their own
        # banner, so nothing is hidden from a human either.
        script:Resolve-ExitCode -AuthSkipped $true -CollectorsFailed $false -ArchiveFailureCount 1 | Should -Be 2
        script:Resolve-ExitCode -AuthSkipped $false -CollectorsFailed $true -ArchiveFailureCount 1 | Should -Be 2
        script:Resolve-ExitCode -AuthSkipped $true -CollectorsFailed $true -ArchiveFailureCount 1 | Should -Be 2
    }

    It 'without a lost archive the 3/4/5 precedence is untouched' {
        script:Resolve-ExitCode -AuthSkipped $true -CollectorsFailed $false -ArchiveFailureCount 0 | Should -Be 3
        script:Resolve-ExitCode -AuthSkipped $false -CollectorsFailed $true -ArchiveFailureCount 0 | Should -Be 4
        script:Resolve-ExitCode -AuthSkipped $true -CollectorsFailed $true -ArchiveFailureCount 0 | Should -Be 5
    }

    It 'the wrapper sets code 2 unconditionally on an archive failure' {
        # Source guard on the precedence rule, since the behavioural tests above
        # run a copy of it. A reintroduced `-eq 0` guard would let 3/4/5 mask a
        # missing report.
        $Src = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'Run-AllSubscriptions.ps1') -Raw
        $Src | Should -Match '(?s)if \(@\(\$ArchiveWriteFailures\)\.Count -gt 0\)\s*\{\s*\$WrapperExitCode = 2\s*\}'
        $Src | Should -Not -Match 'if \(\$WrapperExitCode -eq 0\)\s*\{\s*\$WrapperExitCode = 2\s*\}'
    }

    It 'the archive-failure banner prints before Stop-Transcript so it is persisted' {
        # A banner emitted after the transcript stops exists only on the console.
        $Lines = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'Run-AllSubscriptions.ps1')
        $BannerIdx = ($Lines | Select-String -SimpleMatch 'FAILED (report archive)' | Select-Object -First 1).LineNumber
        $StopIdx = ($Lines | Select-String -SimpleMatch 'Stop-Transcript on normal completion failed' | Select-Object -First 1).LineNumber
        $BannerIdx | Should -Not -BeNullOrEmpty
        $StopIdx | Should -Not -BeNullOrEmpty
        $BannerIdx | Should -BeLessThan $StopIdx
    }
}

# ---------------------------------------------------------------------------
# Blob container URI parsing: single owner
#
# The wrapper used to parse -UploadToBlobContainerUri with its own inline copies of
# the [System.Uri] / Host.Split('.') / AbsolutePath.Trim('/').Split('/', 2)
# sequence, character-for-character identical to Split-BlobContainerUri, which it
# already calls for -StateBlobContainerUri. Identical copies of a parser are how the
# upload path and the state path come to disagree about what a container URL means -
# and the disagreement would surface as blobs written to the wrong prefix, not as an
# error.
#
# SCOPE, stated precisely: this guards Run-AllSubscriptions.ps1 and
# Functions/RunAllSubscriptions.Functions.ps1 only. A fourth copy still lives in
# deploy/Test-NodeReadiness.ps1, left deliberately because that script is a
# self-contained in-pod preflight that dot-sources nothing, so it cannot reach the
# shared helper without acquiring a dependency it is designed not to have. The
# guard is therefore not a repo-wide "exactly one copy" claim.
#
# A behavioural test cannot reach those blocks (they sit inline in the wrapper's
# upload sections, behind a live blob account), so this guards the SOURCE, the same
# way the report-archive guards above do.
# ---------------------------------------------------------------------------
Describe 'Blob container URI parsing has one owner in the wrapper and its shared functions' {

    BeforeAll {
        $script:UriRepoRoot = Split-Path $PSScriptRoot -Parent

        # CODE ONLY - every comment token is removed before matching. A guard that
        # reads comments traps itself: the comments explaining this very consolidation
        # name the patterns being banned, so a later clarity edit to one of them would
        # fail the guard with a completely misleading message.
        #
        # Tokenized via the PowerShell parser rather than a '^\s*#' line filter,
        # because a line filter misses a TRAILING comment on a line of real code and
        # misses the interior lines of a <# ... #> block, both of which would
        # reintroduce the self-trap. Fails LOUD on an unparseable or empty result: a
        # silently empty string would make every 'Should -Not -Match' ban below pass
        # vacuously, which is the worst possible failure mode for a guard.
        function Get-CodeOnly
        {
            param([string]$Path)

            if (-not (Test-Path -LiteralPath $Path)) { throw "Get-CodeOnly: source file not found: $Path" }

            $Tokens = $null
            $ParseErrors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$Tokens, [ref]$ParseErrors)
            if ($ParseErrors -and $ParseErrors.Count -gt 0) { throw "Get-CodeOnly: $Path does not parse: $($ParseErrors[0].Message)" }

            # Excise the comment tokens' character ranges from the RAW text rather than
            # re-joining the code tokens. Re-joining would insert or drop whitespace and
            # break the very patterns being searched for - joining with a space turns
            # "Host.Split(" into "Host . Split (", joining with nothing welds
            # "function Split-BlobContainerUri" into one word. Removing extents leaves
            # every code character exactly where it was. Walk backwards so each removal
            # cannot invalidate the offsets of the ones not yet processed.
            $Raw = Get-Content -LiteralPath $Path -Raw
            $Comments = @($Tokens | Where-Object { $_.Kind -eq 'Comment' } | Sort-Object { $_.Extent.StartOffset } -Descending)
            $Builder = [System.Text.StringBuilder]::new($Raw)
            foreach ($C in $Comments)
            {
                $Start = $C.Extent.StartOffset
                $Length = $C.Extent.EndOffset - $Start
                if ($Length -gt 0 -and $Start -ge 0 -and ($Start + $Length) -le $Builder.Length)
                {
                    $null = $Builder.Remove($Start, $Length)
                }
            }
            $Code = $Builder.ToString()

            if ([string]::IsNullOrWhiteSpace($Code)) { throw "Get-CodeOnly: produced no code text for $Path" }
            return $Code
        }

        $script:UriWrapperSrc = Get-CodeOnly -Path (Join-Path $script:UriRepoRoot 'Run-AllSubscriptions.ps1')
        $script:UriFunctionsSrc = Get-CodeOnly -Path (Join-Path $script:UriRepoRoot 'Functions/RunAllSubscriptions.Functions.ps1')
        # The stream worker dot-sources the same functions file, so unlike
        # deploy/Test-NodeReadiness.ps1 it CAN reach the shared helper - and it already
        # calls it. It is therefore in scope for the ban, not exempt from it.
        $script:UriStreamSrc = Get-CodeOnly -Path (Join-Path $script:UriRepoRoot 'Run-AllSubscriptions.Stream.ps1')
    }

    It 'the comment-stripping helper removes every comment form and keeps real code' {
        # Without this, a bug in Get-CodeOnly would make every guard below pass
        # vacuously by stripping too much - or trap itself by stripping nothing.
        # All three comment forms are covered because a line filter would only have
        # caught the first.
        $Sample = @'
# Host.Split('.') on its own line
$a = 1   # Host.Split('.') trailing on a code line
<#
   Host.Split('.') inside a block comment
#>
$b = 2
'@
        $Tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('rda-codeonly-{0}.ps1' -f [guid]::NewGuid().ToString('N'))
        try
        {
            Set-Content -LiteralPath $Tmp -Value $Sample -Encoding utf8
            $Code = Get-CodeOnly -Path $Tmp

            $Code | Should -Not -Match 'Host\.Split' -Because 'whole-line, trailing AND block comments must all be stripped'
            $Code | Should -Match '\$a' -Because 'real code must survive stripping'
            $Code | Should -Match '\$b' -Because 'code after a block comment must survive stripping'
        }
        finally
        {
            if (Test-Path -LiteralPath $Tmp) { Remove-Item -LiteralPath $Tmp -Force }
        }
    }

    It 'the comment-stripping helper FAILS LOUD rather than returning an empty string' {
        # An empty result would satisfy every 'Should -Not -Match' ban below without
        # checking anything, so it must throw instead.
        { Get-CodeOnly -Path (Join-Path ([System.IO.Path]::GetTempPath()) 'rda-definitely-not-here.ps1') } |
            Should -Throw -Because 'a missing source file must not silently disable the guard'
    }

    # These two patterns are the account extraction and the container/prefix split
    # specifically. A bare .AbsolutePath.Trim('/') is NOT matched: the wrapper's
    # -UploadToBlobContainerUri / -StateBlobContainerUri preflight legitimately
    # uses it to test that the URL carries any path at all, which is a validation,
    # not a parse.
    It 'neither the wrapper nor the stream worker re-derives a storage account name from a URI host' {
        $script:UriWrapperSrc | Should -Not -Match 'Host\.Split\(' -Because 'the wrapper must call Split-BlobContainerUri instead of parsing a container URL itself'
        $script:UriStreamSrc | Should -Not -Match 'Host\.Split\(' -Because 'the stream worker dot-sources the helper and must use it'
    }

    It 'neither the wrapper nor the stream worker re-derives a container and prefix from a URI path' {
        $script:UriWrapperSrc | Should -Not -Match "AbsolutePath\.Trim\('/'\)\.Split" -Because 'the container/prefix split belongs to Split-BlobContainerUri'
        $script:UriStreamSrc | Should -Not -Match "AbsolutePath\.Trim\('/'\)\.Split" -Because 'the stream worker must not carry its own copy either'
    }

    It 'the shared functions file parses a container URL in exactly ONE place' {
        # The support-log upload used to carry its own copy of this parse.
        @([regex]::Matches($script:UriFunctionsSrc, 'Host\.Split\(')).Count | Should -Be 1 -Because 'only Split-BlobContainerUri may extract the account'
        @([regex]::Matches($script:UriFunctionsSrc, "AbsolutePath\.Trim\('/'\)\.Split")).Count | Should -Be 1 -Because 'only Split-BlobContainerUri may split container from prefix'
    }

    It 'the shared helper still owns both halves of the parse' {
        $script:UriFunctionsSrc | Should -Match 'function Split-BlobContainerUri'
        $script:UriFunctionsSrc | Should -Match 'Host\.Split\('
        $script:UriFunctionsSrc | Should -Match "AbsolutePath\.Trim\('/'\)\.Split"
    }

    It 'the wrapper calls the shared helper at exactly the three places it needs container parts' {
        # Exactly three, matching the sibling assertion's exact count rather than a
        # weaker "at least": the -StateBlobContainerUri setup, the upload WRITE PROBE,
        # and the real upload. The probe and the upload must agree, or the probe would
        # confirm access to a location the upload does not use. A fourth call site is
        # not automatically wrong - but it should be a deliberate edit to this number,
        # not something that slides in unnoticed.
        $Calls = @([regex]::Matches($script:UriWrapperSrc, 'Split-BlobContainerUri\s+-Uri'))

        $Calls.Count | Should -Be 3 -Because 'the state path, the upload write probe and the upload itself must all go through the one parser'
    }

    # NOTE: this Describe deliberately contains no behavioural equivalence test.
    # An earlier draft had one that re-implemented the removed inline expressions as
    # its "expected" oracle - but those expressions are character-identical to
    # Split-BlobContainerUri's body, so it compared an expression with itself and
    # could not fail for any input. Split-BlobContainerUri's behaviour is pinned
    # against LITERAL expected values in Tests/BlobStateReconciliation.Tests.ps1,
    # which is the right owner for it. This Describe guards structure only.
}
