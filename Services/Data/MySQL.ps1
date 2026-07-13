param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $MySQL = $Resources | Where-Object { $_.TYPE -eq 'microsoft.dbformysql/servers' }

    if ($MySQL)
    {
        $tmp = @()

        foreach ($1 in $MySQL)
        {
            $sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $data = $1.PROPERTIES
            $sku = $1.SKU

            $obj = @{
                'ID'                        = $1.id;
                'Subscription'              = $sub1.Name;
                'ResourceGroup'             = $1.RESOURCEGROUP;
                'Name'                      = $1.NAME;
                'Location'                  = $1.LOCATION;
                'SKU'                       = $sku.name;
                'SKUFamily'                 = $sku.family;
                'Tier'                      = $sku.tier;
                'Capacity'                  = $sku.capacity;
                'MySQLVersion'              = "=$($data.version)";
                'BackupRetentionDays'       = $data.storageProfile.backupRetentionDays;
                'GeoRedundantBackup'        = $data.storageProfile.geoRedundantBackup;
                'AutoGrow'                  = $data.storageProfile.storageAutogrow;
                'StorageMB'                 = $data.storageProfile.storageMB;
                'State'                     = $data.userVisibleState;
                'ReplicaCapacity'           = $data.replicaCapacity;
            }

            $tmp += $obj
        }

        $tmp
    }
}
