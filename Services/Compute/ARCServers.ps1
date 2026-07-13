param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $Arcservers = $Resources | Where-Object { $_.TYPE -eq 'microsoft.hybridcompute/machines' }

    if ($Arcservers)
    {
        $Tmp = @()
        foreach ($1 in $Arcservers)
        {
            $Sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $Data = $1.PROPERTIES

            $Obj = @{
                'ID'                   = $1.id;
                'Subscription'         = $Sub1.name;
                'ResourceGroup'        = $1.RESOURCEGROUP;
                'Name'                 = $1.NAME;
                'Location'             = $1.LOCATION;
                'Model'                = $Data.detectedProperties.model;
                'Status'               = $Data.status;
                'OsName'               = $Data.osName;
                'OsVersion'            = $Data.osVersion;
                'OsSku'                = $Data.osSku;
                'DomainName'           = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { 'obfuscated' } else { $Data.domainName };
            }

            $Tmp += $Obj
        }

        $Tmp
    }
}
