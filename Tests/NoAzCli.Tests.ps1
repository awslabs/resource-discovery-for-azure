# =============================================================================
# NoAzCli.Tests.ps1
#
# Guard: the tool runs with the Az PowerShell modules only. No script the tool
# runs may call the Azure CLI (`az ...`, `& az`, `Get-Command az`), and the
# Resource Graph data path must not depend on Az.ResourceGraph
# (Search-AzGraph), which is not one of the required modules.
#
# Checked on the PowerShell syntax tree, so a mention of "az" in a comment or
# a message is not a hit, and a call is found however it is spelled.
#
# Run with: Invoke-Pester ./Tests/NoAzCli.Tests.ps1 -Output Detailed
# =============================================================================

BeforeDiscovery {
    $Root = Split-Path $PSScriptRoot -Parent
    $script:Files = @(
        Get-ChildItem -Path $Root -Filter '*.ps1' -File
        foreach ($Dir in 'Functions', 'Extension', 'Services')
        {
            $Path = Join-Path $Root $Dir
            if (Test-Path $Path) { Get-ChildItem -Path $Path -Filter '*.ps1' -File -Recurse }
        }
    ) | ForEach-Object { @{ Name = $_.FullName.Substring($Root.Length + 1); Path = $_.FullName } }
}

Describe 'No Azure CLI in the tool' {

    It 'checks the entry scripts and Functions/' -TestCases @(@{ Names = @($script:Files | ForEach-Object { $_.Name }) }) {
        param($Names)
        @($Names | Where-Object { $_ -in 'ResourceInventory.ps1', 'Run-AllSubscriptions.ps1', 'Run-AllSubscriptions.Stream.ps1' }).Count | Should -Be 3
        @($Names | Where-Object { $_ -like 'Functions*' }).Count | Should -BeGreaterThan 0
    }

    It '<Name> does not call az' -TestCases $script:Files {
        param($Name, $Path)
        $null = $Name
        $Errors = $null
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$Errors)
        @($Errors).Count | Should -Be 0
        $Hits = @($Ast.FindAll({
                    param($Node)
                    if ($Node -isnot [System.Management.Automation.Language.CommandAst]) { return $false }
                    $Command = $Node.GetCommandName()
                    if ($Command -in 'az', 'az.cmd', 'az.exe') { return $true }
                    # Get-Command az / Get-Command -Name az
                    if ($Command -eq 'Get-Command')
                    {
                        return @($Node.CommandElements | Select-Object -Skip 1 | Where-Object { $_ -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $_.Value -in 'az', 'az.cmd', 'az.exe' }).Count -gt 0
                    }
                    return $false
                }, $true) | ForEach-Object { 'line {0}: {1}' -f $_.Extent.StartLineNumber, $_.Extent.Text })
        $Hits | Should -BeNullOrEmpty
    }

    It '<Name> does not use Search-AzGraph or Az.ResourceGraph' -TestCases $script:Files {
        param($Name, $Path)
        $null = $Name
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
        $Hits = @($Ast.FindAll({
                    param($Node)
                    ($Node -is [System.Management.Automation.Language.CommandAst] -and $Node.GetCommandName() -eq 'Search-AzGraph') -or
                    ($Node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $Node.Value -eq 'Az.ResourceGraph')
                }, $true) | ForEach-Object { 'line {0}: {1}' -f $_.Extent.StartLineNumber, $_.Extent.Text })
        $Hits | Should -BeNullOrEmpty
    }

    # The tool never asks the user to run a cmdlet from a module it does not
    # install: the advice it prints names Invoke-AzRestMethod instead.
    It '<Name> does not tell the user to run Search-AzGraph' -TestCases $script:Files {
        param($Name, $Path)
        $null = $Name
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
        $Hits = @($Ast.FindAll({
                    param($Node)
                    ($Node -is [System.Management.Automation.Language.StringConstantExpressionAst] -or $Node -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) -and $Node.Value -match 'Search-AzGraph'
                }, $true) | ForEach-Object { 'line {0}: {1}' -f $_.Extent.StartLineNumber, $_.Extent.Text })
        $Hits | Should -BeNullOrEmpty
    }

    # Set-AzContext without -Scope Process rewrites the user's saved default
    # context (their default subscription, or a process-only service
    # principal sign-in made permanent). The tool keeps every switch to its
    # own process.
    It '<Name> keeps every Set-AzContext to this process' -TestCases $script:Files {
        param($Name, $Path)
        $null = $Name
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
        $Hits = @($Ast.FindAll({
                    param($Node)
                    $Node -is [System.Management.Automation.Language.CommandAst] -and $Node.GetCommandName() -eq 'Set-AzContext' -and $Node.Extent.Text -notmatch '-Scope\s+Process\b'
                }, $true) | ForEach-Object { 'line {0}: {1}' -f $_.Extent.StartLineNumber, $_.Extent.Text })
        $Hits | Should -BeNullOrEmpty
    }
}
