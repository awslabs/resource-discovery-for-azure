
param(
    [Parameter(Mandatory = $true)][string]$CsvFile
)

if ($null -eq $Global:SmaResources)
{
    Write-Log -Message ('VM placement CSV skipped: no collector output in this run.') -Severity 'Info'
    return
}

$HasVmKey = ($null -ne $Global:SmaResources.PSObject.Properties['VirtualMachines'])
$HasVmssKey = ($null -ne $Global:SmaResources.PSObject.Properties['VMSS'])

if (-not $HasVmKey -and -not $HasVmssKey)
{
    Write-Log -Message ('VM placement CSV skipped: neither the VirtualMachines nor the VMSS collector produced output in this run.') -Severity 'Info'
    return
}

$Vms = if ($HasVmKey) { @($Global:SmaResources.VirtualMachines) } else { @() }
$ScaleSets = if ($HasVmssKey) { @($Global:SmaResources.VMSS) } else { @() }

function Get-PlacementNumber
{
    param(
        $Value,
        [switch]$AllowZero
    )

    if ($null -eq $Value) { return $null }
    $Text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }

    $Parsed = 0.0
    $Ok = [double]::TryParse(
        $Text,
        [System.Globalization.NumberStyles]::Float,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [ref]$Parsed)

    if (-not $Ok) { return $null }
    if ($AllowZero.IsPresent) { if ($Parsed -lt 0) { return $null } }
    else { if ($Parsed -le 0) { return $null } }
    return $Parsed
}

if ($Vms.Count -eq 0 -and $ScaleSets.Count -eq 0)
{
    $GraphVmCount = @($Global:Resources | Where-Object { $_.TYPE -eq 'microsoft.compute/virtualmachines' }).Count
    $GraphVmssCount = @($Global:Resources | Where-Object { $_.TYPE -eq 'microsoft.compute/virtualmachinescalesets' }).Count

    if ($GraphVmCount -gt 0 -or $GraphVmssCount -gt 0)
    {
        Write-Log -Message ("VM placement CSV NOT written: the VirtualMachines and VMSS collectors returned no rows, but Resource Graph reports {0} VM(s) and {1} scale set(s) in this subscription. A collector very likely failed - check the collector failures above." -f $GraphVmCount, $GraphVmssCount) -Severity 'Error' -ToDebugLog
    }
    else
    {
        Write-Log -Message ('VM placement CSV skipped: this subscription has no virtual machines or scale sets (confirmed against the Resource Graph payload).') -Severity 'Info'
    }

    return
}

$Obfuscating = ($null -ne $Global:ResourceIdDictionary -and $Global:ResourceIdDictionary.Count -gt 0)
$PlacementByOutputId = @{}

