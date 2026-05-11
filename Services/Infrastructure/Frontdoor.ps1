param($SCPath, $Sub, $Resources, $Task ,$File, $SmaResources, $TableStyle, $Metrics, $ResourceIdDictionary)

if ($Task -eq 'Processing') 
{
    # Match both Classic Front Door and Standard/Premium Front Door.
    # Classic uses microsoft.network/frontdoors; Standard/Premium lives under
    # Microsoft.Cdn/profiles with an AzureFrontDoor SKU (to avoid capturing regular CDN profiles).
    $FRONTDOOR = $Resources | Where-Object { 
        $_.TYPE -eq 'microsoft.network/frontdoors' -or 
        ($_.TYPE -eq 'microsoft.cdn/profiles' -and $_.sku.name -match 'AzureFrontDoor')
    }

    if($FRONTDOOR)
    {
        $tmp = @()

        foreach ($1 in $FRONTDOOR) 
        {
            $sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $data = $1.PROPERTIES

            # Tier identification
            $frontDoorType = if($1.TYPE -eq 'microsoft.network/frontdoors') { 'Classic' } else { 'Standard/Premium' }

            # WAF detection differs per tier
            $WAF = $false
            if($1.TYPE -eq 'microsoft.network/frontdoors') 
            {
                # Classic Front Door — WAF policy is referenced from frontendEndpoints
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
                # Standard/Premium Front Door — WAF presence indicated by frontDoorId existence on the profile
                if(![string]::IsNullOrEmpty($data.frontDoorId)) 
                {
                    $WAF = 'Enabled'
                }
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
        $uniqueCount = ($SmaResources.FRONTDOOR | Select-Object -Property ID -Unique).Count
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

        $ExcelVar = $SmaResources.FrontDoor 

        # Sort by ID first so the -Unique deduplication is deterministic across PowerShell versions
        $ExcelVar | 
        ForEach-Object { [PSCustomObject]$_ } | 
        Sort-Object -Property ID -Unique |
        Select-Object $Exc | 
        Export-Excel -Path $File -WorksheetName 'FrontDoor' -AutoSize -MaxAutoSizeRows 100 -TableName $TableName -TableStyle $tableStyle -ConditionalText $condtxt -Style $Style
    }
}
