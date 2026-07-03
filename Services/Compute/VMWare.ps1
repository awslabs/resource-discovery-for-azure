param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing') 
{
    $VMWare = $Resources | Where-Object { $_.TYPE -eq 'Microsoft.AVS/privateClouds' }

    if($VMWare)
    {
        $tmp = @()
        foreach ($1 in $VMWare) 
        {
            $sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $data = $1.PROPERTIES

            $obj = @{
                'ID'                       = $1.id;
                'Subscription'             = $sub1.Name;
                'ResourceGroup'            = $1.RESOURCEGROUP;
                'Name'                     = $1.NAME;
                'Location'                 = $1.LOCATION;
                'SKU'                      = $data.sku.name;
                'AvailabilityStrategy'     = $data.availability.strategy;
                'Encryption'               = $data.encryption.status;
                'ClusterSize'              = $data.managementCluster.clusterSize;
            }

            $tmp += $obj
        }

        $tmp
    }
}
