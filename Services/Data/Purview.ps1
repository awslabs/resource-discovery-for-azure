param($SCPath, $Sub, $Resources, $Task ,$File, $SmaResources, $TableStyle, $Metrics)

if ($Task -eq 'Processing') 
{
    $Purview = $Resources | Where-Object { $_.TYPE -eq 'microsoft.purview/accounts' }

    if($Purview)
    {
        $tmp = @()
        foreach ($1 in $Purview) 
        {
            $sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $data = $1.PROPERTIES

            $timecreated = $data.createdAt
            $timecreated = [datetime]$timecreated
            $timecreated = $timecreated.ToString("yyyy-MM-dd HH:mm")

            $obj = @{
                'ID'                  = $1.id;
                'Subscription'        = $sub1.Name;
                'ResourceGroup'       = $1.RESOURCEGROUP;
                'Name'                = $1.NAME;
                'Location'            = $1.LOCATION;
                'SKU'                 = $data.sku.name;
                'Capacity'            = $data.sku.capacity;
                'FriendlyName'        = $data.friendlyName;
                'CreatedBy'           = $data.createdBy;      
                'CreatedTime'         = $timecreated;                      
            }

            $tmp += $obj
        }
        
        $tmp
    }
}
else 
{
    if ($SmaResources.Purview) 
    {
        $TableName = ('PurviewATable_'+($SmaResources.Purview.id | Select-Object -Unique).count)
        $Style = New-ExcelStyle -HorizontalAlignment Center -AutoSize -NumberFormat 0
        
        $Exc = New-Object System.Collections.Generic.List[System.Object]
        $Exc.Add('Subscription')
        $Exc.Add('ResourceGroup')
        $Exc.Add('Name')
        $Exc.Add('Location')
        $Exc.Add('SKU')
        $Exc.Add('Capacity')
        $Exc.Add('FriendlyName')
        $Exc.Add('CreatedBy')
        $Exc.Add('CreatedTime')

        $ExcelVar = $SmaResources.Purview 

        $ExcelVar | 
        ForEach-Object { [PSCustomObject]$_ } | Select-Object -Unique $Exc | 
        Export-Excel -Path $File -WorksheetName 'Purview' -AutoSize -MaxAutoSizeRows 100 -TableName $TableName -TableStyle $tableStyle -Style $Style

    }
}
