param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $VM = $Resources | Where-Object { $_.TYPE -eq 'microsoft.compute/virtualmachines' }
    $AVD = $Resources | Where-Object { $_.TYPE -eq 'microsoft.desktopvirtualization/hostpools' }
    $Hosts = $Resources | Where-Object { $_.TYPE -eq 'microsoft.desktopvirtualization/hostpools/sessionhosts' }

    if ($AVD)
    {
        $Tmp = @()

        foreach ($1 in $AVD)
        {
            $Sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $Data = $1.PROPERTIES

            $Sessionhosts = @()
            foreach ($h in $Hosts)
            {
                $N = $h.ID -split '/sessionhosts/'

                if ($N[0] -eq $1.id )
                {
                    $Sessionhosts += $h
                }
            }

            foreach ($2 in $Sessionhosts)
            {
                $Vmsessionhosts = $VM | Where-Object { $_.ID -eq $2.properties.resourceId }

                # Resolve HostId and Hostname
                $HostIdValue = $null
                $HostnameValue = $null
                if (![string]::IsNullOrEmpty($Vmsessionhosts.Id))
                {
                    if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0)
                    {
                        # Obfuscation ON: never emit the real VM id or name. Use the
                        # dictionary value when the backing VM was indexed, else the
                        # lossy 'obfuscated' fallback used elsewhere in the codebase.
                        $HostIdValue = if ($ResourceIdDictionary.ContainsKey($Vmsessionhosts.Id)) { $ResourceIdDictionary[$Vmsessionhosts.Id] } else { 'obfuscated' }
                        # Hostname must reuse the SAME name token the backing VM's inventory 'Name' gets, or the AVD row
                        # can't join back to its VM. $Global:ResourceNameDictionary (keyed by real VM id) is populated up-front; else 'obfuscated'.
                        $HostnameValue = if ($null -ne $Global:ResourceNameDictionary -and $Global:ResourceNameDictionary.ContainsKey($Vmsessionhosts.Id)) { $Global:ResourceNameDictionary[$Vmsessionhosts.Id] } else { 'obfuscated' }
                    }
                    else
                    {
                        $HostIdValue = $Vmsessionhosts.Id
                        $HostnameValue = $Vmsessionhosts.Name
                    }
                }

                $Obj = @{
                    'ID'                 = $1.id;
                    'Subscription'       = $Sub1.Name;
                    'ResourceGroup'      = $1.RESOURCEGROUP;
                    'Name'               = $1.NAME;
                    'Location'           = $1.LOCATION;
                    'HostPoolType'       = $Data.hostPoolType;
                    'LoadBalancer'       = $Data.loadBalancerType;
                    'MaxSessionLimit'    = $Data.maxSessionLimit;
                    'PreferredAppGroup'  = $Data.preferredAppGroupType;
                    'AVDAgentVersion'    = $2.properties.agentVersion;
                    'AllowNewSession'    = $2.properties.allowNewSession;
                    'UpdateStatus'       = $2.properties.updateState;
                    'HostId'             = $HostIdValue;
                    'Hostname'           = $HostnameValue;
                    'VMSize'             = $Vmsessionhosts.properties.hardwareProfile.vmsize;
                    'OSType'             = $Vmsessionhosts.properties.storageProfile.osdisk.ostype;
                    'VMDiskType'         = $Vmsessionhosts.properties.storageProfile.osdisk.managedDisk.storageAccountType;
                    'HostStatus'         = $2.properties.status;
                    'OSVersion'          = $2.properties.osVersion;
                }

                $Tmp += $Obj
            }
        }

        $Tmp
    }
}
