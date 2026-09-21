#requires -Version 7.0
param(
    $Subscriptions,
    $Resources,
    $Task,
    $ConcurrencyLimit,
    $FilePath,
    $ResourceIdDictionary,
    $ResourceNameDictionary,
    [Alias('ResourceSubscriptionDictionary')]$ResourceSubDictionary,
    [Alias('ResourceResourceGroupDictionary')]$ResourceGroupDictionary,
    $Obfuscate,
    $MetricsLookbackDays = 31,
    [switch]$IncludeStorageMetrics,
    [switch]$SkipDiskMetrics,
    [ValidateSet(0, 5, 15, 30, 60)][int]$MetricsIntervalMinutes = 0,
    [switch]$MetricsDetailed,
    [switch]$UseMetricsBatch
)

if (-not (Get-Command -Name 'Write-RdaProgress' -ErrorAction SilentlyContinue))
{
    $CommonFunctionsFile = Join-Path (Split-Path $PSScriptRoot -Parent) 'Functions/Common.Functions.ps1'
    if (Test-Path -LiteralPath $CommonFunctionsFile -PathType Leaf)
    {
        . $CommonFunctionsFile
    }
}

if ($Task -eq 'Processing')
{
    function Write-MetricsDiag([string]$Line)
    {
        Write-Log -Message ('[Metrics] ' + $Line) -NoConsole -ToDebugLog
    }

    function Get-RdaMetricGrainPlan
    {
        param([int]$MetricsIntervalMinutes = 0, [switch]$MetricsDetailed)
        $Effective = if ($MetricsIntervalMinutes -gt 0) { $MetricsIntervalMinutes } elseif ($MetricsDetailed) { 0 } else { 60 }
        $Uniform = if ($Effective -gt 0) { ([TimeSpan]::FromMinutes($Effective)).ToString() } else { $null }
        return @{
            Vm   = if ($Uniform) { $Uniform } else { '00:15:00' }
            Sql  = if ($Uniform) { $Uniform } else { '00:30:00' }
            Db   = if ($Uniform) { $Uniform } else { '01:00:00' }
            Disk = if ($MetricsDetailed) { '00:15:00' } else { '01:00:00' }
        }
    }

    function Get-RdaMappedValue
    {
        param($Map, [string]$Key)

        if ($null -eq $Map) { return 'obfuscated' }
        try
        {
            if ($Map.ContainsKey($Key)) { return $Map[$Key] }
        }
        catch { }
        return 'obfuscated'
    }

    function Protect-RdaMetrics
    {
        param($Metrics, $ResourceIdDictionary, $ResourceNameDictionary, $ResourceSubDictionary, $ResourceGroupDictionary)

        foreach ($metric in $Metrics)
        {
            $OriginalId = $metric.ID
            if (![string]::IsNullOrEmpty($OriginalId) -and $null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0 -and $ResourceIdDictionary.ContainsKey($OriginalId))
            {
                $metric.ID = $ResourceIdDictionary[$OriginalId]
                $metric.Name = Get-RdaMappedValue $ResourceNameDictionary $OriginalId
                $metric.Subscription = Get-RdaMappedValue $ResourceSubDictionary $OriginalId
                $metric.ResourceGroup = Get-RdaMappedValue $ResourceGroupDictionary $OriginalId
            }
            else
            {
                if (![string]::IsNullOrEmpty($OriginalId) -and $null -ne $ResourceIdDictionary)
                {
                    $FbPrefix = if ($OriginalId -match '\b(dev|test|qa|tst|development|non-prod|uat|nonprod)\b') { 'nonprod_' } else { 'prod_' }

                    if (-not $script:MetricsFbUriCaches)
                    {
                        $script:MetricsFbUriCaches = @{ Sub = @{}; Rg = @{}; Name = @{} }
                    }
                    if (Get-Command Build-ObfuscatedResourceUri -CommandType Function -ErrorAction SilentlyContinue)
                    {
                        $ResourceIdDictionary[$OriginalId] = Build-ObfuscatedResourceUri -RawUri $OriginalId -Prefix $FbPrefix -SubscriptionDictionary $null -ResourceGroupDictionary $null -NameDictionary $null -SubCache $script:MetricsFbUriCaches.Sub -RgCache $script:MetricsFbUriCaches.Rg -NameCache $script:MetricsFbUriCaches.Name
                    }
                    else
                    {
                        $ResourceIdDictionary[$OriginalId] = $FbPrefix + [guid]::NewGuid().ToString()
                    }
                    $ResourceNameDictionary[$OriginalId] = $FbPrefix + [guid]::NewGuid().ToString()
                    $ResourceSubDictionary[$OriginalId] = $FbPrefix + 'sub_' + [guid]::NewGuid().ToString()
                    $ResourceGroupDictionary[$OriginalId] = $FbPrefix + 'rg_' + [guid]::NewGuid().ToString()
                    $metric.ID = $ResourceIdDictionary[$OriginalId]
                    $metric.Name = $ResourceNameDictionary[$OriginalId]
                    $metric.Subscription = $ResourceSubDictionary[$OriginalId]
                    $metric.ResourceGroup = $ResourceGroupDictionary[$OriginalId]
                }
                else
                {
                    $metric.ID = 'obfuscated'
                    $metric.Name = 'obfuscated'
                    $metric.Subscription = 'obfuscated'
                    $metric.ResourceGroup = 'obfuscated'
                }
            }
        }
    }

    function New-RdaMetricObject
    {
        param($Def, $MetricResult)

        $MetricError = $false
        $DataPoints = @()
        if ($null -ne $MetricResult -and $MetricResult.timeseries -and $null -ne $MetricResult.timeseries[0].data)
        {
            $DataPoints = @($MetricResult.timeseries[0].data)
        }
        $MetricTotalCount = $DataPoints.Count

        $Agg = ([string]$Def.Aggregation).ToLowerInvariant()
        $MetricQueryResults = @($DataPoints | ForEach-Object { $_.$Agg })
        $MetricQueryResultsCount = ($MetricQueryResults.Where({ $null -ne $_ }).Count)
        $MetricPercentile = 0
        $MetricTimeSeries = 0

        if ($MetricQueryResultsCount -eq 0)
        {
            $MetricQueryResults = 0
            $MetricQueryResultsCount = 0
            $MetricPercentile = 0
        }
        else
        {
            $MetricQueryResultsSorted = @($MetricQueryResults | Where-Object { $null -ne $_ } | Sort-Object)
            $MetricPercentileIndex = [math]::Ceiling(0.95 * $MetricQueryResultsSorted.Count) - 1
            $MetricPercentile = $MetricQueryResultsSorted[$MetricPercentileIndex]

            if ($Def.Series -eq 'true')
            {
                $MetricTimeSeries = $MetricQueryResults.Where({ $null -ne $_ })
            }

            switch ($Def.Measure)
            {
                'Average' { $MetricQueryResults = ($MetricQueryResults | Measure-Object -Average).Average }
                'Maximum' { $MetricQueryResults = ($MetricQueryResults | Measure-Object -Maximum).Maximum }
                'Sum' { $MetricQueryResults = ($MetricQueryResults | Measure-Object -Sum).Sum }
                'Minimum' { $MetricQueryResults = ($MetricQueryResults | Measure-Object -Minimum).Minimum }
                'Largest' { $MetricQueryResults = ($MetricQueryResults | Sort-Object -Descending)[0] }
                default
                {
                    throw ("Unhandled Measure '{0}' for metric '{1}' - the per-interval values could not be collapsed to a single figure." -f $_, $Def.MetricName)
                }
            }
        }

        return @{
            'ID'               = $Def.Id;
            'Subscription'     = $Def.SubName;
            'ResourceGroup'    = $Def.ResourceGroup;
            'Name'             = $Def.Name;
            'Location'         = $Def.Location;
            'Service'          = $Def.Service;
            'Metric'           = $Def.MetricName;
            'MetricAggregate'  = $Def.Aggregation;
            'MetricTimeGrain'  = $Def.Interval;
            'MetricMeasure'    = $Def.Measure;
            'MetricPercentile' = $MetricPercentile;
            'MetricValue'      = $MetricQueryResults;
            'MetricCount'      = $MetricQueryResultsCount;
            'MetricTotalCount' = $MetricTotalCount;
            'MetricSeries'     = $MetricTimeSeries;
            'MetricError'      = $MetricError;
        }
    }

    function Invoke-RdaMetricsBatch
    {
        param($Defs, $MetricNamespace)

        $Results = [System.Collections.Generic.List[object]]::new()
        if (-not $Defs -or @($Defs).Count -eq 0) { return $Results.ToArray() }

        $Groups = $Defs | Group-Object -Property { (([string]$_.Id) -split '/')[2] + '|' + $_.Location + '|' + $_.Interval + '|' + $_.StartTime + '|' + $_.EndTime }
        foreach ($Group in $Groups)
        {
            $First = $Group.Group[0]
            $SubscriptionId = (([string]$First.Id) -split '/')[2]
            $Region = $First.Location
            if ([string]::IsNullOrEmpty($SubscriptionId) -or [string]::IsNullOrEmpty($Region))
            {
                throw ("Metrics batch: cannot derive subscription/region from id '{0}'." -f $First.Id)
            }

            $Endpoint = "https://$Region.metrics.monitor.azure.com"
            $MetricNames = @($Group.Group | Select-Object -ExpandProperty MetricName -Unique)
            $Aggregations = @($Group.Group | Select-Object -ExpandProperty Aggregation -Unique | ForEach-Object { ([string]$_).ToLowerInvariant() })
            $StartIso = ([datetime]$First.StartTime).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [cultureinfo]::InvariantCulture)
            $EndIso = ([datetime]$First.EndTime).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [cultureinfo]::InvariantCulture)
            $IntervalIso = [System.Xml.XmlConvert]::ToString([TimeSpan]$First.Interval)

            $TokenObj = Get-AzAccessToken -ResourceUrl 'https://metrics.monitor.azure.com' -WarningAction SilentlyContinue
            $BearerToken = if ($TokenObj.Token -is [securestring]) { [System.Net.NetworkCredential]::new('', $TokenObj.Token).Password } else { [string]$TokenObj.Token }

            $NamesParam = (($MetricNames | ForEach-Object { [uri]::EscapeDataString($_) }) -join ',')
            $NsParam = [uri]::EscapeDataString($MetricNamespace)
            $AggParam = ($Aggregations -join ',')

            $ResourceIds = @($Group.Group | Select-Object -ExpandProperty Id -Unique)
            for ($Offset = 0; $Offset -lt $ResourceIds.Count; $Offset += 50)
            {
                if ($null -ne $TokenObj.ExpiresOn -and $TokenObj.ExpiresOn -lt [DateTimeOffset]::UtcNow.AddMinutes(5))
                {
                    $TokenObj = Get-AzAccessToken -ResourceUrl 'https://metrics.monitor.azure.com' -WarningAction SilentlyContinue
                    $BearerToken = if ($TokenObj.Token -is [securestring]) { [System.Net.NetworkCredential]::new('', $TokenObj.Token).Password } else { [string]$TokenObj.Token }
                }

                $Chunk = @($ResourceIds[$Offset..([math]::Min($Offset + 49, $ResourceIds.Count - 1))])
                $Uri = "{0}/subscriptions/{1}/metrics:getBatch?api-version=2023-10-01&metricnamespace={2}&metricnames={3}&aggregation={4}&interval={5}&starttime={6}&endtime={7}" -f `
                    $Endpoint, $SubscriptionId, $NsParam, $NamesParam, $AggParam, $IntervalIso, $StartIso, $EndIso
                $BodyJson = @{ resourceids = $Chunk } | ConvertTo-Json

                $Response = Invoke-RestMethod -Method Post -Uri $Uri -Headers @{ Authorization = "Bearer $BearerToken"; 'Content-Type' = 'application/json' } -Body $BodyJson -ErrorAction Stop
                $script:MetricsBatchHttpCalls++

                foreach ($ResourceResult in @($Response.values))
                {
                    $ResId = [string]$ResourceResult.resourceid
                    $ResourceDefs = @($Group.Group | Where-Object { ([string]$_.Id) -ieq $ResId })
                    foreach ($Def in $ResourceDefs)
                    {
                        $MetricResult = @($ResourceResult.value | Where-Object { ([string]$_.name.value) -ieq ([string]$Def.MetricName) })[0]
                        if ($null -ne $MetricResult)
                        {
                            $Results.Add((New-RdaMetricObject -Def $Def -MetricResult $MetricResult))
                        }
                    }
                }
            }
        }

        return $Results.ToArray()
    }

    function Initialize-RdaMetricsBatchPrereq
    {
        try
        {
            $Rp = Get-AzResourceProvider -ProviderNamespace 'Microsoft.Insights' -ErrorAction Stop | Select-Object -First 1
            if ($null -ne $Rp -and $Rp.RegistrationState -eq 'Registered')
            {
                Write-MetricsDiag '[batch] Microsoft.Insights resource provider already registered.'
                return
            }

            Write-MetricsDiag ("[batch] Microsoft.Insights RP is '{0}'; registering (required for metrics:getBatch)..." -f $(if ($Rp) { $Rp.RegistrationState } else { 'unknown' }))
            Register-AzResourceProvider -ProviderNamespace 'Microsoft.Insights' -ErrorAction Stop | Out-Null

            $Deadline = (Get-Date).AddSeconds(60)
            $State = ''
            do
            {
                Start-Sleep -Seconds 10
                $State = (Get-AzResourceProvider -ProviderNamespace 'Microsoft.Insights' -ErrorAction SilentlyContinue | Select-Object -First 1).RegistrationState
            } while ($State -ne 'Registered' -and (Get-Date) -lt $Deadline)
            Write-MetricsDiag ("[batch] Microsoft.Insights registration state after wait: {0}" -f $State)
        }
        catch
        {
            Write-MetricsDiag ("[batch] could not ensure Microsoft.Insights registration ({0}). If batch fails, an admin must register the provider: Register-AzResourceProvider -ProviderNamespace Microsoft.Insights" -f $_.Exception.Message)
        }
    }

    $Tmp = New-Object PSObject

    $Tmp | Add-Member -MemberType NoteProperty -Name Metrics -Value NotSet

    $Tmp.Metrics = [System.Collections.Concurrent.ConcurrentBag[psobject]]::new()

    $MetricDefs = [System.Collections.Generic.List[object]]::new()

    $MetricsLookbackPeriodDays = -1 * [math]::Abs([int]$MetricsLookbackDays)

    $MetricStartTime = (Get-Date).AddDays($MetricsLookbackPeriodDays)

    $MetricEndTime = (Get-Date)
    $MetricTimeOneDay = (Get-Date).AddDays(-1)

    $Grain = Get-RdaMetricGrainPlan -MetricsIntervalMinutes $MetricsIntervalMinutes -MetricsDetailed:$MetricsDetailed
    $VmMetricInterval = $Grain.Vm; $SqlMetricInterval = $Grain.Sql; $DbMetricInterval = $Grain.Db; $DiskMetricInterval = $Grain.Disk
    Write-MetricsDiag ("Metric grain (requested {0} min, detailed={4}): VM={1} SQL={2} OSS-DB={3} Disk={5} (default = hourly; -MetricsDetailed = native cadences; a set -MetricsIntervalMinutes is applied uniformly to VM/SQL/OSS-DB and honoured as-is)." -f $MetricsIntervalMinutes, $VmMetricInterval, $SqlMetricInterval, $DbMetricInterval, [bool]$MetricsDetailed, $DiskMetricInterval)

    $SubLookup = @{}
    foreach ($subItem in $Subscriptions)
    {
        if ($null -ne $subItem -and ![string]::IsNullOrEmpty($subItem.id))
        {
            $SubLookup[$subItem.id] = $subItem
        }
    }

    # Define VM Metrics
    $VirtualMachines = $Resources | Where-Object { $_.TYPE -eq 'microsoft.compute/virtualmachines' }

    $MetricCountId = 1;

    if ($VirtualMachines)
    {
        foreach ($virtualMachine in $VirtualMachines)
        {
            $Subscription = $SubLookup[$virtualMachine.subscriptionId]
            $MetricDefs.Add([PSCustomObject]@{
                    MetricIndex = $MetricCountId++;
                    MetricName = 'Percentage CPU';
                    StartTime = $MetricStartTime;
                    EndTime = $MetricEndTime;
                    Interval = $VmMetricInterval;
                    Aggregation = 'Maximum';
                    Measure = 'Average';
                    Id = $virtualMachine.Id;
                    SubName = $Subscription.Name;
                    ResourceGroup = $virtualMachine.ResourceGroup;
                    Name = $virtualMachine.Name;
                    Location = $virtualMachine.Location;
                    Service = 'Virtual Machines';
                    Series = 'true'
                })
            $MetricDefs.Add([PSCustomObject]@{
                    MetricIndex = $MetricCountId++;
                    MetricName = 'Available Memory Bytes';
                    StartTime = $MetricStartTime;
                    EndTime = $MetricEndTime;
                    Interval = $VmMetricInterval;
                    Aggregation = 'Minimum';
                    Measure = 'Average';
                    Id = $virtualMachine.Id;
                    SubName = $Subscription.Name;
                    ResourceGroup = $virtualMachine.ResourceGroup;
                    Name = $virtualMachine.Name;
                    Location = $virtualMachine.Location;
                    Service = 'Virtual Machines';
                    Series = 'true'
                })
        }
    }

    # Define Managed Disk Metrics: composite I/O (IOPS + throughput) for ATTACHED disks only
    $ManagedDisks = $Resources | Where-Object { $_.TYPE -eq 'microsoft.compute/disks' -and -not [string]::IsNullOrEmpty($_.ManagedBy) }

    if ($ManagedDisks -and -not $SkipDiskMetrics)
    {
        foreach ($managedDisk in $ManagedDisks)
        {
            $Subscription = $SubLookup[$managedDisk.subscriptionId]

            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'Composite Disk Read Operations/sec'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = $DiskMetricInterval; Aggregation = 'Maximum'; Measure = 'Average'; Id = $managedDisk.Id; SubName = $Subscription.Name; ResourceGroup = $managedDisk.ResourceGroup; Name = $managedDisk.Name; Location = $managedDisk.Location; Service = 'Managed Disk'; Series = 'true' })
            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'Composite Disk Write Operations/sec'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = $DiskMetricInterval; Aggregation = 'Maximum'; Measure = 'Average'; Id = $managedDisk.Id; SubName = $Subscription.Name; ResourceGroup = $managedDisk.ResourceGroup; Name = $managedDisk.Name; Location = $managedDisk.Location; Service = 'Managed Disk'; Series = 'true' })
            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'Composite Disk Read Bytes/sec'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = $DiskMetricInterval; Aggregation = 'Maximum'; Measure = 'Average'; Id = $managedDisk.Id; SubName = $Subscription.Name; ResourceGroup = $managedDisk.ResourceGroup; Name = $managedDisk.Name; Location = $managedDisk.Location; Service = 'Managed Disk'; Series = 'true' })
            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'Composite Disk Write Bytes/sec'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = $DiskMetricInterval; Aggregation = 'Maximum'; Measure = 'Average'; Id = $managedDisk.Id; SubName = $Subscription.Name; ResourceGroup = $managedDisk.ResourceGroup; Name = $managedDisk.Name; Location = $managedDisk.Location; Service = 'Managed Disk'; Series = 'true' })
        }
    }

    #Define Storage Account Metrics

    $StorageAccounts = $Resources | Where-Object { $_.TYPE -eq 'microsoft.storage/storageaccounts' }

    if ($StorageAccounts)
    {
        if ($IncludeStorageMetrics)
        {
            Write-MetricsDiag ("Storage Account 'UsedCapacity': COLLECTING for {0} account(s) (-IncludeStorageMetrics was passed)." -f @($StorageAccounts).Count)
        }
        else
        {
            Write-MetricsDiag ("Storage Account 'UsedCapacity': skipped for {0} account(s) (opt-in; pass -IncludeStorageMetrics to collect it)." -f @($StorageAccounts).Count)
        }
    }
    if ($StorageAccounts -and $IncludeStorageMetrics)
    {
        foreach ($storageAccount in $StorageAccounts)
        {
            $Subscription = $SubLookup[$storageAccount.subscriptionId]

            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'UsedCapacity'; StartTime = $MetricTimeOneDay; EndTime = $MetricEndTime; Interval = '01:00:00'; Aggregation = 'Maximum'; Measure = 'Largest'; Id = $storageAccount.Id; SubName = $Subscription.Name; ResourceGroup = $storageAccount.ResourceGroup; Name = $storageAccount.Name; Location = $storageAccount.Location; Service = 'Storage Account'; Series = 'false' })
        }
    }

    #Define SQL Metrics

    $SqlDatabases = $Resources | Where-Object { $_.TYPE -eq 'microsoft.sql/servers/databases' -and $_.name -ne 'master' }

    if ($SqlDatabases)
    {
        foreach ($sqlDb in $SqlDatabases)
        {
            $Subscription = $SubLookup[$sqlDb.subscriptionId]

            if ($sqlDb.kind -match 'vcore')
            {
                $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'cpu_limit'; StartTime = $MetricTimeOneDay; EndTime = $MetricEndTime; Interval = '1.00:00:00'; Aggregation = 'Maximum'; Measure = 'Largest'; Id = $sqlDb.Id; SubName = $Subscription.Name; ResourceGroup = $sqlDb.ResourceGroup; Name = $sqlDb.Name; Location = $sqlDb.Location; Service = 'SQL Database'; Series = 'false' })
                $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'cpu_used'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = $SqlMetricInterval; Aggregation = 'Maximum'; Measure = 'Average'; Id = $sqlDb.Id; SubName = $Subscription.Name; ResourceGroup = $sqlDb.ResourceGroup; Name = $sqlDb.Name; Location = $sqlDb.Location; Service = 'SQL Database'; Series = 'true' })

                if ($sqlDb.kind -match 'serverless')
                {
                    $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'app_cpu_billed'; StartTime = $MetricTimeOneDay; EndTime = $MetricEndTime; Interval = '0.00:01:00'; Aggregation = 'Total'; Measure = 'Sum'; Id = $sqlDb.Id; SubName = $Subscription.Name; ResourceGroup = $sqlDb.ResourceGroup; Name = $sqlDb.Name; Location = $sqlDb.Location; Service = 'SQL Database'; Series = 'false' })
                }
            }
            else
            {
                $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'dtu_limit'; StartTime = $MetricTimeOneDay; EndTime = $MetricEndTime; Interval = '1.00:00:00'; Aggregation = 'Maximum'; Measure = 'Largest'; Id = $sqlDb.Id; SubName = $Subscription.Name; ResourceGroup = $sqlDb.ResourceGroup; Name = $sqlDb.Name; Location = $sqlDb.Location; Service = 'SQL Database'; Series = 'false' })
                $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'dtu_used'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = $SqlMetricInterval; Aggregation = 'Maximum'; Measure = 'Average'; Id = $sqlDb.Id; SubName = $Subscription.Name; ResourceGroup = $sqlDb.ResourceGroup; Name = $sqlDb.Name; Location = $sqlDb.Location; Service = 'SQL Database'; Series = 'true' })
            }

            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'cpu_percent'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = $SqlMetricInterval; Aggregation = 'Maximum'; Measure = 'Largest'; Id = $sqlDb.Id; SubName = $Subscription.Name; ResourceGroup = $sqlDb.ResourceGroup; Name = $sqlDb.Name; Location = $sqlDb.Location; Service = 'SQL Database'; Series = 'true' })
            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'allocated_data_storage'; StartTime = $MetricTimeOneDay; EndTime = $MetricEndTime; Interval = '1.00:00:00'; Aggregation = 'Average'; Measure = 'Largest'; Id = $sqlDb.Id; SubName = $Subscription.Name; ResourceGroup = $sqlDb.ResourceGroup; Name = $sqlDb.Name; Location = $sqlDb.Location; Service = 'SQL Database'; Series = 'false' })

            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'storage'; StartTime = $MetricTimeOneDay; EndTime = $MetricEndTime; Interval = '1.00:00:00'; Aggregation = 'Maximum'; Measure = 'Largest'; Id = $sqlDb.Id; SubName = $Subscription.Name; ResourceGroup = $sqlDb.ResourceGroup; Name = $sqlDb.Name; Location = $sqlDb.Location; Service = 'SQL Database'; Series = 'false' })
            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'storage_percent'; StartTime = $MetricTimeOneDay; EndTime = $MetricEndTime; Interval = '1.00:00:00'; Aggregation = 'Maximum'; Measure = 'Largest'; Id = $sqlDb.Id; SubName = $Subscription.Name; ResourceGroup = $sqlDb.ResourceGroup; Name = $sqlDb.Name; Location = $sqlDb.Location; Service = 'SQL Database'; Series = 'false' })

            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'physical_data_read_percent'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = '01:00:00'; Aggregation = 'Average'; Measure = 'Largest'; Id = $sqlDb.Id; SubName = $Subscription.Name; ResourceGroup = $sqlDb.ResourceGroup; Name = $sqlDb.Name; Location = $sqlDb.Location; Service = 'SQL Database'; Series = 'false' })
            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'log_write_percent'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = '01:00:00'; Aggregation = 'Average'; Measure = 'Largest'; Id = $sqlDb.Id; SubName = $Subscription.Name; ResourceGroup = $sqlDb.ResourceGroup; Name = $sqlDb.Name; Location = $sqlDb.Location; Service = 'SQL Database'; Series = 'false' })
        }
    }

    # Define App Service Metrics

    $AppServices = $Resources | Where-Object { $_.TYPE -eq 'microsoft.web/sites' }

    if ($AppServices)
    {
        foreach ($app in $AppServices)
        {
            $Subscription = $SubLookup[$app.subscriptionId]

            # Do NOT narrow this on 'kind': a FlexConsumption (FC1) app and a working Linux Dedicated app
            if ($app.kind -match 'functionapp')
            {
                $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'FunctionExecutionCount'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = '1.00:00:00'; Aggregation = 'Total'; Measure = 'Sum'; Id = $app.Id; SubName = $Subscription.Name; ResourceGroup = $app.ResourceGroup; Name = $app.Name; Location = $app.Location; Service = 'Functions'; Series = 'false' })
                $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'FunctionExecutionUnits'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = '1.00:00:00'; Aggregation = 'Total'; Measure = 'Sum'; Id = $app.Id; SubName = $Subscription.Name; ResourceGroup = $app.ResourceGroup; Name = $app.Name; Location = $app.Location; Service = 'Functions'; Series = 'false' })
            }
        }
    }

    # Define MariaDB Metrics

    $MariaDbs = $Resources | Where-Object { $_.TYPE -eq 'microsoft.dbformariadb/servers' }

    if ($MariaDbs)
    {
        foreach ($mariaDb in $MariaDbs)
        {
            $Subscription = $SubLookup[$mariaDb.subscriptionId]

            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'cpu_percent'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = $DbMetricInterval; Aggregation = 'Maximum'; Measure = 'Maximum'; Id = $mariaDb.Id; SubName = $Subscription.Name; ResourceGroup = $mariaDb.ResourceGroup; Name = $mariaDb.Name; Location = $mariaDb.Location; Service = 'MariaDB'; Series = 'true' })
            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'memory_percent'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = $DbMetricInterval; Aggregation = 'Maximum'; Measure = 'Maximum'; Id = $mariaDb.Id; SubName = $Subscription.Name; ResourceGroup = $mariaDb.ResourceGroup; Name = $mariaDb.Name; Location = $mariaDb.Location; Service = 'MariaDB'; Series = 'true' })
            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'storage_percent'; StartTime = $MetricTimeOneDay; EndTime = $MetricEndTime; Interval = '01:00:00'; Aggregation = 'Average'; Measure = 'Maximum'; Id = $mariaDb.Id; SubName = $Subscription.Name; ResourceGroup = $mariaDb.ResourceGroup; Name = $mariaDb.Name; Location = $mariaDb.Location; Service = 'MariaDB'; Series = 'false' })
        }
    }

    # Define PostgreSQL Metrics

    $PostgresDbs = $Resources | Where-Object { $_.TYPE -eq 'microsoft.dbforpostgresql/servers' }

    if ($PostgresDbs)
    {
        foreach ($postgreDb in $PostgresDbs)
        {
            $Subscription = $SubLookup[$postgreDb.subscriptionId]

            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'cpu_percent'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = $DbMetricInterval; Aggregation = 'Maximum'; Measure = 'Maximum'; Id = $postgreDb.Id; SubName = $Subscription.Name; ResourceGroup = $postgreDb.ResourceGroup; Name = $postgreDb.Name; Location = $postgreDb.Location; Service = 'PostgreSQL'; Series = 'true' })
            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'memory_percent'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = $DbMetricInterval; Aggregation = 'Maximum'; Measure = 'Maximum'; Id = $postgreDb.Id; SubName = $Subscription.Name; ResourceGroup = $postgreDb.ResourceGroup; Name = $postgreDb.Name; Location = $postgreDb.Location; Service = 'PostgreSQL'; Series = 'true' })
            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'storage_percent'; StartTime = $MetricTimeOneDay; EndTime = $MetricEndTime; Interval = '01:00:00'; Aggregation = 'Average'; Measure = 'Maximum'; Id = $postgreDb.Id; SubName = $Subscription.Name; ResourceGroup = $postgreDb.ResourceGroup; Name = $postgreDb.Name; Location = $postgreDb.Location; Service = 'PostgreSQL'; Series = 'false' })
        }
    }

    # Define MySQL Metrics

    $MySqldbs = $Resources | Where-Object { $_.TYPE -eq 'microsoft.DBforMySQL/servers' }

    if ($MySqldbs)
    {
        foreach ($mysqlDb in $MySqldbs)
        {
            $Subscription = $SubLookup[$mysqlDb.subscriptionId]

            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'cpu_percent'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = $DbMetricInterval; Aggregation = 'Maximum'; Measure = 'Maximum'; Id = $mysqlDb.Id; SubName = $Subscription.Name; ResourceGroup = $mysqlDb.ResourceGroup; Name = $mysqlDb.Name; Location = $mysqlDb.Location; Service = 'MySQL'; Series = 'true' })
            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'memory_percent'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = $DbMetricInterval; Aggregation = 'Maximum'; Measure = 'Maximum'; Id = $mysqlDb.Id; SubName = $Subscription.Name; ResourceGroup = $mysqlDb.ResourceGroup; Name = $mysqlDb.Name; Location = $mysqlDb.Location; Service = 'MySQL'; Series = 'true' })
            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'storage_percent'; StartTime = $MetricTimeOneDay; EndTime = $MetricEndTime; Interval = '01:00:00'; Aggregation = 'Average'; Measure = 'Maximum'; Id = $mysqlDb.Id; SubName = $Subscription.Name; ResourceGroup = $mysqlDb.ResourceGroup; Name = $mysqlDb.Name; Location = $mysqlDb.Location; Service = 'MySQL'; Series = 'false' })
        }
    }

    # Define MySQL Flexible Metrics

    $MySqldbs = $Resources | Where-Object { $_.TYPE -eq 'microsoft.DBforMySQL/flexibleServers' }

    if ($MySqldbs)
    {
        foreach ($mysqlDb in $MySqldbs)
        {
            $Subscription = $SubLookup[$mysqlDb.subscriptionId]

            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'cpu_percent'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = $DbMetricInterval; Aggregation = 'Maximum'; Measure = 'Maximum'; Id = $mysqlDb.Id; SubName = $Subscription.Name; ResourceGroup = $mysqlDb.ResourceGroup; Name = $mysqlDb.Name; Location = $mysqlDb.Location; Service = 'MySQL Flexible'; Series = 'true' })
            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'memory_percent'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = $DbMetricInterval; Aggregation = 'Maximum'; Measure = 'Maximum'; Id = $mysqlDb.Id; SubName = $Subscription.Name; ResourceGroup = $mysqlDb.ResourceGroup; Name = $mysqlDb.Name; Location = $mysqlDb.Location; Service = 'MySQL Flexible'; Series = 'true' })
            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'storage_percent'; StartTime = $MetricTimeOneDay; EndTime = $MetricEndTime; Interval = '01:00:00'; Aggregation = 'Average'; Measure = 'Maximum'; Id = $mysqlDb.Id; SubName = $Subscription.Name; ResourceGroup = $mysqlDb.ResourceGroup; Name = $mysqlDb.Name; Location = $mysqlDb.Location; Service = 'MySQL Flexible'; Series = 'false' })
        }
    }

    # Define PostgreSQL Flexible Metrics

    $PostgresDbs = $Resources | Where-Object { $_.TYPE -eq 'microsoft.DBforPostgreSQL/flexibleServers' }

    if ($PostgresDbs)
    {
        foreach ($postgreDb in $PostgresDbs)
        {
            $Subscription = $SubLookup[$postgreDb.subscriptionId]

            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'cpu_percent'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = $DbMetricInterval; Aggregation = 'Maximum'; Measure = 'Maximum'; Id = $postgreDb.Id; SubName = $Subscription.Name; ResourceGroup = $postgreDb.ResourceGroup; Name = $postgreDb.Name; Location = $postgreDb.Location; Service = 'PostgreSQL Flexible'; Series = 'true' })
            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'memory_percent'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = $DbMetricInterval; Aggregation = 'Maximum'; Measure = 'Maximum'; Id = $postgreDb.Id; SubName = $Subscription.Name; ResourceGroup = $postgreDb.ResourceGroup; Name = $postgreDb.Name; Location = $postgreDb.Location; Service = 'PostgreSQL Flexible'; Series = 'true' })
            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'storage_percent'; StartTime = $MetricTimeOneDay; EndTime = $MetricEndTime; Interval = '01:00:00'; Aggregation = 'Average'; Measure = 'Maximum'; Id = $postgreDb.Id; SubName = $Subscription.Name; ResourceGroup = $postgreDb.ResourceGroup; Name = $postgreDb.Name; Location = $postgreDb.Location; Service = 'PostgreSQL Flexible'; Series = 'false' })
        }
    }

    # Define Scale Set Metrics

    $VmScaleSets = $Resources | Where-Object { $_.TYPE -eq 'microsoft.compute/virtualmachinescalesets' }

    if ($VmScaleSets)
    {
        foreach ($vmss in $VmScaleSets)
        {
            $Subscription = $SubLookup[$vmss.subscriptionId]

            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'Percentage CPU'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = '01:00:00'; Aggregation = 'Maximum'; Measure = 'Average'; Id = $vmss.Id; SubName = $Subscription.Name; ResourceGroup = $vmss.ResourceGroup; Name = $vmss.Name; Location = $vmss.Location; Service = 'Virtual Machines Scale Sets'; Series = 'false' })
            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'Available Memory Bytes'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = '01:00:00'; Aggregation = 'Minimum'; Measure = 'Average'; Id = $vmss.Id; SubName = $Subscription.Name; ResourceGroup = $vmss.ResourceGroup; Name = $vmss.Name; Location = $vmss.Location; Service = 'Virtual Machines Scale Sets'; Series = 'false' })
        }
    }

    # Define CosmosDB Metrics

    $CosmosDbs = $Resources | Where-Object { $_.TYPE -eq 'microsoft.documentdb/databaseaccounts' }

    if ($CosmosDbs)
    {
        foreach ($cosmosDb in $CosmosDbs)
        {
            $Subscription = $SubLookup[$cosmosDb.subscriptionId]

            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'TotalRequests'; StartTime = $MetricTimeOneDay; EndTime = $MetricEndTime; Interval = '00:01:00'; Aggregation = 'Count'; Measure = 'Largest'; Id = $cosmosDb.Id; SubName = $Subscription.Name; ResourceGroup = $cosmosDb.ResourceGroup; Name = $cosmosDb.Name; Location = $cosmosDb.Location; Service = 'CosmosDB'; Series = 'false' })
            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'TotalRequestUnits'; StartTime = $MetricTimeOneDay; EndTime = $MetricEndTime; Interval = '00:01:00'; Aggregation = 'Total'; Measure = 'Sum'; Id = $cosmosDb.Id; SubName = $Subscription.Name; ResourceGroup = $cosmosDb.ResourceGroup; Name = $cosmosDb.Name; Location = $cosmosDb.Location; Service = 'CosmosDB'; Series = 'false' })
            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'DataUsage'; StartTime = $MetricTimeOneDay; EndTime = $MetricEndTime; Interval = '01:00:00'; Aggregation = 'Total'; Measure = 'Largest'; Id = $cosmosDb.Id; SubName = $Subscription.Name; ResourceGroup = $cosmosDb.ResourceGroup; Name = $cosmosDb.Name; Location = $cosmosDb.Location; Service = 'CosmosDB'; Series = 'false' })
            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'ProvisionedThroughput'; StartTime = $MetricTimeOneDay; EndTime = $MetricEndTime; Interval = '01:00:00'; Aggregation = 'Maximum'; Measure = 'Largest'; Id = $cosmosDb.Id; SubName = $Subscription.Name; ResourceGroup = $cosmosDb.ResourceGroup; Name = $cosmosDb.Name; Location = $cosmosDb.Location; Service = 'CosmosDB'; Series = 'false' })
        }
    }

    # Define Container Registry Metrics

    $ContainerRegistry = $Resources | Where-Object { $_.TYPE -eq 'microsoft.containerregistry/registries' }

    if ($ContainerRegistry)
    {
        foreach ($registry in $ContainerRegistry)
        {
            $Subscription = $SubLookup[$registry.subscriptionId]

            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'StorageUsed'; StartTime = $MetricTimeOneDay; EndTime = $MetricEndTime; Interval = '01:00:00'; Aggregation = 'Maximum'; Measure = 'Largest'; Id = $registry.Id; SubName = $Subscription.Name; ResourceGroup = $registry.ResourceGroup; Name = $registry.Name; Location = $registry.Location; Service = 'ContainerRegistry'; Series = 'false' })
        }
    }

    $MetricCount = $MetricDefs.Count

    $script:MetricsBatchHttpCalls = 0

    if ($UseMetricsBatch)
    {
        $BatchNamespaceMap = [ordered]@{
            'Virtual Machines'            = 'microsoft.compute/virtualMachines'
            'Managed Disk'                = 'microsoft.compute/disks'
            'Storage Account'             = 'microsoft.storage/storageAccounts'
            'SQL Database'                = 'microsoft.sql/servers/databases'
            'Virtual Machines Scale Sets' = 'microsoft.compute/virtualMachineScaleSets'
            'CosmosDB'                    = 'microsoft.documentdb/databaseAccounts'
        }

        $RemainingDefs = [System.Collections.Generic.List[object]]::new()
        $BatchGroups = [ordered]@{}
        foreach ($Def in $MetricDefs)
        {
            if ($BatchNamespaceMap.Contains($Def.Service))
            {
                if (-not $BatchGroups.Contains($Def.Service)) { $BatchGroups[$Def.Service] = [System.Collections.Generic.List[object]]::new() }
                $BatchGroups[$Def.Service].Add($Def)
            }
            else
            {
                $RemainingDefs.Add($Def)
            }
        }

        if ($BatchGroups.Count -gt 0)
        {
            Initialize-RdaMetricsBatchPrereq

            foreach ($Service in $BatchGroups.Keys)
            {
                $ServiceDefs = $BatchGroups[$Service]
                $Namespace = $BatchNamespaceMap[$Service]
                try
                {
                    $BatchObjects = Invoke-RdaMetricsBatch -Defs $ServiceDefs -MetricNamespace $Namespace
                    if (@($BatchObjects).Count -eq 0)
                    {
                        throw ("getBatch returned no metric records for {0} {1} metric def(s)." -f $ServiceDefs.Count, $Service)
                    }

                    $SatisfiedKeys = @{}
                    foreach ($BatchObj in $BatchObjects)
                    {
                        $SatisfiedKeys[('{0}|{1}' -f ([string]$BatchObj.ID).ToLower(), $BatchObj.Metric)] = $true
                    }
                    foreach ($Def in $ServiceDefs)
                    {
                        if (-not $SatisfiedKeys.ContainsKey(('{0}|{1}' -f ([string]$Def.Id).ToLower(), $Def.MetricName)))
                        {
                            $RemainingDefs.Add($Def)
                        }
                    }

                    foreach ($BatchObj in $BatchObjects) { $Tmp.Metrics.Add($BatchObj) }
                    Write-MetricsDiag ("Metrics batch fast-path: fetched {0} {1} metric record(s) via getBatch." -f $BatchObjects.Count, $Service)
                }
                catch
                {
                    foreach ($Def in $ServiceDefs) { $RemainingDefs.Add($Def) }
                    $BatchErr = $_.Exception.Message
                    $Hint = if ($BatchErr -match '(?i)403|AuthorizationFailed|does not have access|does not have authorization')
                    {
                        'the signed-in identity lacks subscription-level read for the metrics data plane - assign Reader or Monitoring Reader at the subscription scope, and ensure Microsoft.Insights is registered'
                    }
                    else
                    {
                        'ensure Microsoft.Insights is registered and the region/resources are reachable'
                    }
                    Write-MetricsDiag ("WARNING: metrics batch fast-path failed for {0} ({1}). {2}. Those metrics fall back to per-call (no data lost)." -f $Service, $BatchErr, $Hint)
                }
            }

            if ($Tmp.Metrics.Count -gt 0)
            {
                if ($Obfuscate)
                {
                    Protect-RdaMetrics -Metrics $Tmp.Metrics -ResourceIdDictionary $ResourceIdDictionary -ResourceNameDictionary $ResourceNameDictionary -ResourceSubDictionary $ResourceSubDictionary -ResourceGroupDictionary $ResourceGroupDictionary
                }
                $BatchOutputPath = $FilePath + "_0.json"
                $Tmp | ConvertTo-Json -depth 5 -compress | Out-File -LiteralPath $BatchOutputPath -Encoding utf8
                $Tmp.Metrics.Clear()
            }

            $MetricDefs = $RemainingDefs
            $MetricCount = $MetricDefs.Count
            Write-MetricsDiag ("Metrics batch fast-path: {0} metric def(s) remain on the per-call path." -f $MetricCount)
        }
    }

    $WarningPreference = "SilentlyContinue"

    $MetricAzContext = $null
    try
    {
        $MetricAzContext = (Get-AzContext)
    }
    catch
    {
        Write-MetricsDiag "WARNING: could not capture Az context for parallel runspaces; metric calls will rely on per-runspace context autosave."
    }

    $MetricTimeoutSeconds = 120
    $MetricMaxRetries = 3
    $MetricMaxThrottleRetries = 6
    $MetricMaxRetryAfterSeconds = 120
    $MetricRetryAfterFnDef = if (Get-Command Get-RdaRetryAfterSeconds -CommandType Function -ErrorAction SilentlyContinue) { ${function:Get-RdaRetryAfterSeconds}.ToString() } else { $null }

    $MetricDiagnostics = [System.Collections.Concurrent.ConcurrentBag[psobject]]::new()

    $PhaseStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Write-MetricsDiag ("Starting metrics collection: {0} metric definition(s), ThrottleLimit={1}, per-call timeout={2}s, max retries={3}, throttle retries={5} (honours Retry-After up to {6}s), lookback={4} day(s)." -f $MetricCount, $ConcurrencyLimit, $MetricTimeoutSeconds, $MetricMaxRetries, [math]::Abs($MetricsLookbackPeriodDays), $MetricMaxThrottleRetries, $MetricMaxRetryAfterSeconds)

    $RangeBatch = [math]::Min($MetricCount , 250)
    $RangeIdx = 1
    $MetricsProcessed = 0
    $Defs = [System.Collections.Generic.List[object]]::new()

    for ($i = 0; $i -lt $MetricCount; $i++)
    {
        $Defs.Add($MetricDefs[$i])
        $MetricsProcessed++

        if ($Defs.Count -ge $RangeBatch -or $MetricsProcessed -ge $MetricCount)
        {
            $BatchStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            Write-RdaProgress -Activity 'Metrics collection' -CurrentItem ("batch {0} ({1} call(s))" -f $RangeIdx, $Defs.Count) -Index $MetricsProcessed -Total $MetricCount -BarOnly
            Write-Verbose ("[Metrics] Batch {0}: dispatching {1} metric call(s) (processed {2}/{3})." -f $RangeIdx, $Defs.Count, $MetricsProcessed, $MetricCount)

            $Defs | ForEach-Object -Parallel {
                $AzContext = $using:MetricAzContext
                $CallTimeoutSeconds = $using:MetricTimeoutSeconds
                $CallMaxRetries = $using:MetricMaxRetries
                $CallMaxThrottleRetries = $using:MetricMaxThrottleRetries
                $CallMaxRetryAfterSeconds = $using:MetricMaxRetryAfterSeconds
                $RetryAfterFnDef = $using:MetricRetryAfterFnDef
                if ($RetryAfterFnDef) { Set-Item -Path function:Get-RdaRetryAfterSeconds -Value ([scriptblock]::Create($RetryAfterFnDef)) }
                $DiagBag = $using:MetricDiagnostics

                $MetricError = $false
                $MetricName = $_.MetricName
                $MetricService = $_.Service

                $CallStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                $CallOutcome = 'Success'
                $CallAttempts = 0
                $CallErrorMsg = $null
                $CallErrorBody = $null

                function Get-RdaMetricFailureClass
                {
                    param([string]$Message)
                    if ($Message -match "invalid status code '?(?<Status>NotFound|BadRequest|Unauthorized|Forbidden)'?")
                    {
                        return @{ Permanent = $true; Outcome = $Matches['Status']; Throttled = $false }
                    }
                    if ($Message -match 'ExpiredAuthenticationToken|InvalidAuthenticationToken|AuthenticationFailed')
                    {
                        return @{ Permanent = $true; Outcome = 'Unauthorized'; Throttled = $false }
                    }
                    if ($Message -match 'AuthorizationFailed')
                    {
                        return @{ Permanent = $true; Outcome = 'Forbidden'; Throttled = $false }
                    }
                    if ($Message -match '429|throttl|TooManyRequests|rate limit')
                    {
                        return @{ Permanent = $false; Outcome = 'Throttled'; Throttled = $true }
                    }
                    return @{ Permanent = $false; Outcome = 'Error'; Throttled = $false }
                }

                function Get-RdaMetricRetryPlan
                {
                    param(
                        [int]$Attempt, [bool]$Throttled, [int]$ThrottledAttempts, [double]$RetryAfterSeconds, [bool]$Permanent,
                        [int]$MaxRetries, [int]$MaxThrottleRetries, [double]$MaxRetryAfterSeconds
                    )
                    if ($Permanent) { return @{ Retry = $false; SleepSeconds = 0 } }
                    $Retry = if ($Throttled) { $ThrottledAttempts -le $MaxThrottleRetries } else { $Attempt -lt $MaxRetries }
                    if (-not $Retry) { return @{ Retry = $false; SleepSeconds = 0 } }
                    $Backoff = [math]::Min([math]::Pow(2, $Attempt), 30)
                    if ($Throttled)
                    {
                        $Backoff = [math]::Min($Backoff * 2, 60)
                        if ($RetryAfterSeconds -gt 0) { $Backoff = [math]::Min([math]::Max($RetryAfterSeconds, $Backoff), $MaxRetryAfterSeconds) }
                    }
                    return @{ Retry = $true; SleepSeconds = $Backoff }
                }

                function Get-RdaMetricErrorBody
                {
                    param($ErrorRecord)

                    try
                    {
                        if ($null -eq $ErrorRecord) { return $null }

                        $Found = $null

                        try
                        {
                            $Details = $ErrorRecord.ErrorDetails.Message
                            if (-not [string]::IsNullOrWhiteSpace($Details)) { $Found = [string]$Details }
                        }
                        catch { }

                        if ([string]::IsNullOrWhiteSpace($Found))
                        {
                            $Visited = [System.Collections.Generic.HashSet[int]]::new()
                            $Current = $ErrorRecord.Exception
                            $Depth = 0

                            while ($null -ne $Current -and $Depth -lt 10)
                            {
                                $Key = [System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($Current)
                                if (-not $Visited.Add($Key)) { break }

                                foreach ($Probe in @(
                                        { $Current.Response.Content },
                                        { $Current.Body }
                                    ))
                                {
                                    try
                                    {
                                        $Value = & $Probe
                                        if ($null -ne $Value -and -not ($Value -is [System.IO.Stream]))
                                        {
                                            $Text = [string]$Value
                                            if (-not [string]::IsNullOrWhiteSpace($Text)) { $Found = $Text; break }
                                        }
                                    }
                                    catch { }
                                }

                                if (-not [string]::IsNullOrWhiteSpace($Found)) { break }

                                $Current = $Current.InnerException
                                $Depth++
                            }
                        }

                        if ([string]::IsNullOrWhiteSpace($Found)) { return $null }

                        $Rendered = $Found
                        try
                        {
                            $Parsed = $Found | ConvertFrom-Json -ErrorAction Stop
                            $Node = if ($null -ne $Parsed.error) { $Parsed.error } else { $Parsed }
                            $Code = [string]$Node.code
                            $Msg = [string]$Node.message
                            if (-not [string]::IsNullOrWhiteSpace($Code) -or -not [string]::IsNullOrWhiteSpace($Msg))
                            {
                                $Rendered = (@($Code, $Msg) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ': '
                            }
                        }
                        catch { }

                        $Rendered = ([string]$Rendered) -replace '\s+', ' '
                        $Rendered = $Rendered.Trim()

                        $BodyCap = 2000
                        $TruncationMarkerBudget = 32
                        if ($Rendered.Length -gt ($BodyCap + $TruncationMarkerBudget))
                        {
                            $HeadLen = [int]($BodyCap * 0.6)
                            $TailLen = $BodyCap - $HeadLen
                            $Rendered = $Rendered.Substring(0, $HeadLen) +
                            ('...[{0} chars omitted]...' -f ($Rendered.Length - $BodyCap)) +
                            $Rendered.Substring($Rendered.Length - $TailLen)
                        }
                        if ([string]::IsNullOrWhiteSpace($Rendered)) { return $null }
                        return $Rendered
                    }
                    catch
                    {
                        return $null
                    }
                }

                $MetricArgs = @{
                    ResourceId      = $_.Id
                    MetricName      = $_.MetricName
                    StartTime       = $_.StartTime
                    EndTime         = $_.EndTime
                    TimeGrain       = $_.Interval
                    AggregationType = $_.Aggregation
                    ErrorAction     = 'Stop'
                    WarningAction   = 'SilentlyContinue'
                }
                if ($null -ne $AzContext)
                {
                    $MetricArgs['DefaultProfile'] = $AzContext
                }

                try
                {
                    $Attempt = 0
                    $ThrottledAttempts = 0
                    $Succeeded = $false
                    $LastError = $null
                    $MetricQuery = $null

                    while (-not $Succeeded)
                    {
                        $CallAttempts = $Attempt + 1
                        $TimedOut = $false
                        $Throttled = $false
                        $RetryAfterSeconds = 0
                        $CallErrorBody = $null
                        $Permanent = $false
                        $PermanentOutcome = $null

                        $Job = Start-ThreadJob -ScriptBlock {
                            param($MArgs)
                            Get-AzMetric @MArgs
                        } -ArgumentList $MetricArgs

                        if (Wait-Job -Job $Job -Timeout $CallTimeoutSeconds)
                        {
                            try
                            {
                                $MetricQuery = Receive-Job -Job $Job -ErrorAction Stop
                                $Succeeded = $true
                            }
                            catch
                            {
                                $LastError = $_.Exception.Message

                                $CallErrorBody = Get-RdaMetricErrorBody -ErrorRecord $_

                                $FailureClass = Get-RdaMetricFailureClass -Message $LastError
                                if ($FailureClass.Permanent)
                                {
                                    $Permanent = $true
                                    $PermanentOutcome = $FailureClass.Outcome
                                }
                                elseif ($FailureClass.Throttled)
                                {
                                    $Throttled = $true
                                    $ThrottledAttempts++
                                    if (Get-Command Get-RdaRetryAfterSeconds -ErrorAction SilentlyContinue)
                                    {
                                        try { $RetryAfterSeconds = [double](Get-RdaRetryAfterSeconds -ErrorRecord $_) } catch { $RetryAfterSeconds = 0 }
                                    }
                                }
                            }
                            finally
                            {
                                Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue
                            }
                        }
                        else
                        {
                            $TimedOut = $true
                            $LastError = ("Timed out after {0}s" -f $CallTimeoutSeconds)
                            Stop-Job -Job $Job -ErrorAction SilentlyContinue
                            Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue
                        }

                        if ($Succeeded)
                        {
                            break
                        }

                        $Plan = Get-RdaMetricRetryPlan -Attempt $Attempt -Throttled $Throttled -ThrottledAttempts $ThrottledAttempts -RetryAfterSeconds $RetryAfterSeconds -Permanent $Permanent `
                            -MaxRetries $CallMaxRetries -MaxThrottleRetries $CallMaxThrottleRetries -MaxRetryAfterSeconds $CallMaxRetryAfterSeconds
                        if ($Plan.Retry)
                        {
                            $Jitter = (Get-Random -Minimum 0 -Maximum 1000) / 1000.0
                            $SleepSeconds = [math]::Round($Plan.SleepSeconds + $Jitter, 2)
                            Start-Sleep -Seconds $SleepSeconds
                        }
                        else
                        {
                            $CallOutcome = if ($Permanent) { $PermanentOutcome } elseif ($TimedOut) { 'Timeout' } elseif ($Throttled) { 'Throttled' } else { 'Error' }

                            break
                        }

                        $Attempt++
                    }

                    if (-not $Succeeded)
                    {
                        throw ("Get-AzMetric failed after {0} attempt(s): {1}" -f $CallAttempts, $LastError)
                    }

                    $MetricTotalCount = @($MetricQuery.Data).Count

                    $MetricQueryResults = 0
                    $MetricTimeSeries = 0

                    switch ($_.Aggregation)
                    {
                        'Average'
                        {
                            $MetricQueryResults = $MetricQuery.Data.Average
                        }
                        'Maximum'
                        {
                            $MetricQueryResults = $MetricQuery.Data.Maximum
                        }
                        'Count'
                        {
                            $MetricQueryResults = $MetricQuery.Data.Count
                        }
                        'Total'
                        {
                            $MetricQueryResults = $MetricQuery.Data.Total
                        }
                        'Minimum'
                        {
                            $MetricQueryResults = $MetricQuery.Data.Minimum
                        }
                        default
                        {
                            throw ("Unhandled Aggregation '{0}' for metric '{1}' - no value could be read from the response." -f $_, $MetricName)
                        }
                    }

                    $MetricQueryResultsCount = ($MetricQueryResults.Where({ $null -ne $_ }).Count)

                    if ($MetricQueryResultsCount -eq 0)
                    {
                        $MetricQueryResults = 0
                        $MetricQueryResultsCount = 0
                        $MetricPercentileIndex = 0
                        $MetricPercentile = 0
                    }
                    else
                    {
                        $MetricQueryResultsSorted = @($MetricQueryResults | Where-Object { $null -ne $_ } | Sort-Object)
                        $MetricPercentileIndex = [math]::Ceiling(0.95 * $MetricQueryResultsSorted.Count) - 1
                        $MetricPercentile = $MetricQueryResultsSorted[$MetricPercentileIndex]

                        if ($_.Series -eq 'true')
                        {
                            $MetricTimeSeries = $MetricQueryResults.Where({ $null -ne $_ })
                        }

                        switch ($_.Measure)
                        {
                            'Average' { $MetricQueryResults = ($MetricQueryResults | Measure-Object -Average).Average }
                            'Maximum' { $MetricQueryResults = ($MetricQueryResults | Measure-Object -Maximum).Maximum }
                            'Sum' { $MetricQueryResults = ($MetricQueryResults | Measure-Object -Sum).Sum }
                            'Minimum' { $MetricQueryResults = ($MetricQueryResults | Measure-Object -Minimum).Minimum }
                            'Largest' { $MetricQueryResults = ($MetricQueryResults | Sort-Object -Descending)[0] }
                            default
                            {
                                throw ("Unhandled Measure '{0}' for metric '{1}' - the per-interval values could not be collapsed to a single figure." -f $_, $MetricName)
                            }
                        }
                    }
                }
                catch
                {
                    $MetricQueryResults = 0
                    $MetricQueryResultsCount = 0
                    $MetricTotalCount = 0
                    $MetricPercentileIndex = 0
                    $MetricPercentile = 0

                    $MetricError = $true
                    if ($CallOutcome -eq 'Success') { $CallOutcome = 'Error' }
                    $CallErrorMsg = $_.Exception.Message
                }

                $CallStopwatch.Stop()
                $DiagBag.Add([PSCustomObject]@{
                        MetricIndex = $_.MetricIndex
                        Service     = $MetricService
                        Name        = $_.Name
                        Metric      = $MetricName
                        Interval    = $_.Interval
                        Aggregation = $_.Aggregation
                        Outcome     = $CallOutcome
                        Attempts    = $CallAttempts
                        ElapsedSec  = [math]::Round($CallStopwatch.Elapsed.TotalSeconds, 2)
                        Error       = $CallErrorMsg
                        ErrorBody   = $CallErrorBody
                    })

                $Obj = @{
                    'ID'                   = $_.Id;
                    'Subscription'         = $_.SubName;
                    'ResourceGroup'        = $_.ResourceGroup;
                    'Name'                 = $_.Name;
                    'Location'             = $_.Location;
                    'Service'              = $_.Service;
                    'Metric'               = $_.MetricName;
                    'MetricAggregate'      = $_.Aggregation;
                    'MetricTimeGrain'      = $_.Interval;
                    'MetricMeasure'        = $_.Measure;
                    'MetricPercentile'     = $MetricPercentile;
                    'MetricValue'          = $MetricQueryResults;
                    'MetricCount'          = $MetricQueryResultsCount;
                    'MetricTotalCount'     = $MetricTotalCount;
                    'MetricSeries'         = $MetricTimeSeries;
                    'MetricError'          = $MetricError;
                }

                ($using:Tmp).Metrics.Add($Obj)

                $MetricQuery = $null
                $MetricQueryResults = $null
                $MetricQueryResultsCount = $null
                $MetricTotalCount = $null
                $MetricTimeSeries = $null
                $MetricQueryResultsSorted = $null
                $MetricPercentile = $null;

            } -ThrottleLimit $ConcurrencyLimit

            $Defs.Clear()

            $BatchStopwatch.Stop()
            Write-Verbose ("[Metrics] Batch {0} complete in {1}s. Cumulative diagnostics: {2} call record(s) so far." -f $RangeIdx, [math]::Round($BatchStopwatch.Elapsed.TotalSeconds, 1), $MetricDiagnostics.Count)

            if ($Obfuscate)
            {
                Protect-RdaMetrics -Metrics $Tmp.Metrics -ResourceIdDictionary $ResourceIdDictionary -ResourceNameDictionary $ResourceNameDictionary -ResourceSubDictionary $ResourceSubDictionary -ResourceGroupDictionary $ResourceGroupDictionary
            }

            $OutputPath = $FilePath + "_" + $RangeIdx + ".json"
            $Tmp | ConvertTo-Json -depth 5 -compress | Out-File -LiteralPath $OutputPath -Encoding utf8
            $Tmp.Metrics.Clear()

            $RangeIdx++
        }
    }

    Write-RdaProgress -Activity 'Metrics collection' -Completed

    $PhaseStopwatch.Stop()

    $DiagRecords = @($MetricDiagnostics)
    $OkCount = @($DiagRecords | Where-Object { $_.Outcome -eq 'Success' }).Count
    $TimeoutCount = @($DiagRecords | Where-Object { $_.Outcome -eq 'Timeout' }).Count
    $ThrottledCount = @($DiagRecords | Where-Object { $_.Outcome -eq 'Throttled' }).Count
    $ErrorCount = @($DiagRecords | Where-Object { $_.Outcome -eq 'Error' }).Count
    $NotFoundCount = @($DiagRecords | Where-Object { $_.Outcome -eq 'NotFound' }).Count
    $BadRequestCount = @($DiagRecords | Where-Object { $_.Outcome -eq 'BadRequest' }).Count
    $UnauthorizedCount = @($DiagRecords | Where-Object { $_.Outcome -eq 'Unauthorized' }).Count
    $ForbiddenCount = @($DiagRecords | Where-Object { $_.Outcome -eq 'Forbidden' }).Count

    Write-MetricsDiag ("===== Metrics phase summary =====")
    Write-MetricsDiag ("Total calls: {0} | Success: {1} | Timeout: {2} | Throttled: {3} | Error: {4} | NotFound: {5} | BadRequest: {6} | Unauthorized: {8} | Forbidden: {9} | Elapsed: {7}s" -f $DiagRecords.Count, $OkCount, $TimeoutCount, $ThrottledCount, $ErrorCount, $NotFoundCount, $BadRequestCount, [math]::Round($PhaseStopwatch.Elapsed.TotalSeconds, 1), $UnauthorizedCount, $ForbiddenCount)

    $PerCallHttpCalls = if ($DiagRecords.Count -gt 0) { [int]($DiagRecords | Measure-Object -Property Attempts -Sum).Sum } else { 0 }
    $BatchHttpCalls = [int]$script:MetricsBatchHttpCalls
    Write-MetricsDiag ("Metric-query API calls issued (this subscription): {0} total | per-call Get-AzMetric incl. retries: {1} | getBatch POSTs: {2}. Counts toward the Azure Monitor 'metric queries' meter (10,000,000 free/account/month)." -f ($PerCallHttpCalls + $BatchHttpCalls), $PerCallHttpCalls, $BatchHttpCalls)

    if ($null -eq $Global:MetricsApiCallCount) { $Global:MetricsApiCallCount = 0 }
    $Global:MetricsApiCallCount = [int]$Global:MetricsApiCallCount + $PerCallHttpCalls + $BatchHttpCalls

    if (($TimeoutCount + $ThrottledCount + $ErrorCount) -gt 0)
    {
        Write-MetricsDiag ("Non-success calls (where it got stuck):")
        foreach ($rec in ($DiagRecords | Where-Object { $_.Outcome -in @('Timeout', 'Throttled', 'Error') } | Sort-Object ElapsedSec -Descending))
        {
            $StuckBodyNote = if ([string]::IsNullOrWhiteSpace($rec.ErrorBody)) { '' } else { (' | azure: ' + $rec.ErrorBody) }
            Write-MetricsDiag ("  {0} idx={1} {2}/{3}/{4} interval={5} attempts={6} {7}s {8}{9}" -f $rec.Outcome, $rec.MetricIndex, $rec.Service, $rec.Name, $rec.Metric, $rec.Interval, $rec.Attempts, $rec.ElapsedSec, $rec.Error, $StuckBodyNote)
        }
    }

    if (($UnauthorizedCount + $ForbiddenCount) -gt 0)
    {
        $AccessSample = $DiagRecords | Where-Object { $_.Outcome -in @('Unauthorized', 'Forbidden') } | Select-Object -First 1
        $AccessFirstLine = if ([string]::IsNullOrWhiteSpace($AccessSample.Error)) { '(no error text captured)' } else { (([string]$AccessSample.Error) -split "`r?`n")[0].Trim() }
        if ($UnauthorizedCount -gt 0)
        {
            $AuthMsg = ("{0} metric call(s) were rejected with 401 Unauthorized: the access token was expired or invalid, so no metric could be collected with it. Re-authenticate (Connect-AzAccount) and re-run; -Resume keeps what was collected. First error: {1}" -f $UnauthorizedCount, $AccessFirstLine)
            Write-MetricsDiag ("ACCESS FAILURE: " + $AuthMsg)
            Write-Log -Message ("[Metrics] " + $AuthMsg) -Severity 'Warning'
        }
        if ($ForbiddenCount -gt 0)
        {
            $ForbMsg = ("{0} metric call(s) were rejected with 403 Forbidden: this identity lacks Monitoring Reader on those resources (see -Preflight). First error: {1}" -f $ForbiddenCount, $AccessFirstLine)
            Write-MetricsDiag ("ACCESS FAILURE: " + $ForbMsg)
            Write-Log -Message ("[Metrics] " + $ForbMsg) -Severity 'Warning'
        }
    }

    if (($NotFoundCount + $BadRequestCount) -gt 0)
    {
        Write-MetricsDiag ("Metrics not collected for these resources (permanent, not retried - no data was available to collect):")
        foreach ($rec in ($DiagRecords | Where-Object { $_.Outcome -in @('NotFound', 'BadRequest') } | Sort-Object Service, Name))
        {
            $FirstLine = if ([string]::IsNullOrWhiteSpace($rec.Error)) { '(no error text captured)' } else { (([string]$rec.Error) -split "`r?`n")[0].Trim() }

            $BodyNote = if ([string]::IsNullOrWhiteSpace($rec.ErrorBody)) { '' } else { (' | azure: ' + $rec.ErrorBody) }

            if ($rec.Outcome -eq 'NotFound')
            {
                Write-MetricsDiag ("  NotFound idx={0} {1}/{2}/{3} interval={4} aggregation={5} - Azure Monitor has no such resource; usually it was deleted between discovery and this call: {6}{7}" -f $rec.MetricIndex, $rec.Service, $rec.Name, $rec.Metric, $rec.Interval, $rec.Aggregation, $FirstLine, $BodyNote)
            }
            else
            {
                Write-MetricsDiag ("  BadRequest idx={0} {1}/{2}/{3} interval={4} aggregation={5} - Azure Monitor rejected this request; usually the metric is not valid for this resource, but check the interval and aggregation above are ones it supports: {6}{7}" -f $rec.MetricIndex, $rec.Service, $rec.Name, $rec.Metric, $rec.Interval, $rec.Aggregation, $FirstLine, $BodyNote)
            }
        }
    }

    if ($DiagRecords.Count -gt 0)
    {
        $Slowest = $DiagRecords | Sort-Object ElapsedSec -Descending | Select-Object -First 5
        Write-MetricsDiag ("Slowest 5 calls:")
        foreach ($rec in $Slowest)
        {
            Write-MetricsDiag ("  {0}s idx={1} {2}/{3}/{4} interval={5} ({6})" -f $rec.ElapsedSec, $rec.MetricIndex, $rec.Service, $rec.Name, $rec.Metric, $rec.Interval, $rec.Outcome)
        }
    }

    $WarningPreference = "Continue"

    $MetricDefs = $null;
}

