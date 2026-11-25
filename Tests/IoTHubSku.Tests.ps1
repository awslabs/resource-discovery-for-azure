# IoT Hub SKU and SKUTier tests
# Run with: Invoke-Pester ./Tests/IoTHubSku.Tests.ps1 -Output Detailed
#
# Services/Integration/IOTHubs.ps1 read the SKU from properties.sku, where Azure
# does not put it: the SKU is on the resource itself (sku.name and sku.tier), so
# both columns were empty for every hub. The REAL collector runs on synthetic
# records shaped as Resource Graph returns them; no live Azure.

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    # The Azure documentation placeholder; not a real subscription id.
    $script:Guid = '12345678-1234-1234-1234-123456789012'
    $script:Subs = @([pscustomobject]@{ id = $script:Guid; Name = 'sub-placeholder' })
    $script:Rg = "/subscriptions/$($script:Guid)/resourceGroups/rg-a/providers"

    function Invoke-Collector
    {
        param($Records)
        return , @(& (Join-Path $script:Root 'Services/Integration/IOTHubs.ps1') -Sub $script:Subs -Resources @($Records) -Task 'Processing' -ResourceIdDictionary $null)
    }

    function New-Hub
    {
        param($Sku, [switch]$NoSku)
        $Hub = [ordered]@{
            TYPE           = 'microsoft.devices/iothubs'
            id             = "$($script:Rg)/microsoft.devices/iothubs/iot-a"
            NAME           = 'iot-a'
            RESOURCEGROUP  = 'rg-a'
            LOCATION       = 'eastus'
            subscriptionId = $script:Guid
            PROPERTIES     = [pscustomobject]@{
                state             = 'Active'
                locations         = @([pscustomobject]@{ location = 'eastus'; role = 'primary' }, [pscustomobject]@{ location = 'westus'; role = 'secondary' })
                eventHubEndpoints = [pscustomobject]@{ events = [pscustomobject]@{ retentionTimeInDays = 1; partitionCount = 2; path = 'iot-a' } }
                cloudToDevice     = [pscustomobject]@{ maxDeliveryCount = 10 }
            }
        }
        if (-not $NoSku) { $Hub['sku'] = $Sku }
        return [pscustomobject]$Hub
    }
}

Describe 'IoT Hub SKU and SKUTier' {
    It 'reads the top-level sku <Name>/<Tier> on every location row' -ForEach @(
        @{ Name = 'F1'; Tier = 'Free' }
        @{ Name = 'S1'; Tier = 'Standard' }
        @{ Name = 'B2'; Tier = 'Basic' }
    ) {
        $Rows = Invoke-Collector @(New-Hub -Sku ([pscustomobject]@{ name = $Name; tier = $Tier; capacity = 1 }))
        $Rows.Count | Should -Be 2
        foreach ($Row in $Rows)
        {
            $Row.SKU | Should -BeExactly $Name
            $Row.SKUTier | Should -BeExactly $Tier
        }
        ($Rows | ForEach-Object { $_.Location }) | Should -Be @('eastus', 'westus')
    }

    It 'leaves the other columns unchanged' {
        $Rows = Invoke-Collector @(New-Hub -Sku ([pscustomobject]@{ name = 'S1'; tier = 'Standard'; capacity = 1 }))
        $Rows[0].State | Should -BeExactly 'Active'
        $Rows[0].Role | Should -BeExactly 'primary'
        $Rows[0].EventRetentionTimeInDays | Should -BeExactly '1'
        $Rows[0].EventPartitionCount | Should -BeExactly '2'
        $Rows[0].MaxDeliveryCount | Should -BeExactly '10'
    }

    It 'writes empty SKU columns when the hub has no sku, and keeps the rows' {
        $Rows = Invoke-Collector @(New-Hub -NoSku)
        $Rows.Count | Should -Be 2
        foreach ($Row in $Rows)
        {
            $Row.SKU | Should -BeNullOrEmpty
            $Row.SKUTier | Should -BeNullOrEmpty
            $Row.State | Should -BeExactly 'Active'
        }
    }
}
