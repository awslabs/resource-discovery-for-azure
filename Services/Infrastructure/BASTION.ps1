param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $BASTION = $Resources | Where-Object { $_.TYPE -eq 'microsoft.network/bastionhosts' }

    if ($BASTION)
    {
        $tmp = @()

        foreach ($1 in $BASTION)
        {
            $sub1 = $SUB | Where-Object { $_.Id -eq $1.subscriptionId }
            $data = $1.PROPERTIES

            $obj = @{
                'ID'              = $1.id;
                'Subscription'    = $sub1.Name;
                'ResourceGroup'   = $1.RESOURCEGROUP;
                'Name'            = $1.NAME;
                'Location'        = $1.LOCATION;
                'SKU'             = $1.sku.name;
                'ScaleUnits'      = $data.scaleUnits;
            }

            $tmp += $obj

        }
        $tmp
    }
}
