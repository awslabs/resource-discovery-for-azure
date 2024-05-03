param($SCPath, $Sub, $Resources, $Task ,$File, $SmaResources, $TableStyle, $Metrics)

if ($Task -eq 'Processing') 
{
    #$CloudServices0 = $Resources | Where-Object { $_.TYPE -eq 'microsoft.compute/cloudservices' }
    $CloudServices = $Resources | Where-Object { $_.TYPE -eq 'microsoft.classiccompute/domainnames' }

    if($CloudServices)
    {
        $tmp = @()

        foreach ($1 in $CloudServices) 
        {
            $sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $data = $1.PROPERTIES

            $obj = @{
                'ID'                   = $1.id;
                'Subscription'         = $sub1.Name;
                'ResourceGroup'        = $1.RESOURCEGROUP;
                'Name'                 = $1.name;
                'Location'             = $1.location;
                'Status'               = $data.status;
                'Label'                = $data.label;
                'Hostname'             = $data.hostname;    
            }

            $tmp += $obj
        }
        
        $tmp
    }
}
else 
{
    if ($SmaResources.CloudServices) 
    {
        $TableName = ('CloudServicesTable_'+($SmaResources.CloudServices.id | Select-Object -Unique).count)
        $Style = New-ExcelStyle -HorizontalAlignment Center -AutoSize -NumberFormat '0'

        $Exc = New-Object System.Collections.Generic.List[System.Object]
        $Exc.Add('Subscription')
        $Exc.Add('ResourceGroup')
        $Exc.Add('Name')         
        $Exc.Add('Location')             
        $Exc.Add('Status')          
        $Exc.Add('Label')           
        $Exc.Add('Hostname')      

        $ExcelVar = $SmaResources.CloudServices

        $ExcelVar | 
        ForEach-Object { [PSCustomObject]$_ } | Select-Object -Unique $Exc | 
        Export-Excel -Path $File -WorksheetName 'CloudServices' -AutoSize -TableName $TableName -MaxAutoSizeRows 100 -TableStyle $tableStyle -Numberformat '0' -Style $Style
    }
}