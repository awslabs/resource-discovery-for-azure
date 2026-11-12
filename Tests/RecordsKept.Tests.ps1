# Collectors keep a resource that has no child yet
# Run with: Invoke-Pester ./Tests/RecordsKept.Tests.ps1 -Output Detailed
#
# The AVD and Virtual WAN collectors wrote rows only per child: a session host
# for a host pool, a hub for a virtual WAN. A host pool with no session host,
# or a WAN with no hub, both normal right after they are created, produced no
# row and was missing from the inventory. AvSet.ps1 writes the parent row with
# the child column empty when a set has no VMs; these collectors now do the
# same. Resources that have children get the same rows as before.
#
# Records are built the way Resource Graph answers reach the collectors: JSON
# text, lowercased, then ConvertFrom-Json. No live Azure is needed. All ids use
# the Azure documentation placeholder subscription id.

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    $script:G = '12345678-1234-1234-1234-123456789012'
    $script:Rg = "/subscriptions/$script:G/resourceGroups/RG-Kept/providers"
    $script:Subs = @([pscustomobject]@{ id = $script:G; Name = 'sub-placeholder' })

    function ConvertTo-GraphRecords
    {
        param($Records)
        return ((ConvertTo-Json -InputObject @($Records) -Depth 10).ToLower() | ConvertFrom-Json)
    }

    function Invoke-Collector
    {
        param([string]$Collector, $Records)
        return @(& (Join-Path $script:Root ("Services/{0}.ps1" -f $Collector)) -Sub $script:Subs -Resources (ConvertTo-GraphRecords $Records) -Task 'Processing' -ResourceIdDictionary $null)
    }

    function New-Arm
    {
        param([string]$Type, [string]$Name, $Properties, [string]$Id)
        [ordered]@{ id = $(if ($Id) { $Id } else { "$script:Rg/$Type/$Name" }); name = $Name; type = $Type; resourceGroup = 'RG-Kept'; location = 'eastus'; subscriptionId = $script:G; properties = $Properties }
    }
}

Describe 'AVD: a host pool with no session host keeps its row' {
    BeforeAll {
        function New-Pool
        {
            param([string]$Name)
            New-Arm -Type 'Microsoft.DesktopVirtualization/hostpools' -Name $Name -Properties ([ordered]@{ hostPoolType = 'Pooled'; loadBalancerType = 'BreadthFirst'; maxSessionLimit = 10; preferredAppGroupType = 'Desktop' })
        }
        function New-SessionHost
        {
            param([string]$Pool, [string]$Vm)
            New-Arm -Type 'Microsoft.DesktopVirtualization/hostpools/sessionhosts' -Name "$Pool/$Vm.example.test" -Properties ([ordered]@{ resourceId = "$script:Rg/Microsoft.Compute/virtualMachines/$Vm"; agentVersion = '1.0.9'; allowNewSession = $true; status = 'Available'; osVersion = '10.0.22631' }) -Id "$script:Rg/Microsoft.DesktopVirtualization/hostpools/$Pool/sessionhosts/$Vm.example.test"
        }
        function New-Vm
        {
            param([string]$Name)
            New-Arm -Type 'Microsoft.Compute/virtualMachines' -Name $Name -Properties ([ordered]@{ hardwareProfile = [ordered]@{ vmSize = 'Standard_D4s_v5' }; storageProfile = [ordered]@{ osDisk = [ordered]@{ osType = 'Windows'; managedDisk = [ordered]@{ storageAccountType = 'Premium_LRS' } } } })
        }
        $script:Others = @((New-Pool 'hp-a'), (New-Pool 'hp-c'), (New-SessionHost 'hp-a' 'vm-a'), (New-SessionHost 'hp-c' 'vm-c'), (New-Vm 'vm-a'), (New-Vm 'vm-c'))
        $script:Valid = @(Invoke-Collector 'Compute/AVD' $script:Others)
    }

    It 'writes one row for a host pool with no session host, between two that have one' {
        $Out = @(Invoke-Collector 'Compute/AVD' (@($script:Others[0], (New-Pool 'hp-b')) + $script:Others[1..5]))
        ($Out | ForEach-Object { $_.Name }) | Should -Be @('hp-a', 'hp-b', 'hp-c')
        $B = $Out[1]
        $B.ID | Should -Match '/hp-b$'
        $B.HostPoolType | Should -BeExactly 'pooled'
        $B.MaxSessionLimit | Should -Be 10
        foreach ($Col in @('AVDAgentVersion', 'AllowNewSession', 'UpdateStatus', 'HostId', 'Hostname', 'VMSize', 'OSType', 'VMDiskType', 'HostStatus', 'OSVersion')) { $B[$Col] | Should -BeNullOrEmpty -Because "$Col belongs to a session host" }
        ConvertTo-Json $Out[0] -Compress | Should -BeExactly (ConvertTo-Json $script:Valid[0] -Compress)
        ConvertTo-Json $Out[2] -Compress | Should -BeExactly (ConvertTo-Json $script:Valid[1] -Compress)
    }

    It 'writes one row when the subscription has a host pool and no session host at all' {
        $Out = @(Invoke-Collector 'Compute/AVD' @(New-Pool 'hp-new'))
        $Out.Count | Should -Be 1
        $Out[0].Name | Should -BeExactly 'hp-new'
        $Out[0].HostId | Should -BeNullOrEmpty
    }

    It 'still writes one row per session host' {
        $Out = @(Invoke-Collector 'Compute/AVD' @((New-Pool 'hp-a'), (New-SessionHost 'hp-a' 'vm-a'), (New-SessionHost 'hp-a' 'vm-c'), (New-Vm 'vm-a'), (New-Vm 'vm-c')))
        ($Out | ForEach-Object { $_.HostId -replace '^.*/', '' }) | Should -Be @('vm-a', 'vm-c')
    }
}

