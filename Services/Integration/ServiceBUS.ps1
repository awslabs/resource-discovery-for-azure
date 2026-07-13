param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $svchub = $Resources | Where-Object { $_.TYPE -eq 'microsoft.servicebus/namespaces' }

    if ($svchub)
    {
        $tmp = @()

        foreach ($1 in $svchub)
        {
            $sub1 = $SUB | Where-Object { $_.Id -eq $1.subscriptionId }
            $data = $1.PROPERTIES
            $sku = $1.SKU
            $timecreated = $data.createdAt
            $timecreated = [datetime]$timecreated
            $timecreated = $timecreated.ToString("yyyy-MM-dd HH:mm")

            $obj = @{
                'ID'                    = $1.id;
                'Subscription'          = $sub1.Name;
                'ResourceGroup'         = $1.RESOURCEGROUP;
                'Name'                  = $1.NAME;
                'Location'              = $1.LOCATION;
                'SKU'                   = $sku.name;
                'Status'                = $data.status;
                'GeoRep'                = $data.zoneRedundant;
                'ThroughputUnits'       = $1.sku.capacity;
                'CreatedTime'           = $timecreated;
            }

            $tmp += $obj
        }

        $tmp
    }
}
