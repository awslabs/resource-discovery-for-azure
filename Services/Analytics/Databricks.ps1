param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $DataBricks = $Resources | Where-Object { $_.TYPE -eq 'microsoft.databricks/workspaces' }

    if ($DataBricks)
    {
        $Tmp = @()

        foreach ($1 in $DataBricks)
        {
            $Sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $Data = $1.PROPERTIES
            $Sku = $1.SKU
            $Timecreated = $Data.createdDateTime
            $Timecreated = [datetime]$Timecreated
            $Timecreated = $Timecreated.ToString("yyyy-MM-dd HH:mm")

            $Obj = @{
                'ID'                        = $1.id;
                'Subscription'              = $Sub1.Name;
                'ResourceGroup'             = $1.RESOURCEGROUP;
                'Name'                      = $1.NAME;
                'Location'                  = $1.LOCATION;
                'PricingTier'               = $Sku.name;
                # ManagedResourceGroupId is theoretically always set on a workspace, but
                # split('/')[4] still fails if the property is missing or malformed.
                # Guard cheaply rather than crash the whole subscription.
                'ManagedResourceGroup'      = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { 'obfuscated' } elseif ([string]::IsNullOrEmpty($Data.managedResourceGroupId)) { $null } else { $Data.managedResourceGroupId.split('/')[4] };
                'StorageAccount'            = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { 'obfuscated' } else { $Data.parameters.storageAccountName.value };
                'StorageAccountSKU'         = $Data.parameters.storageAccountSkuName.value;
                'CreatedTime'               = $Timecreated;
            }

            $Tmp += $Obj
        }

        $Tmp
    }
}
