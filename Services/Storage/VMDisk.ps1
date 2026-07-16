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
            $Timecreated = [datetime]$Timecreated
            $Timecreated = $Timecreated.ToString("yyyy-MM-dd HH:mm")
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
