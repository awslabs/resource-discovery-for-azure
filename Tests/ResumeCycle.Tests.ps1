# Sequential -Resume cycle tests (offline / deterministic)
#
# Exercises the multi-subscription wrapper's SEQUENTIAL resume contract end to
# end WITHOUT a live Azure run. The wrapper body (Run-AllSubscriptions.ps1)
# authenticates + enumerates + has top-level side effects, so it cannot be
# dot-sourced; like Tests/RunAllSubscriptionsReconciliation.Tests.ps1, we
# instead drive the REAL shared state helpers (Get-ResumeStateObject /
# Save-CompletedSubscriptionIds / Get-SubscriptionDelta) through the wrapper's
# EXACT seed / skip / append / persist expressions and assert the observable
# resume behaviour:
#
#   - a fresh run seeds an empty completed list with the wrapper's own
#     @(if...else @()) idiom, so the first append is a real array push (never a
#     $null-collapse -> string concatenation),
#   - completing a subset persists a real multi-element completed set,
#   - a -Resume run skips exactly the already-completed subs and processes the
#     remainder,
#   - a -Resume run after everything completed skips ALL subs, and
#   - Get-SubscriptionDelta reports no gaps once the responsible set is done.
#
# The behavioural tests run a faithful COPY of the wrapper's seed expression, so
# they exercise the production seed shape but cannot by themselves catch a
# regression in the wrapper SOURCE. A dedicated source-guard It therefore asserts
# the real seed line in Run-AllSubscriptions.ps1 keeps its outer @(...) wrapper -
# the exact thing whose removal reintroduces the $null-collapse bug that parse +
# review + the pure-helper unit tests all missed.
#
# Run with: Invoke-Pester ./Tests/ResumeCycle.Tests.ps1 -Output Detailed

BeforeAll {
    $script:FunctionsPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Functions/RunAllSubscriptions.Functions.ps1'
    if (-not (Test-Path $script:FunctionsPath))
    {
        throw "Could not find shared functions file at $script:FunctionsPath"
    }
    . $script:FunctionsPath

    $TargetFunctions = @('Get-ResumeStateObject', 'Get-CompletedSubscriptionIds', 'Save-CompletedSubscriptionIds', 'Get-SubscriptionDelta', 'Remove-FailedAttempt')
    foreach ($Fn in $TargetFunctions)
    {
        if (-not (Get-Command $Fn -CommandType Function -ErrorAction SilentlyContinue))
        {
            throw "Expected function '$Fn' to be defined by $script:FunctionsPath, but it was not. Has it been renamed or removed?"
        }
    }

    $TmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { '/tmp' }
    $script:TestRoot = Join-Path $TmpBase ("ResumeCycleTest_" + [guid]::NewGuid().ToString().Substring(0, 8))
    New-Item -ItemType Directory -Path $script:TestRoot -Force | Out-Null

    $script:Tenant = 'tenant-resume-cycle'

    # Model the wrapper's sequential loop over an ordered subscription list,
    # exactly mirroring its seed / skip / append / persist expressions so the
    # test fails if any of them regress:
    #   seed:    $s = Get-ResumeStateObject -Path $f -Tenant $t
    #            $CompletedIds = @(if ($s -and $s.CompletedSubscriptionIds) { $s.CompletedSubscriptionIds } else { @() })
    #   skip:    if ($Resume -and ($CompletedIds -contains $Sub.Id)) { skip }
    #   append:  if (-not ($CompletedIds -contains $Sub.Id)) { $CompletedIds += $Sub.Id }
    #   persist: Save-CompletedSubscriptionIds -Ids $CompletedIds ...
    # $FailWhenId lets a test simulate a sub that fails (never marked complete).
    function Invoke-SequentialResumeRun
    {
        param(
            [string]$StateFile,
            [string[]]$SubIds,
            [switch]$Resume,
            [string[]]$FailWhenId = @()
        )
        # Seed EXACTLY as the wrapper does (Run-AllSubscriptions.ps1): read the
        # state object once, then derive the completed list with the same
        # @(if...else @()) idiom. The outer @(...) is what stops a fresh-run
        # empty result collapsing to $null (which would turn the first += into
        # string concatenation). Going through Get-ResumeStateObject - not the
        # already-@()-wrapping Get-CompletedSubscriptionIds - keeps this harness
        # faithful to the production seed shape.
        $SeedState = Get-ResumeStateObject -Path $StateFile -Tenant $script:Tenant
        $CompletedIds = @(if ($SeedState -and $SeedState.CompletedSubscriptionIds) { $SeedState.CompletedSubscriptionIds } else { @() })
        $Processed = @()
        $Skipped = @()
        foreach ($Id in $SubIds)
        {
            if ($Resume -and ($CompletedIds -contains $Id))
            {
                $Skipped += $Id
                continue
            }
            $Processed += $Id
            if ($FailWhenId -contains $Id) { continue }   # failed sub: not marked complete
            if (-not ($CompletedIds -contains $Id))
            {
                $CompletedIds += $Id
                Save-CompletedSubscriptionIds -Path $StateFile -Tenant $script:Tenant -Ids $CompletedIds -FailedAttempts @()
            }
        }
        return [pscustomobject]@{
            Processed    = @($Processed)
            Skipped      = @($Skipped)
            CompletedIds = @($CompletedIds)
        }
    }
}

