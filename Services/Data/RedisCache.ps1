param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $RedisCache = @()
    $RedisCache += $Resources | Where-Object { $_.TYPE -eq 'microsoft.cache/redis' }
    $RedisCache += $Resources | Where-Object { $_.TYPE -eq 'microsoft.cache/redisenterprise' }

    if ($RedisCache)
    {
        $Tmp = @()

        foreach ($redisCacheInstance in $RedisCache)
        {
            $Subscription = $Sub | Where-Object { $_.id -eq $redisCacheInstance.subscriptionId }
            $Data = $redisCacheInstance.Properties

            if ($redisCacheInstance.Type -eq 'microsoft.cache/redis')
            {
                $Obj = @{
                    'ID'                    = $redisCacheInstance.id;
                    'Subscription'          = $Subscription.Name;
                    'ResourceGroup'         = $redisCacheInstance.ResourceGroup;
                    'Name'                  = $redisCacheInstance.Name;
                    'Location'              = $redisCacheInstance.Location;
                    'Sku'                   = $Data.sku.name;
                    'Capacity'              = $Data.sku.capacity;
                    'Family'                = $Data.sku.family;
                }

                $Tmp += $Obj
            }
            else
            {
                $Obj = @{
                    'ID'                    = $redisCacheInstance.id;
                    'Subscription'          = $Subscription.Name;
                    'ResourceGroup'         = $redisCacheInstance.ResourceGroup;
                    'Name'                  = $redisCacheInstance.Name;
                    'Location'              = $redisCacheInstance.Location;
                    'Sku'                   = $redisCacheInstance.sku.name;
                    'Capacity'              = $redisCacheInstance.sku.capacity;
                    'Family'                = 'enterprise';
                }

                $Tmp += $Obj
            }
        }

        $Tmp
    }
}
