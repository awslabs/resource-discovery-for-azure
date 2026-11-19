param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    # Match both Classic Front Door and Standard/Premium Front Door.
    # Classic uses microsoft.network/frontdoors; Standard/Premium lives under
    # Microsoft.Cdn/profiles with an AzureFrontDoor SKU (to avoid capturing regular CDN profiles).
    # SKU regex is anchored and symmetric with the tier classification below.
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

            # Tier identification.
            # Classic has a single tier; Standard/Premium are distinguished by SKU name
            # (Standard_AzureFrontDoor vs Premium_AzureFrontDoor).
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
                # Fallback — unexpected SKU string, preserve it so we don't silently mislabel.
                [string]$1.sku.name
            }

            # WAF detection differs per tier.
            # Classic: WAF policy is referenced from frontendEndpoints and we can name it.
            # Standard/Premium: WAF is attached via security policies (a sub-resource of the
            # profile) which aren't exposed on the profile resource in ARG. We output 'Unknown'
            # rather than claiming 'Enabled' based only on profile existence.
            $WAF = $false
            if ($1.TYPE -eq 'microsoft.network/frontdoors')
            {
                # Each frontend endpoint links its own WAF policy, or none. Name every distinct
                # policy, sorted by id and joined with ', ', and count the endpoints without one,
                # so a Front Door with an unprotected endpoint does not read as fully covered.
                $Endpoints = @($Data.frontendendpoints | Where-Object { $null -ne $_ })
                $WafIds = [System.Collections.Generic.List[string]]::new()
                foreach ($Endpoint in $Endpoints)
                {
                    $WafId = [string]$Endpoint.properties.webApplicationFirewallPolicyLink.id
                    if (-not [string]::IsNullOrEmpty($WafId)) { $WafIds.Add($WafId) }
                }
                if ($WafIds.Count -gt 0)
                {
                    $WafNames = foreach ($WafId in @($WafIds | Sort-Object -Unique))
                    {
                        if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0)
                        {
                            if ($ResourceIdDictionary.ContainsKey($WafId)) { $ResourceIdDictionary[$WafId] } else { 'obfuscated' }
                        }
                        else
                        {
                            # A link id that is not an ARM id has no name segment: keep it whole.
                            $WafName = $WafId.split('/')[8]
                            if ([string]::IsNullOrEmpty($WafName)) { $WafId } else { $WafName }
                        }
                    }
                    $WAF = @($WafNames) -join ', '
                    $NoWaf = $Endpoints.Count - $WafIds.Count
                    if ($NoWaf -gt 0) { $WAF += (' ({0} of {1} endpoints without WAF)' -f $NoWaf, $Endpoints.Count) }
                }
            }
            else
            {
                # Standard/Premium — security policy associations are not visible on the profile
                # itself; mark Unknown instead of asserting a WAF is attached.
                $WAF = 'Unknown'
            }

            # State with fallback chain
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
