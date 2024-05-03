param($SCPath, $Sub, $Resources, $Task ,$File, $SmaResources, $TableStyle, $Metrics)

if ($Task -eq 'Processing')
{
    $wrkspace = $Resources | Where-Object {$_.TYPE -eq 'microsoft.operationalinsights/workspaces'}

    if($wrkspace)
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
                'Currency'          = $Cost.Currency;
                'DailyCost'         = '{0:C}' -f $Cost.Cost;
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
else
{
    if($SmaResources.WrkSpace)
    {
        $TableName = ('WorkSpaceTable_'+($SmaResources.WrkSpace.id | Select-Object -Unique).count)
        $Style = New-ExcelStyle -HorizontalAlignment Center -AutoSize -NumberFormat '0.0'

        $condtxt = @()

        $Exc = New-Object System.Collections.Generic.List[System.Object]
        $Exc.Add('Subscription')
        $Exc.Add('ResourceGroup')
        $Exc.Add('Name')
        $Exc.Add('Location')
        $Exc.Add('SKU')
        $Exc.Add('RetentionDays')
        $Exc.Add('DailyQuotaGB')
        $Exc.Add('CreatedTime')  

        $ExcelVar = $SmaResources.WrkSpace 

        $ExcelVar | 
        ForEach-Object { [PSCustomObject]$_ } | Select-Object -Unique $Exc | 
        Export-Excel -Path $File -WorksheetName 'Workspaces' -AutoSize -MaxAutoSizeRows 100 -ConditionalText $condtxt -TableName $TableName -TableStyle $tableStyle -Style $Style
    }
}