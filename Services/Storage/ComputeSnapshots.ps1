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
            $Timecreated = [datetime]$Timecreated
            $Timecreated = $Timecreated.ToString("yyyy-MM-dd HH:mm")

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
