param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $ARO = $Resources | Where-Object { $_.TYPE -eq 'microsoft.redhatopenshift/openshiftclusters' }

    if ($ARO)
    {
        $tmp = @()
        foreach ($1 in $ARO)
        {
            $sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $data = $1.PROPERTIES

            $obj = @{
                'ID'                   = $1.id;
                'Subscription'         = $sub1.Name;
                'ResourceGroup'        = $1.RESOURCEGROUP;
                'Clusters'             = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { 'obfuscated' } else { $1.NAME };
                'Location'             = $1.LOCATION;
                'AROVersion'           = $data.clusterProfile.version;
                'OutboundType'         = $data.networkProfile.outboundType;
                'APIServerType'        = $data.apiserverProfile.visibility;
                'MasterSKU'            = $data.masterProfile.vmSize;
                'WorkerSKU'            = $data.workerProfiles.vmSize | Select-Object -Unique;
                'WorkerDiskSize'       = $data.workerProfiles.diskSizeGB | Select-Object -Unique;
                'TotalWorkerNodes'     = $data.workerProfiles.count;
            }

            $tmp += $obj
        }

        $tmp
    }
}
