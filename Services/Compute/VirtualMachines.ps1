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
        $Tmp = @()

        foreach ($vm in $VirtualMachines)
        {
            $Sub1 = $SUB | Where-Object { $_.id -eq $vm.subscriptionId }
            $Data = $vm.PROPERTIES
            $Timecreated = if ($null -ne $Data.timeCreated) { [datetime]($Data.timeCreated) | Get-Date -Format "yyyy-MM-dd HH:mm" } else { 'Unknown' }

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
                $OSDisk = ($Disk | Where-Object { $_.id -eq $Data.storageProfile.osDisk.managedDisk.id } | Select-Object -Unique).sku.name
                $OSDiskSize = ($Disk | Where-Object { $_.id -eq $Data.storageProfile.osDisk.managedDisk.id } | Select-Object -Unique).Properties.diskSizeGB
            }
            else
            {
                $OSDisk = if ($Data.storageProfile.osDisk.vhd.uri) { 'Custom VHD' } else { 'None' }
                $OSDiskSize = $Data.storageProfile.osDisk.diskSizeGB
            }

            $Cpus = $Vmsizemap[$Data.hardwareProfile.vmSize].CPU;
            $Ram = $Vmsizemap[$Data.hardwareProfile.vmSize].RAM;

            $Cpus = if ($null -ne $Cpus) { $Cpus } else { '0' }
            $Ram = if ($null -ne $Ram) { $Ram } else { '0' }

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

            $Tmp += $Obj
        }

        $Tmp
    }
}
