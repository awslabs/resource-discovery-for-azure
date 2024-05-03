param($SCPath, $Sub, $Resources, $Task ,$File, $SmaResources, $TableStyle, $Metrics)

if ($Task -eq 'Processing') 
{
    $Streamanalytics = $Resources | Where-Object { $_.TYPE -eq 'microsoft.streamanalytics/streamingjobs' }

    if($Streamanalytics)
    {
        $tmp = @()

        foreach ($1 in $Streamanalytics) 
        {
            $sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $data = $1.PROPERTIES
            $CreateDate = (get-date $data.createdDate).ToString("yyyy-MM-dd HH:mm:ss")
            $LastOutput = (get-date $data.lastOutputEventTime).ToString("yyyy-MM-dd HH:mm:ss:ffff")
            $OutputStart = (get-date $data.outputStartTime).ToString("yyyy-MM-dd HH:mm:ss:ffff")

            $obj = @{
                'ID'                               = $1.id;
                'Subscription'                     = $sub1.Name;
                'ResourceGroup'                    = $1.RESOURCEGROUP;
                'Name'                             = $1.NAME;
                'Location'                         = $1.LOCATION;
                'SKU'                              = $data.sku.name;
                'CompatibilityLevel'               = $data.compatibilityLevel;
                'ContentStoragePolicy'             = $data.contentStoragePolicy;
                'CreatedDate'                      = $CreateDate;
                'DataLocale'                       = $data.dataLocale;
                'LateArrivalMaxDelaySeconds'       = $data.eventsLateArrivalMaxDelayInSeconds;
                'OutOfOrderMaxDelaySeconds'        = $data.eventsOutOfOrderMaxDelayInSeconds;
                'OutOfOrderPolicy'                 = $data.eventsOutOfOrderPolicy;
                'JobState'                         = $data.jobState;
                'JobType'                          = $data.jobType;
                'LastOutputEventTime'              = $LastOutput;
                'OutputStartTime'                  = $OutputStart;
                'OutputErrorPolicy'                = $data.outputErrorPolicy;
            }

            $tmp += $obj
        }
        
        $tmp
    }
}
else 
{
    if ($SmaResources.Streamanalytics) 
    {
        $TableName = ('StreamsATable_'+($SmaResources.Streamanalytics.id | Select-Object -Unique).count)
        $Style = New-ExcelStyle -HorizontalAlignment Center -AutoSize -NumberFormat 0
        
        $Exc = New-Object System.Collections.Generic.List[System.Object]
        $Exc.Add('Subscription')
        $Exc.Add('ResourceGroup')
        $Exc.Add('Name')
        $Exc.Add('Location')
        $Exc.Add('SKU')
        $Exc.Add('CompatibilityLevel')
        $Exc.Add('ContentStoragePolicy')
        $Exc.Add('CreatedDate')
        $Exc.Add('DataLocale')
        $Exc.Add('LateArrivalMaxDelaySeconds')
        $Exc.Add('OutofOrderMaxDelaySeconds')
        $Exc.Add('OutOfOrderPolicy')
        $Exc.Add('Jobstate')
        $Exc.Add('JobType')
        $Exc.Add('LastOutputEventTime')
        $Exc.Add('OutputStartTime')
        $Exc.Add('OutputErrorPolicy')

        $ExcelVar = $SmaResources.Streamanalytics 

        $ExcelVar | 
        ForEach-Object { [PSCustomObject]$_ } | Select-Object -Unique $Exc | 
        Export-Excel -Path $File -WorksheetName 'Stream Analytics Jobs' -AutoSize -MaxAutoSizeRows 100 -TableName $TableName -TableStyle $tableStyle -Style $Style
    }
}