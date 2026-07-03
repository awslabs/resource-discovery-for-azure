param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing') 
{
    $Synapse = $Resources | Where-Object { $_.TYPE -eq 'microsoft.synapse/workspaces' }

    if($Synapse)
    {
        $tmp = @()
        
        foreach ($1 in $Synapse) 
        {
            $sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $data = $1.PROPERTIES

            $obj = @{
                'ID'                           = $1.id;
                'Subscription'                 = $sub1.Name;
                'ResourceGroup'                = $1.RESOURCEGROUP;
                'Name'                         = $1.NAME;
                'Location'                     = $1.LOCATION;
                'WorkspaceType'                = [string]$data.extraProperties.WorkspaceType;
                'ManagedVirtualNetwork'        = $data.managedVirtualNetwork;                            
                'ManagedResourceGroup'         = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { 'obfuscated' } else { $data.managedResourceGroupName };
            }

            $tmp += $obj
        }

        $tmp
    }
}
