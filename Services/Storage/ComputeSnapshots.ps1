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
            $Timecreated = if ($null -ne $Data.timeCreated) { [datetime]($Data.timeCreated) | Get-Date -Format "yyyy-MM-dd HH:mm" } else { 'Unknown' }

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
                # Migration phase: a CustomerKey / PlatformAndCustomerKeys snapshot is encrypted
                # with a customer-managed key (referenced by the disk-encryption-set below); the
                # key must be handled before the snapshot can be migrated. Surfaced for AWS
                # migration planning.
                'EncryptionType'                        = $Data.encryption.type;
                'DiskEncryptionSet'                     = if (![string]::IsNullOrEmpty($Data.encryption.diskEncryptionSetId) -and $null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { if ($ResourceIdDictionary.ContainsKey($Data.encryption.diskEncryptionSetId)) { $ResourceIdDictionary[$Data.encryption.diskEncryptionSetId] } else { 'obfuscated' } } else { $Data.encryption.diskEncryptionSetId };
            }

            $Tmp += $Obj
        }

        $Tmp
    }
}
