param($SCPath, $Sub, $Resources, $Task ,$File, $SmaResources, $TableStyle, $Metrics)

if ($Task -eq 'Processing')
{
    $REGISTRIES = $Resources | Where-Object {$_.TYPE -eq 'microsoft.containerregistry/registries'}

    if($REGISTRIES)
    {
        $tmp = @()

        foreach ($1 in $REGISTRIES) 
        {
            $sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $data = $1.PROPERTIES
            $timecreated = [datetime]($data.creationDate) | Get-Date -Format "yyyy-MM-dd HH:mm"
            
            $obj = @{
                'ID'                        = $1.id;
                'Subscription'              = $sub1.Name;
                'ResourceGroup'             = $1.RESOURCEGROUP;
                'Name'                      = $1.NAME;
                'Location'                  = $1.LOCATION;
                'SKU'                       = $1.sku.name;
                'State'                     = $data.provisioningState;
                'Encryption'                = $data.encryption.status;
                'CreatedTime'               = $timecreated;
            }

            $tmp += $obj
        }
        
        $tmp
    }
}
else
{
    if($SmaResources.REGISTRIES)
    {
        $TableName = ('ContsTable_'+($SmaResources.REGISTRIES.id | Select-Object -Unique).count)
        $Style = New-ExcelStyle -HorizontalAlignment Center -AutoSize -NumberFormat '0'

        $cond = @()

        $Exc = New-Object System.Collections.Generic.List[System.Object]
        $Exc.Add('Subscription')
        $Exc.Add('ResourceGroup')
        $Exc.Add('Name')
        $Exc.Add('Location')
        $Exc.Add('SKU')
        $Exc.Add('State')
        $Exc.Add('Encryption')
        $Exc.Add('CreatedTime')  

        $ExcelVar = $SmaResources.REGISTRIES 
            
        $ExcelVar | 
        ForEach-Object { [PSCustomObject]$_ } | Select-Object -Unique $Exc | 
        Export-Excel -Path $File -WorksheetName 'Registries' -AutoSize -ConditionalText $cond -MaxAutoSizeRows 100 -TableName $TableName -TableStyle $tableStyle -Style $Style
    }
}