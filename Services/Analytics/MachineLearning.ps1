param($Sub, $Resources, $Task, $ResourceIdDictionary)

If ($Task -eq 'Processing')
{
    $AzureML = $Resources | Where-Object { $_.TYPE -eq 'microsoft.machinelearningservices/workspaces' }

    if ($AzureML)
    {
        $tmp = @()

        foreach ($1 in $AzureML)
        {
            $sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $data = $1.PROPERTIES
            $timecreated = [datetime]($data.creationTime) | Get-Date -Format "yyyy-MM-dd HH:mm"

            # The four cross-resource references (storage / key vault / app insights /
            # container registry) are *optional* on an Azure ML workspace - a workspace
            # without one of them returns $null in PROPERTIES rather than the property
            # being absent. The original line `$data.storageAccount.split('/')[8]` then
            # fails with "You cannot call a method on a null-valued expression" and
            # aborts the entire subscription. Guard every reference and emit $null
            # (or, for obfuscated runs, the literal string 'obfuscated' to match the
            # rest of this module's lossy fallback pattern) when the field is absent.
            $StorageAcc = if ([string]::IsNullOrEmpty($data.storageAccount)) { $null } else { $data.storageAccount.split('/')[8] }
            $KeyVault = if ([string]::IsNullOrEmpty($data.keyVault)) { $null } else { $data.keyVault.split('/')[8] }
            $Insight = if ([string]::IsNullOrEmpty($data.applicationInsights)) { $null } else { $data.applicationInsights.split('/')[8] }
            $containerRegistry = if ([string]::IsNullOrEmpty($data.containerRegistry)) { $null } else { $data.containerRegistry.split('/')[8] }

            # Obfuscate cross-reference names when dictionary is populated
            if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0)
            {
                $StorageAcc = if (![string]::IsNullOrEmpty($data.storageAccount) -and $ResourceIdDictionary.Count -gt 0 -and $ResourceIdDictionary.ContainsKey($data.storageAccount)) { $ResourceIdDictionary[$data.storageAccount] } else { 'obfuscated' }
                $KeyVault = if (![string]::IsNullOrEmpty($data.keyVault) -and $ResourceIdDictionary.Count -gt 0 -and $ResourceIdDictionary.ContainsKey($data.keyVault)) { $ResourceIdDictionary[$data.keyVault] } else { 'obfuscated' }
                $Insight = if (![string]::IsNullOrEmpty($data.applicationInsights) -and $ResourceIdDictionary.Count -gt 0 -and $ResourceIdDictionary.ContainsKey($data.applicationInsights)) { $ResourceIdDictionary[$data.applicationInsights] } else { 'obfuscated' }
                $containerRegistry = if (![string]::IsNullOrEmpty($data.containerRegistry) -and $ResourceIdDictionary.Count -gt 0 -and $ResourceIdDictionary.ContainsKey($data.containerRegistry)) { $ResourceIdDictionary[$data.containerRegistry] } else { 'obfuscated' }
            }

            $obj = @{
                'ID'                        = $1.id;
                'Subscription'              = $sub1.Name;
                'ResourceGroup'             = $1.RESOURCEGROUP;
                'Name'                      = $1.NAME;
                'Location'                  = $1.LOCATION;
                'SKU'                       = $1.sku.name;
                'FriendlyName'              = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { Protect-FreeTextValue $data.friendlyName } else { $data.friendlyName };
                'Description'               = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { Protect-FreeTextValue $data.description } else { $data.description };
                'ContainerRegistry'         = $containerRegistry;
                'StorageHNSEnabled'         = $data.storageHnsEnabled;
                'StorageAccount'            = $StorageAcc;
                'KeyVault'                  = $KeyVault;
                'CreatedTime'               = $timecreated;
                'ApplicationInsight'        = $Insight;
            }

            $tmp += $obj
        }

        $tmp
    }
}
