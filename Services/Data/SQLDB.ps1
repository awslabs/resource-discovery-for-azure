param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $SQLDB = $Resources | Where-Object { $_.TYPE -eq 'microsoft.sql/servers/databases' -and $_.name -ne 'master' }

    if ($SQLDB)
    {
        $Tmp = @()

        foreach ($1 in $SQLDB)
        {
            $Sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $Data = $1.PROPERTIES
            $DBServer = [string]$1.id.split("/")[8]

            if (![string]::IsNullOrEmpty($Data.elasticPoolId)) { $PoolId = $Data.elasticPoolId.Split("/")[10] } else { $PoolId = "None" }

            if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0)
            {
                $ServerParentId = ($1.id -split '/databases/')[0]
                $DBServer = if ($ResourceIdDictionary.ContainsKey($ServerParentId)) { $ResourceIdDictionary[$ServerParentId] } else { 'obfuscated' }
                $PoolId = if ($PoolId -ne "None" -and ![string]::IsNullOrEmpty($Data.elasticPoolId) -and $ResourceIdDictionary.ContainsKey($Data.elasticPoolId)) { $ResourceIdDictionary[$Data.elasticPoolId] } else { if ($PoolId -ne "None") { 'obfuscated' } else { $PoolId } }
            }
            if ($1.kind.Contains("vcore")) { $SqlType = "vcore" } else { $SqlType = "dtu" }
            if ($1.kind.Contains("serverless")) { $ComputeTier = "Serverless" } else { $ComputeTier = "Provisioned" }

            $Obj = @{
                'ID'                         = $1.id;
                'Subscription'               = $Sub1.Name;
                'ResourceGroup'              = $1.RESOURCEGROUP;
                'Name'                       = $1.NAME;
                'Location'                   = $1.LOCATION;
                'StorageAccountType'         = $Data.storageAccountType;
                'DatabaseServer'             = $DBServer;
                'SecondaryLocation'          = $Data.defaultSecondaryLocation;
                'Status'                     = $Data.status;
                'Tier'                       = $Data.currentSku.Tier;
                'ComputeTier'                = $ComputeTier
                'Type'                       = $SqlType;
                'Capacity'                   = $Data.currentSku.capacity;
                'Sku'                        = $Data.requestedServiceObjectiveName;
                'ZoneRedundant'              = $Data.zoneRedundant;
                'License'                    = if ($null -ne $Data.licenseType) { $Data.licenseType } else { 'License Included' }
                'CatalogCollation'           = $Data.catalogCollation;
                'ReadReplicaCount'           = if ($null -ne $Data.highAvailabilityReplicaCount) { $Data.highAvailabilityReplicaCount } else { '0' }
                'DataMaxSizeGB'              = (($Data.maxSizeBytes / 1024) / 1024) / 1024;
                'ElasticPoolID'              = $PoolId;
            }

            $Tmp += $Obj
        }

        $Tmp
    }
}
