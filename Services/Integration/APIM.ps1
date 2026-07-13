param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $APIM = $Resources | Where-Object { $_.TYPE -eq 'microsoft.apimanagement/service' }

    if ($APIM)
    {
        $tmp = @()

        foreach ($1 in $APIM)
        {
            $sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $data = $1.PROPERTIES

            $obj = @{
                'ID'                   = $1.id;
                'Subscription'         = $sub1.Name;
                'ResourceGroup'        = $1.RESOURCEGROUP;
                'Name'                 = $1.NAME;
                'Location'             = $1.LOCATION;
                'Capacity'             = $1.sku.capacity;
                'SKU'                  = $1.sku.name;
                'VirtualNetworkType'   = $data.virtualNetworkType;
            }

            $tmp += $obj
        }

        $tmp
    }
}
