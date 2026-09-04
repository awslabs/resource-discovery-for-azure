# VM Placement CSV Tests
#
# OFFLINE unit tests for Extension/VMPlacement.ps1 - the tenant-wide capacity
# planning CSV. No Azure calls: each test builds synthetic $Global:SmaResources
# (already-obfuscated collector output) plus a synthetic $Global:Resources
# (Resource Graph payload), invokes the REAL extension, and parses the CSV it
# wrote.
#
# WHY THESE ASSERTIONS EXIST
#
# The file's whole purpose is being summed by a capacity planner, which makes two
# failure modes far worse than a missing row:
#
#   1. A placeholder word in a numeric column. 'Unknown' in DataDiskCount makes the
#      column mixed-type; Excel SUM() silently skips it and pandas coerces the
#      column to object. The planner gets a WRONG total rather than an obviously
#      missing one. Every numeric column must therefore be a number or EMPTY.
#   2. A misleading 0. Both the VM and VMSS collectors fall back to 0 vCPUs/RAM
#      when Get-AzComputeResourceSku fails (see Tests/CollectorGuards.Tests.ps1).
#      No real SKU has 0 vCPU, so 0 there means "lookup failed" and reporting it as
#      0 understates capacity silently. It must render EMPTY.
#
# Scale sets are covered because they are real capacity in a real zone: omitting
# them understated the estate with nothing in the file to signal the gap.
#
# Run with: Invoke-Pester ./Tests/VMPlacementCsv.Tests.ps1 -Output Detailed

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $script:Extension = Join-Path $script:RepoRoot 'Extension/VMPlacement.ps1'
    if (-not (Test-Path -LiteralPath $script:Extension))
    {
        throw "Cannot find Extension/VMPlacement.ps1 at $script:Extension"
    }

    $TmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { '/tmp' }
    $script:WorkDir = Join-Path $TmpBase ('VMPlacementTest_' + [guid]::NewGuid().ToString().Substring(0, 8))
    New-Item -ItemType Directory -Path $script:WorkDir -Force | Out-Null

    # The extension calls Write-Log. Define a silent stand-in in THIS scope so the
    # tests exercise the real logic without needing the orchestrator's logging.
    function global:Write-Log
    {
        param([string]$Message, [string]$Severity, [switch]$ToDebugLog)
        $script:LogLines += ('[{0}] {1}' -f $Severity, $Message)
    }

    # Runs the extension against the supplied synthetic state and returns the parsed
    # CSV rows. Keeping this in one helper means every test exercises the same entry
    # path the orchestrator uses (a plain call with -CsvFile).
    function script:Invoke-Placement
    {
        param($Vms, $ScaleSets, $GraphRows, $Dictionary)

        $script:LogLines = @()
        $Csv = Join-Path $script:WorkDir ([guid]::NewGuid().ToString('N').Substring(0, 8) + '.csv')

        $Payload = @{}
        if ($null -ne $Vms) { $Payload['VirtualMachines'] = $Vms }
        if ($null -ne $ScaleSets) { $Payload['VMSS'] = $ScaleSets }

        $Global:SmaResources = [PSCustomObject]$Payload
        $Global:Resources = @($GraphRows)
        $Global:ResourceIdDictionary = $Dictionary

        & $script:Extension -CsvFile $Csv

        if (-not (Test-Path -LiteralPath $Csv)) { return $null }
        return @(Import-Csv -LiteralPath $Csv)
    }

    # --- fixture builders ----------------------------------------------------
    function script:New-VmRecord
    {
        param($Id, $Name, $Cpu = 2, $Memory = 8, $OsDiskGb = 30)
        [PSCustomObject]@{
            ID = $Id; Subscription = 'prod_sub'; ResourceGroup = 'prod_rg'; Name = $Name
            Location = 'westeurope'; Size = 'Standard_D2s_v5'; CPU = $Cpu; Memory = $Memory
            PowerState = 'VM running'; AvailabilitySet = ''; OSType = 'Linux'
            OSName = 'Ubuntu'; OSVersion = '22.04'; OSDisk = 'Premium_LRS'; OSDiskSizeGB = $OsDiskGb
        }
    }

    function script:New-VmssRecord
    {
        param($Id, $Name, $Instances = 3, $Cpu = 4, $Ram = 16)
        # Hashtable, matching what Services/Containers/VMSS.ps1 actually emits.
        @{
            ID = $Id; Subscription = 'prod_sub'; ResourceGroup = 'prod_rg'; Name = $Name
            Location = 'westeurope'; VMSize = 'Standard_D4s_v5'; Instances = $Instances
            vCPUs = $Cpu; RAM = $Ram; VMOS = 'Linux'; OSImage = 'ubuntu'
            ImageVersion = '22_04-lts'; StorageAccountType = 'Premium_LRS'; DiskSizeGB = 64
        }
    }

    function script:New-GraphVm
    {
        param($Id, $Zones = @('1'), $DataDiskSizes = @())
        [PSCustomObject]@{
            TYPE = 'microsoft.compute/virtualmachines'; id = $Id; zones = $Zones
            PROPERTIES = [PSCustomObject]@{
                storageProfile = [PSCustomObject]@{
                    dataDisks = @($DataDiskSizes | ForEach-Object { [PSCustomObject]@{ diskSizeGB = $_ } })
                }
            }
        }
    }

    function script:New-GraphVmss
    {
        param($Id, $Zones = @('1', '2'), $DataDiskSizes = @())
        # A scale set nests its storage profile one level deeper, under
        # virtualMachineProfile. That difference is the thing worth testing.
        [PSCustomObject]@{
            TYPE = 'microsoft.compute/virtualmachinescalesets'; id = $Id; zones = $Zones
            PROPERTIES = [PSCustomObject]@{
                virtualMachineProfile = [PSCustomObject]@{
                    storageProfile = [PSCustomObject]@{
                        dataDisks = @($DataDiskSizes | ForEach-Object { [PSCustomObject]@{ diskSizeGB = $_ } })
                    }
                }
            }
        }
    }
}

