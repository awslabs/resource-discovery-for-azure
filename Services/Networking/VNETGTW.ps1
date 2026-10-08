param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $VNETGTW = foreach ($Row in $Resources) { if ($Row.TYPE -eq 'microsoft.network/virtualnetworkgateways') { $Row } }

    if ($VNETGTW)
    {
        $Tmp = @()

        foreach ($1 in $VNETGTW)
        {
            $Sub1 = $SUB | Where-Object { $_.Id -eq $1.subscriptionId }
            $Data = $1.PROPERTIES

            $Obj = @{
                'ID'                     = $1.id;
                'Subscription'           = $Sub1.Name;
                'ResourceGroup'          = $1.RESOURCEGROUP;
                'Name'                   = $1.NAME;
                'Location'               = $1.LOCATION;
                'SKU'                    = $Data.sku.tier;
                'ActiveActiveMode'       = $Data.activeActive;
            }

            $Tmp += $Obj
        }

        $Tmp
    }
}
