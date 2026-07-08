param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing') 
{
    $VM =  $Resources | Where-Object {$_.TYPE -eq 'microsoft.compute/virtualmachines'}
    $AVD = $Resources | Where-Object { $_.TYPE -eq 'microsoft.desktopvirtualization/hostpools' }
    $Hosts = $Resources | Where-Object { $_.TYPE -eq 'microsoft.desktopvirtualization/hostpools/sessionhosts' }

    if($AVD)
    {
        $tmp = @()

        foreach ($1 in $AVD) 
        {
            $sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $data = $1.PROPERTIES

            $sessionhosts = @()
            foreach ($h in $Hosts)
            {
                $n = $h.ID -split '/sessionhosts/' 

                if ($n[0] -eq $1.id ) 
                {
                    $sessionhosts += $h                    
                }
            }
            
            foreach ($2 in $sessionhosts)
            {
                $vmsessionhosts = $VM | Where-Object { $_.ID -eq $2.properties.resourceId}

                # Resolve HostId and Hostname
                $hostIdValue = $null
                $hostnameValue = $null
                if (![string]::IsNullOrEmpty($vmsessionhosts.Id)) {
                    if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) {
                        # Obfuscation ON: never emit the real VM id or name. Use the
                        # dictionary value when the backing VM was indexed, else the
                        # lossy 'obfuscated' fallback used elsewhere in the codebase.
                        $hostIdValue = if ($ResourceIdDictionary.ContainsKey($vmsessionhosts.Id)) { $ResourceIdDictionary[$vmsessionhosts.Id] } else { 'obfuscated' }
                        # Deterministic hostname: derive from VM ID hash so same input = same output
                        $hnPrefix = $hostIdValue.Split('_')[0]
                        $sha = [System.Security.Cryptography.SHA256]::Create()
                        try {
                            $hnHash = [System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($vmsessionhosts.Id + '_hostname'))).Replace('-','').Substring(0,32).ToLower()
                        } finally { $sha.Dispose() }
                        $hostnameValue = $hnPrefix + '_' + $hnHash.Substring(0,8) + '-' + $hnHash.Substring(8,4) + '-' + $hnHash.Substring(12,4) + '-' + $hnHash.Substring(16,4) + '-' + $hnHash.Substring(20,12)
                    } else {
                        $hostIdValue = $vmsessionhosts.Id
                        $hostnameValue = $vmsessionhosts.Name
                    }
                }

                $obj = @{
                    'ID'                 = $1.id;
                    'Subscription'       = $sub1.Name;
                    'ResourceGroup'      = $1.RESOURCEGROUP;
                    'Name'               = $1.NAME;
                    'Location'           = $1.LOCATION;
                    'HostPoolType'       = $data.hostPoolType;
                    'LoadBalancer'       = $data.loadBalancerType;
                    'MaxSessionLimit'    = $data.maxSessionLimit;
                    'PreferredAppGroup'  = $data.preferredAppGroupType;
                    'AVDAgentVersion'    = $2.properties.agentVersion;
                    'AllowNewSession'    = $2.properties.allowNewSession;
                    'UpdateStatus'       = $2.properties.updateState;
                    'HostId'             = $hostIdValue;
                    'Hostname'           = $hostnameValue;
                    'VMSize'             = $vmsessionhosts.properties.hardwareProfile.vmsize;
                    'OSType'             = $vmsessionhosts.properties.storageProfile.osdisk.ostype;
                    'VMDiskType'         = $vmsessionhosts.properties.storageProfile.osdisk.managedDisk.storageAccountType;
                    'HostStatus'         = $2.properties.status;
                    'OSVersion'          = $2.properties.osVersion;
                }

                $tmp += $obj
            }
        }

        $tmp
    }
}