Describe 'VirtualWAN: a WAN with no hub keeps its row' {
    BeforeAll {
        function New-Hub
        {
            param([string]$Name)
            New-Arm -Type 'Microsoft.Network/virtualHubs' -Name $Name -Properties ([ordered]@{ addressPrefix = '10.0.0.0/24' })
        }
        function New-Site
        {
            param([string]$Name)
            New-Arm -Type 'Microsoft.Network/vpnSites' -Name $Name -Properties ([ordered]@{ deviceProperties = [ordered]@{ deviceVendor = 'ExampleVendor' }; vpnSiteLinks = @([ordered]@{ properties = [ordered]@{ linkProperties = [ordered]@{ linkProviderName = 'ExampleIsp'; linkSpeedInMbps = 100 } } }) })
        }
        function New-Wan
        {
            param([string]$Name, [string[]]$Hubs = @(), [string[]]$Sites = @(), [switch]$NoHubList)
            $Props = [ordered]@{ type = 'Standard' }
            if (-not $NoHubList) { $Props.virtualHubs = @($Hubs | ForEach-Object { [ordered]@{ id = "$script:Rg/Microsoft.Network/virtualHubs/$_" } }) }
            $Props.vpnSites = @($Sites | ForEach-Object { [ordered]@{ id = "$script:Rg/Microsoft.Network/vpnSites/$_" } })
            New-Arm -Type 'Microsoft.Network/virtualWans' -Name $Name -Properties $Props
        }
        $script:Hubs = @((New-Hub 'hub-a'), (New-Hub 'hub-c'))
        $script:Valid = @(Invoke-Collector 'Networking/VirtualWAN' (@((New-Wan 'wan-a' -Hubs 'hub-a'), (New-Wan 'wan-c' -Hubs 'hub-c')) + $script:Hubs))
    }

    It 'writes one row for a WAN whose hub list is <Label>, between two that have a hub' -ForEach @(
        @{ Label = 'empty'; NoHubList = $false }
        @{ Label = 'absent'; NoHubList = $true }
    ) {
        $Out = @(Invoke-Collector 'Networking/VirtualWAN' (@((New-Wan 'wan-a' -Hubs 'hub-a'), (New-Wan 'wan-b' -NoHubList:$NoHubList), (New-Wan 'wan-c' -Hubs 'hub-c')) + $script:Hubs))
        ($Out | ForEach-Object { $_.Name }) | Should -Be @('wan-a', 'wan-b', 'wan-c')
        $Out[1].ID | Should -Match '/wan-b$'
        $Out[1].Location | Should -BeExactly 'eastus'
        ConvertTo-Json $Out[0] -Compress | Should -BeExactly (ConvertTo-Json $script:Valid[0] -Compress)
        ConvertTo-Json $Out[2] -Compress | Should -BeExactly (ConvertTo-Json $script:Valid[1] -Compress)
    }

    It 'writes one row per VPN site for a WAN with sites and no hub, the hub columns empty' {
        $Out = @(Invoke-Collector 'Networking/VirtualWAN' @((New-Wan 'wan-s' -Sites 'site-1'), (New-Site 'site-1')))
        $Out.Count | Should -Be 1
        $Out[0].Name | Should -BeExactly 'wan-s'
        $Out[0].HUBName | Should -BeNullOrEmpty
        $Out[0].HUBLocation | Should -BeNullOrEmpty
        $Out[0].DeviceVendor | Should -BeExactly 'examplevendor'
        $Out[0].LinkSpeedMbps | Should -BeExactly '100'
    }

    It 'still writes one row per hub' {
        $Out = @(Invoke-Collector 'Networking/VirtualWAN' (@(New-Wan 'wan-two' -Hubs 'hub-a', 'hub-c') + $script:Hubs))
        $Out.Count | Should -Be 2
    }
}
