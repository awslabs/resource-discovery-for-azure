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

            $Timecreated = try { if ($null -ne $Data.createdAt) { [datetime]($Data.createdAt) | Get-Date -Format "yyyy-MM-dd HH:mm" } else { 'Unknown' } } catch { 'Unknown' }

            $Obj = @{
                'ID'                  = $1.id;
                'Subscription'        = $Sub1.Name;
                'ResourceGroup'       = $1.RESOURCEGROUP;
                'Name'                = $1.NAME;
                'Location'            = $1.LOCATION;
                # sku is a TOP-LEVEL Resource Graph column for this type, not a
                # member of properties: the ARM contract for
                # Microsoft.Purview/accounts declares sku (name = Free|Standard,
                # capacity) as a sibling of properties. Reading $Data.sku
                # (= properties.sku) therefore always yielded null for BOTH fields.
                # Same correction as IOTHubs.
                'SKU'                 = $1.sku.name;
                'Capacity'            = $1.sku.capacity;
                'CreatedBy'           = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { Protect-FreeTextValue $Data.createdBy } else { $Data.createdBy };
                'FriendlyName'        = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { Protect-FreeTextValue $Data.friendlyName } else { $Data.friendlyName };
                'CreatedTime'         = $Timecreated;
            }

            $Tmp += $Obj
        }

        $Tmp
    }
}
