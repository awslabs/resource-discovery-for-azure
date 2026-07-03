param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $RECOVAULT = $Resources | Where-Object {$_.TYPE -eq 'microsoft.recoveryservices/vaults'}

    if($RECOVAULT)
    {
        $tmp = @()

        foreach ($1 in $RECOVAULT) 
        {
            $sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $data = $1.PROPERTIES
            
            $obj = @{
                'ID'                 = $1.id;
                'Subscription'       = $sub1.Name;
                'ResourceGroup'      = $1.RESOURCEGROUP;
                'Name'               = $1.NAME;
                'Location'           = $1.LOCATION;
                'SKUName'            = $1.sku.name;
                'SKUTier'            = $1.sku.tier;
            }
            
            $tmp += $obj
        }

        $tmp
    }
}
