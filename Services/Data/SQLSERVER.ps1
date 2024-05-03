param($SCPath, $Sub, $Resources, $Task ,$File, $SmaResources, $TableStyle, $Metrics)

if ($Task -eq 'Processing') 
{
    $SQLSERVER = $Resources | Where-Object { $_.TYPE -eq 'microsoft.sql/servers' }

    if($SQLSERVER)
    {
        $tmp = @()

        foreach ($1 in $SQLSERVER) 
        {
            $sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $data = $1.PROPERTIES

            $obj = @{
                'ID'                    = $1.id;
                'Subscription'          = $sub1.Name;
                'ResourceGroup'         = $1.RESOURCEGROUP;
                'Name'                  = $1.NAME;
                'Location'              = $1.LOCATION;
                'Kind'                  = $1.kind;
                'State'                 = $data.state;
                'Version'               = $data.version;
                'ZoneRedundant'         = $1.zones;
            }

            $tmp += $obj       
        }

        $tmp
    }
}
else 
{
    if ($SmaResources.SQLSERVER) 
    {
        $TableName = ('SQLSERVERTable_'+($SmaResources.SQLSERVER.id | Select-Object -Unique).count)
        $Style = New-ExcelStyle -HorizontalAlignment Center -AutoSize -NumberFormat 0

        $condtxt = @()

        $Exc = New-Object System.Collections.Generic.List[System.Object]
        $Exc.Add('Subscription')
        $Exc.Add('ResourceGroup')
        $Exc.Add('Name')
        $Exc.Add('Location')
        $Exc.Add('Kind')
        $Exc.Add('State')
        $Exc.Add('Version')
        $Exc.Add('ZoneRedundant')

        $ExcelVar = $SmaResources.SQLSERVER 

        $ExcelVar | 
        ForEach-Object { [PSCustomObject]$_ } | Select-Object -Unique $Exc | 
        Export-Excel -Path $File -WorksheetName 'SQL Servers' -AutoSize -MaxAutoSizeRows 100 -TableName $TableName -TableStyle $tableStyle -ConditionalText $condtxt -Style $Style
    }
}