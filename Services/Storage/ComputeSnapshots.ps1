param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $snapshots = $Resources | Where-Object { $_.TYPE -eq 'Microsoft.Compute/snapshots' }

    if ($snapshots)
    {
        $tmp = @()

        foreach ($snapshot in $snapshots)
        {
            $sub1 = $SUB | Where-Object { $_.Id -eq $snapshot.subscriptionId }
            $data = $snapshot.PROPERTIES
            $timecreated = $data.timeCreated
            $timecreated = [datetime]$timecreated
            $timecreated = $timecreated.ToString("yyyy-MM-dd HH:mm")

            $obj = @{
                'ID'                                    = $snapshot.id;
                'Subscription'                          = $sub1.Name;
                'ResourceGroup'                         = $snapshot.RESOURCEGROUP;
                'Name'                                  = $snapshot.NAME;
                'Location'                              = $snapshot.LOCATION;
                'Size'                                  = $data.diskSizeGB;
                'Sku'                                   = $snapshot.sku.name;
                'State'                                 = $data.provisioningState;
                'OS'                                    = $data.osType;
                'Incremental'                           = $data.incremental;
                'CreatedTime'                           = $timecreated;
                'SourceResourceId'                      = if (![string]::IsNullOrEmpty($data.creationData.sourceResourceId) -and $null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { if ($ResourceIdDictionary.ContainsKey($data.creationData.sourceResourceId)) { $ResourceIdDictionary[$data.creationData.sourceResourceId] } else { 'obfuscated' } } else { $data.creationData.sourceResourceId };
            }

            $tmp += $obj
        }

        $tmp
    }
}
