param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $CONTAINER = $Resources | Where-Object { $_.TYPE -eq 'microsoft.containerinstance/containergroups' }

    if ($CONTAINER)
    {
        $Tmp = @()

        foreach ($1 in $CONTAINER)
        {
            $Sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $Data = $1.PROPERTIES

            foreach ($2 in $Data.containers)
            {
                $Obj = @{
                    'ID'                  = $1.id;
                    'Subscription'        = $Sub1.Name;
                    'ResourceGroup'       = $1.RESOURCEGROUP;
                    'Name'                = $1.NAME;
                    'Location'            = $1.LOCATION;
                    'Sku'                 = $Data.Sku;
                    'InstanceOSType'      = $Data.osType;
                    'ContainerName'       = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { Protect-FreeTextValue $2.name } else { $2.name };
                    'ContainerState'      = $2.properties.instanceView.currentState.state;
                    'ContainerImage'      = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { Protect-FreeTextValue ([string]$2.properties.image) } else { [string]$2.properties.image };
                    'RestartCount'        = $2.properties.instanceView.restartCount;
                    'StartTime'           = $2.properties.instanceView.currentState.startTime;
                    'Command'             = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { Protect-FreeTextValue ([string]$2.properties.command) } else { [string]$2.properties.command };
                    'RequestCPU'          = $2.properties.resources.requests.cpu;
                    'RequestMemoryGB'     = $2.properties.resources.requests.memoryInGB;
                }

                $Tmp += $Obj
            }
        }

        $Tmp
    }
}
