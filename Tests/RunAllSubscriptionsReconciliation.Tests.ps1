# Unit tests for Run-AllSubscriptions.ps1's pure reconciliation/exit-code/access-gate/summary helpers,
# dot-sourcing the definitions-only Functions/RunAllSubscriptions.Functions.ps1 (the exact file loaded at runtime) so no live Azure session is needed.

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
    $TargetFunctions = @('Get-StreamResumeStateFiles', 'Merge-FailedAttempts', 'Get-WrapperExitCode', 'Add-FailedAttempt', 'Remove-FailedAttempt', 'Get-ConsumptionAccessOutcome', 'Resolve-AccessPreflight', 'Confirm-PartialAccessContinue', 'Invoke-RdaSupportLogCollectionInTranscript', 'Test-RdaFinalScreenClearable', 'Get-RdaFinalScreenLines', 'Test-SubscriptionAccessAll', 'Expand-ServiceFilter', 'Test-BackgroundJobSupport', 'Save-CompletedSubscriptionIds', 'Get-FailedAttempts', 'Test-ReportArchiveUsable',
        'Split-BlobContainerUri', 'Get-CompletedSubscriptionIds', 'Get-StartSnapshot', 'Resolve-ResumeState', 'Get-ResumeStateObject',
        'Get-StreamImportMarkerPath', 'Get-StaleAzContextSnapshot', 'Test-AzContextSnapshotReleasable', 'Invoke-PreFlightChecks', 'Get-RunSummaryLogContent', 'Write-RdaHostLinesInTranscript')
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

    # True when THIS test's transcript file is still recording. Probing with Stop-Transcript instead
    # would stop a transcript the caller's own session may have running. Redirected host output is
    # still transcribed but not shown, so the probe line never reaches the console.
    function script:Test-OwnTranscriptOpen
    {
        param([string]$Path)
        $Marker = 'rda-transcript-probe-' + [guid]::NewGuid().ToString('N')
        Write-Host $Marker 6>$null
        return [bool]((Test-Path -LiteralPath $Path) -and (Get-Content -LiteralPath $Path -Raw).Contains($Marker))
    }
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
    # A one-element result collapses to a scalar PSCustomObject (not IEnumerable), which the old
    # [IEnumerable] params rejected with an argument-transformation throw; params are now [object], @()-normalized.

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
        Get-ConsumptionAccessOutcome -ErrorMessage '' | Should -Be 'Ok'
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

    It 'Falls through to Unavailable (warn + continue, not a hard fail) for an error matching NEITHER the denial nor the transient patterns' {
        # Pins the default branch decision (dossier invariant 4): an unclassified
        # probe error - a 5xx server error or an entirely unrecognised message -
        # is NOT a Denied authorization failure, so it must NOT hard-fail the run.
        # It falls through to 'Unavailable', which warns and continues. Only an
        # explicit denial signature may escalate to the up-front hard fail.
        Get-ConsumptionAccessOutcome -ErrorMessage 'Response status code 500 (InternalServerError)' | Should -Be 'Unavailable' -Because 'a 5xx server error is not an authorization denial and must not hard-fail the run'
        Get-ConsumptionAccessOutcome -ErrorMessage 'Response status code 502 (BadGateway)' | Should -Be 'Unavailable'
        Get-ConsumptionAccessOutcome -ErrorMessage 'Response status code 503 (ServiceUnavailable)' | Should -Be 'Unavailable'
        Get-ConsumptionAccessOutcome -ErrorMessage 'An unexpected error of a kind this gate has never seen before' | Should -Be 'Unavailable' -Because 'an unrecognised probe error defaults to warn + continue, never to the Denied hard fail'
    }
}

Describe 'Interrupted-parallel-run stream-state fold-in (F2)' {
    # Reproduces the -Resume/-ResumeFailedOnly fold-in of unmerged per-stream files at the helper level
    # (guards the "-ResumeFailedOnly reports Nothing to retry" bug; the wrapper body itself needs a live Azure session).
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

Describe 'Confirm-PartialAccessContinue (ask before continuing with partial access)' {
    # A user at the console is asked. Anyone else gets $false with no prompt, so a headless run
    # stops exactly as it did before the prompt existed.
    It 'does not ask and returns false when <Case>' -ForEach @(
        @{ Case = 'the session is not interactive'; AccountType = 'User'; IsInteractive = $false }
        @{ Case = 'the sign-in is a service principal'; AccountType = 'ServicePrincipal'; IsInteractive = $true }
        @{ Case = 'the sign-in is a managed identity'; AccountType = 'ManagedService'; IsInteractive = $true }
        @{ Case = 'the sign-in type is unknown'; AccountType = ''; IsInteractive = $true }
    ) {
        Mock Read-Host { 'y' }
        Confirm-PartialAccessContinue -Question 'Continue?' -AccountType $AccountType -IsInteractive $IsInteractive | Should -BeFalse
        Should -Invoke Read-Host -Exactly -Times 0 -Because 'nobody can answer, so the run must stop without waiting for input'
    }

    It 'asks a user at the console once and returns <Expected> for the answer "<Answer>"' -ForEach @(
        @{ Answer = 'y'; Expected = $true }
        @{ Answer = 'Y'; Expected = $true }
        @{ Answer = 'yes'; Expected = $true }
        @{ Answer = 'YES'; Expected = $true }
        @{ Answer = ''; Expected = $false }
        @{ Answer = 'n'; Expected = $false }
        @{ Answer = 'no'; Expected = $false }
        @{ Answer = 'yes please'; Expected = $false }
    ) {
        $script:NextAnswer = $Answer
        Mock Read-Host { $script:NextAnswer }
        $Result = Confirm-PartialAccessContinue -Question 'Continue?' -AccountType 'User' -IsInteractive $true 6>$null
        $Result | Should -Be $Expected
        Should -Invoke Read-Host -Exactly -Times 1 -ParameterFilter { $Prompt -eq 'Continue? [y/N]' }
    }
}

Describe 'Run-AllSubscriptions.ps1: the partial-access stop points ask a user before stopping' {
    # Each stop point is lifted from the wrapper's parsed source and run as the wrapper runs it.
    # Headless runs must print exactly what they printed before and exit 1; a user who answers
    # yes continues the way -AllowPartialAccess would; -AllowPartialAccess and -Preflight never ask.
    BeforeAll {
        $Tokens = $null
        $ParseErrors = $null
        $WrapperAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $PSScriptRoot -Parent) 'Run-AllSubscriptions.ps1'), [ref]$Tokens, [ref]$ParseErrors)

        function Get-SingleWrapperIf
        {
            param([string]$Condition)
            $Found = @($WrapperAst.FindAll({ $args[0] -is [System.Management.Automation.Language.IfStatementAst] -and $args[0].Clauses[0].Item1.Extent.Text -eq $Condition }, $true))
            if ($Found.Count -ne 1) { throw ("expected exactly one 'if ({0})' in Run-AllSubscriptions.ps1, found {1}" -f $Condition, $Found.Count) }
            return $Found[0]
        }

        $CoverageIf = Get-SingleWrapperIf -Condition '$null -eq $Coverage.Ids'
        $script:CoverageBlock = [scriptblock]::Create($CoverageIf.Extent.Text)
        $script:ProbeBlock = [scriptblock]::Create((Get-SingleWrapperIf -Condition '$ScopeForProbe.Count -gt 0').Extent.Text)

        # The sign-in type every stop point passes on is read once, before the first of them.
        $script:AccountTypeAssignments = @($WrapperAst.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] -and $args[0].Left.Extent.Text -eq '$PartialAccessAccountType' }, $true))
        $script:CoverageIfStart = $CoverageIf.Extent.StartOffset

        # The real Exit-Wrapper ends the process; this stand-in turns the call into a result.
        function Exit-Wrapper { param([int]$Code) throw "Exit-Wrapper $Code" }

        # The wrapper variables a stop point reads, with a user signed in and three visible
        # subscriptions. $Override replaces or adds entries for one case.
        function New-StopPointVars
        {
            param([hashtable]$Override = @{})
            $Three = @(
                [pscustomobject]@{ Id = 's1'; Name = 'One' }
                [pscustomobject]@{ Id = 's2'; Name = 'Two' }
                [pscustomobject]@{ Id = 's3'; Name = 'Three' }
            )
            $Vars = @{
                AllowPartialAccess       = $false
                Preflight                = $false
                AllSubscriptions         = $Three
                Subscriptions            = $Three
                ScopeForProbe            = $Three
                PartialAccessAccountType = 'User'
            }
            foreach ($Key in $Override.Keys) { $Vars[$Key] = $Override[$Key] }
            return $Vars
        }

        # Runs a lifted stop point in this function's scope with $Vars as its variables, and
        # returns what it printed, the exit code it asked for (or $null) and the resulting
        # $Subscriptions.
        function Invoke-StopPoint
        {
            param([scriptblock]$Block, [hashtable]$Vars)
            foreach ($Name in $Vars.Keys) { Set-Variable -Name $Name -Value $Vars[$Name] }
            $Lines = [System.Collections.Generic.List[string]]::new()
            $ExitCode = $null
            try
            {
                . $Block 6>&1 | ForEach-Object { $Lines.Add([string]$_) }
            }
            catch
            {
                if ($_.Exception.Message -match '^Exit-Wrapper (\d+)$') { $ExitCode = [int]$Matches[1] } else { throw }
            }
            [pscustomobject]@{ Lines = @($Lines); ExitCode = $ExitCode; Subscriptions = @(Get-Variable -Name 'Subscriptions' -ValueOnly) }
        }

        $script:Unreadable = [pscustomobject]@{ Ids = $null; Detail = 'AuthorizationFailed' }
        $script:Shortfall = [pscustomobject]@{ Ids = @('s1', 's2', 's3', 's4', 's5'); Detail = $null }
    }

    It 'reads the sign-in type once, before the first stop point' {
        $script:AccountTypeAssignments.Count | Should -Be 1
        $script:AccountTypeAssignments[0].Extent.StartOffset | Should -BeLessThan $script:CoverageIfStart
    }

    Context 'tenant-root management group cannot be read' {
        It 'headless: prints what it always printed and exits 1' {
            $R = Invoke-StopPoint -Block $script:CoverageBlock -Vars (New-StopPointVars @{ Coverage = $script:Unreadable; PartialAccessAccountType = 'ServicePrincipal' })
            $R.ExitCode | Should -Be 1
            $R.Lines | Should -Be @(
                'ERROR: Could not verify full subscription coverage: the tenant-root management group (GroupName = tenant id) could not be read by this identity, so there is no way to confirm the 3 enumerated subscription(s) are ALL of them.'
                '  Reason: AuthorizationFailed'
                '  Grant the identity Reader at the tenant-root management group (it inherits to every subscription and makes coverage verifiable), then re-run.'
                '  (Or pass -AllowPartialAccess to proceed with only the subscriptions this identity can currently see.)'
            )
        }

        It 'a user who answers yes continues with the enumerated subscriptions' {
            Mock Confirm-PartialAccessContinue { $true }
            $R = Invoke-StopPoint -Block $script:CoverageBlock -Vars (New-StopPointVars @{ Coverage = $script:Unreadable })
            $R.ExitCode | Should -BeNullOrEmpty
            $R.Lines[-1] | Should -Be '  Confirmed at the prompt: continuing with the enumerated subscription(s), which may not be the full tenant.'
            ($R.Lines -join "`n") | Should -Not -Match 'Grant the identity'
            Should -Invoke Confirm-PartialAccessContinue -Exactly -Times 1 -ParameterFilter { $AccountType -eq 'User' -and $Question -eq 'Continue with the 3 subscription(s) this identity can see, which may not be the full tenant?' }
        }

        It 'a user who answers no gets the fix and exits 1' {
            Mock Confirm-PartialAccessContinue { $false }
            $R = Invoke-StopPoint -Block $script:CoverageBlock -Vars (New-StopPointVars @{ Coverage = $script:Unreadable })
            $R.ExitCode | Should -Be 1
            $R.Lines[-2] | Should -Match '^  Grant the identity Reader at the tenant-root management group'
            $R.Lines[-1] | Should -Match '^  \(Or pass -AllowPartialAccess'
        }

        It 'does not ask when <Switch> is set' -ForEach @(
            @{ Switch = 'AllowPartialAccess' }
            @{ Switch = 'Preflight' }
        ) {
            Mock Confirm-PartialAccessContinue { $false }
            $R = Invoke-StopPoint -Block $script:CoverageBlock -Vars (New-StopPointVars @{ Coverage = $script:Unreadable; $Switch = $true })
            $R.ExitCode | Should -BeNullOrEmpty
            Should -Invoke Confirm-PartialAccessContinue -Exactly -Times 0
        }
    }

    Context 'the management group lists subscriptions this identity cannot see' {
        It 'headless: prints what it always printed and exits 1' {
            $R = Invoke-StopPoint -Block $script:CoverageBlock -Vars (New-StopPointVars @{ Coverage = $script:Shortfall; PartialAccessAccountType = '' })
            $R.ExitCode | Should -Be 1
            $R.Lines | Should -Be @(
                'ERROR: Subscription coverage shortfall: the tenant-root management group contains 5 subscription(s) but this identity can enumerate only 3 - 2 would be SILENTLY MISSED from the inventory.'
                '  Missed: s4, s5'
                '  Grant the identity Reader at the tenant-root management group (it inherits to all subscriptions) instead of per-subscription, then re-run.'
                '  (Or pass -AllowPartialAccess to proceed with only the subscriptions this identity can currently see.)'
            )
        }

        It 'a user who answers yes continues with the visible subscriptions' {
            Mock Confirm-PartialAccessContinue { $true }
            $R = Invoke-StopPoint -Block $script:CoverageBlock -Vars (New-StopPointVars @{ Coverage = $script:Shortfall })
            $R.ExitCode | Should -BeNullOrEmpty
            $R.Lines[-1] | Should -Be '  Confirmed at the prompt: continuing with the 3 visible subscription(s).'
            Should -Invoke Confirm-PartialAccessContinue -Exactly -Times 1 -ParameterFilter { $Question -eq 'Continue with the 3 visible subscription(s) and leave the 2 missed subscription(s) out of the inventory?' }
        }

        It 'a user who answers no gets the fix and exits 1' {
            Mock Confirm-PartialAccessContinue { $false }
            $R = Invoke-StopPoint -Block $script:CoverageBlock -Vars (New-StopPointVars @{ Coverage = $script:Shortfall })
            $R.ExitCode | Should -Be 1
            $R.Lines[-1] | Should -Match '^  \(Or pass -AllowPartialAccess'
        }
    }

    Context 'the up-front access probe finds unreadable subscriptions' {
        BeforeEach {
            $script:Probed = @(
                [pscustomobject]@{ Id = 's1'; Name = 'One'; State = 'Empty' }
                [pscustomobject]@{ Id = 's2'; Name = 'Two'; State = 'NoAccess' }
                [pscustomobject]@{ Id = 's3'; Name = 'Three'; State = 'Empty' }
            )
            Mock Test-SubscriptionAccessAll { $script:Probed }
        }

        It 'headless: prints what it always printed and exits 1' {
            $R = Invoke-StopPoint -Block $script:ProbeBlock -Vars (New-StopPointVars @{ PartialAccessAccountType = 'ServicePrincipal' })
            $R.ExitCode | Should -Be 1
            $R.Lines | Should -Be @(
                'Verifying subscription access up front for 3 subscription(s)...'
                '  1 subscription(s) are NOT readable by the signed-in identity:'
                '    - Two (s2) - no role on the subscription'
                '  Stopping before any work. Grant the identity Reader on these subscriptions, then re-run.'
                '  (Or pass -AllowPartialAccess to skip them and inventory only the accessible subscriptions.)'
            )
        }

        It 'a user who answers yes skips them and continues with the readable ones' {
            Mock Confirm-PartialAccessContinue { $true }
            $R = Invoke-StopPoint -Block $script:ProbeBlock -Vars (New-StopPointVars)
            $R.ExitCode | Should -BeNullOrEmpty
            $R.Lines[-1] | Should -Be '  Confirmed at the prompt: skipping the above and continuing with the accessible subscription(s).'
            @($R.Subscriptions | ForEach-Object { $_.Id }) | Should -Be @('s1', 's3')
            Should -Invoke Confirm-PartialAccessContinue -Exactly -Times 1 -ParameterFilter { $Question -eq 'Skip the 1 unreadable subscription(s) and continue with the 2 readable one(s)?' }
        }

        It 'a user who answers no gets the fix and exits 1' {
            Mock Confirm-PartialAccessContinue { $false }
            $R = Invoke-StopPoint -Block $script:ProbeBlock -Vars (New-StopPointVars)
            $R.ExitCode | Should -Be 1
            $R.Lines[-2] | Should -Match '^  Stopping before any work'
        }

        It 'does not ask when no subscription would be left' {
            $script:Probed = @($script:Probed | ForEach-Object { [pscustomobject]@{ Id = $_.Id; Name = $_.Name; State = 'NoAccess' } })
            Mock Confirm-PartialAccessContinue { $true }
            $R = Invoke-StopPoint -Block $script:ProbeBlock -Vars (New-StopPointVars)
            $R.ExitCode | Should -Be 1
            $R.Lines[-2] | Should -Match '^  Stopping before any work'
            Should -Invoke Confirm-PartialAccessContinue -Exactly -Times 0
        }

        It 'does not ask when -AllowPartialAccess is set, and says so' {
            Mock Confirm-PartialAccessContinue { $false }
            $R = Invoke-StopPoint -Block $script:ProbeBlock -Vars (New-StopPointVars @{ AllowPartialAccess = $true })
            $R.ExitCode | Should -BeNullOrEmpty
            $R.Lines[-1] | Should -Be '  -AllowPartialAccess set: skipping the above and continuing with the accessible subscription(s).'
            Should -Invoke Confirm-PartialAccessContinue -Exactly -Times 0
        }
    }
}

Describe 'Invoke-RdaSupportLogCollectionInTranscript (support-log lines reach the reopened transcript)' {
    BeforeEach {
        $script:Tr = Join-Path $script:TestRoot ('transcript_{0}.txt' -f [guid]::NewGuid().ToString('N'))
    }
    AfterEach {
        # A helper that left the reopened transcript running would otherwise record the rest of the suite.
        if (script:Test-OwnTranscriptOpen $script:Tr) { Stop-Transcript | Out-Null }
    }

    It 'writes the held lines once, in order and colour, and appends them to the closed transcript' {
        Start-Transcript -LiteralPath $script:Tr -UseMinimalHeader -Force | Out-Null
        Write-Host 'last line before the stop'
        Stop-Transcript | Out-Null
        Mock Invoke-RdaSupportLogCollection {
            Write-Host 'Support logs collected: /x/SupportLogs_Run.zip' -ForegroundColor Cyan
            Write-Host '  plain line'
        }

        $Records = @(Invoke-RdaSupportLogCollectionInTranscript -TranscriptStarted -TranscriptFile $script:Tr -InventoryRoot 'root' -SinceTime (Get-Date) 6>&1)

        @($Records | ForEach-Object { [string]$_.MessageData.Message }) | Should -Be @('Support logs collected: /x/SupportLogs_Run.zip', '  plain line')
        $Records[0].MessageData.ForegroundColor | Should -Be 'Cyan'
        $Plain = @(Write-Host 'x' 6>&1)[0].MessageData.ForegroundColor
        $Records[1].MessageData.ForegroundColor | Should -Be $Plain -Because 'Write-Host without -ForegroundColor records the host colour: -1 on macOS and Linux, the console colour on Windows'
        $Text = Get-Content -LiteralPath $script:Tr -Raw
        $Text.IndexOf('last line before the stop') | Should -BeGreaterOrEqual 0
        $Text.IndexOf('last line before the stop') | Should -BeLessThan $Text.IndexOf('Support logs collected: /x/SupportLogs_Run.zip')
        $Text | Should -Match '  plain line'
        (script:Test-OwnTranscriptOpen $script:Tr) | Should -BeFalse -Because 'the reopened transcript must be closed again before the run exits'
    }

    It 'still writes the lines, and creates no transcript, when none was started' {
        Mock Invoke-RdaSupportLogCollection { Write-Host 'Support logs collected: /x/b.zip' }
        $Lines = @(Invoke-RdaSupportLogCollectionInTranscript -TranscriptFile $script:Tr -InventoryRoot 'root' -SinceTime (Get-Date) 6>&1 | ForEach-Object { [string]$_ })
        $Lines | Should -Be @('Support logs collected: /x/b.zip')
        Test-Path -LiteralPath $script:Tr | Should -BeFalse
    }

    It 'does not reopen the transcript when the step printed nothing' {
        Set-Content -LiteralPath $script:Tr -Value 'closed transcript'
        Mock Invoke-RdaSupportLogCollection { }
        Invoke-RdaSupportLogCollectionInTranscript -TranscriptStarted -TranscriptFile $script:Tr -InventoryRoot 'root' -SinceTime (Get-Date) 6>$null
        (Get-Content -LiteralPath $script:Tr -Raw).Trim() | Should -BeExactly 'closed transcript'
    }

    It 'reports through -Outcome whether it listed a support bundle' {
        Mock Invoke-RdaSupportLogCollection { Write-Host 'Support logs collected: /x/c.zip' }
        $Listed = @{}
        Invoke-RdaSupportLogCollectionInTranscript -TranscriptFile $script:Tr -InventoryRoot 'root' -SinceTime (Get-Date) -Outcome $Listed 6>$null
        $Listed['Listed'] | Should -BeExactly $true

        Mock Invoke-RdaSupportLogCollection { }
        $Quiet = @{}
        Invoke-RdaSupportLogCollectionInTranscript -TranscriptFile $script:Tr -InventoryRoot 'root' -SinceTime (Get-Date) -Outcome $Quiet 6>$null
        $Quiet['Listed'] | Should -BeExactly $false
    }
}

