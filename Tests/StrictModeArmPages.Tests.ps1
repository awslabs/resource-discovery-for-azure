# The ARM page readers under Set-StrictMode -Version Latest.
#
# Azure leaves nextLink out of the last page of a list (and value out of some
# empty answers). Invoke-RoleCheckGet (the up-front role check) and
# Get-UsageAggregatesPage (the consumption check and phase) read both, so a run
# started from a shell with Set-StrictMode -Version Latest must not stop on a
# page without them: the role check would come back inconclusive and skip
# every subscription.
#
# The role check and the consumption check read Failed, which only a check
# that threw carries, so a result without it must not stop either check.
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

Describe 'Reading a failed call''s status under Set-StrictMode -Version Latest' {
    BeforeEach { Set-StrictMode -Version Latest }
    AfterEach { Set-StrictMode -Off }

    It 'reads the status of an exception that has no Response, and none from one that has neither' {
        $Http = [System.Net.Http.HttpRequestException]::new('HTTP 429', $null, [System.Net.HttpStatusCode]::TooManyRequests)
        Get-ConsumptionErrorStatusCode -Exception $Http | Should -Be 429
        Get-ConsumptionErrorStatusCode -Exception ([System.IO.IOException]::new('Error while copying content to a stream.')) | Should -BeNullOrEmpty
        Get-ConsumptionErrorStatusCode -Exception ([System.Exception]::new('outer', $Http)) | Should -Be 429
    }

    It 'retries a role check call that was throttled once, and reads the next answer' {
        Mock Start-Sleep { }
        $script:RestCalls = 0
        $script:ArmAnswer = $null
        function global:Invoke-AzRestMethod { param([string]$Method, [string]$Path, [string]$Payload) $script:RestCalls++; if ($script:RestCalls -eq 1) { [pscustomobject]@{ StatusCode = 429; Content = '{}' } } else { [pscustomobject]@{ StatusCode = 200; Content = '{"value":[{"id":"a"}]}' } } }
        try
        {
            $R = Invoke-RoleCheckGet -Path '/subscriptions/x/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01'
        }
        finally
        {
            function global:Invoke-AzRestMethod { param([string]$Method, [string]$Path, [string]$Payload) $script:ArmAnswer }
        }
        $R.Error | Should -BeNullOrEmpty
        $R.Status | Should -Be 200
        $script:RestCalls | Should -Be 2
    }
}

Describe 'Reading a check result without Failed under Set-StrictMode -Version Latest' {
    BeforeAll {
        $script:Sub = [pscustomobject]@{ Id = '00000000-0000-0000-0000-000000000001'; Name = 'sub-one' }
        Mock Write-Host {}
    }
    BeforeEach { Set-StrictMode -Version Latest }
    AfterEach { Set-StrictMode -Off }

    It 'keeps a role check record that did not fail' {
        Mock Get-RoleCheckCallerObjectId { 'caller' }
        Mock Get-SubscriptionRoleAccess {
            [pscustomobject]@{ Id = $Item.Id; Name = $Item.Name; State = 'Readable'; Verdict = 'Readable'; Reason = 'reader'; UsageVerdict = $null; UsageText = $null; Assignments = 1; Permissions = $null; Seconds = 0.1 }
        }
        $Records = @(Test-SubscriptionRoleAccessAll -Subscriptions @($script:Sub) -ThrottleLimit 1)
        $Records.Count | Should -Be 1
        $Records[0].State | Should -Be 'Readable'
    }

    It 'keeps a consumption check result that did not fail' {
        Mock Get-SubscriptionResourceCounts { @{} }
        Mock Get-SubscriptionConsumptionCheck {
            [pscustomobject]@{ Id = $Item.Id; Name = $Item.Name; ResourceCount = $null; Outcome = 'Pass'; Passed = $true; Detail = 'usage found'; PageCapReached = $false; PagesRead = 1; Seconds = 0.1 }
        }
        $Result = Invoke-ConsumptionDataCheck -Subscriptions @($script:Sub) -ThrottleLimit 1
        $Result.ShouldBlock | Should -BeFalse
    }
}
