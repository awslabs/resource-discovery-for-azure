param($SCPath, $Sub, $Resources, $Task ,$File, $SmaResources, $TableStyle, $Metrics)

if ($Task -eq 'Processing')
{
    $disks = $Resources | Where-Object {$_.TYPE -eq 'microsoft.compute/disks'}

    if($disks)
    {
        $tmp = @() 
                   
        foreach ($disk in $disks) 
        {
            $sub1 = $SUB | Where-Object { $_.Id -eq $disk.subscriptionId }
            $data = $disk.PROPERTIES
            $timecreated = $data.timeCreated
            $timecreated = [datetime]$timecreated
            $timecreated = $timecreated.ToString("yyyy-MM-dd HH:mm")
            $SKU = $disk.SKU
            
            $obj = @{
                'ID'                    = $disk.id;
                'Subscription'          = $sub1.Name;
                'ResourceGroup'         = $disk.RESOURCEGROUP;
                'Name'                  = $disk.NAME;
                'State'                 = $data.diskState;
                'AssociatedResource'    = $disk.MANAGEDBY.split('/')[8];
                'Location'              = $disk.LOCATION;
                'SKU'                   = $SKU.Name;
                'Tier'                  = $data.Tier;
                'Size'                  = $data.diskSizeGB;
                'OSType'                = $data.osType;
                'DiskIOPS'              = $data.diskIOPSReadWrite;
                'DiskMBps'              = $data.diskMBpsReadWrite;
                'CreatedTime'           = $timecreated;   
            }

            $tmp += $obj
        }

        $tmp
    }
}
else
{
    if($SmaResources.VMDisk)
    {
        $TableName = ('VMDiskT_'+($SmaResources.VMDisk.id | Select-Object -Unique).count)
        $condtxt = @()
        $Style = New-ExcelStyle -HorizontalAlignment Center -AutoSize -NumberFormat '0'

        $Exc = New-Object System.Collections.Generic.List[System.Object]
        $Exc.Add('Subscription')
        $Exc.Add('ResourceGroup')
        $Exc.Add('Name')
        $Exc.Add('Tier')
        $Exc.Add('State')
        $Exc.Add('AssociatedResource')        
        $Exc.Add('SKU')
        $Exc.Add('Size')
        $Exc.Add('Location')
        $Exc.Add('OSType')        
        $Exc.Add('DiskIOPS')
        $Exc.Add('DiskMBps')
        $Exc.Add('CreatedTime')

        $ExcelVar = $SmaResources.VMDisk

        $ExcelVar | 
        ForEach-Object { [PSCustomObject]$_ } | Select-Object -Unique $Exc | 
        Export-Excel -Path $File -WorksheetName 'Disks' -TableName $TableName -MaxAutoSizeRows 100 -TableStyle $tableStyle -ConditionalText $condtxt -Style $Style
    }
}