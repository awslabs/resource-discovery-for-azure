param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $Runbook = $Resources | Where-Object { $_.TYPE -eq 'microsoft.automation/automationaccounts/runbooks' }
    $Autacc = $Resources | Where-Object { $_.TYPE -eq 'microsoft.automation/automationaccounts' }

    if ($Autacc)
    {
        $Tmp = @()

        foreach ($0 in $Autacc)
        {
            $Sub1 = $SUB | Where-Object { $_.Id -eq $0.subscriptionId }
            $Rbs = $Runbook | Where-Object { $_.id.split('/')[8] -eq $0.name }

            $Data0 = $0.properties
            $Timecreated = try { if ($null -ne $Data0.creationTime) { [datetime]($Data0.creationTime) | Get-Date -Format "yyyy-MM-dd HH:mm" } else { 'Unknown' } } catch { 'Unknown' }

            if ($null -ne $Rbs)
            {
                foreach ($1 in $Rbs)
                {
                    $Data = $1.PROPERTIES
                    $LastModified = try { if ($null -ne $Data.lastModifiedTime) { ([datetime]$Data.lastModifiedTime).ToString('MM/dd/yyyy hh:mm') } else { 'Unknown' } } catch { 'Unknown' }

                    $Obj = @{
                        'ID'                            = $1.id;
                        'Subscription'                  = $Sub1.Name;
                        'ResourceGroup'                 = $0.RESOURCEGROUP;
                        'AutomationAccountName'         = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { Protect-FreeTextValue $0.NAME } else { $0.NAME };
                        'AutomationAccountState'        = $0.properties.State;
                        'AutomationAccountSKU'          = $0.properties.sku.name;
                        'AutomationAccountCreatedTime'  = $Timecreated;
                        'Location'                      = $0.LOCATION;
                        'RunbookName'                   = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { Protect-FreeTextValue $1.Name } else { $1.Name };
                        'LastModifiedTime'              = $LastModified;
                        'RunbookState'                  = $Data.state;
                        'RunbookType'                   = $Data.runbookType;
                        'RunbookDescription'            = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { Protect-FreeTextValue $Data.description } else { $Data.description };
                    }

                    $Tmp += $Obj
                }
            }
            else
            {
                $Obj = @{
                    'ID'                            = $0.id;
                    'Subscription'                  = $Sub1.name;
                    'ResourceGroup'                 = $0.RESOURCEGROUP;
                    'AutomationAccountName'         = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { Protect-FreeTextValue $0.NAME } else { $0.NAME };
                    'AutomationAccountState'        = $0.properties.State;
                    'AutomationAccountSKU'          = $0.properties.sku.name;
                    'AutomationAccountCreatedTime'  = $Timecreated;
                    'Location'                      = $0.LOCATION;
                    'RunbookName'                   = $null;
                    'LastModifiedTime'              = $null;
                    'RunbookState'                  = $null;
                    'RunbookType'                   = $null;
                    'RunbookDescription'            = $null;
                }

                $Tmp += $Obj
            }
        }

        $Tmp
    }
}
