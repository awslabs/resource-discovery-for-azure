param($SCPath, $Sub, $Resources, $Task ,$File, $SmaResources, $TableStyle, $Metrics)

if ($Task -eq 'Processing')
{
    $evthub = $Resources | Where-Object {$_.TYPE -eq 'microsoft.eventhub/namespaces'}

    if($evthub)
    {
        $tmp = @()
        
        foreach ($1 in $evthub) 
        {
            $sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $data = $1.PROPERTIES
            $timecreated = $data.createdAt
            $timecreated = [datetime]$timecreated
            $timecreated = $timecreated.ToString("yyyy-MM-dd HH:mm")

            $obj = @{
                'ID'                   = $1.id;
                'Subscription'         = $sub1.Name;
                'ResourceGroup'        = $1.RESOURCEGROUP;
                'Name'                 = $1.NAME;
                'Location'             = $1.LOCATION;
                'SKU'                  = $1.sku.name;
                'Status'               = $data.status;
                'GeoReplication'       = $data.zoneRedundant;
                'ThroughputUnits'      = $1.sku.capacity;
                'AutoInflate'          = $data.isAutoInflateEnabled;
                'MaxThroughputUnits'   = $data.maximumThroughputUnits;
                'KafkaEnabled'         = $data.kafkaEnabled;
                'CreatedTime'          = $timecreated;
            }
            
            $tmp += $obj
        }

        $tmp
    }
}
else
{
    if($SmaResources.EvtHub)
    {
        $TableName = ('EvtHubTable_'+($SmaResources.EvtHub.id | Select-Object -Unique).count)
        $Style = New-ExcelStyle -HorizontalAlignment Center -AutoSize -NumberFormat '0'

        $condtxt = @()

        $Exc = New-Object System.Collections.Generic.List[System.Object]
        $Exc.Add('Subscription')
        $Exc.Add('ResourceGroup')
        $Exc.Add('Name')
        $Exc.Add('Location')
        $Exc.Add('SKU')
        $Exc.Add('Status')
        $Exc.Add('GeoReplication')
        $Exc.Add('ThroughputUnits')
        $Exc.Add('AutoInflate')
        $Exc.Add('MaxThroughputUnits')
        $Exc.Add('KafkaEnabled')
        $Exc.Add('CreatedTime')  

        $ExcelVar = $SmaResources.EvtHub  

        $ExcelVar | 
        ForEach-Object { [PSCustomObject]$_ } | Select-Object -Unique $Exc | 
        Export-Excel -Path $File -WorksheetName 'Event Hubs' -AutoSize -MaxAutoSizeRows 100 -TableName $TableName -TableStyle $tableStyle -ConditionalText $condtxt -Style $Style, $StyleCost
    }
}
