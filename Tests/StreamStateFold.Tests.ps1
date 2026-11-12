# Run-AllSubscriptions.ps1 at the start of a run: the per-stream resume state
# files (.resume-state-<tenant>-stream-<N>.json) an interrupted parallel run left.
#
#   - -Resume and -ResumeFailedOnly fold their records into the unified file and
#     then remove them, once the unified file on disk holds every record they
#     gave. Left in place, a run that does not reach the streams merge
#     (sequential, one subscription, or nothing left) would keep them, and every
#     later -Resume would fold the same old records in again.
#   - A file whose records are not all in the unified file afterwards is kept,
#     and the run says so.
#   - A run without either switch collects every subscription and writes its own
#     state, so such files are stale and are removed.
#
# The startup block is taken from the wrapper's parsed source and run as
# written, with the real state helpers. Offline; placeholder ids only.
#
# Run with: Invoke-Pester ./Tests/StreamStateFold.Tests.ps1 -Output Detailed

BeforeAll {
    $RepoRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $RepoRoot 'Functions/RunAllSubscriptions.Functions.ps1')
    $Ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'Run-AllSubscriptions.ps1'), [ref]$null, [ref]$null)
    $Found = @($Ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.IfStatementAst] -and $_.Clauses[0].Item1.Extent.Text -eq '$Resume -or $ResumeFailedOnly' -and $_.Extent.Text.Contains('Get-StreamResumeStateFiles') })
    if ($Found.Count -ne 1) { throw ('expected one startup fold of the per-stream state files, found {0}' -f $Found.Count) }
    $script:FoldBlock = [scriptblock]::Create($Found[0].Extent.Text)
    # The parallel parent's merge of stream summaries and per-stream state, as in
    # ResumeCarry.Tests.ps1: the orchestration try-body from its summary loop on.
    $Orch = @($Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.TryStatementAst] -and $args[0].Body.Extent.Text -match [regex]::Escape("`$WorkerScript = Join-Path `$PSScriptRoot 'Run-AllSubscriptions.Stream.ps1'") }, $true))
    if ($Orch.Count -ne 1) { throw ('expected one stream-orchestration try block, found {0}' -f $Orch.Count) }
    $Body = @($Orch[0].Body.Statements)
    $AggStart = -1
    for ($i = 0; $i -lt $Body.Count; $i++)
    {
        if ($Body[$i] -is [System.Management.Automation.Language.ForEachStatementAst] -and $Body[$i].Condition.Extent.Text -eq '$StreamSummaries' -and $Body[$i].Body.Extent.Text -match 'ResourceCounts') { $AggStart = $i; break }
    }
    if ($AggStart -lt 0) { throw 'expected the stream-summary loop in the wrapper' }
    # From the loop's list initializers on, so the lifted block starts them as the wrapper does.
    for ($i = $AggStart - 1; $i -ge 0 -and $Body[$i].Extent.Text -match '^\$Stream\w+ = @\(\)$'; $i--) { $AggStart = $i }
    if ($Body[$AggStart].Extent.Text -notmatch '^\$Stream\w+ = @\(\)$') { throw 'expected the list initializers before the stream-summary loop' }
    # A run id, as the wrapper makes one for its streams; the fixtures carry it.
    $script:MergeBlock = [scriptblock]::Create(
        "param(`$StreamSummaries, `$InventoryRoot, `$TenantID, `$ResumeStateFile, `$CompletedIds, `$FailedAttempts, `$CompletedReports)`n" +
        "`$SkippedSubscriptions = @(); `$SubResourceCounts = @(); `$FailedSubscriptions = @(); `$DiagFile = `$null; `$GoneIds = @(); `$RunStartTime = (Get-Date).AddMinutes(-1); `$StreamRunId = 'run-1'`n" +
        (@($Body[$AggStart..($Body.Count - 1)] | ForEach-Object { $_.Extent.Text }) -join "`n"))
    $TmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { '/tmp' }
    $script:TestBase = Join-Path $TmpBase ('StreamStateFold_' + [guid]::NewGuid().ToString().Substring(0, 8))
    New-Item -ItemType Directory -Path $script:TestBase -Force | Out-Null

    function script:New-StreamFile
    {
        param([string]$Root, [int]$N, [string[]]$Completed = @(), [object[]]$Failed = @())
        $Path = Join-Path $Root ('.resume-state-t-stream-{0}.json' -f $N)
        # Each completed sub with its report record, as a stream writes it (a
        # completion without one is collected again).
        $Reports = @(foreach ($Id in $Completed)
            {
                $Zip = Join-Path $Root ('report-{0}.zip' -f $Id)
                Set-Content -LiteralPath $Zip -Value 'zip'
                New-CompletedReportRecord -InventoryRoot $Root -Id $Id -Name $Id -ZipPath $Zip -Obfuscated $false
            })
        [pscustomobject]@{ RunId = 'run-1'; Tenant = 't'; StreamId = '0'; Completed = @($Completed); FailedAttempts = @($Failed); Reports = @($Reports) } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding utf8
        $Path
    }

    # Runs the startup block over $Root and returns what it printed and the state.
    function script:Invoke-Fold
    {
        param([string]$Root, [bool]$Resume, [bool]$ResumeFailedOnly = $false)
        $InventoryRoot = $Root
        $TenantID = 't'
        $ResumeStateFile = Join-Path $Root '.resume-state-t.json'
        $CompletedIds = @(Get-CompletedSubscriptionIds -Path $ResumeStateFile -Tenant $TenantID | Where-Object { $_ })
        $FailedAttempts = @(Get-FailedAttempts -Path $ResumeStateFile -Tenant $TenantID)
        $CompletedReports = @()
        $null = $InventoryRoot, $Resume, $ResumeFailedOnly, $CompletedReports, $CompletedIds, $FailedAttempts
        $UnreadableStreamFiles = @()
        $Lines = @(. $script:FoldBlock 6>&1 | ForEach-Object { [string]$_ })
        [pscustomobject]@{ Unreadable = @($UnreadableStreamFiles); StaleAside = @($StaleAsideFiles | Where-Object { $_ }); Lines = $Lines; Completed = @(Get-CompletedSubscriptionIds -Path $ResumeStateFile -Tenant 't'); Failed = @(Get-FailedAttempts -Path $ResumeStateFile -Tenant 't' | Where-Object { $null -ne $_ } | ForEach-Object Id) }
    }
}

