param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $Purview = $Resources | Where-Object { $_.TYPE -eq 'microsoft.purview/accounts' }

    if ($Purview)
    {
        $tmp = @()
        foreach ($1 in $Purview)
        {
            $sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $data = $1.PROPERTIES

            $timecreated = $data.createdAt
            $timecreated = [datetime]$timecreated
            $timecreated = $timecreated.ToString("yyyy-MM-dd HH:mm")

            $obj = @{
                'ID'                  = $1.id;
                'Subscription'        = $sub1.Name;
                'ResourceGroup'       = $1.RESOURCEGROUP;
                'Name'                = $1.NAME;
                'Location'            = $1.LOCATION;
                'SKU'                 = $data.sku.name;
                'Capacity'            = $data.sku.capacity;
                'CreatedBy'           = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { Protect-FreeTextValue $data.createdBy } else { $data.createdBy };
                'FriendlyName'        = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { Protect-FreeTextValue $data.friendlyName } else { $data.friendlyName };
                'CreatedTime'         = $timecreated;
            }

            $tmp += $obj
        }

        $tmp
    }
}
