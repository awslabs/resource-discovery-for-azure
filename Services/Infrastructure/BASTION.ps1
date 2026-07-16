param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $BASTION = $Resources | Where-Object { $_.TYPE -eq 'microsoft.network/bastionhosts' }

    if ($BASTION)
    {
        $Tmp = @()

        foreach ($1 in $BASTION)
        {
            $Sub1 = $SUB | Where-Object { $_.Id -eq $1.subscriptionId }
            $Data = $1.PROPERTIES

            $Obj = @{
                'ID'              = $1.id;
                'Subscription'    = $Sub1.Name;
                'ResourceGroup'   = $1.RESOURCEGROUP;
                'Name'            = $1.NAME;
                'Location'        = $1.LOCATION;
                'SKU'             = $1.sku.name;
                'ScaleUnits'      = $Data.scaleUnits;
            }

            $Tmp += $Obj

        }
        $Tmp
    }
}
