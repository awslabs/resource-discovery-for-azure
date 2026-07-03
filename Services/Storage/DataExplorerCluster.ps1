param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing') 
{
    $DataExplorer = $Resources | Where-Object { $_.TYPE -eq 'microsoft.kusto/clusters' }

    if($DataExplorer)
    {
        $tmp = @()

        foreach ($1 in $DataExplorer) 
        {
            $sub1 = $SUB | Where-Object { $_.Id -eq $1.subscriptionId }
            $data = $1.PROPERTIES
            $sku = $1.SKU

            $AutoScale = if($data.optimizedAutoscale.isEnabled -eq 'true'){'Enabled'}else{'Disabled'}
            
            $obj = @{
                'ID'                        = $1.id;
                'Subscription'              = $sub1.Name;
                'ResourceGroup'             = $1.RESOURCEGROUP;
                'Name'                      = $1.NAME;
                'Location'                  = $1.LOCATION;
                'ComputeSpecifications'     = $sku.name;
                'InstanceCount'             = $sku.capacity;
                'State'                     = $data.state;
                'StateReason'               = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { $null } else { $data.stateReason };
                'DiskEncryption'            = $data.enableDiskEncryption;
                'StreamingIngestion'        = $data.enableStreamingIngest;
                'OptimizedAutoscale'        = $AutoScale;
                'OptimizedAutoscaleMin'     = $data.optimizedAutoscale.minimum;
                'OptimizedAutoscaleMax'     = $data.optimizedAutoscale.maximum;
            }
            $tmp += $obj
        }
        $tmp
    }
}
