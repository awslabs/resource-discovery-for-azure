# =============================================================================
# VM Placement CSV - capacity-planning view of virtual machine placement
# =============================================================================
# WHY THIS EXISTS
#
# Capacity planning needs to know WHICH Availability Zone each VM sits in, not
# just whether it is zonal. The VM collector deliberately does NOT carry the zone
# identity: Services/Compute/VirtualMachines.ps1 emits 'Zones' = $vm.zones.count,
# a 0/1 flag, and adding a zone field to that object would change the
# Inventory_*.json field set that server ingestion binds on (see
# .kiro/steering/no-json-schema-changes.md).
#
# This phase sidesteps that entirely. It writes a SEPARATE CSV and touches no
# existing output, so the ingestion contract is unchanged and no schema approval
# is required. The Inventory JSON, the Metrics JSON, the Consumption CSV and the
# HTML report are all byte-for-byte unaffected by this file.
#
# WHERE THE DATA COMES FROM (no additional Azure calls)
#
#   $Global:SmaResources.VirtualMachines - everything the VM collector already
#       computed: Size, CPU, Memory, PowerState, AvailabilitySet, OS fields and
#       the OS disk. Reused rather than recomputed specifically so this phase does
#       NOT repeat the collector's Get-AzComputeResourceSku lookups, which would
#       double that API cost for no new information.
#
#   $Global:Resources - the Azure Resource Graph payload, which is the ONLY place
#       the zone lives ('zones') along with the data-disk profile.
#
# THE JOIN, AND WHY IT IS KEYED THE WAY IT IS
#
# ResourceInventory.ps1's CreateResourceJobs applies obfuscation to each
# collector's output as soon as the collector returns, BEFORE storing it on
# $Global:SmaResources. So under -Obfuscate those records carry OBFUSCATED ids,
# while $Global:Resources still carries REAL ids. Joining the two on id directly
# would match nothing in an obfuscated run - and would do so silently, producing
# a CSV with every Zone blank exactly in the mode that gets shared.
#
# The zone map is therefore keyed by the id the OUTPUT record will carry: the
# real id normally, or its token from $Global:ResourceIdDictionary when
# obfuscating. That reuses the run's existing deterministic mapping instead of
# introducing a second one.
#
# OBFUSCATION POSTURE
#
# Every identifier column is taken from $Global:SmaResources, which is already
# obfuscated when -Obfuscate is set, so this file inherits the run's posture and
# adds no new identifier class. Location and Zone are preserved verbatim, exactly
# as Location already is throughout the report: an Azure region and a zone number
# (1-3) are not customer identifiers, and masking them would defeat the purpose of
# a placement file.
#
# WHAT IS COUNTED, AND HOW TO TOTAL IT
#
# One row per virtual machine AND one row per virtual machine SCALE SET. A scale
# set is real capacity sitting in a real zone, so omitting it would understate the
# estate with nothing in the file to signal the gap. ResourceKind distinguishes
# the two.
#
# CPU and MemoryGB are PER INSTANCE for both kinds, and Instances is the
# multiplier (always 1 for a plain VM, sku.capacity for a scale set). So the
# correct total across the whole file is:
#
#     SUM(CPU * Instances)  and  SUM(MemoryGB * Instances)
#
# That works uniformly over both row kinds rather than needing the consumer to
# special-case scale sets.
#
# EMPTY VS ZERO IN NUMERIC COLUMNS
#
# Numeric columns are left EMPTY when the value is genuinely unavailable, never
# filled with a placeholder word or a misleading 0. Two reasons, both learned the
# hard way:
#
#   - A word like 'Unknown' in a numeric column makes the column mixed-type. Excel
#     SUM() silently skips it and pandas coerces the column to object, so a file
#     whose entire purpose is totalling capacity produces a wrong total instead of
#     an obviously missing one.
#   - The VM and VMSS collectors both fall back to 0 vCPUs/RAM when the
#     Get-AzComputeResourceSku lookup fails (see the catch in Services/Compute/
#     VirtualMachines.ps1 and Services/Containers/VMSS.ps1, and the coverage in
#     Tests/CollectorGuards.Tests.ps1). No real VM size has 0 vCPUs or 0 GB RAM, so
#     0 there means "lookup failed", and reporting it as 0 understates capacity
#     silently. It is emitted as empty instead.
#
# Zone is the ONE column that keeps a categorical sentinel, because it is
# categorical rather than numeric: 'Regional' (not zonal) and 'Unknown' (the join
# found nothing) are different facts, and an empty cell would read as "not zonal",
# which is a claim we cannot make.
# =============================================================================

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

