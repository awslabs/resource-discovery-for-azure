param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $Storageacc = $Resources | Where-Object { $_.TYPE -eq 'microsoft.storage/storageaccounts' }

    if ($Storageacc)
    {
        $Tmp = @()

        foreach ($1 in $Storageacc)
        {
            $Sub1 = $SUB | Where-Object { $_.Id -eq $1.subscriptionId }
            $Data = $1.PROPERTIES
            $Timecreated = if ($null -ne $Data.creationTime) { [datetime]($Data.creationTime) | Get-Date -Format "yyyy-MM-dd HH:mm" } else { 'Unknown' }

            if ($Data.isHnsEnabled) { $HnsEnabled = $true } else { $HnsEnabled = $false }

            $Obj = @{
                'ID'                                   = $1.id;
                'Subscription'                         = $Sub1.Name;
                'ResourceGroup'                        = $1.RESOURCEGROUP;
                'Name'                                 = $1.NAME;
                'Location'                             = $1.LOCATION;
                'SKU'                                  = $1.sku.name;
                'Tier'                                 = $1.sku.tier;
                'Kind'                                 = $1.kind;
                'AccessTier'                           = $Data.accessTier;
                'PrimaryLocation'                      = $Data.primaryLocation;
                'StatusOfPrimary'                      = $Data.statusOfPrimary;
                'HierarchicalNamespace'                = $HnsEnabled;
                'CreatedTime'                          = $Timecreated;
                # Migration phase: keySource = 'Microsoft.Keyvault' means the account is
                # encrypted with a customer-managed key (the CMK must be handled before
                # migration); 'Microsoft.Storage' is the platform-managed default and needs
                # no key prep. Surfaced for AWS migration planning.
                'EncryptionKeySource'                  = $Data.encryption.keySource;
            }

            $Tmp += $Obj
        }

        $Tmp
    }
}
