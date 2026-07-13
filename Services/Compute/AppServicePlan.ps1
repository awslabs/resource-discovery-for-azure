param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $APPSvcPlan = $Resources | Where-Object { $_.TYPE -eq 'microsoft.web/serverfarms' }
    $APPAutoScale = $Resources | Where-Object { $_.TYPE -eq "microsoft.insights/autoscalesettings" -and $_.Properties.enabled -eq 'true' }

    if ($APPSvcPlan)
    {
        $Tmp = @()

        foreach ($1 in $APPSvcPlan)
        {
            Remove-Variable AutoScale -ErrorAction SilentlyContinue

            $Sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $Data = $1.PROPERTIES
            $Sku = $1.SKU
            $AutoScale = ($APPAutoScale | Where-Object { $_.Properties.targetResourceUri -eq $1.id })

            if ([string]::IsNullOrEmpty($AutoScale)) { $AutoSc = $false }else { $AutoSc = $true }

            $Obj = @{
                'ID'                    = $1.id;
                'Subscription'          = $Sub1.Name;
                'ResourceGroup'         = $1.RESOURCEGROUP;
                'Name'                  = $1.NAME;
                'Location'              = $1.LOCATION;
                'Tier'                  = $Sku.tier;
                'Size'                  = $Sku.name;
                'PricingTier'           = ($Sku.tier + '(' + $Sku.name + ': ' + $Data.currentNumberOfWorkers + ')');
                'ComputeMode'           = $Data.computeMode;
                'InstanceSize'          = $Data.currentWorkerSize;
                'CurrentInstances'      = $Data.currentNumberOfWorkers;
                'Spot'                  = $Data.isSpot
                'AutoscaleEnabled'      = $AutoSc;
                'MaxInstances'          = $Data.maximumNumberOfWorkers;
                'AppPlanOS'             = if ($Data.reserved -eq 'true') { 'Linux' } else { 'Windows' };
                'AppsType'              = $Data.kind;
                'Apps'                  = $Data.numberOfSites;
                'ZoneRedundant'         = $Data.zoneRedundant;
            }

            $Tmp += $Obj
        }

        $Tmp
    }
}