AfterAll {
    if ($script:TestBase -and (Test-Path -LiteralPath $script:TestBase)) { Remove-Item -LiteralPath $script:TestBase -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'The per-stream resume state files at the start of a run' {
    BeforeEach {
        $script:Root = Join-Path $script:TestBase ([guid]::NewGuid().ToString().Substring(0, 8))
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
    }

    It 'are folded into the unified file and removed on <Mode>, so a later -Resume does not fold them again' -ForEach @(@{ Mode = '-Resume'; Resume = $true; Rfo = $false }, @{ Mode = '-ResumeFailedOnly'; Resume = $false; Rfo = $true }) {
        $null = script:New-StreamFile -Root $script:Root -N 0 -Completed @('sub-a')
        $null = script:New-StreamFile -Root $script:Root -N 1 -Failed @([pscustomobject]@{ Id = 'sub-x'; Name = 'Sub X'; LastFailedAt = '2026-01-01T00:00:00Z'; Reason = 'stand-in'; Attempts = 3 })
        $R = script:Invoke-Fold -Root $script:Root -Resume $Resume -ResumeFailedOnly $Rfo
        @($R.Lines | Where-Object { $_ -like 'Recovered per-stream state*' }).Count | Should -Be 1
        # Fail-safe rule: the cut-off run never proved its results saved, so its
        # completion is not folded in (sub-a is collected again); its failure is.
        $R.Completed | Should -BeNullOrEmpty
        $R.Failed | Should -Be @('sub-x')
        @(Get-StreamResumeStateFiles -InventoryRoot $script:Root -Tenant 't') | Should -BeNullOrEmpty
        $R2 = script:Invoke-Fold -Root $script:Root -Resume $true
        @($R2.Lines | Where-Object { $_ -like 'Recovered per-stream state*' }) | Should -BeNullOrEmpty
    }

    It 'keep the higher count of failed runs over an entry dated later (a clock moved back; <Mode>)' -ForEach @(@{ Mode = '-Resume'; Resume = $true }, @{ Mode = 'a run without -Resume'; Resume = $false }) {
        Save-CompletedSubscriptionIds -Path (Join-Path $script:Root '.resume-state-t.json') -Tenant 't' -Ids @() -FailedAttempts @([pscustomobject]@{ Id = 'sub-x'; Name = 'Sub X'; LastFailedAt = (Get-Date).AddDays(2).ToUniversalTime().ToString('o'); Reason = 'parent'; Attempts = 1 }) -Reports @()
        $null = script:New-StreamFile -Root $script:Root -N 0 -Failed @([pscustomobject]@{ Id = 'sub-x'; Name = 'Sub X'; LastFailedAt = (Get-Date).AddDays(-1).ToUniversalTime().ToString('o'); Reason = 'stream'; Attempts = 2 })
        $null = script:Invoke-Fold -Root $script:Root -Resume $Resume
        $E = @(Get-FailedAttempts -Path (Join-Path $script:Root '.resume-state-t.json') -Tenant 't' | Where-Object Id -eq 'sub-x')
        [int]$E[0].Attempts | Should -Be 2
        [string]$E[0].Reason | Should -Be 'stream'
    }

    It 'Merge-RecoveredFailedAttempts picks the most failed runs, then the latest time, and drops completed ids' {
        $Old = [pscustomobject]@{ Id = 'a'; Name = 'A'; LastFailedAt = '2026-01-01T00:00:00Z'; Reason = 'old'; Attempts = 3 }
        $New = [pscustomobject]@{ Id = 'a'; Name = 'A'; LastFailedAt = '2030-01-01T00:00:00Z'; Reason = 'new'; Attempts = 1 }
        $T1 = [pscustomobject]@{ Id = 'b'; Name = 'B'; LastFailedAt = '2026-01-01T00:00:00Z'; Reason = 'b1'; Attempts = 2 }
        $T2 = [pscustomobject]@{ Id = 'b'; Name = 'B'; LastFailedAt = '2026-02-01T00:00:00Z'; Reason = 'b2'; Attempts = 2 }
        $C = [pscustomobject]@{ Id = 'c'; Name = 'C'; LastFailedAt = '2026-01-01T00:00:00Z'; Reason = 'c'; Attempts = 1 }
        $R = @(Merge-RecoveredFailedAttempts -ExistingFailedAttempts @($New, $T1, $C) -RecoveredFailedAttempts @($Old, $T2) -CompletedIds @('c'))
        @($R | ForEach-Object Id | Sort-Object) | Should -Be @('a', 'b')
        @($R | Where-Object Id -eq 'a')[0].Reason | Should -Be 'old'
        @($R | Where-Object Id -eq 'b')[0].Reason | Should -Be 'b2'
    }

    It 'are kept and named, and the run stops before any stream could write over them, when the unified file does not hold their records afterwards' {
        $Path = script:New-StreamFile -Root $script:Root -N 0 -Failed @([pscustomobject]@{ Id = 'sub-a'; Name = 'Sub A'; LastFailedAt = '2026-01-01T00:00:00Z'; Reason = 'stand-in'; Attempts = 1 })
        Mock Save-CompletedSubscriptionIds { }
        Mock Exit-Wrapper { throw ('Exit-Wrapper ' + $Code) }
        $script:Out = @()
        { & { $InventoryRoot = $script:Root; $TenantID = 't'; $ResumeStateFile = Join-Path $script:Root '.resume-state-t.json'; $CompletedIds = @(); $FailedAttempts = @(); $CompletedReports = @(); $Resume = $true; $ResumeFailedOnly = $false; $UnreadableStreamFiles = @(); $null = $InventoryRoot, $TenantID, $ResumeStateFile, $CompletedIds, $FailedAttempts, $CompletedReports, $Resume, $ResumeFailedOnly, $UnreadableStreamFiles; . $script:FoldBlock 6>&1 | ForEach-Object { $script:Out += [string]$_ } } } | Should -Throw 'Exit-Wrapper 1'
        Test-Path -LiteralPath $Path | Should -BeTrue
        @($script:Out | Where-Object { $_ -like 'ERROR: The resume state file * could not be written with every record of the per-stream files*Nothing was collected (exit 1).' }).Count | Should -Be 1
    }

    It 'that cannot be read are renamed aside, named and recorded as unread, so the run is not clean and no stream writes over them' {
        $Bad = Join-Path $script:Root '.resume-state-t-stream-3.json'
        Set-Content -LiteralPath $Bad -Value '{ not json' -NoNewline
        $Good = script:New-StreamFile -Root $script:Root -N 0 -Completed @('sub-a')
        $R = script:Invoke-Fold -Root $script:Root -Resume $true
        Test-Path -LiteralPath $Bad | Should -BeFalse
        Test-Path -LiteralPath $Good | Should -BeFalse
        $Aside = @(Get-ChildItem -LiteralPath $script:Root -Force -Filter '.resume-state-t-stream-3.json.unreadable-*')
        $Aside.Count | Should -Be 1
        Get-Content -LiteralPath $Aside[0].FullName -Raw | Should -Be '{ not json'
        $R.Unreadable | Should -Be @($Aside[0].FullName)
        @($R.Lines | Where-Object { $_ -like ('WARNING: Could not read the per-stream resume state file {0} of an interrupted run:*It is kept as {1}: fix it and rename it back*' -f $Bad, $Aside[0].FullName) }).Count | Should -Be 1
        @(Get-StreamResumeStateFiles -InventoryRoot $script:Root -Tenant 't') | Should -BeNullOrEmpty -Because 'a later run does not fold it in again'
    }

    It 'are folded and removed, and the run goes on, when they hold no record and the unified file needs reconciling (a subscription both completed and failed)' {
        $State = Join-Path $script:Root '.resume-state-t.json'
        Save-CompletedSubscriptionIds -Path $State -Tenant 't' -Ids @('sub-x') -FailedAttempts @([pscustomobject]@{ Id = 'sub-x'; Name = 'Sub X'; LastFailedAt = '2026-01-01T00:00:00Z'; Reason = 'stand-in'; Attempts = 1 }) -Reports @()
        $Path = script:New-StreamFile -Root $script:Root -N 0
        Mock Exit-Wrapper { throw ('Exit-Wrapper ' + $Code) }
        $null = script:Invoke-Fold -Root $script:Root -Resume $true
        Test-Path -LiteralPath $Path | Should -BeFalse
    }

    It 'let a failure in a per-stream file win over an older completion in the unified file' {
        $State = Join-Path $script:Root '.resume-state-t.json'
        Save-CompletedSubscriptionIds -Path $State -Tenant 't' -Ids @('sub-a', 'sub-b') -FailedAttempts @() -Reports @()
        $null = script:New-StreamFile -Root $script:Root -N 0 -Failed @([pscustomobject]@{ Id = 'sub-a'; Name = 'Sub A'; LastFailedAt = '2026-01-01T00:00:00Z'; Reason = 'stand-in'; Attempts = 1 })
        $R = script:Invoke-Fold -Root $script:Root -Resume $true
        $R.Completed | Should -Be @('sub-b')
        $R.Failed | Should -Be @('sub-a')
        @(Get-StreamResumeStateFiles -InventoryRoot $script:Root -Tenant 't') | Should -BeNullOrEmpty
    }

    It 'are kept when the saved state does not match what was folded (a retry entry with an older count)' {
        $State = Join-Path $script:Root '.resume-state-t.json'
        $Path = script:New-StreamFile -Root $script:Root -N 0 -Failed @([pscustomobject]@{ Id = 'sub-x'; Name = 'Sub X'; LastFailedAt = '2026-02-01T00:00:00Z'; Reason = 'newer'; Attempts = 3 })
        Save-CompletedSubscriptionIds -Path $State -Tenant 't' -Ids @() -FailedAttempts @([pscustomobject]@{ Id = 'sub-x'; Name = 'Sub X'; LastFailedAt = '2026-01-01T00:00:00Z'; Reason = 'older'; Attempts = 1 }) -Reports @()
        Mock Save-CompletedSubscriptionIds { }
        Mock Exit-Wrapper { throw ('Exit-Wrapper ' + $Code) }
        { script:Invoke-Fold -Root $script:Root -Resume $true } | Should -Throw 'Exit-Wrapper 1'
        Test-Path -LiteralPath $Path | Should -BeTrue -Because 'the file on disk still holds the older entry'
    }

    It 'are kept when the saved retry entry differs only in its time' {
        $State = Join-Path $script:Root '.resume-state-t.json'
        $Path = script:New-StreamFile -Root $script:Root -N 0 -Failed @([pscustomobject]@{ Id = 'sub-x'; Name = 'Sub X'; LastFailedAt = '2026-02-01T00:00:00Z'; Reason = 'same'; Attempts = 2 })
        Save-CompletedSubscriptionIds -Path $State -Tenant 't' -Ids @() -FailedAttempts @([pscustomobject]@{ Id = 'sub-x'; Name = 'Sub X'; LastFailedAt = '2026-01-01T00:00:00Z'; Reason = 'same'; Attempts = 2 }) -Reports @()
        Mock Save-CompletedSubscriptionIds { }
        Mock Exit-Wrapper { throw ('Exit-Wrapper ' + $Code) }
        { script:Invoke-Fold -Root $script:Root -Resume $true } | Should -Throw 'Exit-Wrapper 1'
        Test-Path -LiteralPath $Path | Should -BeTrue -Because 'the file on disk holds the older time'
    }

    It 'read back a retry entry whole: one that differs only in its name or the case of its reason is not saved, the same one read back is' {
        $State = Join-Path $script:Root '.resume-state-t.json'
        $Entry = [pscustomobject]@{ Id = 'sub-x'; Name = 'Sub X'; LastFailedAt = (Get-Date '2026-02-01T00:00:00Z').ToString('o'); Reason = 'Same'; Attempts = 2 }
        Save-CompletedSubscriptionIds -Path $State -Tenant 't' -Ids @() -FailedAttempts @($Entry) -Reports @()
        Test-ResumeStateSaved -Path $State -Tenant 't' -Ids @() -FailedAttempts @($Entry) -Reports @() | Should -BeTrue
        Test-ResumeStateSaved -Path $State -Tenant 't' -Ids @() -FailedAttempts @([pscustomobject]@{ Id = 'sub-x'; Name = 'Sub X new'; LastFailedAt = $Entry.LastFailedAt; Reason = 'Same'; Attempts = 2 }) -Reports @() | Should -BeFalse
        Test-ResumeStateSaved -Path $State -Tenant 't' -Ids @() -FailedAttempts @([pscustomobject]@{ Id = 'sub-x'; Name = 'Sub X'; LastFailedAt = $Entry.LastFailedAt; Reason = 'same'; Attempts = 2 }) -Reports @() | Should -BeFalse
    }

    It 'put a file that is <Kind> aside on -Resume, not read it as a file with no record and remove it' -ForEach @(@{ Kind = 'empty'; Text = '' }, @{ Kind = 'an empty object'; Text = '{}' }, @{ Kind = 'a number'; Text = '0' }, @{ Kind = 'a string'; Text = '"text"' }) {
        $Odd = Join-Path $script:Root '.resume-state-t-stream-6.json'
        Set-Content -LiteralPath $Odd -Value $Text -NoNewline
        $R = script:Invoke-Fold -Root $script:Root -Resume $true
        Test-Path -LiteralPath $Odd | Should -BeFalse
        @(Get-ChildItem -LiteralPath $script:Root -Force -Filter '.resume-state-t-stream-6.json.unreadable-*').Count | Should -Be 1
        @($R.Unreadable).Count | Should -Be 1
    }

    It 'put a file that is not a stream state aside in a run without -Resume, not remove it' {
        $Odd = Join-Path $script:Root '.resume-state-t-stream-7.json'
        Set-Content -LiteralPath $Odd -Value '{}' -NoNewline
        $R = script:Invoke-Fold -Root $script:Root -Resume $false
        Test-Path -LiteralPath $Odd | Should -BeFalse
        @(Get-ChildItem -LiteralPath $script:Root -Force -Filter '.resume-state-t-stream-7.json.unreadable-*').Count | Should -Be 1
        @($R.StaleAside).Count | Should -Be 1
    }

    It 'end, in a run without -Resume, the older completion of a subscription they list as failed before they are removed' {
        $State = Join-Path $script:Root '.resume-state-t.json'
        Save-CompletedSubscriptionIds -Path $State -Tenant 't' -Ids @('sub-a', 'sub-b') -FailedAttempts @() -Reports @()
        $Path = script:New-StreamFile -Root $script:Root -N 0 -Failed @([pscustomobject]@{ Id = 'sub-a'; Name = 'Sub A'; LastFailedAt = '2026-01-01T00:00:00Z'; Reason = 'stand-in'; Attempts = 1 })
        $R = script:Invoke-Fold -Root $script:Root -Resume $false
        Test-Path -LiteralPath $Path | Should -BeFalse
        $R.Completed | Should -Be @('sub-b') -Because 'a -Resume after this run stops early must still collect Sub A'
    }

    It 'are merged whole into the retry list by a run without -Resume, also with no older completion, before they are removed' {
        $State = Join-Path $script:Root '.resume-state-t.json'
        # The unified file holds an older, lower count for Sub X and nothing for Sub Y.
        Save-CompletedSubscriptionIds -Path $State -Tenant 't' -Ids @() -FailedAttempts @([pscustomobject]@{ Id = 'sub-x'; Name = 'Sub X'; LastFailedAt = '2026-01-01T00:00:00Z'; Reason = 'older'; Attempts = 1 }) -Reports @()
        $Path = script:New-StreamFile -Root $script:Root -N 0 -Failed @(
            [pscustomobject]@{ Id = 'sub-x'; Name = 'Sub X'; LastFailedAt = '2026-02-01T00:00:00Z'; Reason = 'newer'; Attempts = 3 },
            [pscustomobject]@{ Id = 'sub-y'; Name = 'Sub Y'; LastFailedAt = '2026-02-01T00:00:00Z'; Reason = 'only here'; Attempts = 2 })
        $null = script:Invoke-Fold -Root $script:Root -Resume $false
        Test-Path -LiteralPath $Path | Should -BeFalse
        $Saved = @(Get-FailedAttempts -Path $State -Tenant 't' | Where-Object { $null -ne $_ } | Sort-Object Id)
        @($Saved | ForEach-Object Id) | Should -Be @('sub-x', 'sub-y')
        [int]$Saved[0].Attempts | Should -Be 3
        $Saved[0].Reason | Should -Be 'newer'
        [int]$Saved[1].Attempts | Should -Be 2
        $Saved[1].Reason | Should -Be 'only here'
    }

    It 'are put aside, not removed, by a run without -Resume when they cannot be read' {
        $Bad = Join-Path $script:Root '.resume-state-t-stream-4.json'
        Set-Content -LiteralPath $Bad -Value '{ not json' -NoNewline
        $R = script:Invoke-Fold -Root $script:Root -Resume $false
        Test-Path -LiteralPath $Bad | Should -BeFalse
        @(Get-ChildItem -LiteralPath $script:Root -Force -Filter '.resume-state-t-stream-4.json.unreadable-*').Count | Should -Be 1
        @($R.Lines | Where-Object { $_ -like ('WARNING: Could not read the per-stream resume state file {0} of an earlier run:*removed once this run has collected, unless the resume state still lists as completed a subscription this run did not collect.' -f $Bad) }).Count | Should -Be 1
    }

    It 'are removed as stale by a run without -Resume or -ResumeFailedOnly' {
        $null = script:New-StreamFile -Root $script:Root -N 0 -Completed @('sub-a')
        $R = script:Invoke-Fold -Root $script:Root -Resume $false
        @(Get-StreamResumeStateFiles -InventoryRoot $script:Root -Tenant 't') | Should -BeNullOrEmpty
        @($R.Lines | Where-Object { $_ -like 'Recovered per-stream state*' }) | Should -BeNullOrEmpty
        $R.Completed | Should -BeNullOrEmpty
    }
}

Describe '-ResumeFailedOnly with an empty retry list and a per-stream file it could not read' {
    It 'ends with exit 2, not a clean exit 0' {
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $PSScriptRoot -Parent) 'Run-AllSubscriptions.ps1'), [ref]$null, [ref]$null)
        $Block = @($Ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.IfStatementAst] -and $_.Clauses[0].Item1.Extent.Text -eq '$ResumeFailedOnly' -and $_.Extent.Text.Contains('Nothing to retry') })
        $Block.Count | Should -Be 1
        function Exit-Wrapper { param([int]$Code) throw ('Exit-Wrapper ' + $Code) }
        $ResumeFailedOnly = $true
        $FailedAttempts = @()
        $UnreadableStreamFiles = @('/x/.resume-state-t-stream-0.json')
        $ResumeStateFile = '/x/.resume-state-t.json'
        $null = $ResumeFailedOnly, $FailedAttempts, $UnreadableStreamFiles, $ResumeStateFile
        { . ([scriptblock]::Create($Block[0].Extent.Text)) 6>$null } | Should -Throw 'Exit-Wrapper 2'
    }
}

