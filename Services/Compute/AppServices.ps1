param($SCPath, $Sub, $Resources, $Task ,$File, $SmaResources, $TableStyle, $Metrics)

If ($Task -eq 'Processing')
{
    $AppSvc = $Resources | Where-Object {$_.TYPE -eq 'microsoft.web/sites'}

    if($AppSvc)
    {
        $tmp = @()

        foreach ($1 in $AppSvc) 
        {
            $sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $data = $1.PROPERTIES

            $obj = @{
                'ID'                            = $1.id;
                'Subscription'                  = $sub1.Name;
                'ResourceGroup'                 = $1.RESOURCEGROUP;
                'Name'                          = $1.NAME;
                'AppType'                       = $1.KIND;
                'Location'                      = $1.LOCATION;
                'Enabled'                       = $data.enabled;
                'State'                         = $data.state;
                'SKU'                           = $data.sku;
                'AvailabilityState'             = $data.availabilityState;
                'SiteProperties'                = $data.siteProperties;          
                'ContainerSize'                 = $data.containerSize;
                'ServerFarmId'                  = $data.serverFarmId;
            }

            $tmp += $obj
        }
        
        $tmp
    }
}
Else
{
    if($SmaResources.AppServices)
    {
        $TableName = ('AppSvcsTable_'+($SmaResources.AppServices.id | Select-Object -Unique).count)
        $Style = New-ExcelStyle -HorizontalAlignment Center -AutoSize -NumberFormat '0'

        $Exc = New-Object System.Collections.Generic.List[System.Object]
        $Exc.Add('Subscription')
        $Exc.Add('ResourceGroup')
        $Exc.Add('Name')
        $Exc.Add('AppType')
        $Exc.Add('Location')
        $Exc.Add('Enabled')
        $Exc.Add('State')
        $Exc.Add('SKU')
        $Exc.Add('AvailabilityState')             
        $Exc.Add('ContainerSize')
        
        $ExcelVar = $SmaResources.AppServices 

        $ExcelVar | 
        ForEach-Object { [PSCustomObject]$_ } | Select-Object -Unique $Exc | 
        Export-Excel -Path $File -WorksheetName 'App Services' -AutoSize -MaxAutoSizeRows 100 -TableName $TableName -TableStyle $tableStyle -Style $Style
    }
}
