#Requires -Modules Pester
# The wrapper's reads of the per-stream resume state files, run as written
# (lifted from Run-AllSubscriptions.ps1): the startup fold of -Resume and
# -ResumeFailedOnly, the end-of-run merge of a parallel run, and the end-of-run
# exit rule for a file that could not be moved aside. A file that cannot be
# read, or is not an object with a Completed list, is moved aside and kept; a
# file an older version wrote (no FailedAttempts list) is read, under strict
# mode too.

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:RepoRoot 'Functions/Common.Functions.ps1')
    . (Join-Path $script:RepoRoot 'Functions/RunAllSubscriptions.Functions.ps1')
    function Exit-Wrapper { param([int]$Code = 0) throw ('EXIT {0}' -f $Code) }

    $Tokens = $null
    $ParseErrors = $null
    $Ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepoRoot 'Run-AllSubscriptions.ps1'), [ref]$Tokens, [ref]$ParseErrors)
    $Top = @($Ast.EndBlock.Statements)

    # The startup fold: the top-level 'if ($Resume -or $ResumeFailedOnly)' that reads the per-stream files.
    $Fold = @($Top | Where-Object { $_ -is [System.Management.Automation.Language.IfStatementAst] -and $_.Clauses[0].Item1.Extent.Text -eq '$Resume -or $ResumeFailedOnly' -and $_.Extent.Text -match 'Get-StreamResumeStateFiles' })
    if ($Fold.Count -ne 1) { throw "Expected one startup fold in the wrapper, found $($Fold.Count)." }
    $script:FoldBlock = [scriptblock]::Create(
        "param(`$InventoryRoot, `$TenantID, `$ResumeStateFile, `$Resume, `$ResumeFailedOnly)`n" +
        "`$CompletedIds = @(); `$FailedAttempts = @(); `$FoldedStreamFiles = @(); `$UnreadableStreamFiles = @()`n" +
        $Fold[0].Extent.Text + "`n" +
        "[pscustomobject]@{ CompletedIds = @(`$CompletedIds); FailedAttempts = @(`$FailedAttempts); Folded = @(`$FoldedStreamFiles); Unreadable = @(`$UnreadableStreamFiles) }")

    # The end-of-run merge: from '$AllStreamFiles = ...' to the end of its block.
    $Assign = @($Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] -and $args[0].Left.Extent.Text -eq '$AllStreamFiles' }, $true))
    if ($Assign.Count -ne 1) { throw "Expected one end-of-run read of the per-stream files, found $($Assign.Count)." }
    $Siblings = @($Assign[0].Parent.Statements)
    $From = [array]::IndexOf($Siblings, $Assign[0])
    $MergeText = (@($Siblings[$From..($Siblings.Count - 1)] | ForEach-Object { $_.Extent.Text }) -join "`n")
    $script:MergeBlock = [scriptblock]::Create(
        "param(`$InventoryRoot, `$TenantID, `$ResumeStateFile)`n" +
        "`$CompletedIds = @(); `$FailedAttempts = @(); `$UnreadableStreamFiles = @(); `$StreamStateNotMoved = @()`n" +
        $MergeText + "`n" +
        "[pscustomobject]@{ CompletedIds = @(`$CompletedIds); FailedAttempts = @(`$FailedAttempts); Unreadable = @(`$UnreadableStreamFiles); NotMoved = @(`$StreamStateNotMoved) }")

    # The end-of-run stop and exit rule for a file the merge could not move aside.
    $Stop = @($Top | Where-Object { $_ -is [System.Management.Automation.Language.IfStatementAst] -and $_.Clauses[0].Item1.Extent.Text -eq '$StreamStateNotMoved.Count -gt 0' })
    $ExitRule = @($Top | Where-Object { $_ -is [System.Management.Automation.Language.IfStatementAst] -and $_.Clauses[0].Item1.Extent.Text -eq '$StreamStateNotMoved.Count -gt 0 -and $WrapperExitCode -ne 2' })
    # (Checked in each test of the end of the run, so the other tests still run without it.)
    $script:EndBlock = { throw 'Expected the end-of-run stop and exit rule for a per-stream file that could not be moved aside.' }
    if ($Stop.Count -eq 1 -and $ExitRule.Count -eq 1)
    {
        $script:EndBlock = [scriptblock]::Create(
            "param(`$StreamStateNotMoved, `$WrapperExitCode, `$ResumeFailedOnly)`n" +
            $Stop[0].Extent.Text + "`n" +
            ($ExitRule[0].Extent.Text -replace '\bexit 1\b', "throw 'EXIT 1'") + "`n" +
            "'NO EXIT CHANGE'")
    }

    function script:New-StreamFile
    {
        param([string]$Dir, [int]$N, [string]$Text)
        $Path = Join-Path $Dir ('.resume-state-t-stream-{0}.json' -f $N)
        Set-Content -LiteralPath $Path -Value $Text -NoNewline
        return $Path
    }
}

