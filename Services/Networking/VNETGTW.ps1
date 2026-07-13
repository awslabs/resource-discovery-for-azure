param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $VNETGTW = $Resources | Where-Object { $_.TYPE -eq 'microsoft.network/virtualnetworkgateways' }

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
