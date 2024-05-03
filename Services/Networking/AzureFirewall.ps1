param($SCPath, $Sub, $Resources, $Task ,$File, $SmaResources, $TableStyle, $Metrics)

if ($Task -eq 'Processing') 
{
    $AzureFirewall = $Resources | Where-Object { $_.TYPE -eq 'microsoft.network/azurefirewalls' }

    if($AzureFirewall)
    {
        $tmp = @()

        foreach ($1 in $AzureFirewall) 
        {
            $sub1 = $SUB | Where-Object { $_.Id -eq $1.subscriptionId }
            $data = $1.PROPERTIES
            
            $obj = @{
                'ID'                                = $1.id;
                'Subscription'                      = $sub1.Name;
                'Resource Group'                    = $1.RESOURCEGROUP;
                'Name'                              = $1.NAME;
                'Location'                          = $1.LOCATION;
                'SKU'                               = $data.sku.tier;
            }

            $tmp += $obj            
        }
        
        $tmp
    }
}
else 
{
    if ($SmaResources.AzureFirewall) 
    {
        $TableName = ('AzFirewallTable_'+($SmaResources.AzureFirewall.id | Select-Object -Unique).count)
        $condtxt = @()

        $Style = New-ExcelStyle -HorizontalAlignment Center -AutoSize -NumberFormat 0

        $Exc = New-Object System.Collections.Generic.List[System.Object]
        $Exc.Add('Subscription')
        $Exc.Add('Resource Group')
        $Exc.Add('Name')
        $Exc.Add('Location')
        $Exc.Add('SKU')

        $ExcelVar = $SmaResources.AzureFirewall 

        $ExcelVar | 
        ForEach-Object { [PSCustomObject]$_ } | Select-Object -Unique $Exc | 
        Export-Excel -Path $File -WorksheetName 'Azure Firewall' -AutoSize -MaxAutoSizeRows 100 -TableName $TableName -TableStyle $tableStyle -ConditionalText $condtxt -Style $Style

    }
}