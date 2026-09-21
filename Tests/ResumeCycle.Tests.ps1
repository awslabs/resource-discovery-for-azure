# Offline tests of the wrapper's sequential -Resume contract: drive the real state
# helpers through its exact seed/skip/append/persist so the first += is an array push, never a $null-collapse.

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

    # Models the wrapper's sequential loop, mirroring its seed/skip/append/persist
    # expressions so a regression in any of them fails here; $FailWhenId simulates a failing sub.
    function Invoke-SequentialResumeRun
    {
        param(
            [string]$StateFile,
            [string[]]$SubIds,
            [switch]$Resume,
            [string[]]$FailWhenId = @()
        )
        # Seed EXACTLY as the wrapper does: read state once, project via
        # Get-CompletedSubscriptionIds; the outer @(...) keeps the first += an array push, not string concat.
        $SeedState = Get-ResumeStateObject -Path $StateFile -Tenant $script:Tenant
        $CompletedIds = @(Get-CompletedSubscriptionIds -Path $StateFile -Tenant $script:Tenant -State $SeedState)
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
        # Source guard: the behavioural copies can't catch a wrapper SOURCE regression,
        # so assert the real seed line keeps its outer @(...) (whose removal reintroduces the $null-collapse).
        $WrapperPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Run-AllSubscriptions.ps1'
        Test-Path $WrapperPath | Should -BeTrue
        $CodeLines = @(Get-Content -Path $WrapperPath | Where-Object { $_ -notmatch '^\s*#' })

        # The SEED specifically - projected through the reader, handed the state that
        # was already read. Exactly one: 0 means it was replaced by something else,
        # >1 means a stray/duplicate seed slipped in.
        $SeedLines = @($CodeLines | Where-Object { $_ -match '\$CompletedIds\s*=\s*@\(Get-CompletedSubscriptionIds' })
        $SeedLines.Count | Should -Be 1 -Because 'the completed-ids seed must project through the shared reader'
        $SeedLines[0] | Should -Match '-State\s+\$SeedState' -Because 'the reader must be handed the already-read state, or the blob is fetched twice'

        # EVERY assignment to $CompletedIds must keep the @(...) wrapper, not just the
        # seed. The wrapper is what stops an empty result collapsing to $null; the
        # later fold-ins (stranded per-stream state, per-stream results) are assignments
        # too and carry the same hazard. Asserting all of them is stronger than the
        # single-line check this guard started as.
        $Assignments = @($CodeLines | Where-Object { $_ -match '\$CompletedIds\s*=[^=]' })
        $Assignments.Count | Should -BeGreaterOrEqual 1 -Because 'finding zero assignments would make the loop below vacuous'
        foreach ($Line in $Assignments)
        {
            $Line | Should -Match '\$CompletedIds\s*=\s*@\(' -Because "every assignment to the completed set must be @()-wrapped, but found: $($Line.Trim())"
        }
    }

    It 'the wrapper reads the resume state exactly ONCE for all three projections' {
        # The three projections (completed ids, failed attempts, start snapshot) each
        # accept an already-read state. If any of them omitted -State it would fetch
        # the state blob again - a network round trip per projection, on the recovery
        # path where the blob is least likely to be fast.
        $WrapperPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Run-AllSubscriptions.ps1'
        Test-Path $WrapperPath | Should -BeTrue -Because 'a moved/renamed wrapper must fail with a clear missing-file message, not a misleading "read once" count of 0'
        $CodeLines = @(Get-Content -Path $WrapperPath | Where-Object { $_ -notmatch '^\s*#' })

        $Reads = @($CodeLines | Where-Object { $_ -match '=\s*Get-ResumeStateObject' })
        $Reads.Count | Should -Be 1 -Because 'the state is read once and projected, never read per view'

        foreach ($Reader in @('Get-CompletedSubscriptionIds', 'Get-FailedAttempts', 'Get-StartSnapshot'))
        {
            $Calls = @($CodeLines | Where-Object { $_ -match [regex]::Escape($Reader) })
            $Calls.Count | Should -Be 1 -Because "$Reader is projected once in the wrapper"
            $Calls[0] | Should -Match '-State\s+\$SeedState' -Because "$Reader must reuse the already-read state"
        }
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
