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
                    # Compare against the string 'true' rather than a bare truth test: enableAutoScaling
                    # can arrive as a real bool, as $null, or as the stringified 'false' depending on the
                    # source path, and a bare test would treat the non-empty string 'false' as $true. Do
                    # not align this with the $null -ne tests below.
                    'Autoscale'                 = if ($2.enableAutoScaling -eq 'true') { 'true' } else { 'false' };
                    'AutoscaleMax'              = if ($null -ne $2.maxCount) { $2.maxCount } else { '0' };
                    'AutoscaleMin'              = if ($null -ne $2.minCount) { $2.minCount } else { '0' };
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

