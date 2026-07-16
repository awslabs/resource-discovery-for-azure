param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $AvSet = $Resources | Where-Object { $_.TYPE -eq 'microsoft.compute/availabilitysets' }

    if ($AvSet)
    {
        $Tmp = @()

        foreach ($1 in $AvSet)
        {
            $Sub1 = $SUB | Where-Object { $_.Id -eq $1.subscriptionId }
            $Data = $1.PROPERTIES

            if ($Data.virtualMachines.id)
            {
                foreach ($vmid in $Data.virtualMachines.id)
                {
                    $VmIds = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { if ($ResourceIdDictionary.ContainsKey($vmid)) { $ResourceIdDictionary[$vmid] } else { 'obfuscated' } } else { $vmid.split('/')[8] }

                    $Obj = @{
                        'ID'               = $1.id;
                        'Subscription'     = $Sub1.Name;
                        'ResourceGroup'    = $1.RESOURCEGROUP;
                        'Name'             = $1.NAME;
                        'Location'         = $1.LOCATION;
                        'FaultDomains'     = [string]$Data.platformFaultDomainCount;
                        'UpdateDomains'    = [string]$Data.platformUpdateDomainCount;
                        'VirtualMachines'  = [string]$VmIds;
                    }

                    $Tmp += $Obj
                }
            }
            else
            {
                $Obj = @{
                    'ID'               = $1.id;
                    'Subscription'     = $Sub1.Name;
                    'ResourceGroup'    = $1.RESOURCEGROUP;
                    'Name'             = $1.NAME;
                    'Location'         = $1.LOCATION;
                    'FaultDomains'     = [string]$Data.platformFaultDomainCount;
                    'UpdateDomains'    = [string]$Data.platformUpdateDomainCount;
                    'VirtualMachines'  = '';
                }

                $Tmp += $Obj
            }
        }

        $Tmp
    }
}
