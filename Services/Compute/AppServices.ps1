param($Sub, $Resources, $Task, $ResourceIdDictionary)

If ($Task -eq 'Processing')
{
    $AppSvc = $Resources | Where-Object {$_.TYPE -eq 'microsoft.web/sites'}

    if($AppSvc)
    {
        $tmp = @()

        foreach ($1 in $AppSvc) 
        {
            $sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $data = $1.PROPERTIES

            $obj = @{
                'ID'                            = $1.id;
                'Subscription'                  = $sub1.Name;
                'ResourceGroup'                 = $1.RESOURCEGROUP;
                'Name'                          = $1.NAME;
                'AppType'                       = $1.KIND;
                'Location'                      = $1.LOCATION;
                'Enabled'                       = $data.enabled;
                'State'                         = $data.state;
                'SKU'                           = $data.sku;
                'AvailabilityState'             = $data.availabilityState;
                'SiteProperties'                = $data.siteProperties;          
                'ContainerSize'                 = $data.containerSize;
                'ServerFarmId'                  = if (![string]::IsNullOrEmpty($data.serverFarmId) -and $null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { if ($ResourceIdDictionary.ContainsKey($data.serverFarmId)) { $ResourceIdDictionary[$data.serverFarmId] } else { 'obfuscated' } } else { $data.serverFarmId };
            }

            $tmp += $obj
        }
        
        $tmp
    }
}
