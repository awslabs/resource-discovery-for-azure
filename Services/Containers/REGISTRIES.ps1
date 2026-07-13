param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $REGISTRIES = $Resources | Where-Object { $_.TYPE -eq 'microsoft.containerregistry/registries' }

    if ($REGISTRIES)
    {
        $tmp = @()

        foreach ($1 in $REGISTRIES)
        {
            $sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $data = $1.PROPERTIES
            $timecreated = [datetime]($data.creationDate) | Get-Date -Format "yyyy-MM-dd HH:mm"

            $obj = @{
                'ID'                        = $1.id;
                'Subscription'              = $sub1.Name;
                'ResourceGroup'             = $1.RESOURCEGROUP;
                'Name'                      = $1.NAME;
                'Location'                  = $1.LOCATION;
                'SKU'                       = $1.sku.name;
                'State'                     = $data.provisioningState;
                'Encryption'                = $data.encryption.status;
                'CreatedTime'               = $timecreated;
            }

            $tmp += $obj
        }

        $tmp
    }
}
