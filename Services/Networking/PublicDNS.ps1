param($SCPath, $Sub, $Resources, $Task ,$File, $SmaResources, $TableStyle, $Metrics)

if ($Task -eq 'Processing') 
{
    $PublicDNS = $Resources | Where-Object { $_.TYPE -eq 'microsoft.network/dnszones' }

    if($PublicDNS)
    {
        $tmp = @()

        foreach ($1 in $PublicDNS) 
        {
            $sub1 = $SUB | Where-Object { $_.Id -eq $1.subscriptionId }
            $data = $1.PROPERTIES
            
            $obj = @{
                'ID'                        = $1.id;
                'Subscription'              = $sub1.Name;
                'ResourceGroup'             = $1.RESOURCEGROUP;
                'Name'                      = $1.NAME;
                'Location'                  = $1.LOCATION;
                'ZoneType'                  = $data.zoneType;
                'NumberOfRecordSets'        = $data.numberOfRecordSets;
                'MaxNumberOfRecordSets'     = $data.maxNumberofRecordSets;
            }

            $tmp += $obj
        }

        $tmp
    }
}
else 
{
    if ($SmaResources.PublicDNS) 
    {
        $TableName = ('PubDNSTable_'+($SmaResources.PublicDNS.id | Select-Object -Unique).count)
        $Style = New-ExcelStyle -HorizontalAlignment Center -AutoSize -NumberFormat 0

        $condtxt = @()

        $Exc = New-Object System.Collections.Generic.List[System.Object]
        $Exc.Add('Subscription')
        $Exc.Add('ResourceGroup')
        $Exc.Add('Name')
        $Exc.Add('Location')
        $Exc.Add('ZoneType')
        $Exc.Add('NumberOfRecordSets')
        $Exc.Add('MaxNumberOfRecordSets')

        $ExcelVar = $SmaResources.PublicDNS 

        $ExcelVar | 
        ForEach-Object { [PSCustomObject]$_ } | Select-Object -Unique $Exc | 
        Export-Excel -Path $File -WorksheetName 'Public DNS' -AutoSize -MaxAutoSizeRows 100 -TableName $TableName -TableStyle $tableStyle -ConditionalText $condtxt -Style $Style

    }
}