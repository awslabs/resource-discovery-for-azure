param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $SQLSERVERMIDB = $Resources | Where-Object { $_.TYPE -eq 'microsoft.sql/managedinstances/databases' }

    if ($SQLSERVERMIDB)
    {
        $Tmp = @()

        foreach ($1 in $SQLSERVERMIDB)
        {
            $Sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $Data = $1.PROPERTIES

            $Obj = @{
                'ID'                        = $1.id;
                'Subscription'              = $Sub1.Name;
                'ManagedInstance'           = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { $MiParentId = ($1.id -split '/databases/')[0]; if ($ResourceIdDictionary.ContainsKey($MiParentId)) { $ResourceIdDictionary[$MiParentId] } else { 'obfuscated' } } else { $1.id.split("/")[8] };
                'Name'                      = $1.NAME;
                'Collation'                 = $Data.collation;
                'CreationDate'              = $Data.creationDate;
                'DefaultSecondaryLocation'  = $Data.defaultSecondaryLocation;
                'Status'                    = $Data.status;
            }

            $Tmp += $Obj
        }

        $Tmp
    }
}
