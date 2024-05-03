param($SCPath, $Sub, $Resources, $Task ,$File, $SmaResources, $TableStyle, $Metrics)

if ($Task -eq 'Processing') 
{
    $MySQLFlexible = $Resources | Where-Object { $_.TYPE -eq 'Microsoft.DBforMySQL/flexibleServers' }

    if($MySQLFlexible)
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
else 
{
    if ($SmaResources.MySQLFlexible) 
    {
        $TableName = ('MySQLFlexTable_'+($SmaResources.MySQLFlexible.id | Select-Object -Unique).count)
        $Style = New-ExcelStyle -HorizontalAlignment Center -AutoSize -NumberFormat 0
        
        $Exc = New-Object System.Collections.Generic.List[System.Object]
        $Exc.Add('Subscription')
        $Exc.Add('ResourceGroup')
        $Exc.Add('Name')
        $Exc.Add('Location')
        $Exc.Add('SKU')
        $Exc.Add('Tier')
        $Exc.Add('Version')
        $Exc.Add('State')
        $Exc.Add('Zone')
        $Exc.Add('StorageSizeGB')
        $Exc.Add('LimitIOPs')
        $Exc.Add('AutoGrow')
        $Exc.Add('StorageSku')
        $Exc.Add('CustomMaintenanceWindow')
        $Exc.Add('ReplicationRole')
        $Exc.Add('ReplicaCapacity')
        $Exc.Add('BackupRetentionDays')
        $Exc.Add('GeoRedundantBackup')
        $Exc.Add('HighAvailability')
        $Exc.Add('HighAvailabilityState')

        $ExcelVar = $SmaResources.MySQLFlexible 

        $ExcelVar | 
        ForEach-Object { [PSCustomObject]$_ } | Select-Object -Unique $Exc | 
        Export-Excel -Path $File -WorksheetName 'MySQL Flexible' -AutoSize -MaxAutoSizeRows 100 -TableName $TableName -TableStyle $tableStyle -Style $Style
    }
}
