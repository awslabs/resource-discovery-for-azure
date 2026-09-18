# VM Placement CSV: capacity-planning view joining $Global:SmaResources against the Resource Graph payload ($Global:Resources), the only source of 'zones' and data-disk profile.
# A SEPARATE CSV touching no existing output, so the Inventory/Metrics JSON ingestion schema contract is unchanged and no schema approval is needed; makes no extra Azure calls.

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

# Numeric-column normaliser: returns $null (an EMPTY cell) for anything not a usable number so a column never goes mixed-type (Excel SUM skips it / pandas coerces to object = wrong total, not a visible gap). Parses InvariantCulture on purpose - a current-culture TryParse reads '3.5' as 35 on a de-DE/fr-FR/nl-NL host.
# -AllowZero omitted: 0 means "unavailable" (no real VM size has 0 vCPU/RAM, so a 0 is the collectors' SKU-lookup fallback). -AllowZero present: 0 is legitimate (a VM can have zero data disks). A function with one typed return, not a scriptblock, so a stray expression cannot leak an array into a cell.
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
    # Distinguish the two empty causes, fail-loud: CreateResourceJobs' circuit breaker sets $Result=@() when a collector THREW, so "no rows" can mean "collection failed". Ask the Resource Graph payload - resources present there but absent here means a collector failed (Error), not a genuinely empty subscription (Info). Both types checked so a VMSS-only failure is not silent.
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

# Build the placement map from the Resource Graph payload, keyed by the id the
# collector's OUTPUT record carries (see the header note on the join). A VM whose
# real id is absent from the dictionary during an obfuscated run is skipped rather
# than guessed at, and shows up as an unmatched row below.
$Obfuscating = ($null -ne $Global:ResourceIdDictionary -and $Global:ResourceIdDictionary.Count -gt 0)
$PlacementByOutputId = @{}

# Both types are mapped in ONE pass: their ARG rows carry 'zones' and a
# storageProfile in the same shape (the scale set's under virtualMachineProfile),
# so the join and the zone/data-disk extraction are identical for each.
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

    # 'zones' is an array on the ARG row. A VM is pinned to at most one zone, but
    # join and sort it anyway so a multi-valued payload renders deterministically
    # instead of as a PowerShell type name.
    $ZoneList = @($Vm.zones | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $Zone = if ($ZoneList.Count -gt 0) { (($ZoneList | Sort-Object) -join ',') } else { 'Regional' }

    # A plain VM keeps its storage profile at properties.storageProfile; a scale set
    # keeps the template one level deeper, at
    # properties.virtualMachineProfile.storageProfile. Take whichever is present so
    # one extraction serves both, rather than duplicating the loop per type.
    $StorageProfile = if ($null -ne $Vm.PROPERTIES.virtualMachineProfile) { $Vm.PROPERTIES.virtualMachineProfile.storageProfile } else { $Vm.PROPERTIES.storageProfile }

    $DataDisks = @($StorageProfile.dataDisks)
    $DataDiskGb = 0
    foreach ($Disk in $DataDisks)
    {
        $Size = 0
        if ([int]::TryParse([string]$Disk.diskSizeGB, [ref]$Size)) { $DataDiskGb += $Size }
    }

    # orchestrationMode decides whether a scale set's capacity may be counted from
    # its Instances at all - see the DOUBLE-COUNTING note in the header. Absent on a
    # plain VM row, and on older scale sets that predate the property (those behave
    # as Uniform).
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
# Flexible-orchestration scale sets whose Instances cell is deliberately left EMPTY
# by the double-counting guard below. Initialised HERE, with the other counters,
# because it was previously incremented without ever being declared: under no
# StrictMode '$null++' silently becomes 1, so the count was wrong AND unreported.
$FlexibleCount = 0
# Scale sets whose Instances cell is left EMPTY because a join miss left their
# orchestration mode UNKNOWN, so counting instances could double-count a Flexible
# set whose members were already emitted as VM rows (see the guard below).
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

    # Zone keeps its 'Unknown' sentinel because it is categorical - an empty cell
    # there would read as "this VM is not zonal", a claim we cannot make. Every
    # NUMERIC column instead goes empty when unavailable, so the column stays
    # summable. See the EMPTY VS ZERO note in the header.
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
        # The VM collector already computes the obfuscated id of the scale set this
        # VM belongs to ('Set'), populated only for a scale-set member. Carrying it
        # is what lets a planner attribute Flexible-orchestration VM rows to their
        # parent, which is the other half of the double-counting fix below.
        'ParentScaleSet'    = $Vm.Set
        'AksCluster'        = $null
    }
}

