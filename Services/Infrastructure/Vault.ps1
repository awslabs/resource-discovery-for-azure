param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $VAULT = $Resources | Where-Object {$_.TYPE -eq 'microsoft.keyvault/vaults'}

    if($VAULT)
    {
        $tmp = @()

        foreach ($1 in $VAULT) 
        {
            $sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $data = $1.PROPERTIES
            if([string]::IsNullOrEmpty($Data.enableSoftDelete)){$Soft = $false}else{$Soft = $Data.enableSoftDelete}
            
            $obj = @{
                'ID'                            = $1.id;
                'Subscription'                  = $sub1.Name;
                'ResourceGroup'                 = $1.RESOURCEGROUP;
                'Name'                          = $1.NAME;
                'Location'                      = $1.LOCATION;
                'SKUFamily'                     = $data.sku.family;
                'SKU'                           = $data.sku.name;
            }

            $tmp += $obj           
        }

        $tmp
    }
}
