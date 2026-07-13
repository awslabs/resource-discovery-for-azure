param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $POSTGRE = $Resources | Where-Object { $_.TYPE -eq 'microsoft.dbforpostgresql/servers' }

    if ($POSTGRE)
    {
        $Tmp = @()

        foreach ($1 in $POSTGRE)
        {
            $Sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $Data = $1.PROPERTIES
            $Sku = $1.SKU

            $Obj = @{
                'ID'                        = $1.id;
                'Subscription'              = $Sub1.Name;
                'ResourceGroup'             = $1.RESOURCEGROUP;
                'Name'                      = $1.NAME;
                'Location'                  = $1.LOCATION;
                'SKU'                       = $Sku.name;
                'SKUFamily'                 = $Sku.family;
                'Tier'                      = $Sku.tier;
                'Capacity'                  = $Sku.capacity;
                'PostgreVersion'            = $Data.version;
                'BackupRetentionDays'       = $Data.storageProfile.backupRetentionDays;
                'GeoRedundantBackup'        = $Data.storageProfile.geoRedundantBackup;
                'AutoGrow'                  = $Data.storageProfile.storageAutogrow;
                'StorageMB'                 = $Data.storageProfile.storageMB;
                'State'                     = $Data.userVisibleState;
                'ReplicaCapacity'           = $Data.replicaCapacity;
            }

            $Tmp += $Obj
        }

        $Tmp
    }
}
