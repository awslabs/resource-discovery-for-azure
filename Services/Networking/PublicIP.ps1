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

