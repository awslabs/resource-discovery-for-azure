param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $disks = $Resources | Where-Object {$_.TYPE -eq 'microsoft.compute/disks'}

    if($disks)
    {
        $tmp = @() 
                   
        foreach ($disk in $disks) 
        {
            $sub1 = $SUB | Where-Object { $_.Id -eq $disk.subscriptionId }
            $data = $disk.PROPERTIES
            $timecreated = $data.timeCreated
            $timecreated = [datetime]$timecreated
            $timecreated = $timecreated.ToString("yyyy-MM-dd HH:mm")
            $SKU = $disk.SKU
            
            $obj = @{
                'ID'                    = $disk.id;
                'Subscription'          = $sub1.Name;
                'ResourceGroup'         = $disk.RESOURCEGROUP;
                'Name'                  = $disk.NAME;
                'State'                 = $data.diskState;
                'AssociatedResource'    = if (![string]::IsNullOrEmpty($disk.MANAGEDBY) -and $null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { if ($ResourceIdDictionary.ContainsKey($disk.MANAGEDBY)) { $ResourceIdDictionary[$disk.MANAGEDBY] } else { 'obfuscated' } } else { if(![string]::IsNullOrEmpty($disk.MANAGEDBY)){ $disk.MANAGEDBY.split('/')[8] } else { $null } };
                'Location'              = $disk.LOCATION;
                'SKU'                   = $SKU.Name;
                'Tier'                  = $data.Tier;
                'Size'                  = $data.diskSizeGB;
                'OSType'                = $data.osType;
                'DiskIOPS'              = $data.diskIOPSReadWrite;
                'DiskMBps'              = $data.diskMBpsReadWrite;
                'CreatedTime'           = $timecreated;   
            }

            $tmp += $obj
        }

        $tmp
    }
}
