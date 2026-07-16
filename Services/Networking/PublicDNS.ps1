param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $PublicDNS = $Resources | Where-Object { $_.TYPE -eq 'microsoft.network/dnszones' }

    if ($PublicDNS)
    {
        $Tmp = @()

        foreach ($1 in $PublicDNS)
        {
            $Sub1 = $SUB | Where-Object { $_.Id -eq $1.subscriptionId }
            $Data = $1.PROPERTIES

            $Obj = @{
                'ID'                        = $1.id;
                'Subscription'              = $Sub1.Name;
                'ResourceGroup'             = $1.RESOURCEGROUP;
                'Name'                      = $1.NAME;
                'Location'                  = $1.LOCATION;
                'ZoneType'                  = $Data.zoneType;
                'NumberOfRecordSets'        = $Data.numberOfRecordSets;
                'MaxNumberOfRecordSets'     = $Data.maxNumberofRecordSets;
            }

            $Tmp += $Obj
        }

        $Tmp
    }
}
