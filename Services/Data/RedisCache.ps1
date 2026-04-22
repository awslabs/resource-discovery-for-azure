param($SCPath, $Sub, $Resources, $Task ,$File, $SmaResources, $TableStyle, $Metrics, $ResourceIdDictionary)

if ($Task -eq 'Processing') 
{
    $RedisCache = @()
    $RedisCache += $Resources | Where-Object { $_.TYPE -eq 'microsoft.cache/redis' }
    $RedisCache += $Resources | Where-Object { $_.TYPE -eq 'microsoft.cache/redisenterprise' }

    if($RedisCache)
    {
        $tmp = @()

        foreach ($redisCacheInstance in $RedisCache) 
        {
            $subscription = $Sub | Where-Object { $_.id -eq $redisCacheInstance.subscriptionId }
            $data = $redisCacheInstance.Properties
            
            if($redisCacheInstance.Type -eq 'microsoft.cache/redis')
            {
                $obj = @{
                    'ID'                    = $redisCacheInstance.id;
                    'Subscription'          = $subscription.Name;
                    'ResourceGroup'         = $redisCacheInstance.ResourceGroup;
                    'Name'                  = $redisCacheInstance.Name;
                    'Location'              = $redisCacheInstance.Location;
                    'Sku'                   = $data.sku.name;
                    'Capacity'              = $data.sku.capacity;
                    'Family'                = $data.sku.family;
                }

                $tmp += $obj
            }
            else
            {
                $obj = @{
                    'ID'                    = $redisCacheInstance.id;
                    'Subscription'          = $subscription.Name;
                    'ResourceGroup'         = $redisCacheInstance.ResourceGroup;
                    'Name'                  = $redisCacheInstance.Name;
                    'Location'              = $redisCacheInstance.Location;
                    'Sku'                   = $redisCacheInstance.sku.name;
                    'Capacity'              = $redisCacheInstance.sku.capacity;
                    'Family'                = 'enterprise';
                }

                $tmp += $obj
            }
        }

        $tmp
    }
}
else 
{
    if ($SmaResources.RedisCache) 
    {
        $TableName = ('RedisCacheTable_'+($SmaResources.RedisCache.id | Select-Object -Unique).count)
        $condtxt = @()

        $Style = @()        
        
        $Exc = New-Object System.Collections.Generic.List[System.Object]
        $Exc.Add('Subscription')
        $Exc.Add('ResourceGroup')
        $Exc.Add('Name')                    
        $Exc.Add('Location')           
        $Exc.Add('Sku')                     
        $Exc.Add('Capacity')
        $Exc.Add('Family')       

        $ExcelVar = $SmaResources.RedisCache

        $ExcelVar | 
        ForEach-Object { [PSCustomObject]$_ } | Select-Object -Unique $Exc | 
        Export-Excel -Path $File -WorksheetName 'Redis Cache' -AutoSize -MaxAutoSizeRows 100 -TableName $TableName -TableStyle $tableStyle -ConditionalText $condtxt -Style $Style
    }
}
