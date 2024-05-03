param($SCPath, $Sub, $Resources, $Task ,$File, $SmaResources, $TableStyle, $Metrics)

if ($Task -eq 'Processing') 
{
    $NATGAT = $Resources | Where-Object { $_.TYPE -eq 'microsoft.network/natgateways' }

    if($NATGAT)
    {
        $tmp = @()

        foreach ($1 in $NATGAT) 
        {
            $sub1 = $SUB | Where-Object { $_.Id -eq $1.subscriptionId }
            $data = $1.PROPERTIES
            
            $obj = @{
                'ID'                    = $1.id;
                'Subscription'          = $sub1.Name;
                'ResourceGroup'         = $1.RESOURCEGROUP;
                'Name'                  = $1.NAME;
                'Location'              = $1.LOCATION;
                'SKU'                   = $1.sku.name;
                'IdleTimeoutMin'        = $data.idleTimeoutInMinutes;
            }
            
            $tmp += $obj            
        }

        $tmp
    }
}
else 
{
    if ($SmaResources.NATGateway) 
    {
        $TableName = ('NATGatewayTable_'+($SmaResources.NATGateway.id | Select-Object -Unique).count)
        $Style = New-ExcelStyle -HorizontalAlignment Center -AutoSize -NumberFormat 0

        $Exc = New-Object System.Collections.Generic.List[System.Object]
        $Exc.Add('Subscription')
        $Exc.Add('ResourceGroup')
        $Exc.Add('Name')
        $Exc.Add('Location')
        $Exc.Add('SKU')
        $Exc.Add('IdleTimeoutMin')

        $ExcelVar = $SmaResources.NATGateway

        $ExcelVar | 
        ForEach-Object { [PSCustomObject]$_ } | Select-Object -Unique $Exc | 
        Export-Excel -Path $File -WorksheetName 'NAT Gateway' -AutoSize -MaxAutoSizeRows 100 -TableName $TableName -TableStyle $tableStyle -Style $Style
    }
}