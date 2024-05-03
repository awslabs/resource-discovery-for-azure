param($SCPath, $Sub, $Resources, $Task ,$File, $SmaResources, $TableStyle, $Metrics)

if ($Task -eq 'Processing')
{
    $expressroute = $Resources | Where-Object {$_.TYPE -eq 'microsoft.network/expressroutecircuits'}

    if($expressroute)
    {
        $tmp = @()

        foreach ($1 in $expressroute) 
        {
            $sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $data = $1.PROPERTIES
            $sku = $1.SKU
            
            $obj = @{
                'ID'                    = $1.id;
                'Subscription'          = $sub1.name;
                'ResourceGroup'         = $1.RESOURCEGROUP;
                'Name'                  = $1.NAME;
                'Location'              = $1.LOCATION;
                'Tier'                  = $sku.tier;
                'BillingModel'          = $sku.family;
                'CircuitStatus'         = $data.circuitProvisioningState;
                'ProviderStatus'        = $data.serviceProviderProvisioningState;
                'Provider'              = $data.serviceProviderProperties.serviceProviderName;
                'Bandwidth'             = $data.bandwidthInMbps;
                'ERLocation'            = $data.peeringLocation;
                'GlobalReachEnabled'    = $data.globalReachEnabled;
            }

            $tmp += $obj
        }

        $tmp
    }
}
else
{
    if($SmaResources.expressroute)
    {
        $TableName = ('ERs_'+($SmaResources.expressroute.id | Select-Object -Unique).count)
        $Style = New-ExcelStyle -HorizontalAlignment Center -AutoSize -NumberFormat '0'

        $Exc = New-Object System.Collections.Generic.List[System.Object]
        $Exc.Add('Subscription')
        $Exc.Add('ResourceGroup')
        $Exc.Add('Name')
        $Exc.Add('Location')
        $Exc.Add('Tier')
        $Exc.Add('BillingModel')
        $Exc.Add('CircuitStatus')
        $Exc.Add('ProviderStatus')
        $Exc.Add('Provider')
        $Exc.Add('Bandwidth')
        $Exc.Add('ERLocation')
        $Exc.Add('GlobalReachEnabled')


        $ExcelVar = $SmaResources.expressroute  

        $ExcelVar | 
        ForEach-Object { [PSCustomObject]$_ } | Select-Object -Unique $Exc | 
        Export-Excel -Path $File -WorksheetName 'Express Route' -AutoSize -MaxAutoSizeRows 100 -TableName $TableName -TableStyle $tableStyle -Style $Style
    }
}