# Collector accumulator and VM OS-disk lookup tests
# Run with: Invoke-Pester ./Tests/CollectorSpeed.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# The collectors build their output in a List[object] and the VirtualMachines
# collector finds each VM's OS disk through an id index. Both are performance
# changes that must not change what a collector emits. These tests invoke the
# REAL collectors with synthetic resource rows and pin the output:
#
#   - VirtualMachines: the OS-disk SKU and size are found when the VM's disk
#     reference differs from the disk's own id only in letter case (Azure
#     resource ids are case-insensitive), when two disk rows share an id, and
#     when a disk row has no id; VMs without a managed disk keep the
#     'Custom VHD' / 'None' branches.
#   - VMDisk, RedisCache (two append sites) and AvSet (one row per member VM):
#     zero matching rows emit nothing, one row emits the bare record, many rows
#     emit one record per row in input order, with the same fields and values.
#
# No live Azure: Get-AzComputeResourceSku is mocked. All GUIDs are the Azure
# documentation placeholder, not real identifiers.

BeforeAll {
    $script:ServicesRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'Services' | Resolve-Path | Select-Object -ExpandProperty Path

    $script:DocGuid = '12345678-1234-1234-1234-123456789012'
    $script:Subs = @([pscustomobject]@{ id = $script:DocGuid; Name = 'sub-speed' })
    $script:RgPath = "/subscriptions/$($script:DocGuid)/resourceGroups/rg-speed/providers"

    # The VirtualMachines collector asks Azure for VM sizes; a stub lets the mock
    # attach on hosts without the Az.Compute module.
    if (-not (Get-Command -Name Get-AzComputeResourceSku -ErrorAction SilentlyContinue))
    {
        function global:Get-AzComputeResourceSku { param($Location) }
    }

    function Invoke-TestCollector
    {
        param([string]$RelPath, $Resources)
        $Collector = Join-Path -Path $script:ServicesRoot -ChildPath $RelPath
        & $Collector -Sub $script:Subs -Resources $Resources -Task 'Processing' -ResourceIdDictionary $null
    }

    function New-TestVm
    {
        param([string]$Name, $OsDisk)
        [pscustomobject]@{
            TYPE           = 'microsoft.compute/virtualmachines'
            id             = "$($script:RgPath)/Microsoft.Compute/virtualMachines/$Name"
            NAME           = $Name
            RESOURCEGROUP  = 'rg-speed'
            LOCATION       = 'eastus'
            subscriptionId = $script:DocGuid
            zones          = $null
            tags           = $null
            PROPERTIES     = [pscustomobject]@{
                hardwareProfile = [pscustomobject]@{ vmSize = 'Standard_D2s_v3' }
                storageProfile  = [pscustomobject]@{ osDisk = $OsDisk }
            }
        }
    }

    function New-TestManagedOsDisk
    {
        param([string]$DiskId)
        [pscustomobject]@{ osType = 'Linux'; managedDisk = [pscustomobject]@{ id = $DiskId } }
    }

    function New-TestDisk
    {
        param([AllowNull()][string]$Id, [string]$Name, [string]$Sku = 'Premium_LRS', [int]$SizeGB = 128, [string]$ManagedBy = '')
        [pscustomobject]@{
            TYPE           = 'microsoft.compute/disks'
            id             = if ([string]::IsNullOrEmpty($Id)) { $null } else { $Id }
            NAME           = $Name
            RESOURCEGROUP  = 'rg-speed'
            LOCATION       = 'eastus'
            subscriptionId = $script:DocGuid
            MANAGEDBY      = $ManagedBy
            SKU            = [pscustomobject]@{ name = $Sku; tier = 'Premium' }
            PROPERTIES     = [pscustomobject]@{
                diskState         = 'Attached'
                Tier              = 'P10'
                diskSizeGB        = $SizeGB
                osType            = 'Linux'
                diskIOPSReadWrite = 500
                diskMBpsReadWrite = 100
                timeCreated       = '2026-01-02T03:04:05'
            }
        }
    }

    # Compare one emitted record field by field against the expected hashtable.
    function Assert-TestRecord
    {
        param($Actual, [hashtable]$Expected)
        ($Actual -is [hashtable]) | Should -BeTrue -Because 'each record is a single hashtable, never an array'
        @($Actual.Keys | Sort-Object) | Should -Be @($Expected.Keys | Sort-Object)
        foreach ($Key in $Expected.Keys)
        {
            $Actual[$Key] | Should -Be $Expected[$Key] -Because "field '$Key'"
        }
    }
}

