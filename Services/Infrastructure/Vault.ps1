param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $VAULT = $Resources | Where-Object { $_.TYPE -eq 'microsoft.keyvault/vaults' }

    if ($VAULT)
    {
        $Tmp = @()

        foreach ($1 in $VAULT)
        {
            $Sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $Data = $1.PROPERTIES
            if ([string]::IsNullOrEmpty($Data.enableSoftDelete)) { $Soft = $false }else { $Soft = $Data.enableSoftDelete }

            $Obj = @{
                'ID'                            = $1.id;
                'Subscription'                  = $Sub1.Name;
                'ResourceGroup'                 = $1.RESOURCEGROUP;
                'Name'                          = $1.NAME;
                'Location'                      = $1.LOCATION;
                'SKUFamily'                     = $Data.sku.family;
                'SKU'                           = $Data.sku.name;
            }

            $Tmp += $Obj
        }

        $Tmp
    }
}
