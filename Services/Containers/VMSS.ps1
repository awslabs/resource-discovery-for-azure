param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $Vmss = $Resources | Where-Object { $_.TYPE -eq 'microsoft.compute/virtualmachinescalesets' }
    $AutoScale = $Resources | Where-Object { $_.TYPE -eq "microsoft.insights/autoscalesettings" -and $_.Properties.enabled -eq 'true' }
    $AKS = $Resources | Where-Object { $_.TYPE -eq 'microsoft.containerservice/managedclusters' }
    $SFC = $Resources | Where-Object { $_.TYPE -eq 'microsoft.servicefabric/clusters' }

    $Vmsizemap = @{}

    foreach ($location in ($Vmss | Select-Object -ExpandProperty location -Unique))
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
            # not abort the whole VMSS collector. A terminating .NET exception here is
            # NOT suppressed by the run's $ErrorActionPreference = 'SilentlyContinue',
            # so it would otherwise propagate and drop the entire scale-set section.
            # Skip this region's SKU map instead; any scale set whose size is not in
            # the map falls back to '0' vCPUs/RAM below. Leave a low-noise trace
            # (silent unless -Verbose) so a region-wide SKU failure is
            # distinguishable from genuinely-unknown sizes. Write-Verbose (not
            # Write-Warning) so a broad SKU-API failure across many regions cannot
            # flood a normal run; the finally still restores DebugPreference on
            # every path.
            Write-Verbose ("VMSS: SKU lookup skipped for '{0}': {1}. vCPUs/RAM fall back to '0' for scale sets in that region." -f $location, $_.Exception.Message)
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

    if ($Vmss)
    {
        $Tmp = @()

        foreach ($1 in $Vmss)
        {
            $Sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $Data = $1.PROPERTIES
            $OS = $Data.virtualMachineProfile.storageProfile.osDisk.osType
            $Scaling = ($AutoScale | Where-Object { $_.Properties.targetResourceUri -eq $1.id })

            if ([string]::IsNullOrEmpty($Scaling)) { $AutoSc = $false }else { $AutoSc = $true }

            $RelatedAKSId = ($AKS | Where-Object { $_.properties.nodeResourceGroup -eq $1.resourceGroup }).id
            if ([string]::IsNullOrEmpty($RelatedAKSId)) { $RelatedId = ($SFC | Where-Object { $_.Properties.clusterEndpoint -in $1.properties.virtualMachineProfile.extensionProfile.extensions.properties.settings.clusterEndpoint }).id }else { $RelatedId = $RelatedAKSId }
            $Related = if ([string]::IsNullOrEmpty($RelatedId)) { $RelatedId } elseif ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { if ($ResourceIdDictionary.ContainsKey($RelatedId)) { $ResourceIdDictionary[$RelatedId] } else { 'obfuscated' } } else { $RelatedId.split('/')[8] }

            $Timecreated = if ($null -ne $Data.timeCreated) { [datetime]($Data.timeCreated) | Get-Date -Format "yyyy-MM-dd HH:mm" } else { 'Unknown' }

            $SkuName = $1.sku.name
            $Cpus = if ($null -ne $SkuName) { $Vmsizemap[$SkuName].CPU } else { $null }
            $Ram = if ($null -ne $SkuName) { $Vmsizemap[$SkuName].RAM } else { $null }

            $Cpus = if ($null -ne $Cpus) { $Cpus } else { '0' }
            $Ram = if ($null -ne $Ram) { $Ram } else { '0' }

            $Obj = @{
                'ID'                            = $1.id;
                'Subscription'                  = $Sub1.Name;
                'ResourceGroup'                 = $1.RESOURCEGROUP;
                'AKS'                           = $Related;
                'Name'                          = $1.NAME;
                'Location'                      = $1.LOCATION;
                'SKUTier'                       = $1.sku.tier;
                'VMSize'                        = $1.sku.name;
                'Instances'                     = $1.sku.capacity;
                'AutoscaleEnabled'              = $AutoSc;
                'License'                       = $Data.virtualMachineProfile.licenseType;
                'vCPUs'                         = $Cpus;
                'RAM'                           = $Ram;
                'VMOS'                          = $OS;
                'OSImage'                       = $Data.virtualMachineProfile.storageProfile.imageReference.offer;
                'ImageVersion'                  = $Data.virtualMachineProfile.storageProfile.imageReference.sku;
                'DiskSizeGB'                    = $Data.virtualMachineProfile.storageProfile.osDisk.diskSizeGB;
                'StorageAccountType'            = $Data.virtualMachineProfile.storageProfile.osDisk.managedDisk.storageAccountType;
                'AcceleratedNetworkingEnabled'  = $Data.virtualMachineProfile.networkProfile.networkInterfaceConfigurations.properties.enableAcceleratedNetworking;
                'CreatedTime'                   = $Timecreated;
            }

            $Tmp += $Obj
        }

        $Tmp
    }
}
