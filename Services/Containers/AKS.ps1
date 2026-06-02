param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $AKS = $Resources | Where-Object {$_.TYPE -eq 'microsoft.containerservice/managedclusters'}

    if($AKS)
    {
        $tmp = @()

        foreach ($1 in $AKS) 
        {
            $sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $data = $1.PROPERTIES

            foreach ($2 in $data.agentPoolProfiles) 
            {
                $obj = @{
                    'ID'                        = $1.id;
                    'Subscription'              = $sub1.Name;
                    'ResourceGroup'             = $1.RESOURCEGROUP;
                    'Name'                      = $1.NAME;
                    'Location'                  = $1.LOCATION;
                    'Sku'                       = $1.sku.name;
                    'SkuTier'                   = $1.sku.tier;
                    'KubernetesVersion'         = $data.kubernetesVersion;
                    'LoadBalancerSku'           = $data.networkProfile.loadBalancerSku;                
                    'NodePoolName'              = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { 'obfuscated' } else { $2.name };
                    'PoolProfileType'           = $2.type;
                    'PoolMode'                  = $2.mode;
                    'PoolOS'                    = $2.osType;
                    'NodeSize'                  = $2.vmSize;
                    'OSDiskSize'                = $2.osDiskSizeGB;
                    'Nodes'                     = $2.count;
                    'Autoscale'                 = if ($null -ne $2.enableAutoScaling) { 'true' } else { 'false' }
                    'AutoscaleMax'              = if ($null -ne $2.maxCount) { $2.maxCount } else { '0' }
                    'AutoscaleMin'              = if ($null -ne $2.minCount) { $2.minCount } else { '0' }
                    'MaxPodsPerNode'            = $2.maxPods;
                    'OrchestratorVersion'       = $2.orchestratorVersion;
                }

                $tmp += $obj
            }
        }

        $tmp
    }
}
