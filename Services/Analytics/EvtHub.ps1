param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $Evthub = $Resources | Where-Object { $_.TYPE -eq 'microsoft.eventhub/namespaces' }

    if ($Evthub)
    {
        $Tmp = @()

        foreach ($1 in $Evthub)
        {
            $Sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $Data = $1.PROPERTIES
            $Timecreated = $Data.createdAt
            $Timecreated = [datetime]$Timecreated
            $Timecreated = $Timecreated.ToString("yyyy-MM-dd HH:mm")

            # Geo replication: the namespace lists every region it replicates to,
            # the primary included, in geoDataReplication.locations; one entry or
            # none means no replica in another region.
            $GeoRep = @($Data.geoDataReplication.locations | Where-Object { $null -ne $_ }).Count -gt 1

            $Obj = @{
                'ID'                   = $1.id;
                'Subscription'         = $Sub1.Name;
                'ResourceGroup'        = $1.RESOURCEGROUP;
                'Name'                 = $1.NAME;
                'Location'             = $1.LOCATION;
                'SKU'                  = $1.sku.name;
                'Status'               = $Data.status;
                'GeoReplication'       = $GeoRep;
                'ThroughputUnits'      = $1.sku.capacity;
                'AutoInflate'          = $Data.isAutoInflateEnabled;
                'MaxThroughputUnits'   = $Data.maximumThroughputUnits;
                'KafkaEnabled'         = $Data.kafkaEnabled;
                'CreatedTime'          = $Timecreated;
            }

            $Tmp += $Obj
        }

        $Tmp
    }
}
