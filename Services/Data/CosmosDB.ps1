param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $COSMOS = $Resources | Where-Object { $_.TYPE -eq 'microsoft.documentdb/databaseaccounts' }

    if ($COSMOS)
    {
        $Tmp = @()

        foreach ($1 in $COSMOS)
        {
            $Sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $Data = $1.PROPERTIES

            $GeoReplicate = if ($Data.failoverPolicies.count -gt 1) { 'Enabled' } else { 'Disabled' }
            $FreeTier = if ($Data.enableFreeTier -eq $true) { 'Opted In' } else { 'Opted Out' }

            $Obj = @{
                'ID'                        = $1.id;
                'Subscription'              = $Sub1.Name;
                'ResourceGroup'             = $1.RESOURCEGROUP;
                'Name'                      = $1.NAME;
                'Location'                  = $1.LOCATION;
                'EnabledAPITypes'           = $Data.EnabledApiTypes;
                'BackupPolicy'              = $Data.backupPolicy.type;
                'BackupStorageRedundancy'   = $Data.backupPolicy.periodicModeProperties.backupStorageRedundancy;
                'AccountOfferType'          = $Data.databaseAccountOfferType;
                'ReplicateDataGlobally'     = $GeoReplicate;
                'FreeTierDiscount'          = $FreeTier;
                'DefaultConsistency'        = $Data.consistencyPolicy.defaultConsistencyLevel;
            }

            $Tmp += $Obj
        }

        $Tmp
    }
}