AfterAll {
    if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir))
    {
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-Item function:global:Write-Log -ErrorAction SilentlyContinue
    $Global:SmaResources = $null
    $Global:Resources = $null
    $Global:ResourceIdDictionary = $null
}

Describe 'VM placement CSV' {

    Context 'Schema' {

        It 'emits the documented 22 columns in order' {
            $Rows = script:Invoke-Placement -Vms @(script:New-VmRecord -Id 'v1' -Name 'prod_vm1') `
                -ScaleSets $null -GraphRows @(script:New-GraphVm -Id 'v1') -Dictionary $null

            # This list IS the VMPlacement.csv column contract: the emitter builds an
            # ordered hashtable and Export-Csv takes the header from it, so a change
            # here changes the shipped file for every consumer.
            #
            # The last three complete the capacity picture and are not optional:
            #   OrchestrationMode - Flexible vs Uniform, set on scale-set rows.
            #   ParentScaleSet    - attributes a Flexible-orchestration VM row to its
            #                       scale set.
            #   AksCluster        - marks Kubernetes-managed capacity.
            # The last two exist specifically to stop double-counting: the report's
            # AKS section reports the same nodes as NodeSize/Nodes, and a Flexible
            # VMSS reports both the set and its member VMs, so without these two a
            # planner counts that capacity twice. See the rationale comments at
            # Extension/VMPlacement.ps1 around the 'ParentScaleSet' and 'AksCluster'
            # assignments.
            $Expected = @(
                'ResourceKind', 'Subscription', 'ResourceGroup', 'Name', 'Location', 'Zone',
                'Size', 'Instances', 'CPU', 'MemoryGB', 'PowerState', 'AvailabilitySet',
                'OSType', 'OSName', 'OSVersion', 'OSDiskSKU', 'OSDiskSizeGB',
                'DataDiskCount', 'DataDiskTotalGB',
                'OrchestrationMode', 'ParentScaleSet', 'AksCluster'
            )
            @($Rows[0].PSObject.Properties.Name) | Should -Be $Expected
        }
    }

    Context 'Virtual machine rows' {

        It 'records the zone and sums data disk sizes' {
            $Rows = script:Invoke-Placement -Vms @(script:New-VmRecord -Id 'v1' -Name 'prod_vm1') `
                -ScaleSets $null `
                -GraphRows @(script:New-GraphVm -Id 'v1' -Zones @('1') -DataDiskSizes @(128, 256)) `
                -Dictionary $null

            $Rows.Count | Should -Be 1
            $Rows[0].ResourceKind | Should -Be 'VirtualMachine'
            $Rows[0].Zone | Should -Be '1'
            $Rows[0].DataDiskCount | Should -Be '2'
            $Rows[0].DataDiskTotalGB | Should -Be '384'
        }

        It 'reports Instances as 1 so SUM(CPU * Instances) works uniformly' {
            $Rows = script:Invoke-Placement -Vms @(script:New-VmRecord -Id 'v1' -Name 'prod_vm1' -Cpu 2) `
                -ScaleSets $null -GraphRows @(script:New-GraphVm -Id 'v1') -Dictionary $null

            $Rows[0].Instances | Should -Be '1'
        }

        It 'marks a non-zonal VM Regional rather than leaving Zone blank' {
            # Blank would read as "not known"; Regional is a definite, different fact.
            $Rows = script:Invoke-Placement -Vms @(script:New-VmRecord -Id 'v1' -Name 'prod_vm1') `
                -ScaleSets $null -GraphRows @(script:New-GraphVm -Id 'v1' -Zones @()) -Dictionary $null

            $Rows[0].Zone | Should -Be 'Regional'
        }
    }

    Context 'Scale set rows' {

        It 'includes scale sets, since they are real capacity in a real zone' {
            $Rows = script:Invoke-Placement -Vms $null `
                -ScaleSets @(script:New-VmssRecord -Id 's1' -Name 'prod_ss1' -Instances 3) `
                -GraphRows @(script:New-GraphVmss -Id 's1') -Dictionary $null

            $Rows.Count | Should -Be 1
            $Rows[0].ResourceKind | Should -Be 'VirtualMachineScaleSet'
            $Rows[0].Instances | Should -Be '3'
        }

        It 'keeps CPU per-instance so the Instances multiplier is not double counted' {
            $Rows = script:Invoke-Placement -Vms $null `
                -ScaleSets @(script:New-VmssRecord -Id 's1' -Name 'prod_ss1' -Instances 3 -Cpu 4) `
                -GraphRows @(script:New-GraphVmss -Id 's1') -Dictionary $null

            # 4 per instance, NOT 12. The consumer multiplies.
            $Rows[0].CPU | Should -Be '4'
        }

        It 'reads the nested virtualMachineProfile storage profile' {
            $Rows = script:Invoke-Placement -Vms $null `
                -ScaleSets @(script:New-VmssRecord -Id 's1' -Name 'prod_ss1') `
                -GraphRows @(script:New-GraphVmss -Id 's1' -DataDiskSizes @(512)) -Dictionary $null

            $Rows[0].DataDiskCount | Should -Be '1'
            $Rows[0].DataDiskTotalGB | Should -Be '512'
        }

        It 'renders a multi-zone scale set as a sorted, comma-joined list' {
            $Rows = script:Invoke-Placement -Vms $null `
                -ScaleSets @(script:New-VmssRecord -Id 's1' -Name 'prod_ss1') `
                -GraphRows @(script:New-GraphVmss -Id 's1' -Zones @('2', '1')) -Dictionary $null

            $Rows[0].Zone | Should -Be '1,2'
        }

        It 'leaves PowerState and AvailabilitySet empty rather than inventing a value' {
            # A scale set has no single power state and cannot be in an availability set.
            $Rows = script:Invoke-Placement -Vms $null `
                -ScaleSets @(script:New-VmssRecord -Id 's1' -Name 'prod_ss1') `
                -GraphRows @(script:New-GraphVmss -Id 's1') -Dictionary $null

            $Rows[0].PowerState | Should -BeNullOrEmpty
            $Rows[0].AvailabilitySet | Should -BeNullOrEmpty
        }
    }

    Context 'Numeric columns are summable (never a placeholder word)' {

        It 'leaves CPU and MemoryGB EMPTY when the SKU lookup failed (0), not 0' {
            # 0 vCPU is not a real SKU, so 0 means the collector's lookup fell back.
            # Emitting 0 would understate a capacity total silently.
            $Rows = script:Invoke-Placement -Vms @(script:New-VmRecord -Id 'v1' -Name 'prod_vm1' -Cpu 0 -Memory 0) `
                -ScaleSets $null -GraphRows @(script:New-GraphVm -Id 'v1') -Dictionary $null

            $Rows[0].CPU | Should -BeNullOrEmpty
            $Rows[0].MemoryGB | Should -BeNullOrEmpty
        }

        It 'leaves scale-set CPU and MemoryGB EMPTY for the string 0 fallback too' {
            # Services/Containers/VMSS.ps1 falls back to the STRING '0', not the int.
            $Rows = script:Invoke-Placement -Vms $null `
                -ScaleSets @(script:New-VmssRecord -Id 's1' -Name 'prod_ss1' -Cpu '0' -Ram '0') `
                -GraphRows @(script:New-GraphVmss -Id 's1') -Dictionary $null

            $Rows[0].CPU | Should -BeNullOrEmpty
            $Rows[0].MemoryGB | Should -BeNullOrEmpty
        }

        It 'leaves disk columns EMPTY on a join miss instead of writing Unknown' {
            # THE regression guard. A word here makes the column mixed-type and breaks
            # SUM() in every consumer.
            $Rows = script:Invoke-Placement -Vms @(script:New-VmRecord -Id 'orphan' -Name 'prod_vm1') `
                -ScaleSets $null -GraphRows @() -Dictionary $null

            $Rows[0].DataDiskCount | Should -BeNullOrEmpty
            $Rows[0].DataDiskTotalGB | Should -BeNullOrEmpty
        }

        It 'never writes the word Unknown into any numeric column' {
            $Rows = script:Invoke-Placement `
                -Vms @(script:New-VmRecord -Id 'orphan' -Name 'prod_vm1' -Cpu 0 -Memory 0) `
                -ScaleSets @(script:New-VmssRecord -Id 'orphan-ss' -Name 'prod_ss1' -Cpu '0' -Ram '0') `
                -GraphRows @() -Dictionary $null

            foreach ($Row in $Rows)
            {
                foreach ($Col in @('Instances', 'CPU', 'MemoryGB', 'OSDiskSizeGB', 'DataDiskCount', 'DataDiskTotalGB'))
                {
                    $Row.$Col | Should -Not -Be 'Unknown' -Because "$Col must stay summable"
                }
            }
        }

        It 'keeps Unknown for Zone, which is categorical rather than numeric' {
            $Rows = script:Invoke-Placement -Vms @(script:New-VmRecord -Id 'orphan' -Name 'prod_vm1') `
                -ScaleSets $null -GraphRows @() -Dictionary $null

            $Rows[0].Zone | Should -Be 'Unknown'
        }

        It 'keeps a legitimate zero, distinguishing "none" from "unavailable"' {
            # A VM genuinely with no data disks must report 0, not empty.
            $Rows = script:Invoke-Placement -Vms @(script:New-VmRecord -Id 'v1' -Name 'prod_vm1') `
                -ScaleSets $null -GraphRows @(script:New-GraphVm -Id 'v1' -DataDiskSizes @()) -Dictionary $null

            $Rows[0].DataDiskCount | Should -Be '0'
            $Rows[0].DataDiskTotalGB | Should -Be '0'
        }
    }

    Context 'Mixed estate and totals' {

        It 'emits both kinds together and the instance total is summable' {
            $Rows = script:Invoke-Placement `
                -Vms @(script:New-VmRecord -Id 'v1' -Name 'prod_vm1' -Cpu 2) `
                -ScaleSets @(script:New-VmssRecord -Id 's1' -Name 'prod_ss1' -Instances 3 -Cpu 4) `
                -GraphRows @((script:New-GraphVm -Id 'v1'), (script:New-GraphVmss -Id 's1')) -Dictionary $null

            $Rows.Count | Should -Be 2

            # The documented total: SUM(CPU * Instances) = (2*1) + (4*3) = 14.
            $Total = 0
            foreach ($Row in $Rows) { $Total += ([int]$Row.CPU * [int]$Row.Instances) }
            $Total | Should -Be 14
        }
    }

    Context 'Obfuscated runs' {

        It 'joins on the obfuscated id so an -Obfuscate run still resolves the zone' {
            # Collector output is obfuscated before it reaches SmaResources, while the
            # Graph payload keeps real ids. The map must be keyed by the OUTPUT id or
            # every Zone silently goes Unknown in exactly the mode that gets shared.
            $Dict = @{ 'real-id-1' = 'prod_token_1' }
            $Rows = script:Invoke-Placement `
                -Vms @(script:New-VmRecord -Id 'prod_token_1' -Name 'prod_vm1') `
                -ScaleSets $null `
                -GraphRows @(script:New-GraphVm -Id 'real-id-1' -Zones @('3') -DataDiskSizes @(64)) `
                -Dictionary $Dict

            $Rows[0].Zone | Should -Be '3'
            $Rows[0].DataDiskTotalGB | Should -Be '64'
        }
    }

    Context 'Empty estate' {

        It 'writes no CSV when there are neither VMs nor scale sets' {
            $Rows = script:Invoke-Placement -Vms @() -ScaleSets @() -GraphRows @() -Dictionary $null
            $Rows | Should -BeNullOrEmpty
        }
    }
}
