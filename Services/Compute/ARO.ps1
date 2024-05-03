param($SCPath, $Sub, $Resources, $Task ,$File, $SmaResources, $TableStyle, $Metrics)

if ($Task -eq 'Processing') 
{
    $ARO = $Resources | Where-Object { $_.TYPE -eq 'microsoft.redhatopenshift/openshiftclusters' }

    if($ARO)
    {
        $tmp = @()
        foreach ($1 in $ARO)
        {
            $sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $data = $1.PROPERTIES

            $obj = @{
                'ID'                   = $1.id;
                'Subscription'         = $sub1.Name;
                'ResourceGroup'        = $1.RESOURCEGROUP;
                'Clusters'             = $1.NAME;
                'Location'             = $1.LOCATION;
                'AROVersion'           = $data.clusterProfile.version;
                'OutboundType'         = $data.networkProfile.outboundType;
                'APIServerType'        = $data.apiserverProfile.visibility;               
                'MasterSKU'            = $data.masterProfile.vmSize;                 
                'WorkerSKU'            = $data.workerProfiles.vmSize | Select-Object -Unique;        
                'WorkerDiskSize'       = $data.workerProfiles.diskSizeGB | Select-Object -Unique;        
                'TotalWorkerNodes'     = $data.workerProfiles.count;            
            }

            $tmp += $obj
        }

        $tmp
    }
}
else 
{
    if ($SmaResources.ARO) 
    {
        $TableName = ('AROTable_'+($SmaResources.ARO.id | Select-Object -Unique).count)
        $Style = New-ExcelStyle -HorizontalAlignment Center -AutoSize -NumberFormat '0'

        $Exc = New-Object System.Collections.Generic.List[System.Object]
        $Exc.Add('Subscription')
        $Exc.Add('ResourceGroup')
        $Exc.Add('Clusters')         
        $Exc.Add('Location')             
        $Exc.Add('AROVersion')          
        $Exc.Add('OutboundType')        
        $Exc.Add('MasterSKU')                            
        $Exc.Add('WorkerSKU')           
        $Exc.Add('WorkerDiskSize')        
        $Exc.Add('TotalWorkerNodes')   

        $ExcelVar = $SmaResources.ARO 

        $ExcelVar | 
        ForEach-Object { [PSCustomObject]$_ } | Select-Object -Unique $Exc | 
        Export-Excel -Path $File -WorksheetName 'ARO' -AutoSize -TableName $TableName -MaxAutoSizeRows 100 -TableStyle $tableStyle -Numberformat '0' -Style $Style   
    }
}