AfterAll {
    if ($script:TestRoot -and (Test-Path $script:TestRoot))
    {
        Remove-Item -Path $script:TestRoot -Recurse -Force
    }
}

Describe 'Sequential -Resume cycle' {
    BeforeEach {
        $script:StateFile = Join-Path $script:TestRoot ((([guid]::NewGuid()).ToString('N')) + '.json')
    }
    AfterEach {
        if (Test-Path $script:StateFile) { Remove-Item -Path $script:StateFile -Force }
    }

    It 'the wrapper seeds the completed-ids list as an @()-wrapped array (source guard against the $null-collapse regression)' {
        # The behavioural tests below run a faithful COPY of the wrapper's seed
        # expression, so they cannot by themselves catch a regression in the
        # wrapper SOURCE. This guard reads the real seed line in
        # Run-AllSubscriptions.ps1 and asserts it keeps its outer @(...) wrapper -
        # the exact thing whose removal lets an empty fresh-run result collapse
        # to $null and turns the first += into string concatenation.
        $WrapperPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Run-AllSubscriptions.ps1'
        Test-Path $WrapperPath | Should -BeTrue
        $SeedLines = @(Get-Content -Path $WrapperPath |
                Where-Object { $_ -notmatch '^\s*#' } |
                Where-Object { $_ -match '\$CompletedIds\s*=\s*@\(\s*if' })
        # Exactly one such seed line: 0 means the @(...) wrapper was dropped
        # (the $null-collapse regression); >1 means a stray/duplicate seed slipped in.
        $SeedLines.Count | Should -Be 1 -Because 'the completed-ids seed must stay wrapped in @(...) so an empty start is a real array, not $null'
    }

    It 'a fresh run completing a subset persists a real multi-element completed array (not a mashed string)' {
        # Fresh run interrupted after the first two subs.
        $First = Invoke-SequentialResumeRun -StateFile $script:StateFile -SubIds @('s1', 's2')
        $First.CompletedIds.Count | Should -Be 2
        # The persisted state must round-trip as a 2-element array, NOT a single
        # concatenated string ('s1s2').
        $Persisted = Get-Content -Path $script:StateFile -Raw | ConvertFrom-Json
        @($Persisted.CompletedSubscriptionIds).Count | Should -Be 2
        (@($Persisted.CompletedSubscriptionIds) -join '|') | Should -Be 's1|s2'
    }

    It 'a -Resume run skips exactly the completed subs and processes only the remainder' {
        $Subs = @('s1', 's2', 's3', 's4')
        $null = Invoke-SequentialResumeRun -StateFile $script:StateFile -SubIds @('s1', 's2')
        $Resumed = Invoke-SequentialResumeRun -StateFile $script:StateFile -SubIds $Subs -Resume
        ($Resumed.Skipped | Sort-Object)   | Should -Be @('s1', 's2')
        ($Resumed.Processed | Sort-Object) | Should -Be @('s3', 's4')
        ($Resumed.CompletedIds | Sort-Object) | Should -Be @('s1', 's2', 's3', 's4')
    }

    It 'a -Resume run after everything completed skips ALL subs (nothing reprocessed)' {
        $Subs = @('s1', 's2', 's3')
        $null = Invoke-SequentialResumeRun -StateFile $script:StateFile -SubIds $Subs
        $Resumed = Invoke-SequentialResumeRun -StateFile $script:StateFile -SubIds $Subs -Resume
        ($Resumed.Skipped | Sort-Object) | Should -Be @('s1', 's2', 's3')
        $Resumed.Processed.Count | Should -Be 0
    }

    It 'a failed sub is NOT persisted as completed, so -Resume retries exactly it' {
        $Subs = @('s1', 's2', 's3')
        # s2 fails on the first pass -> only s1, s3 complete.
        $First = Invoke-SequentialResumeRun -StateFile $script:StateFile -SubIds $Subs -FailWhenId @('s2')
        ($First.CompletedIds | Sort-Object) | Should -Be @('s1', 's3')
        # -Resume must reprocess exactly s2.
        $Resumed = Invoke-SequentialResumeRun -StateFile $script:StateFile -SubIds $Subs -Resume
        $Resumed.Processed | Should -Be @('s2')
        ($Resumed.Skipped | Sort-Object) | Should -Be @('s1', 's3')
    }

    It 'reconciliation reports no incomplete once the responsible set is fully completed' {
        $Subs = @('s1', 's2', 's3', 's4')
        $Run = Invoke-SequentialResumeRun -StateFile $script:StateFile -SubIds $Subs
        # End universe = start universe (no drift); everything owed is done.
        $Delta = Get-SubscriptionDelta -StartIds $Subs -EndIds $Subs -CompletedIds $Run.CompletedIds
        $Delta.Incomplete | Should -BeNullOrEmpty
        $Delta.Vanished   | Should -BeNullOrEmpty
        $Delta.New        | Should -BeNullOrEmpty
    }

    It 'reconciliation flags a sub still owed but not completed after an interrupted run' {
        $Subs = @('s1', 's2', 's3')
        $Run = Invoke-SequentialResumeRun -StateFile $script:StateFile -SubIds @('s1')   # interrupted early
        $Delta = Get-SubscriptionDelta -StartIds $Subs -EndIds $Subs -CompletedIds $Run.CompletedIds
        ($Delta.Incomplete | Sort-Object) | Should -Be @('s2', 's3')
    }
}