foreach ($Vm in @($Global:Resources | Where-Object { $_.TYPE -eq 'microsoft.compute/virtualmachines' -or $_.TYPE -eq 'microsoft.compute/virtualmachinescalesets' }))
{
    $RealId = [string]$Vm.id
    if ([string]::IsNullOrEmpty($RealId)) { continue }

    $OutputId = if ($Obfuscating)
    {
        if ($Global:ResourceIdDictionary.ContainsKey($RealId)) { $Global:ResourceIdDictionary[$RealId] } else { $null }
    }
    else
    {
        $RealId
    }

    if ([string]::IsNullOrEmpty($OutputId) -or $PlacementByOutputId.ContainsKey($OutputId)) { continue }

    $ZoneList = @($Vm.zones | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $Zone = if ($ZoneList.Count -gt 0) { (($ZoneList | Sort-Object) -join ',') } else { 'Regional' }

    $StorageProfile = if ($null -ne $Vm.PROPERTIES.virtualMachineProfile) { $Vm.PROPERTIES.virtualMachineProfile.storageProfile } else { $Vm.PROPERTIES.storageProfile }

    $DataDisks = @($StorageProfile.dataDisks)
    $DataDiskGb = 0
    foreach ($Disk in $DataDisks)
    {
        $Size = 0
        if ([int]::TryParse([string]$Disk.diskSizeGB, [ref]$Size)) { $DataDiskGb += $Size }
    }

    $Orchestration = [string]$Vm.PROPERTIES.orchestrationMode

    $PlacementByOutputId[$OutputId] = [PSCustomObject]@{
        Zone              = $Zone
        DataDiskCount     = $DataDisks.Count
        DataDiskTotalGB   = $DataDiskGb
        OrchestrationMode = $Orchestration
    }
}

$Rows = @()
$Unmatched = 0
$FlexibleCount = 0
$UnknownOrchestrationCount = 0

foreach ($Vm in $Vms)
{
    if ($null -eq $Vm) { continue }

    $Placement = $null
    $VmId = [string]$Vm.ID
    if (-not [string]::IsNullOrEmpty($VmId) -and $PlacementByOutputId.ContainsKey($VmId))
    {
        $Placement = $PlacementByOutputId[$VmId]
    }
    else
    {
        $Unmatched++
    }

    $Rows += [PSCustomObject]@{
        'ResourceKind'      = 'VirtualMachine'
        'Subscription'      = $Vm.Subscription
        'ResourceGroup'     = $Vm.ResourceGroup
        'Name'              = $Vm.Name
        'Location'          = $Vm.Location
        'Zone'              = if ($null -ne $Placement) { $Placement.Zone } else { 'Unknown' }
        'Size'              = $Vm.Size
        'Instances'         = 1
        'CPU'               = (Get-PlacementNumber -Value $Vm.CPU)
        'MemoryGB'          = (Get-PlacementNumber -Value $Vm.Memory)
        'PowerState'        = $Vm.PowerState
        'AvailabilitySet'   = $Vm.AvailabilitySet
        'OSType'            = $Vm.OSType
        'OSName'            = $Vm.OSName
        'OSVersion'         = $Vm.OSVersion
        'OSDiskSKU'         = $Vm.OSDisk
        'OSDiskSizeGB'      = (Get-PlacementNumber -Value $Vm.OSDiskSizeGB -AllowZero)
        'DataDiskCount'     = if ($null -ne $Placement) { (Get-PlacementNumber -Value $Placement.DataDiskCount -AllowZero) } else { $null }
        'DataDiskTotalGB'   = if ($null -ne $Placement) { (Get-PlacementNumber -Value $Placement.DataDiskTotalGB -AllowZero) } else { $null }
        'OrchestrationMode' = $null
        'ParentScaleSet'    = $Vm.Set
        'AksCluster'        = $null
    }
}

foreach ($Ss in $ScaleSets)
{
    if ($null -eq $Ss) { continue }

    $Placement = $null
    $SsId = [string]$Ss.ID
    if (-not [string]::IsNullOrEmpty($SsId) -and $PlacementByOutputId.ContainsKey($SsId))
    {
        $Placement = $PlacementByOutputId[$SsId]
    }
    else
    {
        $Unmatched++
    }

    $Orchestration = if ($null -ne $Placement) { [string]$Placement.OrchestrationMode } else { '' }
    $IsFlexible = ($Orchestration -eq 'Flexible')
    if ($IsFlexible) { $FlexibleCount++ }

    $InstanceValue = if ($null -ne $Placement -and -not $IsFlexible) { (Get-PlacementNumber -Value $Ss.Instances -AllowZero) } else { $null }
    if ($null -eq $Placement) { $UnknownOrchestrationCount++ }

    $Rows += [PSCustomObject]@{
        'ResourceKind'      = 'VirtualMachineScaleSet'
        'Subscription'      = $Ss.Subscription
        'ResourceGroup'     = $Ss.ResourceGroup
        'Name'              = $Ss.Name
        'Location'          = $Ss.Location
        'Zone'              = if ($null -ne $Placement) { $Placement.Zone } else { 'Unknown' }
        'Size'              = $Ss.VMSize
        'Instances'         = $InstanceValue
        'CPU'               = (Get-PlacementNumber -Value $Ss.vCPUs)
        'MemoryGB'          = (Get-PlacementNumber -Value $Ss.RAM)
        'PowerState'        = $null
        'AvailabilitySet'   = $null
        'OSType'            = $Ss.VMOS
        'OSName'            = $Ss.OSImage
        'OSVersion'         = $Ss.ImageVersion
        'OSDiskSKU'         = $Ss.StorageAccountType
        'OSDiskSizeGB'      = (Get-PlacementNumber -Value $Ss.DiskSizeGB -AllowZero)
        'DataDiskCount'     = if ($null -ne $Placement) { (Get-PlacementNumber -Value $Placement.DataDiskCount -AllowZero) } else { $null }
        'DataDiskTotalGB'   = if ($null -ne $Placement) { (Get-PlacementNumber -Value $Placement.DataDiskTotalGB -AllowZero) } else { $null }
        'OrchestrationMode' = if ([string]::IsNullOrWhiteSpace($Orchestration)) { $null } else { $Orchestration }
        'ParentScaleSet'    = $null
        'AksCluster'        = $Ss.AKS
    }
}

$Rows | Export-Csv -LiteralPath $CsvFile -Encoding utf8 -NoTypeInformation

$ZonalCount = @($Rows | Where-Object { $_.Zone -ne 'Regional' -and $_.Zone -ne 'Unknown' }).Count
$RegionalCount = @($Rows | Where-Object { $_.Zone -eq 'Regional' }).Count
$VmRowCount = @($Rows | Where-Object { $_.ResourceKind -eq 'VirtualMachine' }).Count
$SsRowCount = @($Rows | Where-Object { $_.ResourceKind -eq 'VirtualMachineScaleSet' }).Count
$InstanceTotal = 0
foreach ($Row in $Rows) { if ($null -ne $Row.Instances) { $InstanceTotal += [int]$Row.Instances } }

Write-Log -Message ("VM placement CSV written: {0} row(s) = {1} VM(s) + {2} scale set(s); {3} zonal, {4} regional; {5} total instance(s)." -f $Rows.Count, $VmRowCount, $SsRowCount, $ZonalCount, $RegionalCount, $InstanceTotal) -Severity 'Success'

$NoCapacityRows = @($Rows | Where-Object { $null -eq $_.CPU -or $null -eq $_.MemoryGB })
if ($NoCapacityRows.Count -gt 0)
{
    Write-Log -Message ("VM placement CSV: {0} of {1} row(s) have no vCPU/RAM figure (SKU lookup unavailable); their CPU and MemoryGB cells are EMPTY, so any capacity total from this file excludes them." -f $NoCapacityRows.Count, $Rows.Count) -Severity 'Warning' -ToDebugLog
}

if ($Unmatched -gt 0)
{
    Write-Log -Message ("VM placement CSV: {0} row(s) (VM or scale set) could not be matched to the Resource Graph payload; their Zone reads 'Unknown' and their data-disk cells are EMPTY." -f $Unmatched) -Severity 'Error' -ToDebugLog
}

if ($FlexibleCount -gt 0)
{
    Write-Log -Message ("VM placement CSV: {0} Flexible-orchestration scale set(s) have an EMPTY Instances cell BY DESIGN - their member VMs are first-class resources and are already counted as individual VirtualMachine rows, so counting the set's instances too would double-count that capacity. The rows remain visible for SKU and zone, and their ParentScaleSet column links the member VMs back to them." -f $FlexibleCount) -Severity 'Warning' -ToDebugLog
}

if ($UnknownOrchestrationCount -gt 0)
{
    Write-Log -Message ("VM placement CSV: {0} scale set(s) could not be matched to the Resource Graph payload, so their orchestration mode is UNKNOWN and their Instances cell is left EMPTY - counting instances for a set that might be Flexible would double-count member VMs already emitted as individual rows. SUM(CPU * Instances) therefore excludes these set(s)." -f $UnknownOrchestrationCount) -Severity 'Warning' -ToDebugLog
}

