param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $Disks = $Resources | Where-Object { $_.TYPE -eq 'microsoft.compute/disks' }

    if ($Disks)
    {
        $Tmp = @()

        foreach ($disk in $Disks)
        {
            $Sub1 = $SUB | Where-Object { $_.Id -eq $disk.subscriptionId }
            $Data = $disk.PROPERTIES
            $Timecreated = $Data.timeCreated
            # A missing value, or one that does not convert to a date, is 'Unknown'
            # rather than an exception that fails the whole collector.
            # A valid value is written in UTC on every host; one with no zone is taken as UTC.
            $Timecreated = try { if ($null -ne $Timecreated) { [datetime]::Parse($Timecreated, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]'AdjustToUniversal, AssumeUniversal').ToString("yyyy-MM-dd HH:mm") } else { 'Unknown' } } catch { 'Unknown' }
            $SKU = $disk.SKU

            $Obj = @{
                'ID'                    = $disk.id;
                'Subscription'          = $Sub1.Name;
                'ResourceGroup'         = $disk.RESOURCEGROUP;
                'Name'                  = $disk.NAME;
                'State'                 = $Data.diskState;
                'AssociatedResource'    = if (![string]::IsNullOrEmpty($disk.MANAGEDBY) -and $null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { if ($ResourceIdDictionary.ContainsKey($disk.MANAGEDBY)) { $ResourceIdDictionary[$disk.MANAGEDBY] } else { 'obfuscated' } } else { if (![string]::IsNullOrEmpty($disk.MANAGEDBY)) { $disk.MANAGEDBY.split('/')[8] } else { $null } };
                'Location'              = $disk.LOCATION;
                'SKU'                   = $SKU.Name;
                'Tier'                  = $Data.Tier;
                'Size'                  = $Data.diskSizeGB;
                'OSType'                = $Data.osType;
                'DiskIOPS'              = $Data.diskIOPSReadWrite;
                'DiskMBps'              = $Data.diskMBpsReadWrite;
                'CreatedTime'           = $Timecreated;
            }

            $Tmp += $Obj
        }

        $Tmp
    }
}
