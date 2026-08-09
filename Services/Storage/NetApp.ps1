param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $NetApp = $Resources | Where-Object { $_.TYPE -eq 'Microsoft.NetApp/netAppAccounts/capacityPools/volumes' }

    if ($NetApp)
    {
        $Tmp = @()
        foreach ($1 in $NetApp)
        {
            $Sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $Data = $1.PROPERTIES

            $NameParts = @(([string]$1.Name).Split('/'))
            $NetAppAccount = $NameParts[0]
            $CapacityPool = $NameParts[1]
            $Volume = $NameParts[2]
            $Quota = ((($Data.usageThreshold / 1024) / 1024) / 1024) / 1024

            $Obj = @{
                'ID'                                = $1.id;
                'Subscription'                      = $Sub1.Name;
                'ResourceGroup'                     = $1.RESOURCEGROUP;
                'Location'                          = $1.LOCATION;
                'NetAppAccount'                     = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { 'obfuscated' } else { $NetAppAccount };
                'CapacityPool'                      = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { 'obfuscated' } else { $CapacityPool };
                'Volume'                            = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { 'obfuscated' } else { $Volume };
                'ServiceLevel'                      = $Data.serviceLevel;
                'QuotaTB'                           = [string]$Quota;
                'Protocol'                          = [string]$Data.protocolTypes;
                'MaxThroughputMiBs'                 = [string]$Data.throughputMibps;
                'LDAP'                              = $Data.ldapEnabled;
            }

            $Tmp += $Obj
        }

        $Tmp
    }
}
