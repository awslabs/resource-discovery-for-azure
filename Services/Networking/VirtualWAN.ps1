param($SCPath, $Sub, $Resources, $Task, $File, $SmaResources, $TableStyle, $Metrics)

if ($Task -eq 'Processing') 
{
    $VirtualWAN = $Resources | Where-Object { $_.TYPE -eq 'microsoft.network/virtualwans' }
    $VirtualHub = $Resources | Where-Object { $_.TYPE -eq 'microsoft.network/virtualhubs' }
    $VPNSite = $Resources | Where-Object { $_.TYPE -eq 'microsoft.network/vpnsites' }

    if($VirtualWAN)
    {
        $tmp = @()

        foreach ($1 in $VirtualWAN) 
        {
            $sub1 = $SUB | Where-Object { $_.Id -eq $1.subscriptionId }
            $data = $1.PROPERTIES
            $vhub = $VirtualHub | Where-Object { $_.ID -in $data.virtualHubs.id }
            $vpn = $VPNSite | Where-Object { $_.ID -in $data.vpnSites.id }
            
            if($vpn)
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
                            'HUBName'                       = [string]$2.name;
                            'HUBLocation'                   = [string]$2.location;
                            'DeviceVendor'                  = [string]$3.properties.deviceProperties.deviceVendor;
                            'LinkProviderName'              = [string]$3.properties.vpnSiteLinks.properties.linkProperties.linkProviderName;
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
else 
{
    if ($SmaResources.VirtualWAN) 
    {
        $TableName = ('VWANTable_'+($SmaResources.VirtualWAN.id | Select-Object -Unique).count)
        $Style = New-ExcelStyle -HorizontalAlignment Center -AutoSize -NumberFormat 0

        $Exc = New-Object System.Collections.Generic.List[System.Object]
        $Exc.Add('Subscription')
        $Exc.Add('ResourceGroup')
        $Exc.Add('Name')                              
        $Exc.Add('Location')                                     
        $Exc.Add('HUBName')                          
        $Exc.Add('HUBLocation')                                       
        $Exc.Add('Device Vendor')                     
        $Exc.Add('LinkProviderName')                
        $Exc.Add('LinkSpeedMbps')                

        $ExcelVar = $SmaResources.VirtualWAN 

        $ExcelVar | 
        ForEach-Object { [PSCustomObject]$_ } | Select-Object -Unique $Exc | 
        Export-Excel -Path $File -WorksheetName 'Virtual WAN' -AutoSize -MaxAutoSizeRows 100 -TableName $TableName -TableStyle $tableStyle -Style $Style   
    }
}