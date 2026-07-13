param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $SQLSERVER = $Resources | Where-Object { $_.TYPE -eq 'microsoft.sql/servers' }

    if ($SQLSERVER)
    {
        $tmp = @()

        foreach ($1 in $SQLSERVER)
        {
            $sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $data = $1.PROPERTIES

            $obj = @{
                'ID'                    = $1.id;
                'Subscription'          = $sub1.Name;
                'ResourceGroup'         = $1.RESOURCEGROUP;
                'Name'                  = $1.NAME;
                'Location'              = $1.LOCATION;
                'Kind'                  = $1.kind;
                'State'                 = $data.state;
                'Version'               = $data.version;
                'ZoneRedundant'         = $1.zones;
            }

            $tmp += $obj
        }

        $tmp
    }
}
