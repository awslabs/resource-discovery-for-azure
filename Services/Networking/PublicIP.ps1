param($SCPath, $Sub, $Resources, $Task ,$File, $SmaResources, $TableStyle, $Metrics)

if ($Task -eq 'Processing') 
{
    $PublicIP = $Resources | Where-Object { $_.TYPE -eq 'microsoft.network/publicipaddresses' }

    if($PublicIP)
    {
        $tmp = @()

        foreach ($1 in $PublicIP) 
        {
            $sub1 = $SUB | Where-Object { $_.Id -eq $1.subscriptionId }
            $data = $1.PROPERTIES

            if (!($data.ipConfiguration.id)) { $Use = 'UnderUtilized' } else { $Use = 'Utilized' }
            if (!($data.natGateway.id) -and $Use -eq 'UnderUtilized') { $Use = 'UnderUtilized' } else { $Use = 'Utilized' }
                      
            if ($null -ne $data.ipConfiguration.id) 
            {
                $obj = @{
                    'ID'                       = $1.id;
                    'Subscription'             = $sub1.Name;
                    'ResourceGroup'            = $1.RESOURCEGROUP;
                    'Name'                     = $1.NAME;
                    'SKU'                      = $1.SKU.Name;
                    'Location'                 = $1.LOCATION;
                    'AllocationType'           = $data.publicIPAllocationMethod;
                    'Version'                  = $data.publicIPAddressVersion;
                    'ProvisioningState'        = $data.provisioningState;
                    'Use'                      = $Use;
                    'AssociatedResource'       = $data.ipConfiguration.id.split('/')[8];
                    'AssociatedResourceType'   = $data.ipConfiguration.id.split('/')[7];
                }

                $tmp += $obj
            }               
            else 
            {
                $obj = @{
                    'ID'                       = $1.id;
                    'Subscription'             = $sub1.name;
                    'ResourceGroup'            = $1.RESOURCEGROUP;
                    'Name'                     = $1.NAME;
                    'SKU'                      = $1.SKU.Name;
                    'Location'                 = $1.LOCATION;
                    'AllocationType'           = $data.publicIPAllocationMethod;
                    'Version'                  = $data.publicIPAddressVersion;
                    'ProvisioningState'        = $data.provisioningState;
                    'Use'                      = $Use;
                    'AssociatedResource'       = 'None';
                    'AssociatedResourceType'   = 'None';
                }
                
                $tmp += $obj           
            }             
        }

        $tmp
    }
}
else 
{
    if ($SmaResources.PublicIP) 
    {        
        $TableName = ('PIPTable_'+($SmaResources.PublicIP.id | Select-Object -Unique).count)
        $Style = New-ExcelStyle -HorizontalAlignment Center -AutoSize -NumberFormat 0

        $condtxt = @()

        $Exc = New-Object System.Collections.Generic.List[System.Object]
        $Exc.Add('Subscription')
        $Exc.Add('ResourceGroup')
        $Exc.Add('Name')
        $Exc.Add('SKU')
        $Exc.Add('Location')
        $Exc.Add('AllocationType')
        $Exc.Add('Version')
        $Exc.Add('ProvisioningState')
        $Exc.Add('Use')
        $Exc.Add('AssociatedResource')
        $Exc.Add('AssociatedResourceType')

        $ExcelVar = $SmaResources.PublicIP

        $ExcelVar | 
        ForEach-Object { [PSCustomObject]$_ } | Select-Object -Unique $Exc | 
        Export-Excel -Path $File -WorksheetName 'Public IPs' -AutoSize -MaxAutoSizeRows 100 -TableName $TableName -TableStyle $tableStyle -Style $Style -ConditionalText $condtxt  
    }
}
