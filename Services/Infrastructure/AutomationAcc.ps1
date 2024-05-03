param($SCPath, $Sub, $Resources, $Task ,$File, $SmaResources, $TableStyle, $Metrics)

if ($Task -eq 'Processing')
{
    $runbook = $Resources | Where-Object {$_.TYPE -eq 'microsoft.automation/automationaccounts/runbooks'}
    $autacc = $Resources | Where-Object {$_.TYPE -eq 'microsoft.automation/automationaccounts'}

    if($autacc)
    {
        $tmp = @()

        foreach ($0 in $autacc) 
        {
            $sub1 = $SUB | Where-Object { $_.Id -eq $0.subscriptionId }
            $rbs = $runbook | Where-Object { $_.id.split('/')[8] -eq $0.name }
            
            $data0 = $0.properties
            $timecreated = $data0.creationTime
            $timecreated = [datetime]$timecreated
            $timecreated = $timecreated.ToString("yyyy-MM-dd HH:mm")

            if ($null -ne $rbs) 
            {
                foreach ($1 in $rbs) 
                {
                    $data = $1.PROPERTIES

                    $obj = @{
                        'ID'                            = $1.id;
                        'Subscription'                  = $sub1.Name;
                        'ResourceGroup'                 = $0.RESOURCEGROUP;
                        'AutomationAccountName'         = $0.NAME;
                        'AutomationAccountState'        = $0.properties.State;
                        'AutomationAccountSKU'          = $0.properties.sku.name;
                        'AutomationAccountCreatedTime'  = $timecreated;   
                        'Location'                      = $0.LOCATION;
                        'RunbookName'                   = $1.Name;
                        'LastModifiedTime'              = ([datetime]$data.lastModifiedTime).tostring('MM/dd/yyyy hh:mm') ;
                        'RunbookState'                  = $data.state;
                        'RunbookType'                   = $data.runbookType;
                        'RunbookDescription'            = $data.description;
                    }

                    $tmp += $obj
                }
            }
            else 
            {
                $obj = @{
                    'ID'                            = $1.id;
                    'Subscription'                  = $sub1.name;
                    'ResourceGroup'                 = $0.RESOURCEGROUP;
                    'AutomationAccountName'         = $0.NAME;
                    'AutomationAccountState'        = $0.properties.State;
                    'AutomationAccountSKU'          = $0.properties.sku.name;
                    'AutomationAccountCreatedTime'  = $timecreated;   
                    'Location'                      = $0.LOCATION;
                    'RunbookName'                   = $null;
                    'LastModifiedTime'              = $null;
                    'RunbookState'                  = $null;
                    'RunbookType'                   = $null;
                    'RunbookDescription'            = $null;
                }

                $tmp += $obj
            }
        }

        $tmp
    }
}
else
{
    if($SmaResources.AutomationAcc)
    {

        $TableName = ('AutAccTable_'+($SmaResources.AutomationAcc.id | Select-Object -Unique).count)
        $Style = New-ExcelStyle -HorizontalAlignment Center -AutoSize -NumberFormat '0'
        $StyleExt = New-ExcelStyle -HorizontalAlignment Left -Range K:K -Width 80 -WrapText 

        $condtxt = @()

        $Exc = New-Object System.Collections.Generic.List[System.Object]
        $Exc.Add('Subscription')
        $Exc.Add('ResourceGroup')
        $Exc.Add('AutomationAccountName')
        $Exc.Add('AutomationAccountState')
        $Exc.Add('AutomationAccountSKU')
        $Exc.Add('AutomationAccountCreatedTime')
        $Exc.Add('Location')
        $Exc.Add('RunbookName')
        $Exc.Add('LastModifiedTime')
        $Exc.Add('RunbookState')
        $Exc.Add('RunbookType')
        $Exc.Add('RunbookDescription')

        $ExcelVar = $SmaResources.AutomationAcc  
            
        $ExcelVar | 
        ForEach-Object { [PSCustomObject]$_ } | Select-Object -Unique $Exc | 
        Export-Excel -Path $File -WorksheetName 'Runbooks' -AutoSize -MaxAutoSizeRows 100 -TableName $TableName -TableStyle $tableStyle -ConditionalText $condtxt -Style $Style, $StyleExt
    }
}