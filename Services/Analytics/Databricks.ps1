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
            # A missing value, or one that does not convert to a date, is 'Unknown'
            # rather than an exception that fails the whole collector.
            # A valid value is written in UTC on every host; one with no zone is taken as UTC.
            $Timecreated = try { if ($null -ne $Timecreated) { [datetime]::Parse($Timecreated, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]'AdjustToUniversal, AssumeUniversal').ToString("yyyy-MM-dd HH:mm") } else { 'Unknown' } } catch { 'Unknown' }

            $Obj = @{
                'ID'                        = $1.id;
                'Subscription'              = $Sub1.Name;
                'ResourceGroup'             = $1.RESOURCEGROUP;
                'Name'                      = $1.NAME;
                'Location'                  = $1.LOCATION;
                'Sku'               = $Sku.name;
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
