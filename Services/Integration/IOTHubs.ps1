param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $IOTHubs = $Resources | Where-Object { $_.TYPE -eq 'microsoft.devices/iothubs' }

    if ($IOTHubs)
    {
        $Tmp = @()

        foreach ($1 in $IOTHubs)
        {
            $Sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $Data = $1.PROPERTIES

            # A hub whose properties.locations is empty must still yield one row
            # (previously it was silently dropped). Normalize to a single null
            # entry so the hub appears with null Location/Role in that edge case.
            $Locations = @($Data.locations)
            if ($Locations.Count -eq 0) { $Locations = @($null) }

            foreach ($loc in $Locations)
            {
                $Obj = @{
                    'ID'                                = $1.id;
                    'Subscription'                      = $Sub1.Name;
                    'ResourceGroup'                     = $1.RESOURCEGROUP;
                    'Name'                              = $1.NAME;
                    'SKU'                               = $1.sku.name;
                    'SKUTier'                           = $1.sku.tier;
                    'Location'                          = if ($null -eq $loc) { $null } else { $loc.location };
                    'Role'                              = if ($null -eq $loc) { $null } else { $loc.role };
                    'State'                             = $Data.state;
                    'EventRetentionTimeInDays'          = [string]$Data.eventHubEndpoints.events.retentionTimeInDays;
                    'EventPartitionCount'               = [string]$Data.eventHubEndpoints.events.partitionCount;
                    'EventsPath'                        = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { Protect-FreeTextValue ([string]$Data.eventHubEndpoints.events.path) } else { [string]$Data.eventHubEndpoints.events.path };
                    'MaxDeliveryCount'                  = [string]$Data.cloudToDevice.maxDeliveryCount;
                    'HostName'                          = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { Protect-FreeTextValue $Data.hostName } else { $Data.hostName };
                }

                $Tmp += $Obj
            }
        }

        $Tmp
    }
}
