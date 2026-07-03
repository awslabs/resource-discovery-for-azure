param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing') 
{
    $TrafficManager = $Resources | Where-Object { $_.TYPE -eq 'microsoft.network/trafficmanagerprofiles' }

    if($TrafficManager)
    {
        $tmp = @()

        foreach ($1 in $TrafficManager) 
        {
            $sub1 = $SUB | Where-Object { $_.Id -eq $1.subscriptionId }
            $data = $1.PROPERTIES
            
            $obj = @{
                'ID'                               = $1.id;
                'Subscription'                     = $sub1.Name;
                'ResourceGroup'                    = $1.RESOURCEGROUP;
                'Name'                             = $1.NAME;
                'Status'                           = $data.profilestatus;
                'RoutingMethod'                    = $data.trafficroutingmethod;
                'MonitorStatus'                    = $data.monitorconfig.profilemonitorstatus;                            
            }

            $tmp += $obj
        }

        $tmp
    }
}