Describe 'A per-stream resume state file that cannot be retired at the start of a run' {
    BeforeEach {
        $script:Root = Join-Path $script:TestBase ([guid]::NewGuid().ToString().Substring(0, 8))
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        Mock Exit-Wrapper { throw ('Exit-Wrapper ' + $Code) }
    }

    It 'stops the run with exit 1, before anything is collected, when a folded file cannot be removed' {
        $Path = script:New-StreamFile -Root $script:Root -N 0 -Failed @([pscustomobject]@{ Id = 'sub-x'; Name = 'Sub X'; LastFailedAt = '2026-01-01T00:00:00Z'; Reason = 'stand-in'; Attempts = 1 })
        Mock Remove-Item -ParameterFilter { $LiteralPath -like '*-stream-*.json' } -MockWith { throw 'stand-in: read-only' }
        { script:Invoke-Fold -Root $script:Root -Resume $true } | Should -Throw 'Exit-Wrapper 1'
        Test-Path -LiteralPath $Path | Should -BeTrue
        # Its records are saved, so the run after the file is removed retries Sub X once.
        @(Get-FailedAttempts -Path (Join-Path $script:Root '.resume-state-t.json') -Tenant 't' | ForEach-Object Id) | Should -Be @('sub-x')
    }

    It 'stops a run without -Resume with exit 1 when a stale file cannot be removed' {
        $null = script:New-StreamFile -Root $script:Root -N 0 -Completed @('sub-a')
        Mock Remove-Item -ParameterFilter { $LiteralPath -like '*-stream-*.json' } -MockWith { throw 'stand-in: read-only' }
        { script:Invoke-Fold -Root $script:Root -Resume $false } | Should -Throw 'Exit-Wrapper 1'
    }

    It 'stops the run with exit 1 when a file it cannot read cannot be renamed aside either, so no stream writes over it' {
        $Bad = Join-Path $script:Root '.resume-state-t-stream-2.json'
        Set-Content -LiteralPath $Bad -Value '{ not json' -NoNewline
        Mock Move-Item { throw 'stand-in: read-only' }
        { script:Invoke-Fold -Root $script:Root -Resume $true } | Should -Throw 'Exit-Wrapper 1'
        Get-Content -LiteralPath $Bad -Raw | Should -Be '{ not json'
    }
}