Describe 'Write-RdaHostLinesInTranscript (lines printed after the stop still reach the transcript)' {
    BeforeEach {
        $script:Tr = Join-Path $script:TestRoot ('transcript_{0}.txt' -f [guid]::NewGuid().ToString('N'))
    }
    AfterEach {
        if (script:Test-OwnTranscriptOpen $script:Tr) { Stop-Transcript | Out-Null }
    }

    It 'writes the lines in order and colour, appends them to the closed transcript, then closes it again' {
        Start-Transcript -LiteralPath $script:Tr -UseMinimalHeader -Force | Out-Null
        Write-Host 'last line before the stop'
        Stop-Transcript | Out-Null
        $FinalLines = @(
            [pscustomobject]@{ Text = 'RUN COMPLETE - EXIT CODE 0.'; Color = 'Green' }
            [pscustomobject]@{ Text = '  plain line'; Color = $null }
        )

        $Records = @(Write-RdaHostLinesInTranscript -Lines $FinalLines -TranscriptStarted -TranscriptFile $script:Tr 6>&1)

        @($Records | ForEach-Object { [string]$_.MessageData.Message }) | Should -Be @('RUN COMPLETE - EXIT CODE 0.', '  plain line')
        $Records[0].MessageData.ForegroundColor | Should -Be 'Green'
        $Plain = @(Write-Host 'x' 6>&1)[0].MessageData.ForegroundColor
        $Records[1].MessageData.ForegroundColor | Should -Be $Plain -Because 'Write-Host without -ForegroundColor records the host colour: -1 on macOS and Linux, the console colour on Windows'
        $Text = Get-Content -LiteralPath $script:Tr -Raw
        $Text.IndexOf('last line before the stop') | Should -BeGreaterOrEqual 0
        $Text.IndexOf('last line before the stop') | Should -BeLessThan $Text.IndexOf('RUN COMPLETE - EXIT CODE 0.')
        $Text | Should -Match '  plain line'
        (script:Test-OwnTranscriptOpen $script:Tr) | Should -BeFalse -Because 'the reopened transcript must be closed again before the run exits'
    }

    It 'still writes the lines, and creates no transcript, when none was kept' {
        $Out = @(Write-RdaHostLinesInTranscript -Lines @([pscustomobject]@{ Text = 'only line'; Color = 'Red' }) -TranscriptFile $script:Tr 6>&1 | ForEach-Object { [string]$_ })
        $Out | Should -Be @('only line')
        Test-Path -LiteralPath $script:Tr | Should -BeFalse
    }
}

Describe 'Test-RdaFinalScreenClearable (clear only when nothing is lost)' {
    It 'returns <Expected> for console=<IsConsole>, bundle=<BundleBuilt>, transcript=<TranscriptKept>' -ForEach @(
        @{ IsConsole = $true; BundleBuilt = $true; TranscriptKept = $true; Expected = $true }
        @{ IsConsole = $false; BundleBuilt = $true; TranscriptKept = $true; Expected = $false }
        @{ IsConsole = $true; BundleBuilt = $false; TranscriptKept = $true; Expected = $false }
        @{ IsConsole = $true; BundleBuilt = $true; TranscriptKept = $false; Expected = $false }
    ) {
        Test-RdaFinalScreenClearable -BundleBuilt $BundleBuilt -TranscriptKept $TranscriptKept -IsConsole $IsConsole | Should -Be $Expected
    }
}

Describe 'Get-RdaFinalScreenLines (outcome first, then one file to send)' {
    BeforeAll {
        $script:Bundle = '/Users/Someone/InventoryReports/AllSubscriptions_Run.zip'
        $script:Transcript = '/Users/Someone/InventoryReports/RunAllSubscriptions_transcript_Run.txt'
        function Get-FinalText
        {
            param([hashtable]$Params)
            $Base = @{ ExitCode = 0; HasWarnings = $false; TranscriptFile = $script:Transcript; TranscriptKept = $true; BundleFile = $script:Bundle; InventoryFolderName = 'InventoryReports' }
            foreach ($Key in $Params.Keys) { $Base[$Key] = $Params[$Key] }
            @(Get-RdaFinalScreenLines @Base)
        }
    }

    It 'a clean run: outcome, the one file, and the folder warning' {
        $Lines = Get-FinalText @{}
        @($Lines | ForEach-Object { $_.Text }) | Should -Be @(
            'RUN COMPLETE - EXIT CODE 0.'
            ('SEND THIS ONE FILE:  {0}' -f $script:Bundle)
            '  DO NOT ZIP OR SEND THE InventoryReports FOLDER ITSELF. IT HOLDS FILES THAT MUST STAY LOCAL.'
        )
        $Lines[0].Color | Should -Be 'Green'
    }

    It 'opens with <Outcome> and points at the transcript for exit code <ExitCode>, warnings <HasWarnings>' -ForEach @(
        @{ ExitCode = 0; HasWarnings = $true; Outcome = 'RUN COMPLETE WITH WARNINGS - EXIT CODE 0.'; Color = 'Yellow' }
        @{ ExitCode = 2; HasWarnings = $false; Outcome = 'RUN FINISHED WITH FAILURES - EXIT CODE 2.'; Color = 'Red' }
        @{ ExitCode = 5; HasWarnings = $true; Outcome = 'RUN FINISHED WITH FAILURES - EXIT CODE 5.'; Color = 'Red' }
    ) {
        $Lines = Get-FinalText @{ ExitCode = $ExitCode; HasWarnings = $HasWarnings }
        $Lines[0].Text | Should -BeExactly $Outcome
        $Lines[0].Color | Should -Be $Color
        $Lines[1].Text | Should -BeExactly ('THE DETAILS ARE IN THE TRANSCRIPT: {0}' -f $script:Transcript)
        @($Lines | Where-Object { $_.Text -like 'SEND THIS ONE FILE:*' }).Count | Should -Be 1 -Because 'the final screen carries one upload instruction'
    }

    It 'says to scroll up when the transcript was not kept' {
        $Lines = Get-FinalText @{ ExitCode = 2; TranscriptKept = $false }
        $Lines[1].Text | Should -BeExactly 'SCROLL UP FOR THE DETAILS.'
    }

    It 'says there is nothing to send when no bundle was produced' {
        $Lines = Get-FinalText @{ ExitCode = 2; BundleFile = '' }
        $Lines[-1].Text | Should -BeExactly 'NO REPORT BUNDLE WAS PRODUCED, SO THERE IS NO FILE TO SEND.'
        @($Lines | Where-Object { $_.Text -like 'SEND THIS ONE FILE:*' }).Count | Should -Be 0
    }

    It 'names the shard when the run is one of several' {
        $Lines = Get-FinalText @{ ShardIndex = 2; ShardCount = 3 }
        $Lines[2].Text | Should -BeExactly "  THIS IS SHARD 2 OF 3 AND COVERS ONLY THIS NODE'S SUBSCRIPTIONS. SEND ONE SUCH FILE FROM EVERY SHARD."
    }

    It 'writes every instruction in capitals and keeps the case of paths and the folder name' {
        $Lines = Get-FinalText @{ ExitCode = 2; ShardIndex = 1; ShardCount = 2 }
        foreach ($Line in $Lines)
        {
            $Instruction = $Line.Text.Replace($script:Bundle, '').Replace($script:Transcript, '').Replace('InventoryReports', '')
            $Instruction | Should -BeExactly $Instruction.ToUpperInvariant()
        }
        ($Lines.Text -join "`n") | Should -Match ([regex]::Escape($script:Bundle))
    }

    It 'says a support log bundle still listed above is only for support, and still names one file to send' {
        $Lines = Get-FinalText @{ ExitCode = 2; SupportBundleListed = $true }
        @($Lines | Where-Object { $_.Text -like 'SEND THIS ONE FILE:*' }).Count | Should -Be 1
        $Lines[-1].Text | Should -BeExactly '  THE SUPPORT LOG BUNDLE LISTED ABOVE IS ONLY FOR SUPPORT. SEND IT ONLY IF SUPPORT ASKS FOR IT.'
    }

    It 'points at the support log bundle listed above when no report bundle was produced' {
        $Lines = Get-FinalText @{ ExitCode = 2; BundleFile = ''; SupportBundleListed = $true }
        $Lines[-1].Text | Should -BeExactly 'NO REPORT BUNDLE WAS PRODUCED. SEND THE SUPPORT LOG BUNDLE LISTED ABOVE TO SUPPORT INSTEAD.'
        @($Lines | Where-Object { $_.Text -like '*NO FILE TO SEND*' }).Count | Should -Be 0
    }
}

Describe 'Run-AllSubscriptions.ps1: the final screen comes last and the support-log step writes into the transcript' {
    BeforeAll {
        $Root = Split-Path $PSScriptRoot -Parent
        $script:WrapperLines = Get-Content -LiteralPath (Join-Path $Root 'Run-AllSubscriptions.ps1')
        $Tokens = $null
        $ParseErrors = $null
        $script:WrapperAstForFinal = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Root 'Run-AllSubscriptions.ps1'), [ref]$Tokens, [ref]$ParseErrors)
        $FunctionsAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Root 'Functions/RunAllSubscriptions.Functions.ps1'), [ref]$Tokens, [ref]$ParseErrors)
        $script:ExitWrapperAst = $FunctionsAst.Find({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'Exit-Wrapper' }, $true)

        function Get-CommandLine
        {
            param($Ast, [string]$Name)
            @($Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] -and $args[0].GetCommandName() -eq $Name }, $true) | ForEach-Object { $_.Extent.StartLineNumber })
        }
    }

    It 'the wrapper runs the support-log step only through the transcript-aware helper' {
        @(Get-CommandLine -Ast $script:WrapperAstForFinal -Name 'Invoke-RdaSupportLogCollection').Count | Should -Be 0
        @(Get-CommandLine -Ast $script:WrapperAstForFinal -Name 'Invoke-RdaSupportLogCollectionInTranscript').Count | Should -Be 1
    }

    It 'stops the transcript, runs the support-log step, then clears and prints the final block, then exits' {
        $StopIdx = ($script:WrapperLines | Select-String -SimpleMatch 'Stop-Transcript on normal completion failed' | Select-Object -First 1).LineNumber
        $SupportIdx = @(Get-CommandLine -Ast $script:WrapperAstForFinal -Name 'Invoke-RdaSupportLogCollectionInTranscript')[0]
        $LastCodeIdx = ($script:WrapperLines | Select-String -Pattern '^\s*\$WrapperExitCode = 2\s*$' | Select-Object -Last 1).LineNumber
        $ClearIdx = @(Get-CommandLine -Ast $script:WrapperAstForFinal -Name 'Clear-Host')
        $FinalIdx = @(Get-CommandLine -Ast $script:WrapperAstForFinal -Name 'Get-RdaFinalScreenLines')
        $ExitIdx = ($script:WrapperLines | Select-String -Pattern '^exit \$WrapperExitCode\s*$' | Select-Object -Last 1).LineNumber

        # A null index on the left of -BeLessThan passes ($null -ge N is false), so every anchor must be found first.
        $StopIdx | Should -Not -BeNullOrEmpty -Because 'the normal-completion Stop-Transcript anchor must be found, or the ordering below is not checked'
        $SupportIdx | Should -Not -BeNullOrEmpty -Because 'the support-log step must be found, or the ordering below is not checked'
        $LastCodeIdx | Should -Not -BeNullOrEmpty
        $ExitIdx | Should -Not -BeNullOrEmpty
        $ClearIdx.Count | Should -Be 1
        $FinalIdx.Count | Should -Be 1
        $StopIdx | Should -BeLessThan $SupportIdx
        $SupportIdx | Should -BeLessThan $LastCodeIdx
        $LastCodeIdx | Should -BeLessThan $ClearIdx[0] -Because 'the outcome line needs the final exit code'
        $ClearIdx[0] | Should -BeLessThan $FinalIdx[0]
        $FinalIdx[0] | Should -BeLessThan $ExitIdx
    }

    It 'clears the screen only when Test-RdaFinalScreenClearable allows it' {
        $ClearIf = $script:WrapperAstForFinal.Find({ $args[0] -is [System.Management.Automation.Language.IfStatementAst] -and $args[0].Clauses[0].Item2.Extent.Text -match 'Clear-Host' }, $true)
        $ClearIf | Should -Not -BeNullOrEmpty
        $ClearIf.Clauses[0].Item1.Extent.Text | Should -Match '^Test-RdaFinalScreenClearable '
    }

    It 'Exit-Wrapper stops the transcript before the support-log step and never clears the screen' {
        $script:ExitWrapperAst | Should -Not -BeNullOrEmpty
        $Stop = @(Get-CommandLine -Ast $script:ExitWrapperAst -Name 'Stop-Transcript')
        $Support = @(Get-CommandLine -Ast $script:ExitWrapperAst -Name 'Invoke-RdaSupportLogCollectionInTranscript')
        $Stop.Count | Should -Be 1
        $Support.Count | Should -Be 1
        $Stop[0] | Should -BeLessThan $Support[0]
        @(Get-CommandLine -Ast $script:ExitWrapperAst -Name 'Invoke-RdaSupportLogCollection').Count | Should -Be 0
        @(Get-CommandLine -Ast $script:ExitWrapperAst -Name 'Clear-Host').Count | Should -Be 0
    }

    It 'writes the final block with the transcript reopened, and tells it whether the support bundle is still on screen' {
        $FindCommand = {
            param([string]$Name)
            @($script:WrapperAstForFinal.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] -and $args[0].GetCommandName() -eq $Name }, $true))
        }
        $SupportCmd = @(& $FindCommand 'Invoke-RdaSupportLogCollectionInTranscript')
        $FinalCmd = @(& $FindCommand 'Get-RdaFinalScreenLines')
        $WriteCmd = @(& $FindCommand 'Write-RdaHostLinesInTranscript')
        $ExitIdx = ($script:WrapperLines | Select-String -Pattern '^exit \$WrapperExitCode\s*$' | Select-Object -Last 1).LineNumber

        $WriteCmd.Count | Should -Be 1
        $FinalCmd[0].Extent.StartLineNumber | Should -BeLessThan $WriteCmd[0].Extent.StartLineNumber
        $WriteCmd[0].Extent.StartLineNumber | Should -BeLessThan $ExitIdx
        $WriteCmd[0].Extent.Text | Should -Match '-TranscriptStarted:\$FinalTranscriptKept'
        $SupportCmd[0].Extent.Text | Should -Match '-Outcome \$SupportLogOutcome'
        $FinalCmd[0].Extent.Text | Should -Match '-SupportBundleListed \(\$SupportLogOutcome\[''Listed''\] -and -not \$FinalScreenCleared\)'
        @($script:WrapperLines | Select-String -SimpleMatch 'Write-Host $FinalLine.Text').Count | Should -Be 0 -Because 'the final block is written only through the transcript-aware helper'
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
        $script:MarketplaceSkips = @([pscustomobject]@{ Name = 'Northwind-Marketplace'; Id = '55555555-5555-5555-5555-555555555555'; Message = 'marketplace pull incomplete for Northwind' })
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

    It 'renders the Marketplace records-collected line and failed-subs count in the Health block' {
        # Marketplace must have full parity with Consumption/Metrics in the shareable
        # RunSummary.log: a records-collected line and a failed-subs count.
        $Lines = Get-RunSummaryLogContent `
            -Visible 5 -Excluded 1 -Eligible 4 -Processed 3 -Skipped 0 `
            -MarketplaceRecordCount 42 -MarketplaceFailedSubs $script:MarketplaceSkips `
            -ConsumptionRecordCount 100
        $Text = ($Lines -join "`n")

        $Text | Should -Match 'Marketplace records collected\s+:\s+42'
        $Text | Should -Match 'Marketplace failed subs\s+:\s+1'
    }

    It 'renders n/a for Marketplace records when Marketplace was not requested' {
        $Lines = Get-RunSummaryLogContent `
            -Visible 5 -Excluded 1 -Eligible 4 -Processed 3 -Skipped 0 `
            -MarketplaceRequested:$false -MarketplaceRecordCount 0
        $Text = ($Lines -join "`n")

        $Text | Should -Match 'Marketplace records collected\s+:\s+n/a'
    }

    It 'non-obfuscated run includes the Marketplace failed-subscription detail line' {
        $Lines = Get-RunSummaryLogContent `
            -Visible 5 -Excluded 1 -Eligible 4 -Processed 3 -Skipped 0 `
            -MarketplaceFailedSubs $script:MarketplaceSkips
        $Text = ($Lines -join "`n")

        $Text | Should -Match 'Marketplace failed subscriptions \(detail\):'
        $Text | Should -Match 'Northwind-Marketplace'
        $Text | Should -Match 'marketplace pull incomplete for Northwind'
    }

    It 'obfuscated run emits Marketplace counts only - no names, ids, or raw messages' {
        $Lines = Get-RunSummaryLogContent -Obfuscated `
            -Visible 5 -Excluded 1 -Eligible 4 -Processed 3 -Skipped 0 `
            -MarketplaceRecordCount 42 -MarketplaceFailedSubs $script:MarketplaceSkips
        $Text = ($Lines -join "`n")

        $Text | Should -Not -Match 'Northwind-Marketplace'
        $Text | Should -Not -Match '55555555-5555-5555-5555-555555555555'
        $Text | Should -Not -Match 'marketplace pull incomplete'
        $Text | Should -Not -Match 'Marketplace failed subscriptions \(detail\):'
        $Text | Should -Match 'Marketplace failed subs\s+:\s+1'
        $Text | Should -Match 'Marketplace records collected\s+:\s+42'
    }

    It 'renders STRING-shaped failed subscriptions, the shape production actually passes' {
        # Pins the STRING shape production actually passes: the renderer once read only .Name/.Id (both $null on a
        # string), rendering every failed sub as '  - ()'; object-shaped fixtures hid it. Last element is an Id-only object for the ToString() fallback.
        $StringShaped = @(
            'Contoso-Prod-Sub'
            'stream-2 (no summary)'
            'Fabrikam-Locked (stream-1: boom)'
            [pscustomobject]@{ Id = '44444444-4444-4444-4444-444444444444' }
        )
        $Lines = Get-RunSummaryLogContent `
            -Visible 5 -Excluded 1 -Eligible 4 -Processed 4 -Skipped 0 `
            -FailedSubscriptions $StringShaped
        $Text = ($Lines -join "`n")

        $Text | Should -Match 'Failed subscriptions\s+:\s+4'
        # Each must appear on its own detail line. The inner separators are [^\S\r\n]*
        # rather than \s* on purpose: \s* matches a newline, which would let a bare '-' on
        # one line and the name on the next satisfy these. The trailing \s*$ is kept - it
        # cannot swallow a same-line '(id)' and it keeps the assertion CRLF-safe.
        $Text | Should -Match '(?m)^[^\S\r\n]*-[^\S\r\n]*Contoso-Prod-Sub\s*$'
        $Text | Should -Match '(?m)^[^\S\r\n]*-[^\S\r\n]*stream-2 \(no summary\)\s*$'
        $Text | Should -Match '(?m)^[^\S\r\n]*-[^\S\r\n]*Fabrikam-Locked \(stream-1: boom\)\s*$'
        # The no-Name object falls back to its own ToString() rather than rendering blank.
        $Text | Should -Match '(?m)^[^\S\r\n]*-[^\S\r\n]*\S.*44444444-4444-4444-4444-444444444444'
        # And the defect itself must be gone. Widened to \(\s*\) so a near-miss variant of
        # the empty pair is caught too, though the positives above are what actually fail
        # on a revert.
        $Text | Should -Not -Match '(?m)^\s*-\s*\(\s*\)\s*$' -Because 'a failed-subscription line must never render as an empty pair'
        # No detail line may be blank either - the other way the fallback could regress.
        $Text | Should -Not -Match '(?m)^[^\S\r\n]*-[^\S\r\n]*$' -Because 'a failed-subscription line must always name something'
    }

    It 'keeps string-shaped failed subscriptions out of an OBFUSCATED run' {
        # The string shape carries a real subscription name directly rather than behind a
        # .Name property, so the fix above must not have opened a leak: the detail block
        # is gated on -not $Obfuscated, and only the COUNT may survive.
        $StringShaped = @('Contoso-Prod-Sub', 'Fabrikam-Locked (stream-1: boom)')
        $Lines = Get-RunSummaryLogContent -Obfuscated `
            -Visible 5 -Excluded 1 -Eligible 4 -Processed 3 -Skipped 0 `
            -FailedSubscriptions $StringShaped
        $Text = ($Lines -join "`n")

        $Text | Should -Not -Match 'Contoso'
        $Text | Should -Not -Match 'Fabrikam'
        $Text | Should -Not -Match 'stream-1'
        # Pins the -not $Obfuscated gate DIRECTLY rather than inferring it from three
        # substrings: shape-independent, and immune to a future name colliding with
        # unrelated summary wording.
        $Text | Should -Not -Match 'Failed subscriptions \(detail\):'
        $Text | Should -Match 'Failed subscriptions\s+:\s+2'
    }

    It 'drops target identifiers from the parameter list but keeps allowlisted tuning knobs' {
        $Params = @{
            TenantID               = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
            SubscriptionID         = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
            InventoryRoot          = '/home/someone/InventoryReports'
            SkipConsumption        = [switch]$true
            ParallelStreams        = 4
            MetricsIntervalMinutes = 60
            MetricsLookbackDays    = 30
        }
        $Text = (Get-RunSummaryLogContent -InvocationParameters $Params -Obfuscated) -join "`n"

        $Text | Should -Not -Match 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        $Text | Should -Not -Match 'bbbbbbbb-bbbb'
        $Text | Should -Not -Match '/home/someone'
        $Text | Should -Match '-SkipConsumption'
        # Allowlisted tuning knobs keep their value even under obfuscation. Asserting a
        # METRIC knob too, so trimming $SafeValueParamNames back cannot silently regress
        # -MetricsLookbackDays to '<value omitted>' with the suite still green.
        $Text | Should -Match '-ParallelStreams 4'
        $Text | Should -Match '-MetricsIntervalMinutes 60'
        $Text | Should -Match '-MetricsLookbackDays 30'
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
                -MetricsFailedSubs $null -ConsumptionFailedSubs $null -MemoryReadings $null } | Should -Not -Throw
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
    # Covers only the platform-agnostic contract: the real trigger (Start-Job throwing under a Windows WDAC/AppLocker
    # ConstrainedLanguage policy) is Windows-only, so the non-Windows runner takes the early return; the $false path is tested out-of-band.
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

