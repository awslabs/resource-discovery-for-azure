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
    if (-not (Test-Path $script:FunctionsPath)) {
        throw "Could not find shared functions file at $script:FunctionsPath"
    }
    . $script:FunctionsPath

    # Guard: the functions under test must be defined by the shared file. If a
    # future change renames or removes one, fail loudly here rather than with a
    # confusing "command not found" mid-test.
    $TargetFunctions = @('Get-StreamResumeStateFiles', 'Merge-FailedAttempts', 'Get-WrapperExitCode', 'Add-FailedAttempt', 'Remove-FailedAttempt')
    foreach ($Fn in $TargetFunctions) {
        if (-not (Get-Command $Fn -CommandType Function -ErrorAction SilentlyContinue)) {
            throw "Expected function '$Fn' to be defined by $script:FunctionsPath, but it was not. Has it been renamed or removed?"
        }
    }

    $TmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { '/tmp' }
    $script:TestRoot = Join-Path $TmpBase ("RunAllSubsReconTest_" + [guid]::NewGuid().ToString().Substring(0, 8))
    New-Item -ItemType Directory -Path $script:TestRoot -Force | Out-Null
}

AfterAll {
    if ($script:TestRoot -and (Test-Path $script:TestRoot)) {
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
        $First  = Add-FailedAttempt -Existing @() -Id 'sub-1' -Name 'Sub One' -Reason 'first'
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
        $StreamScalar   = [pscustomobject]@{ Id = 'sub-2'; Name = 'Sub Two'; LastFailedAt = '2026-06-01T00:00:00Z'; Reason = 'new'; Attempts = 1 }

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