Describe 'The end-of-run merge of the per-stream resume state files' {
    BeforeEach {
        $script:Root = Join-Path $script:TestBase ([guid]::NewGuid().ToString().Substring(0, 8))
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        $script:State = Join-Path $script:Root '.resume-state-t.json'
        $script:Summary = Join-Path $script:Root '.rda-stream-0-summary.json'
        @{ RunId = 'run-1'; StreamId = '0'; Tenant = 't'; Status = 'partial-failure'; Completed = @('sub-a'); ResourceCounts = @(); Failed = @(@{ Id = 'sub-b'; Name = 'Sub B'; Reason = 'stand-in failure' }) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:Summary -Encoding utf8
        $script:Streams = @([pscustomobject]@{ StreamId = 0; SummaryPath = $script:Summary; FailuresPath = (Join-Path $script:Root 'failures-stream-0.log'); SubCount = 2 })
        Set-Variable -Name Subscriptions -Value @([pscustomobject]@{ Id = 'sub-a'; Name = 'Sub A' }, [pscustomobject]@{ Id = 'sub-b'; Name = 'Sub B' })
    }

    It 'puts a subscription the stream summary lists as failed on the retry list when the stream''s own file cannot be read' {
        Set-Content -LiteralPath (Join-Path $script:Root '.resume-state-t-stream-0.json') -Value '{ not json' -NoNewline
        Set-Variable -Name UnreadableStreamFiles -Value @()
        Set-Variable -Name LeftStreamFiles -Value @()
        $null = & { . $script:MergeBlock $script:Streams $script:Root 't' $script:State @() @() @(); $UnreadableStreamFiles } 6>$null
        $Entry = @(Get-FailedAttempts -Path $script:State -Tenant 't' | Where-Object { $null -ne $_ -and $_.Id -eq 'sub-b' })
        $Entry.Count | Should -Be 1 -Because 'otherwise -ResumeFailedOnly finds nothing to retry'
        $Entry[0].Name | Should -Be 'Sub B'
        $Entry[0].Reason | Should -Be 'stand-in failure'
    }

    It 'puts a stream file that is <Kind> aside, so the subscription the summary lists as failed is on the retry list' -ForEach @(@{ Kind = 'empty'; Text = '' }, @{ Kind = 'an empty object'; Text = '{}' }, @{ Kind = 'a number'; Text = '0' }, @{ Kind = 'a string'; Text = '"text"' }) {
        $Empty = Join-Path $script:Root '.resume-state-t-stream-0.json'
        Set-Content -LiteralPath $Empty -Value $Text -NoNewline
        Set-Variable -Name UnreadableStreamFiles -Value @()
        Set-Variable -Name LeftStreamFiles -Value @()
        $Unread = @(& { . $script:MergeBlock $script:Streams $script:Root 't' $script:State @() @() @(); $UnreadableStreamFiles } 6>$null)
        @($Unread | Where-Object { $_ -like '*.resume-state-t-stream-0.json.unreadable-*' }).Count | Should -Be 1
        @(Get-FailedAttempts -Path $script:State -Tenant 't' | Where-Object { $null -ne $_ -and $_.Id -eq 'sub-b' }).Count | Should -Be 1
    }

    It 'counts a failure the stream''s own file recorded once, not again from the summary' {
        # The stream recorded the failure this run (a time after the run's start).
        [pscustomobject]@{ RunId = 'run-1'; Tenant = 't'; StreamId = '0'; Completed = @('sub-a'); FailedAttempts = @([pscustomobject]@{ Id = 'sub-b'; Name = 'Sub B'; LastFailedAt = (Get-Date).ToUniversalTime().ToString('o'); Reason = 'stand-in failure'; Attempts = 1 }); Reports = @() } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $script:Root '.resume-state-t-stream-0.json') -Encoding utf8
        Set-Variable -Name UnreadableStreamFiles -Value @()
        Set-Variable -Name LeftStreamFiles -Value @()
        $null = & { . $script:MergeBlock $script:Streams $script:Root 't' $script:State @() @() @() } 6>$null
        [int](@(Get-FailedAttempts -Path $script:State -Tenant 't' | Where-Object { $null -ne $_ -and $_.Id -eq 'sub-b' })[0].Attempts) | Should -Be 1
    }

    It 'keeps the resume state for the per-stream files it keeps because the state does not hold their records' {
        $File = Join-Path $script:Root '.resume-state-t-stream-0.json'
        [pscustomobject]@{ RunId = 'run-1'; Tenant = 't'; StreamId = '0'; Completed = @('sub-a'); FailedAttempts = @(); Reports = @() } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $File -Encoding utf8
        Mock Test-ResumeStateSaved { $false }
        Set-Variable -Name UnreadableStreamFiles -Value @()
        Set-Variable -Name LeftStreamFiles -Value @()
        $Lines = @(& { . $script:MergeBlock $script:Streams $script:Root 't' $script:State @() @() @(); 'LEFT=' + ($LeftStreamFiles -join ',') } 6>&1 | ForEach-Object { [string]$_ })
        Test-Path -LiteralPath $File | Should -BeTrue -Because 'it holds records the state does not'
        @($Lines | Where-Object { $_ -eq ('LEFT=' + $File) }).Count | Should -Be 1 -Because 'so the run keeps the state and is not a clean run'
    }

    It 'records a merged file it cannot remove, so the run keeps the state and ends with exit 2' {
        $File = Join-Path $script:Root '.resume-state-t-stream-0.json'
        [pscustomobject]@{ RunId = 'run-1'; Tenant = 't'; StreamId = '0'; Completed = @('sub-a'); FailedAttempts = @(); Reports = @() } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $File -Encoding utf8
        Mock Remove-Item -ParameterFilter { $LiteralPath -like '*-stream-*.json' } -MockWith { throw 'stand-in: read-only' }
        Set-Variable -Name UnreadableStreamFiles -Value @()
        Set-Variable -Name LeftStreamFiles -Value @()
        $Lines = @(& { . $script:MergeBlock $script:Streams $script:Root 't' $script:State @() @() @(); 'LEFT=' + ($LeftStreamFiles -join ',') } 6>&1 | ForEach-Object { [string]$_ })
        @($Lines | Where-Object { $_ -eq ('LEFT=' + $File) }).Count | Should -Be 1
        @($Lines | Where-Object { $_ -like ('WARNING: Could not remove the per-stream resume state file {0}:*ends with exit 2*' -f $File) }).Count | Should -Be 1
    }
}

