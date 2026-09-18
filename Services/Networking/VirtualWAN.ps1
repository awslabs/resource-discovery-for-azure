param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $VirtualWAN = $Resources | Where-Object { $_.TYPE -eq 'microsoft.network/virtualwans' }
    $VirtualHub = $Resources | Where-Object { $_.TYPE -eq 'microsoft.network/virtualhubs' }
    $VPNSite = $Resources | Where-Object { $_.TYPE -eq 'microsoft.network/vpnsites' }

    if ($VirtualWAN)
    {
        $Tmp = @()

        foreach ($1 in $VirtualWAN)
        {
            $Sub1 = $SUB | Where-Object { $_.Id -eq $1.subscriptionId }
            $Data = $1.PROPERTIES
            $Vhub = $VirtualHub | Where-Object { $_.ID -in $Data.virtualHubs.id }
            $Vpn = $VPNSite | Where-Object { $_.ID -in $Data.vpnSites.id }

            $Hubs = @($Vhub)
            if ($Hubs.Count -eq 0) { $Hubs = @($null) }
            $Vpns = @($Vpn)
            if ($Vpns.Count -eq 0) { $Vpns = @($null) }

            foreach ($2 in $Hubs)
            {
                foreach ($3 in $Vpns)
                {
                    $Obj = @{
                        'ID'                            = $1.id;
                        'Subscription'                  = $Sub1.Name;
                        'ResourceGroup'                 = $1.RESOURCEGROUP;
                        'Name'                          = $1.NAME;
                        'Location'                      = $1.LOCATION;
                        'HUBName'                       = if ($null -eq $2) { $null } elseif ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { 'obfuscated' } else { [string]$2.name };
                        'HUBLocation'                   = if ($null -eq $2) { $null } else { [string]$2.location };
                        'DeviceVendor'                  = if ($null -eq $3) { $null } else { [string]$3.properties.deviceProperties.deviceVendor };
                        'LinkProviderName'              = if ($null -eq $3) { $null } elseif ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { 'obfuscated' } else { [string]$3.properties.vpnSiteLinks.properties.linkProperties.linkProviderName };
                        'LinkSpeedMbps'                 = if ($null -eq $3) { $null } else { [string]$3.properties.vpnSiteLinks.properties.linkProperties.linkSpeedInMbps };
                    }

                    $Tmp += $Obj
                }
            }
        }

        $Tmp
    }
}

