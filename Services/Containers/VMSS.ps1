param($SCPath, $Sub, $Resources, $Task ,$File, $SmaResources, $TableStyle, $Metrics)

if ($Task -eq 'Processing')
{
    $vmss = $Resources | Where-Object {$_.TYPE -eq 'microsoft.compute/virtualmachinescalesets'}
    $AutoScale = $Resources | Where-Object {$_.TYPE -eq "microsoft.insights/autoscalesettings" -and $_.Properties.enabled -eq 'true'} 
    $AKS = $Resources | Where-Object {$_.TYPE -eq 'microsoft.containerservice/managedclusters'}
    $SFC = $Resources | Where-Object {$_.TYPE -eq 'microsoft.servicefabric/clusters'}

    $vmsizemap = @{}

    foreach($location in ($vmss | Select-Object -ExpandProperty location -Unique))
    {
        foreach ($vmsize in (az vm list-sizes -l $location | ConvertFrom-Json))
        {
            $vmsizemap[$vmsize.name] = @{
                CPU = $vmSize.numberOfCores
                RAM = [math]::Max($vmSize.memoryInMB / 1024, 0) 
            }
        }
    }

    if($vmss)
    {
        $tmp = @()

        foreach ($1 in $vmss) 
        {
            $sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $data = $1.PROPERTIES
            $OS = $data.virtualMachineProfile.storageProfile.osDisk.osType
            $RelatedAKS = ($AKS | Where-Object {$_.properties.nodeResourceGroup -eq $1.resourceGroup}).Name

            if([string]::IsNullOrEmpty($RelatedAKS)){$Related = ($SFC | Where-Object {$_.Properties.clusterEndpoint -in $1.properties.virtualMachineProfile.extensionProfile.extensions.properties.settings.clusterEndpoint}).Name}else{$Related = $RelatedAKS}
            $Scaling = ($AutoScale | Where-Object {$_.Properties.targetResourceUri -eq $1.id})

            if([string]::IsNullOrEmpty($Scaling)){$AutoSc = $false}else{$AutoSc = $true}

            $timecreated = $data.timeCreated
            $timecreated = [datetime]$timecreated
            $timecreated = $timecreated.ToString("yyyy-MM-dd HH:mm")

            $cpus = $vmsizemap[$1.sku.name].CPU;
            $ram = $vmsizemap[$1.sku.name].RAM;

            $cpus = if ($null -ne $cpus) { $cpus } else { '0' }
            $ram = if ($null -ne $ram) { $ram } else { '0' }

            $obj = @{
                'ID'                            = $1.id;
                'Subscription'                  = $sub1.Name;
                'ResourceGroup'                 = $1.RESOURCEGROUP;
                'AKS'                           = $Related;
                'Name'                          = $1.NAME;
                'Location'                      = $1.LOCATION;
                'SKUTier'                       = $1.sku.tier;
                'VMSize'                        = $1.sku.name;
                'Instances'                     = $1.sku.capacity;
                'AutoscaleEnabled'              = $AutoSc;
                'License'                       = $data.virtualMachineProfile.licenseType;
                'vCPUs'                         = $cpus;
                'RAM'                           = $ram;
                'VMOS'                          = $OS;
                'OSImage'                       = $data.virtualMachineProfile.storageProfile.imageReference.offer;
                'ImageVersion'                  = $data.virtualMachineProfile.storageProfile.imageReference.sku;                            
                'DiskSizeGB'                    = $data.virtualMachineProfile.storageProfile.osDisk.diskSizeGB;
                'StorageAccountType'            = $data.virtualMachineProfile.storageProfile.osDisk.managedDisk.storageAccountType;
                'AcceleratedNetworkingEnabled'  = $data.virtualMachineProfile.networkProfile.networkInterfaceConfigurations.properties.enableAcceleratedNetworking; 
                'CreatedTime'                   = $timecreated;
            }

            $tmp += $obj
        }

        $tmp
    }
}
else
{
    if($SmaResources.VMSS)
    {
        $TableName = ('VMSSTable_'+($SmaResources.VMSS.id | Select-Object -Unique).count)
        $Style = @()        
        $condtxt = @()

        $Exc = New-Object System.Collections.Generic.List[System.Object]
        $Exc.Add('Subscription')
        $Exc.Add('ResourceGroup')
        $Exc.Add('AKS')
        $Exc.Add('Name')
        $Exc.Add('Location')
        $Exc.Add('SKUTier')
        $Exc.Add('VMSize')
        $Exc.Add('vCPUs')
        $Exc.Add('RAM')
        $Exc.Add('License')
        $Exc.Add('Instances')
        $Exc.Add('AutoscaleEnabled')
        $Exc.Add('VMOS')
        $Exc.Add('OSImage')
        $Exc.Add('ImageVersion')                        
        $Exc.Add('DiskSizeGB')
        $Exc.Add('StorageAccountType')
        $Exc.Add('AcceleratedNetworkingEnabled')
        $Exc.Add('CreatedTime')

        $ExcelVar = $SmaResources.VMSS 

        $ExcelVar | 
        ForEach-Object { [PSCustomObject]$_ } | Select-Object -Unique $Exc | 
        Export-Excel -Path $File -WorksheetName 'VM Scale Sets' -AutoSize -MaxAutoSizeRows 50 -TableName $TableName -TableStyle $tableStyle -ConditionalText $condtxt -Style $Style
    }
}
