param(
    $Sub,
    $Resources,
    $Task,
    $ResourceIdDictionary
)

if ($Task -eq 'Processing')
{
    $Vault = $Resources | Where-Object { $_.TYPE -eq 'microsoft.keyvault/vaults' }

    if ($Vault)
    {
        $Tmp = @()

        foreach ($1 in $Vault)
        {
            $Sub1 = $Sub | Where-Object { $_.id -eq $1.subscriptionId }
            $Data = $1.PROPERTIES
            # https://learn.microsoft.com/en-us/azure/templates/microsoft.keyvault/vaults?pivots=deployment-language-bicep
            <#
                Property to specify whether the 'soft delete' functionality is enabled for this key vault.
                If it's not set to any value(true or false) when creating new key vault, it will be set to true by default.
                Once set to true, it cannot be reverted to false.
                flags which vaults are protected and which aren't, so the migration assessment can quantify security risk in the source environment.
            #>
            if ([string]::IsNullOrEmpty($Data.enableSoftDelete))
            {
                $Soft = $false
            }
            else
            {
                $Soft = $Data.enableSoftDelete
            }
            # Purge Protection
            if ([string]::IsNullOrEmpty($Data.enablePurgeProtection))
            {
                $Purge = $false
            }
            else
            {
                $Purge = $Data.enablePurgeProtection
            }

            $Obj = @{
                'ID'                            = $1.id;
                'Subscription'                  = $Sub1.Name;
                'ResourceGroup'                 = $1.RESOURCEGROUP;
                'Name'                          = $1.NAME;
                'Location'                      = $1.LOCATION;
                'SKUFamily'                     = $Data.sku.family;
                'SKU'                           = $Data.sku.name;
                'EnableSoftDelete'              = $Soft;
                'EnablePurgeProtection'         = $Purge
            }

            $Tmp += $Obj
        }

        $Tmp
    }
}
