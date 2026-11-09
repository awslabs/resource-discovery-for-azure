# Run-AllSubscriptions.ps1 reads the completed subscription ids of the resume
# state as an array.
#
# Get-CompletedSubscriptionIds returns $null for no ids and a bare string for
# one id (PowerShell unrolls the array it returns). The wrapper adds each
# subscription it completes with `+=`, and merges the per-stream lists into it,
# so a bare string would join the next id onto the first one ('sub-asub-b'),
# and a later -Resume would collect the completed subscriptions again.
#
# The startup statement is taken from the wrapper's parsed source and run as
# written, with Get-CompletedSubscriptionIds standing in for the state file.
#
# Run with: Invoke-Pester ./Tests/CompletedIdsRead.Tests.ps1 -Output Detailed

BeforeAll {
    $RepoRoot = Split-Path $PSScriptRoot -Parent
    $Ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'Run-AllSubscriptions.ps1'), [ref]$null, [ref]$null)
    $Found = @($Ast.EndBlock.Statements | Where-Object { $_.Extent.Text -match '^\$CompletedIds = (@\()?Get-CompletedSubscriptionIds ' })
    if ($Found.Count -ne 1) { throw ('expected one startup read of the completed ids in Run-AllSubscriptions.ps1, found {0}' -f $Found.Count) }
    $script:ReadText = $Found[0].Extent.Text
}

Describe 'The startup read of the completed ids' {
    It 'keeps <Label> as an array, so the next completed id is added beside them' -ForEach @(
        @{ Label = 'no ids'; Ids = $null; Expected = @('sub-b') }
        @{ Label = 'one id'; Ids = 'sub-a'; Expected = @('sub-a', 'sub-b') }
        @{ Label = 'two ids'; Ids = @('sub-a', 'sub-c'); Expected = @('sub-a', 'sub-c', 'sub-b') }
    ) {
        function Get-CompletedSubscriptionIds { param($Path, $Tenant) return $Ids }
        $ResumeStateFile = 'unused'
        $TenantID = 'unused'
        . ([scriptblock]::Create($script:ReadText))
        $CompletedIds += 'sub-b'
        @($CompletedIds) | Should -Be $Expected
    }
}
