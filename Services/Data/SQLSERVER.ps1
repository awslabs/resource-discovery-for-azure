param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $SQLSERVER = $Resources | Where-Object { $_.TYPE -eq 'microsoft.sql/servers' }

    if ($SQLSERVER)
    {
        $Tmp = @()

        foreach ($1 in $SQLSERVER)
        {
            $Sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $Data = $1.PROPERTIES

            $Obj = @{
                'ID'                    = $1.id;
                'Subscription'          = $Sub1.Name;
                'ResourceGroup'         = $1.RESOURCEGROUP;
                'Name'                  = $1.NAME;
                'Location'              = $1.LOCATION;
                'Kind'                  = $1.kind;
                'State'                 = $Data.state;
                'Version'               = $Data.version;
                'ZoneRedundant'         = $1.zones;
            }

            $Tmp += $Obj
        }

        $Tmp
    }
}
