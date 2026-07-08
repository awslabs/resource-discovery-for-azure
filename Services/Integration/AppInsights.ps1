param($Sub, $Resources, $Task, $ResourceIdDictionary)

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
