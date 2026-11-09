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

    It 'that cannot be read are named, kept and recorded as unread, so the run is not clean' {
        $Bad = Join-Path $script:Root '.resume-state-t-stream-3.json'
        Set-Content -LiteralPath $Bad -Value '{ not json' -NoNewline
        $Good = script:New-StreamFile -Root $script:Root -N 0 -Completed @('sub-a')
        $R = script:Invoke-Fold -Root $script:Root -Resume $true
        Test-Path -LiteralPath $Bad | Should -BeTrue
        Test-Path -LiteralPath $Good | Should -BeFalse
        $R.Unreadable | Should -Be @($Bad)
        @($R.Lines | Where-Object { $_ -like ('WARNING: Could not read the per-stream resume state file {0} of an interrupted run:*Fix or delete the file*' -f $Bad) }).Count | Should -Be 1
    }

    It 'are removed as stale by a run without -Resume or -ResumeFailedOnly' {
        $null = script:New-StreamFile -Root $script:Root -N 0 -Completed @('sub-a')
        $R = script:Invoke-Fold -Root $script:Root -Resume $false
        @(Get-StreamResumeStateFiles -InventoryRoot $script:Root -Tenant 't') | Should -BeNullOrEmpty
        @($R.Lines | Where-Object { $_ -like 'Recovered per-stream state*' }) | Should -BeNullOrEmpty
        $R.Completed | Should -BeNullOrEmpty
    }
}
