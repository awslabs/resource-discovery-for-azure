param($SCPath, $Sub, $Resources, $Task ,$File, $SmaResources, $TableStyle, $Metrics)

if ($Task -eq 'Processing')
{
    $VAULT = $Resources | Where-Object {$_.TYPE -eq 'microsoft.keyvault/vaults'}

    if($VAULT)
    {
        $tmp = @()

        foreach ($1 in $VAULT) 
        {
            $sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $data = $1.PROPERTIES
            if([string]::IsNullOrEmpty($Data.enableSoftDelete)){$Soft = $false}else{$Soft = $Data.enableSoftDelete}
            
            $obj = @{
                'ID'                            = $1.id;
                'Subscription'                  = $sub1.Name;
                'ResourceGroup'                 = $1.RESOURCEGROUP;
                'Name'                          = $1.NAME;
                'Location'                      = $1.LOCATION;
                'SKUFamily'                     = $data.sku.family;
                'SKU'                           = $data.sku.name;
                'EnableRBAC'                    = $data.enableRbacAuthorization;
                'EnableSoftDelete'              = $Soft;
                'EnableEncryption'              = $data.enabledForDiskEncryption;
                'EnableTemplateDeploy'          = $data.enabledForTemplateDeployment;
                'SoftDeleteRetentionDays'       = $data.softDeleteRetentionInDays;
            }

            $tmp += $obj           
        }

        $tmp
    }
}
else
{
    if($SmaResources.Vault)
    {

        $TableName = ('VaultTable_'+($SmaResources.Vault.id | Select-Object -Unique).count)
        $Style = New-ExcelStyle -HorizontalAlignment Center -AutoSize -NumberFormat '0'

        $condtxt = @()

        $Exc = New-Object System.Collections.Generic.List[System.Object]
        $Exc.Add('Subscription')
        $Exc.Add('ResourceGroup')
        $Exc.Add('Name')
        $Exc.Add('Location')
        $Exc.Add('SKUFamily')
        $Exc.Add('SKU')
        $Exc.Add('EnableRBAC')
        $Exc.Add('EnableSoftDelete')
        $Exc.Add('EnableEncryption')
        $Exc.Add('EnableTemplateDeploy')
        $Exc.Add('SoftDeleteRetentionDays')

        $ExcelVar = $SmaResources.Vault 

        $ExcelVar | 
        ForEach-Object { [PSCustomObject]$_ } | Select-Object -Unique $Exc | 
        Export-Excel -Path $File -WorksheetName 'Key Vaults' -AutoSize -MaxAutoSizeRows 100 -TableName $TableName -TableStyle $tableStyle -ConditionalText $condtxt -Style $Style
    }
}