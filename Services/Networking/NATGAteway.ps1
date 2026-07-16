param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $NATGAT = $Resources | Where-Object { $_.TYPE -eq 'microsoft.network/natgateways' }

    if ($NATGAT)
    {
        $Tmp = @()

        foreach ($1 in $NATGAT)
        {
            $Sub1 = $SUB | Where-Object { $_.Id -eq $1.subscriptionId }
            $Data = $1.PROPERTIES

            $Obj = @{
                'ID'                    = $1.id;
                'Subscription'          = $Sub1.Name;
                'ResourceGroup'         = $1.RESOURCEGROUP;
                'Name'                  = $1.NAME;
                'Location'              = $1.LOCATION;
                'SKU'                   = $1.sku.name;
                'IdleTimeoutMin'        = $Data.idleTimeoutInMinutes;
            }

            $Tmp += $Obj
        }

        $Tmp
    }
}
