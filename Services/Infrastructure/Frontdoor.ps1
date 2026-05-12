param($SCPath, $Sub, $Resources, $Task ,$File, $SmaResources, $TableStyle, $Metrics, $ResourceIdDictionary)

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

    if($FRONTDOOR)
    {
        $tmp = @()

        foreach ($1 in $FRONTDOOR) 
        {
            $sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $data = $1.PROPERTIES

            # Tier identification.
            # Classic has a single tier; Standard/Premium are distinguished by SKU name
            # (Standard_AzureFrontDoor vs Premium_AzureFrontDoor).
            $frontDoorType = if($1.TYPE -eq 'microsoft.network/frontdoors') 
            { 
                'Classic' 
            } 
            elseif($1.sku.name -match '^Premium_AzureFrontDoor$') 
            { 
                'Premium' 
            } 
            elseif($1.sku.name -match '^Standard_AzureFrontDoor$') 
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
            if($1.TYPE -eq 'microsoft.network/frontdoors') 
            {
                $wafId = $data.frontendendpoints.properties.webApplicationFirewallPolicyLink.id
                if(![string]::IsNullOrEmpty($wafId)) 
                {
                    $WAF = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { 
                        if ($ResourceIdDictionary.ContainsKey($wafId)) { $ResourceIdDictionary[$wafId] } else { 'obfuscated' } 
                    } else { 
                        $wafId.split('/')[8] 
                    }
                }
            } 
            else 
            {
                # Standard/Premium — security policy associations are not visible on the profile
                # itself; mark Unknown instead of asserting a WAF is attached.
                $WAF = 'Unknown'
            }

            # State with fallback chain
            $state = if($data.enabledState) { $data.enabledState } 
                     elseif($data.provisioningState) { $data.provisioningState }
                     else { 'Unknown' }

            $obj = @{
                'ID'                        = $1.id;
                'Subscription'              = $sub1.Name;
                'ResourceGroup'             = $1.RESOURCEGROUP;
                'Name'                      = $1.NAME;
                'Location'                  = $1.LOCATION;
                'Type'                      = $frontDoorType;
                'ResourceType'              = $1.TYPE;
                'State'                     = $state;
                'WebApplicationFirewall'    = [string]$WAF;
            }

            $tmp += $obj
        }

        $tmp
    }
}
else 
{
    if ($SmaResources.FRONTDOOR) 
    {
        # Deterministic dedup by composite key so rows with shared/empty IDs aren't silently
        # dropped. Group-Object keeps the first row for each unique combination.
        $deduped = $SmaResources.FrontDoor |
            ForEach-Object { [PSCustomObject]$_ } |
            Group-Object -Property {
                '{0}|{1}|{2}|{3}|{4}' -f $_.ID, $_.Name, $_.ResourceGroup, $_.Subscription, $_.Location
            } |
            ForEach-Object { $_.Group[0] }

        $uniqueCount = @($deduped).Count
        $TableName = ('FRONTDOORTable_' + $uniqueCount)
        $Style = New-ExcelStyle -HorizontalAlignment Center -AutoSize -NumberFormat 0

        $condtxt = @()

        $Exc = New-Object System.Collections.Generic.List[System.Object]
        $Exc.Add('Subscription')
        $Exc.Add('ResourceGroup')
        $Exc.Add('Name')
        $Exc.Add('Location')
        $Exc.Add('Type')
        $Exc.Add('State')
        $Exc.Add('ResourceType')
        $Exc.Add('WebApplicationFirewall')

        $deduped |
            Select-Object $Exc |
            Export-Excel -Path $File -WorksheetName 'FrontDoor' -AutoSize -MaxAutoSizeRows 100 -TableName $TableName -TableStyle $tableStyle -ConditionalText $condtxt -Style $Style
    }
}
