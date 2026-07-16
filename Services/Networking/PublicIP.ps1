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

            if ($null -ne $Data.ipConfiguration.id)
            {
                $Obj = @{
                    'ID'                       = $1.id;
                    'Subscription'             = $Sub1.Name;
                    'ResourceGroup'            = $1.RESOURCEGROUP;
                    'Name'                     = $1.NAME;
                    'SKU'                      = $1.SKU.Name;
                    'Location'                 = $1.LOCATION;
                    'AllocationType'           = $Data.publicIPAllocationMethod;
                    'Version'                  = $Data.publicIPAddressVersion;
                    'ProvisioningState'        = $Data.provisioningState;
                    'Use'                      = $Use;
                    'AssociatedResource'       = if ([string]::IsNullOrEmpty($Data.ipConfiguration.id)) { $null } elseif ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { if ($ResourceIdDictionary.ContainsKey($Data.ipConfiguration.id)) { $ResourceIdDictionary[$Data.ipConfiguration.id] } else { 'obfuscated' } } else { $Data.ipConfiguration.id.split('/')[8] };
                    'AssociatedResourceType'   = if ([string]::IsNullOrEmpty($Data.ipConfiguration.id)) { $null } else { $Data.ipConfiguration.id.split('/')[7] };
                }

                $Tmp += $Obj
            }
            else
            {
                $Obj = @{
                    'ID'                       = $1.id;
                    'Subscription'             = $Sub1.name;
                    'ResourceGroup'            = $1.RESOURCEGROUP;
                    'Name'                     = $1.NAME;
                    'SKU'                      = $1.SKU.Name;
                    'Location'                 = $1.LOCATION;
                    'AllocationType'           = $Data.publicIPAllocationMethod;
                    'Version'                  = $Data.publicIPAddressVersion;
                    'ProvisioningState'        = $Data.provisioningState;
                    'Use'                      = $Use;
                    'AssociatedResource'       = 'None';
                    'AssociatedResourceType'   = 'None';
                }

                $Tmp += $Obj
            }
        }

        $Tmp
    }
}