# Get-CompletedSubscriptionIds/Get-FailedAttempts/Get-StartSnapshot each read the resume state themselves; -State lets
# one read serve all three (avoiding a blob re-download per reader). No-read is proven via an absent -Path plus a mock with a positive control.
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

    # The only UNMOCKED proof the self-read projects correct data off a real file;
    # the mocked siblings only prove the read was dispatched, so this is not redundant.
    It 'still reads for itself when -State is OMITTED, so that shape stays valid' {
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

# Source+behaviour guards for the packaging seam where a swallowed Compress-Archive failure shipped a bundle one report short.
# Load-bearing: $LASTEXITCODE is shared/sticky (reset before each `&`) and a failed sub is excluded from the archive count, so only the exit-code override catches the loss.

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
    # The gate's two classification statements are inline in the wrapper body, which cannot be
    # dot-sourced, so they are lifted from Run-AllSubscriptions.ps1's AST and executed as-is. A change
    # to either statement in the wrapper is therefore what these tests run; there is no copy to drift.
    BeforeAll {
        $TmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { '/tmp' }
        $script:ZipRoot = Join-Path $TmpBase ("ArchiveVerifyTest_" + [guid]::NewGuid().ToString().Substring(0, 8))
        New-Item -ItemType Directory -Path $script:ZipRoot -Force | Out-Null
        $script:PresentZip = Join-Path $script:ZipRoot 'ResourcesReport_present.zip'
        Set-Content -LiteralPath $script:PresentZip -Value 'x' -Encoding utf8
        $script:AbsentZip = Join-Path $script:ZipRoot 'ResourcesReport_absent.zip'

        $Tokens = $null
        $ParseErrors = $null
        $VerifyAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $PSScriptRoot -Parent) 'Run-AllSubscriptions.ps1'), [ref]$Tokens, [ref]$ParseErrors)
        $script:VerifyStatements = foreach ($Var in @('$MissingSubs', '$UnverifiableSubs'))
        {
            $Found = @($VerifyAst.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] -and $args[0].Left.Extent.Text -eq $Var }, $true))
            if ($Found.Count -ne 1) { throw "Expected exactly one '$Var = ...' statement in Run-AllSubscriptions.ps1, found $($Found.Count)." }
            $Found[0].Extent.Text
        }

        # Runs the REAL shared predicate (Test-ReportArchiveUsable, dot-sourced by the BeforeAll at the
        # top of this file) through the wrapper's own two statements.
        $script:SplitBlock = [scriptblock]::Create(
            "param(`$SubResourceCounts)`n" + ($script:VerifyStatements -join "`n") + "`n@{ Missing = `$MissingSubs; Unverifiable = `$UnverifiableSubs }")
        function script:Split-VerificationRows
        {
            param($Rows)
            return (& $script:SplitBlock $Rows)
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

# Source guard: only Split-BlobContainerUri may parse a container URI - duplicate inline copies drift and silently write blobs to the wrong prefix.
# deploy/Test-NodeReadiness.ps1 keeps its own copy deliberately (it dot-sources nothing) and is out of scope; behavioural tests can't reach the inline upload blocks.
Describe 'Blob container URI parsing has one owner in the wrapper and its shared functions' {

    BeforeAll {
        $script:UriRepoRoot = Split-Path $PSScriptRoot -Parent

        # Strip comments before matching (the guard's own comments name the banned patterns, so a line filter would self-trap);
        # parser-based to catch trailing and block comments, and fails loud on empty/unparseable so the Should -Not -Match bans can't pass vacuously.
        function Get-CodeOnly
        {
            param([string]$Path)

            if (-not (Test-Path -LiteralPath $Path)) { throw "Get-CodeOnly: source file not found: $Path" }

            $Tokens = $null
            $ParseErrors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$Tokens, [ref]$ParseErrors)
            if ($ParseErrors -and $ParseErrors.Count -gt 0) { throw "Get-CodeOnly: $Path does not parse: $($ParseErrors[0].Message)" }

            # Excise comment extents from the raw text rather than re-joining code tokens (which would alter whitespace and break the searched patterns);
            # walk backwards so each removal cannot invalidate the offsets not yet processed.
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
        # Exactly three call sites (state setup, upload write probe, real upload): the probe and upload must parse
        # identically, or the probe confirms access to a location the upload never uses.
        $Calls = @([regex]::Matches($script:UriWrapperSrc, 'Split-BlobContainerUri\s+-Uri'))

        $Calls.Count | Should -Be 3 -Because 'the state path, the upload write probe and the upload itself must all go through the one parser'
    }

    # Structure-only guard: no behavioural equivalence test, because its oracle would be character-identical to
    # Split-BlobContainerUri (comparing an expression with itself, never failing). Its behaviour is pinned in Tests/BlobStateReconciliation.Tests.ps1.
}

Describe 'Resume-state completed-ids seed array-ness (regression: null-collapse -> string concat)' {

    # An empty array captured from a FUNCTION CALL collapses to $null on assignment,
    # so an unwrapped `$CompletedIds = Get-CompletedSubscriptionIds ...` left $null on
    # a fresh run; the loop's `$CompletedIds += $Sub.Id` then string-concatenated
    # instead of array-appending, mashing every id into one string and silently
    # breaking -Resume (its -contains never matched). The @(...) wrap fixes it; these
    # lock in both the behaviour and the source form.

    It 'seeds a fresh-run (absent-file) completed list as an array so += appends instead of concatenating' {
        $AbsentPath = Join-Path $script:TestRoot ('no-such-state-' + [guid]::NewGuid().ToString('N') + '.json')
        # Mirror the wrapper's FIXED seed expression.
        $CompletedIds = @(Get-CompletedSubscriptionIds -Path $AbsentPath -Tenant 'tenant-fresh')
        $CompletedIds += 'sub-a'
        $CompletedIds += 'sub-b'
        @($CompletedIds).Count | Should -Be 2 -Because 'each += must append a distinct element, not concatenate a string'
        ($CompletedIds -join '|') | Should -Be 'sub-a|sub-b'
        ($CompletedIds -contains 'sub-a') | Should -BeTrue -Because '-Resume relies on -contains matching each completed id'
    }

    It 'keeps the @(...) wrap on the completed-ids seed in Run-AllSubscriptions.ps1 (guards against reverting the fix)' {
        $WrapperPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Run-AllSubscriptions.ps1'
        Test-Path -LiteralPath $WrapperPath | Should -BeTrue
        # Match CODE lines only (drop whole-line comments) so an explanatory comment
        # showing the unwrapped form can't false-fail the negative guard. The prefix
        # anchor accepts the seed's trailing args (@StateBlobArgs -State $SeedState).
        $CodeText = ((Get-Content -LiteralPath $WrapperPath) | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
        ($CodeText -match '\$CompletedIds\s*=\s*@\(\s*Get-CompletedSubscriptionIds') | Should -BeTrue -Because 'the completed-ids seed must be @()-wrapped so an empty result stays an array'
        ($CodeText -match '\$CompletedIds\s*=\s*Get-CompletedSubscriptionIds') | Should -BeFalse -Because 'an unwrapped seed collapses @() to $null on a fresh run and breaks -Resume'
    }
}

# Marketplace phase must have full health-plumbing PARITY with Consumption/Metrics across
# the wrapper+stream seam: MarketplaceRecords sum into the run-wide count and
# MarketplaceFailedSubs concatenate across streams. The aggregation loop is inline in the
# wrapper body (not dot-sourceable), so its two Marketplace statements are lifted from the
# wrapper's AST and executed against in-memory stream summaries, with the run-wide globals
# rebound to locals so the test leaves no global state behind.
Describe 'Marketplace stream/wrapper health parity' {
    BeforeAll {
        $Tokens = $null
        $ParseErrors = $null
        $MergeAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $PSScriptRoot -Parent) 'Run-AllSubscriptions.ps1'), [ref]$Tokens, [ref]$ParseErrors)
        $MergeStatements = foreach ($Condition in @('$null -ne $StreamSummary.MarketplaceRecords', '$StreamSummary.MarketplaceFailedSubs -and $StreamSummary.MarketplaceFailedSubs.Count -gt 0'))
        {
            $Found = @($MergeAst.FindAll({ $args[0] -is [System.Management.Automation.Language.IfStatementAst] -and $args[0].Clauses[0].Item1.Extent.Text -eq $Condition }, $true))
            if ($Found.Count -ne 1) { throw "Expected exactly one 'if ($Condition)' merge statement in Run-AllSubscriptions.ps1, found $($Found.Count)." }
            $Found[0].Extent.Text -replace '\$Global:', '$'
        }
        $script:MergeBlock = [scriptblock]::Create(
            "param(`$StreamSummaries)`n`$MarketplaceRecordCount = `$null`n`$MarketplaceFailedSubs = `$null`n" +
            "foreach (`$StreamSummary in `$StreamSummaries)`n{`n" + ($MergeStatements -join "`n") + "`n}`n" +
            "@{ RecordCount = [int]`$MarketplaceRecordCount; FailedSubs = @(if (`$null -ne `$MarketplaceFailedSubs) { `$MarketplaceFailedSubs }) }")

        # Runs the wrapper's own per-stream Marketplace merge.
        function script:Merge-StreamMarketplace
        {
            param($StreamSummaries)
            return (& $script:MergeBlock $StreamSummaries)
        }
    }

    It 'sums MarketplaceRecords and concatenates MarketplaceFailedSubs across streams' {
        $Streams = @(
            [pscustomobject]@{ MarketplaceRecords = 10; MarketplaceFailedSubs = @([pscustomobject]@{ Name = 'Sub A'; Id = 'a1'; Message = 'incomplete' }) }
            [pscustomobject]@{ MarketplaceRecords = 7; MarketplaceFailedSubs = @() }
            [pscustomobject]@{ MarketplaceRecords = 0; MarketplaceFailedSubs = @([pscustomobject]@{ Name = '(all subscriptions)'; Id = '(auth)'; Message = 'skipped' }) }
        )
        $Merged = script:Merge-StreamMarketplace -StreamSummaries $Streams
        $Merged.RecordCount | Should -Be 17 -Because 'Marketplace records must sum across streams like Consumption records'
        $Merged.FailedSubs.Count | Should -Be 2 -Because 'per-sub Marketplace failures from every stream must be retained, including the auth-skip sentinel'
    }

    It 'yields zero records and no failures when no stream reported Marketplace data' {
        $Streams = @(
            [pscustomobject]@{ MarketplaceRecords = 0; MarketplaceFailedSubs = @() }
            [pscustomobject]@{ MarketplaceRecords = 0; MarketplaceFailedSubs = @() }
        )
        $Merged = script:Merge-StreamMarketplace -StreamSummaries $Streams
        $Merged.RecordCount | Should -Be 0
        $Merged.FailedSubs.Count | Should -Be 0
    }
}

