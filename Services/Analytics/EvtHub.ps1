param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $Evthub = $Resources | Where-Object { $_.TYPE -eq 'microsoft.eventhub/namespaces' }

    if ($Evthub)
    {
        $Tmp = [System.Collections.Generic.List[object]]::new()

        foreach ($1 in $Evthub)
        {
            $Sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $Data = $1.PROPERTIES
            $Timecreated = $Data.createdAt
            # A missing value, or one that does not convert to a date, is 'Unknown'
            # rather than an exception that fails the whole collector.
            # A valid value is written in UTC on every host; one with no zone is taken as UTC.
            $Timecreated = try { if ($null -ne $Timecreated) { [datetime]::Parse($Timecreated, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]'AdjustToUniversal, AssumeUniversal').ToString("yyyy-MM-dd HH:mm") } else { 'Unknown' } } catch { 'Unknown' }

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

            [void]$Tmp.Add($Obj)
        }

        $Tmp
    }
}
