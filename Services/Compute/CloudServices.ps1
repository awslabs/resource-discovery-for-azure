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

            # roleProfile is a CloudServiceRoleProfile OBJECT whose 'roles' member holds the
            # array. Iterating roleProfile itself walked one object with no name or sku, so
            # every cloud service emitted a single all-null role row whatever its real count.
            $Roles = $Data.roleProfile.roles

            $Obj = @{
                'ID'                   = $1.id;
                'Subscription'         = $Sub1.Name;
                'ResourceGroup'        = $1.RESOURCEGROUP;
                'Name'                 = $1.name;
                'Location'             = $1.location;
            }

            # No Add-Member here: the assignment below creates 'Roles' by itself. A
            # NoteProperty of the same name shadowed it for member access while
            # ConvertTo-Json read the other, and which one won depended on whether the
            # property had already been read. One store means nothing to shadow.
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
