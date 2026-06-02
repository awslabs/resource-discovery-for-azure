param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing') 
{
    $NetApp = $Resources | Where-Object { $_.TYPE -eq 'Microsoft.NetApp/netAppAccounts/capacityPools/volumes' }

    if($NetApp)
    {
        $tmp = @()
        foreach ($1 in $NetApp) 
        {
            $sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $data = $1.PROPERTIES

            $NetApp = $1.Name.split('/')[0]
            $CapacityPool = $1.Name.split('/')[1]
            $Volume = $1.Name.split('/')[2]
            $Quota = ((($data.usageThreshold/1024)/1024)/1024)/1024
            
            $obj = @{
                'ID'                                = $1.id;
                'Subscription'                      = $sub1.Name;
                'ResourceGroup'                     = $1.RESOURCEGROUP;
                'Location'                          = $1.LOCATION;
                'NetAppAccount'                     = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { 'obfuscated' } else { $NetApp };
                'CapacityPool'                      = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { 'obfuscated' } else { $CapacityPool };
                'Volume'                            = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { 'obfuscated' } else { $Volume };
                'ServiceLevel'                      = $data.serviceLevel;
                'QuotaTB'                           = [string]$Quota;
                'Protocol'                          = [string]$data.protocolTypes;
                'MaxThroughputMiBs'                 = [string]$data.throughputMibps;
                'LDAP'                              = $data.ldapEnabled;                        
            }

            $tmp += $obj
        }

        $tmp
    }
}
