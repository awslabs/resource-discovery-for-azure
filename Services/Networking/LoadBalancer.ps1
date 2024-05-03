param($SCPath, $Sub, $Resources, $Task ,$File, $SmaResources, $TableStyle, $Metrics)

if ($Task -eq 'Processing') 
{
    $LoadBalancer = $Resources | Where-Object { $_.TYPE -eq 'microsoft.network/loadbalancers' }

    if($LoadBalancer)
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
else 
{
    if ($SmaResources.LoadBalancer) 
    {
        $TableName = ('LBTable_'+($SmaResources.LoadBalancer.id | Select-Object -Unique).count)                        
        $Style = New-ExcelStyle -HorizontalAlignment Center -AutoSize -NumberFormat 0

        $Exc = New-Object System.Collections.Generic.List[System.Object]
        $Exc.Add('Subscription')
        $Exc.Add('ResourceGroup')
        $Exc.Add('Name')
        $Exc.Add('Location')
        $Exc.Add('SKU')
        $Exc.Add('SKUTier')
        $Exc.Add('RuleCount')

        $ExcelVar = $SmaResources.LoadBalancer 

        $ExcelVar | 
        ForEach-Object { [PSCustomObject]$_ } | Select-Object -Unique $Exc | 
        Export-Excel -Path $File -WorksheetName 'Load Balancers' -AutoSize -MaxAutoSizeRows 100 -TableName $TableName -TableStyle $tableStyle -Style $Style
    }  
}