param($SCPath, $Sub, $Resources, $Task ,$File, $SmaResources, $TableStyle, $Metrics)

if ($Task -eq 'Processing')
{
    $CONTAINER = $Resources | Where-Object {$_.TYPE -eq 'microsoft.containerinstance/containergroups'}

    if($CONTAINER)
    {
        $tmp = @()

        foreach ($1 in $CONTAINER) 
        {
            $sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $data = $1.PROPERTIES
            
            foreach ($2 in $data.containers) 
            {
                $obj = @{
                    'ID'                  = $1.id;
                    'Subscription'        = $sub1.Name;
                    'ResourceGroup'       = $1.RESOURCEGROUP;
                    'Name'                = $1.NAME;
                    'Location'            = $1.LOCATION;
                    'Sku'                 = $data.Sku;
                    'InstanceOSType'      = $data.osType;
                    'ContainerName'       = $2.name;
                    'ContainerState'      = $2.properties.instanceView.currentState.state;
                    'ContainerImage'      = [string]$2.properties.image;
                    'RestartCount'        = $2.properties.instanceView.restartCount;
                    'StartTime'           = $2.properties.instanceView.currentState.startTime;
                    'Command'             = [string]$2.properties.command;
                    'RequestCPU'          = $2.properties.resources.requests.cpu;
                    'RequestMemoryGB'     = $2.properties.resources.requests.memoryInGB;
                }

                $tmp += $obj
            }
        }

        $tmp
    }
}
else
{
    if($SmaResources.CONTAINER)
    {
        $TableName = ('ContsTable_'+($SmaResources.CONTAINER.id | Select-Object -Unique).count)
        $Style = New-ExcelStyle -HorizontalAlignment Center -AutoSize -NumberFormat '0'

        $Exc = New-Object System.Collections.Generic.List[System.Object]
        $Exc.Add('Subscription')
        $Exc.Add('ResourceGroup')
        $Exc.Add('Name')
        $Exc.Add('Location')
        $Exc.Add('Sku')
        $Exc.Add('InstanceOSType')
        $Exc.Add('ContainerName')
        $Exc.Add('ContainerState')
        $Exc.Add('ContainerImage')
        $Exc.Add('RestartCount')
        $Exc.Add('StartTime')
        $Exc.Add('Command')
        $Exc.Add('RequestCPU')
        $Exc.Add('RequestMemoryGB')

        $ExcelVar = $SmaResources.CONTAINER 
            
        $ExcelVar | 
        ForEach-Object { [PSCustomObject]$_ } | Select-Object -Unique $Exc | 
        Export-Excel -Path $File -WorksheetName 'Containers' -AutoSize -MaxAutoSizeRows 100 -TableName $TableName -TableStyle $tableStyle -Style $Style
    }
}