param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $APPGTW = $Resources | Where-Object { $_.TYPE -eq 'microsoft.network/applicationgateways' }

    if ($APPGTW)
    {
        $Tmp = @()

        foreach ($1 in $APPGTW)
        {
            $Sub1 = $SUB | Where-Object { $_.Id -eq $1.subscriptionId }
            $Data = $1.PROPERTIES

            if ([string]::IsNullOrEmpty($Data.autoscaleConfiguration.maxCapacity)) { $MaxCap = 'Autoscale Disabled' }else { $MaxCap = $Data.autoscaleConfiguration.maxCapacity }
            if ([string]::IsNullOrEmpty($Data.autoscaleConfiguration.minCapacity)) { $MinCap = 'Autoscale Disabled' }else { $MinCap = $Data.autoscaleConfiguration.minCapacity }
            if ([string]::IsNullOrEmpty($Data.sslPolicy.minProtocolVersion)) { $PROT = 'Default' }else { $PROT = $Data.sslPolicy.minProtocolVersion }
            if ([string]::IsNullOrEmpty($Data.webApplicationFirewallConfiguration.enabled)) { $WAF = $false }else { $WAF = $Data.webApplicationFirewallConfiguration.enabled }

            $Obj = @{
                'ID'                    = $1.id;
                'Subscription'          = $Sub1.Name;
                'ResourceGroup'         = $1.RESOURCEGROUP;
                'Name'                  = $1.NAME;
                'Location'              = $1.LOCATION;
                'State'                 = $Data.OperationalState;
                'WAFEnabled'            = $WAF;
                'MinimumTLSVersion'     = "$($PROT -Replace '_', '.' -Replace 'v', ' ' -Replace 'tls', 'TLS')";
                'AutoscaleMinCapacity'  = $MinCap;
                'AutoscaleMaxCapacity'  = $MaxCap;
                'SKUName'               = $Data.sku.tier;
                'CurrentInstances'      = $Data.sku.capacity;
            }

            $Tmp += $Obj
        }

        $Tmp
    }
}
