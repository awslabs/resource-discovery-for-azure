# The ARM page readers under Set-StrictMode -Version Latest.
#
# Azure leaves nextLink out of the last page of a list (and value out of some
# empty answers). Invoke-RoleCheckGet (the up-front role check) and
# Get-UsageAggregatesPage (the consumption check and phase) read both, so a run
# started from a shell with Set-StrictMode -Version Latest must not stop on a
# page without them: the role check would come back inconclusive and skip
# every subscription.
#
# Run with: Invoke-Pester ./Tests/StrictModeArmPages.Tests.ps1 -Output Detailed

BeforeAll {
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'Functions/Common.Functions.ps1')
    function global:Invoke-AzRestMethod { param([string]$Method, [string]$Path, [string]$Payload) $script:ArmAnswer }
}

AfterAll {
    Remove-Item -Path 'Function:global:Invoke-AzRestMethod' -ErrorAction SilentlyContinue
}

Describe 'Reading an ARM page without nextLink under Set-StrictMode -Version Latest' {
    BeforeEach { Set-StrictMode -Version Latest }
    AfterEach { Set-StrictMode -Off }

    It 'reads a role assignment list whose only page has no nextLink' {
        $script:ArmAnswer = [pscustomobject]@{ StatusCode = 200; Content = '{"value":[{"id":"a"},{"id":"b"}]}' }
        $R = Invoke-RoleCheckGet -Path '/subscriptions/x/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01'
        $R.Error | Should -BeNullOrEmpty
        $R.Status | Should -Be 200
        @($R.Items).Count | Should -Be 2
    }

    It 'reads a usage page without nextLink, and one without value, as the last page' -ForEach @(
        @{ Content = '{"value":[{"properties":{"quantity":1}}]}'; Rows = 1 }
        @{ Content = '{}'; Rows = 0 }
    ) {
        $script:ArmAnswer = [pscustomobject]@{ StatusCode = 200; Content = $Content }
        $Page = Get-UsageAggregatesPage -SubscriptionId 'x' -ReportedStartTime ([datetime]'2026-10-01') -ReportedEndTime ([datetime]'2026-10-31')
        $Page.ContinuationToken | Should -BeNullOrEmpty
        @($Page.UsageAggregations).Count | Should -Be $Rows
    }
}
