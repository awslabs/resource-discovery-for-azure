param($SCPath, $Sub, $Resources, $Task ,$File, $SmaResources, $TableStyle, $Metrics)

if ($Task -eq 'Processing')
{
    $BASTION = $Resources | Where-Object {$_.TYPE -eq 'microsoft.network/bastionhosts'}

    if($BASTION)
    {
        $tmp = @()

        foreach ($1 in $BASTION) 
        {
            $sub1 = $SUB | Where-Object { $_.Id -eq $1.subscriptionId }
            $data = $1.PROPERTIES
            
            $obj = @{
                'ID'              = $1.id;
                'Subscription'    = $sub1.Name;
                'ResourceGroup'   = $1.RESOURCEGROUP;
                'Name'            = $1.NAME;
                'Location'        = $1.LOCATION;
                'SKU'             = $1.sku.name;
                'ScaleUnits'      = $data.scaleUnits;
            }

            $tmp += $obj

        }
        $tmp
    }
}
else
{
    if($SmaResources.BASTION)
    {
        $TableName = ('BASTIONTable_'+($SmaResources.BASTION.id | Select-Object -Unique).count)
        $Style = New-ExcelStyle -HorizontalAlignment Center -AutoSize -NumberFormat '0'

        $Exc = New-Object System.Collections.Generic.List[System.Object]
        $Exc.Add('Subscription')
        $Exc.Add('ResourceGroup')
        $Exc.Add('Name')
        $Exc.Add('Location')
        $Exc.Add('SKU')
        $Exc.Add('ScaleUnits')

        $ExcelVar = $SmaResources.BASTION  

        $ExcelVar | 
        ForEach-Object { [PSCustomObject]$_ } | Select-Object -Unique $Exc | 
        Export-Excel -Path $File -WorksheetName 'Bastion Hosts' -AutoSize -MaxAutoSizeRows 100 -TableName $TableName -TableStyle $tableStyle -Style $Style
    }
}
