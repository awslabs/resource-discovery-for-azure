param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $Snapshots = $Resources | Where-Object { $_.TYPE -eq 'Microsoft.Compute/snapshots' }

    if ($Snapshots)
    {
        $Tmp = @()

        foreach ($snapshot in $Snapshots)
        {
            $Sub1 = $SUB | Where-Object { $_.Id -eq $snapshot.subscriptionId }
            $Data = $snapshot.PROPERTIES
            $Timecreated = $Data.timeCreated
            # A missing value, or one that does not convert to a date, is 'Unknown'
            # rather than an exception that fails the whole collector.
            # A valid value is written in UTC on every host; one with no zone is taken as UTC.
            $Timecreated = try { if ($null -ne $Timecreated) { [datetime]::Parse($Timecreated, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]'AdjustToUniversal, AssumeUniversal').ToString("yyyy-MM-dd HH:mm") } else { 'Unknown' } } catch { 'Unknown' }

            $Obj = @{
                'ID'                                    = $snapshot.id;
                'Subscription'                          = $Sub1.Name;
                'ResourceGroup'                         = $snapshot.RESOURCEGROUP;
                'Name'                                  = $snapshot.NAME;
                'Location'                              = $snapshot.LOCATION;
                'Size'                                  = $Data.diskSizeGB;
                'Sku'                                   = $snapshot.sku.name;
                'State'                                 = $Data.provisioningState;
                'OS'                                    = $Data.osType;
                'Incremental'                           = $Data.incremental;
                'CreatedTime'                           = $Timecreated;
                'SourceResourceId'                      = if (![string]::IsNullOrEmpty($Data.creationData.sourceResourceId) -and $null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { if ($ResourceIdDictionary.ContainsKey($Data.creationData.sourceResourceId)) { $ResourceIdDictionary[$Data.creationData.sourceResourceId] } else { 'obfuscated' } } else { $Data.creationData.sourceResourceId };
            }

            $Tmp += $Obj
        }

        $Tmp
    }
}
