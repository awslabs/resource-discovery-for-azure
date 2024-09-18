param($SCPath, $Sub, $Resources, $Task ,$File, $SmaResources, $TableStyle, $Metrics)

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
                    'RoleName'        = $roleProfile.name;
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
else 
{
    if ($SmaResources.CloudServices) 
    {
        $TableName = ('CloudServicesTable_'+($SmaResources.CloudServices.id | Select-Object -Unique).count)
        $Style = New-ExcelStyle -HorizontalAlignment Center -AutoSize -NumberFormat '0'

        $Exc = New-Object System.Collections.Generic.List[System.Object]
        $Exc.Add('Subscription')
        $Exc.Add('ResourceGroup')
        $Exc.Add('Name')         
        $Exc.Add('Location')                 

        $ExcelVar = $SmaResources.CloudServices

        $ExcelVar | 
        ForEach-Object { [PSCustomObject]$_ } | Select-Object -Unique $Exc | 
        Export-Excel -Path $File -WorksheetName 'CloudServices' -AutoSize -TableName $TableName -MaxAutoSizeRows 100 -TableStyle $tableStyle -Numberformat '0' -Style $Style
    }
}
