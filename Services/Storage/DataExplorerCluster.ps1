param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $DataExplorer = $Resources | Where-Object { $_.TYPE -eq 'microsoft.kusto/clusters' }

    if ($DataExplorer)
    {
        $Tmp = @()

        foreach ($1 in $DataExplorer)
        {
            $Sub1 = $SUB | Where-Object { $_.Id -eq $1.subscriptionId }
            $Data = $1.PROPERTIES
            $Sku = $1.SKU

            $AutoScale = if ($Data.optimizedAutoscale.isEnabled -eq 'true') { 'Enabled' }else { 'Disabled' }

            $Obj = @{
                'ID'                        = $1.id;
                'Subscription'              = $Sub1.Name;
                'ResourceGroup'             = $1.RESOURCEGROUP;
                'Name'                      = $1.NAME;
                'Location'                  = $1.LOCATION;
                'ComputeSpecifications'     = $Sku.name;
                'InstanceCount'             = $Sku.capacity;
                'State'                     = $Data.state;
                'StateReason'               = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { $null } else { $Data.stateReason };
                'DiskEncryption'            = $Data.enableDiskEncryption;
                'StreamingIngestion'        = $Data.enableStreamingIngest;
                'OptimizedAutoscale'        = $AutoScale;
                'OptimizedAutoscaleMin'     = $Data.optimizedAutoscale.minimum;
                'OptimizedAutoscaleMax'     = $Data.optimizedAutoscale.maximum;
            }
            $Tmp += $Obj
        }
        $Tmp
    }
}
