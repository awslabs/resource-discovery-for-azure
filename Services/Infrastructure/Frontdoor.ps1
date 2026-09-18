param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $FRONTDOOR = $Resources | Where-Object {
        $_.TYPE -eq 'microsoft.network/frontdoors' -or
        ($_.TYPE -eq 'microsoft.cdn/profiles' -and $_.sku.name -match '^(Standard|Premium)_AzureFrontDoor$')
    }

    if ($FRONTDOOR)
    {
        $Tmp = @()

        foreach ($1 in $FRONTDOOR)
        {
            $Sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $Data = $1.PROPERTIES

            $FrontDoorType = if ($1.TYPE -eq 'microsoft.network/frontdoors')
            {
                'Classic'
            }
            elseif ($1.sku.name -match '^Premium_AzureFrontDoor$')
            {
                'Premium'
            }
            elseif ($1.sku.name -match '^Standard_AzureFrontDoor$')
            {
                'Standard'
            }
            else
            {
                [string]$1.sku.name
            }

            $WAF = $false
            if ($1.TYPE -eq 'microsoft.network/frontdoors')
            {
                $WafId = $Data.frontendendpoints.properties.webApplicationFirewallPolicyLink.id |
                    Where-Object { -not [string]::IsNullOrEmpty($_) } |
                    Select-Object -First 1
                if (![string]::IsNullOrEmpty($WafId))
                {
                    $WAF = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0)
                    {
                        if ($ResourceIdDictionary.ContainsKey($WafId)) { $ResourceIdDictionary[$WafId] } else { 'obfuscated' }
                    }
                    else
                    {
                        $WafId.split('/')[8]
                    }
                }
            }
            else
            {
                $WAF = 'Unknown'
            }

            $State = if ($Data.enabledState) { $Data.enabledState }
            elseif ($Data.provisioningState) { $Data.provisioningState }
            else { 'Unknown' }

            $Obj = @{
                'ID'                        = $1.id;
                'Subscription'              = $Sub1.Name;
                'ResourceGroup'             = $1.RESOURCEGROUP;
                'Name'                      = $1.NAME;
                'Location'                  = $1.LOCATION;
                'Type'                      = $FrontDoorType;
                'ResourceType'              = $1.TYPE;
                'State'                     = $State;
                'WebApplicationFirewall'    = [string]$WAF;
            }

            $Tmp += $Obj
        }

        $Tmp
    }
}