Describe 'VirtualMachines OS-disk lookup' {

    BeforeAll {
        Mock Get-AzComputeResourceSku { @() }
    }

    It 'finds the OS disk when the VM reference differs from the disk id only in letter case' {
        $Vm = New-TestVm -Name 'vm-case' -OsDisk (New-TestManagedOsDisk -DiskId "$($script:RgPath)/Microsoft.Compute/disks/OsDisk-Case")
        $Disk = New-TestDisk -Id "/subscriptions/$($script:DocGuid)/resourcegroups/rg-speed/providers/microsoft.compute/disks/osdisk-case" -Name 'osdisk-case' -Sku 'Premium_LRS' -SizeGB 128

        $Rec = Invoke-TestCollector -RelPath 'Compute/VirtualMachines.ps1' -Resources @($Vm, $Disk)

        $Rec | Should -BeOfType ([hashtable])
        $Rec['OSDisk'] | Should -Be 'Premium_LRS'
        $Rec['OSDiskSizeGB'] | Should -Be 128
    }

    It 'keeps disk rows that share an id in input order, so the result matches a scan of the disk list' {
        $DiskId = "$($script:RgPath)/Microsoft.Compute/disks/osdisk-dup"
        $Vm = New-TestVm -Name 'vm-dup' -OsDisk (New-TestManagedOsDisk -DiskId $DiskId)
        $Same1 = New-TestDisk -Id $DiskId -Name 'osdisk-dup' -Sku 'Premium_LRS' -SizeGB 64
        $Same2 = New-TestDisk -Id $DiskId -Name 'osdisk-dup' -Sku 'Premium_LRS' -SizeGB 64
        $Other = New-TestDisk -Id $DiskId -Name 'osdisk-dup' -Sku 'StandardSSD_LRS' -SizeGB 256

        $Identical = Invoke-TestCollector -RelPath 'Compute/VirtualMachines.ps1' -Resources @($Vm, $Same1, $Same2)
        $Identical['OSDisk'] | Should -Be 'Premium_LRS'
        $Identical['OSDiskSizeGB'] | Should -Be 64

        # Select-Object -Unique keeps the first of these rows, so which one is
        # reported depends only on the order the rows arrive in.
        $SameFirst = Invoke-TestCollector -RelPath 'Compute/VirtualMachines.ps1' -Resources @($Vm, $Same1, $Other)
        $SameFirst['OSDisk'] | Should -Be 'Premium_LRS'
        $SameFirst['OSDiskSizeGB'] | Should -Be 64

        $OtherFirst = Invoke-TestCollector -RelPath 'Compute/VirtualMachines.ps1' -Resources @($Vm, $Other, $Same1)
        $OtherFirst['OSDisk'] | Should -Be 'StandardSSD_LRS'
        $OtherFirst['OSDiskSizeGB'] | Should -Be 256
    }

    It 'ignores a disk row with no id and still resolves the valid disks around it' {
        $Vm1 = New-TestVm -Name 'vm-a' -OsDisk (New-TestManagedOsDisk -DiskId "$($script:RgPath)/Microsoft.Compute/disks/osdisk-a")
        $Vm2 = New-TestVm -Name 'vm-b' -OsDisk (New-TestManagedOsDisk -DiskId "$($script:RgPath)/Microsoft.Compute/disks/osdisk-b")
        $NoId = New-TestDisk -Id $null -Name 'orphan' -Sku 'UltraSSD_LRS' -SizeGB 1024
        $DiskA = New-TestDisk -Id "$($script:RgPath)/Microsoft.Compute/disks/osdisk-a" -Name 'osdisk-a' -Sku 'Premium_LRS' -SizeGB 128
        $DiskB = New-TestDisk -Id "$($script:RgPath)/Microsoft.Compute/disks/osdisk-b" -Name 'osdisk-b' -Sku 'Standard_LRS' -SizeGB 32

        $Recs = @(Invoke-TestCollector -RelPath 'Compute/VirtualMachines.ps1' -Resources @($Vm1, $NoId, $Vm2, $DiskA, $DiskB))

        $Recs.Count | Should -Be 2
        $Recs[0]['OSDisk'] | Should -Be 'Premium_LRS'
        $Recs[0]['OSDiskSizeGB'] | Should -Be 128
        $Recs[1]['OSDisk'] | Should -Be 'Standard_LRS'
        $Recs[1]['OSDiskSizeGB'] | Should -Be 32
    }

    It 'leaves the OS-disk fields empty when the referenced disk is not in the inventory' {
        $Vm = New-TestVm -Name 'vm-missing' -OsDisk (New-TestManagedOsDisk -DiskId "$($script:RgPath)/Microsoft.Compute/disks/not-listed")
        $Disk = New-TestDisk -Id "$($script:RgPath)/Microsoft.Compute/disks/some-other" -Name 'some-other'

        $Rec = Invoke-TestCollector -RelPath 'Compute/VirtualMachines.ps1' -Resources @($Vm, $Disk)

        $Rec['OSDisk'] | Should -BeNullOrEmpty
        $Rec['OSDiskSizeGB'] | Should -BeNullOrEmpty
    }

    It "reports 'Custom VHD' or 'None' for a VM without a managed OS disk" {
        $VhdVm = New-TestVm -Name 'vm-vhd' -OsDisk ([pscustomobject]@{ osType = 'Linux'; diskSizeGB = 30; vhd = [pscustomobject]@{ uri = 'https://example.invalid/vhds/os.vhd' } })
        $BareVm = New-TestVm -Name 'vm-bare' -OsDisk ([pscustomobject]@{ osType = 'Linux'; diskSizeGB = 40 })
        $Disk = New-TestDisk -Id "$($script:RgPath)/Microsoft.Compute/disks/unrelated" -Name 'unrelated'

        $Recs = @(Invoke-TestCollector -RelPath 'Compute/VirtualMachines.ps1' -Resources @($VhdVm, $BareVm, $Disk))

        $Recs.Count | Should -Be 2
        $Recs[0]['OSDisk'] | Should -Be 'Custom VHD'
        $Recs[0]['OSDiskSizeGB'] | Should -Be 30
        $Recs[1]['OSDisk'] | Should -Be 'None'
        $Recs[1]['OSDiskSizeGB'] | Should -Be 40
    }
}

