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
            $Timecreated = if ($null -ne $Data.timeCreated) { [datetime]($Data.timeCreated) | Get-Date -Format "yyyy-MM-dd HH:mm" } else { 'Unknown' }
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
                # Migration phase: a CustomerKey / PlatformAndCustomerKeys disk is encrypted
                # with a customer-managed key (referenced by the disk-encryption-set below).
                # That key must be available / re-wrapped before the disk can be migrated;
                # platform-key disks need no key prep. Surfaced for AWS migration planning.
                'EncryptionType'        = $Data.encryption.type;
                'DiskEncryptionSet'     = if (![string]::IsNullOrEmpty($Data.encryption.diskEncryptionSetId) -and $null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { if ($ResourceIdDictionary.ContainsKey($Data.encryption.diskEncryptionSetId)) { $ResourceIdDictionary[$Data.encryption.diskEncryptionSetId] } else { 'obfuscated' } } else { $Data.encryption.diskEncryptionSetId };
            }

            $Tmp += $Obj
        }

        $Tmp
    }
}