Describe 'Resume state helpers with a folder whose path holds brackets' {
    It 'write and read back the state through literal paths' {
        $Dir = Join-Path $script:TestBase 'inv[1]'
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        $State = Join-Path $Dir '.resume-state-t.json'
        $Failed = @([pscustomobject]@{ Id = 'sub-x'; Name = 'Sub X'; LastFailedAt = '2026-01-01T00:00:00Z'; Reason = 'r'; Attempts = 1 })
        Save-CompletedSubscriptionIds -Path $State -Tenant 't' -Ids @('sub-a') -FailedAttempts $Failed -Reports @() 6>$null
        @(Get-CompletedSubscriptionIds -Path $State -Tenant 't') | Should -Be @('sub-a')
        @(Get-FailedAttempts -Path $State -Tenant 't' | ForEach-Object Id) | Should -Be @('sub-x')
        Test-ResumeStateSaved -Path $State -Tenant 't' -Ids @('sub-a') -FailedAttempts $Failed -Reports @() | Should -BeTrue
    }

    It 'find, write and read back the per-stream files through literal paths' {
        $Dir = Join-Path $script:TestBase 'streams[2]'
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        $Path = Join-Path $Dir '.resume-state-t-stream-0.json'
        Write-StreamState -Path $Path -Completed @('sub-a') -FailedAttempts @() -Reports @() 6>$null
        @(Get-StreamResumeStateFiles -InventoryRoot $Dir -Tenant 't' | ForEach-Object { $_.FullName }) | Should -Be @($Path)
        @((Read-StreamState -Path $Path).Completed) | Should -Be @('sub-a')
    }
}

Describe 'A temporary state file whose write fails without stopping' {
    It 'is not moved over the last good <Name> file' -ForEach @(@{ Name = 'per-stream' }, @{ Name = 'unified' }) {
        $Root = Join-Path $script:TestBase ('nonterm-' + [guid]::NewGuid().ToString().Substring(0, 8))
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
        $Path = Join-Path $Root '.resume-state-t-stream-0.json'
        Set-Content -LiteralPath $Path -Value '{"Completed":["sub-good"]}' -NoNewline
        # What a full disk does: part of the file is written, and the error does not stop the pipeline.
        Mock Set-Content -ParameterFilter { $LiteralPath -like '*.tmp' } -MockWith {
            [System.IO.File]::WriteAllText($LiteralPath, '{"Compl')
            Write-Error 'stand-in: No space left on device'
        }
        if ($Name -eq 'per-stream')
        {
            $TenantID = 't'; $StreamId = 0; $Tag = '[stream-0]'; $null = $TenantID, $StreamId, $Tag
            Write-StreamState -Path $Path -Completed @('sub-new') 6>$null 2>$null
        }
        else
        {
            Save-CompletedSubscriptionIds -Path $Path -Tenant 't' -Ids @('sub-new') -FailedAttempts @() -Reports @() 6>$null 2>$null
        }
        Get-Content -LiteralPath $Path -Raw | Should -Be '{"Completed":["sub-good"]}'
        Test-Path -LiteralPath "$Path.tmp" | Should -BeFalse
    }
}

Describe 'Write-StreamState' {
    It 'leaves the file it had when the write is stopped, never one cut short' {
        $Dir = Join-Path $script:TestBase ('ws-' + [guid]::NewGuid().ToString().Substring(0, 8))
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        $Path = Join-Path $Dir '.resume-state-t-stream-0.json'
        Write-StreamState -Path $Path -Completed @('sub-a') -FailedAttempts @() -Reports @() 6>$null
        $Before = Get-Content -LiteralPath $Path -Raw
        # The write stops part-way, as when the stream is killed during it.
        Mock Set-Content { $Target = if ($LiteralPath) { $LiteralPath } else { $Path }; [System.IO.File]::WriteAllText([string]$Target, '{ "Tena'); throw 'stand-in: stopped during the write' }
        Write-StreamState -Path $Path -Completed @('sub-a', 'sub-b') -FailedAttempts @() -Reports @() 6>$null
        Get-Content -LiteralPath $Path -Raw | Should -Be $Before
        @(Get-StreamResumeStateFiles -InventoryRoot $Dir -Tenant 't').Count | Should -Be 1
        Test-Path -LiteralPath ($Path + '.tmp') | Should -BeFalse -Because 'a failed write leaves no copy of the records behind'
    }
}

Describe 'Test-ResumeStateSaved under strict mode' {
    It 'reads a retry-list entry with no Reason without throwing' {
        $State = Join-Path $script:TestBase '.resume-state-strict.json'
        [pscustomobject]@{ TenantID = 't'; CompletedSubscriptionIds = @(); FailedAttempts = @([pscustomobject]@{ Id = 'sub-x'; Attempts = 1 }); CompletedReports = @() } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $State -Encoding utf8
        $Result = & {
            Set-StrictMode -Version Latest
            Test-ResumeStateSaved -Path $State -Tenant 't' -Ids @() -FailedAttempts @([pscustomobject]@{ Id = 'sub-x'; Attempts = 1 }) -Reports @()
        }
        $Result | Should -BeTrue
    }
}

Describe '-ResumeFailedOnly with a retry list none of whose subscriptions are listed' {
    It 'ends with exit 2 and names the way to start over, so a repeat run is not stuck without advice' {
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $PSScriptRoot -Parent) 'Run-AllSubscriptions.ps1'), [ref]$null, [ref]$null)
        $Block = @($Ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.IfStatementAst] -and $_.Clauses[0].Item1.Extent.Text -eq '$ResumeFailedOnly' -and $_.Extent.Text.Contains('Nothing to retry') })
        $Block.Count | Should -Be 1
        function Exit-Wrapper { param([int]$Code) throw ('Exit-Wrapper ' + $Code) }
        $ResumeFailedOnly = $true
        $FailedAttempts = @([pscustomobject]@{ Id = 'sub-gone'; Name = 'Sub Gone'; Attempts = 1; Reason = 'r' })
        $Subscriptions = @([pscustomobject]@{ Id = 'sub-a'; Name = 'Sub A' })
        Set-Variable -Name UnreadableStreamFiles -Value @()
        $TenantID = 't'
        $ResumeStateFile = '/x/.resume-state-t.json'
        $null = $ResumeFailedOnly, $FailedAttempts, $Subscriptions, $UnreadableStreamFiles, $TenantID, $ResumeStateFile
        $script:Out = @()
        { . ([scriptblock]::Create($Block[0].Extent.Text)) 6>&1 | ForEach-Object { $script:Out += [string]$_ } } | Should -Throw 'Exit-Wrapper 2'
        @($script:Out | Where-Object { $_ -like '*delete the resume state files .resume-state-t.json and .resume-state-t-stream-`*.json*' }).Count | Should -Be 1
    }
}