Describe 'Az context snapshot lifecycle: it leaves the disk once every stream has imported it or ended (Get-StreamImportMarkerPath, Test-AzContextSnapshotReleasable, Get-StaleAzContextSnapshot, Invoke-PreFlightChecks)' {
    BeforeAll {
        # The path a printed delete command names, read back through the PowerShell parser.
        function Get-HintLiteralPath
        {
            param([Parameter(Mandatory = $true)][string]$Hint)
            $Tokens = $null
            $ParseErrors = $null
            $HintAst = [System.Management.Automation.Language.Parser]::ParseInput($Hint.Trim(), [ref]$Tokens, [ref]$ParseErrors)
            if ($ParseErrors.Count -gt 0) { throw ("The delete command does not parse: {0}" -f $ParseErrors[0].Message) }
            $Command = $HintAst.Find({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)
            if ($Command.GetCommandName() -ne 'Remove-Item') { throw ("Expected a Remove-Item command, got: {0}" -f $Hint) }
            $Quoted = @($Command.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $_.StringConstantType -eq 'SingleQuoted' })
            if ($Quoted.Count -ne 1) { throw ("Expected one single-quoted path, found {0}" -f $Quoted.Count) }
            return $Quoted[0].Value
        }
    }
    BeforeEach {
        $script:CaseDir = Join-Path $script:TestRoot ([guid]::NewGuid().ToString().Substring(0, 8))
        New-Item -ItemType Directory -Path $script:CaseDir -Force | Out-Null
        $script:Snapshot = Join-Path $script:CaseDir '.rda-stream-azcontext-11111111-1111-1111-1111-111111111111.json'
    }
    AfterEach {
        if (Test-Path -LiteralPath $script:CaseDir) { Remove-Item -LiteralPath $script:CaseDir -Recurse -Force }
    }
    It 'names the marker after the snapshot and the stream, so the sweep can find it by prefix' {
        Get-StreamImportMarkerPath -AzContextPath $script:Snapshot -StreamId '2' | Should -BeExactly ($script:Snapshot + '.imported-2')
    }
    It 'releases the snapshot only when every stream has imported it or has already ended (<Why>)' -ForEach @(
        @{ Markers = @($true, $true, $true); States = @('Running', 'Running', 'Running'); Expected = $true; Why = 'all imported' }
        @{ Markers = @($true, $false, $true); States = @('Running', 'Running', 'Running'); Expected = $false; Why = 'one still running without a marker' }
        @{ Markers = @($true, $false, $true); States = @('Running', 'Completed', 'Running'); Expected = $true; Why = 'the unmarked stream has completed' }
        @{ Markers = @($false, $true); States = @('', 'Running'); Expected = $false; Why = 'an unmarked stream with no known state' }
        @{ Markers = @($false, $true); States = @(); Expected = $false; Why = 'no job states at all' }
        @{ Markers = @($true, $true); States = @('Running', 'Running', 'Running'); Expected = $false; Why = 'a third stream without a marker slot is unaccounted for' }
        @{ Markers = @(); States = @(); Expected = $false; Why = 'no streams is never releasable' }
    ) {
        Test-AzContextSnapshotReleasable -MarkerPresent $Markers -JobState $States | Should -BeExactly $Expected
    }
    It 'treats an unmarked stream as done only in a final job state (<State>)' -ForEach @(
        [enum]::GetNames([System.Management.Automation.JobState]) | ForEach-Object { @{ State = $_; Expected = ($_ -in @('Completed', 'Failed', 'Stopped')) } }
    ) {
        Test-AzContextSnapshotReleasable -MarkerPresent @($false, $true) -JobState @($State, 'Running') | Should -BeExactly $Expected
    }
    It 'keeps the snapshot when the job states are missing, and refuses a missing marker list outright' {
        Test-AzContextSnapshotReleasable -MarkerPresent @($true) -JobState $null | Should -BeExactly $false
        # $null cannot become a [bool[]]; the wrapper treats that error as keep, see the release block tests below.
        { Test-AzContextSnapshotReleasable -MarkerPresent $null -JobState @('Running') } | Should -Throw -ErrorId 'ParameterArgumentTransformationError,Test-AzContextSnapshotReleasable'
    }
    It 'finds only snapshots, not the markers or the other stream files beside them' {
        Set-Content -LiteralPath $script:Snapshot -Value '{}'
        Set-Content -LiteralPath ($script:Snapshot + '.imported-0') -Value '0'
        Set-Content -LiteralPath (Join-Path $script:CaseDir '.rda-stream-0-summary.json') -Value '{}'
        $Found = @(Get-StaleAzContextSnapshot -InventoryRoot $script:CaseDir)
        $Found.Count | Should -Be 1
        $Found[0].Name | Should -Be (Split-Path -Path $script:Snapshot -Leaf)
    }
    It 'finds nothing when only a marker and a stream summary are left' {
        Set-Content -LiteralPath ($script:Snapshot + '.imported-0') -Value '0'
        Set-Content -LiteralPath (Join-Path $script:CaseDir '.rda-stream-0-summary.json') -Value '{}'
        @(Get-StaleAzContextSnapshot -InventoryRoot $script:CaseDir).Count | Should -Be 0
    }
    It 'pre-flight warns about each leftover snapshot, gives one literal delete command per file, and leaves them in place' {
        $Second = Join-Path $script:CaseDir '.rda-stream-azcontext-22222222-2222-2222-2222-222222222222.json'
        Set-Content -LiteralPath $script:Snapshot -Value '{}'
        Set-Content -LiteralPath $Second -Value '{}'
        # The real Exit-Wrapper exits the process; a throwing stand-in makes any call visible in the output or as a failure.
        function Exit-Wrapper { param([int]$Code) throw "Exit-Wrapper $Code" }
        $Lines = @(& { Invoke-PreFlightChecks -InventoryRoot $script:CaseDir } 6>&1 | ForEach-Object { [string]$_ })
        $Text = $Lines -join "`n"
        $Text | Should -Not -Match 'Exit-Wrapper'
        $Text | Should -Match 'WARNING: 2 Az context snapshot\(s\) from another parallel-streams run'
        $Text | Should -Match 'token cache'
        $Text | Should -Match 'written \d+ min ago'
        foreach ($Path in @($script:Snapshot, $Second))
        {
            $Text | Should -Match ([regex]::Escape((Split-Path -Path $Path -Leaf)))
            Test-Path -LiteralPath $Path -PathType Leaf | Should -BeTrue
        }
        $Hints = @($Lines | Where-Object { $_ -match 'Remove-Item' })
        $Hints.Count | Should -Be 2
        # A wildcard could also delete the snapshot of a run that is still using it.
        $Hints | Should -Not -Match '\*'
        $Hints | ForEach-Object { $_ | Should -Match "Remove-Item -LiteralPath '.+' -Force$" }
        # One command per file: the two commands name the two snapshots, not one of them twice.
        $Named = @($Hints | ForEach-Object { Get-HintLiteralPath -Hint $_ } | Sort-Object)
        $Expected = @(Get-StaleAzContextSnapshot -InventoryRoot $script:CaseDir | ForEach-Object { $_.FullName } | Sort-Object)
        $Named.Count | Should -Be 2
        ($Named -join '|') | Should -BeExactly ($Expected -join '|')
        $Text | Should -Match 'Pre-flight checks passed'
    }
    It 'pre-flight gives a delete command that parses and names the real file, whatever quotes the path holds' {
        $QuotedDir = [System.IO.Directory]::CreateDirectory((Join-Path $script:CaseDir ("it's " + [char]0x2019 + 'quoted'))).FullName
        $Quoted = Join-Path $QuotedDir '.rda-stream-azcontext-33333333-3333-3333-3333-333333333333.json'
        Set-Content -LiteralPath $Quoted -Value '{}'
        function Exit-Wrapper { param([int]$Code) throw "Exit-Wrapper $Code" }
        $Lines = @(& { Invoke-PreFlightChecks -InventoryRoot $QuotedDir } 6>&1 | ForEach-Object { [string]$_ })
        ($Lines -join "`n") | Should -Not -Match 'Exit-Wrapper'
        $Hint = @($Lines | Where-Object { $_ -match 'Remove-Item' })
        $Hint.Count | Should -Be 1
        $Named = Get-HintLiteralPath -Hint $Hint[0]
        # The path as the pre-flight listed it; Windows may report the folder casing differently from $env:TEMP.
        $Named | Should -BeExactly @(Get-StaleAzContextSnapshot -InventoryRoot $QuotedDir)[0].FullName
        $Named | Should -Match ([regex]::Escape("it's " + [char]0x2019 + 'quoted'))
        Test-Path -LiteralPath $Named -PathType Leaf | Should -BeTrue
    }
    It 'pre-flight says nothing about snapshots when there is none' {
        function Exit-Wrapper { param([int]$Code) throw "Exit-Wrapper $Code" }
        $Text = @(& { Invoke-PreFlightChecks -InventoryRoot $script:CaseDir } 6>&1 | ForEach-Object { [string]$_ }) -join "`n"
        $Text | Should -Not -Match 'Exit-Wrapper'
        $Text | Should -Match 'Pre-flight checks passed'
        $Text | Should -Not -Match 'Az context snapshot'
    }
    It 'pre-flight states the age the same way in any culture, and never as a negative age (<Case>)' -ForEach @(
        @{ Case = 'two and a half hours old'; OffsetMinutes = -150; Expected = 'written 2.5 h ago' }
        @{ Case = 'just over two hours old'; OffsetMinutes = -120.5; Expected = 'written 2.0 h ago' }
        @{ Case = 'dated in the future'; OffsetMinutes = 30; Expected = 'written 0 min ago' }
    ) {
        Set-Content -LiteralPath $script:Snapshot -Value '{}'
        (Get-Item -LiteralPath $script:Snapshot -Force).LastWriteTimeUtc = [datetime]::UtcNow.AddMinutes($OffsetMinutes)
        function Exit-Wrapper { param([int]$Code) throw "Exit-Wrapper $Code" }
        # A comma decimal separator would show up here if the hours were formatted in the current culture.
        $SavedCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try
        {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [cultureinfo]::GetCultureInfo('de-DE')
            [cultureinfo]::CurrentCulture.NumberFormat.NumberDecimalSeparator | Should -BeExactly ','
            $Text = @(& { Invoke-PreFlightChecks -InventoryRoot $script:CaseDir } 6>&1 | ForEach-Object { [string]$_ }) -join "`n"
        }
        finally
        {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = $SavedCulture
        }
        $Text | Should -Not -Match 'Exit-Wrapper'
        $Text | Should -Match ([regex]::Escape($Expected))
    }
    Context 'the release block in Run-AllSubscriptions.ps1, run as written' {
        BeforeAll {
            $Tokens = $null; $ParseErrors = $null
            $WrapperAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $PSScriptRoot -Parent) 'Run-AllSubscriptions.ps1'), [ref]$Tokens, [ref]$ParseErrors)
            if ($ParseErrors.Count -gt 0) { throw ("Run-AllSubscriptions.ps1 does not parse: {0}" -f $ParseErrors[0].Message) }
            $Assignments = @($WrapperAst.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] -and $args[0].Left.Extent.Text -eq '$ReleaseSnapshotIfImported' }, $true))
            if ($Assignments.Count -ne 1) { throw ("Expected one `$ReleaseSnapshotIfImported assignment, found {0}" -f $Assignments.Count) }
            $script:WrapperForRelease = $WrapperAst
            $BlockText = $Assignments[0].Right.Expression.ScriptBlock.Extent.Text
            # Drop the outer braces; what is left is the body exactly as the wrapper runs it.
            $script:ReleaseBlock = [scriptblock]::Create($BlockText.Substring(1, $BlockText.Length - 2))
        }
        BeforeEach {
            $AzContextSnapshot = $script:Snapshot
            # Script scope: the extracted block reads these the way it reads the wrapper's own variables.
            $script:ImportMarkerPaths = @(0, 1 | ForEach-Object { Get-StreamImportMarkerPath -AzContextPath $AzContextSnapshot -StreamId ([string]$_) })
            Set-Content -LiteralPath $AzContextSnapshot -Value '{}'
            $script:SnapshotReleased = $false
            $script:SnapshotReleaseWarned = $false
            $script:LockSnapshot = $false
        }
        It 'keeps the snapshot and the markers while a stream is still starting' {
            Set-Content -LiteralPath $script:ImportMarkerPaths[0] -Value '0'
            $script:Jobs = @([pscustomobject]@{ State = 'Running' }, [pscustomobject]@{ State = 'Running' })
            $Output = @(& $script:ReleaseBlock 6>&1)
            $Output.Count | Should -Be 0
            Test-Path -LiteralPath $AzContextSnapshot | Should -BeTrue
            Test-Path -LiteralPath $script:ImportMarkerPaths[0] | Should -BeTrue
            $script:SnapshotReleased | Should -BeFalse
        }
        It 'removes the snapshot, then the markers, once every stream has imported it, and only once' {
            $script:ImportMarkerPaths | ForEach-Object { Set-Content -LiteralPath $_ -Value 'x' }
            $script:Jobs = @([pscustomobject]@{ State = 'Running' }, [pscustomobject]@{ State = 'Running' })
            (@(& $script:ReleaseBlock 6>&1) -join "`n") | Should -Match 'no stream still needs it'
            Test-Path -LiteralPath $AzContextSnapshot | Should -BeFalse
            $script:ImportMarkerPaths | ForEach-Object { Test-Path -LiteralPath $_ | Should -BeFalse }
            $script:SnapshotReleased | Should -BeTrue
            # Once released, a later pass leaves even a file at the same path, and fresh markers, alone.
            Set-Content -LiteralPath $AzContextSnapshot -Value '{}'
            $script:ImportMarkerPaths | ForEach-Object { Set-Content -LiteralPath $_ -Value 'x' }
            @(& $script:ReleaseBlock 6>&1).Count | Should -Be 0
            Test-Path -LiteralPath $AzContextSnapshot | Should -BeTrue
            $script:ImportMarkerPaths | ForEach-Object { Test-Path -LiteralPath $_ | Should -BeTrue }
        }
        It 'marks the release done and sweeps the markers when the snapshot is already gone' {
            $script:ImportMarkerPaths | ForEach-Object { Set-Content -LiteralPath $_ -Value 'x' }
            Remove-Item -LiteralPath $AzContextSnapshot -Force
            $script:Jobs = @([pscustomobject]@{ State = 'Running' }, [pscustomobject]@{ State = 'Running' })
            @(& $script:ReleaseBlock 6>&1).Count | Should -Be 0
            $script:SnapshotReleased | Should -BeTrue
            $script:ImportMarkerPaths | ForEach-Object { Test-Path -LiteralPath $_ | Should -BeFalse }
        }
        It 'releases once the only unmarked stream has ended' {
            Set-Content -LiteralPath $script:ImportMarkerPaths[1] -Value '1'
            $script:Jobs = @([pscustomobject]@{ State = 'Completed' }, [pscustomobject]@{ State = 'Running' })
            $null = @(& $script:ReleaseBlock 6>&1)
            Test-Path -LiteralPath $AzContextSnapshot | Should -BeFalse
            $script:SnapshotReleased | Should -BeTrue
        }
        It 'keeps the markers and retries when the snapshot cannot be removed, warning once' {
            $script:ImportMarkerPaths | ForEach-Object { Set-Content -LiteralPath $_ -Value 'x' }
            $script:Jobs = @([pscustomobject]@{ State = 'Running' }, [pscustomobject]@{ State = 'Running' })
            # Pester 6 no longer falls through to the real command when no -ParameterFilter matches (Pester 5 did),
            # so a default mock does the real removal for every other Remove-Item call here: the markers, AfterEach.
            Mock Remove-Item { & (Get-Command -Name Remove-Item -CommandType Cmdlet) @PesterBoundParameters }
            Mock Remove-Item { throw 'The process cannot access the file because it is being used by another process.' } -ParameterFilter { $script:LockSnapshot -and $LiteralPath -eq $script:Snapshot }
            $script:LockSnapshot = $true
            $First = @(& $script:ReleaseBlock 6>&1 | ForEach-Object { [string]$_ })
            $Second = @(& $script:ReleaseBlock 6>&1 | ForEach-Object { [string]$_ })
            $Warnings = @($First + $Second | Where-Object { $_ -match '^WARNING: could not remove the Az context snapshot yet' })
            $Warnings.Count | Should -Be 1
            # The exception text ends in a full stop of its own; the sentence after it must not double it.
            $Warnings[0] | Should -Match 'another process\. Removal is retried'
            Test-Path -LiteralPath $AzContextSnapshot | Should -BeTrue
            $script:ImportMarkerPaths | ForEach-Object { Test-Path -LiteralPath $_ | Should -BeTrue }
            $script:SnapshotReleased | Should -BeFalse
            $script:LockSnapshot = $false
            $null = @(& $script:ReleaseBlock 6>&1)
            Test-Path -LiteralPath $AzContextSnapshot | Should -BeFalse
            $script:ImportMarkerPaths | ForEach-Object { Test-Path -LiteralPath $_ | Should -BeFalse }
            $script:SnapshotReleased | Should -BeTrue
        }
        It 'removes nothing when the release check itself fails' {
            $script:ImportMarkerPaths | ForEach-Object { Set-Content -LiteralPath $_ -Value 'x' }
            $script:Jobs = @([pscustomobject]@{ State = 'Running' }, [pscustomobject]@{ State = 'Running' })
            Mock Test-AzContextSnapshotReleasable { throw 'unexpected' }
            $Output = @(& $script:ReleaseBlock 6>&1 | ForEach-Object { [string]$_ })
            Should -Invoke Test-AzContextSnapshotReleasable -Exactly -Times 1
            @($Output | Where-Object { $_ -match '^WARNING: could not check whether the Az context snapshot can be removed yet: unexpected\. It is removed at the end of the run\.$' }).Count | Should -Be 1
            Test-Path -LiteralPath $AzContextSnapshot | Should -BeTrue
            $script:ImportMarkerPaths | ForEach-Object { Test-Path -LiteralPath $_ | Should -BeTrue }
            $script:SnapshotReleased | Should -BeFalse
        }
        It 'removes nothing unless the release check answers exactly one boolean true (<Case>)' -ForEach @(
            @{ Case = 'the string False'; Answer = 'False' }
            @{ Case = 'two answers'; Answer = @($false, $true) }
            @{ Case = 'no answer'; Answer = @() }
        ) {
            $script:ImportMarkerPaths | ForEach-Object { Set-Content -LiteralPath $_ -Value 'x' }
            $script:Jobs = @([pscustomobject]@{ State = 'Running' }, [pscustomobject]@{ State = 'Running' })
            $script:MockAnswer = $Answer
            Mock Test-AzContextSnapshotReleasable { $script:MockAnswer }
            $null = @(& $script:ReleaseBlock 6>&1)
            Should -Invoke Test-AzContextSnapshotReleasable -Exactly -Times 1
            Test-Path -LiteralPath $AzContextSnapshot | Should -BeTrue
            $script:ImportMarkerPaths | ForEach-Object { Test-Path -LiteralPath $_ | Should -BeTrue }
            $script:SnapshotReleased | Should -BeFalse
        }
        It 'builds one marker path per stream, numbered 0 to StreamCount - 1, as the wrapper does' {
            $Build = @($script:WrapperForRelease.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] -and $args[0].Left.Extent.Text -eq '$ImportMarkerPaths' }, $true))
            $Build.Count | Should -Be 1
            $MakePaths = [scriptblock]::Create('param($StreamCount, $AzContextSnapshot) ' + $Build[0].Right.Extent.Text)
            $Paths = @(& $MakePaths -StreamCount 3 -AzContextSnapshot $script:Snapshot)
            ($Paths -join '|') | Should -BeExactly ((0, 1, 2 | ForEach-Object { $script:Snapshot + '.imported-' + $_ }) -join '|')
        }
        It 'names a stream that did not complete by its stream number, not its job id' {
            $Loops = @($script:WrapperForRelease.FindAll({ $args[0] -is [System.Management.Automation.Language.ForStatementAst] -and $args[0].Body.Extent.Text -match 'job ended in state' }, $true))
            $Loops.Count | Should -Be 1
            $Report = [scriptblock]::Create('param($Jobs) ' + $Loops[0].Extent.Text)
            $Lines = @(& $Report -Jobs @([pscustomobject]@{ Id = 7; State = 'Completed' }, [pscustomobject]@{ Id = 9; State = 'Failed' }) 6>&1 | ForEach-Object { [string]$_ })
            ($Lines -join "`n") | Should -BeExactly '[stream-1] job ended in state Failed'
        }
    }
    Context 'the wrapper and the worker wire the helpers in' {
        BeforeAll {
            function Get-ParsedScript
            {
                param([Parameter(Mandatory = $true)][string]$Path)
                $Tokens = $null
                $ParseErrors = $null
                $ScriptAst = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$Tokens, [ref]$ParseErrors)
                if ($ParseErrors.Count -gt 0) { throw ("{0} does not parse: {1}" -f $Path, $ParseErrors[0].Message) }
                # Comments are stripped, and line endings normalised, so neither a comment quoting the code
                # nor a CRLF checkout can change what a guard sees.
                $Source = $ScriptAst.Extent.Text
                $Builder = [System.Text.StringBuilder]::new($Source)
                foreach ($Token in @($Tokens | Where-Object { $_.Kind -eq [System.Management.Automation.Language.TokenKind]::Comment } | Sort-Object -Property { $_.Extent.StartOffset } -Descending))
                {
                    [void]$Builder.Remove($Token.Extent.StartOffset, $Token.Extent.EndOffset - $Token.Extent.StartOffset)
                }
                return [pscustomobject]@{ Ast = $ScriptAst; Code = ($Builder.ToString() -replace "`r`n", "`n") }
            }
            $Root = Split-Path $PSScriptRoot -Parent
            $script:Wrapper = Get-ParsedScript -Path (Join-Path $Root 'Run-AllSubscriptions.ps1')
            $script:Worker = Get-ParsedScript -Path (Join-Path $Root 'Run-AllSubscriptions.Stream.ps1')
            $script:Ordinal = [System.StringComparison]::Ordinal
        }
        It 'the worker writes its marker after the import succeeded and before any subscription runs' {
            $Code = $script:Worker.Code
            $Import = $Code.IndexOf('Import-AzContext -Path $AzContextPath', $script:Ordinal)
            $Marker = $Code.IndexOf('Get-StreamImportMarkerPath -AzContextPath $AzContextPath -StreamId $StreamId', $script:Ordinal)
            $Inventory = $Code.IndexOf("& (Join-Path `$ScriptRoot 'ResourceInventory.ps1')", $script:Ordinal)
            $Import | Should -BeGreaterThan 0
            $Marker | Should -BeGreaterThan $Import
            $Inventory | Should -BeGreaterThan $Marker
            # The failed-to-start summary and its exit sit between the two, so the marker is written only once the import has worked.
            $Between = $Code.Substring($Import, $Marker - $Import)
            $Between | Should -Match "Status\s*=\s*'failed-to-start'"
            $Between | Should -Match '\bexit 1\b'
        }
        It 'the worker never refers to the snapshot again after its marker lets the parent delete it' {
            $Code = $script:Worker.Code
            $Marker = $Code.IndexOf('Get-StreamImportMarkerPath -AzContextPath $AzContextPath -StreamId $StreamId', $script:Ordinal)
            $Marker | Should -BeGreaterThan 0
            $LineEnd = $Code.IndexOf("`n", $Marker, $script:Ordinal)
            $LineEnd | Should -BeGreaterThan $Marker
            $After = $Code.Substring($LineEnd)
            # Any spelling: $AzContextPath, ${AzContextPath}, a PSBoundParameters key, or a whole-set splat.
            $After | Should -Not -Match 'AzContextPath'
            $After | Should -Not -Match '@PSBoundParameters'
        }
        It 'the worker moves its process directory to the temp folder before loading Az.Accounts' {
            # Az.Accounts resolves a relative context directory from the user's settings file against the
            # PROCESS directory, which Set-Location does not change. A job that starts in a folder the user
            # cannot write to then fails Import-AzContext with access denied.
            $Code = $script:Worker.Code
            $Move = $Code.IndexOf('[System.IO.Directory]::SetCurrentDirectory([System.IO.Path]::GetTempPath())', $script:Ordinal)
            $Load = $Code.IndexOf('Import-Module Az.Accounts', $script:Ordinal)
            $Move | Should -BeGreaterThan 0
            $Load | Should -BeGreaterThan $Move
            $Code.IndexOf('Import-AzContext -Path $AzContextPath', $script:Ordinal) | Should -BeGreaterThan $Load
        }
        It 'the worker carries on with the import when the process directory cannot be moved' {
            $Move = $script:Worker.Ast.Find({ $args[0] -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $args[0].Extent.Text -like '*SetCurrentDirectory*' }, $true)
            $Move | Should -Not -BeNullOrEmpty
            $Guard = $Move.Parent
            while ($Guard -and $Guard -isnot [System.Management.Automation.Language.TryStatementAst]) { $Guard = $Guard.Parent }
            $Guard | Should -Not -BeNullOrEmpty
            # Its own try, so a failure warns instead of reaching the import's FATAL catch.
            $Guard.Extent.Text | Should -Not -Match 'Import-AzContext'
            $Guard.CatchClauses.Count | Should -Be 1
            $Guard.CatchClauses[0].Body.Extent.Text | Should -Match 'WARNING'
            @($Guard.CatchClauses[0].Body.FindAll({ $args[0] -is [System.Management.Automation.Language.ThrowStatementAst] -or $args[0] -is [System.Management.Automation.Language.ExitStatementAst] -or $args[0] -is [System.Management.Automation.Language.ReturnStatementAst] }, $true)).Count | Should -Be 0
        }
        It 'the wrapper looks for stale snapshots before it writes its own' {
            $Code = $script:Wrapper.Code
            $PreFlight = $Code.IndexOf('Invoke-PreFlightChecks -InventoryRoot $InventoryRoot', $script:Ordinal)
            $Save = $Code.IndexOf('Save-AzContext -Path $AzContextSnapshot', $script:Ordinal)
            $PreFlight | Should -BeGreaterThan 0
            $Save | Should -BeGreaterThan $PreFlight
        }
        It 'the streams are sliced before the token cache is snapshotted, so the weights query runs while no cache is on disk' {
            $Code = $script:Wrapper.Code
            $Slice = $Code.IndexOf('Get-WeightedStreamSlices -Subscriptions', $script:Ordinal)
            $Save = $Code.IndexOf('Save-AzContext -Path $AzContextSnapshot', $script:Ordinal)
            $Slice | Should -BeGreaterThan 0
            $Save | Should -BeGreaterThan $Slice
        }
        It 'the Runspace fallback to the sequential path recomputes the auto concurrency for one stream, as the Process fallback does' {
            $Code = $script:Wrapper.Code
            $From = $Code.IndexOf('-StreamIsolation Runspace needs thread jobs', $script:Ordinal)
            $To = $Code.IndexOf('PowerShell background jobs (Start-Job) are unavailable', $script:Ordinal)
            $From | Should -BeGreaterThan 0
            $To | Should -BeGreaterThan $From
            $Code.Substring($From, $To - $From) | Should -Match 'Get-PerStreamConcurrency -PerStreamConcurrency \$AutoTune\.PerStreamConcurrency -Streams 1'
        }
        It 'the parent checks for release once per pass of its monitoring loop and once more after it' {
            $Loops = @($script:Wrapper.Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.WhileStatementAst] -and $args[0].Condition.Extent.Text -match "State -eq 'Running'" }, $true))
            $Loops.Count | Should -Be 1
            $IsReleaseCall = { param($Node) $Node -is [System.Management.Automation.Language.CommandAst] -and $Node.InvocationOperator -eq 'Ampersand' -and $Node.CommandElements[0].Extent.Text -eq '$ReleaseSnapshotIfImported' }
            @($Loops[0].Body.FindAll({ & $IsReleaseCall $args[0] }, $true)).Count | Should -Be 1
            # The statement straight after the loop drains output; the one after that is the final check.
            $Siblings = @($Loops[0].Parent.Statements)
            $At = [array]::IndexOf($Siblings, $Loops[0])
            $At | Should -BeGreaterOrEqual 0
            $Next = @($Siblings | Select-Object -Skip ($At + 1) -First 2)
            @($Next | ForEach-Object { $_.FindAll({ & $IsReleaseCall $args[0] }, $true) }).Count | Should -Be 1
            $script:Wrapper.Code | Should -Match 'Test-AzContextSnapshotReleasable -MarkerPresent \$MarkerPresent -JobState \$JobState'
        }
        It 'the finally block still removes the snapshot and sweeps the markers with it' {
            $IsSnapshotRemove = { param($Node) $Node -is [System.Management.Automation.Language.CommandAst] -and $Node.GetCommandName() -eq 'Remove-Item' -and $Node.Extent.Text -match '-LiteralPath \$AzContextSnapshot\b' }
            $Owners = @($script:Wrapper.Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.TryStatementAst] -and $args[0].Finally -and @($args[0].Finally.FindAll({ & $IsSnapshotRemove $args[0] }, $true)).Count -gt 0 }, $true))
            $Owners.Count | Should -Be 1
            $Finally = $Owners[0].Finally
            $Sweep = @($Finally.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] -and $args[0].GetCommandName() -eq 'Get-ChildItem' -and $args[0].Extent.Text -match [regex]::Escape("-Filter ((Split-Path -Path `$AzContextSnapshot -Leaf) + '.imported-*')") }, $true))
            $Sweep.Count | Should -Be 1
            @($Finally.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] -and $args[0].Extent.Text -eq 'Remove-Item -LiteralPath $ImportMarker.FullName -Force -ErrorAction Stop' }, $true)).Count | Should -Be 1
        }
    }
}

Describe 'Run-AllSubscriptions.ps1: a consolidated bundle that cannot be built is a failure' {
    # The bundling block and the exit-code rule are lifted from the wrapper's parsed source and run
    # with Compress-Archive mocked, so a failure reported the way the real cmdlet reports it is what they react to.
    BeforeAll {
        $Tokens = $null
        $ParseErrors = $null
        $BundleAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $PSScriptRoot -Parent) 'Run-AllSubscriptions.ps1'), [ref]$Tokens, [ref]$ParseErrors)
        $FindIf = {
            param([string]$Condition, [string]$Contains = '')
            $Found = @($BundleAst.FindAll({ $args[0] -is [System.Management.Automation.Language.IfStatementAst] -and $args[0].Clauses[0].Item1.Extent.Text -eq $Condition -and $args[0].Extent.Text.Contains($Contains) }, $true))
            if ($Found.Count -ne 1) { throw ("expected exactly one 'if ({0})' in Run-AllSubscriptions.ps1, found {1}" -f $Condition, $Found.Count) }
            $Found[0]
        }
        $script:BundleBlock = [scriptblock]::Create((& $FindIf -Condition 'Test-Path -LiteralPath $InventoryRoot -PathType Container' -Contains 'AllSubscriptions_ResourcesReport_').Extent.Text)
        $script:BundleExitBlock = [scriptblock]::Create((& $FindIf -Condition '$BundleBuildFailed').Extent.Text)

        # Runs the lifted bundling block with the variables it reads; the caller mocks Compress-Archive.
        function Invoke-BundleBlock
        {
            Set-Variable -Name InventoryRoot -Value $TestDrive
            Set-Variable -Name Shippable -Value ([pscustomobject]@{ Archives = @((Join-Path $TestDrive 'sub1.zip')) })
            Set-Variable -Name OuterZipFile -Value $null
            Set-Variable -Name BundleBuildFailed -Value $false
            $Printed = @(. $script:BundleBlock 6>&1 | ForEach-Object { [string]$_ })
            [pscustomobject]@{ OuterZipFile = $OuterZipFile; BundleBuildFailed = $BundleBuildFailed; Printed = $Printed }
        }
    }
    It 'a failed build names the cause, claims no bundle, and leaves nothing pointing at the missing zip' {
        # The error the real cmdlet reports for an unreadable per-subscription zip.
        Mock Compress-Archive { Write-Error "Access to the path '$LiteralPath' is denied." }
        $R = Invoke-BundleBlock
        $R.BundleBuildFailed | Should -BeTrue
        $R.OuterZipFile | Should -BeNullOrEmpty
        @($R.Printed | Where-Object { $_ -like 'Consolidated bundle created*' }).Count | Should -Be 0
        @($R.Printed | Where-Object { $_ -like 'ERROR: Could not build the consolidated bundle*is denied.' }).Count | Should -Be 1
    }
    It 'a build that reports no error but leaves no archive is a failure too' {
        Mock Compress-Archive { }
        $R = Invoke-BundleBlock
        $R.BundleBuildFailed | Should -BeTrue
        $R.OuterZipFile | Should -BeNullOrEmpty
        @($R.Printed | Where-Object { $_ -like 'Consolidated bundle created*' }).Count | Should -Be 0
    }
    It 'a successful build still reports the bundle and keeps its path' {
        # A real one-entry zip, written without the (mocked) cmdlet.
        Mock Compress-Archive {
            $Zip = [System.IO.Compression.ZipFile]::Open($DestinationPath, 'Create')
            try { $null = $Zip.CreateEntry('sub1.zip') } finally { $Zip.Dispose() }
        }
        $R = Invoke-BundleBlock
        $R.BundleBuildFailed | Should -BeFalse
        $R.OuterZipFile | Should -BeLike (Join-Path $TestDrive 'AllSubscriptions_ResourcesReport_*.zip')
        @($R.Printed | Where-Object { $_ -like 'Consolidated bundle created*' }).Count | Should -Be 1
    }
    It 'a failed build sets exit code 2, and a built one leaves the code alone' {
        $WrapperExitCode = 0
        Set-Variable -Name BundleBuildFailed -Value $true
        . $script:BundleExitBlock
        $WrapperExitCode | Should -Be 2
        $WrapperExitCode = 4
        Set-Variable -Name BundleBuildFailed -Value $false
        . $script:BundleExitBlock
        $WrapperExitCode | Should -Be 4
    }
}

