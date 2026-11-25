param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $Streamanalytics = $Resources | Where-Object { $_.TYPE -eq 'microsoft.streamanalytics/streamingjobs' }

    if ($Streamanalytics)
    {
        $Tmp = [System.Collections.Generic.List[object]]::new()

        foreach ($1 in $Streamanalytics)
        {
            $Sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $Data = $1.PROPERTIES
            # These timestamps are optional on the Azure resource: a Stream Analytics
            # job that has never produced output (Created/Stopped, never started) returns
            # null for lastOutputEventTime / outputStartTime, and createdDate can be absent
            # too. Converting a null value to a date throws, which previously killed the
            # whole Stream Analytics collector for the subscription. Guard each one and emit
            # $null when the source value is missing. A value that is present but does
            # not convert to a date is 'Unknown' rather than an exception.
            # A valid value is written in UTC on every host; one with no zone is taken as UTC.
            $CreateDate = if ([string]::IsNullOrEmpty($Data.createdDate)) { $null } else { try { [datetime]::Parse($Data.createdDate, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]'AdjustToUniversal, AssumeUniversal').ToString("yyyy-MM-dd HH:mm:ss") } catch { 'Unknown' } }
            $LastOutput = if ([string]::IsNullOrEmpty($Data.lastOutputEventTime)) { $null } else { try { [datetime]::Parse($Data.lastOutputEventTime, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]'AdjustToUniversal, AssumeUniversal').ToString("yyyy-MM-dd HH:mm:ss:ffff") } catch { 'Unknown' } }
            $OutputStart = if ([string]::IsNullOrEmpty($Data.outputStartTime)) { $null } else { try { [datetime]::Parse($Data.outputStartTime, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]'AdjustToUniversal, AssumeUniversal').ToString("yyyy-MM-dd HH:mm:ss:ffff") } catch { 'Unknown' } }

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

            [void]$Tmp.Add($Obj)
        }

        $Tmp
    }
}
