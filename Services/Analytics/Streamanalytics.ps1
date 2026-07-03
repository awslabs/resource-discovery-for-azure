param($Sub, $Resources, $Task, $ResourceIdDictionary)

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
