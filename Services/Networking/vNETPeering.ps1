param($SCPath, $Sub, $Resources, $Task , $File, $SmaResources, $TableStyle, $Metrics)

If ($Task -eq 'Processing') 
{
    $VNET = $Resources | Where-Object { $_.TYPE -eq 'microsoft.network/virtualnetworks' }        
    $VNETProperties = $VNET.PROPERTIES
    $VNETPeering = $Resources | Where-Object { $_.TYPE -eq 'microsoft.network/virtualnetworks' -and $null -ne $VNETProperties.Peering -and $VNETProperties.Peering -ne '' }

    if($VNETPeering)
    {
        $tmp = @()

        foreach ($1 in $VNETPeering) 
        {
            $sub1 = $SUB | Where-Object { $_.Id -eq $1.subscriptionId }
            $data = $1.PROPERTIES
            
            foreach ($2 in $data.addressSpace.addressPrefixes) 
            {
                foreach ($4 in $data.virtualNetworkPeerings) 
                {
                    $obj = @{
                        'ID'                                    = $1.id;
                        'Subscription'                          = $sub1.Name;
                        'ResourceGroup'                         = $1.RESOURCEGROUP;
                        'VNETName'                              = $1.NAME;
                        'Location'                              = $1.LOCATION;
                        'PeeringName'                           = $4.name;
                        'PeeringVNet'                           = $4.properties.remoteVirtualNetwork.id.split('/')[8];
                        'PeeringState'                          = $4.properties.peeringState;
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
    if ($SmaResources.VNETPeering) 
    {
        $TableName = ('PeeringsTable_'+($SmaResources.VNETPeering.id | Select-Object -Unique).count)
        $Style = New-ExcelStyle -HorizontalAlignment Center -AutoSize -NumberFormat 0

        $Exc = New-Object System.Collections.Generic.List[System.Object]
        $Exc.Add('Subscription')
        $Exc.Add('ResourceGroup')
        $Exc.Add('Location')
        $Exc.Add('PeeringName')
        $Exc.Add('VNETName')
        $Exc.Add('AddressSpace')
        $Exc.Add('PeeringVNet')
        $Exc.Add('PeeringState')

        $ExcelVar = $SmaResources.VNETPeering 

        $ExcelVar | 
        ForEach-Object { [PSCustomObject]$_ } | Select-Object -Unique $Exc | 
        Export-Excel -Path $File -WorksheetName 'Peering' -AutoSize -MaxAutoSizeRows 100 -TableName $TableName -TableStyle $tableStyle -Style $Style
    }
}