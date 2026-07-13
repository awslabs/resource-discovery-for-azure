param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $CloudServices = $Resources | Where-Object { $_.TYPE -eq 'microsoft.compute/cloudservices' }

    if ($CloudServices)
    {
        $Tmp = @()

        foreach ($1 in $CloudServices)
        {
            $Sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $Data = $1.PROPERTIES

            $Roles = $Data.roleProfile

            $Obj = @{
                'ID'                   = $1.id;
                'Subscription'         = $Sub1.Name;
                'ResourceGroup'        = $1.RESOURCEGROUP;
                'Name'                 = $1.name;
                'Location'             = $1.location;
            }

            $Obj | Add-Member -MemberType NoteProperty -Name Roles -Value NotSet
            $Obj.Roles = [System.Collections.Generic.List[object]]::new()

            foreach ($roleProfile in $Roles)
            {
                $RoleProfileObj = @{
                    'RoleName'        = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { Protect-FreeTextValue $roleProfile.name } else { $roleProfile.name };
                    'SkuName'     = $roleProfile.sku.name;
                    'SkuTier'     = $roleProfile.sku.tier;
                    'SkuCapacity'     = $roleProfile.sku.capacity;
                }

                $Obj.Roles.Add($RoleProfileObj)
            }

            $Tmp += $Obj
        }

        $Tmp
    }
}
