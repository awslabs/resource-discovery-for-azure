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
            $Scaling = ($AutoScale | Where-Object { $_.Properties.targetResourceUri -eq $1.id })

            if ([string]::IsNullOrEmpty($Scaling)) { $AutoSc = $false }else { $AutoSc = $true }

            $RelatedAKSId = ($AKS | Where-Object { $_.properties.nodeResourceGroup -eq $1.resourceGroup }).id
            if ([string]::IsNullOrEmpty($RelatedAKSId)) { $RelatedId = ($SFC | Where-Object { $_.Properties.clusterEndpoint -in $1.properties.virtualMachineProfile.extensionProfile.extensions.properties.settings.clusterEndpoint }).id }else { $RelatedId = $RelatedAKSId }
            $Related = if ([string]::IsNullOrEmpty($RelatedId)) { $RelatedId } elseif ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { if ($ResourceIdDictionary.ContainsKey($RelatedId)) { $ResourceIdDictionary[$RelatedId] } else { 'obfuscated' } } else { $RelatedId.split('/')[8] }

            $Timecreated = $Data.timeCreated
            $Timecreated = [datetime]$Timecreated
            $Timecreated = $Timecreated.ToString("yyyy-MM-dd HH:mm")

            $Cpus = $Vmsizemap[$1.sku.name].CPU;
            $Ram = $Vmsizemap[$1.sku.name].RAM;

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
