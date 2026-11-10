#Requires -Modules Pester
# The collector (ResourceInventory.ps1) finds its own files and its
# Services/*.ps1 with wildcard paths, so the wrapper refuses a script folder
# whose path holds a wildcard character, before anything is offered,
# installed, read or written.

Describe 'A script folder whose path holds a wildcard character' {
    BeforeAll {
        $script:Wrapper = Join-Path (Split-Path $PSScriptRoot -Parent) 'Run-AllSubscriptions.ps1'
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:Wrapper, [ref]$null, [ref]$null)
        $script:Stop = @($Ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.IfStatementAst] -and $_.Clauses[0].Item1.Extent.Text -eq "`$PSScriptRoot.IndexOfAny([char[]]'[]*?') -ge 0" })
    }

    It 'is stopped before the Azure CLI and the Az modules are looked for, and before the functions load' {
        $script:Stop.Count | Should -Be 1
        $Src = Get-Content -LiteralPath $script:Wrapper -Raw
        foreach ($Later in @('# Azure CLI bootstrap.', '# Az PowerShell module bootstrap.', '$FunctionsFile = Join-Path $PSScriptRoot', '$ResumeStateFile'))
        {
            $At = $Src.IndexOf($Later)
            $At | Should -BeGreaterThan 0 -Because $Later
            $script:Stop[0].Extent.StartOffset | Should -BeLessThan $At -Because $Later
        }
    }

    It 'stops a run from <Name> with exit <Exit>' -TestCases @(
        @{ Name = 'rda[2]'; Exit = 1 }
        @{ Name = 'rda*2'; Exit = 1 }
        @{ Name = 'rda?2'; Exit = 1 }
        @{ Name = 'rda2'; Exit = 0 }
    ) {
        param($Name, $Exit)
        # * and ? cannot be in a folder name on Windows.
        if ($IsWindows -and $Name -match '[*?]') { Set-ItResult -Skipped -Because 'Windows folder names cannot hold * or ?'; return }
        $Dir = Join-Path $TestDrive $Name
        $null = [System.IO.Directory]::CreateDirectory($Dir)
        $Probe = Join-Path $Dir 'probe.ps1'
        [System.IO.File]::WriteAllText($Probe, $script:Stop[0].Extent.Text)
        $Out = & (Join-Path $PSHOME 'pwsh') -NoProfile -NonInteractive -File $Probe 2>&1
        $LASTEXITCODE | Should -Be $Exit
        if ($Exit -eq 1) { ($Out -join ' ') | Should -Match 'has \[ \] \* or \? in its path' }
    }
}
