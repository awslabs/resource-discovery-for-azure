param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $VirtualWAN = $Resources | Where-Object { $_.TYPE -eq 'microsoft.network/virtualwans' }
    $VirtualHub = $Resources | Where-Object { $_.TYPE -eq 'microsoft.network/virtualhubs' }
    $VPNSite = $Resources | Where-Object { $_.TYPE -eq 'microsoft.network/vpnsites' }

    if ($VirtualWAN)
    {
        $Tmp = [System.Collections.Generic.List[object]]::new()

        foreach ($1 in $VirtualWAN)
        {
            $Sub1 = $SUB | Where-Object { $_.Id -eq $1.subscriptionId }
            $Data = $1.PROPERTIES
            $Vhub = $VirtualHub | Where-Object { $_.ID -in $Data.virtualHubs.id }
            $Vpn = $VPNSite | Where-Object { $_.ID -in $Data.vpnSites.id }

            # A virtual WAN with no hub still gets its row(s), the hub columns empty,
            # as AvSet.ps1 writes a set that has no VMs.
            if ($null -eq $Vhub) { $Vhub = @($null) }

            if ($Vpn)
            {
                foreach ($2 in $Vhub)
                {
                    foreach ($3 in $Vpn)
                    {
                        $Obj = @{
                            'ID'                            = $1.id;
                            'Subscription'                  = $Sub1.Name;
                            'ResourceGroup'                 = $1.RESOURCEGROUP;
                            'Name'                          = $1.NAME;
                            'Location'                      = $1.LOCATION;
                            'HUBName'                       = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { 'obfuscated' } else { [string]$2.name };
                            'HUBLocation'                   = [string]$2.location;
                            'DeviceVendor'                  = [string]$3.properties.deviceProperties.deviceVendor;
                            'LinkProviderName'              = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { 'obfuscated' } else { [string]$3.properties.vpnSiteLinks.properties.linkProperties.linkProviderName };
                            'LinkSpeedMbps'                 = [string]$3.properties.vpnSiteLinks.properties.linkProperties.linkSpeedInMbps;
                        }

                        [void]$Tmp.Add($Obj)
                    }
                }
            }
            else
            {
                foreach ($2 in $Vhub)
                {
                    $Obj = @{
                        'ID'                            = $1.id;
                        'Subscription'                  = $Sub1.Name;
                        'ResourceGroup'                 = $1.RESOURCEGROUP;
                        'Name'                          = $1.NAME;
                        'Location'                      = $1.LOCATION;
                    }

                    [void]$Tmp.Add($Obj)
                }
            }
        }

        $Tmp
    }
}