# Numeric-column normaliser. Returns $null (an EMPTY csv cell) for anything that is
# not a usable number, so a mixed-type column can never reach the file.
#
# -AllowZero distinguishes the two cases:
#   omitted : 0 means "unavailable". Used for vCPU/RAM, because no real VM size has
#             0 of either, so a 0 there is the collectors' SKU-lookup fallback
#             rather than a fact (see the EMPTY VS ZERO note in the header).
#   present : 0 is a legitimate value. Used for counts and sizes, because a VM
#             genuinely can have zero data disks.
#
# Parsing is INVARIANT-culture on purpose. [double]::TryParse(string, [ref]double)
# uses the CURRENT culture, where '.' is a group separator on a de-DE / fr-FR /
# nl-NL host - so an invariantly-rendered '3.5' GB would parse as 35 and write a
# MemoryGB ten times too large. That is a wrong total rather than a missing one,
# which is the specific outcome this whole normaliser exists to prevent.
#
# A real function rather than a scriptblock: a scriptblock returns its entire
# pipeline, so a future edit that drops a 'return' or leaves a stray expression
# would silently emit an array into a numeric cell and reintroduce the mixed-type
# column. A function with a single typed return path cannot drift that way.
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
    # An empty collector result has TWO very different causes and they must not
    # report identically. CreateResourceJobs' circuit breaker sets $Result = @()
    # when a collector THREW, so "no rows" can mean "collection failed" as easily
    # as "this subscription genuinely has none". Ask the Resource Graph payload
    # which one it is: resources present there but absent from the collector
    # output means the collector failed, and that is an Error, not an Info.
    # Checked for BOTH types, so a VMSS-only collector failure is not silent.
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

# Scale-set rows. A scale set is capacity in a zone just as much as a VM is, so
# leaving it out understated the estate with nothing in the file to say so.
# CPU/MemoryGB stay PER INSTANCE, matching the VM rows, with Instances carrying the
# multiplier - so SUM(CPU * Instances) is correct over the whole file without the
# consumer special-casing anything.
#
# PowerState and AvailabilitySet are left EMPTY rather than filled with a
# placeholder: a scale set has no single power state (its instances each have one)
# and cannot be in an availability set. An empty cell is the honest answer.
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

    # THE DOUBLE-COUNTING GUARD. A Flexible scale set's members are first-class
    # microsoft.compute/virtualmachines resources, so they have ALREADY been emitted
    # as individual VirtualMachine rows above. Multiplying this row's per-instance
    # CPU by Instances would count that same capacity a second time and overstate a
    # Flexible estate by up to 2x - silently, in the exact total the header tells the
    # consumer to compute.
    #
    # So Instances is left EMPTY for a Flexible set: the row stays VISIBLE (the
    # planner can see the scale set exists, its SKU and its zones) but contributes
    # nothing to SUM(CPU * Instances), because its members already did. The count is
    # named in a Warning below rather than left to be inferred.
    #
    # Uniform sets are unaffected: their members are the CHILD ARM type
    # (.../virtualmachinescalesets/virtualmachines), never matched by the VM filter,
    # so Instances is the only place their capacity is represented.
    $InstanceValue = if ($IsFlexible) { $null } else { (Get-PlacementNumber -Value $Ss.Instances -AllowZero) }

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