Describe 'Run-AllSubscriptions.ps1: subscriptions of a stream that failed to start can be retried' {
    # The stream-summary fold and the save that follows are lifted from the wrapper's parsed source.
    BeforeAll {
        $Tokens = $null
        $ParseErrors = $null
        $FoldAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $PSScriptRoot -Parent) 'Run-AllSubscriptions.ps1'), [ref]$Tokens, [ref]$ParseErrors)
        $FindIf = {
            param([string]$Condition)
            $Found = @($FoldAst.FindAll({ $args[0] -is [System.Management.Automation.Language.IfStatementAst] -and $args[0].Clauses[0].Item1.Extent.Text -eq $Condition }, $true))
            if ($Found.Count -ne 1) { throw ("expected exactly one 'if ({0})' in Run-AllSubscriptions.ps1, found {1}" -f $Condition, $Found.Count) }
            $Found[0]
        }
        $script:FailedFoldBlock = [scriptblock]::Create((& $FindIf -Condition '$StreamSummary.Failed').Extent.Text)
        $script:StreamSaveBlock = [scriptblock]::Create((& $FindIf -Condition '$AllCompletedFromStreams.Count -gt 0 -or $AllFailedFromStreams.Count -gt 0 -or $FailedToStartRecorded').Extent.Text)

        # Folds one stream summary the way the wrapper does, then runs the save decision.
        function Invoke-FailedFold
        {
            param([string]$Status, [object[]]$Failed)
            Set-Variable -Name S -Value ([pscustomobject]@{ StreamId = 0 })
            Set-Variable -Name StreamSummary -Value ([pscustomobject]@{ Status = $Status; Failed = $Failed })
            Set-Variable -Name FailedSubscriptions -Value @()
            Set-Variable -Name FailedSubscriptionIds -Value @()
            Set-Variable -Name FailedAttempts -Value @()
            Set-Variable -Name FailedToStartRecorded -Value $false
            Set-Variable -Name AllCompletedFromStreams -Value @()
            Set-Variable -Name AllFailedFromStreams -Value @()
            $script:Saved = $null
            function Save-CompletedSubscriptionIds { param($Path, $Tenant, $Ids, $FailedAttempts) $script:Saved = @($FailedAttempts) }
            . $script:FailedFoldBlock
            . $script:StreamSaveBlock
            [pscustomobject]@{ FailedAttempts = @($FailedAttempts); FailedIds = @($FailedSubscriptionIds); Saved = $script:Saved }
        }
    }
    It 'a stream that failed to start records each named subscription as a failed attempt and saves it' {
        $R = Invoke-FailedFold -Status 'failed-to-start' -Failed @(
            [pscustomobject]@{ Id = 'sub-a'; Name = 'A'; Reason = 'stream did not start: Az context import failed' }
            [pscustomobject]@{ Id = '<unknown>'; Name = 'B'; Reason = 'stream did not start: SubscriptionIds/SubscriptionNames length mismatch' }
        )
        @($R.FailedAttempts | ForEach-Object { $_.Id }) | Should -Be @('sub-a')
        $R.FailedAttempts[0].Reason | Should -Be 'stream did not start: Az context import failed'
        @($R.Saved | ForEach-Object { $_.Id }) | Should -Be @('sub-a')
        $R.FailedIds | Should -Contain 'sub-a'
    }
    It 'a stream that started leaves failed attempts to its own state file, so nothing is counted twice' {
        $R = Invoke-FailedFold -Status 'partial-failure' -Failed @([pscustomobject]@{ Id = 'sub-a'; Name = 'A'; Reason = 'inner exit 1' })
        @($R.FailedAttempts).Count | Should -Be 0
        $R.Saved | Should -BeNullOrEmpty
        $R.FailedIds | Should -Contain 'sub-a'
    }
}

Describe 'Run-AllSubscriptions.ps1: -ResumeFailedOnly keeps the resume state while a subscription is still owed' {
    # The owed-subscription check and the clean-run clear are lifted from the wrapper's parsed source.
    BeforeAll {
        $Tokens = $null
        $ParseErrors = $null
        $OwedAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $PSScriptRoot -Parent) 'Run-AllSubscriptions.ps1'), [ref]$Tokens, [ref]$ParseErrors)
        $FindIf = {
            param([string]$Condition, [string]$Contains)
            $Found = @($OwedAst.FindAll({ $args[0] -is [System.Management.Automation.Language.IfStatementAst] -and $args[0].Clauses[0].Item1.Extent.Text -eq $Condition -and $args[0].Extent.Text.Contains($Contains) }, $true))
            if ($Found.Count -ne 1) { throw ("expected exactly one 'if ({0})' containing '{1}' in Run-AllSubscriptions.ps1, found {2}" -f $Condition, $Contains, $Found.Count) }
            $Found[0]
        }
        $script:OwedBlock = [scriptblock]::Create((& $FindIf -Condition '$ResumeFailedOnly' -Contains '$OwedOutsideRetry = @(').Extent.Text)
        $ClearIf = & $FindIf -Condition '$FailedSubscriptions.Count -eq 0 -and $FailedAttempts.Count -eq 0 -and $OwedOutsideRetry.Count -eq 0 -and ((Test-Path -LiteralPath $ResumeStateFile -PathType Leaf) -or $StateBlobArgs.Count -gt 0)' -Contains 'Resume state cleared (clean run).'
        $script:ClearBlock = [scriptblock]::Create($ClearIf.Extent.Text)

        # A (completed earlier), B (failed, retried now and completed), C (never reached).
        function Invoke-OwedCheck
        {
            param([string[]]$CompletedIds, [string[]]$EndIds)
            $StateFile = Join-Path $TestDrive 'resume-state.json'
            Set-Content -LiteralPath $StateFile -Value '{}'
            Set-Variable -Name ResumeStateFile -Value $StateFile
            Set-Variable -Name StateBlobArgs -Value @{}
            Set-Variable -Name ResumeFailedOnly -Value $true
            Set-Variable -Name EligibleBeforeRetryFilter -Value @(
                [pscustomobject]@{ Id = 'sub-a'; Name = 'A' }
                [pscustomobject]@{ Id = 'sub-b'; Name = 'B' }
                [pscustomobject]@{ Id = 'sub-c'; Name = 'C' }
            )
            Set-Variable -Name RetriedIds -Value @('sub-b')
            Set-Variable -Name CompletedIds -Value $CompletedIds
            Set-Variable -Name EndIds -Value $EndIds
            Set-Variable -Name FailedSubscriptions -Value @()
            Set-Variable -Name FailedAttempts -Value @()
            $Printed = @(& { . $script:OwedBlock; . $script:ClearBlock } 6>&1 | ForEach-Object { [string]$_ })
            [pscustomobject]@{ StateKept = (Test-Path -LiteralPath $StateFile); Printed = $Printed }
        }
    }
    It 'a subscription the interrupted run never reached keeps the state and is named' {
        $R = Invoke-OwedCheck -CompletedIds @('sub-a', 'sub-b') -EndIds @('sub-a', 'sub-b', 'sub-c')
        $R.StateKept | Should -BeTrue
        @($R.Printed | Where-Object { $_ -eq 'Never collected, and not retried by -ResumeFailedOnly (1): C (sub-c)' }).Count | Should -Be 1
        @($R.Printed | Where-Object { $_ -like 'Resume state cleared*' }).Count | Should -Be 0
    }
    It 'the state is cleared once every eligible subscription is complete' {
        $R = Invoke-OwedCheck -CompletedIds @('sub-a', 'sub-b', 'sub-c') -EndIds @('sub-a', 'sub-b', 'sub-c')
        $R.StateKept | Should -BeFalse
        @($R.Printed | Where-Object { $_ -eq 'Resume state cleared (clean run).' }).Count | Should -Be 1
    }
    It 'a subscription deleted since the start is not owed' {
        $R = Invoke-OwedCheck -CompletedIds @('sub-a', 'sub-b') -EndIds @('sub-a', 'sub-b')
        $R.StateKept | Should -BeFalse
    }
}

Describe 'Run-AllSubscriptions.ps1: a clean run clears the resume state blob as well as the local file' {
    # The next run seeds its state from the blob first, so a blob left behind makes -Resume skip every
    # subscription this run collected. The clean-run clear is lifted from the wrapper's parsed source.
    BeforeAll {
        $Tokens = $null
        $ParseErrors = $null
        $ClearAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $PSScriptRoot -Parent) 'Run-AllSubscriptions.ps1'), [ref]$Tokens, [ref]$ParseErrors)
        $Found = @($ClearAst.FindAll({ $args[0] -is [System.Management.Automation.Language.IfStatementAst] -and $args[0].Clauses[0].Item1.Extent.Text.StartsWith('$FailedSubscriptions.Count -eq 0 -and $FailedAttempts.Count -eq 0 -and $OwedOutsideRetry.Count -eq 0') -and $args[0].Extent.Text.Contains('Resume state cleared (clean run).') }, $true))
        if ($Found.Count -ne 1) { throw ("expected exactly one clean-run clear in Run-AllSubscriptions.ps1, found {0}" -f $Found.Count) }
        $script:BlobClearBlock = [scriptblock]::Create($Found[0].Extent.Text)

        # -RemoveError: $null removes the blob; otherwise the message Remove-AzStorageBlob throws.
        function Invoke-BlobClear
        {
            param([bool]$WithLocalFile, [AllowNull()][string]$RemoveError)
            $StateFile = Join-Path $TestDrive ('state-{0}.json' -f [guid]::NewGuid().ToString('N'))
            if ($WithLocalFile) { Set-Content -LiteralPath $StateFile -Value '{}' }
            $Removed = [System.Collections.Generic.List[string]]::new()
            function Remove-AzStorageBlob
            {
                param($Container, $Blob, $Context, [switch]$Force)
                if ($RemoveError) { throw $RemoveError }
                $Removed.Add(('{0}/{1}' -f $Container, $Blob))
            }
            Set-Variable -Name ResumeStateFile -Value $StateFile
            Set-Variable -Name StateBlobArgs -Value @{ BlobContext = 'ctx'; BlobContainer = 'rdastate'; BlobName = '_state/.resume-state-t.json' }
            Set-Variable -Name FailedSubscriptions -Value @()
            Set-Variable -Name FailedAttempts -Value @()
            Set-Variable -Name OwedOutsideRetry -Value @()
            $Printed = @(& { . $script:BlobClearBlock } 6>&1 | ForEach-Object { [string]$_ })
            [pscustomobject]@{ LocalKept = (Test-Path -LiteralPath $StateFile); Removed = @($Removed); Printed = $Printed }
        }
    }
    It 'removes the main state blob and the local file, then reports the state cleared' {
        $R = Invoke-BlobClear -WithLocalFile $true -RemoveError $null
        $R.LocalKept | Should -BeFalse
        $R.Removed.Count | Should -Be 1
        $R.Removed[0] | Should -Be 'rdastate/_state/.resume-state-t.json'
        @($R.Printed | Where-Object { $_ -eq 'Resume state cleared (clean run).' }).Count | Should -Be 1
    }
    It 'removes the blob even when no local state file exists' {
        $R = Invoke-BlobClear -WithLocalFile $false -RemoveError $null
        $R.Removed.Count | Should -Be 1
        $R.Removed[0] | Should -Be 'rdastate/_state/.resume-state-t.json'
        @($R.Printed | Where-Object { $_ -eq 'Resume state cleared (clean run).' }).Count | Should -Be 1
    }
    It 'a blob that is already gone counts as cleared' {
        $R = Invoke-BlobClear -WithLocalFile $true -RemoveError 'The specified blob does not exist. HTTP Status Code: 404 - HTTP Error Message: The specified blob does not exist. ErrorCode: BlobNotFound'
        @($R.Printed | Where-Object { $_ -eq 'Resume state cleared (clean run).' }).Count | Should -Be 1
        @($R.Printed | Where-Object { $_ -like 'WARNING: Could not remove resume state blob*' }).Count | Should -Be 0
    }
    It 'a blob that could not be removed is named, and the state is not reported cleared' {
        $R = Invoke-BlobClear -WithLocalFile $true -RemoveError 'This request is not authorized to perform this operation using this permission. HTTP Status Code: 403 - ErrorCode: AuthorizationPermissionMismatch'
        @($R.Printed | Where-Object { $_ -like 'WARNING: Could not remove resume state blob rdastate/_state/.resume-state-t.json:*' }).Count | Should -Be 1
        @($R.Printed | Where-Object { $_ -like 'Resume state cleared*' }).Count | Should -Be 0
    }
}

Describe 'Run-AllSubscriptions.ps1: the reconciliation judges only the subscriptions this run was given' {
    # The sequential path runs ResourceInventory.ps1 in this process, and it assigns $Global:Subscriptions,
    # which is the wrapper's own $Subscriptions under pwsh -File. The copy taken before the processing
    # branch is what the reconciliation must read.
    BeforeAll {
        $Tokens = $null
        $ParseErrors = $null
        $script:RespAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $PSScriptRoot -Parent) 'Run-AllSubscriptions.ps1'), [ref]$Tokens, [ref]$ParseErrors)
        $script:InnerAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $PSScriptRoot -Parent) 'ResourceInventory.ps1'), [ref]$Tokens, [ref]$ParseErrors)
    }
    It 'the inner script still assigns $Global:Subscriptions, so the copy is still needed' {
        @($script:InnerAst.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] -and $args[0].Left.Extent.Text -eq '$Global:Subscriptions' }, $true)).Count | Should -BeGreaterThan 0
    }
    It 'the copy is taken at the top level, before the sequential/parallel branch' {
        $Top = @($script:RespAst.EndBlock.Statements)
        $CopyAt = @(0..($Top.Count - 1) | Where-Object { $Top[$_].Extent.Text -eq '$ResponsibleSubscriptions = @($Subscriptions)' })
        $BranchAt = @(0..($Top.Count - 1) | Where-Object { $Top[$_] -is [System.Management.Automation.Language.IfStatementAst] -and $Top[$_].Clauses[0].Item1.Extent.Text -eq '$ParallelStreams -le 1' })
        $CopyAt.Count | Should -Be 1
        $BranchAt.Count | Should -Be 1
        $CopyAt[0] | Should -BeLessThan $BranchAt[0]
    }
    It 'the responsible set is built from the copy' {
        $Loops = @($script:RespAst.FindAll({ $args[0] -is [System.Management.Automation.Language.ForEachStatementAst] -and $args[0].Variable.Extent.Text -eq '$ResponsibleSub' }, $true))
        $Loops.Count | Should -Be 1
        $Loops[0].Condition.Extent.Text | Should -Be '$ResponsibleSubscriptions'
    }
}

Describe 'Run-AllSubscriptions.ps1: a -Resume bundle carries the reports of the subscriptions it skipped' {
    # A -Resume run skips what an earlier run completed. The earlier run was interrupted before it built
    # a bundle, so the skipped subscriptions' reports are shipped only through this run's bundle.
    # The selection statements are lifted from the wrapper's AST and run as written, beside the real
    # shared functions dot-sourced at the top of this file.
    BeforeAll {
        $TmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { '/tmp' }
        $script:CarryRoot = Join-Path $TmpBase ("ResumeCarryTest_" + [guid]::NewGuid().ToString().Substring(0, 8))
        New-Item -ItemType Directory -Path $script:CarryRoot -Force | Out-Null

        # A report folder and its archive as the inner script leaves them, with a Diagnostics header
        # for the given mode, or none at all.
        function script:New-CarryReport
        {
            param([string]$Stamp, [string]$Header)
            $Folder = Join-Path $script:CarryRoot ('ResourcesReport' + $Stamp)
            $Stage = Join-Path $script:CarryRoot ('stage-' + $Stamp)
            New-Item -ItemType Directory -Path $Folder, $Stage -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $Stage ('Inventory_ResourcesReport_{0}.json' -f $Stamp)) -Value '{}' -Encoding utf8
            if ($Header) { Set-Content -LiteralPath (Join-Path $Stage ('Diagnostics_ResourcesReport_{0}.log' -f $Stamp)) -Value @($Header, 'Tool version    : 0.0.0') -Encoding utf8 }
            $Zip = Join-Path $Folder ('ResourcesReport_{0}.zip' -f $Stamp)
            Compress-Archive -Path (Join-Path $Stage '*') -DestinationPath $Zip -Force
            Remove-Item -LiteralPath $Stage -Recurse -Force
            return $Zip
        }
        $script:DefaultHeader = 'Resource Discovery for Azure - diagnostics (default/non-obfuscated run)'
        $script:ObfuscatedHeader = 'Resource Discovery for Azure - shareable diagnostics (obfuscated run)'

        # The earlier run's report for sub-a, written well before this run started.
        $script:EarlierZip = script:New-CarryReport -Stamp '20260101000000000aaaa' -Header $script:DefaultHeader
        $Past = (Get-Date).AddHours(-3)
        (Get-Item -LiteralPath $script:EarlierZip).LastWriteTime = $Past
        (Get-Item -LiteralPath (Split-Path -Path $script:EarlierZip -Parent)).LastWriteTime = $Past
        $script:Since = (Get-Date).AddMinutes(-1)
        # This run's report for sub-b.
        $script:ThisRunZip = script:New-CarryReport -Stamp '20260101000000000bbbb' -Header $script:DefaultHeader

        $Tokens = $null
        $ParseErrors = $null
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $PSScriptRoot -Parent) 'Run-AllSubscriptions.ps1'), [ref]$Tokens, [ref]$ParseErrors)
        $script:CarryAst = $Ast
        $Select = @($Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] -and $args[0].Left.Extent.Text -eq '$Shippable' -and $args[0].Right.Extent.Text -match 'Select-RdaShippableReports' }, $true))
        if ($Select.Count -ne 1) { throw "Expected exactly one '`$Shippable = Select-RdaShippableReports ...' statement in Run-AllSubscriptions.ps1, found $($Select.Count)." }
        # The statements that work out what is carried and the records that ship, in source order,
        # then the selection.
        $Carry = @($Ast.EndBlock.Statements | Where-Object {
                ($_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -in @('$ResumeCarry', '$CarriedReports', '$UncarriedSkipped', '$ShippedRecords')) -or
                ($_ -is [System.Management.Automation.Language.ForEachStatementAst] -and $_.Variable.Extent.Text -eq '$Carried')
            } | ForEach-Object { $_.Extent.Text })
        $script:SelectionBlock = [scriptblock]::Create(
            "param(`$InventoryRoot, `$RunStartTime, `$SubResourceCounts, `$SkippedSubscriptions, `$CompletedReports, `$Obfuscate)`n" +
            ($Carry -join "`n") + "`n" + $Select[0].Extent.Text + "`n" +
            "[pscustomobject]@{ Archives = @(`$Shippable.Archives); Folders = @(`$Shippable.Folders | ForEach-Object { `$_.Name }); Uncarried = @(`$UncarriedSkipped) }")

        $script:SubA = [pscustomobject]@{ Name = 'Sub A'; Id = 'sub-a' }
        $script:ThisRun = @([pscustomobject]@{ Name = 'Sub B'; Id = 'sub-b'; Count = 2; Zip = $script:ThisRunZip })
        function script:Invoke-CarrySelection
        {
            param($Reports, [bool]$Obfuscate = $false)
            return (& $script:SelectionBlock $script:CarryRoot $script:Since $script:ThisRun @($script:SubA) @($Reports) $Obfuscate)
        }
    }
    AfterAll {
        if ($script:CarryRoot -and (Test-Path $script:CarryRoot)) { Remove-Item -Path $script:CarryRoot -Recurse -Force }
    }

    It 'the resume state keeps the archive each completed subscription recorded, and only theirs' {
        $StatePath = Join-Path $script:CarryRoot '.resume-state-t.json'
        $Reports = @(
            [pscustomobject]@{ Name = 'Sub A'; Id = 'sub-a'; Count = 5; Zip = 'old.zip' },
            [pscustomobject]@{ Name = 'Sub A'; Id = 'sub-a'; Count = 5; Zip = $script:EarlierZip },
            [pscustomobject]@{ Name = 'Sub X'; Id = 'sub-x'; Count = 1; Zip = 'x.zip' })
        Save-CompletedSubscriptionIds -Path $StatePath -Tenant 't' -Ids @('sub-a') -Reports $Reports
        $Saved = Get-ResumeStateObject -Path $StatePath -Tenant 't'
        @($Saved.Reports).Count | Should -Be 1 -Because 'one record per completed id, none for an id that is not completed'
        @($Saved.Reports)[0].Zip | Should -Be $script:EarlierZip -Because 'the last record given for a subscription wins'
        @($Saved.Reports)[0].Count | Should -Be 5
    }

    It 'the bundle selection, run as written, ships the skipped subscription''s earlier archive beside this run''s' {
        $Reports = @([pscustomobject]@{ Name = 'Sub A'; Id = 'sub-a'; Count = 5; Zip = $script:EarlierZip })
        $Sel = script:Invoke-CarrySelection -Reports $Reports
        $Sel.Archives | Should -Contain $script:ThisRunZip
        $Sel.Archives | Should -Contain $script:EarlierZip -Because 'a subscription skipped as completed must not drop out of the bundle'
        @($Sel.Archives).Count | Should -Be 2
        $Sel.Folders | Should -Contain (Split-Path -Path (Split-Path -Path $script:EarlierZip -Parent) -Leaf) -Because 'its HTML report and the main summary read the shipped folders'
        @($Sel.Uncarried).Count | Should -Be 0
    }

    It 'an -Obfuscate resume does not carry a non-obfuscated archive, and names it instead' {
        $Reports = @([pscustomobject]@{ Name = 'Sub A'; Id = 'sub-a'; Count = 5; Zip = $script:EarlierZip })
        $Sel = script:Invoke-CarrySelection -Reports $Reports -Obfuscate $true
        $Sel.Archives | Should -Not -Contain $script:EarlierZip -Because 'one bundle never mixes obfuscated and real identifiers'
        @($Sel.Uncarried).Count | Should -Be 1
        $Sel.Uncarried[0].Id | Should -Be 'sub-a'
        $Sel.Uncarried[0].Reason | Should -Match 'not obfuscated'
    }

    It 'an archive whose privacy mode cannot be read is not carried, and is named' {
        $NoHeaderZip = script:New-CarryReport -Stamp '20260101000000000cccc' -Header $null
        $Reports = @([pscustomobject]@{ Name = 'Sub A'; Id = 'sub-a'; Count = 5; Zip = $NoHeaderZip })
        $Sel = script:Invoke-CarrySelection -Reports $Reports
        $Sel.Archives | Should -Not -Contain $NoHeaderZip
        @($Sel.Uncarried).Count | Should -Be 1
        $Sel.Uncarried[0].Reason | Should -Match 'does not show whether it is obfuscated'
    }

    It 'a skipped subscription with no recorded or no surviving archive is named, never shipped silently' {
        $Gone = Join-Path $script:CarryRoot 'ResourcesReport20260101000000000dddd/ResourcesReport_20260101000000000dddd.zip'
        foreach ($Reports in @(@(), @([pscustomobject]@{ Name = 'Sub A'; Id = 'sub-a'; Count = 5; Zip = $Gone })))
        {
            $Sel = script:Invoke-CarrySelection -Reports $Reports
            @($Sel.Archives) | Should -Be @($script:ThisRunZip)
            @($Sel.Uncarried).Count | Should -Be 1
            $Sel.Uncarried[0].Id | Should -Be 'sub-a'
        }
    }

    It 'both skip paths record the subscription they skip' {
        $Skips = @($script:CarryAst.FindAll({ $args[0] -is [System.Management.Automation.Language.IfStatementAst] -and $args[0].Clauses[0].Item1.Extent.Text -eq '$Resume -and ($CompletedIds -contains $Sub.Id)' }, $true))
        $Skips.Count | Should -Be 2 -Because 'the sequential loop and the parallel pre-slice each skip completed subscriptions'
        foreach ($Skip in $Skips)
        {
            $Skip.Clauses[0].Item2.Extent.Text | Should -Match '\$SkippedSubscriptions \+= @\(\$Sub\)'
        }
    }

    It 'a report that cannot be carried sets exit code 2 and has a banner printed before the transcript stops' {
        $Src = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'Run-AllSubscriptions.ps1') -Raw
        $Src | Should -Match '(?s)if \(@\(\$UncarriedSkipped\)\.Count -gt 0\)\s*\{\s*\$WrapperExitCode = 2\s*\}'
        $Lines = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'Run-AllSubscriptions.ps1')
        $BannerIdx = ($Lines | Select-String -SimpleMatch 'FAILED (earlier report not carried)' | Select-Object -First 1).LineNumber
        $StopIdx = ($Lines | Select-String -SimpleMatch 'Stop-Transcript on normal completion failed' | Select-Object -First 1).LineNumber
        $BannerIdx | Should -Not -BeNullOrEmpty
        $BannerIdx | Should -BeLessThan $StopIdx
    }
}

