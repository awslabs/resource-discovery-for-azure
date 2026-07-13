param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $MySQLFlexible = $Resources | Where-Object { $_.TYPE -eq 'Microsoft.DBforMySQL/flexibleServers' }

    if ($MySQLFlexible)
    {
        $tmp = @()

        foreach ($1 in $MySQLFlexible)
        {
            $sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $data = $1.PROPERTIES

            $obj = @{
                'ID'                                = $1.id;
                'Subscription'                      = $sub1.Name;
                'ResourceGroup'                     = $1.RESOURCEGROUP;
                'Name'                              = $1.NAME;
                'Location'                          = $1.LOCATION;
                'SKU'                               = $1.sku.name;
                'Tier'                              = $1.sku.tier;
                'Version'                           = $data.version;
                'State'                             = $data.state;
                'Zone'                              = $data.availabilityZone;
                'StorageSizeGB'                     = $data.storage.storageSizeGB;
                'LimitIOPs'                         = $data.storage.iops;
                'AutoGrow'                          = $data.storage.autoGrow;
                'StorageSku'                        = $data.storage.storageSku;
                'CustomMaintenanceWindow'           = $data.maintenanceWindow.customWindow;
                'ReplicationRole'                   = $data.replicationRole;
                'ReplicaCapacity'                   = $data.replicaCapacity;
                'BackupRetentionDays'               = $data.backup.backupRetentionDays;
                'GeoRedundantBackup'                = $data.backup.geoRedundantBackup;
                'HighAvailability'                  = $data.highAvailability.mode;
                'HighAvailabilityState'             = $data.highAvailability.state;
            }

            $tmp += $obj
        }

        $tmp
    }
}
