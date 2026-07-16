param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $SQLPOOL = $Resources | Where-Object { $_.TYPE -eq 'microsoft.sql/servers/elasticPools' }

    if ($SQLPOOL)
    {
        $Tmp = @()

        foreach ($1 in $SQLPOOL)
        {
            $Sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $Data = $1.PROPERTIES

            $Obj = @{
                'ID'                         = $1.id;
                'Subscription'               = $Sub1.Name;
                'ResourceGroup'              = $1.RESOURCEGROUP;
                'Name'                       = $1.NAME;
                'Location'                   = $1.LOCATION;
                'Capacity'                   = $1.sku.Capacity;
                'Sku'                        = $1.sku.name;
                'Size'                       = $1.sku.size;
                'Tier'                       = $1.sku.tier;
                'ReplicaCount'               = $Data.highAvailabilityReplicaCount;
                'License'                    = $Data.licenseType;
                'MinCapacity'                = $Data.minCapacity;
                'MaxSizeGB'                  = (($Data.maxSizeBytes / 1024) / 1024) / 1024;
                'DBMaxCapacity'              = $Data.perDatabaseSettings.maxCapacity;
                'DBMinCapacity'              = $Data.perDatabaseSettings.minCapacity;
                'ZoneRedundant'              = $Data.zoneRedundant;
            }

            $Tmp += $Obj
        }

        $Tmp
    }
}
