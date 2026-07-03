param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing') 
{
    $SQLSERVERMI = $Resources | Where-Object { $_.TYPE -eq 'microsoft.sql/managedInstances' }
    $SQLSERVERMIDB = $Resources | Where-Object { $_.TYPE -eq 'microsoft.sql/managedinstances/databases' }

    if($SQLSERVERMI)
    {
        $tmp = @()

        foreach ($1 in $SQLSERVERMI) 
        {
            $sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $data = $1.PROPERTIES
            $databases = $SQLSERVERMIDB | Where-Object { $_.Id -contains $1.Id }

            $obj = @{
                'ID'                            = $1.id;
                'Subscription'                  = $sub1.Name;
                'ResourceGroup'                 = $1.RESOURCEGROUP;
                'Name'                          = $1.NAME;
                'Location'                      = $1.LOCATION;
                'SkuName'                       = $1.sku.Name;
                'SkuCapacity'                   = $1.sku.capacity;
                'SkuTier'                       = $1.sku.tier;
                'SkuFamily'                     = $1.sku.family;
                'InstancePoolName'              = if (![string]::IsNullOrEmpty($data.instancePoolId) -and $null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { if ($ResourceIdDictionary.ContainsKey($data.instancePoolId)) { $ResourceIdDictionary[$data.instancePoolId] } else { 'obfuscated' } } else { $data.instancePoolId };
                'vCores'                        = $data.vCores;
                'StorageGB'                     = $data.storageSizeInGB;
                'StorageAccountType'            = $data.storageAccountType;
                'LicenseType'                   = $data.licenseType;
                'State'                         = $data.state;
                'ManagedInstanceCreateMode'     = $data.managedInstanceCreateMode;
                'ZoneRedundant'                 = $data.zoneRedundant;
                'Databases'                     = if ($null -ne $databases) { $databases.Count } else { '0' }
            }
            
            $tmp += $obj        
        }
        
        $tmp
    }
}
