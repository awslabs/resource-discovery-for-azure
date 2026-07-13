param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $arcservers = $Resources | Where-Object { $_.TYPE -eq 'microsoft.hybridcompute/machines' }

    if ($arcservers)
    {
        $tmp = @()
        foreach ($1 in $arcservers)
        {
            $sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $data = $1.PROPERTIES

            $obj = @{
                'ID'                   = $1.id;
                'Subscription'         = $sub1.name;
                'ResourceGroup'        = $1.RESOURCEGROUP;
                'Name'                 = $1.NAME;
                'Location'             = $1.LOCATION;
                'Model'                = $data.detectedProperties.model;
                'Status'               = $data.status;
                'OsName'               = $data.osName;
                'OsVersion'            = $data.osVersion;
                'OsSku'                = $data.osSku;
                'DomainName'           = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { 'obfuscated' } else { $data.domainName };
            }

            $tmp += $obj
        }

        $tmp
    }
}
