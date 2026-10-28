param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $Svchub = $Resources | Where-Object { $_.TYPE -eq 'microsoft.servicebus/namespaces' }

    if ($Svchub)
    {
        $Tmp = @()

        foreach ($1 in $Svchub)
        {
            $Sub1 = $SUB | Where-Object { $_.Id -eq $1.subscriptionId }
            $Data = $1.PROPERTIES
            $Sku = $1.SKU
            $Timecreated = $Data.createdAt
            $Timecreated = [datetime]$Timecreated
            $Timecreated = $Timecreated.ToString("yyyy-MM-dd HH:mm")
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

            $Tmp += $Obj
        }

        $Tmp
    }
}
