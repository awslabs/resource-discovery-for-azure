param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $PublicIP = $Resources | Where-Object { $_.TYPE -eq 'microsoft.network/publicipaddresses' }

    if ($PublicIP)
    {
        $Tmp = @()

        foreach ($1 in $PublicIP)
        {
            $Sub1 = $SUB | Where-Object { $_.Id -eq $1.subscriptionId }
            $Data = $1.PROPERTIES

            if (!($Data.ipConfiguration.id)) { $Use = 'UnderUtilized' } else { $Use = 'Utilized' }
            if (!($Data.natGateway.id) -and $Use -eq 'UnderUtilized') { $Use = 'UnderUtilized' } else { $Use = 'Utilized' }

            # A public IP has TWO association surfaces, and only one used to be read.
            #
            # 'ipConfiguration' is set when the IP is attached to a NIC, a load-balancer
            # frontend and similar. 'natGateway' is set when it is attached to a NAT
            # gateway. They are separate properties, and a NAT-gateway-attached IP has NO
            # ipConfiguration at all - CONFIRMED live: on such a row Resource Graph omits
            # the ipConfiguration key entirely and returns natGateway = @{ id = ... }.
            #
            # The Use flag above already counts natGateway, so a NAT-gateway-only IP was
            # correctly reported as 'Utilized' while the association fields fell to the
            # else branch and emitted the literal 'None'. The row therefore contradicted
            # itself - in use, associated with nothing - and the association was sitting
            # unread in $Data.natGateway.id the whole time.
            #
            # Resolve ONE association from whichever surface is populated, preferring
            # ipConfiguration so no existing row changes value. Both id shapes place the
            # provider type at segment 7 and the resource name at segment 8, so a single
            # extraction serves both:
            #   .../providers/Microsoft.Network/networkInterfaces/<nic>/ipConfigurations/<cfg>
            #   .../providers/Microsoft.Network/natGateways/<nat>
            #
            # Collapsing the two near-identical branches into one object is deliberate:
            # they differed ONLY in these two fields, and keeping two copies is what let
            # them disagree in the first place.
            $AssocId = if (-not [string]::IsNullOrEmpty([string]$Data.ipConfiguration.id))
            {
                [string]$Data.ipConfiguration.id
            }
            elseif (-not [string]::IsNullOrEmpty([string]$Data.natGateway.id))
            {
                [string]$Data.natGateway.id
            }
            else
            {
                $null
            }

            # 'None' (not $null) when there is genuinely no association, preserving the
            # value the unassociated row has always emitted.
            #
            # A NAT gateway is a first-class collected resource, so unlike an
            # ipConfiguration child path - which is never a dictionary key, hence the
            # long-standing 'obfuscated' fallback - this id normally RESOLVES to the same
            # token the NATGateway collector emitted, giving a usable cross-reference
            # rather than a sentinel.
            $AssocName = if ([string]::IsNullOrEmpty($AssocId))
            {
                'None'
            }
            elseif ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0)
            {
                if ($ResourceIdDictionary.ContainsKey($AssocId)) { $ResourceIdDictionary[$AssocId] } else { 'obfuscated' }
            }
            else
            {
                $AssocId.split('/')[8]
            }

            $AssocType = if ([string]::IsNullOrEmpty($AssocId)) { 'None' } else { $AssocId.split('/')[7] }

            $Obj = @{
                'ID'                     = $1.id;
                'Subscription'           = $Sub1.Name;
                'ResourceGroup'          = $1.RESOURCEGROUP;
                'Name'                   = $1.NAME;
                'SKU'                    = $1.SKU.Name;
                'Location'               = $1.LOCATION;
                'AllocationType'         = $Data.publicIPAllocationMethod;
                'Version'                = $Data.publicIPAddressVersion;
                'ProvisioningState'      = $Data.provisioningState;
                'Use'                    = $Use;
                'AssociatedResource'     = $AssocName;
                'AssociatedResourceType' = $AssocType;
            }

            $Tmp += $Obj
        }

        $Tmp
    }
}
