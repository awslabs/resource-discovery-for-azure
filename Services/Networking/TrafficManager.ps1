param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $TrafficManager = $Resources | Where-Object { $_.TYPE -eq 'microsoft.network/trafficmanagerprofiles' }

    if ($TrafficManager)
    {
        $Tmp = @()

        foreach ($1 in $TrafficManager)
        {
            $Sub1 = $SUB | Where-Object { $_.Id -eq $1.subscriptionId }
            $Data = $1.PROPERTIES

            $Obj = @{
                'ID'                               = $1.id;
                'Subscription'                     = $Sub1.Name;
                'ResourceGroup'                    = $1.RESOURCEGROUP;
                'Name'                             = $1.NAME;
                'Status'                           = $Data.profilestatus;
                'RoutingMethod'                    = $Data.trafficroutingmethod;
                'MonitorStatus'                    = $Data.monitorconfig.profilemonitorstatus;
            }

            $Tmp += $Obj
        }

        $Tmp
    }
}
