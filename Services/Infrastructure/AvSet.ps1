param($SCPath, $Sub, $Resources, $Task ,$File, $SmaResources, $TableStyle, $Metrics)

if ($Task -eq 'Processing')
{
    $AvSet = $Resources | Where-Object {$_.TYPE -eq 'microsoft.compute/availabilitysets'}

    if($AvSet)
    {
        $tmp = @()

        foreach ($1 in $AvSet) 
        {
            $sub1 = $SUB | Where-Object { $_.Id -eq $1.subscriptionId }
            $data = $1.PROPERTIES
            
            foreach ($vmid in $data.virtualMachines.id) 
            {
                $vmIds = $vmid.split('/')[8]
                
                $obj = @{
                    'ID'               = $1.id;
                    'Subscription'     = $sub1.Name;
                    'ResourceGroup'    = $1.RESOURCEGROUP;
                    'Name'             = $1.NAME;
                    'Location'         = $1.LOCATION;
                    'FaultDomains'     = [string]$data.platformFaultDomainCount;
                    'UpdateDomains'    = [string]$data.platformUpdateDomainCount;
                    'VirtualMachines'  = [string]$vmIds;
                }

                $tmp += $obj                 
            }
        }

        $tmp
    }
}
else
{
    if($SmaResources.AvSet)
    {

        $TableName = ('AvSetTable_'+($SmaResources.AvSet.id | Select-Object -Unique).count)
        $Style = New-ExcelStyle -HorizontalAlignment Center -AutoSize -NumberFormat '0'
            
        $Exc = New-Object System.Collections.Generic.List[System.Object]
        $Exc.Add('Subscription')
        $Exc.Add('ResourceGroup')
        $Exc.Add('Name')
        $Exc.Add('Location')
        $Exc.Add('FaultDomains')
        $Exc.Add('UpdateDomains')
        $Exc.Add('VirtualMachines')

        $ExcelVar = $SmaResources.AvSet  

        $ExcelVar | 
        ForEach-Object { [PSCustomObject]$_ } | Select-Object -Unique $Exc | 
        Export-Excel -Path $File -WorksheetName 'Availability Sets' -AutoSize -MaxAutoSizeRows 100 -TableName $TableName -TableStyle $tableStyle -Style $Style
    }
}