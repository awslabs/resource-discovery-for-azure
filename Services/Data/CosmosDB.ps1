param($SCPath, $Sub, $Resources, $Task ,$File, $SmaResources, $TableStyle, $Metrics)

if ($Task -eq 'Processing') 
{
    $COSMOS = $Resources | Where-Object { $_.TYPE -eq 'microsoft.documentdb/databaseaccounts' }

    if($COSMOS)
    {
        $tmp = @()

        foreach ($1 in $COSMOS) 
        {                
            $sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $data = $1.PROPERTIES

            $GeoReplicate = if($data.failoverPolicies.count -gt 1) { 'Enabled' } else { 'Disabled' }
            $FreeTier = if($data.enableFreeTier -eq $true) { 'Opted In' } else { 'Opted Out' }
            
            $obj = @{
                'ID'                        = $1.id;
                'Subscription'              = $sub1.Name;
                'ResourceGroup'             = $1.RESOURCEGROUP;
                'Name'                      = $1.NAME;
                'Location'                  = $1.LOCATION;
                'EnabledAPITypes'           = $data.EnabledApiTypes;
                'BackupPolicy'              = $data.backupPolicy.type;
                'BackupStorageRedundancy'   = $data.backupPolicy.periodicModeProperties.backupStorageRedundancy;
                'AccountOfferType'          = $data.databaseAccountOfferType;
                'ReplicateDataGlobally'     = $GeoReplicate;
                'FreeTierDiscount'          = $FreeTier;
                'DefaultConsistency'        = $data.consistencyPolicy.defaultConsistencyLevel;
            }

            $tmp += $obj
        }
        
        $tmp
    }
}
else 
{
    if ($SmaResources.CosmosDB) 
    {
        $TableName = ('CosmosTable_'+($SmaResources.CosmosDB.id | Select-Object -Unique).count)
        $Style = New-ExcelStyle -HorizontalAlignment Center -AutoSize -NumberFormat 0

        $condtxt = @()

        $Exc = New-Object System.Collections.Generic.List[System.Object]
        $Exc.Add('Subscription')
        $Exc.Add('ResourceGroup')
        $Exc.Add('Name')
        $Exc.Add('Location')
        $Exc.Add('EnabledAPITypes')
        $Exc.Add('BackupPolicy')
        $Exc.Add('BackupStorageRedundancy')
        $Exc.Add('AccountOfferType')
        $Exc.Add('ReplicateDataGlobally')
        $Exc.Add('FreeTierDiscount')
        $Exc.Add('DefaultConsistency')

        $ExcelVar = $SmaResources.CosmosDB 

        $ExcelVar | 
        ForEach-Object { [PSCustomObject]$_ } | Select-Object -Unique $Exc | 
        Export-Excel -Path $File -WorksheetName 'Cosmos DB' -AutoSize -MaxAutoSizeRows 100 -TableName $TableName -TableStyle $tableStyle -ConditionalText $condtxt -Style $Style
    }
}