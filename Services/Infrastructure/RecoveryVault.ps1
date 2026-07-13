param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $RECOVAULT = $Resources | Where-Object { $_.TYPE -eq 'microsoft.recoveryservices/vaults' }

    if ($RECOVAULT)
    {
        $Tmp = @()

        foreach ($1 in $RECOVAULT)
        {
            $Sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $Data = $1.PROPERTIES

            $Obj = @{
                'ID'                 = $1.id;
                'Subscription'       = $Sub1.Name;
                'ResourceGroup'      = $1.RESOURCEGROUP;
                'Name'               = $1.NAME;
                'Location'           = $1.LOCATION;
                'SKUName'            = $1.sku.name;
                'SKUTier'            = $1.sku.tier;
            }

            $Tmp += $Obj
        }

        $Tmp
    }
}
