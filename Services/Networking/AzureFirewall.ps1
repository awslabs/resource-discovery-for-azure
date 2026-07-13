param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $AzureFirewall = $Resources | Where-Object { $_.TYPE -eq 'microsoft.network/azurefirewalls' }

    if ($AzureFirewall)
    {
        $tmp = @()

        foreach ($1 in $AzureFirewall)
        {
            $sub1 = $SUB | Where-Object { $_.Id -eq $1.subscriptionId }
            $data = $1.PROPERTIES

            $obj = @{
                'ID'                                = $1.id;
                'Subscription'                      = $sub1.Name;
                'ResourceGroup'                     = $1.RESOURCEGROUP;
                'Name'                              = $1.NAME;
                'Location'                          = $1.LOCATION;
                'SKU'                               = $data.sku.tier;
            }

            $tmp += $obj
        }

        $tmp
    }
}