Describe 'The startup fold of the per-stream resume state files' {
    BeforeEach {
        $script:Lines = [System.Collections.Generic.List[string]]::new()
        Mock Write-Host { $script:Lines.Add([string]$Object) }
        $script:Dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:Dir -Force | Out-Null
        $script:State = Join-Path $script:Dir '.resume-state-t.json'
    }

    It 'moves aside a file that is an object with no Completed list, and does not fold it in' {
        $Bad = script:New-StreamFile -Dir $script:Dir -N 0 -Text '{}'
        $R = & $script:FoldBlock $script:Dir 't' $script:State $true $false
        Test-Path -LiteralPath $Bad | Should -BeFalse
        @(Get-ChildItem -LiteralPath $script:Dir -Force -Filter '.resume-state-t-stream-0.json.unreadable-*').Count | Should -Be 1
        @($R.Folded) | Should -BeNullOrEmpty
        @($R.Unreadable | ForEach-Object Name) | Should -Be @('.resume-state-t-stream-0.json')
    }

    It 'folds in a file an older version wrote (no FailedAttempts list) under strict mode' {
        $null = script:New-StreamFile -Dir $script:Dir -N 1 -Text '{ "Completed": [ "sub-a" ] }'
        $R = & { Set-StrictMode -Version Latest; & $script:FoldBlock $script:Dir 't' $script:State $true $false }
        @($R.CompletedIds) | Should -Be @('sub-a')
        @($R.Folded | ForEach-Object Name) | Should -Be @('.resume-state-t-stream-1.json')
    }

    It 'stops with exit 1 before it saves any record when a file it cannot read cannot be moved aside' {
        $null = script:New-StreamFile -Dir $script:Dir -N 0 -Text '{ "Completed": [ "sub-a" ], "FailedAttempts": [] }'
        $Bad = script:New-StreamFile -Dir $script:Dir -N 1 -Text 'cut'
        Mock Rename-Item { throw 'denied' }
        Mock Save-CompletedSubscriptionIds { }
        { & $script:FoldBlock $script:Dir 't' $script:State $true $false } | Should -Throw 'EXIT 1'
        Should -Invoke Save-CompletedSubscriptionIds -Times 0 -Exactly
        Test-Path -LiteralPath $Bad | Should -BeTrue
    }
}

Describe 'The end-of-run merge of the per-stream resume state files' {
    BeforeEach {
        $script:Lines = [System.Collections.Generic.List[string]]::new()
        Mock Write-Host { $script:Lines.Add([string]$Object) }
        $script:Dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:Dir -Force | Out-Null
        $script:State = Join-Path $script:Dir '.resume-state-t.json'
    }

    It 'moves aside a file it cannot read (<Label>) and keeps it, and removes the files it read' -TestCases @(
        @{ Label = 'cut short'; Text = '{ "Completed": [' }
        @{ Label = 'empty'; Text = '' }
        @{ Label = 'no Completed list'; Text = '{}' }
    ) {
        $Good = script:New-StreamFile -Dir $script:Dir -N 0 -Text '{ "Completed": [ "sub-a" ], "FailedAttempts": [] }'
        $Bad = script:New-StreamFile -Dir $script:Dir -N 1 -Text $Text
        $R = & $script:MergeBlock $script:Dir 't' $script:State
        Test-Path -LiteralPath $Bad | Should -BeFalse
        @(Get-ChildItem -LiteralPath $script:Dir -Force -Filter '.resume-state-t-stream-1.json.unreadable-*').Count | Should -Be 1 -Because 'it is kept for inspection, not deleted'
        Test-Path -LiteralPath $Good | Should -BeFalse -Because 'its records are in the resume state now'
        @($R.CompletedIds) | Should -Be @('sub-a')
        @($R.Unreadable | ForEach-Object Name) | Should -Be @('.resume-state-t-stream-1.json')
        @($R.NotMoved) | Should -BeNullOrEmpty
        @($script:Lines | Where-Object { $_ -like 'WARNING: The per-stream state file .resume-state-t-stream-1.json could not be read, so its records are not used:*' }).Count | Should -Be 1
    }

    It 'reads a file an older version wrote (no FailedAttempts list) under strict mode' {
        $Good = script:New-StreamFile -Dir $script:Dir -N 0 -Text '{ "Completed": [ "sub-a" ] }'
        $R = & { Set-StrictMode -Version Latest; & $script:MergeBlock $script:Dir 't' $script:State }
        @($R.CompletedIds) | Should -Be @('sub-a')
        Test-Path -LiteralPath $Good | Should -BeFalse
    }

    It 'leaves alone a file it cannot read that cannot be moved aside, and names it for the end of the run' {
        $Bad = script:New-StreamFile -Dir $script:Dir -N 2 -Text 'cut'
        Mock Rename-Item { throw 'denied' }
        $R = & $script:MergeBlock $script:Dir 't' $script:State
        Test-Path -LiteralPath $Bad | Should -BeTrue
        @($R.NotMoved | ForEach-Object Name) | Should -Be @('.resume-state-t-stream-2.json')
    }
}

