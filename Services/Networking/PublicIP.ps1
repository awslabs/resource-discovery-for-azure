param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing') 
{
    $PublicIP = $Resources | Where-Object { $_.TYPE -eq 'microsoft.network/publicipaddresses' }

    if($PublicIP)
    {
        $tmp = @()

        foreach ($1 in $PublicIP) 
        {
            $sub1 = $SUB | Where-Object { $_.Id -eq $1.subscriptionId }
            $data = $1.PROPERTIES

            if (!($data.ipConfiguration.id)) { $Use = 'UnderUtilized' } else { $Use = 'Utilized' }
            if (!($data.natGateway.id) -and $Use -eq 'UnderUtilized') { $Use = 'UnderUtilized' } else { $Use = 'Utilized' }
                      
            if ($null -ne $data.ipConfiguration.id) 
            {
                $obj = @{
                    'ID'                       = $1.id;
                    'Subscription'             = $sub1.Name;
                    'ResourceGroup'            = $1.RESOURCEGROUP;
                    'Name'                     = $1.NAME;
                    'SKU'                      = $1.SKU.Name;
                    'Location'                 = $1.LOCATION;
                    'AllocationType'           = $data.publicIPAllocationMethod;
                    'Version'                  = $data.publicIPAddressVersion;
                    'ProvisioningState'        = $data.provisioningState;
                    'Use'                      = $Use;
                    'AssociatedResource'       = if ([string]::IsNullOrEmpty($data.ipConfiguration.id)) { $null } elseif ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { if ($ResourceIdDictionary.ContainsKey($data.ipConfiguration.id)) { $ResourceIdDictionary[$data.ipConfiguration.id] } else { 'obfuscated' } } else { $data.ipConfiguration.id.split('/')[8] };
                    'AssociatedResourceType'   = if ([string]::IsNullOrEmpty($data.ipConfiguration.id)) { $null } else { $data.ipConfiguration.id.split('/')[7] };
                }

                $tmp += $obj
            }               
            else 
            {
                $obj = @{
                    'ID'                       = $1.id;
                    'Subscription'             = $sub1.name;
                    'ResourceGroup'            = $1.RESOURCEGROUP;
                    'Name'                     = $1.NAME;
                    'SKU'                      = $1.SKU.Name;
                    'Location'                 = $1.LOCATION;
                    'AllocationType'           = $data.publicIPAllocationMethod;
                    'Version'                  = $data.publicIPAddressVersion;
                    'ProvisioningState'        = $data.provisioningState;
                    'Use'                      = $Use;
                    'AssociatedResource'       = 'None';
                    'AssociatedResourceType'   = 'None';
                }
                
                $tmp += $obj           
            }             
        }

        $tmp
    }
}
