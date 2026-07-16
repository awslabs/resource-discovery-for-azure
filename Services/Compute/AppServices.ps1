param($Sub, $Resources, $Task, $ResourceIdDictionary)

If ($Task -eq 'Processing')
{
    $AppSvc = $Resources | Where-Object { $_.TYPE -eq 'microsoft.web/sites' }

    if ($AppSvc)
    {
        $Tmp = @()

        foreach ($1 in $AppSvc)
        {
            $Sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $Data = $1.PROPERTIES

            $Obj = @{
                'ID'                            = $1.id;
                'Subscription'                  = $Sub1.Name;
                'ResourceGroup'                 = $1.RESOURCEGROUP;
                'Name'                          = $1.NAME;
                'AppType'                       = $1.KIND;
                'Location'                      = $1.LOCATION;
                'Enabled'                       = $Data.enabled;
                'State'                         = $Data.state;
                'SKU'                           = $Data.sku;
                'AvailabilityState'             = $Data.availabilityState;
                'SiteProperties'                = $Data.siteProperties;
                'ContainerSize'                 = $Data.containerSize;
                'ServerFarmId'                  = if (![string]::IsNullOrEmpty($Data.serverFarmId) -and $null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { if ($ResourceIdDictionary.ContainsKey($Data.serverFarmId)) { $ResourceIdDictionary[$Data.serverFarmId] } else { 'obfuscated' } } else { $Data.serverFarmId };
            }

            $Tmp += $Obj
        }

        $Tmp
    }
}