Describe 'The end-of-run merge reads stream summaries by literal path' {
    It 'reads a summary in a folder whose path holds brackets, so its failures reach the retry list' {
        $Root = Join-Path $script:TestBase 'sum[1]'
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
        $Summary = Join-Path $Root '.rda-stream-0-summary.json'
        @{ RunId = 'run-1'; StreamId = '0'; Tenant = 't'; Status = 'partial-failure'; Completed = @(); ResourceCounts = @(); Failed = @(@{ Id = 'sub-b'; Name = 'Sub B'; Reason = 'stand-in failure' }) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Summary -Encoding utf8
        $Streams = @([pscustomobject]@{ StreamId = 0; SummaryPath = $Summary; FailuresPath = (Join-Path $Root 'failures-stream-0.log'); SubCount = 1 })
        Set-Variable -Name Subscriptions -Value @([pscustomobject]@{ Id = 'sub-b'; Name = 'Sub B' })
        $State = Join-Path $Root '.resume-state-t.json'
        Set-Variable -Name UnreadableStreamFiles -Value @()
        Set-Variable -Name LeftStreamFiles -Value @()
        $null = & { . $script:MergeBlock $Streams $Root 't' $State @() @() @() } 6>$null
        @(Get-FailedAttempts -Path $State -Tenant 't' | Where-Object { $null -ne $_ } | ForEach-Object Id) | Should -Be @('sub-b')
    }
}

Describe 'Retry-list entries this run leaves out' {
    BeforeAll {
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $PSScriptRoot -Parent) 'Run-AllSubscriptions.ps1'), [ref]$null, [ref]$null)
        $Top = @($Ast.EndBlock.Statements)
        $script:NotInRunSet = @($Top | Where-Object { $_.Extent.Text -like '$RetryNotInRunIds = *' })
        # sync/pr-61 also limits them to subscriptions the tenant still lists.
        $script:TopStatements = $Top
        $script:ListedSet = @($Top | Where-Object { $_.Extent.Text -like '$ListedSubscriptionIds = *' })
        $script:TimeAt = [array]::IndexOf($Top, @($Top | Where-Object { $_.Extent.Text.StartsWith('Write-Host ("Execution Time:') })[0])
        $script:StopAt = [array]::IndexOf($Top, @($Top | Where-Object { $_ -is [System.Management.Automation.Language.IfStatementAst] -and $_.Extent.Text.Contains('Stop-Transcript') })[-1])
        $script:OwedSet = @($Top | Where-Object { $_.Extent.Text -like '$RetryOwedNotInRun = *' })
        $script:OwedIf = @($Top | Where-Object { $_ -is [System.Management.Automation.Language.IfStatementAst] -and $_.Clauses[0].Item1.Extent.Text -eq '$RetryOwedNotInRun.Count -gt 0' })
        $script:WrapperSource = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'Run-AllSubscriptions.ps1') -Raw
    }

    It 'are those whose subscription is not in the run''s set, named with the way out, and they make the run end with exit 2' {
        $script:NotInRunSet.Count | Should -Be 1
        $script:OwedSet.Count | Should -Be 1
        $script:OwedIf.Count | Should -Be 1
        $Subscriptions = @([pscustomobject]@{ Id = 'sub-a'; Name = 'Sub A' })
        $RunSubscriptionIds = @('sub-a')
        $FailedAttempts = @([pscustomobject]@{ Id = 'sub-a'; Name = 'Sub A'; Attempts = 1; Reason = 'r' }, [pscustomobject]@{ Id = 'sub-off'; Name = 'Sub Off'; Attempts = 1; Reason = 'r' })
        $RetryLimitedOwed = @()
        $TenantID = 't'
        $AllSubscriptions = @([pscustomobject]@{ Id = 'sub-a'; Name = 'Sub A' }, [pscustomobject]@{ Id = 'sub-off'; Name = 'Sub Off' })
        $null = $Subscriptions, $RunSubscriptionIds, $FailedAttempts, $RetryLimitedOwed, $TenantID, $AllSubscriptions
        foreach ($Listed in $script:ListedSet) { . ([scriptblock]::Create($Listed.Extent.Text)) }
        . ([scriptblock]::Create($script:NotInRunSet[0].Extent.Text))
        . ([scriptblock]::Create($script:OwedSet[0].Extent.Text))
        @($RetryOwedNotInRun | ForEach-Object Id) | Should -Be @('sub-off')
        $Out = @(. ([scriptblock]::Create($script:OwedIf[0].Extent.Text)) 6>&1 | ForEach-Object { [string]$_ })
        @($Out | Where-Object { $_ -like 'Not In This Run:*Sub Off (sub-off)*' }).Count | Should -Be 1
        @($Out | Where-Object { $_ -like '*delete the resume state files .resume-state-t.json*' }).Count | Should -Be 1
        $script:WrapperSource | Should -Match ([regex]::Escape('-or (@($RetryOwedNotInRun).Count -gt 0)') + '[^\n]*\) -SubscriptionsFailed')
    }

    It 'are named in the run summary, before the wrapper transcript stops, so the transcript says why the run ends with exit 2' {
        $OwedIfAt = [array]::IndexOf($script:TopStatements, $script:OwedIf[0])
        $OwedIfAt | Should -BeLessThan $script:StopAt
    }

    It 'name a subscription the tenant no longer lists apart, not as pending (sync/pr-61)' -Skip:(-not (Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'Run-AllSubscriptions.ps1') -Raw).Contains('$ListedSubscriptionIds = ')) {
        $NotListedSet = @($script:TopStatements | Where-Object { $_.Extent.Text -like '$RetryNotListed = *' })
        $NotListedIf = @($script:TopStatements | Where-Object { $_ -is [System.Management.Automation.Language.IfStatementAst] -and $_.Clauses[0].Item1.Extent.Text -eq '$RetryNotListed.Count -gt 0' })
        $NotListedSet.Count | Should -Be 1
        $NotListedIf.Count | Should -Be 1
        $FailedAttempts = @([pscustomobject]@{ Id = 'sub-gone'; Name = 'Sub Gone'; Attempts = 1; Reason = 'r' }, [pscustomobject]@{ Id = 'sub-a'; Name = 'Sub A'; Attempts = 1; Reason = 'r' })
        $AllSubscriptions = @([pscustomobject]@{ Id = 'sub-a'; Name = 'Sub A' })
        $TenantID = 't'
        $null = $FailedAttempts, $AllSubscriptions, $TenantID
        foreach ($Listed in $script:ListedSet) { . ([scriptblock]::Create($Listed.Extent.Text)) }
        . ([scriptblock]::Create($NotListedSet[0].Extent.Text))
        @($RetryNotListed | ForEach-Object Id) | Should -Be @('sub-gone')
        $Out = @(. ([scriptblock]::Create($NotListedIf[0].Extent.Text)) 6>&1 | ForEach-Object { [string]$_ })
        @($Out | Where-Object { $_ -like 'Not Listed:*Sub Gone (sub-gone)*this run could not collect them*' }).Count | Should -Be 1
        $script:WrapperSource | Should -Match ([regex]::Escape('$FailedAttempts.Count - $RetryOwedNotInRun.Count - $RetryNotListed.Count'))
    }

    It 'leave out a subscription the tenant no longer lists, which no run could collect (sync/pr-61)' -Skip:(-not (Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'Run-AllSubscriptions.ps1') -Raw).Contains('$ListedSubscriptionIds = ')) {
        $Subscriptions = @([pscustomobject]@{ Id = 'sub-a'; Name = 'Sub A' })
        $RunSubscriptionIds = @('sub-a')
        $FailedAttempts = @([pscustomobject]@{ Id = 'sub-gone'; Name = 'Sub Gone'; Attempts = 1; Reason = 'r' })
        $AllSubscriptions = @([pscustomobject]@{ Id = 'sub-a'; Name = 'Sub A' })
        $null = $Subscriptions, $RunSubscriptionIds, $FailedAttempts, $AllSubscriptions
        foreach ($Listed in $script:ListedSet) { . ([scriptblock]::Create($Listed.Extent.Text)) }
        . ([scriptblock]::Create($script:NotInRunSet[0].Extent.Text))
        @($RetryNotInRunIds) | Should -BeNullOrEmpty
    }
}

