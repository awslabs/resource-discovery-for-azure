param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing') 
{
    $NATGAT = $Resources | Where-Object { $_.TYPE -eq 'microsoft.network/natgateways' }

    if($NATGAT)
    {
        $tmp = @()

        foreach ($1 in $NATGAT) 
        {
            $sub1 = $SUB | Where-Object { $_.Id -eq $1.subscriptionId }
            $data = $1.PROPERTIES
            
            $obj = @{
                'ID'                    = $1.id;
                'Subscription'          = $sub1.Name;
                'ResourceGroup'         = $1.RESOURCEGROUP;
                'Name'                  = $1.NAME;
                'Location'              = $1.LOCATION;
                'SKU'                   = $1.sku.name;
                'IdleTimeoutMin'        = $data.idleTimeoutInMinutes;
            }
            
            $tmp += $obj            
        }

        $tmp
    }
}
