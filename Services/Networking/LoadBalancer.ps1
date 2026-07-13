param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $LoadBalancer = $Resources | Where-Object { $_.TYPE -eq 'microsoft.network/loadbalancers' }

    if ($LoadBalancer)
    {
        $Tmp = @()

        foreach ($1 in $LoadBalancer)
        {
            $Sub1 = $SUB | Where-Object { $_.Id -eq $1.subscriptionId }
            $Data = $1.PROPERTIES

            $RuleCount = $Data.loadBalancingRules | Measure-Object

            $Obj = @{
                'ID'                        = $1.id;
                'Subscription'              = $Sub1.Name;
                'ResourceGroup'             = $1.RESOURCEGROUP;
                'Name'                      = $1.NAME;
                'Location'                  = $1.LOCATION;
                'SKU'                       = $1.sku.name;
                'SKUTier'                   = $1.sku.tier;
                'RuleCount'                 = $RuleCount.count;
            }

            $Tmp += $Obj
        }

        $Tmp
    }
}
