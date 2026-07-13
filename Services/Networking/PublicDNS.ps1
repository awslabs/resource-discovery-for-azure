param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $PublicDNS = $Resources | Where-Object { $_.TYPE -eq 'microsoft.network/dnszones' }

    if ($PublicDNS)
    {
        $tmp = @()

        foreach ($1 in $PublicDNS)
        {
            $sub1 = $SUB | Where-Object { $_.Id -eq $1.subscriptionId }
            $data = $1.PROPERTIES

            $obj = @{
                'ID'                        = $1.id;
                'Subscription'              = $sub1.Name;
                'ResourceGroup'             = $1.RESOURCEGROUP;
                'Name'                      = $1.NAME;
                'Location'                  = $1.LOCATION;
                'ZoneType'                  = $data.zoneType;
                'NumberOfRecordSets'        = $data.numberOfRecordSets;
                'MaxNumberOfRecordSets'     = $data.maxNumberofRecordSets;
            }

            $tmp += $obj
        }

        $tmp
    }
}
