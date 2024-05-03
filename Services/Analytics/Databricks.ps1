param($SCPath, $Sub, $Resources, $Task ,$File, $SmaResources, $TableStyle, $Metrics)

if($Task -eq 'Processing') 
{
    $DataBricks = $Resources | Where-Object { $_.TYPE -eq 'microsoft.databricks/workspaces' }

    if($DataBricks)
    {
        $tmp = @()

        foreach ($1 in $DataBricks) 
        {
            $sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $data = $1.PROPERTIES
            $sku = $1.SKU
            $timecreated = $data.createdDateTime
            $timecreated = [datetime]$timecreated
            $timecreated = $timecreated.ToString("yyyy-MM-dd HH:mm")
            
            $obj = @{
                'ID'                        = $1.id;
                'Subscription'              = $sub1.Name;
                'ResourceGroup'             = $1.RESOURCEGROUP;
                'Name'                      = $1.NAME;
                'Location'                  = $1.LOCATION;
                'PricingTier'               = $sku.name;
                'ManagedResourceGroup'      = $data.managedResourceGroupId.split('/')[4];
                'StorageAccount'            = $data.parameters.storageAccountName.value;
                'StorageAccountSKU'         = $data.parameters.storageAccountSkuName.value;
                'CreatedTime'               = $timecreated;
            }
            
            $tmp += $obj
        }

        $tmp
    }
}
else 
{
    if($SmaResources.Databricks) 
    {
        $TableName = ('DBricksTable_'+($SmaResources.Databricks.id | Select-Object -Unique).count)
        $Style = New-ExcelStyle -HorizontalAlignment Center -AutoSize -NumberFormat 0

        $condtxt = @()

        $Exc = New-Object System.Collections.Generic.List[System.Object]
        $Exc.Add('Subscription')
        $Exc.Add('ResourceGroup')
        $Exc.Add('Name')
        $Exc.Add('Location')
        $Exc.Add('PricingTier')
        $Exc.Add('ManagedResourceGroup')
        $Exc.Add('StorageAccount')
        $Exc.Add('StorageAccountSKU')
        $Exc.Add('CreatedTime')  

        $ExcelVar = $SmaResources.Databricks

        $ExcelVar | 
        ForEach-Object { [PSCustomObject]$_ } | Select-Object -Unique $Exc | 
        Export-Excel -Path $File -WorksheetName 'Databricks' -AutoSize -MaxAutoSizeRows 100 -TableName $TableName -TableStyle $tableStyle -ConditionalText $condtxt -Style $Style
    }
}
