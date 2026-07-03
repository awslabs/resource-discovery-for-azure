param($Sub, $Resources, $Task, $ResourceIdDictionary)

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
