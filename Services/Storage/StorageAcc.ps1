param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $Storageacc = $Resources | Where-Object { $_.TYPE -eq 'microsoft.storage/storageaccounts' }

    if ($Storageacc)
    {
        $Tmp = [System.Collections.Generic.List[object]]::new()

        foreach ($1 in $Storageacc)
        {
            $Sub1 = $SUB | Where-Object { $_.Id -eq $1.subscriptionId }
            $Data = $1.PROPERTIES
            $Timecreated = $Data.creationTime
            # A missing value, or one that does not convert to a date, is 'Unknown'
            # rather than an exception that fails the whole collector.
            # A valid value is written in UTC on every host; one with no zone is taken as UTC.
            $Timecreated = try { if ($null -ne $Timecreated) { [datetime]::Parse($Timecreated, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]'AdjustToUniversal, AssumeUniversal').ToString("yyyy-MM-dd HH:mm") } else { 'Unknown' } } catch { 'Unknown' }

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

            [void]$Tmp.Add($Obj)
        }

        $Tmp
    }
}
