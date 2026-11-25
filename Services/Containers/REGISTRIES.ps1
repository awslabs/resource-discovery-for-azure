param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $REGISTRIES = $Resources | Where-Object { $_.TYPE -eq 'microsoft.containerregistry/registries' }

    if ($REGISTRIES)
    {
        $Tmp = [System.Collections.Generic.List[object]]::new()

        foreach ($1 in $REGISTRIES)
        {
            $Sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $Data = $1.PROPERTIES
            # A missing value, or one that does not convert to a date, is 'Unknown'
            # rather than an exception that fails the whole collector.
            # A valid value is written in UTC on every host; one with no zone is taken as UTC.
            $Timecreated = try { if ($null -ne $Data.creationDate) { [datetime]::Parse($Data.creationDate, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]'AdjustToUniversal, AssumeUniversal') | Get-Date -Format "yyyy-MM-dd HH:mm" } else { 'Unknown' } } catch { 'Unknown' }

            $Obj = @{
                'ID'                        = $1.id;
                'Subscription'              = $Sub1.Name;
                'ResourceGroup'             = $1.RESOURCEGROUP;
                'Name'                      = $1.NAME;
                'Location'                  = $1.LOCATION;
                'SKU'                       = $1.sku.name;
                'State'                     = $Data.provisioningState;
                'Encryption'                = $Data.encryption.status;
                'CreatedTime'               = $Timecreated;
            }

            [void]$Tmp.Add($Obj)
        }

        $Tmp
    }
}
