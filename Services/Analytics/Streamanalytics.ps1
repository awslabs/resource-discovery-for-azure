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
            # Timestamps are optional: Get-Date on a null value throws and previously killed the whole Stream
            # Analytics collector for the subscription. Guard each one and emit $null when the source value is missing.
            $CreateDate = if ([string]::IsNullOrEmpty($Data.createdDate)) { $null } else { try { (get-date $Data.createdDate).ToString("yyyy-MM-dd HH:mm:ss") } catch { $null } }
            $LastOutput = if ([string]::IsNullOrEmpty($Data.lastOutputEventTime)) { $null } else { try { (get-date $Data.lastOutputEventTime).ToString("yyyy-MM-dd HH:mm:ss:ffff") } catch { $null } }
            $OutputStart = if ([string]::IsNullOrEmpty($Data.outputStartTime)) { $null } else { try { (get-date $Data.outputStartTime).ToString("yyyy-MM-dd HH:mm:ss:ffff") } catch { $null } }

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
