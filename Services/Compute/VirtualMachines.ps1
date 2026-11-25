param($Sub, $Resources, $Task, $ResourceIdDictionary)

If ($Task -eq 'Processing')
{
    $VirtualMachines = $Resources | Where-Object { $_.TYPE -eq 'microsoft.compute/virtualmachines' }
    $Disk = $Resources | Where-Object { $_.TYPE -eq 'microsoft.compute/disks' }

    $Vmsizemap = @{}

    foreach ($location in ($VirtualMachines | Select-Object -ExpandProperty location -Unique))
    {
        $SavedDebugPref = $DebugPreference
        $DebugPreference = 'SilentlyContinue'
        $Skus = Get-AzComputeResourceSku -Location $location | Where-Object { $_.ResourceType -eq 'virtualMachines' }
        $DebugPreference = $SavedDebugPref

        foreach ($vmsize in $Skus)
        {
            $CpuCap = ($vmsize.Capabilities | Where-Object { $_.Name -eq 'vCPUs' }).Value
            $MemCap = ($vmsize.Capabilities | Where-Object { $_.Name -eq 'MemoryGB' }).Value
            if ($null -ne $CpuCap -and -not $Vmsizemap.ContainsKey($vmsize.Name))
            {
                $Vmsizemap[$vmsize.Name] = @{
                    CPU = [int]$CpuCap
                    RAM = [math]::Max([decimal]$MemCap, 0)
                }
            }
        }
    }

    if ($VirtualMachines)
    {
        # Index the disks by id once so each VM finds its OS disk with a lookup
        # instead of scanning every disk. Resource ids compare case-insensitively,
        # as the -eq this replaces did. A disk with no id can never match, so it
        # is left out; disks sharing an id stay together in input order.
        $DiskById = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[object]]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($DiskRow in $Disk)
        {
            if ($null -eq $DiskRow.id) { continue }
            $DiskKey = [string]$DiskRow.id
            if (-not $DiskById.ContainsKey($DiskKey))
            {
                $DiskById[$DiskKey] = [System.Collections.Generic.List[object]]::new()
            }
            $DiskById[$DiskKey].Add($DiskRow)
        }

        $Tmp = [System.Collections.Generic.List[object]]::new()

        foreach ($vm in $VirtualMachines)
        {
            $Sub1 = $SUB | Where-Object { $_.id -eq $vm.subscriptionId }
            $Data = $vm.PROPERTIES
            # A missing timeCreated, or one that does not convert to a date, is
            # 'Unknown' rather than an exception that fails every virtual machine.
            # A valid value is written in UTC on every host; one with no zone is taken as UTC.
            $Timecreated = try { if ($null -ne $Data.timeCreated) { [datetime]::Parse($Data.timeCreated, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]'AdjustToUniversal, AssumeUniversal') | Get-Date -Format "yyyy-MM-dd HH:mm" } else { 'Unknown' } } catch { 'Unknown' }

            $Lic = ''

            switch ($Data.licenseType)
            {
                'Windows_Server' { $Lic = 'AHUB for Windows' }
                'Windows_Client' { $Lic = 'Windows Client Multi-Tenant' }
                'RHEL_BYOS' { $Lic = 'AHUB for Redhat' }
                'SLES_BYOS' { $Lic = 'AHUB for SUSE' }
            }

            $Lic = if ($Lic) { $Lic } else { 'License Included' }

            if ($Data.storageProfile.osDisk.managedDisk.id)
            {
                $OSDiskRows = $null
                if ($DiskById.TryGetValue([string]$Data.storageProfile.osDisk.managedDisk.id, [ref]$OSDiskRows))
                {
                    $OSDisk = ($OSDiskRows | Select-Object -Unique).sku.name
                    $OSDiskSize = ($OSDiskRows | Select-Object -Unique).Properties.diskSizeGB
                }
                else
                {
                    $OSDisk = $null
                    $OSDiskSize = $null
                }
            }
            else
            {
                $OSDisk = if ($Data.storageProfile.osDisk.vhd.uri) { 'Custom VHD' } else { 'None' }
                $OSDiskSize = $Data.storageProfile.osDisk.diskSizeGB
            }

            # A size the size list for the region does not return (a retired size, for
            # example) leaves CPU and Memory empty rather than 0.
            $Cpus = $Vmsizemap[$Data.hardwareProfile.vmSize].CPU;
            $Ram = $Vmsizemap[$Data.hardwareProfile.vmSize].RAM;

            $PowerState = if ($null -ne $Data.extended.instanceView.powerState.displayStatus) { $Data.extended.instanceView.powerState.displayStatus } else { 'vm unknown' }

            $Tags = if (![string]::IsNullOrEmpty($vm.tags.psobject.properties)) { $vm.tags.psobject.properties | Select-Object Name, Value } else { $null }

            $ObfuscatedId = if (![string]::IsNullOrEmpty($Data.virtualMachineScaleSet.id)) { if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { if ($ResourceIdDictionary.ContainsKey($Data.virtualMachineScaleSet.id)) { $ResourceIdDictionary[$Data.virtualMachineScaleSet.id] } else { 'obfuscated' } } else { $Data.virtualMachineScaleSet.id } } else { $null }

            $Obj = @{
                'ID'                            = $vm.id;
                'Subscription'                  = $Sub1.Name;
                'ResourceGroup'                 = $vm.RESOURCEGROUP;
                'Name'                          = $vm.NAME;
                'Location'                      = $vm.LOCATION;
                'AvailabilitySet'               = if ($null -ne $Data.availabilitySet) { 'true' } else { 'false' }
                'Size'                          = $Data.hardwareProfile.vmSize;
                'CPU'                           = $Cpus;
                'Memory'                        = $Ram;
                'Set'                           = $ObfuscatedId;
                'ImageReference'                = $Data.storageProfile.imageReference.publisher;
                'ImageVersion'                  = $Data.storageProfile.imageReference.exactVersion;
                'ImageSku'                      = $Data.storageProfile.imageReference.sku;
                'ImageOffer'                    = $Data.storageProfile.imageReference.offer;
                'HybridBenefit'                 = $Lic;
                'OSName'                        = $Data.extended.instanceView.osname;
                'OSType'                        = $Data.storageProfile.osDisk.osType;
                'OSVersion'                     = $Data.extended.instanceView.osversion;
                'OSDisk'                        = $OSDisk;
                'OSDiskSizeGB'                  = $OSDiskSize;
                'PowerState'                    = $PowerState;
                'Zones'                         = $vm.zones.count;
                'CreatedTime'                   = $Timecreated;
                'Tags'                          = $Tags;
            }

            [void]$Tmp.Add($Obj)
        }

        $Tmp
    }
}
