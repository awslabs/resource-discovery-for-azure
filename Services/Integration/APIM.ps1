param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $APIM = $Resources | Where-Object { $_.TYPE -eq 'microsoft.apimanagement/service' }

    if ($APIM)
    {
        $Tmp = @()

        foreach ($1 in $APIM)
        {
            $Sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $Data = $1.PROPERTIES

            $Obj = @{
                'ID'                   = $1.id;
                'Subscription'         = $Sub1.Name;
                'ResourceGroup'        = $1.RESOURCEGROUP;
                'Name'                 = $1.NAME;
                'Location'             = $1.LOCATION;
                'Capacity'             = $1.sku.capacity;
                'SKU'                  = $1.sku.name;
                'VirtualNetworkType'   = $Data.virtualNetworkType;
            }

            $Tmp += $Obj
        }

        $Tmp
    }
}
