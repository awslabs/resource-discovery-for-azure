param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $PostgreSQLFlexible = $Resources | Where-Object { $_.TYPE -eq 'Microsoft.DBforPostgreSQL/flexibleServers' }

    if ($PostgreSQLFlexible)
    {
        $Tmp = @()

        foreach ($1 in $PostgreSQLFlexible)
        {
            $Sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $Data = $1.PROPERTIES

            $Obj = @{
                'ID'                                = $1.id;
                'Subscription'                      = $Sub1.Name;
                'ResourceGroup'                     = $1.RESOURCEGROUP;
                'Name'                              = $1.NAME;
                'Location'                          = $1.LOCATION;
                'SKU'                               = $1.sku.name;
                'Tier'                              = $1.sku.tier;
                'Version'                           = $Data.version;
                'State'                             = $Data.state;
                'Zone'                              = $Data.availabilityZone;
                'StorageSizeGB'                     = $Data.storage.storageSizeGB;
                'LimitIOPs'                         = $Data.storage.iops;
                'AutoGrow'                          = $Data.storage.autoGrow;
                'StorageSku'                        = $Data.storage.tier;
                'ReplicationRole'                   = $Data.replicationRole;
                'ReplicaCapacity'                   = $Data.replicaCapacity;
                'BackupRetentionDays'               = $Data.backup.backupRetentionDays;
                'GeoRedundantBackup'                = $Data.backup.geoRedundantBackup;
                'HighAvailability'                  = $Data.highAvailability.mode;
                'HighAvailabilityState'             = $Data.highAvailability.state;
            }

            $Tmp += $Obj
        }

        $Tmp
    }
}