Describe 'Run-AllSubscriptions.ps1: -StreamIsolation Runspace runs each stream as a thread job in this process' {
    # The wrapper's launch and start-wait blocks are lifted from its parsed source and run against a stub
    # worker, so what is asserted is what the wrapper does in each mode. The real worker is run with
    # -SharedProcess against a stub inventory, with the process-wide Az commands it must leave alone
    # replaced by stubs that record any call.
    BeforeAll {
        $script:SiRoot = Split-Path $PSScriptRoot -Parent
        $SiAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:SiRoot 'Run-AllSubscriptions.ps1'), [ref]$null, [ref]$null)
        $FindRunspaceIf = {
            param([string]$Contains)
            $Found = @($SiAst.FindAll({ $args[0] -is [System.Management.Automation.Language.IfStatementAst] -and $args[0].Clauses[0].Item1.Extent.Text -eq "`$StreamIsolation -eq 'Runspace'" -and $args[0].Extent.Text.Contains($Contains) }, $true))
            if ($Found.Count -ne 1) { throw ("expected one Runspace block containing '{0}' in Run-AllSubscriptions.ps1, found {1}" -f $Contains, $Found.Count) }
            [scriptblock]::Create($Found[0].Extent.Text)
        }
        $script:LaunchBlock = & $FindRunspaceIf '$Jobs += Start-ThreadJob'
        $script:StartWaitBlock = & $FindRunspaceIf "State -eq 'NotStarted'"
        $script:IsolationParam = @($SiAst.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'StreamIsolation' })

        # A worker that reports where it ran, and leaves a "pool" in its runspace's globals.
        $script:StubWorker = Join-Path $TestDrive 'stub-worker.ps1'
        Set-Content -LiteralPath $script:StubWorker -Value @'
param([string]$Probe, [switch]$SharedProcess)
$Global:MetricCallPool = 'stub-pool'
[pscustomobject]@{ ProcessId = $PID; RunspaceId = [runspace]::DefaultRunspace.Id; SharedProcess = [bool]$SharedProcess } | ConvertTo-Json | Set-Content -LiteralPath $Probe
'@
        # Stands in for Functions/Common.Functions.ps1: records which pool the release saw. It is called from the
        # thread job's own script block, so it reads that block's $WorkerArgs through its scope chain.
        $script:StubCommon = Join-Path $TestDrive 'stub-common.ps1'
        Set-Content -LiteralPath $script:StubCommon -Value @'
function Close-RdaMetricWorkerPool { Set-Content -LiteralPath ($WorkerArgs.Probe + '.released') -Value ([string]$Global:MetricCallPool); 'released' }
'@
    }

    It 'defaults to Process and accepts only Process or Runspace' {
        $script:IsolationParam.Count | Should -Be 1
        $script:IsolationParam[0].DefaultValue.Extent.Text | Should -Be "'Process'"
        $Validate = @($script:IsolationParam[0].Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' })
        $Validate.Count | Should -Be 1
        @($Validate[0].PositionalArguments.Value) | Should -Be @('Process', 'Runspace')
    }

    It 'Runspace: starts a thread job in this process that runs the worker with -SharedProcess and releases its pool there' {
        $Probe = Join-Path $TestDrive 'runspace.json'
        # Inputs of the lifted block, which reads them when it is dot-sourced below.
        Set-Variable -Name StreamIsolation -Value 'Runspace'
        Set-Variable -Name StreamCount -Value 2
        Set-Variable -Name WorkerScript -Value $script:StubWorker
        Set-Variable -Name CommonFunctionsFile -Value $script:StubCommon
        $WorkerArgs = @{ Probe = $Probe }
        $Jobs = @()
        . $script:LaunchBlock
        @($Jobs).Count | Should -Be 1
        $Jobs[0].PSJobTypeName | Should -Be 'ThreadJob'
        $null = $Jobs | Wait-Job -Timeout 60
        $Jobs[0].State | Should -Be 'Completed'
        $Jobs | Remove-Job -Force
        $Seen = Get-Content -Raw -LiteralPath $Probe | ConvertFrom-Json
        $Seen.ProcessId | Should -Be $PID -Because 'a thread job runs in the wrapper''s own process'
        $Seen.RunspaceId | Should -Not -Be ([runspace]::DefaultRunspace.Id) -Because 'each stream gets a runspace of its own'
        $Seen.SharedProcess | Should -BeTrue
        $WorkerArgs.SharedProcess | Should -BeTrue
        (Get-Content -Raw -LiteralPath ($Probe + '.released')).Trim() | Should -Be 'stub-pool' -Because 'the stream''s pool lives in its own runspace, so that is where it must be released'
    }

    It 'Process (default): still starts the worker in a separate pwsh process, without -SharedProcess' {
        $Probe = Join-Path $TestDrive 'process.json'
        Set-Variable -Name StreamIsolation -Value 'Process'
        Set-Variable -Name StreamCount -Value 2
        Set-Variable -Name WorkerScript -Value $script:StubWorker
        Set-Variable -Name CommonFunctionsFile -Value $script:StubCommon
        $WorkerArgs = @{ Probe = $Probe }
        $Jobs = @()
        . $script:LaunchBlock
        @($Jobs).Count | Should -Be 1
        $Jobs[0].PSJobTypeName | Should -Be 'BackgroundJob'
        $null = $Jobs | Wait-Job -Timeout 120
        $Jobs | Remove-Job -Force
        $Seen = Get-Content -Raw -LiteralPath $Probe | ConvertFrom-Json
        $Seen.ProcessId | Should -Not -Be $PID
        $Seen.SharedProcess | Should -BeFalse
        $WorkerArgs.ContainsKey('SharedProcess') | Should -BeFalse
    }

    It 'Runspace: waits until every thread job has left NotStarted, which the Running-watch loop cannot see' {
        Set-Variable -Name StreamIsolation -Value 'Runspace'
        $Jobs = @(1..3 | ForEach-Object { Start-ThreadJob -ThrottleLimit 3 -ScriptBlock { Start-Sleep -Seconds 2 } })
        try
        {
            . $script:StartWaitBlock
            @($Jobs | Where-Object { $_.State -eq 'NotStarted' }).Count | Should -Be 0
        }
        finally { $Jobs | Remove-Job -Force }
    }

    It 'Test-ThreadJobSupport reports thread jobs usable and leaves no job behind' {
        $Before = @(Get-Job).Count
        Test-ThreadJobSupport | Should -BeTrue
        @(Get-Job).Count | Should -Be $Before
    }

    Context 'the worker, run as a stream' {
        BeforeAll {
            $script:WorkerPath = Join-Path $script:SiRoot 'Run-AllSubscriptions.Stream.ps1'
            # An inventory that only reports a finished subscription.
            $script:StubTree = Join-Path $TestDrive 'tree'
            New-Item -ItemType Directory -Path $script:StubTree -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $script:StubTree 'ResourceInventory.ps1') -Value @'
param($TenantID, $SubscriptionID, [switch]$RunAllSubs, $ConcurrencyLimit)
$Global:ResourceCount = 3
$Global:ZipOutputFile = 'report-' + $SubscriptionID + '.zip'
'@
            function script:Invoke-StubStream
            {
                param([string]$Root, [switch]$SharedProcess)
                New-Item -ItemType Directory -Path $Root -Force | Out-Null
                $WorkerArgs = @{
                    TenantID           = 'tenant-x'
                    StreamId           = '0'
                    InventoryRoot      = $Root
                    ScriptRoot         = $script:StubTree
                    AzContextPath      = (Join-Path $Root 'snapshot.json')
                    StreamSummaryPath  = (Join-Path $Root 'summary.json')
                    StreamFailuresPath = (Join-Path $Root 'failures.log')
                    SubscriptionIds    = @('sub-1')
                    SubscriptionNames  = @('Sub One')
                }
                if ($SharedProcess) { $WorkerArgs.SharedProcess = $true }
                $null = & $script:WorkerPath @WorkerArgs 6>&1
                Get-Content -Raw -LiteralPath (Join-Path $Root 'summary.json') | ConvertFrom-Json
            }
        }

        It 'with -SharedProcess it leaves the Az context, autosave and the process directory alone, and still completes' {
            Mock Import-Module { }
            Mock Disable-AzContextAutosave { }
            Mock Import-AzContext { }
            $Root = Join-Path $TestDrive 'shared'
            $DirectoryBefore = [System.Environment]::CurrentDirectory
            $Summary = script:Invoke-StubStream -Root $Root -SharedProcess
            Should -Invoke Import-Module -Times 0 -Exactly
            Should -Invoke Disable-AzContextAutosave -Times 0 -Exactly
            Should -Invoke Import-AzContext -Times 0 -Exactly
            [System.Environment]::CurrentDirectory | Should -Be $DirectoryBefore
            @(Get-ChildItem -LiteralPath $Root -Filter '*.imported-*' -Force).Count | Should -Be 0 -Because 'there is no snapshot to release'
            $Summary.Status | Should -Be 'ok'
            @($Summary.Completed) | Should -Be @('sub-1')
        }

        It 'without it, the same worker still imports the snapshot and leaves its marker, as a stream process does' {
            Mock Import-Module { }
            Mock Disable-AzContextAutosave { }
            Mock Import-AzContext { }
            $Root = Join-Path $TestDrive 'process'
            $DirectoryBefore = [System.Environment]::CurrentDirectory
            try { $Summary = script:Invoke-StubStream -Root $Root }
            finally { [System.Environment]::CurrentDirectory = $DirectoryBefore }
            Should -Invoke Import-Module -Times 1 -Exactly -ParameterFilter { $Name -eq 'Az.Accounts' }
            Should -Invoke Disable-AzContextAutosave -Times 1 -Exactly
            Should -Invoke Import-AzContext -Times 1 -Exactly -ParameterFilter { $Path -eq (Join-Path $Root 'snapshot.json') }
            @(Get-ChildItem -LiteralPath $Root -Filter 'snapshot.json.imported-*' -Force).Count | Should -Be 1
            $Summary.Status | Should -Be 'ok'
        }
    }
}

