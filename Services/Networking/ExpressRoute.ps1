param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $Expressroute = $Resources | Where-Object { $_.TYPE -eq 'microsoft.network/expressroutecircuits' }

    if ($Expressroute)
    {
        $Tmp = @()

        foreach ($1 in $Expressroute)
        {
            $Sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $Data = $1.PROPERTIES
            $Sku = $1.SKU

            $Obj = @{
                'ID'                    = $1.id;
                'Subscription'          = $Sub1.name;
                'ResourceGroup'         = $1.RESOURCEGROUP;
                'Name'                  = $1.NAME;
                'Location'              = $1.LOCATION;
                'Tier'                  = $Sku.tier;
                'BillingModel'          = $Sku.family;
                'CircuitStatus'         = $Data.circuitProvisioningState;
                'ProviderStatus'        = $Data.serviceProviderProvisioningState;
                'Provider'              = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { 'obfuscated' } else { $Data.serviceProviderProperties.serviceProviderName };
                'Bandwidth'             = $Data.bandwidthInMbps;
                'ERLocation'            = $Data.peeringLocation;
                'GlobalReachEnabled'    = $Data.globalReachEnabled;
            }

            $Tmp += $Obj
        }

        $Tmp
    }
}
