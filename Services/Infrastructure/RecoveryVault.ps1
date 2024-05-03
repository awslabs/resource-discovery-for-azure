param($SCPath, $Sub, $Resources, $Task ,$File, $SmaResources, $TableStyle, $Metrics)

if ($Task -eq 'Processing')
{
    $RECOVAULT = $Resources | Where-Object {$_.TYPE -eq 'microsoft.recoveryservices/vaults'}

    if($RECOVAULT)
    {
        $tmp = @()

        foreach ($1 in $RECOVAULT) 
        {
            $sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $data = $1.PROPERTIES
            
            $obj = @{
                'ID'                 = $1.id;
                'Subscription'       = $sub1.Name;
                'ResourceGroup'      = $1.RESOURCEGROUP;
                'Name'               = $1.NAME;
                'Location'           = $1.LOCATION;
                'SKUName'            = $1.sku.name;
                'SKUTier'            = $1.sku.tier;
            }
            
            $tmp += $obj
        }

        $tmp
    }
}
else
{
    if($SmaResources.RecoveryVault)
    {
        $TableName = ('RecoveryVaultTable_'+($SmaResources.RecoveryVault.id | Select-Object -Unique).count)
        $Style = New-ExcelStyle -HorizontalAlignment Center -AutoSize -NumberFormat '0'

        $condtxt = @()

        $Exc = New-Object System.Collections.Generic.List[System.Object]
        $Exc.Add('Subscription')
        $Exc.Add('ResourceGroup')
        $Exc.Add('Name')
        $Exc.Add('Location')
        $Exc.Add('SKUName')
        $Exc.Add('SKUTier')

        $ExcelVar = $SmaResources.RecoveryVault

        $ExcelVar | 
        ForEach-Object { [PSCustomObject]$_ } | Select-Object -Unique $Exc | 
        Export-Excel -Path $File -WorksheetName 'Recovery Vaults' -AutoSize -MaxAutoSizeRows 100 -TableName $TableName -ConditionalText $condtxt -TableStyle $tableStyle -Style $Style
    }
}
