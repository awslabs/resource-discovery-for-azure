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

            # properties.WorkspaceResourceId is the ARM id of the Log Analytics workspace
            # a workspace-based component stores its telemetry in. Without it the report
            # says IngestionMode='loganalytics' with no way to tell WHICH workspace, and
            # the workspace is itself a collected resource (Services/Analytics/
            # WrkSpace.ps1), so this is a real cross-reference rather than free text.
            #
            # The live value is a full ARM id carrying the subscription GUID and the
            # resource group name, so it MUST route through $ResourceIdDictionary in an
            # obfuscated run. ContainsKey is safe without any casing work of its own
            # because that dictionary is built with [StringComparer]::OrdinalIgnoreCase
            # (ResourceInventory.ps1) - do NOT "fix" this with a .ToLower().
            #
            # A classic component has no workspace at all and gets 'None', the sentinel
            # SQLVM, SQLDB and PublicIP already use for an absent cross-reference.
            # Obfuscation off emits the full raw id, matching the field name and the
            # id-valued convention of SQLVM's ParentVirtualMachine.
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
