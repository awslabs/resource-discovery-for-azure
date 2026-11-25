param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $Svchub = $Resources | Where-Object { $_.TYPE -eq 'microsoft.servicebus/namespaces' }

    if ($Svchub)
    {
        $Tmp = [System.Collections.Generic.List[object]]::new()

        foreach ($1 in $Svchub)
        {
            $Sub1 = $SUB | Where-Object { $_.Id -eq $1.subscriptionId }
            $Data = $1.PROPERTIES
            $Sku = $1.SKU
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
                'ID'                    = $1.id;
                'Subscription'          = $Sub1.Name;
                'ResourceGroup'         = $1.RESOURCEGROUP;
                'Name'                  = $1.NAME;
                'Location'              = $1.LOCATION;
                'SKU'                   = $Sku.name;
                'Status'                = $Data.status;
                'GeoRep'                = $GeoRep;
                'ThroughputUnits'       = $1.sku.capacity;
                'CreatedTime'           = $Timecreated;
            }

            [void]$Tmp.Add($Obj)
        }

        $Tmp
    }
}