# Scale-set rows: a scale set is real zone capacity like a VM, so include it; CPU/MemoryGB stay PER INSTANCE with Instances the multiplier, keeping SUM(CPU * Instances) uniform across both row kinds.
# PowerState/AvailabilitySet left EMPTY (a scale set has no single power state and cannot be in an availability set) rather than filled with a placeholder.
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

    # DOUBLE-COUNTING GUARD: leave Instances EMPTY for a Flexible set - its members are first-class microsoft.compute/virtualmachines already emitted as VM rows above, so counting them again overstates a Flexible estate up to 2x. The row stays visible for SKU/zone. Uniform members are the child ARM type, never matched by the VM filter, so Instances is their only representation.
    # A join miss is UNKNOWN, not Uniform ($Placement null -> $Orchestration '' -> $IsFlexible false), so count Instances ONLY when matched AND not Flexible; trusting the empty default would re-open the double-count for a set that might really be Flexible.
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
        # Already obfuscated by the VMSS collector. Carrying it lets a planner
        # exclude Kubernetes-managed capacity, which the report's AKS section also
        # reports as NodeSize/Nodes - so without this column the two sources cannot
        # be reconciled and AKS nodes get counted twice across the bundle.
        'AksCluster'        = $Ss.AKS
    }
}

$Rows | Export-Csv -LiteralPath $CsvFile -Encoding utf8 -NoTypeInformation

# State the zero explicitly and name the scope, so a caller never has to re-run to
# find out whether an empty result meant "no zonal VMs" or "the phase did nothing".
# Both row kinds are counted separately, and the instance total is reported because
# a scale-set row represents many instances - "3 rows" alone would understate it.
$ZonalCount = @($Rows | Where-Object { $_.Zone -ne 'Regional' -and $_.Zone -ne 'Unknown' }).Count
$RegionalCount = @($Rows | Where-Object { $_.Zone -eq 'Regional' }).Count
$VmRowCount = @($Rows | Where-Object { $_.ResourceKind -eq 'VirtualMachine' }).Count
$SsRowCount = @($Rows | Where-Object { $_.ResourceKind -eq 'VirtualMachineScaleSet' }).Count
$InstanceTotal = 0
foreach ($Row in $Rows) { if ($null -ne $Row.Instances) { $InstanceTotal += [int]$Row.Instances } }

Write-Log -Message ("VM placement CSV written: {0} row(s) = {1} VM(s) + {2} scale set(s); {3} zonal, {4} regional; {5} total instance(s)." -f $Rows.Count, $VmRowCount, $SsRowCount, $ZonalCount, $RegionalCount, $InstanceTotal) -Severity 'Success'

# Name any row whose capacity could not be determined. A blank CPU/MemoryGB is the
# honest representation in the file, but it must not pass silently: it means the
# collector's SKU lookup failed, so a capacity total built from this file will be
# short by exactly these rows.
$NoCapacityRows = @($Rows | Where-Object { $null -eq $_.CPU -or $null -eq $_.MemoryGB })
if ($NoCapacityRows.Count -gt 0)
{
    Write-Log -Message ("VM placement CSV: {0} of {1} row(s) have no vCPU/RAM figure (SKU lookup unavailable); their CPU and MemoryGB cells are EMPTY, so any capacity total from this file excludes them." -f $NoCapacityRows.Count, $Rows.Count) -Severity 'Warning' -ToDebugLog
}

if ($Unmatched -gt 0)
{
    # Loud, not silent: an unmatched row means the placement map and the collector
    # output disagreed, which is a real defect rather than a property of the estate.
    Write-Log -Message ("VM placement CSV: {0} row(s) (VM or scale set) could not be matched to the Resource Graph payload; their Zone reads 'Unknown' and their data-disk cells are EMPTY." -f $Unmatched) -Severity 'Error' -ToDebugLog
}

# Name the Flexible-set count in a Warning: without it the ONE fact a capacity planner needs - that some scale-set rows contribute nothing to SUM(CPU * Instances) by design - is left to be inferred from an empty cell and misread as a shortfall or SKU-lookup failure.
if ($FlexibleCount -gt 0)
{
    Write-Log -Message ("VM placement CSV: {0} Flexible-orchestration scale set(s) have an EMPTY Instances cell BY DESIGN - their member VMs are first-class resources and are already counted as individual VirtualMachine rows, so counting the set's instances too would double-count that capacity. The rows remain visible for SKU and zone, and their ParentScaleSet column links the member VMs back to them." -f $FlexibleCount) -Severity 'Warning' -ToDebugLog
}

# Name the unknown-orchestration count: an unmatched scale set has UNKNOWN orchestration, so its Instances stay EMPTY (were it Flexible, its members were already emitted as VM rows and counting the set too would double-count) - report why SUM(CPU * Instances) excludes it rather than leaving it inferred.
if ($UnknownOrchestrationCount -gt 0)
{
    Write-Log -Message ("VM placement CSV: {0} scale set(s) could not be matched to the Resource Graph payload, so their orchestration mode is UNKNOWN and their Instances cell is left EMPTY - counting instances for a set that might be Flexible would double-count member VMs already emitted as individual rows. SUM(CPU * Instances) therefore excludes these set(s)." -f $UnknownOrchestrationCount) -Severity 'Warning' -ToDebugLog
}
