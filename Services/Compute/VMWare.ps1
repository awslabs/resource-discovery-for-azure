param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $VMWare = $Resources | Where-Object { $_.TYPE -eq 'Microsoft.AVS/privateClouds' }

    if ($VMWare)
    {
        $Tmp = @()
        foreach ($1 in $VMWare)
        {
            $Sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $Data = $1.PROPERTIES

            $Obj = @{
                'ID'                       = $1.id;
                'Subscription'             = $Sub1.Name;
                'ResourceGroup'            = $1.RESOURCEGROUP;
                'Name'                     = $1.NAME;
                'Location'                 = $1.LOCATION;
                'SKU'                      = $Data.sku.name;
                'AvailabilityStrategy'     = $Data.availability.strategy;
                'Encryption'               = $Data.encryption.status;
                'ClusterSize'              = $Data.managementCluster.clusterSize;
            }

            $Tmp += $Obj
        }

        $Tmp
    }
}
