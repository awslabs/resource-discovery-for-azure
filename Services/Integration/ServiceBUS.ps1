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
            $Timecreated = if ($null -ne $Data.createdAt) { [datetime]($Data.createdAt) | Get-Date -Format "yyyy-MM-dd HH:mm" } else { 'Unknown' }

            $Obj = @{
                'ID'                    = $1.id;
                'Subscription'          = $Sub1.Name;
                'ResourceGroup'         = $1.RESOURCEGROUP;
                'Name'                  = $1.NAME;
                'Location'              = $1.LOCATION;
                'SKU'                   = $Sku.name;
                'Status'                = $Data.status;
                'GeoRep'                = $Data.zoneRedundant;
                'ThroughputUnits'       = $1.sku.capacity;
                'CreatedTime'           = $Timecreated;
            }

            $Tmp += $Obj
        }

        $Tmp
    }
}
