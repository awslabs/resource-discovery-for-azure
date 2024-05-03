param($SCPath, $Sub, $Resources, $Task ,$File, $SmaResources, $TableStyle, $Metrics)

if ($Task -eq 'Processing')
{
    $svchub = $Resources | Where-Object {$_.TYPE -eq 'microsoft.servicebus/namespaces'}

    if($svchub)
    {
        $tmp = @()

        foreach ($1 in $svchub) 
        {
            $sub1 = $SUB | Where-Object { $_.Id -eq $1.subscriptionId }
            $data = $1.PROPERTIES
            $sku = $1.SKU
            $timecreated = $data.createdAt
            $timecreated = [datetime]$timecreated
            $timecreated = $timecreated.ToString("yyyy-MM-dd HH:mm")
            
            $obj = @{
                'ID'                    = $1.id;
                'Subscription'          = $sub1.Name;
                'ResourceGroup'         = $1.RESOURCEGROUP;
                'Name'                  = $1.NAME;
                'Location'              = $1.LOCATION;
                'SKU'                   = $sku.name;
                'Status'                = $data.status;
                'GeoRep'                = $data.zoneRedundant;
                'ThroughputUnits'       = $1.sku.capacity;
                'CreatedTime'           = $timecreated;      
            }

            $tmp += $obj
        }

        $tmp
    }
}
else
{
    if($SmaResources.ServiceBUS)
    {
        $TableName = ('ServiceBUSTable_'+($SmaResources.ServiceBUS.id | Select-Object -Unique).count)
        $Style = New-ExcelStyle -HorizontalAlignment Center -AutoSize -NumberFormat '0'

        $condtxt = @()

        $Exc = New-Object System.Collections.Generic.List[System.Object]
        $Exc.Add('Subscription')
        $Exc.Add('ResourceGroup')
        $Exc.Add('Name')
        $Exc.Add('Location')
        $Exc.Add('SKU')
        $Exc.Add('Status')
        $Exc.Add('GeoRep')
        $Exc.Add('ThroughputUnits')
        $Exc.Add('CreatedTime')

        $ExcelVar = $SmaResources.ServiceBUS  

        $ExcelVar | 
        ForEach-Object { [PSCustomObject]$_ } | Select-Object -Unique $Exc | 
        Export-Excel -Path $File -WorksheetName 'Service BUS' -AutoSize -MaxAutoSizeRows 100 -TableName $TableName -TableStyle $tableStyle -ConditionalText $condtxt -Style $Style
    }
}