param($SCPath, $Sub, $Resources, $Task ,$File, $SmaResources, $TableStyle, $Metrics)

if ($Task -eq 'Processing') 
{
    $PrivateDNS = $Resources | Where-Object { $_.TYPE -eq 'microsoft.network/privatednszones' }

    if($PrivateDNS)
    {
        $tmp = @()

        foreach ($1 in $PrivateDNS) 
        {
            $sub1 = $SUB | Where-Object { $_.Id -eq $1.subscriptionId }
            $data = $1.PROPERTIES

            $obj = @{
                'ID'                              = $1.id;
                'Subscription'                    = $sub1.Name;
                'ResourceGroup'                   = $1.RESOURCEGROUP;
                'Name'                            = $1.NAME;
                'Location'                        = $1.LOCATION;
                'NumberOfRecords'                 = $data.numberOfRecordSets;
                'VirtualNetworkLinks'             = $data.numberOfVirtualNetworkLinks;
                'NetworkLinksRegistration'        = $data.numberOfVirtualNetworkLinksWithRegistration;
            }
    
            $tmp += $obj             
        }
        
        $tmp
    }
}
else 
{
    if ($SmaResources.PrivateDNS) 
    {
        $TableName = ('PrivDNSTable_'+($SmaResources.PrivateDNS.id | Select-Object -Unique).count)
        $Style = New-ExcelStyle -HorizontalAlignment Center -AutoSize -NumberFormat 0

        $condtxt = @()

        $Exc = New-Object System.Collections.Generic.List[System.Object]
        $Exc.Add('Subscription')
        $Exc.Add('ResourceGroup')
        $Exc.Add('Name')
        $Exc.Add('Location')
        $Exc.Add('NumberOfRecords')
        $Exc.Add('VirtualNetworkLinks')
        $Exc.Add('NetworkLinksRegistration')

        $ExcelVar = $SmaResources.PrivateDNS

        $ExcelVar | 
        ForEach-Object { [PSCustomObject]$_ } | Select-Object -Unique $Exc | 
        Export-Excel -Path $File -WorksheetName 'Private DNS' -AutoSize -MaxAutoSizeRows 100 -TableName $TableName -ConditionalText $condtxt -TableStyle $tableStyle -Style $Style
    
    }   
}