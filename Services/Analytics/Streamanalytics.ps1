param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $Streamanalytics = $Resources | Where-Object { $_.TYPE -eq 'microsoft.streamanalytics/streamingjobs' }

    if ($Streamanalytics)
    {
        $Tmp = @()

        foreach ($1 in $Streamanalytics)
        {
            $Sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $Data = $1.PROPERTIES
            # These timestamps are optional on the Azure resource: a Stream Analytics
            # job that has never produced output (Created/Stopped, never started) returns
            # null for lastOutputEventTime / outputStartTime, and createdDate can be absent
            # too. Get-Date on a null value throws "Cannot bind parameter 'Date' ... Cannot
            # convert null to type System.DateTime", which previously killed the whole
            # Stream Analytics collector for the subscription. Guard each one and emit $null
            # when the source value is missing.
            $CreateDate = if ([string]::IsNullOrEmpty($Data.createdDate)) { $null } else { (get-date $Data.createdDate).ToString("yyyy-MM-dd HH:mm:ss") }
            $LastOutput = if ([string]::IsNullOrEmpty($Data.lastOutputEventTime)) { $null } else { (get-date $Data.lastOutputEventTime).ToString("yyyy-MM-dd HH:mm:ss:ffff") }
            $OutputStart = if ([string]::IsNullOrEmpty($Data.outputStartTime)) { $null } else { (get-date $Data.outputStartTime).ToString("yyyy-MM-dd HH:mm:ss:ffff") }

            $Obj = @{
                'ID'                               = $1.id;
                'Subscription'                     = $Sub1.Name;
                'ResourceGroup'                    = $1.RESOURCEGROUP;
                'Name'                             = $1.NAME;
                'Location'                         = $1.LOCATION;
                'SKU'                              = $Data.sku.name;
                'CompatibilityLevel'               = $Data.compatibilityLevel;
                'ContentStoragePolicy'             = $Data.contentStoragePolicy;
                'CreatedDate'                      = $CreateDate;
                'DataLocale'                       = $Data.dataLocale;
                'LateArrivalMaxDelaySeconds'       = $Data.eventsLateArrivalMaxDelayInSeconds;
                'OutOfOrderMaxDelaySeconds'        = $Data.eventsOutOfOrderMaxDelayInSeconds;
                'OutOfOrderPolicy'                 = $Data.eventsOutOfOrderPolicy;
                'JobState'                         = $Data.jobState;
                'JobType'                          = $Data.jobType;
                'LastOutputEventTime'              = $LastOutput;
                'OutputStartTime'                  = $OutputStart;
                'OutputErrorPolicy'                = $Data.outputErrorPolicy;
            }

            $Tmp += $Obj
        }

        $Tmp
    }
}
