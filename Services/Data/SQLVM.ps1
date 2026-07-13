param($Sub, $Resources, $Task, $ResourceIdDictionary)

If ($Task -eq 'Processing')
{
    $SQLVM = $Resources | Where-Object { $_.TYPE -eq 'microsoft.sqlvirtualmachine/sqlvirtualmachines' }

    if ($SQLVM)
    {
        $tmp = @()

        foreach ($1 in $SQLVM)
        {
            $sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $data = $1.PROPERTIES

            # The parent compute VM that this SQL VM resource sits on. Azure exposes
            # it as properties.virtualMachineResourceId (the ARM id of the underlying
            # microsoft.compute/virtualmachines resource). In obfuscated mode the
            # VirtualMachines collector indexes that same id into $ResourceIdDictionary,
            # so resolving the cross-reference here yields the SAME obfuscated token,
            # preserving the SQL-VM -> compute-VM link. Falls back to 'obfuscated' when
            # obfuscation is on but the parent id was not indexed (e.g. out-of-scope VM),
            # matching the convention used by the other collectors.
            $ParentVM = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0)
            {
                if (![string]::IsNullOrEmpty($data.virtualMachineResourceId) -and $ResourceIdDictionary.ContainsKey($data.virtualMachineResourceId)) { $ResourceIdDictionary[$data.virtualMachineResourceId] } else { 'obfuscated' }
            }
            else
            {
                if (![string]::IsNullOrEmpty($data.virtualMachineResourceId)) { $data.virtualMachineResourceId } else { 'None' }
            }

            $obj = @{
                'ID'                        = $1.id;
                'Subscription'              = $sub1.Name;
                'ResourceGroup'             = $1.RESOURCEGROUP;
                'Name'                      = $1.NAME;
                'Location'                  = $1.LOCATION;
                'Zone'                      = if ($null -ne $1.ZONES) { $1.ZONES } else { 'None' }
                'ParentVirtualMachine'      = $ParentVM;
                'SQLServerLicenseType'      = $data.sqlServerLicenseType;
                'SQLImage'                  = $data.sqlImageOffer;
                'SQLManagement'             = $data.sqlManagement;
                'SQLImageSku'               = $data.sqlImageSku;
            }

            $tmp += $obj
        }

        $tmp
    }
}
