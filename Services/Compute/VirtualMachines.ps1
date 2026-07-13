param($Sub, $Resources, $Task, $ResourceIdDictionary)

If ($Task -eq 'Processing')
{
    $virtualMachines = $Resources | Where-Object { $_.TYPE -eq 'microsoft.compute/virtualmachines' }
    $disk = $Resources | Where-Object { $_.TYPE -eq 'microsoft.compute/disks' }

    $vmsizemap = @{}

    foreach ($location in ($virtualMachines | Select-Object -ExpandProperty location -Unique))
    {
        $savedDebugPref = $DebugPreference
        $DebugPreference = 'SilentlyContinue'
        $skus = Get-AzComputeResourceSku -Location $location | Where-Object { $_.ResourceType -eq 'virtualMachines' }
        $DebugPreference = $savedDebugPref

        foreach ($vmsize in $skus)
        {
            $cpuCap = ($vmsize.Capabilities | Where-Object { $_.Name -eq 'vCPUs' }).Value
            $memCap = ($vmsize.Capabilities | Where-Object { $_.Name -eq 'MemoryGB' }).Value
            if ($null -ne $cpuCap -and -not $vmsizemap.ContainsKey($vmsize.Name))
            {
                $vmsizemap[$vmsize.Name] = @{
                    CPU = [int]$cpuCap
                    RAM = [math]::Max([decimal]$memCap, 0)
                }
            }
        }
    }

    if ($virtualMachines)
    {
        $tmp = @()

        foreach ($vm in $virtualMachines)
        {
            $sub1 = $SUB | Where-Object { $_.id -eq $vm.subscriptionId }
            $data = $vm.PROPERTIES
            $timecreated = if ($null -ne $data.timeCreated) { [datetime]($data.timeCreated) | Get-Date -Format "yyyy-MM-dd HH:mm" } else { 'Unknown' }

            $Lic = ''

            switch ($data.licenseType)
            {
                'Windows_Server' { $Lic = 'AHUB for Windows' }
                'Windows_Client' { $Lic = 'Windows Client Multi-Tenant' }
                'RHEL_BYOS' { $Lic = 'AHUB for Redhat' }
                'SLES_BYOS' { $Lic = 'AHUB for SUSE' }
            }

            $Lic = if ($Lic) { $Lic } else { 'License Included' }

            if ($data.storageProfile.osDisk.managedDisk.id)
            {
                $OSDisk = ($disk | Where-Object { $_.id -eq $data.storageProfile.osDisk.managedDisk.id } | Select-Object -Unique).sku.name
                $OSDiskSize = ($disk | Where-Object { $_.id -eq $data.storageProfile.osDisk.managedDisk.id } | Select-Object -Unique).Properties.diskSizeGB
            }
            else
            {
                $OSDisk = if ($data.storageProfile.osDisk.vhd.uri) { 'Custom VHD' } else { 'None' }
                $OSDiskSize = $data.storageProfile.osDisk.diskSizeGB
            }

            $cpus = $vmsizemap[$data.hardwareProfile.vmSize].CPU;
            $ram = $vmsizemap[$data.hardwareProfile.vmSize].RAM;

            $cpus = if ($null -ne $cpus) { $cpus } else { '0' }
            $ram = if ($null -ne $ram) { $ram } else { '0' }

            $powerState = if ($null -ne $data.extended.instanceView.powerState.displayStatus) { $data.extended.instanceView.powerState.displayStatus } else { 'vm unknown' }

            $tags = if (![string]::IsNullOrEmpty($vm.tags.psobject.properties)) { $vm.tags.psobject.properties | Select-Object Name, Value } else { $null }

            $obfuscatedId = if (![string]::IsNullOrEmpty($data.virtualMachineScaleSet.id)) { if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { if ($ResourceIdDictionary.ContainsKey($data.virtualMachineScaleSet.id)) { $ResourceIdDictionary[$data.virtualMachineScaleSet.id] } else { 'obfuscated' } } else { $data.virtualMachineScaleSet.id } } else { $null }

            $obj = @{
                'ID'                            = $vm.id;
                'Subscription'                  = $sub1.Name;
                'ResourceGroup'                 = $vm.RESOURCEGROUP;
                'Name'                          = $vm.NAME;
                'Location'                      = $vm.LOCATION;
                'AvailabilitySet'               = if ($null -ne $data.availabilitySet) { 'true' } else { 'false' }
                'Size'                          = $data.hardwareProfile.vmSize;
                'CPU'                           = $cpus;
                'Memory'                        = $ram;
                'Set'                           = $obfuscatedId;
                'ImageReference'                = $data.storageProfile.imageReference.publisher;
                'ImageVersion'                  = $data.storageProfile.imageReference.exactVersion;
                'ImageSku'                      = $data.storageProfile.imageReference.sku;
                'ImageOffer'                    = $data.storageProfile.imageReference.offer;
                'HybridBenefit'                 = $Lic;
                'OSType'                        = $data.storageProfile.osDisk.osType;
                'OSVersion'                     = $data.extended.instanceView.osversion;
                'OSDisk'                        = $OSDisk;
                'OSDiskSizeGB'                  = $OSDiskSize;
                'PowerState'                    = $powerState;
                'Zones'                         = $vm.zones.count;
                'CreatedTime'                   = $timecreated;
                'Tags'                          = $tags;
            }

            $tmp += $obj
        }

        $tmp
    }
}
