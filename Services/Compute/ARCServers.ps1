param($SCPath, $Sub, $Resources, $Task ,$File, $SmaResources, $TableStyle, $Metrics)

if ($Task -eq 'Processing')
{
    $arcservers = $Resources | Where-Object {$_.TYPE -eq 'microsoft.hybridcompute/machines'}

    if($arcservers)
    {
        $tmp = @()
        foreach ($1 in $arcservers) 
        {
            $sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $data = $1.PROPERTIES

            foreach ($Tag in $Tags) { 
                $obj = @{
                    'ID'                   = $1.id;
                    'Subscription'         = $sub1.name;
                    'ResourceGroup'       = $1.RESOURCEGROUP;
                    'Name'                 = $1.NAME;
                    'Location'             = $1.LOCATION;
                    'Model'                = $data.detectedProperties.model;
                    'Status'               = $data.status;
                    'OsName'               = $data.osName;
                    'OsVersion'            = $data.osVersion;
                    'OsSku'                = $data.osSku;
                    'DomainName'           = $data.domainName;
                }
                
                $tmp += $obj
            }               
        }

        $tmp
    }
}
else
{
    if($SmaResources.ARCServers)
    {
        $TableName = ('ARCServer_'+($SmaResources.ARCServer.id | Select-Object -Unique).count)
        $Style = New-ExcelStyle -HorizontalAlignment Center -AutoSize -NumberFormat '0'

        $Exc = New-Object System.Collections.Generic.List[System.Object]
        $Exc.Add('Subscription')
        $Exc.Add('ResourceGroup')
        $Exc.Add('Name')
        $Exc.Add('Location')
        $Exc.Add('Model')
        $Exc.Add('Status')
        $Exc.Add('OssName')
        $Exc.Add('OsVersion')
        $Exc.Add('OsSku')
        $Exc.Add('DomainName')

        $ExcelVar = $SmaResources.ARCServers  

        $ExcelVar | 
        ForEach-Object { [PSCustomObject]$_ } | Select-Object -Unique $Exc | 
        Export-Excel -Path $File -WorksheetName 'ARC Servers' -AutoSize -MaxAutoSizeRows 100 -TableName $TableName -TableStyle $tableStyle -Style $Style
    }
}
