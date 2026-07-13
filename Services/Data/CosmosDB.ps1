param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $COSMOS = $Resources | Where-Object { $_.TYPE -eq 'microsoft.documentdb/databaseaccounts' }

    if ($COSMOS)
    {
        $tmp = @()

        foreach ($1 in $COSMOS)
        {
            $sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $data = $1.PROPERTIES

            $GeoReplicate = if ($data.failoverPolicies.count -gt 1) { 'Enabled' } else { 'Disabled' }
            $FreeTier = if ($data.enableFreeTier -eq $true) { 'Opted In' } else { 'Opted Out' }

            $obj = @{
                'ID'                        = $1.id;
                'Subscription'              = $sub1.Name;
                'ResourceGroup'             = $1.RESOURCEGROUP;
                'Name'                      = $1.NAME;
                'Location'                  = $1.LOCATION;
                'EnabledAPITypes'           = $data.EnabledApiTypes;
                'BackupPolicy'              = $data.backupPolicy.type;
                'BackupStorageRedundancy'   = $data.backupPolicy.periodicModeProperties.backupStorageRedundancy;
                'AccountOfferType'          = $data.databaseAccountOfferType;
                'ReplicateDataGlobally'     = $GeoReplicate;
                'FreeTierDiscount'          = $FreeTier;
                'DefaultConsistency'        = $data.consistencyPolicy.defaultConsistencyLevel;
            }

            $tmp += $obj
        }

        $tmp
    }
}
