param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $APPGTW = $Resources | Where-Object { $_.TYPE -eq 'microsoft.network/applicationgateways' }

    if ($APPGTW)
    {
        $tmp = @()

        foreach ($1 in $APPGTW)
        {
            $sub1 = $SUB | Where-Object { $_.Id -eq $1.subscriptionId }
            $data = $1.PROPERTIES

            if ([string]::IsNullOrEmpty($data.autoscaleConfiguration.maxCapacity)) { $MaxCap = 'Autoscale Disabled' }else { $MaxCap = $data.autoscaleConfiguration.maxCapacity }
            if ([string]::IsNullOrEmpty($data.autoscaleConfiguration.minCapacity)) { $MinCap = 'Autoscale Disabled' }else { $MinCap = $data.autoscaleConfiguration.minCapacity }
            if ([string]::IsNullOrEmpty($data.sslPolicy.minProtocolVersion)) { $PROT = 'Default' }else { $PROT = $data.sslPolicy.minProtocolVersion }
            if ([string]::IsNullOrEmpty($data.webApplicationFirewallConfiguration.enabled)) { $WAF = $false }else { $WAF = $data.webApplicationFirewallConfiguration.enabled }

            $obj = @{
                'ID'                    = $1.id;
                'Subscription'          = $sub1.Name;
                'ResourceGroup'         = $1.RESOURCEGROUP;
                'Name'                  = $1.NAME;
                'Location'              = $1.LOCATION;
                'State'                 = $data.OperationalState;
                'WAFEnabled'            = $WAF;
                'MinimumTLSVersion'     = "$($PROT -Replace '_', '.' -Replace 'v', ' ' -Replace 'tls', 'TLS')";
                'AutoscaleMinCapacity'  = $MinCap;
                'AutoscaleMaxCapacity'  = $MaxCap;
                'SKUName'               = $data.sku.tier;
                'CurrentInstances'      = $data.sku.capacity;
            }

            $tmp += $obj
        }

        $tmp
    }
}
