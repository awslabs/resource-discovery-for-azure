param($Sub, $Resources, $Task, $ResourceIdDictionary)

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
                        'AutomationAccountName'         = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { Protect-FreeTextValue $0.NAME } else { $0.NAME };
                        'AutomationAccountState'        = $0.properties.State;
                        'AutomationAccountSKU'          = $0.properties.sku.name;
                        'AutomationAccountCreatedTime'  = $timecreated;   
                        'Location'                      = $0.LOCATION;
                        'RunbookName'                   = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { Protect-FreeTextValue $1.Name } else { $1.Name };
                        'LastModifiedTime'              = ([datetime]$data.lastModifiedTime).tostring('MM/dd/yyyy hh:mm') ;
                        'RunbookState'                  = $data.state;
                        'RunbookType'                   = $data.runbookType;
                        'RunbookDescription'            = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { Protect-FreeTextValue $data.description } else { $data.description };
                    }

                    $tmp += $obj
                }
            }
            else 
            {
                $obj = @{
                    'ID'                            = $0.id;
                    'Subscription'                  = $sub1.name;
                    'ResourceGroup'                 = $0.RESOURCEGROUP;
                    'AutomationAccountName'         = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { Protect-FreeTextValue $0.NAME } else { $0.NAME };
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