Describe 'The end of a run whose merge could not move a per-stream file aside' {
    BeforeEach {
        $script:Lines = [System.Collections.Generic.List[string]]::new()
        Mock Write-Host { $script:Lines.Add([string]$Object) }
        $script:NotMoved = @([pscustomobject]@{ Kind = 'Stream'; Name = '.resume-state-t-stream-2.json'; MovedTo = $null; Path = '/x/.resume-state-t-stream-2.json'; Problem = $null; Reason = 'denied'; NotMoved = $true; Unreadable = $true })
    }

    It 'ends with exit 1 in place of exit <Code>, and names the file with the command that removes it' -TestCases @(@{ Code = 0 }, @{ Code = 3 }, @{ Code = 5 }) {
        { & $script:EndBlock $script:NotMoved $Code $false } | Should -Throw 'EXIT 1'
        $script:Lines[0] | Should -Be 'ERROR: The per-stream state file .resume-state-t-stream-2.json could not be read, and it could not be moved aside: denied'
        @($script:Lines | Where-Object { $_ -like '  This run ends with exit 1 in place of 0 and 3-5;*' }).Count | Should -Be 1
        @($script:Lines | Where-Object { $_ -eq "  Remove-Item -LiteralPath '/x/.resume-state-t-stream-2.json' -Force" }).Count | Should -Be 1
    }

    It 'keeps exit 2, and changes nothing when every file was moved aside' {
        & $script:EndBlock $script:NotMoved 2 $false | Should -Be 'NO EXIT CHANGE'
        $script:Lines.Clear()
        & $script:EndBlock @() 0 $false | Should -Be 'NO EXIT CHANGE'
        $script:Lines.Count | Should -Be 0
    }
}

Describe 'The early exit 2 of a run whose merge could not move a per-stream file aside' {
    It 'names the file with what to do before the per-subscription output check ends the run with exit 2' {
        $Tokens = $null
        $ParseErrors = $null
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepoRoot 'Run-AllSubscriptions.ps1'), [ref]$Tokens, [ref]$ParseErrors)
        $Gap = @($Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.StatementBlockAst] -and $args[0].Extent.Text.Contains('Recover by either:') -and $args[0].Extent.Text.Contains('Exit-Wrapper -Code 2') -and $args[0].Parent -is [System.Management.Automation.Language.IfStatementAst] }, $true) | Sort-Object { $_.Extent.Text.Length } | Select-Object -First 1)
        $Gap.Count | Should -Be 1
        $Text = $Gap[0].Extent.Text
        $Stop = $Text.IndexOf('Stop-WrongShapeStateNotMoved -Files $StreamStateNotMoved -AfterCollection -NoExit')
        $Stop | Should -BeGreaterThan -1
        $Stop | Should -BeLessThan $Text.IndexOf('Exit-Wrapper -Code 2')
    }

    It 'says at the move that the run ends with exit 1, or exit 2 when a report is missing' {
        $script:Lines = [System.Collections.Generic.List[string]]::new()
        Mock Write-Host { $script:Lines.Add([string]$Object) }
        $Dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        $File = script:New-StreamFile -Dir $Dir -N 3 -Text 'cut'
        Mock Rename-Item { throw 'denied' }
        $null = Move-UnreadableStreamStateFile -File (Get-Item -LiteralPath $File -Force) -AtRunEnd
        $script:Lines[1] | Should -Be "  This run does not use the file's records and does not write over it. It goes on as usual and ends with exit 1 (exit 2 when a report is missing), with what to do next at its end."
    }
}

Describe 'The retry-list writer when a write of the resume state stops part way' {
    It 'is not moved over the last good file, and leaves no temporary file' {
        Mock Write-Host { }
        $Dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        $State = Join-Path $Dir '.resume-state-t.json'
        Save-CompletedSubscriptionIds -Path $State -Tenant 't' -Ids @('sub-good') -FailedAttempts @()
        $Good = Get-Content -LiteralPath $State -Raw
        # What a full disk does: part of the file is written, and the error does not stop the pipeline.
        Mock Set-Content -ParameterFilter { [string]$LiteralPath -like '*.tmp' -or [string]$Path -like '*.tmp' } -MockWith {
            $Target = if ($LiteralPath) { [string]$LiteralPath } else { [string]$Path }
            [System.IO.File]::WriteAllText($Target, '{"Compl')
            Write-Error 'stand-in: No space left on device'
        }
        Update-ResumeStateRetryList -Path $State -Tenant 't' -Ids @() -FailedAttempts @([pscustomobject]@{ Id = 'sub-good'; Name = 'Sub Good'; LastFailedAt = (Get-Date).ToString('o'); Reason = 'skipped by the up-front role check'; Attempts = 1 }) 2>$null
        Get-Content -LiteralPath $State -Raw | Should -Be $Good
        Test-Path -LiteralPath "$State.tmp" | Should -BeFalse
    }
}
