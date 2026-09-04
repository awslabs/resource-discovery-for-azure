param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $VMWare = $Resources | Where-Object { $_.TYPE -eq 'microsoft.avs/privateclouds' }

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
                # sku is a TOP-LEVEL Resource Graph column for this type, not a
                # member of properties: the ARM contract for
                # Microsoft.AVS/privateClouds declares sku as a required sibling of
                # properties. Reading $Data.sku (= properties.sku) therefore always
                # yielded null. Same correction as IOTHubs.
                'SKU'                      = $1.sku.name;
                'AvailabilityStrategy'     = $Data.availability.strategy;
                'Encryption'               = $Data.encryption.status;
                'ClusterSize'              = $Data.managementCluster.clusterSize;
            }

            $Tmp += $Obj
        }

        $Tmp
    }
}
