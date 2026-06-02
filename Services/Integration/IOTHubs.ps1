param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing') 
{
    $IOTHubs = $Resources | Where-Object { $_.TYPE -eq 'microsoft.devices/iothubs' }

    if($IOTHubs)
    {
        $tmp = @()

        foreach ($1 in $IOTHubs) 
        {
            $sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $data = $1.PROPERTIES
            
            foreach ($loc in $data.locations) 
            {
                $obj = @{
                    'ID'                                = $1.id;
                    'Subscription'                      = $sub1.Name;
                    'ResourceGroup'                     = $1.RESOURCEGROUP;
                    'Name'                              = $1.NAME;                                    
                    'SKU'                               = $data.sku.name;
                    'SKUTier'                           = $data.sku.tier;
                    'Location'                          = $loc.location;
                    'Role'                              = $loc.role;
                    'State'                             = $data.state;
                    'EventRetentionTimeInDays'          = [string]$data.eventHubEndpoints.events.retentionTimeInDays;
                    'EventPartitionCount'               = [string]$data.eventHubEndpoints.events.partitionCount;
                    'EventsPath'                        = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { 'obfuscated' } else { [string]$data.eventHubEndpoints.events.path };
                    'MaxDeliveryCount'                  = [string]$data.cloudToDevice.maxDeliveryCount;
                    'HostName'                          = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { 'obfuscated' } else { $data.hostName };
                }

                $tmp += $obj
            }              
        }

        $tmp
    }
}
