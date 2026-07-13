param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $wrkspace = $Resources | Where-Object { $_.TYPE -eq 'microsoft.operationalinsights/workspaces' }

    if ($wrkspace)
    {
        $tmp = @()

        foreach ($1 in $wrkspace)
        {
            $sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $data = $1.PROPERTIES
            $timecreated = [datetime]($data.createdDate) | Get-Date -Format "yyyy-MM-dd HH:mm"

            $obj = @{
                'ID'                = $1.id;
                'Subscription'      = $sub1.Name;
                'ResourceGroup'     = $1.RESOURCEGROUP;
                'Name'              = $1.NAME;
                'Location'          = $1.LOCATION;
                'SKU'               = $data.sku.name;
                'RetentionDays'     = $data.retentionInDays;
                'DailyQuotaGB'      = [decimal]$data.workspaceCapping.dailyQuotaGb;
                'CreatedTime'       = $timecreated;
            }

            $tmp += $obj
        }

        $tmp
    }
}
