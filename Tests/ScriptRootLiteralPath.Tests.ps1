#Requires -Modules Pester
# The wrapper and the stream worker check that their own files (found from
# $PSScriptRoot) are there before they load or start them. Test-Path -Path reads
# [ and ] as a wildcard pattern, so from a folder whose name holds brackets a
# file that is there reads as missing and the run stops (exit 1). Each check
# takes the path as written (-LiteralPath).

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $script:Folder = Join-Path $TestDrive 'rda[1]'
    New-Item -ItemType Directory -Path (Join-Path $script:Folder 'Functions') -Force | Out-Null
    $script:File = Join-Path $script:Folder 'Functions/x.ps1'
    [System.IO.File]::WriteAllText($script:File, '')
    # The condition of each "is the file there" check in a script, by the
    # variable it tests.
    function script:Get-FileCheck
    {
        param([string]$Script, [string]$Variable)
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepoRoot $Script), [ref]$null, [ref]$null)
        @($Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.IfStatementAst] -and $N.Clauses[0].Item1.Extent.Text -match ('^-not \(Test-Path .*\${0} -PathType Leaf\)$' -f $Variable) }, $true) | ForEach-Object { $_.Clauses[0].Item1.Extent.Text })
    }
}

Describe 'The checks for the scripts'' own files read a path with brackets as written' {
    It '<Script> finds $<Variable> in a folder named rda[1]' -TestCases @(
        @{ Script = 'Run-AllSubscriptions.ps1'; Variable = 'FunctionsFile' }
        @{ Script = 'Run-AllSubscriptions.ps1'; Variable = 'CommonFunctionsFile' }
        @{ Script = 'Run-AllSubscriptions.ps1'; Variable = 'WorkerScript' }
        @{ Script = 'Run-AllSubscriptions.ps1'; Variable = 'AllSubSummaryFunctions' }
        @{ Script = 'Run-AllSubscriptions.Stream.ps1'; Variable = 'FunctionsFile' }
    ) {
        param($Script, $Variable)
        $Checks = @(script:Get-FileCheck -Script $Script -Variable $Variable)
        $Checks.Count | Should -Be 1
        Set-Variable -Name $Variable -Value $script:File
        # The check's own condition: true means "missing", which stops the run.
        & ([scriptblock]::Create($Checks[0])) | Should -BeFalse
    }
}
