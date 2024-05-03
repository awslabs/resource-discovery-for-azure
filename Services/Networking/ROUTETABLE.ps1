param($SCPath, $Sub, $Resources, $Task, $File, $SmaResources, $TableStyle, $Metrics)

if ($Task -eq 'Processing') 
{
    $ROUTETABLE = $Resources | Where-Object { $_.TYPE -eq 'microsoft.network/routetables' }

    if($ROUTETABLE)
    {
        $tmp = @()

        foreach ($1 in $ROUTETABLE) 
        {
            $sub1 = $SUB | Where-Object { $_.Id -eq $1.subscriptionId }
            $data = $1.PROPERTIES
            
            $obj = @{
                'ID'                            = $1.id;
                'Subscription'                  = $sub1.Name;
                'ResourceGroup'                 = $1.RESOURCEGROUP;
                'Name'                          = $1.NAME;
                'Location'                      = $1.LOCATION;
            }

            $tmp += $obj            
        }

        $tmp
    }
}
else 
{
    if ($SmaResources.ROUTETABLE) 
    {
        $TableName = ('RouteTbTable_'+($SmaResources.ROUTETABLE.id | Select-Object -Unique).count)
        $Style = New-ExcelStyle -HorizontalAlignment Center -AutoSize -NumberFormat 0

        $Exc = New-Object System.Collections.Generic.List[System.Object]
        $Exc.Add('Subscription')
        $Exc.Add('ResourceGroup')
        $Exc.Add('Name')
        $Exc.Add('Location')

        $ExcelVar = $SmaResources.ROUTETABLE 

        $ExcelVar | 
        ForEach-Object { [PSCustomObject]$_ } | Select-Object -Unique $Exc | 
        Export-Excel -Path $File -WorksheetName 'Route Tables' -AutoSize -MaxAutoSizeRows 100 -TableName $TableName -TableStyle $tableStyle -Style $Style
    }
}