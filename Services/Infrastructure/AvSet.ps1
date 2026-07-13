param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $AvSet = $Resources | Where-Object { $_.TYPE -eq 'microsoft.compute/availabilitysets' }

    if ($AvSet)
    {
        $tmp = @()

        foreach ($1 in $AvSet)
        {
            $sub1 = $SUB | Where-Object { $_.Id -eq $1.subscriptionId }
            $data = $1.PROPERTIES

            if ($data.virtualMachines.id)
            {
                foreach ($vmid in $data.virtualMachines.id)
                {
                    $vmIds = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { if ($ResourceIdDictionary.ContainsKey($vmid)) { $ResourceIdDictionary[$vmid] } else { 'obfuscated' } } else { $vmid.split('/')[8] }

                    $obj = @{
                        'ID'               = $1.id;
                        'Subscription'     = $sub1.Name;
                        'ResourceGroup'    = $1.RESOURCEGROUP;
                        'Name'             = $1.NAME;
                        'Location'         = $1.LOCATION;
                        'FaultDomains'     = [string]$data.platformFaultDomainCount;
                        'UpdateDomains'    = [string]$data.platformUpdateDomainCount;
                        'VirtualMachines'  = [string]$vmIds;
                    }

                    $tmp += $obj
                }
            }
            else
            {
                $obj = @{
                    'ID'               = $1.id;
                    'Subscription'     = $sub1.Name;
                    'ResourceGroup'    = $1.RESOURCEGROUP;
                    'Name'             = $1.NAME;
                    'Location'         = $1.LOCATION;
                    'FaultDomains'     = [string]$data.platformFaultDomainCount;
                    'UpdateDomains'    = [string]$data.platformUpdateDomainCount;
                    'VirtualMachines'  = '';
                }

                $tmp += $obj
            }
        }

        $tmp
    }
}
