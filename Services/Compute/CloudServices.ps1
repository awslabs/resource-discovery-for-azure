param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing') 
{
    $CloudServices = $Resources | Where-Object { $_.TYPE -eq 'microsoft.compute/cloudservices' }

    if($CloudServices)
    {
        $tmp = @()

        foreach ($1 in $CloudServices) 
        {
            $sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $data = $1.PROPERTIES

            $roles = $data.roleProfile

            $obj = @{
                'ID'                   = $1.id;
                'Subscription'         = $sub1.Name;
                'ResourceGroup'        = $1.RESOURCEGROUP;
                'Name'                 = $1.name;
                'Location'             = $1.location;
            }

            $obj | Add-Member -MemberType NoteProperty -Name Roles -Value NotSet
            $obj.Roles = [System.Collections.Generic.List[object]]::new()

            foreach ($roleProfile in $roles) 
            {
                $roleProfileObj = @{
                    'RoleName'        = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { 'obfuscated' } else { $roleProfile.name };
                    'SkuName'     = $roleProfile.sku.name;
                    'SkuTier'     = $roleProfile.sku.tier;
                    'SkuCapacity'     = $roleProfile.sku.capacity;
                }

                $obj.Roles.Add($roleProfileObj) 
            }

            $tmp += $obj
        }
        
        $tmp
    }
}
