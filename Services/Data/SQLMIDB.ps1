param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $SQLSERVERMIDB = $Resources | Where-Object { $_.TYPE -eq 'microsoft.sql/managedinstances/databases' }

    if ($SQLSERVERMIDB)
    {
        $tmp = @()

        foreach ($1 in $SQLSERVERMIDB)
        {
            $sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $data = $1.PROPERTIES

            $obj = @{
                'ID'                        = $1.id;
                'Subscription'              = $sub1.Name;
                'ManagedInstance'           = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { $miParentId = ($1.id -split '/databases/')[0]; if ($ResourceIdDictionary.ContainsKey($miParentId)) { $ResourceIdDictionary[$miParentId] } else { 'obfuscated' } } else { $1.id.split("/")[8] };
                'Name'                      = $1.NAME;
                'Collation'                 = $data.collation;
                'CreationDate'              = $data.creationDate;
                'DefaultSecondaryLocation'  = $data.defaultSecondaryLocation;
                'Status'                    = $data.status;
            }

            $tmp += $obj
        }

        $tmp
    }
}
