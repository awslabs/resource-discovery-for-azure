param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $CONTAINER = $Resources | Where-Object {$_.TYPE -eq 'microsoft.containerinstance/containergroups'}

    if($CONTAINER)
    {
        $tmp = @()

        foreach ($1 in $CONTAINER) 
        {
            $sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $data = $1.PROPERTIES
            
            foreach ($2 in $data.containers) 
            {
                $obj = @{
                    'ID'                  = $1.id;
                    'Subscription'        = $sub1.Name;
                    'ResourceGroup'       = $1.RESOURCEGROUP;
                    'Name'                = $1.NAME;
                    'Location'            = $1.LOCATION;
                    'Sku'                 = $data.Sku;
                    'InstanceOSType'      = $data.osType;
                    'ContainerName'       = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { 'obfuscated' } else { $2.name };
                    'ContainerState'      = $2.properties.instanceView.currentState.state;
                    'ContainerImage'      = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { 'obfuscated' } else { [string]$2.properties.image };
                    'RestartCount'        = $2.properties.instanceView.restartCount;
                    'StartTime'           = $2.properties.instanceView.currentState.startTime;
                    'Command'             = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { $null } else { [string]$2.properties.command };
                    'RequestCPU'          = $2.properties.resources.requests.cpu;
                    'RequestMemoryGB'     = $2.properties.resources.requests.memoryInGB;
                }

                $tmp += $obj
            }
        }

        $tmp
    }
}
