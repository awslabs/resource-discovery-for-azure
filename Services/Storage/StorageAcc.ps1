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
            $Timecreated = $Data.creationTime
            $Timecreated = [datetime]$Timecreated
            $Timecreated = $Timecreated.ToString("yyyy-MM-dd HH:mm")

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
            }

            $Tmp += $Obj
        }

        $Tmp
    }
}
