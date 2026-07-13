param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $APPSvcPlan = $Resources | Where-Object { $_.TYPE -eq 'microsoft.web/serverfarms' }
    $APPAutoScale = $Resources | Where-Object { $_.TYPE -eq "microsoft.insights/autoscalesettings" -and $_.Properties.enabled -eq 'true' }

    if ($APPSvcPlan)
    {
        $tmp = @()

        foreach ($1 in $APPSvcPlan)
        {
            Remove-Variable AutoScale -ErrorAction SilentlyContinue

            $sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $data = $1.PROPERTIES
            $sku = $1.SKU
            $AutoScale = ($APPAutoScale | Where-Object { $_.Properties.targetResourceUri -eq $1.id })

            if ([string]::IsNullOrEmpty($AutoScale)) { $AutoSc = $false }else { $AutoSc = $true }

            $obj = @{
                'ID'                    = $1.id;
                'Subscription'          = $sub1.Name;
                'ResourceGroup'         = $1.RESOURCEGROUP;
                'Name'                  = $1.NAME;
                'Location'              = $1.LOCATION;
                'Tier'                  = $sku.tier;
                'Size'                  = $sku.name;
                'PricingTier'           = ($sku.tier + '(' + $sku.name + ': ' + $data.currentNumberOfWorkers + ')');
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
