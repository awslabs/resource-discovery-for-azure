param($Sub, $Resources, $Task, $ResourceIdDictionary)

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
