param($SCPath, $Sub, $Resources, $Task ,$File, $SmaResources, $TableStyle, $Metrics)

if ($Task -eq 'Processing') 
{
    $SQLSERVERMI = $Resources | Where-Object { $_.TYPE -eq 'microsoft.sql/managedInstances' }
    $SQLSERVERMIDB = $Resources | Where-Object { $_.TYPE -eq 'microsoft.sql/managedinstances/databases' }

    if($SQLSERVERMI)
    {
        $tmp = @()

        foreach ($1 in $SQLSERVERMI) 
        {
            $sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $data = $1.PROPERTIES
            $databases = $SQLSERVERMIDB | Where-Object { $_.Id -contains $1.Id }

            $obj = @{
                'ID'                            = $1.id;
                'Subscription'                  = $sub1.Name;
                'ResourceGroup'                 = $1.RESOURCEGROUP;
                'Name'                          = $1.NAME;
                'Location'                      = $1.LOCATION;
                'SkuName'                       = $1.sku.Name;
                'SkuCapacity'                   = $1.sku.capacity;
                'SkuTier'                       = $1.sku.tier;
                'SkuFamily'                     = $1.sku.family;
                'InstancePoolName'              = $data.instancePoolId;
                'vCores'                        = $data.vCores;
                'StorageGB'                     = $data.storageSizeInGB;
                'StorageAccountType'            = $data.storageAccountType;
                'LicenseType'                   = $data.licenseType;
                'State'                         = $data.state;
                'ManagedInstanceCreateMode'     = $data.managedInstanceCreateMode;
                'ZoneRedundant'                 = $data.zoneRedundant;
                'Databases'                     = if ($null -ne $databases) { $databases.Count } else { '0' }
            }
            
            $tmp += $obj        
        }
        
        $tmp
    }
}
else 
{
    if ($SmaResources.SQLMI) 
    {
        $TableName = ('SQLMITable_'+($SmaResources.SQLMI.id | Select-Object -Unique).count)
        $Style = New-ExcelStyle -HorizontalAlignment Center -AutoSize -NumberFormat 0

        $condtxt = @()

        $Exc = New-Object System.Collections.Generic.List[System.Object]
        $Exc.Add('Subscription')
        $Exc.Add('ResourceGroup')
        $Exc.Add('Name')
        $Exc.Add('Location')
        $Exc.Add('SkuName')
        $Exc.Add('SkuCapacity')
        $Exc.Add('SkuTier')
        $Exc.Add('SkuFamily')
        $Exc.Add('LicenseType')
        $Exc.Add('InstancePoolName')
        $Exc.Add('vCores')
        $Exc.Add('StorageGB')
        $Exc.Add('StorageAccountType')
        $Exc.Add('State')
        $Exc.Add('vCores')
        $Exc.Add('ManagedInstanceCreateMode')
        $Exc.Add('ZoneRedundant')
        $Exc.Add('Databases')

        $ExcelVar = $SmaResources.SQLMI

        $ExcelVar | 
        ForEach-Object { [PSCustomObject]$_ } | Select-Object -Unique $Exc | 
        Export-Excel -Path $File -WorksheetName 'SQL MI' -AutoSize -MaxAutoSizeRows 100 -TableName $TableName -TableStyle $tableStyle -ConditionalText $condtxt -Style $Style
    }
}