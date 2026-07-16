param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $ARO = $Resources | Where-Object { $_.TYPE -eq 'microsoft.redhatopenshift/openshiftclusters' }

    if ($ARO)
    {
        $Tmp = @()
        foreach ($1 in $ARO)
        {
            $Sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $Data = $1.PROPERTIES

            $Obj = @{
                'ID'                   = $1.id;
                'Subscription'         = $Sub1.Name;
                'ResourceGroup'        = $1.RESOURCEGROUP;
                'Clusters'             = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { 'obfuscated' } else { $1.NAME };
                'Location'             = $1.LOCATION;
                'AROVersion'           = $Data.clusterProfile.version;
                'OutboundType'         = $Data.networkProfile.outboundType;
                'APIServerType'        = $Data.apiserverProfile.visibility;
                'MasterSKU'            = $Data.masterProfile.vmSize;
                'WorkerSKU'            = $Data.workerProfiles.vmSize | Select-Object -Unique;
                'WorkerDiskSize'       = $Data.workerProfiles.diskSizeGB | Select-Object -Unique;
                'TotalWorkerNodes'     = $Data.workerProfiles.count;
            }

            $Tmp += $Obj
        }

        $Tmp
    }
}
