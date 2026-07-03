param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing') 
{
    $SQLPOOL = $Resources | Where-Object { $_.TYPE -eq 'microsoft.sql/servers/elasticPools' }

    if($SQLPOOL)
    {
        $tmp = @()

        foreach ($1 in $SQLPOOL) 
        {          
            $sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $data = $1.PROPERTIES

            $obj = @{
                'ID'                         = $1.id;
                'Subscription'               = $sub1.Name;
                'ResourceGroup'              = $1.RESOURCEGROUP;
                'Name'                       = $1.NAME;
                'Location'                   = $1.LOCATION;
                'Capacity'                   = $1.sku.Capacity;
                'Sku'                        = $1.sku.name;
                'Size'                       = $1.sku.size;
                'Tier'                       = $1.sku.tier;
                'ReplicaCount'               = $data.highAvailabilityReplicaCount;
                'License'                    = $data.licenseType;
                'MinCapacity'                = $data.minCapacity;
                'MaxSizeGB'                  = (($data.maxSizeBytes / 1024) / 1024) / 1024;
                'DBMaxCapacity'              = $data.perDatabaseSettings.maxCapacity;
                'DBMinCapacity'              = $data.perDatabaseSettings.minCapacity;
                'ZoneRedundant'              = $data.zoneRedundant;
            }
            
            $tmp += $obj
        }

        $tmp
    }
}
