param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $AppInsights = $Resources | Where-Object { $_.TYPE -eq 'microsoft.insights/components' }

    if ($AppInsights)
    {
        $Tmp = @()

        foreach ($1 in $AppInsights)
        {
            $Sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $Data = $1.PROPERTIES
            $Timecreated = 'Unknown'
            if ($null -ne $Data.CreationDate)
            {
                try
                {
                    $Timecreated = $Data.CreationDate
                    $Timecreated = [datetime]$Timecreated
                    $Timecreated = $Timecreated.ToString("yyyy-MM-dd HH:mm")
                }
                catch
                {
                    $Timecreated = 'Unknown'
                }
            }
            $Sampling = if ([string]::IsNullOrEmpty($Data.SamplingPercentage)) { 'Disabled' }else { $Data.SamplingPercentage }

            # WorkspaceResourceId (LA workspace ARM id) routes through $ResourceIdDictionary when obfuscating;
            # ContainsKey needs no .ToLower() (dictionary is OrdinalIgnoreCase). Classic components get 'None'.
            $WorkspaceId = [string]$Data.WorkspaceResourceId

            $WorkspaceRef = if ([string]::IsNullOrEmpty($WorkspaceId))
            {
                'None'
            }
            elseif ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0)
            {
                if ($ResourceIdDictionary.ContainsKey($WorkspaceId)) { $ResourceIdDictionary[$WorkspaceId] } else { 'obfuscated' }
            }
            else
            {
                $WorkspaceId
            }

            $Obj = @{
                'ID'                    = $1.id;
                'Subscription'          = $Sub1.Name;
                'ResourceGroup'         = $1.RESOURCEGROUP;
                'Name'                  = $1.NAME;
                'Location'              = $1.LOCATION;
                'ApplicationType'       = $Data.Application_Type;
                'FlowType'              = $Data.Flow_Type;
                'Version'               = $Data.Ver;
                'DataSampling'          = [string]$Sampling;
                'RetentionInDays'       = $Data.RetentionInDays;
                'IngestionMode'         = $Data.IngestionMode;
                'WorkspaceResourceId'   = $WorkspaceRef;
                'CreatedTime'           = $Timecreated;
            }

            $Tmp += $Obj
        }

        $Tmp
    }
}
