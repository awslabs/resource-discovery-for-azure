param($SCPath, $Sub, $Resources, $Task ,$File, $SmaResources, $TableStyle, $Metrics)

if ($Task -eq 'Processing') 
{
    $AppInsights = $Resources | Where-Object { $_.TYPE -eq 'microsoft.insights/components' }

    if($AppInsights)
    {
        $tmp = @()

        foreach ($1 in $AppInsights) 
        {
            $sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $data = $1.PROPERTIES
            $timecreated = $data.CreationDate
            $timecreated = [datetime]$timecreated
            $timecreated = $timecreated.ToString("yyyy-MM-dd HH:mm")
            $Sampling = if([string]::IsNullOrEmpty($data.SamplingPercentage)){'Disabled'}else{$data.SamplingPercentage}
            
            $obj = @{
                'ID'                    = $1.id;
                'Subscription'          = $sub1.Name;
                'ResourceGroup'         = $1.RESOURCEGROUP;
                'Name'                  = $1.NAME;
                'Location'              = $1.LOCATION;
                'ApplicationType'       = $data.Application_Type;
                'FlowType'              = $data.Flow_Type;
                'Version'               = $data.Ver;
                'DataSampling'          = [string]$Sampling;
                'RetentionInDays'       = $data.RetentionInDays;
                'IngestionMode'         = $data.IngestionMode;
                'CreatedTime'           = $timecreated;                            
            }

            $tmp += $obj
        }
        
        $tmp
    }
}
else 
{
    if ($SmaResources.AppInsights) 
    {
        $TableName = ('AppInsightsTable_'+($SmaResources.AppInsights.id | Select-Object -Unique).count)
        $Style = New-ExcelStyle -HorizontalAlignment Center -AutoSize -NumberFormat 0

        $condtxt = @()
        
        $Exc = New-Object System.Collections.Generic.List[System.Object]
        $Exc.Add('Subscription')
        $Exc.Add('ResourceGroup')
        $Exc.Add('Name')
        $Exc.Add('Location')
        $Exc.Add('ApplicationType')
        $Exc.Add('FlowType')
        $Exc.Add('Version')
        $Exc.Add('DataSampling')
        $Exc.Add('RetentionInDays')
        $Exc.Add('IngestionMode')
        $Exc.Add('CreatedTime')

        $ExcelVar = $SmaResources.AppInsights 

        $ExcelVar | 
        ForEach-Object { [PSCustomObject]$_ } | Select-Object -Unique $Exc | 
        Export-Excel -Path $File -WorksheetName 'AppInsights' -AutoSize -MaxAutoSizeRows 100 -TableName $TableName -TableStyle $tableStyle -Style $Style -ConditionalText $condtxt
    }
}