param($SCPath, $Sub, $Resources, $Task ,$File, $SmaResources, $TableStyle, $Metrics)

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
else 
{
    if ($SmaResources.SQLPOOL) 
    {
        $TableName = ('SqlPoolTable_'+($SmaResources.SQLPOOL.id | Select-Object -Unique).count)
        $Style = New-ExcelStyle -HorizontalAlignment Center -AutoSize -NumberFormat 0
        
        $Exc = New-Object System.Collections.Generic.List[System.Object]
        $Exc.Add('Subscription')
        $Exc.Add('ResourceGroup')
        $Exc.Add('Name')
        $Exc.Add('Location')
        $Exc.Add('Capacity')
        $Exc.Add('Sku')
        $Exc.Add('Size')
        $Exc.Add('Tier')
        $Exc.Add('ReplicaCount')
        $Exc.Add('License')
        $Exc.Add('MinCapacity')
        $Exc.Add('MaxSizeGB')
        $Exc.Add('DBMinCapacity')
        $Exc.Add('DBMaxCapacity')
        $Exc.Add('ZoneRedundant')        

        $ExcelVar = $SmaResources.SQLPOOL 

        $ExcelVar | 
        ForEach-Object { [PSCustomObject]$_ } | Select-Object -Unique $Exc | 
        Export-Excel -Path $File -WorksheetName 'SQL Pools' -AutoSize -MaxAutoSizeRows 100 -TableName $TableName -TableStyle $tableStyle -Style $Style
    }
}