param($Sub, $Resources, $Task, $ResourceIdDictionary)

If ($Task -eq 'Processing')
{
    $AzureML = $Resources | Where-Object { $_.TYPE -eq 'microsoft.machinelearningservices/workspaces' }

    if ($AzureML)
    {
        $Tmp = @()

        foreach ($1 in $AzureML)
        {
            $Sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $Data = $1.PROPERTIES
            $Timecreated = [datetime]($Data.creationTime) | Get-Date -Format "yyyy-MM-dd HH:mm"

            # The four cross-resource references (storage / key vault / app insights /
            # container registry) are *optional* on an Azure ML workspace - a workspace
            # without one of them returns $null in PROPERTIES rather than the property
            # being absent. The original line `$data.storageAccount.split('/')[8]` then
            # fails with "You cannot call a method on a null-valued expression" and
            # aborts the entire subscription. Guard every reference and emit $null
            # (or, for obfuscated runs, the literal string 'obfuscated' to match the
            # rest of this module's lossy fallback pattern) when the field is absent.
            $StorageAcc = if ([string]::IsNullOrEmpty($Data.storageAccount)) { $null } else { $Data.storageAccount.split('/')[8] }
            $KeyVault = if ([string]::IsNullOrEmpty($Data.keyVault)) { $null } else { $Data.keyVault.split('/')[8] }
            $Insight = if ([string]::IsNullOrEmpty($Data.applicationInsights)) { $null } else { $Data.applicationInsights.split('/')[8] }
            $ContainerRegistry = if ([string]::IsNullOrEmpty($Data.containerRegistry)) { $null } else { $Data.containerRegistry.split('/')[8] }

            # Obfuscate cross-reference names when dictionary is populated
            if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0)
            {
                $StorageAcc = if (![string]::IsNullOrEmpty($Data.storageAccount) -and $ResourceIdDictionary.Count -gt 0 -and $ResourceIdDictionary.ContainsKey($Data.storageAccount)) { $ResourceIdDictionary[$Data.storageAccount] } else { 'obfuscated' }
                $KeyVault = if (![string]::IsNullOrEmpty($Data.keyVault) -and $ResourceIdDictionary.Count -gt 0 -and $ResourceIdDictionary.ContainsKey($Data.keyVault)) { $ResourceIdDictionary[$Data.keyVault] } else { 'obfuscated' }
                $Insight = if (![string]::IsNullOrEmpty($Data.applicationInsights) -and $ResourceIdDictionary.Count -gt 0 -and $ResourceIdDictionary.ContainsKey($Data.applicationInsights)) { $ResourceIdDictionary[$Data.applicationInsights] } else { 'obfuscated' }
                $ContainerRegistry = if (![string]::IsNullOrEmpty($Data.containerRegistry) -and $ResourceIdDictionary.Count -gt 0 -and $ResourceIdDictionary.ContainsKey($Data.containerRegistry)) { $ResourceIdDictionary[$Data.containerRegistry] } else { 'obfuscated' }
            }

            $Obj = @{
                'ID'                        = $1.id;
                'Subscription'              = $Sub1.Name;
                'ResourceGroup'             = $1.RESOURCEGROUP;
                'Name'                      = $1.NAME;
                'Location'                  = $1.LOCATION;
                'SKU'                       = $1.sku.name;
                'FriendlyName'              = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { Protect-FreeTextValue $Data.friendlyName } else { $Data.friendlyName };
                'Description'               = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { Protect-FreeTextValue $Data.description } else { $Data.description };
                'ContainerRegistry'         = $ContainerRegistry;
                'StorageHNSEnabled'         = $Data.storageHnsEnabled;
                'StorageAccount'            = $StorageAcc;
                'KeyVault'                  = $KeyVault;
                'CreatedTime'               = $Timecreated;
                'ApplicationInsight'        = $Insight;
            }

            $Tmp += $Obj
        }

        $Tmp
    }
}
