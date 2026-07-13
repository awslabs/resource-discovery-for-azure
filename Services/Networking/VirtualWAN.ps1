param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $VirtualWAN = $Resources | Where-Object { $_.TYPE -eq 'microsoft.network/virtualwans' }
    $VirtualHub = $Resources | Where-Object { $_.TYPE -eq 'microsoft.network/virtualhubs' }
    $VPNSite = $Resources | Where-Object { $_.TYPE -eq 'microsoft.network/vpnsites' }

    if ($VirtualWAN)
    {
        $tmp = @()

        foreach ($1 in $VirtualWAN)
        {
            $sub1 = $SUB | Where-Object { $_.Id -eq $1.subscriptionId }
            $data = $1.PROPERTIES
            $vhub = $VirtualHub | Where-Object { $_.ID -in $data.virtualHubs.id }
            $vpn = $VPNSite | Where-Object { $_.ID -in $data.vpnSites.id }

            if ($vpn)
            {
                foreach ($2 in $vhub)
                {
                    foreach ($3 in $vpn)
                    {
                        $obj = @{
                            'ID'                            = $1.id;
                            'Subscription'                  = $sub1.Name;
                            'ResourceGroup'                 = $1.RESOURCEGROUP;
                            'Name'                          = $1.NAME;
                            'Location'                      = $1.LOCATION;
                            'HUBName'                       = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { 'obfuscated' } else { [string]$2.name };
                            'HUBLocation'                   = [string]$2.location;
                            'DeviceVendor'                  = [string]$3.properties.deviceProperties.deviceVendor;
                            'LinkProviderName'              = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { 'obfuscated' } else { [string]$3.properties.vpnSiteLinks.properties.linkProperties.linkProviderName };
                            'LinkSpeedMbps'                 = [string]$3.properties.vpnSiteLinks.properties.linkProperties.linkSpeedInMbps;
                        }

                        $tmp += $obj
                    }
                }
            }
            else
            {
                foreach ($2 in $vhub)
                {
                    $obj = @{
                        'ID'                            = $1.id;
                        'Subscription'                  = $sub1.Name;
                        'ResourceGroup'                 = $1.RESOURCEGROUP;
                        'Name'                          = $1.NAME;
                        'Location'                      = $1.LOCATION;
                    }

                    $tmp += $obj
                }
            }
        }

        $tmp
    }
}