Describe 'Run-AllSubscriptions.ps1: under -StreamIsolation Runspace a stream starts a subscription only when free memory allows' {
    # Enter-StreamAdmission runs directly here, with an injected free-memory reader and log, and from thread
    # jobs that share one state. The real worker runs with -SharedProcess and a state against stub inventories,
    # in this runspace and as thread jobs, and the wrapper blocks that create the state and hand it to each stream
    # are lifted from its parsed source and run, as in the Describe above.
    BeforeAll {
        $script:AdRoot = Split-Path $PSScriptRoot -Parent
    }

    It 'admits at once when free memory is at the floor, after one gen-0 reading, and records the subscription as in progress' {
        $State = New-StreamAdmissionState -FloorGB 2 -PollSeconds 0.05 -MaxWaitSeconds 30
        [void]$State.Holders.Add('other')
        $Calls = [System.Collections.Generic.List[bool]]::new()
        $Logs = [System.Collections.Generic.List[object]]::new()
        $Reader = { param([bool]$Full) $Calls.Add($Full); 2.0 }.GetNewClosure()
        $LogBlock = { param([string]$Message, [string]$Color) $Logs.Add([pscustomobject]@{ Message = $Message; Color = $Color }) }.GetNewClosure()
        $Admission = Enter-StreamAdmission -State $State -Holder 'sub-a' -Subscription 'Sub A (sub-a)' -FreeMemoryReader $Reader -Log $LogBlock
        $Admission.Reason | Should -Be 'memory'
        @($State.Holders | Sort-Object) | Should -Be @('other', 'sub-a')
        $State.Waiting.Count | Should -Be 0
        @($Calls) | Should -Be @($false) -Because 'no full collection is needed when the gen-0 reading already clears the floor'
        $Logs.Count | Should -Be 0 -Because 'only a wait is logged'
    }

    It 'admits below the floor when no other subscription is in progress, without reading memory' {
        $State = New-StreamAdmissionState -FloorGB 2 -PollSeconds 0.05 -MaxWaitSeconds 30
        $Calls = [System.Collections.Generic.List[bool]]::new()
        $Logs = [System.Collections.Generic.List[object]]::new()
        $Reader = { param([bool]$Full) $Calls.Add($Full); 0.1 }.GetNewClosure()
        $LogBlock = { param([string]$Message, [string]$Color) $Logs.Add([pscustomobject]@{ Message = $Message; Color = $Color }) }.GetNewClosure()
        $Admission = Enter-StreamAdmission -State $State -Holder 'sub-a' -Subscription 'Sub A (sub-a)' -FreeMemoryReader $Reader -Log $LogBlock
        $Admission.Reason | Should -Be 'alone'
        @($State.Holders) | Should -Be @('sub-a')
        $Calls.Count | Should -Be 0
        $Logs.Count | Should -Be 0
    }

    It 'below the floor it runs one full collection, waits on gen-0 readings every poll, and is admitted once memory recovers' {
        $State = New-StreamAdmissionState -FloorGB 2 -PollSeconds 0.05 -MaxWaitSeconds 30
        [void]$State.Holders.Add('other')
        $Calls = [System.Collections.Generic.List[bool]]::new()
        $Logs = [System.Collections.Generic.List[object]]::new()
        $Readings = [System.Collections.Generic.Queue[double]]::new([double[]]@(1.0, 1.5, 1.0, 1.0, 3.0))
        $Reader = { param([bool]$Full) $Calls.Add($Full); $Readings.Dequeue() }.GetNewClosure()
        $LogBlock = { param([string]$Message, [string]$Color) $Logs.Add([pscustomobject]@{ Message = $Message; Color = $Color }) }.GetNewClosure()
        $Admission = Enter-StreamAdmission -State $State -Holder 'sub-a' -Subscription 'Sub A (sub-a)' -FreeMemoryReader $Reader -Log $LogBlock
        $Admission.Reason | Should -Be 'memory'
        $Admission.FreeGB | Should -Be 3.0
        $Admission.WaitedSeconds | Should -BeGreaterOrEqual 0.15 -Because 'three polls of 0.05 s came before the reading that cleared the floor'
        $State.Holders.Count | Should -Be 2
        $State.LastFullCollection | Should -Not -BeNullOrEmpty
        @($Calls) | Should -Be @($false, $true, $false, $false, $false) -Because 'one full collection before the first wait, then gen-0 readings only'
        $Logs.Count | Should -Be 2 -Because 'one line when the wait starts and one on admission'
        $Logs[0].Message | Should -Be 'waiting for free memory before starting Sub A (sub-a): 1.5 GB free, floor 2 GB (-StreamMemoryGB), 1 other subscription(s) in progress, 0 stream(s) ahead of it'
        $Logs[0].Color | Should -Be 'Yellow'
        $Logs[1].Message | Should -Match '^admitted Sub A \(sub-a\) after waiting \d+ s: 3\.0 GB free$'
    }

    It 'skips the full collection when another stream ran one within the poll interval' {
        foreach ($Recent in @($true, $false))
        {
            $State = New-StreamAdmissionState -FloorGB 2 -PollSeconds 30 -MaxWaitSeconds 0.3
            [void]$State.Holders.Add('other')
            if ($Recent) { $State.LastFullCollection = [System.Diagnostics.Stopwatch]::GetTimestamp() }
            $Calls = [System.Collections.Generic.List[bool]]::new()
            $Reader = { param([bool]$Full) $Calls.Add($Full); 0.5 }.GetNewClosure()
            $Admission = Enter-StreamAdmission -State $State -Holder 'sub-a' -Subscription 'Sub A (sub-a)' -FreeMemoryReader $Reader -Log { param([string]$Message, [string]$Color) }
            $Admission.Reason | Should -Be 'max-wait'
            if ($Recent)
            {
                @($Calls) | Should -Be @($false) -Because 'one full collection ran just before, and the heap is shared'
            }
            else
            {
                @($Calls) | Should -Be @($false, $true)
            }
        }
    }

    It 'is admitted as soon as no other subscription is in progress, woken by the release rather than by its next poll' {
        # A poll interval of 30 s makes the stream sleep in 1 s slices, so only the release's wake can admit it sooner.
        $State = New-StreamAdmissionState -FloorGB 2 -PollSeconds 30 -MaxWaitSeconds 60
        [void]$State.Holders.Add('other')
        $Ready = [System.Threading.ManualResetEventSlim]::new($false)
        $Started = [System.Threading.ManualResetEventSlim]::new($false)
        $Logs = [System.Collections.Generic.List[object]]::new()
        $LogBlock = { param([string]$Message, [string]$Color) $Logs.Add([pscustomobject]@{ Message = $Message; Color = $Color }); if ($Message -like 'waiting*') { $Started.Set() } }.GetNewClosure()
        # The other stream finishes its subscription 0.2 s after this one starts waiting.
        $Other = Start-ThreadJob -ScriptBlock {
            param([string]$FunctionsPath, [hashtable]$State, [System.Threading.ManualResetEventSlim]$Ready, [System.Threading.ManualResetEventSlim]$Started)
            . $FunctionsPath
            $Ready.Set()
            if ($Started.Wait(30000))
            {
                Start-Sleep -Milliseconds 200
                [System.Diagnostics.Stopwatch]::GetTimestamp()
                Exit-StreamAdmission -State $State -Holder 'other'
            }
        } -ArgumentList $script:FunctionsPath, $State, $Ready, $Started
        try
        {
            $Ready.Wait(30000) | Should -BeTrue
            $Admission = Enter-StreamAdmission -State $State -Holder 'sub-c' -Subscription 'Sub C (sub-c)' -FreeMemoryReader { param([bool]$Full) 0.5 } -Log $LogBlock
            $AdmittedTick = [System.Diagnostics.Stopwatch]::GetTimestamp()
            $ReleaseTick = Receive-Job -Job $Other -Wait
        }
        finally
        {
            $Other | Remove-Job -Force
            $Ready.Dispose()
            $Started.Dispose()
        }
        $Admission.Reason | Should -Be 'alone'
        $HandoffSeconds = ($AdmittedTick - $ReleaseTick) / [double][System.Diagnostics.Stopwatch]::Frequency
        $HandoffSeconds | Should -BeLessThan 0.5 -Because ([string]::Format([cultureinfo]::InvariantCulture, 'the release wakes the waiting stream at once; it took {0:N3} s', $HandoffSeconds))
        @($State.Holders) | Should -Be @('sub-c') -Because 'the other subscription left and this one entered'
        $Logs.Count | Should -Be 2
        $Logs[1].Message | Should -Match '^admitted Sub C \(sub-c\) after waiting \d+ s: no other subscription in progress$'
    }

    It 'writes the waiting line without holding the lock' {
        $State = New-StreamAdmissionState -FloorGB 2 -PollSeconds 0.05 -MaxWaitSeconds 30
        [void]$State.Holders.Add('other')
        $Lock = $State['Lock']
        $Logs = [System.Collections.Generic.List[object]]::new()
        $Readings = [System.Collections.Generic.Queue[double]]::new([double[]]@(1.0, 1.5, 3.0))
        $Reader = { param([bool]$Full) $Readings.Dequeue() }.GetNewClosure()
        # Monitor.IsEntered answers for the calling thread, which is the one running Enter-StreamAdmission.
        $LogBlock = { param([string]$Message, [string]$Color) $Logs.Add([pscustomobject]@{ Message = $Message; LockHeld = [System.Threading.Monitor]::IsEntered($Lock) }) }.GetNewClosure()
        $Admission = Enter-StreamAdmission -State $State -Holder 'sub-a' -Subscription 'Sub A (sub-a)' -FreeMemoryReader $Reader -Log $LogBlock
        $Admission.Reason | Should -Be 'memory'
        $Logs.Count | Should -Be 2
        $Logs[0].Message | Should -Be 'waiting for free memory before starting Sub A (sub-a): 1.5 GB free, floor 2 GB (-StreamMemoryGB), 1 other subscription(s) in progress, 0 stream(s) ahead of it'
        $Logs[0].LockHeld | Should -BeFalse -Because 'a slow host write while the lock is held would hold up every other stream'
        $Logs[1].LockHeld | Should -BeFalse
        [System.Threading.Monitor]::IsEntered($Lock) | Should -BeFalse -Because 'the lock taken back after the waiting line is let go again on admission'
    }

    It 'is admitted at once when the subscription ahead of it ends while its waiting line is being written' {
        # A poll interval of 30 s makes the stream sleep in 1 s slices. The release lands while the lock is free for
        # the waiting line, so its wake finds no stream asleep, and only a check before the first sleep admits it sooner.
        $State = New-StreamAdmissionState -FloorGB 2 -PollSeconds 30 -MaxWaitSeconds 60
        [void]$State.Holders.Add('other')
        $Release = ${function:Exit-StreamAdmission}
        $LogBlock = { param([string]$Message, [string]$Color) if ($Message -like 'waiting*') { & $Release -State $State -Holder 'other' } }.GetNewClosure()
        $Admission = Enter-StreamAdmission -State $State -Holder 'sub-g' -Subscription 'Sub G (sub-g)' -FreeMemoryReader { param([bool]$Full) 0.5 } -Log $LogBlock
        $Admission.Reason | Should -Be 'alone'
        $Admission.WaitedSeconds | Should -BeLessThan 0.9 -Because ([string]::Format([cultureinfo]::InvariantCulture, 'a check before the first 1 s sleep admits it at once; it waited {0:N3} s', $Admission.WaitedSeconds))
        @($State.Holders) | Should -Be @('sub-g')
        $State.Waiting.Count | Should -Be 0
    }

    It 'leaves the queue when writing its waiting line fails, so the stream behind it is not held up' {
        # The waiting line is written without the lock, so a failure there has to take the lock back to leave the queue.
        $State = New-StreamAdmissionState -FloorGB 2 -PollSeconds 30 -MaxWaitSeconds 60
        [void]$State.Holders.Add('other')
        $Lock = $State['Lock']
        { Enter-StreamAdmission -State $State -Holder 'sub-h' -Subscription 'Sub H (sub-h)' -FreeMemoryReader { param([bool]$Full) 0.5 } -Log { param([string]$Message, [string]$Color) throw 'the host write failed' } } | Should -Throw '*the host write failed*'
        $State.Waiting.Count | Should -Be 0 -Because 'only the head of the queue can be admitted, so a token left there would hold every later stream forever'
        @($State.Holders) | Should -Be @('other')
        [System.Threading.Monitor]::IsEntered($Lock) | Should -BeFalse
        Exit-StreamAdmission -State $State -Holder 'other'
        $Next = Enter-StreamAdmission -State $State -Holder 'sub-i' -Subscription 'Sub I (sub-i)' -FreeMemoryReader { param([bool]$Full) 0.5 } -Log { param([string]$Message, [string]$Color) }
        $Next.Reason | Should -Be 'alone'
    }

    It 'leaves the queue and the lock when its stream is stopped while it writes its waiting line' {
        # The stop lands while the lock is let go for the line, so the finally block has to take it back to leave the queue.
        $State = New-StreamAdmissionState -FloorGB 2 -PollSeconds 30 -MaxWaitSeconds 60
        [void]$State.Holders.Add('other')
        $Lock = $State['Lock']
        $Writing = [System.Threading.ManualResetEventSlim]::new($false)
        $Job = Start-ThreadJob -ScriptBlock {
            param([string]$FunctionsPath, [hashtable]$State, [System.Threading.ManualResetEventSlim]$Writing)
            . $FunctionsPath
            $LogBlock = { param([string]$Message, [string]$Color) if ($Message -like 'waiting*') { $Writing.Set(); Start-Sleep -Seconds 30 } }.GetNewClosure()
            Enter-StreamAdmission -State $State -Holder 'sub-j' -Subscription 'Sub J (sub-j)' -FreeMemoryReader { param([bool]$Full) 0.5 } -Log $LogBlock
        } -ArgumentList $script:FunctionsPath, $State, $Writing
        $Taken = $false
        try
        {
            $Writing.Wait(30000) | Should -BeTrue
            $State.Waiting.Count | Should -Be 1 -Because 'the stream stays queued while it writes'
            Stop-Job -Job $Job
            $null = Wait-Job -Job $Job -Timeout 30
            $Job.State | Should -Be 'Stopped'
            $State.Waiting.Count | Should -Be 0 -Because 'a token left at the head of the queue would hold every later stream'
            @($State.Holders) | Should -Be @('other')
            $Taken = [System.Threading.Monitor]::TryEnter($Lock, 1000)
            $Taken | Should -BeTrue -Because 'a stopped stream must not leave the lock held'
        }
        finally
        {
            if ($Taken) { [System.Threading.Monitor]::Exit($Lock) }
            $Job | Remove-Job -Force
            $Writing.Dispose()
        }
    }

    It 'refuses a caller that already holds the lock, and leaves that hold alone' {
        # The lock is let go while the waiting line is written, so a call made under the caller's own hold would give
        # that hold away; it is refused before anything is queued.
        $State = New-StreamAdmissionState -FloorGB 2 -PollSeconds 0.05 -MaxWaitSeconds 30
        $Lock = $State['Lock']
        $LockTaken = $false
        try
        {
            [System.Threading.Monitor]::Enter($Lock, [ref]$LockTaken)
            { Enter-StreamAdmission -State $State -Holder 'sub-k' -Subscription 'Sub K (sub-k)' -FreeMemoryReader { param([bool]$Full) 0.5 } -Log { param([string]$Message, [string]$Color) } } | Should -Throw '*must not be called while holding the admission lock*'
            [System.Threading.Monitor]::IsEntered($Lock) | Should -BeTrue -Because 'the caller''s own hold is left alone'
            $State.Waiting.Count | Should -Be 0
            $State.Holders.Count | Should -Be 0
        }
        finally
        {
            if ($LockTaken) { [System.Threading.Monitor]::Exit($Lock) }
        }
        [System.Threading.Monitor]::IsEntered($Lock) | Should -BeFalse
    }

    It 'is admitted with a warning once it has waited the longest wait, when memory never recovers' {
        $State = New-StreamAdmissionState -FloorGB 2 -PollSeconds 0.05 -MaxWaitSeconds 0.3
        [void]$State.Holders.Add('other-1')
        [void]$State.Holders.Add('other-2')
        $Logs = [System.Collections.Generic.List[object]]::new()
        $LogBlock = { param([string]$Message, [string]$Color) $Logs.Add([pscustomobject]@{ Message = $Message; Color = $Color }) }.GetNewClosure()
        $Admission = Enter-StreamAdmission -State $State -Holder 'sub-d' -Subscription 'Sub D (sub-d)' -FreeMemoryReader { param([bool]$Full) 0.5 } -Log $LogBlock
        $Admission.Reason | Should -Be 'max-wait'
        $Admission.WaitedSeconds | Should -BeGreaterOrEqual 0.3
        $State.Holders.Count | Should -Be 3
        $State.LastOverride | Should -Not -BeNullOrEmpty
        $Logs.Count | Should -Be 2
        $Logs[1].Color | Should -Be 'Yellow'
        $Logs[1].Message | Should -Match '^WARNING: starting Sub D \(sub-d\) after waiting \d+ s for free memory: 0\.5 GB free, floor 2 GB \(-StreamMemoryGB\), 2 other subscription\(s\) in progress\.$'
    }

    It 'with a floor of 0 it never reads memory or waits' {
        $State = New-StreamAdmissionState -FloorGB 0 -PollSeconds 5 -MaxWaitSeconds 30
        foreach ($N in 1..5) { [void]$State.Holders.Add(('other-{0}' -f $N)) }
        $Calls = [System.Collections.Generic.List[bool]]::new()
        $Logs = [System.Collections.Generic.List[object]]::new()
        $Reader = { param([bool]$Full) $Calls.Add($Full); 0.0 }.GetNewClosure()
        $LogBlock = { param([string]$Message, [string]$Color) $Logs.Add([pscustomobject]@{ Message = $Message; Color = $Color }) }.GetNewClosure()
        $Watch = [System.Diagnostics.Stopwatch]::StartNew()
        $Admission = Enter-StreamAdmission -State $State -Holder 'sub-e' -Subscription 'Sub E (sub-e)' -FreeMemoryReader $Reader -Log $LogBlock
        $Watch.Elapsed.TotalSeconds | Should -BeLessThan 2 -Because 'a single poll would take 5 s'
        $Admission.Reason | Should -Be 'disabled'
        $State.Holders.Count | Should -Be 6
        $Calls.Count | Should -Be 0
        $Logs.Count | Should -Be 0
    }

    It 'a free-memory reading that fails admits the subscription with a warning instead of failing it' {
        $State = New-StreamAdmissionState -FloorGB 2 -PollSeconds 0.05 -MaxWaitSeconds 30
        [void]$State.Holders.Add('other')
        $Logs = [System.Collections.Generic.List[object]]::new()
        $LogBlock = { param([string]$Message, [string]$Color) $Logs.Add([pscustomobject]@{ Message = $Message; Color = $Color }) }.GetNewClosure()
        $Admission = Enter-StreamAdmission -State $State -Holder 'sub-f' -Subscription 'Sub F (sub-f)' -FreeMemoryReader { param([bool]$Full) throw 'no reading' } -Log $LogBlock
        $Admission.Reason | Should -Be 'unreadable'
        $State.Holders.Count | Should -Be 2
        @($Logs.Message) | Should -Be @('WARNING: could not read free memory before starting Sub F (sub-f): no reading. Starting it without the check.')
    }

    It 'Exit-StreamAdmission releases only the token it is given, and a token not recorded changes nothing' {
        $State = New-StreamAdmissionState
        [void]$State.Holders.Add('sub-a')
        [void]$State.Holders.Add('sub-b')
        Exit-StreamAdmission -State $State -Holder 'sub-a'
        @($State.Holders) | Should -Be @('sub-b')
        Exit-StreamAdmission -State $State -Holder 'sub-a'
        Exit-StreamAdmission -State $State -Holder 'never-admitted'
        @($State.Holders) | Should -Be @('sub-b') -Because 'releasing twice, or a subscription that was never admitted, must not take another off'
    }

    It 'takes and releases the lock on the state, so a stream that cannot get the lock does not decide' {
        $State = New-StreamAdmissionState -FloorGB 2 -PollSeconds 0.05 -MaxWaitSeconds 30
        $Ready = [System.Threading.ManualResetEventSlim]::new($false)
        $Lock = $State['Lock']
        [object]::ReferenceEquals($Lock, $State.PSBase.SyncRoot) | Should -BeTrue -Because 'the lock is the table''s own SyncRoot'
        $LockTaken = $false
        $Job = $null
        try
        {
            [System.Threading.Monitor]::Enter($Lock, [ref]$LockTaken)
            $Job = Start-ThreadJob -ScriptBlock {
                param([string]$FunctionsPath, [hashtable]$State, [System.Threading.ManualResetEventSlim]$Ready)
                . $FunctionsPath
                $Ready.Set()
                (Enter-StreamAdmission -State $State -Holder 'blocked' -FreeMemoryReader { param([bool]$Full) 0.5 } -Log { param([string]$Message, [string]$Color) }).Reason
            } -ArgumentList $script:FunctionsPath, $State, $Ready
            $Ready.Wait(30000) | Should -BeTrue
            Start-Sleep -Milliseconds 500
            $Job.State | Should -Be 'Running'
            $State.Waiting.Count | Should -Be 0 -Because 'the stream is held at the lock, before it can even queue'
            $State.Holders.Count | Should -Be 0
        }
        finally
        {
            if ($LockTaken) { [System.Threading.Monitor]::Exit($Lock) }
        }
        try
        {
            Receive-Job -Job $Job -Wait | Should -Be 'alone'
        }
        finally
        {
            $Job | Remove-Job -Force
            $Ready.Dispose()
        }
        @($State.Holders) | Should -Be @('blocked')
    }

    It 'Get-GcFreeMemoryGB reads a figure from 0 up to the memory the runtime may use' {
        $TotalGB = [double][System.GC]::GetGCMemoryInfo().TotalAvailableMemoryBytes / 1GB
        foreach ($FreeGB in @((Get-GcFreeMemoryGB), (Get-GcFreeMemoryGB -Full)))
        {
            $FreeGB | Should -BeGreaterOrEqual 0
            $FreeGB | Should -BeLessOrEqual $TotalGB
        }
    }

    It 'Get-GcFreeMemoryGB stays within the heap''s room under a 2 GiB heap hard limit, and is unchanged without a limit' {
        # Each reading runs in a child pwsh, because a heap limit can only be set when a process starts.
        $Probe = Join-Path $TestDrive 'gc-free-probe.ps1'
        Set-Content -LiteralPath $Probe -Value @'
param([string]$FunctionsPath)
. $FunctionsPath
$Free = Get-GcFreeMemoryGB
$Info = [System.GC]::GetGCMemoryInfo()
$Limit = 0.0
if ([System.GC].GetMethod('GetConfigurationVariables')) { $Limit = [double][System.GC]::GetConfigurationVariables()['GCHeapHardLimit'] }
[pscustomobject]@{
    Free    = $Free
    Plain   = ([double]$Info.TotalAvailableMemoryBytes - [double]$Info.MemoryLoadBytes) / 1GB
    TotalGB = [double]$Info.TotalAvailableMemoryBytes / 1GB
    Limit   = $Limit
} | ConvertTo-Json -Compress
'@
        $Pwsh = (Get-Process -Id $PID).Path
        $Saved = $env:DOTNET_GCHeapHardLimit
        try
        {
            $env:DOTNET_GCHeapHardLimit = $null
            $Plain = & $Pwsh -NoProfile -NonInteractive -File $Probe -FunctionsPath $script:FunctionsPath | ConvertFrom-Json
            $env:DOTNET_GCHeapHardLimit = '0x80000000'
            $Limited = & $Pwsh -NoProfile -NonInteractive -File $Probe -FunctionsPath $script:FunctionsPath | ConvertFrom-Json
        }
        finally
        {
            $env:DOTNET_GCHeapHardLimit = $Saved
        }
        $Limited.Limit | Should -Be 2147483648 -Because 'the child process must run under the 2 GiB heap limit'
        $Limited.Free | Should -BeGreaterThan 0 -Because ([string]::Format([cultureinfo]::InvariantCulture, 'the heap has room under its limit; the figure was {0:N2} GB', $Limited.Free))
        $Limited.Free | Should -BeLessOrEqual 2.0 -Because 'no more than the heap''s own limit can be free to it'
        if ($Plain.Limit -eq 0)
        {
            [math]::Abs($Plain.Free - $Plain.Plain) | Should -BeLessOrEqual ($Plain.TotalGB / 100) -Because 'without a heap limit the figure is the memory not in use, as before'
        }
    }

    It 'Get-GcFreeMemoryGB -Full decommits the memory of dropped arrays, which on Windows only an aggressive collection does' {
        # On macOS any full collection decommits it, so there this proves only that a full collection ran.
        $Arrays = [System.Collections.Generic.List[byte[]]]::new()
        for ($N = 0; $N -lt 300; $N++)
        {
            $Arrays.Add([byte[]]::new(1MB))
            [System.Array]::Fill($Arrays[$N], [byte]7)
        }
        $Arrays = $null
        [System.GC]::Collect(0)
        $CommittedBefore = [double][System.GC]::GetGCMemoryInfo().TotalCommittedBytes / 1MB
        $null = Get-GcFreeMemoryGB -Full
        $CommittedAfter = [double][System.GC]::GetGCMemoryInfo().TotalCommittedBytes / 1MB
        ($CommittedBefore - $CommittedAfter) | Should -BeGreaterOrEqual 225 -Because ([string]::Format([cultureinfo]::InvariantCulture, '300 MB of arrays were dropped; the heap held {0:N0} MB committed before and {1:N0} MB after', $CommittedBefore, $CommittedAfter))
    }

    It 'two streams below the floor with nothing else in progress: one is admitted at a time, the other only after it releases' {
        $State = New-StreamAdmissionState -FloorGB 2 -PollSeconds 0.01 -MaxWaitSeconds 60
        $Barrier = [System.Threading.Barrier]::new(2)
        $Events = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
        $Rounds = 25
        # Both streams reach Enter-StreamAdmission together in every round, through the barrier.
        $Worker = {
            param([string]$FunctionsPath, [hashtable]$State, [System.Threading.Barrier]$Barrier, $Events, [string]$Name, [int]$Rounds)
            . $FunctionsPath
            for ($Round = 0; $Round -lt $Rounds; $Round++)
            {
                $Holder = '{0}-{1}' -f $Name, $Round
                $null = $Barrier.SignalAndWait(30000)
                $Admission = Enter-StreamAdmission -State $State -Holder $Holder -Subscription $Name -FreeMemoryReader { param([bool]$Full) 0.5 } -Log { param([string]$Message, [string]$Color) }
                $Events.Enqueue([pscustomobject]@{ Tick = [System.Diagnostics.Stopwatch]::GetTimestamp(); Name = $Name; Kind = 'admit'; Reason = $Admission.Reason; InProgress = $State['Holders'].Count })
                Start-Sleep -Milliseconds 20
                $Events.Enqueue([pscustomobject]@{ Tick = [System.Diagnostics.Stopwatch]::GetTimestamp(); Name = $Name; Kind = 'release'; Reason = ''; InProgress = -1 })
                Exit-StreamAdmission -State $State -Holder $Holder
            }
        }
        $Jobs = @('stream-a', 'stream-b' | ForEach-Object { Start-ThreadJob -ThrottleLimit 8 -ScriptBlock $Worker -ArgumentList $script:FunctionsPath, $State, $Barrier, $Events, $_, $Rounds })
        try
        {
            $null = $Jobs | Wait-Job -Timeout 120
            @($Jobs | Where-Object { $_.State -ne 'Completed' }).Count | Should -Be 0
        }
        finally
        {
            $Jobs | Remove-Job -Force
            $Barrier.Dispose()
        }
        $Ordered = @($Events.ToArray() | Sort-Object -Property Tick)
        $Ordered.Count | Should -Be (4 * $Rounds)
        for ($k = 0; $k -lt $Ordered.Count; $k += 2)
        {
            $Ordered[$k].Kind | Should -Be 'admit' -Because ('event {0} must be an admission: the previous one was released before it' -f $k)
            $Ordered[$k].InProgress | Should -Be 1 -Because 'the admitted subscription is the only one in progress'
            $Ordered[$k].Reason | Should -Be 'alone'
            $Ordered[$k + 1].Kind | Should -Be 'release'
            $Ordered[$k + 1].Name | Should -Be $Ordered[$k].Name
        }
        $State.Holders.Count | Should -Be 0
        $State.Waiting.Count | Should -Be 0
    }

    Context 'the wrapper' {
        BeforeAll {
            $AdAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:AdRoot 'Run-AllSubscriptions.ps1'), [ref]$null, [ref]$null)
            $FindAdBlock = {
                param([string]$Contains)
                $Found = @($AdAst.FindAll({ $args[0] -is [System.Management.Automation.Language.IfStatementAst] -and $args[0].Clauses[0].Item1.Extent.Text -eq "`$StreamIsolation -eq 'Runspace'" -and $args[0].Extent.Text.Contains($Contains) }, $true))
                if ($Found.Count -ne 1) { throw ("expected one Runspace block containing '{0}' in Run-AllSubscriptions.ps1, found {1}" -f $Contains, $Found.Count) }
                [scriptblock]::Create($Found[0].Extent.Text)
            }
            $script:AdCreateBlock = & $FindAdBlock 'New-StreamAdmissionState'
            $script:AdLaunchBlock = & $FindAdBlock '$Jobs += Start-ThreadJob'
            # The wrapper's own param block, run on its own, so the declared default and range are what is tested.
            $script:AdParamBlock = [scriptblock]::Create($AdAst.ParamBlock.Extent.Text + ' $StreamMemoryGB')
            $script:AdParamNames = @($AdAst.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })

            # A worker that records one admission in the state it was given, under the state's lock, and reports
            # whether it got one.
            $script:AdStubWorker = Join-Path $TestDrive 'admission-stub-worker.ps1'
            Set-Content -LiteralPath $script:AdStubWorker -Value @'
