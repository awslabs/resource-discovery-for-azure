param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $LoadBalancer = $Resources | Where-Object { $_.TYPE -eq 'microsoft.network/loadbalancers' }

    if ($LoadBalancer)
    {
        $tmp = @()

        foreach ($1 in $LoadBalancer)
        {
            $sub1 = $SUB | Where-Object { $_.Id -eq $1.subscriptionId }
            $data = $1.PROPERTIES

            $ruleCount = $data.loadBalancingRules | Measure-Object

            $obj = @{
                'ID'                        = $1.id;
                'Subscription'              = $sub1.Name;
                'ResourceGroup'             = $1.RESOURCEGROUP;
                'Name'                      = $1.NAME;
                'Location'                  = $1.LOCATION;
                'SKU'                       = $1.sku.name;
                'SKUTier'                   = $1.sku.tier;
                'RuleCount'                 = $ruleCount.count;
            }

            $tmp += $obj
        }

        $tmp
    }
}
