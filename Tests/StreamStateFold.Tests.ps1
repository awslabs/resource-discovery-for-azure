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
    $script:MergeBlock = [scriptblock]::Create(
        "param(`$StreamSummaries, `$InventoryRoot, `$TenantID, `$ResumeStateFile, `$CompletedIds, `$FailedAttempts, `$CompletedReports)`n" +
        "`$SkippedSubscriptions = @(); `$SubResourceCounts = @(); `$FailedSubscriptions = @(); `$DiagFile = `$null; `$GoneIds = @()`n" +
        (@($Body[$AggStart..($Body.Count - 1)] | ForEach-Object { $_.Extent.Text }) -join "`n"))
    $TmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { '/tmp' }
    $script:TestBase = Join-Path $TmpBase ('StreamStateFold_' + [guid]::NewGuid().ToString().Substring(0, 8))
    New-Item -ItemType Directory -Path $script:TestBase -Force | Out-Null

    function script:New-StreamFile
    {
        param([string]$Root, [int]$N, [string[]]$Completed = @(), [object[]]$Failed = @())
        $Path = Join-Path $Root ('.resume-state-t-stream-{0}.json' -f $N)
        [pscustomobject]@{ Tenant = 't'; Completed = @($Completed); FailedAttempts = @($Failed); Reports = @() } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding utf8
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
        [pscustomobject]@{ Unreadable = @($UnreadableStreamFiles); Lines = $Lines; Completed = @(Get-CompletedSubscriptionIds -Path $ResumeStateFile -Tenant 't'); Failed = @(Get-FailedAttempts -Path $ResumeStateFile -Tenant 't' | Where-Object { $null -ne $_ } | ForEach-Object Id) }
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
        $R.Completed | Should -Be @('sub-a')
        $R.Failed | Should -Be @('sub-x')
        @(Get-StreamResumeStateFiles -InventoryRoot $script:Root -Tenant 't') | Should -BeNullOrEmpty
        $R2 = script:Invoke-Fold -Root $script:Root -Resume $true
        @($R2.Lines | Where-Object { $_ -like 'Recovered per-stream state*' }) | Should -BeNullOrEmpty
    }

    It 'are kept and named when the unified file does not hold their records afterwards' {
        $Path = script:New-StreamFile -Root $script:Root -N 0 -Completed @('sub-a')
        Mock Save-CompletedSubscriptionIds { }
        $R = script:Invoke-Fold -Root $script:Root -Resume $true
        Test-Path -LiteralPath $Path | Should -BeTrue
        @($R.Lines | Where-Object { $_ -like 'WARNING: The resume state file * does not hold every record of the per-stream files*' }).Count | Should -Be 1
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
        $null = script:Invoke-Fold -Root $script:Root -Resume $true
        Test-Path -LiteralPath $Path | Should -BeTrue -Because 'the file on disk still holds the older entry'
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
        @{ StreamId = '0'; Tenant = 't'; Status = 'partial-failure'; Completed = @('sub-a'); ResourceCounts = @(); Failed = @(@{ Id = 'sub-b'; Name = 'Sub B'; Reason = 'stand-in failure' }) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:Summary -Encoding utf8
        $script:Streams = @([pscustomobject]@{ StreamId = 0; SummaryPath = $script:Summary; FailuresPath = (Join-Path $script:Root 'failures-stream-0.log'); SubCount = 2 })
        Set-Variable -Name Subscriptions -Value @([pscustomobject]@{ Id = 'sub-a'; Name = 'Sub A' }, [pscustomobject]@{ Id = 'sub-b'; Name = 'Sub B' })
    }

    It 'puts a subscription the stream summary lists as failed on the retry list when the stream''s own file cannot be read' {
        Set-Content -LiteralPath (Join-Path $script:Root '.resume-state-t-stream-0.json') -Value '{ not json' -NoNewline
        $UnreadableStreamFiles = @()
        $LeftStreamFiles = @()
        $null = & { . $script:MergeBlock $script:Streams $script:Root 't' $script:State @() @() @(); $UnreadableStreamFiles } 6>$null
        $Entry = @(Get-FailedAttempts -Path $script:State -Tenant 't' | Where-Object { $null -ne $_ -and $_.Id -eq 'sub-b' })
        $Entry.Count | Should -Be 1 -Because 'otherwise -ResumeFailedOnly finds nothing to retry'
        $Entry[0].Name | Should -Be 'Sub B'
        $Entry[0].Reason | Should -Be 'stand-in failure'
    }

    It 'counts a failure the stream''s own file recorded once, not again from the summary' {
        [pscustomobject]@{ Tenant = 't'; Completed = @('sub-a'); FailedAttempts = @([pscustomobject]@{ Id = 'sub-b'; Name = 'Sub B'; LastFailedAt = '2026-01-01T00:00:00Z'; Reason = 'stand-in failure'; Attempts = 1 }); Reports = @() } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $script:Root '.resume-state-t-stream-0.json') -Encoding utf8
        $UnreadableStreamFiles = @()
        $LeftStreamFiles = @()
        $null = & { . $script:MergeBlock $script:Streams $script:Root 't' $script:State @() @() @() } 6>$null
        [int](@(Get-FailedAttempts -Path $script:State -Tenant 't' | Where-Object { $null -ne $_ -and $_.Id -eq 'sub-b' })[0].Attempts) | Should -Be 1
    }

    It 'records a merged file it cannot remove, so the run keeps the state and ends with exit 2' {
        $File = Join-Path $script:Root '.resume-state-t-stream-0.json'
        [pscustomobject]@{ Tenant = 't'; Completed = @('sub-a'); FailedAttempts = @(); Reports = @() } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $File -Encoding utf8
        Mock Remove-Item -ParameterFilter { $LiteralPath -like '*-stream-*.json' } -MockWith { throw 'stand-in: read-only' }
        $UnreadableStreamFiles = @()
        $LeftStreamFiles = @()
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
        $UnreadableStreamFiles = @()
        $TenantID = 't'
        $ResumeStateFile = '/x/.resume-state-t.json'
        $null = $ResumeFailedOnly, $FailedAttempts, $Subscriptions, $UnreadableStreamFiles, $TenantID, $ResumeStateFile
        $script:Out = @()
        { . ([scriptblock]::Create($Block[0].Extent.Text)) 6>&1 | ForEach-Object { $script:Out += [string]$_ } } | Should -Throw 'Exit-Wrapper 2'
        @($script:Out | Where-Object { $_ -like '*delete the resume state files .resume-state-t.json and .resume-state-t-stream-`*.json*' }).Count | Should -Be 1
    }
}
