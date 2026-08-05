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
            $Timecreated = try { if ($null -ne $Data.createdDateTime) { [datetime]($Data.createdDateTime) | Get-Date -Format "yyyy-MM-dd HH:mm" } else { 'Unknown' } } catch { 'Unknown' }

            $Obj = @{
                'ID'                        = $1.id;
                'Subscription'              = $Sub1.Name;
                'ResourceGroup'             = $1.RESOURCEGROUP;
                'Name'                      = $1.NAME;
                'Location'                  = $1.LOCATION;
                'Sku'                       = $Sku.name;
                # ManagedResourceGroupId is usually set, but below we make sure it's there before we
                # split it, otherwise a missing or malformed value crashes the subscription.
                'ManagedResourceGroup'      = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { 'obfuscated' } elseif ([string]::IsNullOrEmpty($Data.managedResourceGroupId)) { $null } else { $Data.managedResourceGroupId.split('/')[4] };
                'StorageAccount'            = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { 'obfuscated' } else { $Data.parameters.storageAccountName.value };
                'StorageAccountSKU'         = $Data.parameters.storageAccountSkuName.value;
                'CreatedTime'               = $Timecreated;
                # Migration phase: the identity type the workspace uses to access its managed
                # storage (e.g. SystemAssigned) affects how storage access is re-established at
                # the target. Only the identity TYPE is emitted - never principalId/tenantId
                # (those are real GUIDs). Surfaced for AWS migration planning.
                'StorageAccountIdentityType' = $Data.storageAccountIdentity.type;
            }

            $Tmp += $Obj
        }

        $Tmp
    }
}
