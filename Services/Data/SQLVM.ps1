param($Sub, $Resources, $Task, $ResourceIdDictionary)

If ($Task -eq 'Processing') 
{
    $SQLVM = $Resources | Where-Object { $_.TYPE -eq 'microsoft.sqlvirtualmachine/sqlvirtualmachines' }

    if($SQLVM)
    {
        $tmp = @()

        foreach ($1 in $SQLVM) 
        {
            $sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $data = $1.PROPERTIES
            
            $obj = @{
                'ID'                        = $1.id;
                'Subscription'              = $sub1.Name;
                'ResourceGroup'             = $1.RESOURCEGROUP;
                'Name'                      = $1.NAME;
                'Location'                  = $1.LOCATION;
                'Zone'                      = if ($null -ne $1.ZONES) { $1.ZONES } else { 'None' }
                'SQLServerLicenseType'      = $data.sqlServerLicenseType;
                'SQLImage'                  = $data.sqlImageOffer;
                'SQLManagement'             = $data.sqlManagement;
                'SQLImageSku'               = $data.sqlImageSku;
            }
            
            $tmp += $obj      
        }

        $tmp
    }
}
