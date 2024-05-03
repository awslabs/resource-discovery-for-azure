param($SCPath, $Sub, $Resources, $Task ,$File, $SmaResources, $TableStyle, $Metrics)

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
                    'NodePoolName'              = $2.name;
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
else
{
    if($SmaResources.AKS)
    {
        $TableName = ('AKSTable_'+($SmaResources.AKS.id | Select-Object -Unique).count)
        $Style = New-ExcelStyle -HorizontalAlignment Center -AutoSize -NumberFormat '0'   

        $Exc = New-Object System.Collections.Generic.List[System.Object]
        $Exc.Add('Subscription')
        $Exc.Add('ResourceGroup')
        $Exc.Add('Name')
        $Exc.Add('Location')
        $Exc.Add('Sku')
        $Exc.Add('SkuTier')
        $Exc.Add('KubernetesVersion')
        $Exc.Add('LoadBalancerSku')
        $Exc.Add('NodePoolName')
        $Exc.Add('PoolProfileType')
        $Exc.Add('PoolMode')
        $Exc.Add('PoolOS')
        $Exc.Add('NodeSize')
        $Exc.Add('OSDiskSize')
        $Exc.Add('Nodes')
        $Exc.Add('Autoscale')
        $Exc.Add('AutoscaleMax')
        $Exc.Add('AutoscaleMin')
        $Exc.Add('MaxPodsPerNode')
        $Exc.Add('OrchestratorVersion')

        $ExcelVar = $SmaResources.AKS 

        $ExcelVar | 
        ForEach-Object { [PSCustomObject]$_ } | Select-Object -Unique $Exc | 
        Export-Excel -Path $File -WorksheetName 'AKS' -AutoSize -TableName $TableName -MaxAutoSizeRows 50 -TableStyle $tableStyle -Numberformat '0' -Style $Style            
    }
}
