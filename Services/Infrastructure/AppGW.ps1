param($SCPath, $Sub, $Resources, $Task ,$File, $SmaResources, $TableStyle, $Metrics)

if ($Task -eq 'Processing') 
{
    $APPGTW = $Resources | Where-Object { $_.TYPE -eq 'microsoft.network/applicationgateways' }

    if($APPGTW)
    {
        $tmp = @()

        foreach ($1 in $APPGTW) 
        {
            $sub1 = $SUB | Where-Object { $_.Id -eq $1.subscriptionId }
            $data = $1.PROPERTIES

            if([string]::IsNullOrEmpty($data.autoscaleConfiguration.maxCapacity)){$MaxCap = 'Autoscale Disabled'}else{$MaxCap = $data.autoscaleConfiguration.maxCapacity}
            if([string]::IsNullOrEmpty($data.autoscaleConfiguration.minCapacity)){$MinCap = 'Autoscale Disabled'}else{$MinCap = $data.autoscaleConfiguration.minCapacity}
            if([string]::IsNullOrEmpty($data.sslPolicy.minProtocolVersion)){$PROT = 'Default'}else{$PROT = $data.sslPolicy.minProtocolVersion}
            if([string]::IsNullOrEmpty($data.webApplicationFirewallConfiguration.enabled)){$WAF = $false}else{$WAF = $data.webApplicationFirewallConfiguration.enabled}
            
            $obj = @{
                'ID'                    = $1.id;
                'Subscription'          = $sub1.Name;
                'ResourceGroup'         = $1.RESOURCEGROUP;
                'Name'                  = $1.NAME;
                'Location'              = $1.LOCATION;
                'State'                 = $data.OperationalState;
                'WAFEnabled'            = $WAF;
                'MinimumTLSVersion'     = "$($PROT -Replace '_', '.' -Replace 'v', ' ' -Replace 'tls', 'TLS')";
                'AutoscaleMinCapacity'  = $MinCap;
                'AutoscaleMaxCapacity'  = $MaxCap;
                'SKUName'               = $data.sku.tier;
                'CurrentInstances'      = $data.sku.capacity;
            }

            $tmp += $obj
        }

        $tmp
    }
}
else 
{
    if ($SmaResources.APPGW) 
    {
        $TableName = ('APPGWTable_'+($SmaResources.APPGW.id | Select-Object -Unique).count)
        $Style = New-ExcelStyle -HorizontalAlignment Center -AutoSize -NumberFormat 0

        $condtxt = @()

        $Exc = New-Object System.Collections.Generic.List[System.Object]
        $Exc.Add('Subscription')
        $Exc.Add('ResourceGroup')
        $Exc.Add('Name')
        $Exc.Add('Location')
        $Exc.Add('State')
        $Exc.Add('WAFEnabled')
        $Exc.Add('MinimumTLSVersion')
        $Exc.Add('AutoscaleMinCapacity')
        $Exc.Add('AutoscaleMaxCapacity')
        $Exc.Add('SKUName')
        $Exc.Add('CurrentInstances')

        $ExcelVar = $SmaResources.APPGW 

        $ExcelVar | 
        ForEach-Object { [PSCustomObject]$_ } | Select-Object -Unique $Exc | 
        Export-Excel -Path $File -WorksheetName 'App Gateway' -AutoSize -MaxAutoSizeRows 100 -TableName $TableName -TableStyle $tableStyle -ConditionalText $condtxt -Style $Style
    }
}