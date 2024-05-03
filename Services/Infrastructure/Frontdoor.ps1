param($SCPath, $Sub, $Resources, $Task ,$File, $SmaResources, $TableStyle, $Metrics)

if ($Task -eq 'Processing') 
{
    $FRONTDOOR = $Resources | Where-Object { $_.TYPE -eq 'microsoft.network/frontdoors' }

    if($FRONTDOOR)
    {
        $tmp = @()

        foreach ($1 in $FRONTDOOR) 
        {
            $sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $data = $1.PROPERTIES
            if([string]::IsNullOrEmpty($data.frontendendpoints.properties.webApplicationFirewallPolicyLink.id)){$WAF = $false} else {$WAF = $data.frontendendpoints.properties.webApplicationFirewallPolicyLink.id.split('/')[8]}
            
            $obj = @{
                'ID'                        = $1.id;
                'Subscription'              = $sub1.Name;
                'ResourceGroup'             = $1.RESOURCEGROUP;
                'Name'                      = $1.NAME;
                'Location'                  = $1.LOCATION;
                'FriendlyName'              = $data.friendlyName;
                'cName'                     = $data.cName;
                'State'                     = $data.enabledState;
                'WebApplicationFirewall'    = [string]$WAF;
            }

            $tmp += $obj
        }

        $tmp
    }
}
else 
{
    if ($SmaResources.FRONTDOOR) 
    {
        $TableName = ('FRONTDOORTable_'+($SmaResources.FRONTDOOR.id | Select-Object -Unique).count)
        $Style = New-ExcelStyle -HorizontalAlignment Center -AutoSize -NumberFormat 0

        $condtxt = @()

        $Exc = New-Object System.Collections.Generic.List[System.Object]
        $Exc.Add('Subscription')
        $Exc.Add('ResourceGroup')
        $Exc.Add('Name')
        $Exc.Add('Location')
        $Exc.Add('FriendlyName')
        $Exc.Add('cName')
        $Exc.Add('State')
        $Exc.Add('WebApplicationFirewall')

        $ExcelVar = $SmaResources.FrontDoor 

        $ExcelVar | 
        ForEach-Object { [PSCustomObject]$_ } | Select-Object -Unique $Exc | 
        Export-Excel -Path $File -WorksheetName 'FrontDoor' -AutoSize -MaxAutoSizeRows 100 -TableName $TableName -TableStyle $tableStyle -ConditionalText $condtxt -Style $Style
    }
}