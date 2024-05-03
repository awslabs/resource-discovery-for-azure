param($SCPath, $Sub, $Resources, $Task ,$File, $SmaResources, $TableStyle, $Metrics)

if ($Task -eq 'Processing') 
{
    $VMWare = $Resources | Where-Object { $_.TYPE -eq 'Microsoft.AVS/privateClouds' }

    if($VMWare)
    {
        $tmp = @()
        foreach ($1 in $VMWare) 
        {
            $sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $data = $1.PROPERTIES

            $obj = @{
                'ID'                       = $1.id;
                'Subscription'             = $sub1.Name;
                'ResourceGroup'            = $1.RESOURCEGROUP;
                'Name'                     = $1.NAME;
                'Location'                 = $1.LOCATION;
                'SKU'                      = $data.sku.name;
                'AvailabilityStrategy'     = $data.availability.strategy;
                'Encryption'               = $data.encryption.status;
                'ClusterSize'              = $data.managementCluster.clusterSize;
            }

            $tmp += $obj
        }

        $tmp
    }
}
else 
{
    if ($SmaResources.VMWare) 
    {
        $TableName = ('VMWareTable_'+($SmaResources.VMWare.id | Select-Object -Unique).count)
        $Style = New-ExcelStyle -HorizontalAlignment Center -AutoSize -NumberFormat 0
        
        $Exc = New-Object System.Collections.Generic.List[System.Object]
        $Exc.Add('Subscription')
        $Exc.Add('ResourceGroup')
        $Exc.Add('Name')
        $Exc.Add('Location')
        $Exc.Add('SKU')
        $Exc.Add('AvailabilityStrategy')
        $Exc.Add('Encryption')
        $Exc.Add('ClusterSize')

        $ExcelVar = $SmaResources.VMWare 

        $ExcelVar | 
        ForEach-Object { [PSCustomObject]$_ } | Select-Object -Unique $Exc | 
        Export-Excel -Path $File -WorksheetName 'VMWare' -AutoSize -MaxAutoSizeRows 100 -TableName $TableName -TableStyle $tableStyle -Style $Style

    }
}
