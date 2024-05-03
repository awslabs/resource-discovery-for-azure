param($SCPath, $Sub, $Resources, $Task, $File, $SmaResources, $TableStyle, $Metrics)

if ($Task -eq 'Processing') 
{
    $snapshots = $Resources | Where-Object { $_.TYPE -eq 'Microsoft.Compute/snapshots' }

    if($snapshots)
    {
        $tmp = @()

        foreach ($snapshot in $snapshots) 
        {
            $sub1 = $SUB | Where-Object { $_.Id -eq $snapshot.subscriptionId }
            $data = $snapshot.PROPERTIES
            $timecreated = $data.timeCreated
            $timecreated = [datetime]$timecreated
            $timecreated = $timecreated.ToString("yyyy-MM-dd HH:mm")
            
            $obj = @{
                'ID'                                    = $snapshot.id;
                'Subscription'                          = $sub1.Name;
                'ResourceGroup'                         = $snapshot.RESOURCEGROUP;
                'Name'                                  = $snapshot.NAME;
                'Location'                              = $snapshot.LOCATION;
                'Size'                                  = $data.diskSizeGB;
                'Sku'                                   = $snapshot.sku.name;
                'State'                                 = $data.provisioningState;
                'OS'                                    = $data.osType;
                'Incremental'                           = $data.incremental;
                'CreatedTime'                           = $timecreated;
                'SourceResourceId'                      = $data.creationData.sourceResourceId;
            }

            $tmp += $obj
        }

        $tmp
    }
}
else 
{
    if ($SmaResources.ComputeSnapshots) 
    {
        $TableName = ('ComputeSnapsTable_'+($SmaResources.ComputeSnapshots.id | Select-Object -Unique).count)
        $Style = @()
        
        $condtxt = @()

        $Exc = New-Object System.Collections.Generic.List[System.Object]
        $Exc.Add('Subscription')
        $Exc.Add('ResourceGroup')
        $Exc.Add('Name')
        $Exc.Add('Location')
        $Exc.Add('Size')
        $Exc.Add('Sku')
        $Exc.Add('State')
        $Exc.Add('OS')
        $Exc.Add('Incremental')
        $Exc.Add('CreatedTime')
        $Exc.Add('SourceResourceId')

        $ExcelVar = $SmaResources.ComputeSnapshots

        $ExcelVar |
        ForEach-Object { [PSCustomObject]$_ } | Select-Object -Unique $Exc |
        Export-Excel -Path $File -WorksheetName 'VM Snapshots' -AutoSize -MaxAutoSizeRows 100 -TableName $TableName -TableStyle $tableStyle -ConditionalText $condtxt -Style $Style
    }
}
