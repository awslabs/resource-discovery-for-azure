param($Sub, $Resources, $Task, $ResourceIdDictionary)

if($Task -eq 'Processing') 
{
    $DataBricks = $Resources | Where-Object { $_.TYPE -eq 'microsoft.databricks/workspaces' }

    if($DataBricks)
    {
        $tmp = @()

        foreach ($1 in $DataBricks) 
        {
            $sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $data = $1.PROPERTIES
            $sku = $1.SKU
            $timecreated = $data.createdDateTime
            $timecreated = [datetime]$timecreated
            $timecreated = $timecreated.ToString("yyyy-MM-dd HH:mm")
            
            $obj = @{
                'ID'                        = $1.id;
                'Subscription'              = $sub1.Name;
                'ResourceGroup'             = $1.RESOURCEGROUP;
                'Name'                      = $1.NAME;
                'Location'                  = $1.LOCATION;
                'PricingTier'               = $sku.name;
                # ManagedResourceGroupId is theoretically always set on a workspace, but
                # split('/')[4] still fails if the property is missing or malformed.
                # Guard cheaply rather than crash the whole subscription.
                'ManagedResourceGroup'      = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { 'obfuscated' } elseif ([string]::IsNullOrEmpty($data.managedResourceGroupId)) { $null } else { $data.managedResourceGroupId.split('/')[4] };
                'StorageAccount'            = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { 'obfuscated' } else { $data.parameters.storageAccountName.value };
                'StorageAccountSKU'         = $data.parameters.storageAccountSkuName.value;
                'CreatedTime'               = $timecreated;
            }
            
            $tmp += $obj
        }

        $tmp
    }
}
