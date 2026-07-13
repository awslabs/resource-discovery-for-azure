param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $Purview = $Resources | Where-Object { $_.TYPE -eq 'microsoft.purview/accounts' }

    if ($Purview)
    {
        $Tmp = @()
        foreach ($1 in $Purview)
        {
            $Sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $Data = $1.PROPERTIES

            $Timecreated = $Data.createdAt
            $Timecreated = [datetime]$Timecreated
            $Timecreated = $Timecreated.ToString("yyyy-MM-dd HH:mm")

            $Obj = @{
                'ID'                  = $1.id;
                'Subscription'        = $Sub1.Name;
                'ResourceGroup'       = $1.RESOURCEGROUP;
                'Name'                = $1.NAME;
                'Location'            = $1.LOCATION;
                'SKU'                 = $Data.sku.name;
                'Capacity'            = $Data.sku.capacity;
                'CreatedBy'           = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { Protect-FreeTextValue $Data.createdBy } else { $Data.createdBy };
                'FriendlyName'        = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { Protect-FreeTextValue $Data.friendlyName } else { $Data.friendlyName };
                'CreatedTime'         = $Timecreated;
            }

            $Tmp += $Obj
        }

        $Tmp
    }
}
