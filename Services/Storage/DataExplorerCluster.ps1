param($SCPath, $Sub, $Resources, $Task ,$File, $SmaResources, $TableStyle, $Metrics)

if ($Task -eq 'Processing') 
{
    $DataExplorer = $Resources | Where-Object { $_.TYPE -eq 'microsoft.kusto/clusters' }

    if($DataExplorer)
    {
        $tmp = @()

        foreach ($1 in $DataExplorer) 
        {
            $sub1 = $SUB | Where-Object { $_.Id -eq $1.subscriptionId }
            $data = $1.PROPERTIES
            $sku = $1.SKU

            $AutoScale = if($data.optimizedAutoscale.isEnabled -eq 'true'){'Enabled'}else{'Disabled'}
            
            $obj = @{
                'ID'                        = $1.id;
                'Subscription'              = $sub1.Name;
                'ResourceGroup'             = $1.RESOURCEGROUP;
                'Name'                      = $1.NAME;
                'Location'                  = $1.LOCATION;
                'ComputeSpecifications'     = $sku.name;
                'InstanceCount'             = $sku.capacity;
                'State'                     = $data.state;
                'StateReason'               = $data.stateReason;
                'DiskEncryption'            = $data.enableDiskEncryption;
                'StreamingIngestion'        = $data.enableStreamingIngest;
                'OptimizedAutoscale'        = $AutoScale;
                'OptimizedAutoscaleMin'     = $data.optimizedAutoscale.minimum;
                'OptimizedAutoscaleMax'     = $data.optimizedAutoscale.maximum;
            }
            $tmp += $obj
        }
        $tmp
    }
}
else 
{
    if ($SmaResources.DataExplorerCluster) 
    {
        $TableName = ('DTExplTable_'+($SmaResources.DataExplorerCluster.id | Select-Object -Unique).count)
        $Style = New-ExcelStyle -HorizontalAlignment Center -AutoSize -NumberFormat 0

        $condtxt = @()

        $Exc = New-Object System.Collections.Generic.List[System.Object]
        $Exc.Add('Subscription')
        $Exc.Add('ResourceGroup')
        $Exc.Add('Name')
        $Exc.Add('Location')
        $Exc.Add('ComputeSpecifications')
        $Exc.Add('InstanceCount')
        $Exc.Add('State')
        $Exc.Add('StateReason')
        $Exc.Add('DiskEncryption')
        $Exc.Add('StreamingIngestion')
        $Exc.Add('OptimizedAutoscale')
        $Exc.Add('OptimizedAutoscaleMin')
        $Exc.Add('OptimizedAutoscaleMax')

        $ExcelVar = $SmaResources.DataExplorerCluster 

        $ExcelVar | 
        ForEach-Object { [PSCustomObject]$_ } | Select-Object -Unique $Exc | 
        Export-Excel -Path $File -WorksheetName 'Data Explorer Clusters' -AutoSize -MaxAutoSizeRows 100 -TableName $TableName -TableStyle $tableStyle -ConditionalText $condtxt -Style $Style
    }
}