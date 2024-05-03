param($SCPath, $Sub, $Resources, $Task ,$File, $SmaResources, $TableStyle, $Metrics)

if ($Task -eq 'Processing') 
{
    $MySQL = $Resources | Where-Object { $_.TYPE -eq 'microsoft.dbformysql/servers' }

    if($MySQL)
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
else 
{
    if ($SmaResources.MySQL) 
    {
        $TableName = ('MySQLTable_'+($SmaResources.MySQL.id | Select-Object -Unique).count)
        $Style = New-ExcelStyle -HorizontalAlignment Center -AutoSize -NumberFormat 0.0

        $condtxt = @()
        
        $Exc = New-Object System.Collections.Generic.List[System.Object]
        $Exc.Add('Subscription')
        $Exc.Add('ResourceGroup')
        $Exc.Add('Name')
        $Exc.Add('Location')
        $Exc.Add('SKU')
        $Exc.Add('SKUFamily')
        $Exc.Add('Tier')
        $Exc.Add('Capacity')
        $Exc.Add('MySQLVersion')
        $Exc.Add('BackupRetentionDays')
        $Exc.Add('GeoRedundantBackup')
        $Exc.Add('AutoGrow')
        $Exc.Add('StorageMB')
        $Exc.Add('State')
        $Exc.Add('ReplicaCapacity')

        $ExcelVar = $SmaResources.MySQL

        $ExcelVar | 
        ForEach-Object { [PSCustomObject]$_ } | Select-Object -Unique $Exc | 
        Export-Excel -Path $File -WorksheetName 'MySQL' -AutoSize -MaxAutoSizeRows 100 -TableName $TableName -TableStyle $tableStyle -ConditionalText $condtxt -Style $Style
    }
}