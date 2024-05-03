param($SCPath, $Sub, $Resources, $Task ,$File, $SmaResources, $TableStyle, $Metrics)

if ($Task -eq 'Processing') 
{
    $NetApp = $Resources | Where-Object { $_.TYPE -eq 'Microsoft.NetApp/netAppAccounts/capacityPools/volumes' }

    if($NetApp)
    {
        $tmp = @()
        foreach ($1 in $NetApp) 
        {
            $sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $data = $1.PROPERTIES

            $NetApp = $1.Name.split('/')[0]
            $CapacityPool = $1.Name.split('/')[1]
            $Volume = $1.Name.split('/')[2]
            $Quota = ((($data.usageThreshold/1024)/1024)/1024)/1024
            
            $obj = @{
                'ID'                                = $1.id;
                'Subscription'                      = $sub1.Name;
                'ResourceGroup'                     = $1.RESOURCEGROUP;
                'Location'                          = $1.LOCATION;
                'NetAppAccount'                     = $NetApp;
                'CapacityPool'                      = $CapacityPool;
                'Volume'                            = $Volume;
                'ServiceLevel'                      = $data.serviceLevel;
                'QuotaTB'                           = [string]$Quota;
                'Protocol'                          = [string]$data.protocolTypes;
                'MaxThroughputMiBs'                 = [string]$data.throughputMibps;
                'LDAP'                              = $data.ldapEnabled;                        
            }

            $tmp += $obj
        }

        $tmp
    }
}
else 
{
    if ($SmaResources.NetApp) 
    {
        $TableName = ('NetAppATable_'+($SmaResources.NetApp.id | Select-Object -Unique).count)
        $Style = New-ExcelStyle -HorizontalAlignment Center -AutoSize -NumberFormat 0
        
        $Exc = New-Object System.Collections.Generic.List[System.Object]
        $Exc.Add('Subscription')
        $Exc.Add('ResourceGroup')
        $Exc.Add('Location')
        $Exc.Add('NetAppAccount')
        $Exc.Add('CapacityPool')
        $Exc.Add('Volume')
        $Exc.Add('ServiceLevel')
        $Exc.Add('QuotaTB')
        $Exc.Add('Protocol')
        $Exc.Add('MaxThroughputMiBs')
        $Exc.Add('LDAP')

        $ExcelVar = $SmaResources.NetApp 

        $ExcelVar | 
        ForEach-Object { [PSCustomObject]$_ } | Select-Object -Unique $Exc | 
        Export-Excel -Path $File -WorksheetName 'NetApp' -AutoSize -MaxAutoSizeRows 100 -TableName $TableName -TableStyle $tableStyle -Style $Style
    }
}