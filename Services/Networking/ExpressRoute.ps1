param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $expressroute = $Resources | Where-Object {$_.TYPE -eq 'microsoft.network/expressroutecircuits'}

    if($expressroute)
    {
        $tmp = @()

        foreach ($1 in $expressroute) 
        {
            $sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $data = $1.PROPERTIES
            $sku = $1.SKU
            
            $obj = @{
                'ID'                    = $1.id;
                'Subscription'          = $sub1.name;
                'ResourceGroup'         = $1.RESOURCEGROUP;
                'Name'                  = $1.NAME;
                'Location'              = $1.LOCATION;
                'Tier'                  = $sku.tier;
                'BillingModel'          = $sku.family;
                'CircuitStatus'         = $data.circuitProvisioningState;
                'ProviderStatus'        = $data.serviceProviderProvisioningState;
                'Provider'              = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { 'obfuscated' } else { $data.serviceProviderProperties.serviceProviderName };
                'Bandwidth'             = $data.bandwidthInMbps;
                'ERLocation'            = $data.peeringLocation;
                'GlobalReachEnabled'    = $data.globalReachEnabled;
            }

            $tmp += $obj
        }

        $tmp
    }
}