Describe 'Collector output shape for zero, one and many rows' {

    Context 'VMDisk' {

        BeforeAll {
            function Get-ExpectedDiskRecord
            {
                param($Disk, $AssociatedResource)
                @{
                    ID                 = $Disk.id
                    Subscription       = 'sub-speed'
                    ResourceGroup      = 'rg-speed'
                    Name               = $Disk.NAME
                    State              = 'Attached'
                    AssociatedResource = $AssociatedResource
                    Location           = 'eastus'
                    SKU                = $Disk.SKU.name
                    Tier               = 'P10'
                    Size               = $Disk.PROPERTIES.diskSizeGB
                    OSType             = 'Linux'
                    DiskIOPS           = 500
                    DiskMBps           = 100
                    CreatedTime        = '2026-01-02 03:04'
                }
            }
        }

        It 'emits nothing when there are no disks' {
            $Other = [pscustomobject]@{ TYPE = 'microsoft.network/publicipaddresses'; id = "$($script:RgPath)/Microsoft.Network/publicIPAddresses/pip1" }
            $Result = Invoke-TestCollector -RelPath 'Storage/VMDisk.ps1' -Resources @($Other)
            $null -eq $Result | Should -BeTrue
        }

        It 'emits the bare record for one disk' {
            $Disk = New-TestDisk -Id "$($script:RgPath)/Microsoft.Compute/disks/data1" -Name 'data1' -ManagedBy "$($script:RgPath)/Microsoft.Compute/virtualMachines/vm-owner"
            $Result = Invoke-TestCollector -RelPath 'Storage/VMDisk.ps1' -Resources @($Disk)
            Assert-TestRecord -Actual $Result -Expected (Get-ExpectedDiskRecord -Disk $Disk -AssociatedResource 'vm-owner')
        }

        It 'emits one record per disk in input order' {
            $Disks = foreach ($i in 1..25) { New-TestDisk -Id "$($script:RgPath)/Microsoft.Compute/disks/data$i" -Name "data$i" -SizeGB (8 * $i) }
            $Result = Invoke-TestCollector -RelPath 'Storage/VMDisk.ps1' -Resources $Disks
            ($Result -is [object[]]) | Should -BeTrue -Because 'many records reach the caller as a plain array, not a List'
            $Result.Count | Should -Be 25
            for ($i = 0; $i -lt 25; $i++)
            {
                Assert-TestRecord -Actual $Result[$i] -Expected (Get-ExpectedDiskRecord -Disk $Disks[$i] -AssociatedResource $null)
            }
        }
    }

    Context 'RedisCache' {

        BeforeAll {
            function New-TestRedis
            {
                param([string]$Name, [switch]$Enterprise)
                if ($Enterprise)
                {
                    [pscustomobject]@{
                        TYPE = 'microsoft.cache/redisenterprise'; id = "$($script:RgPath)/Microsoft.Cache/redisEnterprise/$Name"; Name = $Name
                        ResourceGroup = 'rg-speed'; Location = 'eastus'; subscriptionId = $script:DocGuid
                        sku = [pscustomobject]@{ name = 'Enterprise_E10'; capacity = 2 }; Properties = [pscustomobject]@{}
                    }
                }
                else
                {
                    [pscustomobject]@{
                        TYPE = 'microsoft.cache/redis'; id = "$($script:RgPath)/Microsoft.Cache/Redis/$Name"; Name = $Name
                        ResourceGroup = 'rg-speed'; Location = 'eastus'; subscriptionId = $script:DocGuid
                        Properties = [pscustomobject]@{ sku = [pscustomobject]@{ name = 'Standard'; capacity = 1; family = 'C' } }
                    }
                }
            }

            function Get-ExpectedRedisRecord
            {
                param($Cache)
                $Enterprise = $Cache.TYPE -eq 'microsoft.cache/redisenterprise'
                @{
                    ID            = $Cache.id
                    Subscription  = 'sub-speed'
                    ResourceGroup = 'rg-speed'
                    Name          = $Cache.Name
                    Location      = 'eastus'
                    Sku           = if ($Enterprise) { 'Enterprise_E10' } else { 'Standard' }
                    Capacity      = if ($Enterprise) { 2 } else { 1 }
                    Family        = if ($Enterprise) { 'enterprise' } else { 'C' }
                }
            }
        }

        It 'emits nothing when there are no caches' {
            $Disk = New-TestDisk -Id "$($script:RgPath)/Microsoft.Compute/disks/d1" -Name 'd1'
            $Result = Invoke-TestCollector -RelPath 'Data/RedisCache.ps1' -Resources @($Disk)
            $null -eq $Result | Should -BeTrue
        }

        It 'emits the bare record for one cache of either kind' {
            foreach ($Cache in @((New-TestRedis -Name 'cache1'), (New-TestRedis -Name 'ent1' -Enterprise)))
            {
                $Result = Invoke-TestCollector -RelPath 'Data/RedisCache.ps1' -Resources @($Cache)
                Assert-TestRecord -Actual $Result -Expected (Get-ExpectedRedisRecord -Cache $Cache)
            }
        }

        It 'emits one record per cache from both append sites' {
            # The collector lists all basic caches first, then all enterprise ones.
            $Basic = foreach ($i in 1..6) { New-TestRedis -Name "cache$i" }
            $Ent = foreach ($i in 1..4) { New-TestRedis -Name "ent$i" -Enterprise }
            $Mixed = @($Ent[0], $Basic[0], $Ent[1]) + $Basic[1..5] + $Ent[2..3]
            $Result = Invoke-TestCollector -RelPath 'Data/RedisCache.ps1' -Resources $Mixed
            $Expected = @($Basic) + @($Ent)
            $Result.Count | Should -Be 10
            for ($i = 0; $i -lt 10; $i++)
            {
                Assert-TestRecord -Actual $Result[$i] -Expected (Get-ExpectedRedisRecord -Cache $Expected[$i])
            }
        }
    }

    Context 'AvSet' {

        BeforeAll {
            function New-TestAvSet
            {
                param([string]$Name, [string[]]$VmNames)
                $Members = @($VmNames | ForEach-Object { [pscustomobject]@{ id = "$($script:RgPath)/Microsoft.Compute/virtualMachines/$_" } })
                [pscustomobject]@{
                    TYPE = 'microsoft.compute/availabilitysets'; id = "$($script:RgPath)/Microsoft.Compute/availabilitySets/$Name"; NAME = $Name
                    RESOURCEGROUP = 'rg-speed'; LOCATION = 'eastus'; subscriptionId = $script:DocGuid
                    PROPERTIES = [pscustomobject]@{ platformFaultDomainCount = 2; platformUpdateDomainCount = 5; virtualMachines = $Members }
                }
            }

            function Get-ExpectedAvSetRecord
            {
                param($AvSet, $VmName)
                @{
                    ID              = $AvSet.id
                    Subscription    = 'sub-speed'
                    ResourceGroup   = 'rg-speed'
                    Name            = $AvSet.NAME
                    Location        = 'eastus'
                    FaultDomains    = '2'
                    UpdateDomains   = '5'
                    VirtualMachines = $VmName
                }
            }
        }

        It 'emits nothing when there are no availability sets' {
            $Disk = New-TestDisk -Id "$($script:RgPath)/Microsoft.Compute/disks/d1" -Name 'd1'
            $Result = Invoke-TestCollector -RelPath 'Infrastructure/AvSet.ps1' -Resources @($Disk)
            $null -eq $Result | Should -BeTrue
        }

        It 'emits the bare record for one set, with or without a member VM' {
            $Empty = New-TestAvSet -Name 'avset-empty' -VmNames @()
            $Result = Invoke-TestCollector -RelPath 'Infrastructure/AvSet.ps1' -Resources @($Empty)
            Assert-TestRecord -Actual $Result -Expected (Get-ExpectedAvSetRecord -AvSet $Empty -VmName '')

            $One = New-TestAvSet -Name 'avset-one' -VmNames @('vm1')
            $Result = Invoke-TestCollector -RelPath 'Infrastructure/AvSet.ps1' -Resources @($One)
            Assert-TestRecord -Actual $Result -Expected (Get-ExpectedAvSetRecord -AvSet $One -VmName 'vm1')
        }

        It 'emits one record per member VM, and one for a set without members, in input order' {
            $Full = New-TestAvSet -Name 'avset-full' -VmNames @('vm1', 'vm2', 'vm3')
            $Empty = New-TestAvSet -Name 'avset-empty' -VmNames @()
            $Pair = New-TestAvSet -Name 'avset-pair' -VmNames @('vm4', 'vm5')
            $Result = Invoke-TestCollector -RelPath 'Infrastructure/AvSet.ps1' -Resources @($Full, $Empty, $Pair)
            $Expected = @(
                (Get-ExpectedAvSetRecord -AvSet $Full -VmName 'vm1'),
                (Get-ExpectedAvSetRecord -AvSet $Full -VmName 'vm2'),
                (Get-ExpectedAvSetRecord -AvSet $Full -VmName 'vm3'),
                (Get-ExpectedAvSetRecord -AvSet $Empty -VmName ''),
                (Get-ExpectedAvSetRecord -AvSet $Pair -VmName 'vm4'),
                (Get-ExpectedAvSetRecord -AvSet $Pair -VmName 'vm5')
            )
            $Result.Count | Should -Be 6
            for ($i = 0; $i -lt 6; $i++)
            {
                Assert-TestRecord -Actual $Result[$i] -Expected $Expected[$i]
            }
        }
    }
}