Describe 'A per-stream file an earlier run put aside as unreadable' {
    It 'is named, and keeps the state with exit 2, on every -Resume until it is fixed or deleted' {
        $Root = Join-Path $script:TestBase ('aside-' + [guid]::NewGuid().ToString().Substring(0, 8))
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
        $Aside = Join-Path $Root '.resume-state-t-stream-3.json.unreadable-20261109000000000'
        Set-Content -LiteralPath $Aside -Value '{ not json' -NoNewline
        foreach ($Run in 1..2)
        {
            $R = script:Invoke-Fold -Root $Root -Resume $true
            $R.Unreadable | Should -Be @($Aside)
            @($R.Lines | Where-Object { $_ -like ('WARNING: The per-stream resume state file {0}, put aside by an earlier run*rename it back to *.resume-state-t-stream-3.json for the next -Resume*' -f $Aside) }).Count | Should -Be 1
        }
        Remove-Item -LiteralPath $Aside -Force
        (script:Invoke-Fold -Root $Root -Resume $true).Unreadable | Should -BeNullOrEmpty
    }

    It 'is kept by a run without -Resume until it has collected, then removed as stale, so a later -Resume names nothing' {
        $Root = Join-Path $script:TestBase ('aside-plain-' + [guid]::NewGuid().ToString().Substring(0, 8))
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
        $Aside = Join-Path $Root '.resume-state-t-stream-1.json.unreadable-20261109000000000'
        Set-Content -LiteralPath $Aside -Value '{ not json' -NoNewline
        $R = script:Invoke-Fold -Root $Root -Resume $false
        Test-Path -LiteralPath $Aside | Should -BeTrue -Because 'the run may still stop before it collects'
        # One this run's own merge puts aside later holds this run's records: kept.
        $OwnAside = Join-Path $Root '.resume-state-t-stream-2.json.unreadable-20261109000000001'
        Set-Content -LiteralPath $OwnAside -Value '{ not json' -NoNewline
        # After the collection: the step before "All subscriptions processed!".
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $PSScriptRoot -Parent) 'Run-AllSubscriptions.ps1'), [ref]$null, [ref]$null)
        $AfterRun = @($Ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.IfStatementAst] -and $_.Clauses[0].Item1.Extent.Text -eq '-not ($Resume -or $ResumeFailedOnly)' -and $_.Extent.Text.Contains('$StaleAsideFiles') })
        $AfterRun.Count | Should -Be 1
        & { $InventoryRoot = $Root; $TenantID = 't'; $Resume = $false; $ResumeFailedOnly = $false; $StaleAsideFiles = $R.StaleAside; $null = $InventoryRoot, $TenantID, $Resume, $ResumeFailedOnly, $StaleAsideFiles; . ([scriptblock]::Create($AfterRun[0].Extent.Text)) } 6>$null
        Test-Path -LiteralPath $Aside | Should -BeFalse
        Test-Path -LiteralPath $OwnAside | Should -BeTrue -Because 'the file this run put aside in its own merge is named with exit 2, to be fixed and renamed back'
        Remove-Item -LiteralPath $OwnAside -Force
        # While the state lists as completed a subscription the run did not
        # collect (left out, or missing from the listing), the file is kept: it
        # may hold a newer failure of it.
        Set-Content -LiteralPath $Aside -Value '{ not json' -NoNewline
        $Out = @(& { $InventoryRoot = $Root; $TenantID = 't'; $Resume = $false; $ResumeFailedOnly = $false; $StaleAsideFiles = @($Aside); $CompletedIds = @('sub-a', 'sub-unlisted'); $RunSubscriptionIds = @('sub-a'); $null = $InventoryRoot, $TenantID, $Resume, $ResumeFailedOnly, $StaleAsideFiles, $CompletedIds, $RunSubscriptionIds; . ([scriptblock]::Create($AfterRun[0].Extent.Text)) } 6>&1 | ForEach-Object { [string]$_ })
        Test-Path -LiteralPath $Aside | Should -BeTrue
        @($Out | Where-Object { $_ -like ('Kept: {0}, *still lists 1 subscription(s) this run did not collect as completed*' -f $Aside) }).Count | Should -Be 1
        # Kept, then the run clears the resume state (a clean run): the file goes too.
        $Ast2 = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $PSScriptRoot -Parent) 'Run-AllSubscriptions.ps1'), [ref]$null, [ref]$null)
        $AfterClear = @($Ast2.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.IfStatementAst] -and $_.Extent.Text.Contains('$KeptAsideFiles') -and $_.Clauses[0].Item1.Extent.Text.Contains('Test-Path -LiteralPath $ResumeStateFile') })
        $AfterClear.Count | Should -Be 1
        # While the state file is still there, the file it guards stays.
        $StateHere = Join-Path $Root '.resume-state-t.json'
        Save-CompletedSubscriptionIds -Path $StateHere -Tenant 't' -Ids @('sub-unlisted') -FailedAttempts @() -Reports @()
        $null = & { $Resume = $false; $ResumeFailedOnly = $false; $KeptAsideFiles = @($Aside); $ResumeStateFile = $StateHere; $null = $Resume, $ResumeFailedOnly, $KeptAsideFiles, $ResumeStateFile; . ([scriptblock]::Create($AfterClear[0].Extent.Text)) } 6>$null
        Test-Path -LiteralPath $Aside | Should -BeTrue -Because 'the state still lists an older completion'
        Remove-Item -LiteralPath $StateHere -Force
        $Out = @(& { $Resume = $false; $ResumeFailedOnly = $false; $KeptAsideFiles = @($Aside); $ResumeStateFile = $StateHere; $null = $Resume, $ResumeFailedOnly, $KeptAsideFiles, $ResumeStateFile; . ([scriptblock]::Create($AfterClear[0].Extent.Text)) } 6>&1 | ForEach-Object { [string]$_ })
        Test-Path -LiteralPath $Aside | Should -BeFalse -Because 'no state is left, so no completion a -Resume would skip'
        @($Out | Where-Object { $_ -like ('Removed: {0}, kept above. The resume state is cleared*' -f $Aside) }).Count | Should -Be 1 -Because 'the Kept line said every -Resume names it'
        Set-Content -LiteralPath $Aside -Value '{ not json' -NoNewline
        # A left-out subscription with no completion (a disabled one) does not keep it.
        $null = & { $InventoryRoot = $Root; $TenantID = 't'; $Resume = $false; $ResumeFailedOnly = $false; $StaleAsideFiles = @($Aside); $CompletedIds = @('sub-a'); $RunSubscriptionIds = @('sub-a'); $AllSubscriptions = @([pscustomobject]@{ Id = 'sub-a' }, [pscustomobject]@{ Id = 'sub-off' }); $null = $InventoryRoot, $TenantID, $Resume, $ResumeFailedOnly, $StaleAsideFiles, $CompletedIds, $RunSubscriptionIds, $AllSubscriptions; . ([scriptblock]::Create($AfterRun[0].Extent.Text)) } 6>$null
        Test-Path -LiteralPath $Aside | Should -BeFalse
        (script:Invoke-Fold -Root $Root -Resume $true).Unreadable | Should -BeNullOrEmpty
    }
}