param([string]$Probe, [switch]$SharedProcess, [hashtable]$AdmissionState)
if ($null -ne $AdmissionState)
{
    [System.Threading.Monitor]::Enter($AdmissionState['Lock'])
    try { [void]$AdmissionState['Holders'].Add([string][runspace]::DefaultRunspace.Id) }
    finally { [System.Threading.Monitor]::Exit($AdmissionState['Lock']) }
}
[pscustomobject]@{ ProcessId = $PID; HasState = ($null -ne $AdmissionState) } | ConvertTo-Json | Set-Content -LiteralPath $Probe
'@
            $script:AdStubCommon = Join-Path $TestDrive 'admission-stub-common.ps1'
            Set-Content -LiteralPath $script:AdStubCommon -Value 'function Close-RdaMetricWorkerPool { }'
        }

        It '-StreamMemoryGB defaults to 2 GB and accepts 0 (off) to 1024' {
            (& $script:AdParamBlock) | Should -Be 2
            (& $script:AdParamBlock -StreamMemoryGB 0) | Should -Be 0
            (& $script:AdParamBlock -StreamMemoryGB 0.5) | Should -Be 0.5
            (& $script:AdParamBlock -StreamMemoryGB 1024) | Should -Be 1024
            { & $script:AdParamBlock -StreamMemoryGB 1025 } | Should -Throw
            { & $script:AdParamBlock -StreamMemoryGB -1 } | Should -Throw
        }

        It 'keeps every parameter of main''s wrapper at main''s position, so positional calls bind as before' {
            $Git = Get-Command -Name git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            $MainSource = $null
            if ($Git)
            {
                $MainSource = & $Git.Source -C $script:AdRoot show 'main:Run-AllSubscriptions.ps1' 2>$null
                if ($LASTEXITCODE -ne 0) { $MainSource = $null }
            }
            if (-not $MainSource)
            {
                Set-ItResult -Skipped -Because 'git or the main branch is not available here'
                return
            }
            $MainAst = [System.Management.Automation.Language.Parser]::ParseInput(($MainSource -join "`n"), [ref]$null, [ref]$null)
            $MainNames = @($MainAst.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
            $MainNames.Count | Should -BeGreaterThan 20
            @($script:AdParamNames | Select-Object -First $MainNames.Count) | Should -Be $MainNames -Because 'a parameter added before one of main''s would shift the position that one binds from'
        }

        It 'Runspace: the wrapper creates one state from -StreamMemoryGB and every stream thread job gets that same instance' {
            Set-Variable -Name StreamIsolation -Value 'Runspace'
            Set-Variable -Name StreamMemoryGB -Value 3.5
            . $script:AdCreateBlock
            $Created = $StreamAdmission
            $Created.IsSynchronized | Should -BeTrue
            $Created.FloorGB | Should -Be 3.5
            $Created.Holders.Count | Should -Be 0
            Set-Variable -Name StreamCount -Value 2
            Set-Variable -Name WorkerScript -Value $script:AdStubWorker
            Set-Variable -Name CommonFunctionsFile -Value $script:AdStubCommon
            $Jobs = @()
            $Probes = @()
            foreach ($N in 0..1)
            {
                $Probe = Join-Path $TestDrive ('admission-runspace-{0}.json' -f $N)
                $Probes += $Probe
                $WorkerArgs = @{ Probe = $Probe }
                . $script:AdLaunchBlock
                [object]::ReferenceEquals($WorkerArgs.AdmissionState, $Created) | Should -BeTrue
            }
            $null = $Jobs | Wait-Job -Timeout 60
            @($Jobs | Where-Object { $_.State -ne 'Completed' }).Count | Should -Be 0
            $Jobs | Remove-Job -Force
            $Created.Holders.Count | Should -Be 2 -Because 'each stream changed the one live state, not a copy of it'
            foreach ($Probe in $Probes)
            {
                (Get-Content -Raw -LiteralPath $Probe | ConvertFrom-Json).HasState | Should -BeTrue
            }
        }

        It 'Process (default): the wrapper creates no state, and its stream processes get none' {
            Set-Variable -Name StreamIsolation -Value 'Process'
            Set-Variable -Name StreamMemoryGB -Value 2
            . $script:AdCreateBlock
            Get-Variable -Name StreamAdmission -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
            Set-Variable -Name StreamCount -Value 2
            Set-Variable -Name WorkerScript -Value $script:AdStubWorker
            Set-Variable -Name CommonFunctionsFile -Value $script:AdStubCommon
            $Probe = Join-Path $TestDrive 'admission-process.json'
            $WorkerArgs = @{ Probe = $Probe }
            $Jobs = @()
            . $script:AdLaunchBlock
            $Jobs[0].PSJobTypeName | Should -Be 'BackgroundJob'
            $null = $Jobs | Wait-Job -Timeout 120
            $Jobs | Remove-Job -Force
            $WorkerArgs.ContainsKey('AdmissionState') | Should -BeFalse
            $Seen = Get-Content -Raw -LiteralPath $Probe | ConvertFrom-Json
            $Seen.ProcessId | Should -Not -Be $PID
            $Seen.HasState | Should -BeFalse
        }
    }

    Context 'the worker, run as a stream in this process' {
        BeforeAll {
            $script:AdWorkerPath = Join-Path $script:AdRoot 'Run-AllSubscriptions.Stream.ps1'
            # An inventory that records how many subscriptions were admitted while it ran, and fails for sub-2. It runs
            # inside the worker, so it reads the worker's own $AdmissionState and appends to the test's list
            # $AdmissionCountsSeen through its scope chain.
            $script:AdStubTree = Join-Path $TestDrive 'admission-tree'
            New-Item -ItemType Directory -Path $script:AdStubTree -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $script:AdStubTree 'ResourceInventory.ps1') -Value @'
param($TenantID, $SubscriptionID, [switch]$RunAllSubs, $ConcurrencyLimit)
$AdmissionCountsSeen.Add($AdmissionState['Holders'].Count)
if ($SubscriptionID -eq 'sub-2') { throw 'stub inventory failure' }
$Global:ResourceCount = 3
$Global:ZipOutputFile = 'report-' + $SubscriptionID + '.zip'
'@
            function script:Invoke-AdStream
            {
                param([string]$Root, [hashtable]$State, [switch]$SharedProcess)
                New-Item -ItemType Directory -Path $Root -Force | Out-Null
                $WorkerArgs = @{
                    TenantID           = 'tenant-x'
                    StreamId           = '0'
                    InventoryRoot      = $Root
                    ScriptRoot         = $script:AdStubTree
                    AzContextPath      = (Join-Path $Root 'snapshot.json')
                    StreamSummaryPath  = (Join-Path $Root 'summary.json')
                    StreamFailuresPath = (Join-Path $Root 'failures.log')
                    SubscriptionIds    = @('sub-1', 'sub-2', 'sub-3')
                    SubscriptionNames  = @('Sub One', 'Sub Two', 'Sub Three')
                    AdmissionState     = $State
                }
                if ($SharedProcess) { $WorkerArgs.SharedProcess = $true }
                $null = & $script:AdWorkerPath @WorkerArgs 6>&1
                Get-Content -Raw -LiteralPath (Join-Path $Root 'summary.json') | ConvertFrom-Json
            }
        }

        It 'with -SharedProcess every subscription runs admitted and is released after, the failed one too' {
            $State = New-StreamAdmissionState -FloorGB 1024 -PollSeconds 0.05 -MaxWaitSeconds 30
            $AdmissionCountsSeen = [System.Collections.Generic.List[int]]::new()
            $Summary = script:Invoke-AdStream -Root (Join-Path $TestDrive 'admission-shared') -State $State -SharedProcess
            @($AdmissionCountsSeen) | Should -Be @(1, 1, 1) -Because 'each subscription ran as the one admitted, so the failed one did not keep its place'
            $State.Holders.Count | Should -Be 0
            $State.Waiting.Count | Should -Be 0
            @($Summary.Completed) | Should -Be @('sub-1', 'sub-3')
            @($Summary.Failed.Id) | Should -Be @('sub-2')
        }

        It 'without -SharedProcess the worker leaves the admission state alone' {
            Mock Import-Module { }
            Mock Disable-AzContextAutosave { }
            Mock Import-AzContext { }
            $State = New-StreamAdmissionState -FloorGB 1024 -PollSeconds 0.05 -MaxWaitSeconds 30
            $AdmissionCountsSeen = [System.Collections.Generic.List[int]]::new()
            $DirectoryBefore = [System.Environment]::CurrentDirectory
            try { $Summary = script:Invoke-AdStream -Root (Join-Path $TestDrive 'admission-process-worker') -State $State }
            finally { [System.Environment]::CurrentDirectory = $DirectoryBefore }
            @($AdmissionCountsSeen) | Should -Be @(0, 0, 0)
            $State.Holders.Count | Should -Be 0
            @($Summary.Completed) | Should -Be @('sub-1', 'sub-3')
        }
    }

    Context 'the worker, run as streams in thread jobs of this process' {
        # What a test reads here comes only from the worker's console lines, its summary and the order the stub
        # inventory saw, so the same tests run against any version of the admission functions.
        BeforeAll {
            $script:AdWorkerPath = Join-Path $script:AdRoot 'Run-AllSubscriptions.Stream.ps1'
            # An inventory that records when each subscription started and ended in the probe the test put in the
            # state, and holds a subscription while its gate is closed or for its duration.
            $script:AdJobTree = Join-Path $TestDrive 'admission-jobs-tree'
            New-Item -ItemType Directory -Path $script:AdJobTree -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $script:AdJobTree 'ResourceInventory.ps1') -Value @'
param($TenantID, $SubscriptionID, [switch]$RunAllSubs, $ConcurrencyLimit)
$Probe = $AdmissionState['Probe']
$Probe.Events.Enqueue([pscustomobject]@{ Sub = $SubscriptionID; Kind = 'start'; Tick = [System.Diagnostics.Stopwatch]::GetTimestamp() })
if ($Probe.Gates.ContainsKey($SubscriptionID)) { $null = $Probe.Gates[$SubscriptionID].Wait(60000) }
if ($Probe.Durations.ContainsKey($SubscriptionID)) { Start-Sleep -Milliseconds $Probe.Durations[$SubscriptionID] }
$Probe.Events.Enqueue([pscustomobject]@{ Sub = $SubscriptionID; Kind = 'end'; Tick = [System.Diagnostics.Stopwatch]::GetTimestamp() })
$Global:ResourceCount = 1
$Global:ZipOutputFile = 'report-' + $SubscriptionID + '.zip'
'@
            function script:Start-AdStream
            {
                param([string]$Name, [hashtable]$State, [string[]]$SubIds)
                $Root = Join-Path $TestDrive ('admission-job-{0}-{1}' -f $Name, [guid]::NewGuid().ToString('N').Substring(0, 8))
                New-Item -ItemType Directory -Path $Root -Force | Out-Null
                $WorkerArgs = @{
                    TenantID           = 'tenant-x'
                    StreamId           = '0'
                    InventoryRoot      = $Root
                    ScriptRoot         = $script:AdJobTree
                    AzContextPath      = (Join-Path $Root 'snapshot.json')
                    StreamSummaryPath  = (Join-Path $Root 'summary.json')
                    StreamFailuresPath = (Join-Path $Root 'failures.log')
                    SubscriptionIds    = $SubIds
                    SubscriptionNames  = @($SubIds | ForEach-Object { 'Sub ' + $_ })
                    SharedProcess      = $true
                    AdmissionState     = $State
                }
                $Job = Start-ThreadJob -ThrottleLimit 8 -ScriptBlock { param($WorkerPath, $WorkerArgs) & $WorkerPath @WorkerArgs } -ArgumentList $script:AdWorkerPath, $WorkerArgs
                [pscustomobject]@{ Name = $Name; Job = $Job; Root = $Root }
            }
            function script:Get-AdStreamLines
            {
                param($Stream)
                @(Receive-Job -Job $Stream.Job -Keep -ErrorAction SilentlyContinue 6>&1 | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [pscustomobject]@{ Time = $_.TimeGenerated; Text = [string]$_.MessageData } })
            }
            function script:Wait-AdCondition
            {
                param([scriptblock]$Condition, [double]$TimeoutSeconds = 30)
                $Watch = [System.Diagnostics.Stopwatch]::StartNew()
                while ($Watch.Elapsed.TotalSeconds -lt $TimeoutSeconds)
                {
                    if (& $Condition) { return $true }
                    Start-Sleep -Milliseconds 50
                }
                return $false
            }
            function script:Stop-AdStreams
            {
                param($Streams)
                $Jobs = @($Streams | Where-Object { $_ } | ForEach-Object { $_.Job })
                foreach ($Job in $Jobs)
                {
                    if ($Job.State -in 'NotStarted', 'Running') { $Job.StopJobAsync() }
                }
                foreach ($Job in $Jobs)
                {
                    $null = Wait-Job -Job $Job -Timeout 15
                    if ($Job.State -notin 'NotStarted', 'Running') { Remove-Job -Job $Job -Force }
                }
            }
            function script:New-AdProbe
            {
                param([string[]]$Gated = @(), [hashtable]$Durations = @{})
                $Gates = @{}
                foreach ($Sub in $Gated) { $Gates[$Sub] = [System.Threading.ManualResetEventSlim]::new($false) }
                @{ Events = [System.Collections.Concurrent.ConcurrentQueue[object]]::new(); Gates = $Gates; Durations = $Durations }
            }
        }

        It 'a stream stopped at the lock leaves nothing in progress, so the next stream is let in at once' {
            $State = New-StreamAdmissionState -FloorGB 1024 -PollSeconds 0.2 -MaxWaitSeconds 5
            $State.Probe = script:New-AdProbe -Durations @{ 't-1' = 100 }
            $Streams = @()
            # The table's own SyncRoot, read here on one thread: the lock the admission functions take.
            $Lock = $State.PSBase.SyncRoot
            $LockTaken = $false
            try
            {
                try
                {
                    [System.Threading.Monitor]::Enter($Lock, [ref]$LockTaken)
                    $Streams += script:Start-AdStream -Name 's' -State $State -SubIds @('s-1')
                    (script:Wait-AdCondition { @(script:Get-AdStreamLines $Streams[0] | Where-Object { $_.Text -like '*processing (1 of 1)*' }).Count -gt 0 }) | Should -BeTrue
                    # The stream is now held at the lock in Enter-StreamAdmission; the stop lands once it gets the lock.
                    Start-Sleep -Milliseconds 500
                    $Streams[0].Job.StopJobAsync()
                    Start-Sleep -Milliseconds 300
                }
                finally
                {
                    if ($LockTaken) { [System.Threading.Monitor]::Exit($Lock) }
                }
                $null = Wait-Job -Job $Streams[0].Job -Timeout 30
                $Streams[0].Job.State | Should -Be 'Stopped'
                $Streams += script:Start-AdStream -Name 't' -State $State -SubIds @('t-1')
                $null = Wait-Job -Job $Streams[1].Job -Timeout 60
                $Streams[1].Job.State | Should -Be 'Completed'
                $Waits = @(script:Get-AdStreamLines $Streams[1] | Where-Object { $_.Text -like '*waiting for free memory*' })
                $Waits.Count | Should -Be 0 -Because 'nothing may still count as in progress once the stopped stream is gone'
                (Get-Content -Raw -LiteralPath (Join-Path $Streams[1].Root 'summary.json') | ConvertFrom-Json).Status | Should -Be 'ok'
                @($State.Probe.Events.ToArray() | Where-Object { $_.Sub -eq 's-1' }).Count | Should -Be 0 -Because 'the stopped stream never started its subscription'
                $State.Holders.Count | Should -Be 0
                $State.Waiting.Count | Should -Be 0
            }
            finally
            {
                script:Stop-AdStreams $Streams
            }
        }

        It 'admits the waiting streams in arrival order, so a stream that has just finished cannot go ahead of them' {
            $State = New-StreamAdmissionState -FloorGB 1024 -PollSeconds 0.2 -MaxWaitSeconds 60
            $Probe = script:New-AdProbe -Gated @('a-1') -Durations @{ 'a-2' = 300; 'a-3' = 300; 'b-1' = 300; 'c-1' = 300 }
            $State.Probe = $Probe
            $Streams = @()
            try
            {
                $Streams += script:Start-AdStream -Name 'a' -State $State -SubIds @('a-1', 'a-2', 'a-3')
                (script:Wait-AdCondition { @($Probe.Events.ToArray() | Where-Object { $_.Sub -eq 'a-1' }).Count -gt 0 }) | Should -BeTrue
                $Streams += script:Start-AdStream -Name 'b' -State $State -SubIds @('b-1')
                (script:Wait-AdCondition { @(script:Get-AdStreamLines $Streams[1] | Where-Object { $_.Text -like '*waiting for free memory*' }).Count -gt 0 }) | Should -BeTrue
                $Streams += script:Start-AdStream -Name 'c' -State $State -SubIds @('c-1')
                (script:Wait-AdCondition { @(script:Get-AdStreamLines $Streams[2] | Where-Object { $_.Text -like '*waiting for free memory*' }).Count -gt 0 }) | Should -BeTrue
                $Probe.Gates['a-1'].Set()
                (script:Wait-AdCondition -TimeoutSeconds 90 { @($Streams | Where-Object { $_.Job.State -in 'NotStarted', 'Running' }).Count -eq 0 }) | Should -BeTrue
                foreach ($Stream in $Streams)
                {
                    (Get-Content -Raw -LiteralPath (Join-Path $Stream.Root 'summary.json') | ConvertFrom-Json).Status | Should -Be 'ok'
                }
            }
            finally
            {
                $Probe.Gates['a-1'].Set()
                script:Stop-AdStreams $Streams
            }
            $Starts = @($Probe.Events.ToArray() | Where-Object { $_.Kind -eq 'start' } | Sort-Object -Property Tick | ForEach-Object { $_.Sub })
            $Starts | Should -Be @('a-1', 'b-1', 'c-1', 'a-2', 'a-3') -Because 'a went back to the end of the queue after a-1'
            $State.Holders.Count | Should -Be 0
            $State.Waiting.Count | Should -Be 0
        }

        It 'lets at most one waiting stream in per longest wait when memory stays short' {
            # The overrides are timed where they are decided: Enter-StreamAdmission stamps LastOverride under the
            # lock when it lets a waiter in for waiting too long, and the test thread samples that stamp while it
            # waits. Their warnings are logged after the lock is left, and a blocking full collection by the next
            # stream can hold a warning back (on Windows by more than 0.1 s), so the warnings are not timed.
            $State = New-StreamAdmissionState -FloorGB 1024 -PollSeconds 0.2 -MaxWaitSeconds 1
            $Probe = script:New-AdProbe -Gated @('a-1') -Durations @{ 'b-1' = 200; 'c-1' = 200 }
            $State.Probe = $Probe
            $Streams = @()
            $Overrides = @()
            $Decisions = [System.Collections.Generic.List[long]]::new()
            # Overrides are at least the longest wait (1 s) apart, and the sample runs every ~50 ms, so none is missed.
            $SampleDecision = {
                $Stamp = $State['LastOverride']
                if ($null -ne $Stamp -and -not $Decisions.Contains([long]$Stamp)) { $Decisions.Add([long]$Stamp) }
            }
            try
            {
                $Streams += script:Start-AdStream -Name 'a' -State $State -SubIds @('a-1')
                (script:Wait-AdCondition { @($Probe.Events.ToArray() | Where-Object { $_.Sub -eq 'a-1' }).Count -gt 0 }) | Should -BeTrue
                # b and c start waiting together, so each reaches the longest wait at about the same moment.
                $Streams += script:Start-AdStream -Name 'b' -State $State -SubIds @('b-1')
                $Streams += script:Start-AdStream -Name 'c' -State $State -SubIds @('c-1')
                $IsOverride = { $_.Text -like '*WARNING: starting*for free memory*' }
                (script:Wait-AdCondition -TimeoutSeconds 30 { & $SampleDecision; @($Streams[1], $Streams[2] | ForEach-Object { script:Get-AdStreamLines $_ } | Where-Object $IsOverride).Count -ge 2 }) | Should -BeTrue
                & $SampleDecision
                $Overrides = @($Streams[1], $Streams[2] | ForEach-Object { script:Get-AdStreamLines $_ } | Where-Object $IsOverride)
                $Probe.Gates['a-1'].Set()
                (script:Wait-AdCondition -TimeoutSeconds 60 { @($Streams | Where-Object { $_.Job.State -in 'NotStarted', 'Running' }).Count -eq 0 }) | Should -BeTrue
            }
            finally
            {
                $Probe.Gates['a-1'].Set()
                script:Stop-AdStreams $Streams
            }
            $Overrides.Count | Should -Be 2
            $Decisions.Count | Should -Be 2 -Because 'each of the two waiters is let in by its own override decision, and each decision stamps LastOverride'
            $Gap = ($Decisions[1] - $Decisions[0]) / [double][System.Diagnostics.Stopwatch]::Frequency
            $Gap | Should -BeGreaterOrEqual 1 -Because ([string]::Format([cultureinfo]::InvariantCulture, 'the second waiter may be let in only a full longest wait (1 s) after the first; the two decisions were {0:N3} s apart', $Gap))
            $State.Holders.Count | Should -Be 0
        }
    }
}
