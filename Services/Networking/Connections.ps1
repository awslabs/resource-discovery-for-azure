param($SCPath, $Sub, $Resources, $Task ,$File, $SmaResources, $TableStyle, $Metrics)

if ($Task -eq 'Processing')
{
    $connections = $Resources | Where-Object {$_.TYPE -eq 'microsoft.network/connections'}

    if($connections)
    {
        $tmp = @()

        foreach ($1 in $connections) 
        {
            $sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $data = $1.PROPERTIES
            
            $obj = @{
                'ID'                    = $1.id;
                'Subscription'          = $sub1.name;
                'ResourceGroup'         = $1.RESOURCEGROUP;
                'Name'                  = $1.NAME;
                'Location'              = $1.LOCATION;
                'Type'                  = $data.connectionType;
                'Status'                = $data.connectionStatus;
                'ConnectionProtocol'    = $data.connectionProtocol;
                'RoutingWeight'         = $data.routingWeight;
                'ConnectionMode'        = $data.connectionMode;
            }

            $tmp += $obj
        }

        $tmp
    }
}
else
{
    if($SmaResources.Connections)
    {
        $TableName = ('Connections_'+($SmaResources.Connections.id | Select-Object -Unique).count)
        $Style = New-ExcelStyle -HorizontalAlignment Center -AutoSize -NumberFormat '0'

        $Exc = New-Object System.Collections.Generic.List[System.Object]
        $Exc.Add('Subscription')
        $Exc.Add('ResourceGroup')
        $Exc.Add('Name')
        $Exc.Add('Location')
        $Exc.Add('Type')
        $Exc.Add('Status')
        $Exc.Add('ConnectionProtocol')
        $Exc.Add('RoutingWeight')
        $Exc.Add('ConnectionMode')

        $ExcelVar = $SmaResources.Connections  

        $ExcelVar | 
        ForEach-Object { [PSCustomObject]$_ } | Select-Object -Unique $Exc | 
        Export-Excel -Path $File -WorksheetName 'Connections' -AutoSize -MaxAutoSizeRows 100 -TableName $TableName -TableStyle $tableStyle -Style $Style
    }
}