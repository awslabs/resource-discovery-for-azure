param($SCPath, $Sub, $Resources, $Task ,$File, $SmaResources, $TableStyle, $Metrics)

if ($Task -eq 'Processing') 
{
    $SQLSERVERMIDB = $Resources | Where-Object { $_.TYPE -eq 'microsoft.sql/managedinstances/databases' }

    if($SQLSERVERMIDB)
    {
        $tmp = @()

        foreach ($1 in $SQLSERVERMIDB) 
        {
            $sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $data = $1.PROPERTIES

            $obj = @{
                'ID'                        = $1.id;
                'Subscription'              = $sub1.Name;
                'ManagedInstance'           = $1.id.split("/")[8];
                'Name'                      = $1.NAME;
                'Collation'                 = $data.collation;
                'CreationDate'              = $data.creationDate;
                'DefaultSecondaryLocation'  = $data.defaultSecondaryLocation;
                'Status'                    = $data.status;   
            } 
            
            $tmp += $obj
        }
        
        $tmp
    }
}
else 
{
    if ($SmaResources.SQLMIDB) 
    {
        $TableName = ('SQLMIDBTable_'+($SmaResources.SQLMIDB.id | Select-Object -Unique).count)
        $Style = New-ExcelStyle -HorizontalAlignment Center -AutoSize -NumberFormat 0

        $condtxt = @()

        $Exc = New-Object System.Collections.Generic.List[System.Object]
        $Exc.Add('Subscription')
        $Exc.Add('ManagedInstance')
        $Exc.Add('Name')
        $Exc.Add('Collation')
        $Exc.Add('CreationDate')
        $Exc.Add('DefaultSecondaryLocation')
        $Exc.Add('Status')

        $ExcelVar = $SmaResources.SQLMIDB

        $ExcelVar | 
        ForEach-Object { [PSCustomObject]$_ } | Select-Object -Unique $Exc | 
        Export-Excel -Path $File -WorksheetName 'SQL MI DBs' -AutoSize -MaxAutoSizeRows 100 -TableName $TableName -TableStyle $tableStyle -ConditionalText $condtxt -Style $Style
    }
}
