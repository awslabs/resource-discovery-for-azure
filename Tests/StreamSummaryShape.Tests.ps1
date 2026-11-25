# Run-AllSubscriptions.Stream.ps1 writes one summary per stream, which the
# wrapper reads property by property. Under Set-StrictMode a property that is
# missing throws, so the short summaries (a stream that did not start, a
# stream with no subscriptions) hold every property of the full one.
#
# The three summaries are taken from the parsed source of the stream script.
#
# Run with: Invoke-Pester ./Tests/StreamSummaryShape.Tests.ps1 -Output Detailed

BeforeAll {
    $Path = Join-Path (Split-Path $PSScriptRoot -Parent) 'Run-AllSubscriptions.Stream.ps1'
    $Ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
    $Tables = @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] -and @($n.KeyValuePairs | ForEach-Object { $_.Item1.Extent.Text }) -contains 'StreamId' }, $true))
    function script:Get-Keys { param($Table) @($Table.KeyValuePairs | ForEach-Object { $_.Item1.Extent.Text }) }
    $script:Full = @($Tables | Where-Object { (script:Get-Keys $_) -contains 'NoReport' -and $_.Extent.Text -match "'partial-failure'" })
    $script:Short = @($Tables | Where-Object { $_.Extent.Text -match "Status\s*=\s*'failed-to-start'" -or $_.Extent.Text -match "SubsProcessed\s*=\s*0" })
}

Describe 'The short stream summaries' {
    It 'are found with the full one' {
        $script:Full.Count | Should -Be 1
        $script:Short.Count | Should -Be 2
    }

    It 'hold every property of the full summary (<Index>)' -ForEach @(@{ Index = 0 }, @{ Index = 1 }) {
        $Missing = @(script:Get-Keys $script:Full[0] | Where-Object { (script:Get-Keys $script:Short[$Index]) -notcontains $_ })
        $Missing | Should -BeNullOrEmpty
    }
}