Describe 'The stream worker and the Az context snapshot use literal paths' {
    It 'writes its summary, and the parent removes the snapshot, by literal path' {
        $RepoRoot = Split-Path $PSScriptRoot -Parent
        $Worker = Get-Content -LiteralPath (Join-Path $RepoRoot 'Run-AllSubscriptions.Stream.ps1') -Raw
        $Wrapper = Get-Content -LiteralPath (Join-Path $RepoRoot 'Run-AllSubscriptions.ps1') -Raw
        $Worker | Should -Not -Match ([regex]::Escape('Set-Content -Path $StreamSummaryPath'))
        # The two short summaries in place, the full one through a temporary file.
        ([regex]::Matches($Worker, [regex]::Escape('Set-Content -LiteralPath $StreamSummaryPath'))).Count | Should -Be 2
        ([regex]::Matches($Worker, [regex]::Escape('Set-Content -LiteralPath "$StreamSummaryPath.tmp"'))).Count | Should -Be 1
        $Wrapper | Should -Not -Match ([regex]::Escape('Test-Path -Path $AzContextSnapshot'))
        $Wrapper | Should -Not -Match ([regex]::Escape('Remove-Item -Path $AzContextSnapshot'))
    }
}

Describe 'The end-of-run merge with a stream whose own file is unread (incomplete data)' {
    It 'puts a subscription the summary lists as incomplete on the retry list with its reason' -Skip:(-not ((Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'Run-AllSubscriptions.ps1') -Raw).Contains('$StreamSummary.Incomplete'))) {
        $Root = Join-Path $script:TestBase ('inc-' + [guid]::NewGuid().ToString().Substring(0, 8))
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $Root '.resume-state-t-stream-0.json') -Value '{ not json' -NoNewline
        $Summary = Join-Path $Root '.rda-stream-0-summary.json'
        @{ RunId = 'run-1'; StreamId = '0'; Tenant = 't'; Status = 'ok'; Completed = @(); ResourceCounts = @(); Failed = @(); Incomplete = @(@{ Id = 'sub-c'; Name = 'Sub C'; Reason = 'Metrics were left incomplete for Sub C.' }) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Summary -Encoding utf8
        $Streams = @([pscustomobject]@{ StreamId = 0; SummaryPath = $Summary; FailuresPath = (Join-Path $Root 'failures-stream-0.log'); SubCount = 1 })
        Set-Variable -Name Subscriptions -Value @([pscustomobject]@{ Id = 'sub-c'; Name = 'Sub C' })
        $State = Join-Path $Root '.resume-state-t.json'
        Set-Variable -Name UnreadableStreamFiles -Value @()
        Set-Variable -Name LeftStreamFiles -Value @()
        $null = & { . $script:MergeBlock $Streams $Root 't' $State @() @() @() } 6>$null
        $Entry = @(Get-FailedAttempts -Path $State -Tenant 't' | Where-Object { $null -ne $_ -and $_.Id -eq 'sub-c' })
        $Entry.Count | Should -Be 1
        $Entry[0].Reason | Should -Be 'Metrics were left incomplete for Sub C.'
    }
}

Describe 'The run''s exit code and stream summaries around a resume state that was not saved' {
    BeforeAll {
        $script:Src = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'Run-AllSubscriptions.ps1') -Raw
        $Tokens = $null
        $ParseErrors = $null
        $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $PSScriptRoot -Parent) 'Run-AllSubscriptions.ps1'), [ref]$Tokens, [ref]$ParseErrors)
    }

    It 'ends with exit 2 when a resume state could not be saved and the run is not clean' {
        $script:Src | Should -Match ([regex]::Escape('-ReportsMissing (($ResumeStateSaveFailed -and -not $RunClean) -or ('))
    }

    It 'removes every stream summary an earlier run left before the sign-in snapshot and the first stream' {
        $Pre = @($script:Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.ForEachStatementAst] -and $args[0].Condition.Extent.Text.Contains("-Filter '.rda-stream-*-summary*.json*'") }, $true))
        $Pre.Count | Should -Be 1
        $Launch = @($script:Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.ForStatementAst] -and $args[0].Body.Extent.Text.Contains('Start-Job') }, $true))
        $Snapshot = @($script:Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] -and $args[0].GetCommandName() -eq 'Save-AzContext' }, $true))
        $Pre[0].Extent.StartOffset | Should -BeLessThan $Snapshot[0].Extent.StartOffset
        $Pre[0].Extent.StartOffset | Should -BeLessThan $Launch[0].Extent.StartOffset
        @($script:Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.ForStatementAst] -and $args[0].Body.Extent.Text.Contains('Start-Job') -and $args[0].Body.Extent.Text.Contains('Remove-Item -LiteralPath $SummaryPath') }, $true)) | Should -BeNullOrEmpty -Because 'no removal is left inside the launch loop'
        # A top-level statement of the script, before the sequential or
        # parallel split: every run that goes on to collect runs it, sequential ones included.
        $script:Ast.EndBlock.Statements | Should -Contain $Pre[0]
        $Split = @($script:Ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.IfStatementAst] -and $_.Clauses[0].Item1.Extent.Text -eq '$ParallelStreams -le 1' })
        $Split.Count | Should -Be 1
        $Pre[0].Extent.StartOffset | Should -BeLessThan $Split[0].Extent.StartOffset
        $script:PreBlock = [scriptblock]::Create("param(`$InventoryRoot, `$StreamCount)`n" + $Pre[0].Extent.Text)
    }

    It 'leaves no stream summary of an earlier run, under the old shared name or a run''s name and of any stream number, and warns but goes on when one cannot be removed' {
        function Exit-Wrapper { param([int]$Code) throw ('EXIT ' + $Code) }
        $script:Warned = @()
        Mock Write-Host { $script:Warned += [string]$Object }
        $Dir = Join-Path $script:TestBase ('stale-' + [guid]::NewGuid().ToString().Substring(0, 8))
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        # Stream 5 is above this run's stream count (2).
        foreach ($N in 0, 1, 5)
        {
            Set-Content -LiteralPath (Join-Path $Dir ('.rda-stream-{0}-summary.json' -f $N)) -Value '{}'
            Set-Content -LiteralPath (Join-Path $Dir ('.rda-stream-{0}-summary-oldrun.json' -f $N)) -Value '{}'
            Set-Content -LiteralPath (Join-Path $Dir ('.rda-stream-{0}-summary-oldrun.json.tmp' -f $N)) -Value '{}'
        }
        & $script:PreBlock $Dir 2
        @(Get-ChildItem -LiteralPath $Dir -Force -Filter '.rda-stream-*-summary*') | Should -BeNullOrEmpty
        Set-Content -LiteralPath (Join-Path $Dir '.rda-stream-1-summary.json') -Value '{}'
        Set-Content -LiteralPath (Join-Path $Dir '.rda-stream-1-summary-oldrun.json') -Value '{}'
        Mock Remove-Item -ParameterFilter { [string]$LiteralPath -like '*.rda-stream-1-summary*' } -MockWith { throw 'stand-in: denied' }
        { & $script:PreBlock $Dir 2 } | Should -Not -Throw
        @($script:Warned | Where-Object { $_ -like 'WARNING: Could not remove the stream summary *stand-in: denied. It is not read; remove it when you can.' }).Count | Should -Be 2
    }

    It 'says the state was cleared at the end of a clean run only when its removal worked' {
        $script:Src | Should -Match ([regex]::Escape('Remove-Item -LiteralPath $ResumeStateFile -Force -ErrorAction Stop'))
        $script:Src | Should -Match ([regex]::Escape('if (-not (Test-Path -LiteralPath $ResumeStateFile))'))
        $script:Src | Should -Match ([regex]::Escape('Write-Host "Resume state cleared (clean run)." -ForegroundColor Green'))
    }

    It 'removes the stream summaries by literal path' {
        $script:Src | Should -Not -Match ([regex]::Escape('Test-Path -Path $S.SummaryPath'))
        $script:Src | Should -Not -Match ([regex]::Escape('Remove-Item -Path $S.SummaryPath'))
    }
}
