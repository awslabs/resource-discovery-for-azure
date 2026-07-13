param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $REGISTRIES = $Resources | Where-Object { $_.TYPE -eq 'microsoft.containerregistry/registries' }

    if ($REGISTRIES)
    {
        $Tmp = @()

        foreach ($1 in $REGISTRIES)
        {
            $Sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $Data = $1.PROPERTIES
            $Timecreated = [datetime]($Data.creationDate) | Get-Date -Format "yyyy-MM-dd HH:mm"

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

            $Tmp += $Obj
        }

        $Tmp
    }
}
