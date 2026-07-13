param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $SQLDB = $Resources | Where-Object { $_.TYPE -eq 'microsoft.sql/servers/databases' -and $_.name -ne 'master' }

    if ($SQLDB)
    {
        $tmp = @()

        foreach ($1 in $SQLDB)
        {
            $sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $data = $1.PROPERTIES
            $DBServer = [string]$1.id.split("/")[8]

            if (![string]::IsNullOrEmpty($data.elasticPoolId)) { $PoolId = $data.elasticPoolId.Split("/")[10] } else { $PoolId = "None" }

            if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0)
            {
                $serverParentId = ($1.id -split '/databases/')[0]
                $DBServer = if ($ResourceIdDictionary.ContainsKey($serverParentId)) { $ResourceIdDictionary[$serverParentId] } else { 'obfuscated' }
                $PoolId = if ($PoolId -ne "None" -and ![string]::IsNullOrEmpty($data.elasticPoolId) -and $ResourceIdDictionary.ContainsKey($data.elasticPoolId)) { $ResourceIdDictionary[$data.elasticPoolId] } else { if ($PoolId -ne "None") { 'obfuscated' } else { $PoolId } }
            }
            if ($1.kind.Contains("vcore")) { $SqlType = "vcore" } else { $SqlType = "dtu" }
            if ($1.kind.Contains("serverless")) { $ComputeTier = "Serverless" } else { $ComputeTier = "Provisioned" }

            $obj = @{
                'ID'                         = $1.id;
                'Subscription'               = $sub1.Name;
                'ResourceGroup'              = $1.RESOURCEGROUP;
                'Name'                       = $1.NAME;
                'Location'                   = $1.LOCATION;
                'StorageAccountType'         = $data.storageAccountType;
                'DatabaseServer'             = $DBServer;
                'SecondaryLocation'          = $data.defaultSecondaryLocation;
                'Status'                     = $data.status;
                'Tier'                       = $data.currentSku.Tier;
                'ComputeTier'                = $ComputeTier
                'Type'                       = $SqlType;
                'Capacity'                   = $data.currentSku.capacity;
                'Sku'                        = $data.requestedServiceObjectiveName;
                'ZoneRedundant'              = $data.zoneRedundant;
                'License'                    = if ($null -ne $data.licenseType) { $data.licenseType } else { 'License Included' }
                'CatalogCollation'           = $data.catalogCollation;
                'ReadReplicaCount'           = if ($null -ne $data.highAvailabilityReplicaCount) { $data.highAvailabilityReplicaCount } else { '0' }
                'DataMaxSizeGB'              = (($data.maxSizeBytes / 1024) / 1024) / 1024;
                'ElasticPoolID'              = $PoolId;
            }

            $tmp += $obj
        }

        $tmp
    }
}
