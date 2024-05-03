param($SCPath, $Sub, $Resources, $Task, $File, $SmaResources, $TableStyle, $Metrics)

if ($Task -eq 'Processing') 
{
    $TrafficManager = $Resources | Where-Object { $_.TYPE -eq 'microsoft.network/trafficmanagerprofiles' }

    if($TrafficManager)
    {
        $tmp = @()

        foreach ($1 in $TrafficManager) 
        {
            $sub1 = $SUB | Where-Object { $_.Id -eq $1.subscriptionId }
            $data = $1.PROPERTIES
            
            $obj = @{
                'ID'                               = $1.id;
                'Subscription'                     = $sub1.Name;
                'ResourceGroup'                    = $1.RESOURCEGROUP;
                'Name'                             = $1.NAME;
                'Status'                           = $data.profilestatus;
                'RoutingMethod'                    = $data.trafficroutingmethod;
                'MonitorStatus'                    = $data.monitorconfig.profilemonitorstatus;                            
            }

            $tmp += $obj
        }

        $tmp
    }
}
else 
{
    if ($SmaResources.TrafficManager) 
    {
        $TableName = ('TrafficManagerTable_'+($SmaResources.TrafficManager.id | Select-Object -Unique).count)

        $Style = New-ExcelStyle -HorizontalAlignment Center -AutoSize -NumberFormat 0
        
        $Exc = New-Object System.Collections.Generic.List[System.Object]
        $Exc.Add('Subscription')
        $Exc.Add('ResourceGroup')
        $Exc.Add('Name')
        $Exc.Add('Status')
        $Exc.Add('RoutingMethod')
        $Exc.Add('MonitorStatus')

        $ExcelVar = $SmaResources.TrafficManager

        $ExcelVar | 
        ForEach-Object { [PSCustomObject]$_ } | Select-Object -Unique $Exc | 
        Export-Excel -Path $File -WorksheetName 'Traffic Manager' -AutoSize -MaxAutoSizeRows 100 -TableName $TableName -TableStyle $tableStyle -Style $Style
    }
}
