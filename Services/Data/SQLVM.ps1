param($Sub, $Resources, $Task, $ResourceIdDictionary)

If ($Task -eq 'Processing')
{
    $SQLVM = $Resources | Where-Object { $_.TYPE -eq 'microsoft.sqlvirtualmachine/sqlvirtualmachines' }

    if ($SQLVM)
    {
        $Tmp = @()

        foreach ($1 in $SQLVM)
        {
            $Sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $Data = $1.PROPERTIES

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
                if (![string]::IsNullOrEmpty($Data.virtualMachineResourceId) -and $ResourceIdDictionary.ContainsKey($Data.virtualMachineResourceId)) { $ResourceIdDictionary[$Data.virtualMachineResourceId] } else { 'obfuscated' }
            }
            else
            {
                if (![string]::IsNullOrEmpty($Data.virtualMachineResourceId)) { $Data.virtualMachineResourceId } else { 'None' }
            }

            $Obj = @{
                'ID'                        = $1.id;
                'Subscription'              = $Sub1.Name;
                'ResourceGroup'             = $1.RESOURCEGROUP;
                'Name'                      = $1.NAME;
                'Location'                  = $1.LOCATION;
                'Zone'                      = if ($null -ne $1.ZONES) { $1.ZONES } else { 'None' }
                'ParentVirtualMachine'      = $ParentVM;
                'SQLServerLicenseType'      = $Data.sqlServerLicenseType;
                'SQLImage'                  = $Data.sqlImageOffer;
                'SQLManagement'             = $Data.sqlManagement;
                'SQLImageSku'               = $Data.sqlImageSku;
            }

            $Tmp += $Obj
        }

        $Tmp
    }
}
