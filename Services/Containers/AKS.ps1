param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $AKS = $Resources | Where-Object { $_.TYPE -eq 'microsoft.containerservice/managedclusters' }

    if ($AKS)
    {
        $Tmp = @()

        foreach ($1 in $AKS)
        {
            $Sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $Data = $1.PROPERTIES

            foreach ($2 in $Data.agentPoolProfiles)
            {
                # Recomputed on every node-pool iteration (not hoisted above this
                # loop): the cluster's tags are the SAME real values across all of
                # its node pools, but the obfuscation pass mutates $tag.Value on
                # the object instance it's given. Sharing one $tags array/element
                # instance across multiple $obj rows would let a value that was
                # already tokenized on row 1 be re-read (and re-keyed) as a "real"
                # value on row 2, corrupting $Global:TagValueDictionary. A fresh
                # Select-Object projection per row gives each row its own object
                # instances so the same real tag value still yields the same
                # token (determinism, P1), without aliasing across rows.
                $Tags = if (![string]::IsNullOrEmpty($1.tags.psobject.properties)) { $1.tags.psobject.properties | Select-Object Name, Value } else { $null }

                $Obj = @{
                    'ID'                        = $1.id;
                    'Subscription'              = $Sub1.Name;
                    'ResourceGroup'             = $1.RESOURCEGROUP;
                    'Name'                      = $1.NAME;
                    'Location'                  = $1.LOCATION;
                    'Sku'                       = $1.sku.name;
                    'SkuTier'                   = $1.sku.tier;
                    'KubernetesVersion'         = $Data.kubernetesVersion;
                    'LoadBalancerSku'           = $Data.networkProfile.loadBalancerSku;
                    'NodePoolName'              = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { Protect-FreeTextValue $2.name } else { $2.name };
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
                    'Tags'                      = $Tags;
                }

                $Tmp += $Obj
            }
        }

        $Tmp
    }
}
