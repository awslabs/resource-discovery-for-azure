# The masked-report check of Extension/Summary.ps1 and of the main summary
# (Functions/AllSubHtmlSummary.Functions.ps1) samples names and subscriptions
# and calls a report masked when most of them look like masked tokens. Under
# -Obfuscate the collector (ResourceInventory.ps1) writes a resource name as
# prod_<guid> or nonprod_<guid>, and with a type hint as prod_aks_<guid>,
# prod_vmss_<guid> or prod_databricks_<guid>: every one of those shapes must
# count as masked, or a masked report of mostly such resources reads as
# identifiable. Offline.
#
# Run with: Invoke-Pester ./Tests/MaskedTokenShapes.Tests.ps1 -Output Detailed

BeforeAll {
    $RepoRoot = Split-Path $PSScriptRoot -Parent
    # The pattern each file assigns to $ObfPattern, as written.
    function script:Get-ObfPattern
    {
        param([string]$File)
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile($File, [ref]$null, [ref]$null)
        $Found = @($Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] -and $args[0].Left.Extent.Text -eq '$ObfPattern' }, $true))
        if ($Found.Count -ne 1) { throw ('expected one $ObfPattern in {0}, found {1}' -f $File, $Found.Count) }
        $Found[0].Right.Expression.Value
    }
    $script:Patterns = @{
        Summary     = script:Get-ObfPattern -File (Join-Path $RepoRoot 'Extension/Summary.ps1')
        MainSummary = script:Get-ObfPattern -File (Join-Path $RepoRoot 'Functions/AllSubHtmlSummary.Functions.ps1')
    }
    $script:Guid = '0f8fad5b-d9cb-469f-a165-70867728950e'
}

Describe 'The masked-token pattern of <File>' -ForEach @(@{ File = 'Summary' }, @{ File = 'MainSummary' }) {
    It 'matches every token shape the collector writes: <Token>' -ForEach @(
        @{ Token = 'prod_{0}' }, @{ Token = 'nonprod_{0}' },
        @{ Token = 'prod_aks_{0}' }, @{ Token = 'nonprod_aks_{0}' },
        @{ Token = 'prod_vmss_{0}' }, @{ Token = 'prod_databricks_{0}' }
    ) {
        ($Token -f $script:Guid) | Should -Match $script:Patterns[$File]
    }

    It 'does not match a real name or a token with another hint: <Name>' -ForEach @(
        @{ Name = 'Contoso Production' }, @{ Name = 'prod_web_{0}' }, @{ Name = 'prod-{0}' }, @{ Name = 'aks_{0}' }
    ) {
        ($Name -f $script:Guid) | Should -Not -Match $script:Patterns[$File]
    }
}
