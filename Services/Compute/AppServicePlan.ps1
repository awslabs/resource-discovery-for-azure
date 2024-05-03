param($SCPath, $Sub, $Resources, $Task ,$File, $SmaResources, $TableStyle, $Metrics)

if ($Task -eq 'Processing')
{
    $APPSvcPlan = $Resources | Where-Object {$_.TYPE -eq 'microsoft.web/serverfarms'}
    $APPAutoScale = $Resources | Where-Object {$_.TYPE -eq "microsoft.insights/autoscalesettings" -and $_.Properties.enabled -eq 'true'}

    if($APPSvcPlan)
    {
        $tmp = @()

        foreach ($1 in $APPSvcPlan) 
        {
            Remove-Variable AutoScale -ErrorAction SilentlyContinue

            $sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $data = $1.PROPERTIES
            $sku = $1.SKU
            $AutoScale = ($APPAutoScale | Where-Object {$_.Properties.targetResourceUri -eq $1.id})

            if([string]::IsNullOrEmpty($AutoScale)){$AutoSc = $false}else{$AutoSc = $true}

            $obj = @{
                'ID'                    = $1.id;
                'Subscription'          = $sub1.Name;
                'ResourceGroup'         = $1.RESOURCEGROUP;
                'Name'                  = $1.NAME;
                'Location'              = $1.LOCATION;
                'Tier'                  = $sku.tier;
                'Size'                  = $sku.name;
                'PricingTier'           = ($sku.tier+'('+$sku.name+': '+$data.currentNumberOfWorkers+')');
                'ComputeMode'           = $data.computeMode;
                'InstanceSize'          = $data.currentWorkerSize;
                'CurrentInstances'      = $data.currentNumberOfWorkers;
                'Spot'                  = $data.isSpot
                'AutoscaleEnabled'      = $AutoSc;
                'MaxInstances'          = $data.maximumNumberOfWorkers;                                                            
                'AppPlanOS'             = if ($data.reserved -eq 'true') { 'Linux' } else { 'Windows' };
                'AppsType'              = $data.kind;
                'Apps'                  = $data.numberOfSites;                    
                'ZoneRedundant'         = $data.zoneRedundant;
            }

            $tmp += $obj    
        }

        $tmp
    }   
}
else
{
    if($SmaResources.AppServicePlan)
    {
        $TableName = ('AppSvcPlanTable_'+($SmaResources.AppServicePlan.id | Select-Object -Unique).count)
        $Style = New-ExcelStyle -HorizontalAlignment Center -AutoSize -NumberFormat '0'
       
        $Exc = New-Object System.Collections.Generic.List[System.Object]
        $Exc.Add('Subscription')
        $Exc.Add('ResourceGroup')
        $Exc.Add('Name')
        $Exc.Add('Location')
        $Exc.Add('Tier')
        $Exc.Add('Size')
        $Exc.Add('PricingTier')
        $Exc.Add('ComputeMode')
        $Exc.Add('InstanceSize')
        $Exc.Add('CurrentInstances')
        $Exc.Add('Spot')
        $Exc.Add('AutoscaleEnabled')
        $Exc.Add('MaxInstances')
        $Exc.Add('AppPlanOS')
        $Exc.Add('AppsType')
        $Exc.Add('Apps')
        $Exc.Add('ZoneRedundant')

        $ExcelVar =  $SmaResources.AppServicePlan 

        $ExcelVar | 
        ForEach-Object { [PSCustomObject]$_ } | Select-Object -Unique $Exc | 
        Export-Excel -Path $File -WorksheetName 'App Service Plan' -AutoSize -MaxAutoSizeRows 100 -TableName $TableName -TableStyle $tableStyle -Style $Style
    }
}