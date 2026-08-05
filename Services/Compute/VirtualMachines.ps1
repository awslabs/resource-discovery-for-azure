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
        try
        {
            $Skus = Get-AzComputeResourceSku -Location $location -ErrorAction Stop | Where-Object { $_.ResourceType -eq 'virtualMachines' }
        }
        catch
        {
            # A per-region SKU lookup failure (throttle / transient / permission) must
            # not abort the whole VM collector. A terminating .NET exception here is
            # NOT suppressed by the run's $ErrorActionPreference = 'SilentlyContinue',
            # so it would otherwise propagate and drop the entire virtual-machines
            # section. Skip this region's SKU map instead; any VM whose size is not in
            # the map falls back to '0' vCPUs/RAM below. Leave a low-noise trace
            # (silent unless -Verbose) so a region-wide SKU failure is
            # distinguishable from genuinely-unknown sizes. Write-Verbose (not
            # Write-Warning) so a broad SKU-API failure across many regions cannot
            # flood a normal run; the finally still restores DebugPreference on
            # every path.
            Write-Verbose ("VirtualMachines: SKU lookup skipped for '{0}': {1}. CPU/Memory fall back to '0' for VMs in that region." -f $location, $_.Exception.Message)
            $Skus = $null
        }
        finally
        {
            $DebugPreference = $SavedDebugPref
        }

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
            $Timecreated = try { if ($null -ne $Data.timeCreated) { [datetime]($Data.timeCreated) | Get-Date -Format "yyyy-MM-dd HH:mm" } else { 'Unknown' } } catch { 'Unknown' }

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
                # Migration phase: SecurityType = 'ConfidentialVM' is a hard migration blocker
                # (vTPM/enclave-backed, no direct lift-and-shift equivalent); 'TrustedLaunch'
                # needs equivalent target config; EncryptionAtHost indicates host-level disk
                # encryption to reproduce. Surfaced for AWS migration planning.
                'SecurityType'                  = $Data.securityProfile.securityType;
                'EncryptionAtHost'              = $Data.securityProfile.encryptionAtHost;
                'Tags'                          = $Tags;
            }

            $Tmp += $Obj
        }

        $Tmp
    }
}
