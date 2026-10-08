param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $Synapse = foreach ($Row in $Resources) { if ($Row.TYPE -eq 'microsoft.synapse/workspaces') { $Row } }

    if ($Synapse)
    {
        $Tmp = @()

        foreach ($1 in $Synapse)
        {
            $Sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $Data = $1.PROPERTIES

            $Obj = @{
                'ID'                           = $1.id;
                'Subscription'                 = $Sub1.Name;
                'ResourceGroup'                = $1.RESOURCEGROUP;
                'Name'                         = $1.NAME;
                'Location'                     = $1.LOCATION;
                'WorkspaceType'                = [string]$Data.extraProperties.WorkspaceType;
                'ManagedVirtualNetwork'        = $Data.managedVirtualNetwork;
                'ManagedResourceGroup'         = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { 'obfuscated' } else { $Data.managedResourceGroupName };
            }

            $Tmp += $Obj
        }

        $Tmp
    }
}
