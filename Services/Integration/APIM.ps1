param($SCPath, $Sub, $Resources, $Task ,$File, $SmaResources, $TableStyle, $Metrics)

if ($Task -eq 'Processing')
{
    $APIM = $Resources | Where-Object {$_.TYPE -eq 'microsoft.apimanagement/service'}

    if($APIM)
    {
        $tmp = @()

        foreach ($1 in $APIM) 
        {
            $sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $data = $1.PROPERTIES
            
            $obj = @{
                'ID'                   = $1.id;
                'Subscription'         = $sub1.Name;
                'ResourceGroup'        = $1.RESOURCEGROUP;
                'Name'                 = $1.NAME;
                'Location'             = $1.LOCATION;
                'Capacity'             = $1.sku.capacity;
                'SKU'                  = $1.sku.name;
                'VirtualNetworkType'   = $data.virtualNetworkType;
            }
            
            $tmp += $obj          
        }
        
        $tmp
    }
}
else
{
    if($SmaResources.APIM)
    {
        $TableName = ('APIMTable_'+($SmaResources.APIM.id | Select-Object -Unique).count)
        $Style = New-ExcelStyle -HorizontalAlignment Center -AutoSize -NumberFormat '0'

        $condtxt = @()

        $Exc = New-Object System.Collections.Generic.List[System.Object]
        $Exc.Add('Subscription')
        $Exc.Add('ResourceGroup')
        $Exc.Add('Name')
        $Exc.Add('Location')
        $Exc.Add('Capacity')
        $Exc.Add('SKU')
        $Exc.Add('VirtualNetworkType')

        $ExcelVar = $SmaResources.APIM 

        $ExcelVar | 
        ForEach-Object { [PSCustomObject]$_ } | Select-Object -Unique $Exc | 
        Export-Excel -Path $File -WorksheetName 'APIM' -AutoSize -MaxAutoSizeRows 100 -TableName $TableName -TableStyle $tableStyle -ConditionalText $condtxt -Style $Style
    }
}