# Automation runbook LastModifiedTime tests
# Run with: Invoke-Pester ./Tests/AutomationRunbookModifiedTime.Tests.ps1 -Output Detailed
#
# Services/Infrastructure/AutomationAcc.ps1 wrote the runbook's lastModifiedTime
# as 'MM/dd/yyyy hh:mm': a 12-hour clock with no AM/PM, so 18:49 read as 06:49,
# in a format no other date column uses. It is now 'yyyy-MM-dd HH:mm', the
# format of AutomationAccountCreatedTime in the same file, converted the same
# way. The REAL collector runs on synthetic records; no live Azure.

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    # The Azure documentation placeholder; not a real subscription id.
    $script:Guid = '12345678-1234-1234-1234-123456789012'
    $script:Subs = @([pscustomobject]@{ id = $script:Guid; Name = 'sub-placeholder' })
    $script:Rg = "/subscriptions/$($script:Guid)/resourceGroups/rg-a/providers"

    function Invoke-Collector
    {
        param($Records)
        return , @(& (Join-Path $script:Root 'Services/Infrastructure/AutomationAcc.ps1') -Sub $script:Subs -Resources @($Records) -Task 'Processing' -ResourceIdDictionary $null)
    }

    function New-Records
    {
        param($Created, $Modified)
        $Account = [pscustomobject]@{
            TYPE           = 'microsoft.automation/automationaccounts'
            id             = "$($script:Rg)/microsoft.automation/automationaccounts/aa-a"
            name           = 'aa-a'
            RESOURCEGROUP  = 'rg-a'
            LOCATION       = 'eastus'
            subscriptionId = $script:Guid
            properties     = [pscustomobject]@{ creationTime = $Created; State = 'Ok'; sku = [pscustomobject]@{ name = 'Basic' } }
        }
        $Runbook = [pscustomobject]@{
            TYPE           = 'microsoft.automation/automationaccounts/runbooks'
            id             = "$($script:Rg)/microsoft.automation/automationaccounts/aa-a/runbooks/rb-a"
            name           = 'aa-a/rb-a'
            RESOURCEGROUP  = 'rg-a'
            LOCATION       = 'eastus'
            subscriptionId = $script:Guid
            PROPERTIES     = [pscustomobject]@{ lastModifiedTime = $Modified; state = 'Published'; runbookType = 'PowerShell' }
        }
        return @($Account, $Runbook)
    }
}

Describe 'Automation runbook LastModifiedTime' {
    # A timestamp with no offset formats the same in every time zone.
    It 'writes <Value> as <Expected>' -ForEach @(
        @{ Value = '2026-10-28T18:49:00'; Expected = '2026-10-28 18:49' }
        @{ Value = '2026-10-28T06:49:09.52'; Expected = '2026-10-28 06:49' }
        @{ Value = '2026-10-28T00:05:00'; Expected = '2026-10-28 00:05' }
        @{ Value = '2026-10-28T12:30:00'; Expected = '2026-10-28 12:30' }
    ) {
        $Rows = Invoke-Collector (New-Records -Created '2026-01-01T00:00:00' -Modified $Value)
        $Rows.Count | Should -Be 1
        $Rows[0].LastModifiedTime | Should -BeExactly $Expected
    }

    It 'writes the same text as AutomationAccountCreatedTime for the same time in Azure''s shape (<Value>)' -ForEach @(
        @{ Value = '2026-10-28T18:49:09.52+00:00' }
        @{ Value = '2026-10-28T06:49:09.52+00:00' }
        @{ Value = '2026-10-28T20:49:00+02:00' }
    ) {
        $Rows = Invoke-Collector (New-Records -Created $Value -Modified $Value)
        $Rows.Count | Should -Be 1
        $Rows[0].LastModifiedTime | Should -Match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$'
        $Rows[0].LastModifiedTime | Should -BeExactly $Rows[0].AutomationAccountCreatedTime
    }

    It 'leaves LastModifiedTime empty on an account with no runbook' {
        $Rows = Invoke-Collector @((New-Records -Created '2026-10-28T18:49:00' -Modified '2026-10-28T18:49:00')[0])
        $Rows.Count | Should -Be 1
        $Rows[0].LastModifiedTime | Should -BeNullOrEmpty
        $Rows[0].AutomationAccountCreatedTime | Should -BeExactly '2026-10-28 18:49'
    }
}
