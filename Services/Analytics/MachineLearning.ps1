param($SCPath, $Sub, $Resources, $Task ,$File, $SmaResources, $TableStyle, $Metrics)

If ($Task -eq 'Processing') 
{
    $AzureML = $Resources | Where-Object { $_.TYPE -eq 'microsoft.machinelearningservices/workspaces' }

    if($AzureML)
    {
        $tmp = @()

        foreach ($1 in $AzureML) 
        {
            $sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $data = $1.PROPERTIES
            $timecreated = [datetime]($data.creationTime) | Get-Date -Format "yyyy-MM-dd HH:mm"

            $StorageAcc = $data.storageAccount.split('/')[8]
            $KeyVault = $data.keyVault.split('/')[8]
            $Insight = $data.applicationInsights.split('/')[8]
            $containerRegistry = $data.containerRegistry.split('/')[8]

            $obj = @{
                'ID'                        = $1.id;
                'Subscription'              = $sub1.Name;
                'ResourceGroup'             = $1.RESOURCEGROUP;
                'Name'                      = $1.NAME;
                'Location'                  = $1.LOCATION;
                'SKU'                       = $1.sku.name;
                'FriendlyName'              = $data.friendlyName;
                'Description'               = $data.description;
                'ContainerRegistry'         = $containerRegistry;
                'StorageHNSEnabled'         = $data.storageHnsEnabled;
                'StorageAccount'            = $StorageAcc;
                'KeyVault'                  = $KeyVault;
                'CreatedTime'               = $timecreated;
                'ApplicationInsight'        = $Insight;
            }

            $tmp += $obj
        }

        $tmp
    }
}
else 
{
    if ($SmaResources.AzureML) 
    {
        $TableName = ('AzureMLTable_'+($SmaResources.AzureML.id | Select-Object -Unique).count)
        $Style = New-ExcelStyle -HorizontalAlignment Center -AutoSize -NumberFormat 0

        $condtxt = @()

        $Exc = New-Object System.Collections.Generic.List[System.Object]
        $Exc.Add('Subscription')
        $Exc.Add('ResourceGroup')
        $Exc.Add('Name')
        $Exc.Add('Location')
        $Exc.Add('SKU')
        $Exc.Add('FriendlyName')
        $Exc.Add('Description')
        $Exc.Add('ContainerRegistry')
        $Exc.Add('StorageHNSEnabled')
        $Exc.Add('StorageAccount')
        $Exc.Add('KeyVault')
        $Exc.Add('ApplicationInsight')
        $Exc.Add('CreatedTime')  

        $ExcelVar = $SmaResources.AzureML

        $ExcelVar | 
        ForEach-Object { [PSCustomObject]$_ } | Select-Object -Unique $Exc | 
        Export-Excel -Path $File -WorksheetName 'Machine Learning' -AutoSize -MaxAutoSizeRows 100 -TableName $TableName -TableStyle $tableStyle -ConditionalText $condtxt -Style $Style

    }
}
