param($SCPath, $Sub, $Resources, $Task ,$File, $SmaResources, $TableStyle, $Metrics)

if ($Task -eq 'Processing') 
{
    $IOTHubs = $Resources | Where-Object { $_.TYPE -eq 'microsoft.devices/iothubs' }

    if($IOTHubs)
    {
        $tmp = @()

        foreach ($1 in $IOTHubs) 
        {
            $sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $data = $1.PROPERTIES
            
            foreach ($Tag in $Tags) 
            {
                $obj = @{
                    'ID'                                = $1.id;
                    'Subscription'                      = $sub1.Name;
                    'ResourceGroup'                     = $1.RESOURCEGROUP;
                    'Name'                              = $1.NAME;                                    
                    'SKU'                               = $data.sku.name;
                    'SKUTier'                           = $data.sku.tier;
                    'Location'                          = $loc.location;
                    'Role'                              = $loc.role;
                    'State'                             = $data.state;
                    'EventRetentionTimeInDays'          = [string]$data.eventHubEndpoints.events.retentionTimeInDays;
                    'EventPartitionCount'               = [string]$data.eventHubEndpoints.events.partitionCount;
                    'EventsPath'                        = [string]$data.eventHubEndpoints.events.path;
                    'MaxDeliveryCount'                  = [string]$data.cloudToDevice.maxDeliveryCount;
                    'HostName'                          = $data.hostName;
                }

                $tmp += $obj
            }              
        }

        $tmp
    }
}
else 
{
    if ($SmaResources.IOTHubs) 
    {
        $TableName = ('IOTHubsTable_'+($SmaResources.IOTHubs.id | Select-Object -Unique).count)
        $Style = New-ExcelStyle -HorizontalAlignment Center -AutoSize -NumberFormat 0
        
        $Exc = New-Object System.Collections.Generic.List[System.Object]
        $Exc.Add('Subscription')
        $Exc.Add('ResourceGroup')
        $Exc.Add('Name')
        $Exc.Add('Location')
        $Exc.Add('SKU')
        $Exc.Add('SKUTier')
        $Exc.Add('Location')
        $Exc.Add('Role')
        $Exc.Add('State')
        $Exc.Add('EventRetentionTimeInDays')
        $Exc.Add('EventPartitionCount')
        $Exc.Add('EventsPath')
        $Exc.Add('MaxDeliveryCount')
        $Exc.Add('HostName')

        $ExcelVar = $SmaResources.IOTHubs 

        $ExcelVar | 
        ForEach-Object { [PSCustomObject]$_ } | Select-Object -Unique $Exc | 
        Export-Excel -Path $File -WorksheetName 'IOTHubs' -AutoSize -MaxAutoSizeRows 100 -TableName $TableName -TableStyle $tableStyle -Style $Style
    }
}