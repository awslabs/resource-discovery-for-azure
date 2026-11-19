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

    if ($Vmss)
    {
        $Tmp = @()

        foreach ($1 in $Vmss)
        {
            $Sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $Data = $1.PROPERTIES
            $OS = $Data.virtualMachineProfile.storageProfile.osDisk.osType
            # The image version, as VirtualMachines.ps1 reads exactVersion; a scale
            # set model usually carries only the requested version (e.g. 'latest').
            $ImageReference = $Data.virtualMachineProfile.storageProfile.imageReference
            $ImageVersion = if (-not [string]::IsNullOrEmpty($ImageReference.exactVersion)) { $ImageReference.exactVersion } elseif (-not [string]::IsNullOrEmpty($ImageReference.version)) { $ImageReference.version } else { $null }
            $Scaling = ($AutoScale | Where-Object { $_.Properties.targetResourceUri -eq $1.id })

            if ([string]::IsNullOrEmpty($Scaling)) { $AutoSc = $false }else { $AutoSc = $true }

            $RelatedAKSId = ($AKS | Where-Object { $_.properties.nodeResourceGroup -eq $1.resourceGroup }).id
            if ([string]::IsNullOrEmpty($RelatedAKSId)) { $RelatedId = ($SFC | Where-Object { $_.Properties.clusterEndpoint -in $1.properties.virtualMachineProfile.extensionProfile.extensions.properties.settings.clusterEndpoint }).id }else { $RelatedId = $RelatedAKSId }
            $Related = if ([string]::IsNullOrEmpty($RelatedId)) { $RelatedId } elseif ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { if ($ResourceIdDictionary.ContainsKey($RelatedId)) { $ResourceIdDictionary[$RelatedId] } else { 'obfuscated' } } else { $RelatedId.split('/')[8] }

            # A missing timeCreated, or one that does not convert to a date, is
            # 'Unknown' rather than an exception that fails every scale set.
            # A valid value is written in UTC on every host; one with no zone is taken as UTC.
            $Timecreated = try { if ($null -ne $Data.timeCreated) { [datetime]::Parse($Data.timeCreated, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]'AdjustToUniversal, AssumeUniversal') | Get-Date -Format "yyyy-MM-dd HH:mm" } else { 'Unknown' } } catch { 'Unknown' }

            # A missing size, or one the SKU list does not know, leaves vCPUs and RAM
            # empty rather than 0.
            $SkuName = $1.sku.name
            $Cpus = if ($null -ne $SkuName) { $Vmsizemap[$SkuName].CPU } else { $null }
            $Ram = if ($null -ne $SkuName) { $Vmsizemap[$SkuName].RAM } else { $null }

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
                'ImageVersion'                  = $ImageVersion;
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
