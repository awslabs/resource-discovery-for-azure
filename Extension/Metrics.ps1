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
    [switch]$UseMetricsBatch,
    # Set by ResourceInventory.ps1 under the wrappers (-RunAllSubs): keep the worker pool open in
    # $Global:MetricCallPool for the next subscription in this process instead of releasing it.
    [switch]$ReuseWorkerPool
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

    function Get-RdaMetricsSubscriptionProfile
    {
        # One profile lookup per subscription for the whole phase, shared by the provider check, every batch
        # service and the per-call map. A lookup costs two Get-AzSubscription calls, and a failing one is the
        # expensive kind, because its second call lists every tenant, so a failure is kept as well, as its
        # error, and thrown again to the next caller rather than retried. Each caller still reports the
        # failure in its own words. The phase creates $script:MetricsSubProfileCache before its first lookup,
        # so nothing found for one subscription of a wrapper run survives into the next. The keys are lower
        # case because the same subscription can arrive written two ways.
        param([Parameter(Mandatory = $true)][string]$SubscriptionId)

        $CacheKey = $SubscriptionId.ToLowerInvariant()
        if (-not $script:MetricsSubProfileCache.ContainsKey($CacheKey))
        {
            try
            {
                $script:MetricsSubProfileCache[$CacheKey] = [pscustomobject]@{ Profile = (Get-RdaSubscriptionProfile -SubscriptionId $SubscriptionId); Failure = $null }
            }
            catch
            {
                $script:MetricsSubProfileCache[$CacheKey] = [pscustomobject]@{ Profile = $null; Failure = $_ }
            }
        }
        $Cached = $script:MetricsSubProfileCache[$CacheKey]
        if ($null -ne $Cached.Failure)
        {
            throw $Cached.Failure
        }
        return $Cached.Profile
    }

    function Invoke-RdaMetricsBatch
    {
        param($Defs, $MetricNamespace)

        $Results = [System.Collections.Generic.List[object]]::new()
        $script:MetricsBatchLastError = $null
        if (-not $Defs -or @($Defs).Count -eq 0) { return $Results.ToArray() }

        $Groups = $Defs | Group-Object -Property { (([string]$_.Id) -split '/')[2] + '|' + $_.Location + '|' + $_.Interval + '|' + $_.StartTime + '|' + $_.EndTime }
        # The groups are keyed on region and time window as well as subscription, so one subscription usually
        # has several. Every one of them takes its profile from the phase's lookup cache
        # (Get-RdaMetricsSubscriptionProfile), which the provider check, the other batch services and the
        # per-call map share, so a subscription costs one lookup in the phase, a failing one included.
        foreach ($Group in $Groups)
        {
            # One failing group, or one failing chunk inside it, used to throw out of this function, and
            # the caller then sent every definition of the service to the per-call path: one bad region
            # turned thousands of batched definitions into thousands of Get-AzMetric calls. What has
            # already been fetched is kept instead, the failure is logged with the subscription, the
            # region and the chunk it covered, and the caller sends on only what is genuinely missing.
            $First = $Group.Group[0]
            $SubscriptionId = (([string]$First.Id) -split '/')[2]
            $Region = $First.Location
            if ([string]::IsNullOrEmpty($SubscriptionId) -or [string]::IsNullOrEmpty($Region))
            {
                $script:MetricsBatchLastError = ("cannot derive subscription/region from id '{0}'" -f $First.Id)
                Write-MetricsDiag ("WARNING: metrics batch group skipped: {0}. Its {1} metric def(s) fall back to per-call." -f $script:MetricsBatchLastError, @($Group.Group).Count)
                continue
            }

            # The token has to be minted for the subscription's own tenant. Without a profile
            # Get-AzAccessToken mints it for the process's current tenant, and a subscription homed
            # in another tenant - a standalone run with no -TenantID - then sent getBatch a token the
            # metrics data plane rejects. Get-RdaSubscriptionProfile returns the scoped context
            # container that -DefaultProfile takes, with the subscription's tenant already swapped in,
            # and throws when the subscription is not visible.
            $SubProfile = $null
            $SubProfileFailed = $false
            $SubProfileError = $null
            try
            {
                $SubProfile = Get-RdaMetricsSubscriptionProfile -SubscriptionId $SubscriptionId
            }
            catch
            {
                $SubProfileFailed = $true
                $SubProfileError = $_.Exception.Message
            }
            if ($SubProfileFailed)
            {
                # Every group of this subscription still reports its own fallback, because each one is a
                # distinct set of definitions leaving the batch; only the lookup is not repeated.
                $script:MetricsBatchLastError = $SubProfileError
                Write-MetricsDiag ("WARNING: metrics batch group skipped for subscription {0} region {1} ({2}). Its {3} metric def(s) fall back to per-call." -f $SubscriptionId, $Region, $script:MetricsBatchLastError, @($Group.Group).Count)
                continue
            }

            try
            {
                $Endpoint = "https://$Region.metrics.monitor.azure.com"
                $MetricNames = @($Group.Group | Select-Object -ExpandProperty MetricName -Unique)
                $Aggregations = @($Group.Group | Select-Object -ExpandProperty Aggregation -Unique | ForEach-Object { ([string]$_).ToLowerInvariant() })
                $StartIso = ([datetime]$First.StartTime).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [cultureinfo]::InvariantCulture)
                $EndIso = ([datetime]$First.EndTime).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [cultureinfo]::InvariantCulture)
                $IntervalIso = [System.Xml.XmlConvert]::ToString([TimeSpan]$First.Interval)

                $TokenObj = Get-AzAccessToken -ResourceUrl 'https://metrics.monitor.azure.com' -DefaultProfile $SubProfile -WarningAction SilentlyContinue
                $BearerToken = if ($TokenObj.Token -is [securestring]) { [System.Net.NetworkCredential]::new('', $TokenObj.Token).Password } else { [string]$TokenObj.Token }

                $NamesParam = (($MetricNames | ForEach-Object { [uri]::EscapeDataString($_) }) -join ',')
                $NsParam = [uri]::EscapeDataString($MetricNamespace)
                $AggParam = ($Aggregations -join ',')

                $ResourceIds = @($Group.Group | Select-Object -ExpandProperty Id -Unique)
                for ($Offset = 0; $Offset -lt $ResourceIds.Count; $Offset += 50)
                {
                    $ChunkEnd = [math]::Min($Offset + 49, $ResourceIds.Count - 1)
                    try
                    {
                        if ($null -ne $TokenObj.ExpiresOn -and $TokenObj.ExpiresOn -lt [DateTimeOffset]::UtcNow.AddMinutes(5))
                        {
                            $TokenObj = Get-AzAccessToken -ResourceUrl 'https://metrics.monitor.azure.com' -DefaultProfile $SubProfile -WarningAction SilentlyContinue
                            $BearerToken = if ($TokenObj.Token -is [securestring]) { [System.Net.NetworkCredential]::new('', $TokenObj.Token).Password } else { [string]$TokenObj.Token }
                        }

                        $Chunk = @($ResourceIds[$Offset..$ChunkEnd])
                        $Uri = "{0}/subscriptions/{1}/metrics:getBatch?api-version=2023-10-01&metricnamespace={2}&metricnames={3}&aggregation={4}&interval={5}&starttime={6}&endtime={7}" -f `
                            $Endpoint, $SubscriptionId, $NsParam, $NamesParam, $AggParam, $IntervalIso, $StartIso, $EndIso
                        $BodyJson = @{ resourceids = $Chunk } | ConvertTo-Json

                        # Counted before the POST, not after: the figure is the requests issued, so one that
                        # fails is counted too - even one that never reached Azure, such as a DNS or
                        # connection failure - and the total can slightly overstate what the metric-query
                        # meter bills. Counting only on success under-reported every failed run.
                        $script:MetricsBatchHttpCalls++
                        $Response = Invoke-RestMethod -Method Post -Uri $Uri -Headers @{ Authorization = "Bearer $BearerToken"; 'Content-Type' = 'application/json' } -Body $BodyJson -ErrorAction Stop

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
                    catch
                    {
                        $script:MetricsBatchLastError = $_.Exception.Message
                        Write-MetricsDiag ("WARNING: metrics batch chunk skipped for subscription {0} region {1}, resource {2}-{3} of {4} ({5}). Those metric def(s) fall back to per-call." -f $SubscriptionId, $Region, ($Offset + 1), ($ChunkEnd + 1), $ResourceIds.Count, $script:MetricsBatchLastError)
                    }
                }
            }
            catch
            {
                $script:MetricsBatchLastError = $_.Exception.Message
                Write-MetricsDiag ("WARNING: metrics batch group skipped for subscription {0} region {1} ({2}). Its {3} metric def(s) fall back to per-call." -f $SubscriptionId, $Region, $script:MetricsBatchLastError, @($Group.Group).Count)
            }
        }

        return $Results.ToArray()
    }

    function Initialize-RdaMetricsBatchPrereq
    {
        # Get-AzResourceProvider and Register-AzResourceProvider act on one subscription. Without a profile they use
        # the process's current one, which need not be the subscription being inventoried (no phase moves the
        # process context), so every call below passes that subscription's own profile.
        # The registration of every subscription that needs it is started first, and they are then polled against
        # ONE shared deadline with one sleep per round. N unregistered subscriptions therefore cost at most one
        # 60 second wait between them, not one each. The parameter is not called $SubscriptionId: Write-Log
        # tags every line with the $SubscriptionID it finds in its callers' scopes, and a list of ids under
        # that name, found before the caller's own, garbled the tag of every line written here.
        param([Parameter(Mandatory = $true)][string[]]$SubscriptionIds)

        $Pending = [System.Collections.Generic.List[object]]::new()
        foreach ($Sub in @($SubscriptionIds))
        {
            try
            {
                $SubProfile = Get-RdaMetricsSubscriptionProfile -SubscriptionId $Sub
                $Rp = Get-AzResourceProvider -ProviderNamespace 'Microsoft.Insights' -DefaultProfile $SubProfile -ErrorAction Stop | Select-Object -First 1
                if ($null -ne $Rp -and $Rp.RegistrationState -eq 'Registered')
                {
                    Write-MetricsDiag ("[batch] Microsoft.Insights resource provider already registered on subscription {0}." -f $Sub)
                    continue
                }

                Write-MetricsDiag ("[batch] Microsoft.Insights RP is '{0}' on subscription {1}; registering (required for metrics:getBatch)..." -f $(if ($Rp) { $Rp.RegistrationState } else { 'unknown' }), $Sub)
                Register-AzResourceProvider -ProviderNamespace 'Microsoft.Insights' -DefaultProfile $SubProfile -ErrorAction Stop | Out-Null
                $Pending.Add([pscustomobject]@{ SubscriptionId = $Sub; SubProfile = $SubProfile; State = '' })
            }
            catch
            {
                # Register-AzResourceProvider has no subscription parameter: it acts on whatever subscription the
                # admin's session points at, so the remediation has to name this one.
                Write-MetricsDiag ("[batch] could not ensure Microsoft.Insights registration on subscription {0} ({1}). If batch fails, an admin must register the provider on subscription {0}: select that subscription, then run Register-AzResourceProvider -ProviderNamespace Microsoft.Insights" -f $Sub, $_.Exception.Message)
            }
        }

        if ($Pending.Count -eq 0) { return }

        $Deadline = (Get-Date).AddSeconds(60)
        $Waiting = [System.Collections.Generic.List[object]]::new($Pending)
        while ($Waiting.Count -gt 0)
        {
            Start-Sleep -Seconds 10
            # Backwards, so removing a subscription that has finished does not disturb the indices still to visit.
            for ($Idx = $Waiting.Count - 1; $Idx -ge 0; $Idx--)
            {
                $Entry = $Waiting[$Idx]
                try
                {
                    $Entry.State = (Get-AzResourceProvider -ProviderNamespace 'Microsoft.Insights' -DefaultProfile $Entry.SubProfile -ErrorAction SilentlyContinue | Select-Object -First 1).RegistrationState
                }
                catch
                {
                    $Entry.State = ''
                }
                if ($Entry.State -eq 'Registered') { $Waiting.RemoveAt($Idx) }
            }
            if ((Get-Date) -ge $Deadline) { break }
        }

        foreach ($Entry in $Pending)
        {
            Write-MetricsDiag ("[batch] Microsoft.Insights registration state on subscription {0} after wait: {1}" -f $Entry.SubscriptionId, $Entry.State)
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
        # Hosting-plan SKU lookup: plan ARM id -> the plan's sku object. Built ONCE
        # from rows ALREADY in $Resources, in the same style as $SubLookup above, so
        # the per-app decision below is an O(1) hashtable hit and costs NO extra
        # Azure call. The startup Resource Graph query carries no type filter and
        # already projects 'sku', so every microsoft.web/serverfarms row arrives
        # alongside the sites. Keys are lowercased because a site's serverFarmId is
        # not guaranteed to match the plan row's id casing.
        $PlanSkuLookup = @{}
        foreach ($PlanRow in ($Resources | Where-Object { $_.TYPE -eq 'microsoft.web/serverfarms' }))
        {
            if ($null -ne $PlanRow -and ![string]::IsNullOrEmpty($PlanRow.id))
            {
                $PlanSkuLookup[$PlanRow.id.ToLower()] = $PlanRow.sku
            }
        }

        foreach ($app in $AppServices)
        {
            $Subscription = $SubLookup[$app.subscriptionId]

            # Do NOT narrow this on 'kind': a FlexConsumption (FC1) app and a working Linux Dedicated app
            # share the same kind and reserved values but need different metric sets. The hosting plan
            # SKU decides: that SKU discriminator is now IMPLEMENTED, via $PlanSkuLookup above.
            if ($app.kind -match 'functionapp')
            {
                $PlanSku = $null
                $FarmId = $app.properties.serverFarmId
                if (![string]::IsNullOrEmpty($FarmId))
                {
                    $PlanSku = $PlanSkuLookup[$FarmId.ToLower()]
                }
                # "Resolved" means a plan row was found AND it actually carried a SKU
                # marker. A found-but-empty sku is treated as unresolved, not as
                # "definitely not Flex" - see the fallback note below.
                $PlanResolved = $null -ne $PlanSku -and (![string]::IsNullOrEmpty($PlanSku.name) -or ![string]::IsNullOrEmpty($PlanSku.tier))
                $IsFlexConsumption = $PlanResolved -and ($PlanSku.name -eq 'FC1' -or $PlanSku.tier -eq 'FlexConsumption')

                # FALLBACK, stated explicitly: when the plan CANNOT be resolved we
                # enqueue BOTH sets. Resource Graph is a change-fed cached snapshot,
                # not a live read, so a site can arrive before its plan or with a null
                # sku. Guessing "not Flex" there would silently lose a real Flex app's
                # only execution metrics, and guessing "Flex" would lose a working
                # app's. Asking for both costs a handful of already-non-retried
                # BadRequests for that one app and matches today's behaviour for the
                # legacy pair, but can never drop a metric that would have returned
                # data. Never treat a missing plan or missing SKU as "this is not Flex".
                if (-not $IsFlexConsumption)
                {
                    $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'FunctionExecutionCount'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = '1.00:00:00'; Aggregation = 'Total'; Measure = 'Sum'; Id = $app.Id; SubName = $Subscription.Name; ResourceGroup = $app.ResourceGroup; Name = $app.Name; Location = $app.Location; Service = 'Functions'; Series = 'false' })
                    $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'FunctionExecutionUnits'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = '1.00:00:00'; Aggregation = 'Total'; Measure = 'Sum'; Id = $app.Id; SubName = $Subscription.Name; ResourceGroup = $app.ResourceGroup; Name = $app.Name; Location = $app.Location; Service = 'Functions'; Series = 'false' })
                }

                # Aggregation/Measure deliberately match the legacy pair ('Total'/'Sum'):
                # all five names reported primaryAggregationType = Total, unit = Count,
                # and Total among their supported aggregations, so they are the same
                # kind of figure (an execution count / execution units total) and stay
                # directly comparable with the legacy pair downstream.
                #
                # AlwaysReadyUnits is the FIFTH Flex-only billing name. It measures the
                # always-ready baseline resource consumption an app is charged for even
                # while idle, which none of the four execution names capture, so omitting
                # it loses a billing dimension rather than duplicating one. Measured on a
                # live FC1/FlexConsumption app: primaryAggregationType = Total,
                # unit = Count, 30 daily buckets returned; absent on Y1/Dynamic.
                if ($IsFlexConsumption -or -not $PlanResolved)
                {
                    $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'AlwaysReadyFunctionExecutionCount'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = '1.00:00:00'; Aggregation = 'Total'; Measure = 'Sum'; Id = $app.Id; SubName = $Subscription.Name; ResourceGroup = $app.ResourceGroup; Name = $app.Name; Location = $app.Location; Service = 'Functions'; Series = 'false' })
                    $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'OnDemandFunctionExecutionCount'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = '1.00:00:00'; Aggregation = 'Total'; Measure = 'Sum'; Id = $app.Id; SubName = $Subscription.Name; ResourceGroup = $app.ResourceGroup; Name = $app.Name; Location = $app.Location; Service = 'Functions'; Series = 'false' })
                    $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'AlwaysReadyFunctionExecutionUnits'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = '1.00:00:00'; Aggregation = 'Total'; Measure = 'Sum'; Id = $app.Id; SubName = $Subscription.Name; ResourceGroup = $app.ResourceGroup; Name = $app.Name; Location = $app.Location; Service = 'Functions'; Series = 'false' })
                    $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'OnDemandFunctionExecutionUnits'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = '1.00:00:00'; Aggregation = 'Total'; Measure = 'Sum'; Id = $app.Id; SubName = $Subscription.Name; ResourceGroup = $app.ResourceGroup; Name = $app.Name; Location = $app.Location; Service = 'Functions'; Series = 'false' })
                    $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'AlwaysReadyUnits'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = '1.00:00:00'; Aggregation = 'Total'; Measure = 'Sum'; Id = $app.Id; SubName = $Subscription.Name; ResourceGroup = $app.ResourceGroup; Name = $app.Name; Location = $app.Location; Service = 'Functions'; Series = 'false' })
                }
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
    # The service's own message for the last group or chunk the batch had to skip. Read by the call site
    # below, which is the one place that knows how many definitions ended up on the per-call path.
    $script:MetricsBatchLastError = $null
    # One profile lookup per subscription for the whole phase, shared by the provider check, every batch
    # service and the per-call map (Get-RdaMetricsSubscriptionProfile). Created here, before the first
    # lookup, so nothing found for one subscription of a wrapper run survives into the next.
    $script:MetricsSubProfileCache = @{}

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
            # The provider is per subscription, and the definitions can span several of them, so every one that
            # has something to batch is passed in together: the registrations all start before any of them is
            # waited for. The id's subscription segment is lower-cased so the same subscription written two ways
            # is checked once.
            $BatchSubscriptionIds = @($BatchGroups.Values | ForEach-Object { $_ } | ForEach-Object { (([string]$_.Id) -split '/')[2] } | Where-Object { -not [string]::IsNullOrEmpty($_) } | ForEach-Object { $_.ToLowerInvariant() } | Select-Object -Unique)
            if ($BatchSubscriptionIds.Count -gt 0)
            {
                Initialize-RdaMetricsBatchPrereq -SubscriptionIds $BatchSubscriptionIds
            }

            foreach ($Service in $BatchGroups.Keys)
            {
                $ServiceDefs = $BatchGroups[$Service]
                $Namespace = $BatchNamespaceMap[$Service]
                $BatchObjects = @()
                $BatchErr = $null
                try
                {
                    $BatchObjects = @(Invoke-RdaMetricsBatch -Defs $ServiceDefs -MetricNamespace $Namespace)
                }
                catch
                {
                    $BatchErr = $_.Exception.Message
                }
                if ([string]::IsNullOrEmpty($BatchErr)) { $BatchErr = $script:MetricsBatchLastError }

                # Whatever came back is kept, and only the definitions it did not cover go to the per-call
                # path. A failed region or chunk inside the batch therefore costs the definitions it
                # covered, not every definition of the service.
                $SatisfiedKeys = @{}
                foreach ($BatchObj in $BatchObjects)
                {
                    $SatisfiedKeys[('{0}|{1}' -f ([string]$BatchObj.ID).ToLower(), $BatchObj.Metric)] = $true
                }
                $FellBack = 0
                foreach ($Def in $ServiceDefs)
                {
                    if (-not $SatisfiedKeys.ContainsKey(('{0}|{1}' -f ([string]$Def.Id).ToLower(), $Def.MetricName)))
                    {
                        $RemainingDefs.Add($Def)
                        $FellBack++
                    }
                }

                foreach ($BatchObj in $BatchObjects) { $Tmp.Metrics.Add($BatchObj) }
                if ($BatchObjects.Count -gt 0)
                {
                    Write-MetricsDiag ("Metrics batch fast-path: fetched {0} {1} metric record(s) via getBatch." -f $BatchObjects.Count, $Service)
                }
                if ($FellBack -gt 0)
                {
                    $BatchErrText = if ([string]::IsNullOrEmpty($BatchErr)) { 'getBatch returned no record for them' } else { $BatchErr }
                    $Hint = if ($BatchErrText -match '(?i)403|AuthorizationFailed|does not have access|does not have authorization')
                    {
                        'the signed-in identity lacks subscription-level read for the metrics data plane - assign Reader or Monitoring Reader at the subscription scope, and ensure Microsoft.Insights is registered'
                    }
                    else
                    {
                        'ensure Microsoft.Insights is registered and the region/resources are reachable'
                    }
                    Write-MetricsDiag ("WARNING: metrics batch fast-path failed for {0} of {1} {2} metric def(s) ({3}). {4}. Those metrics fall back to per-call (no data lost)." -f $FellBack, @($ServiceDefs).Count, $Service, $BatchErrText, $Hint)
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

    # Get-AzMetric's -DefaultProfile is typed IAzureContextContainer, and Get-AzContext returns a
    # PSAzureContext. Left as-is, every pool worker converts it at parameter binding through the
    # type converter Az.Accounts registers in that worker's own runspace, and that conversion
    # intermittently fails ('Cannot convert PSAzureContext to IAzureContextContainer') once the
    # process has seen many Az runspaces. Convert once here, in the main session, so the workers
    # receive an object that already has the parameter's type and bind it without any conversion.
    # If the conversion is unavailable or fails, keep the raw context: that is the previous behaviour.
    if ($null -ne $MetricAzContext)
    {
        $ContextContainerType = 'Microsoft.Azure.Commands.Common.Authentication.Abstractions.Core.IAzureContextContainer' -as [type]
        if ($null -eq $ContextContainerType)
        {
            Write-MetricsDiag "WARNING: the Az context container type was not found; metric calls pass the raw Az context and convert it per call."
        }
        else
        {
            try
            {
                $MetricAzContext = [System.Management.Automation.LanguagePrimitives]::ConvertTo($MetricAzContext, $ContextContainerType)
            }
            catch
            {
                Write-MetricsDiag ("WARNING: could not convert the Az context for the metric workers ({0}); metric calls pass the raw Az context and convert it per call." -f $_.Exception.Message)
            }
        }
    }

    $MetricTimeoutSeconds = 120
    # How long the phase end waits for every pool worker to finish before deciding whether the pool
    # can be released. An idle pool passes at once; only a call still blocked in a network read waits.
    $MetricPoolReleaseGraceSeconds = 10
    # How long to wait before the one retry of a pool open that failed. The phase already gives its
    # workers this long before it decides about releasing a pool, and the wait is paid only after a
    # failure, so a host with memory to spare never meets it.
    $MetricPoolOpenRetryDelaySeconds = 10
    $MetricMaxRetries = 3
    $MetricMaxThrottleRetries = 6
    $MetricMaxRetryAfterSeconds = 120
    $MetricRetryAfterFnDef = if (Get-Command Get-RdaRetryAfterSeconds -CommandType Function -ErrorAction SilentlyContinue) { ${function:Get-RdaRetryAfterSeconds}.ToString() } else { $null }

    $MetricDiagnostics = [System.Collections.Concurrent.ConcurrentBag[psobject]]::new()

    # Every Get-AzMetric attempt runs on this one runspace pool. A pool runspace is reused
    # across calls, so Az.Accounts and Az.Monitor load once per runspace rather than once per
    # attempt, and no call waits behind the process-wide Start-ThreadJob throttle (5 by default).
    # Runspaces are created on demand; the headroom above ConcurrencyLimit is for timed-out
    # calls that are abandoned while they still hold one. Each of the ConcurrencyLimit parallel
    # slots can abandon one call per attempt, so the ceiling is (MaxRetries + 1) per slot: a flat
    # doubling saturates after two timed-out rounds, and once the pool is full BeginInvoke queues
    # while the per-call clock is already running, so a call that never reached Azure is recorded
    # as a timeout and still counted as an API call issued.
    $MetricCallPool = $null
    $MetricPerCallPoolFailed = $false
    $MetricAbandonedCalls = [System.Collections.Concurrent.ConcurrentBag[psobject]]::new()
    if ($MetricCount -gt 0)
    {
        # Under the wrappers one pool serves every subscription in the process. A runspace that loads
        # the Az modules leaves its type table behind in PowerShell's process-wide member-lookup cache
        # (up to about 128 of them, roughly 0.8 MB each), so a new pool per subscription adds about six
        # to that cache every time. Reusing the pool loads Az once per worker for the whole run. Only an
        # open pool is reused; one left in any other state is dropped and a fresh one is built.
        if ($ReuseWorkerPool -and $null -ne $Global:MetricCallPool -and $Global:MetricCallPool.RunspacePoolStateInfo.State -eq [System.Management.Automation.Runspaces.RunspacePoolState]::Opened)
        {
            $MetricCallPool = $Global:MetricCallPool
            [void]$MetricCallPool.SetMaxRunspaces([math]::Max(1, [int]$ConcurrencyLimit) * ([math]::Max(1, [int]$MetricMaxRetries) + 1))
            Write-MetricsDiag "Metric worker pool reused from the previous subscription in this process."
        }
        else
        {
            # A pool open that fails for want of memory can succeed a moment later, so it is tried
            # once more: the broken pool is disposed first, this process compacts its heap, and the
            # wait gives whatever else on the host held that memory time to let go of it. The retry
            # builds a fresh pool of the SAME size, because Open() allocates runspaces on demand and
            # a smaller maximum only brings back calls that time out while queued. The loop carries
            # the decision rather than a break or a continue: the open try is lifted on its own by
            # the tests, and outside a loop either jump unwinds into whatever loop the caller runs.
            # A pool kept for the next subscription is reused only when it is Opened, so one found here
            # in the global is in a state it cannot serve. It is released before the new pool is built,
            # whatever the open then does: a successful open would otherwise overwrite the global and
            # leave it neither disposed - which is the only thing that removes its cleanup timer and
            # releases the runspaces holding the Az modules - nor reachable by the closer at wrapper
            # exit, and a failed open would hold its memory through both attempts and the wait that is
            # meant to free memory. The reuse guard above already treats a pool in any other state as
            # unexpected, so this says so rather than passing over it quietly.
            if ($ReuseWorkerPool -and $null -ne $Global:MetricCallPool -and $Global:MetricCallPool.RunspacePoolStateInfo.State -ne [System.Management.Automation.Runspaces.RunspacePoolState]::Opened)
            {
                Write-MetricsDiag ('Releasing the metric worker pool left from an earlier subscription in state {0}; it can serve no call.' -f $Global:MetricCallPool.RunspacePoolStateInfo.State)
                try
                {
                    $Global:MetricCallPool.Dispose()
                }
                catch
                {
                    Write-MetricsDiag ("Pool teardown reported: {0}" -f $_.Exception.Message)
                }
                $Global:MetricCallPool = $null
            }
            $MetricPoolOpenRetriesLeft = 1
            $MetricPoolOpenPending = $true
            while ($MetricPoolOpenPending)
            {
                $MetricPoolOpenPending = $false
                $MetricCallPool = [runspacefactory]::CreateRunspacePool([initialsessionstate]::CreateDefault2())
                [void]$MetricCallPool.SetMaxRunspaces([math]::Max(1, [int]$ConcurrencyLimit) * ([math]::Max(1, [int]$MetricMaxRetries) + 1))
                # Open() is the only step here that can fail, and the pool it leaves behind is Broken: it has
                # already registered its process-wide cleanup timer, so it has to be disposed, and it can serve
                # no call, so it is never stored for the next subscription. Without this the failure either
                # throws out of the phase under -ErrorAction Stop and leaks that pool, or is swallowed under the
                # default preference and every worker then fails on its own at BeginInvoke. Only the per-call
                # collection of this subscription is given up: the batch records already written and the rest of
                # the inventory are untouched, and the subscription is named in the wrapper's run summary.
                try
                {
                    $MetricCallPool.Open()
                    if ($ReuseWorkerPool)
                    {
                        $Global:MetricCallPool = $MetricCallPool
                    }
                    if ($MetricPoolOpenRetriesLeft -eq 0)
                    {
                        Write-MetricsDiag 'Metric worker pool opened on the second attempt.'
                        Write-Log -Message 'Metrics: the metric worker pool opened on the second attempt, after compacting memory and waiting. The per-call metric collection of this subscription continues.' -Severity 'Info'
                    }
                }
                catch
                {
                    $PoolOpenError = $_.Exception.Message
                    try
                    {
                        $MetricCallPool.Dispose()
                    }
                    catch
                    {
                        Write-MetricsDiag ("Pool teardown reported: {0}" -f $_.Exception.Message)
                    }
                    $MetricCallPool = $null
                    if ($MetricPoolOpenRetriesLeft -gt 0)
                    {
                        # Nothing is given up yet, so no health entry, no Error line and nothing in the
                        # global: this failure is only reported if the retry fails too. $Resources and
                        # $MetricDefs are still needed, so the broken pool is all there is to release.
                        $MetricPoolOpenRetriesLeft--
                        $PoolRetryMsg = ('Metrics: the metric worker pool could not be opened ({0}). Compacting memory and retrying once in {1}s with the same pool size.' -f $PoolOpenError, $MetricPoolOpenRetryDelaySeconds)
                        Write-MetricsDiag ('WARNING: ' + $PoolRetryMsg)
                        Write-Log -Message $PoolRetryMsg -Severity 'Warning'
                        # Compact, drain the finalizers, take what they released, and only then read: the
                        # same four steps ResourceInventory.ps1 runs around a consumption page that ran out
                        # of memory. A long-lived session never compacts the large object heap on its own,
                        # so a plain collect can leave it too fragmented for the next pool. The reading goes
                        # last, so the debug line reports what the retry actually freed rather than what the
                        # process held before it; -Compact would collect again and read inside that collect.
                        [System.Runtime.GCSettings]::LargeObjectHeapCompactionMode = [System.Runtime.GCLargeObjectHeapCompactionMode]::CompactOnce
                        [System.GC]::Collect([System.GC]::MaxGeneration, [System.GCCollectionMode]::Forced, $true, $true)
                        [System.GC]::WaitForPendingFinalizers()
                        [System.GC]::Collect()
                        Write-RdaMemorySnapshot -Phase 'Metric worker pool open failed'
                        Start-Sleep -Seconds $MetricPoolOpenRetryDelaySeconds
                        $MetricPoolOpenPending = $true
                    }
                    else
                    {
                        $PoolSkipMsg = ('Metrics: the metric worker pool could not be opened ({0}); {1} per-call metric definition(s) were not collected.' -f $PoolOpenError, $MetricCount)
                        Write-MetricsDiag ('ERROR: ' + $PoolSkipMsg + ' The rest of the inventory continues.')
                        # The subscription still finishes its inventory, but the wrapper keeps it in the retry list
                        # instead of the completed list, so both resume modes collect it again. A standalone run has
                        # no resume state, so its only remedy is to run the same command again.
                        $PoolRemedy = if ($ReuseWorkerPool)
                        {
                            'To collect the missing metrics, free memory on this host or use a lower -ConcurrencyLimit, then re-run with -Resume or -ResumeFailedOnly, which collects every subscription listed as metrics incomplete again.'
                        }
                        else
                        {
                            'To collect the missing metrics, free memory on this host or use a lower -ConcurrencyLimit, then run the same ResourceInventory.ps1 command again in a new PowerShell 7 session and use its report instead of this one.'
                        }
                        Write-Log -Message ($PoolSkipMsg + ' The rest of the inventory continues. ' + $PoolRemedy) -Severity 'Error'
                        if ($null -eq $Global:MetricsFailedSubs) { $Global:MetricsFailedSubs = @() }
                        # One entry per subscription that had definitions on the per-call path, each carrying its
                        # OWN count. A standalone run's phase can cover several subscriptions, so an entry that
                        # repeated the phase total would tell each of them that every definition of the run was
                        # its own. The ids are lower-cased so the same subscription written two ways is one entry,
                        # and the first-appearance order is kept for the summary. Cause 'pool' keeps the wrapper from
                        # reporting this as an auth skip: the remedy is memory on the host, not Connect-AzAccount.
                        $PoolFailedSubIds = @($MetricDefs | ForEach-Object { (([string]$_.Id) -split '/')[2] } | Where-Object { -not [string]::IsNullOrEmpty($_) } | ForEach-Object { $_.ToLowerInvariant() })
                        $PoolFailedCounts = @{}
                        foreach ($PoolFailedSubId in $PoolFailedSubIds)
                        {
                            if (-not $PoolFailedCounts.ContainsKey($PoolFailedSubId)) { $PoolFailedCounts[$PoolFailedSubId] = 0 }
                            $PoolFailedCounts[$PoolFailedSubId]++
                        }
                        $PoolFailedUniqueIds = @($PoolFailedSubIds | Select-Object -Unique)
                        if ($PoolFailedUniqueIds.Count -eq 0)
                        {
                            $Global:MetricsFailedSubs += [pscustomobject]@{ Name = '(subscription)'; Id = '(unknown)'; Message = $PoolSkipMsg; Cause = 'pool' }
                        }
                        else
                        {
                            foreach ($PoolFailedSubId in $PoolFailedUniqueIds)
                            {
                                $PoolFailedSub = $SubLookup[$PoolFailedSubId]
                                $PoolFailedSubName = if ($null -ne $PoolFailedSub -and ![string]::IsNullOrEmpty($PoolFailedSub.Name)) { $PoolFailedSub.Name } else { '(subscription)' }
                                $Global:MetricsFailedSubs += [pscustomobject]@{
                                    Name    = $PoolFailedSubName
                                    Id      = $PoolFailedSubId
                                    Message = ('Metrics: the metric worker pool could not be opened ({0}); {1} per-call metric definition(s) of this subscription were not collected.' -f $PoolOpenError, $PoolFailedCounts[$PoolFailedSubId])
                                    Cause   = 'pool'
                                }
                            }
                        }
                        # Nothing in this phase repairs the pool, so the per-call loop is skipped rather than run
                        # against a pool that is gone. The counts below then report what was really collected.
                        $MetricCount = 0
                        $MetricPerCallPoolFailed = $true
                    }
                }
            }
        }
    }

    $MetricAbandonedCount = 0
    $MetricAbandonedRunning = 0
    # Counted here and not from the bag: the per-batch drain takes a returned call OFF the bag, so
    # the bag's size at phase end is what is still outstanding, not how many were ever abandoned.
    $MetricAbandonedDrained = 0

    $PhaseStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    # Only a run that has something to collect per call announces a collection. A pool that could not be
    # opened sets $MetricCount to 0, and "Starting metrics collection: 0 metric definition(s)" would read
    # as a clean no-op rather than as the skip the ERROR line above reports.
    if ($MetricCount -gt 0)
    {
        Write-MetricsDiag ("Starting metrics collection: {0} metric definition(s), ThrottleLimit={1}, per-call timeout={2}s, max retries={3}, throttle retries={5} (honours Retry-After up to {6}s), lookback={4} day(s)." -f $MetricCount, $ConcurrencyLimit, $MetricTimeoutSeconds, $MetricMaxRetries, [math]::Abs($MetricsLookbackPeriodDays), $MetricMaxThrottleRetries, $MetricMaxRetryAfterSeconds)
    }
    elseif ($MetricPerCallPoolFailed)
    {
        Write-MetricsDiag "Per-call metrics collection skipped: the metric worker pool could not be opened, as the ERROR above reports."
    }
    else
    {
        Write-MetricsDiag "Per-call metrics collection has nothing to do: no metric definition is left on the per-call path."
    }

    $RangeBatch = [math]::Min($MetricCount , 250)
    $RangeIdx = 1
    $MetricsProcessed = 0
    $Defs = [System.Collections.Generic.List[object]]::new()

    # Released in the finally below rather than on the way out. This phase can end on a throw - a
    # write failure under -Debug, a pipeline stop, or the out-of-memory error this pooling exists
    # to make less likely - and Run-AllSubscriptions.ps1 catches a failed subscription and carries
    # on in the SAME process, so a pool released only on the normal path would leave one open pool
    # per failed subscription: exactly when memory is already short, and the opposite of the point.
    # The per-subscription profile map is built inside this try as well: its lookups are the first slow
    # step after the pool opens, and a stop during them would otherwise leave the opened pool, and its
    # cleanup timer, in a standalone session.
    try
    {
        # Per-subscription profiles for the per-call path, built after the pool so a pool that could not be
        # opened costs no lookup. The context captured above is the process's own, so a subscription homed
        # in another tenant would have every one of its Get-AzMetric calls carry a token for the wrong
        # tenant - the same defect the batch token had, on the path the batch falls back to. Reachable in a
        # standalone ResourceInventory.ps1 run without -TenantID, where $Global:Subscriptions can span
        # tenants; under the wrappers a run is scoped to one tenant and this map holds one entry. Built once
        # for the distinct subscriptions of $MetricDefs, through the phase's lookup cache
        # (Get-RdaMetricsSubscriptionProfile), so a subscription the provider check or the batch already
        # looked up costs nothing more, and any other costs one lookup, not one per call. The lookup returns
        # the IAzureContextContainer that -DefaultProfile takes, so nothing is converted here. A
        # subscription whose profile cannot be built is logged and keeps the phase context, which is what
        # every per-call query used before. The map is only read after it is built, so the worker
        # runspaces share it safely.
        $MetricSubProfiles = @{}
        if ($MetricCount -gt 0)
        {
            $MetricProfileSubIds = @($MetricDefs | ForEach-Object { (([string]$_.Id) -split '/')[2] } | Where-Object { -not [string]::IsNullOrEmpty($_) } | ForEach-Object { $_.ToLowerInvariant() } | Select-Object -Unique)
            foreach ($MetricProfileSubId in $MetricProfileSubIds)
            {
                try
                {
                    $MetricSubProfiles[$MetricProfileSubId] = Get-RdaMetricsSubscriptionProfile -SubscriptionId $MetricProfileSubId
                }
                catch
                {
                    Write-MetricsDiag ("WARNING: could not scope the metric calls of subscription {0} to its own tenant ({1}); they use the process context, as every call did before." -f $MetricProfileSubId, $_.Exception.Message)
                }
            }
        }

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
                    $SubProfiles = $using:MetricSubProfiles
                    $CallTimeoutSeconds = $using:MetricTimeoutSeconds
                    $CallMaxRetries = $using:MetricMaxRetries
                    $CallMaxThrottleRetries = $using:MetricMaxThrottleRetries
                    $CallMaxRetryAfterSeconds = $using:MetricMaxRetryAfterSeconds
                    $RetryAfterFnDef = $using:MetricRetryAfterFnDef
                    if ($RetryAfterFnDef) { Set-Item -Path function:Get-RdaRetryAfterSeconds -Value ([scriptblock]::Create($RetryAfterFnDef)) }
                    $DiagBag = $using:MetricDiagnostics
                    $CallPool = $using:MetricCallPool
                    $AbandonedCalls = $using:MetricAbandonedCalls

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

                    function Get-RdaMetricCallProfile
                    {
                        # Which profile this one query is given: the one built for the subscription the
                        # resource lives in, so a subscription homed in another tenant is queried with a
                        # token for its own tenant. Falls back to the phase context when the map carries
                        # no profile for it, which is what every per-call query used before.
                        param([string]$ResourceId, $SubProfiles, $PhaseProfile)

                        $CallSubId = (([string]$ResourceId) -split '/')[2]
                        if (-not [string]::IsNullOrEmpty($CallSubId) -and $null -ne $SubProfiles)
                        {
                            $Mapped = $SubProfiles[$CallSubId.ToLowerInvariant()]
                            if ($null -ne $Mapped) { return $Mapped }
                        }
                        return $PhaseProfile
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

                    function Wait-RdaMetricCall
                    {
                        param($Handle, [int]$TimeoutSeconds)

                        # Short slices keep the wait responsive to a pipeline stop such as Ctrl+C.
                        $Clock = [System.Diagnostics.Stopwatch]::StartNew()
                        while (-not $Handle.IsCompleted)
                        {
                            $RemainingMs = ($TimeoutSeconds * 1000) - $Clock.ElapsedMilliseconds
                            if ($RemainingMs -le 0) { return $false }
                            [void]$Handle.AsyncWaitHandle.WaitOne([int][math]::Min($RemainingMs, 500))
                        }
                        return $true
                    }

                    function Receive-RdaMetricCall
                    {
                        param($Call, $Handle)

                        try
                        {
                            $Output = $Call.EndInvoke($Handle)
                        }
                        catch
                        {
                            # EndInvoke wraps the failure in a MethodInvocationException. Rethrow the
                            # record Get-AzMetric raised instead, so the classifier, the error-body reader
                            # and the Retry-After reader see Azure's exception and its response.
                            $Inner = $_.Exception.InnerException
                            if ($Inner -is [System.Management.Automation.IContainsErrorRecord] -and $null -ne $Inner.ErrorRecord)
                            {
                                throw $Inner.ErrorRecord
                            }
                            throw
                        }
                        # EndInvoke only throws when the call itself terminated. A cmdlet that WROTE an
                        # error and produced nothing leaves it in the error stream, and returning empty
                        # here would be recorded as a successful call with a metric value of 0 - a silent
                        # zero in the %TimeOn denominator. Surface it so the classifier sees it, matching
                        # what 'Receive-Job -ErrorAction Stop' did before the pool.
                        if ($Call.HadErrors -and @($Output).Count -eq 0 -and $Call.Streams.Error.Count -gt 0)
                        {
                            throw $Call.Streams.Error[0]
                        }
                        foreach ($Item in $Output) { $Item }
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
                    $CallProfile = Get-RdaMetricCallProfile -ResourceId $_.Id -SubProfiles $SubProfiles -PhaseProfile $AzContext
                    if ($null -ne $CallProfile)
                    {
                        $MetricArgs['DefaultProfile'] = $CallProfile
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

                            $Call = [powershell]::Create()
                            $CallHandle = $null
                            try
                            {
                                $Call.RunspacePool = $CallPool
                                [void]$Call.AddCommand('Get-AzMetric').AddParameters($MetricArgs)
                                $CallHandle = $Call.BeginInvoke()
                            }
                            catch
                            {
                                # A broken or closed pool fails here, before the call is dispatched. Without
                                # this the [powershell] leaks and the exception escapes the retry loop, so
                                # this is the one failure that would skip the retry budget entirely.
                                $Call.Dispose()
                                $LastError = $_.Exception.Message
                                # Nothing in this phase repairs the pool, so a retry would re-bind to the same
                                # object and only spend the backoff. Bucketed as a local Error rather than by
                                # what the message happens to contain, so a pool fault whose text mentions 429
                                # or authentication cannot read as an Azure access failure to the operator.
                                $Permanent = $true
                                $PermanentOutcome = 'Error'
                            }

                            if ($null -eq $CallHandle) { }
                            elseif (Wait-RdaMetricCall -Handle $CallHandle -TimeoutSeconds $CallTimeoutSeconds)
                            {
                                try
                                {
                                    $MetricQuery = Receive-RdaMetricCall -Call $Call -Handle $CallHandle
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
                                    $Call.Dispose()
                                }
                            }
                            else
                            {
                                $TimedOut = $true
                                $LastError = ("Timed out after {0}s" -f $CallTimeoutSeconds)
                                # Stop without waiting. A call blocked in a network read only returns when
                                # the read does, so a synchronous stop would hold this runspace until then.
                                # The abandoned call keeps its pool runspace until it finishes.
                                [void]$Call.BeginStop($null, $null)
                                $AbandonedCalls.Add([PSCustomObject]@{ Call = $Call; Handle = $CallHandle })
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
                Write-Verbose ("[Metrics] Batch {0} complete in {1}s. Cumulative diagnostics: {2} call record(s) so far." -f $RangeIdx, ([math]::Round($BatchStopwatch.Elapsed.TotalSeconds, 1)).ToString('0.0', [cultureinfo]::InvariantCulture), $MetricDiagnostics.Count)

                if ($Obfuscate)
                {
                    Protect-RdaMetrics -Metrics $Tmp.Metrics -ResourceIdDictionary $ResourceIdDictionary -ResourceNameDictionary $ResourceNameDictionary -ResourceSubDictionary $ResourceSubDictionary -ResourceGroupDictionary $ResourceGroupDictionary
                }

                $OutputPath = $FilePath + "_" + $RangeIdx + ".json"
                $Tmp | ConvertTo-Json -depth 5 -compress | Out-File -LiteralPath $OutputPath -Encoding utf8
                $Tmp.Metrics.Clear()

                # Release the abandoned calls that have since returned. Draining only at phase end keeps
                # a call abandoned in an early batch - and whatever payload it later received - alive for
                # the rest of the phase, which is the retention this pooling exists to avoid.
                $StillRunning = [System.Collections.Generic.List[object]]::new()
                $Drained = $null
                try
                {
                    while ($MetricAbandonedCalls.TryTake([ref]$Drained)) { $StillRunning.Add($Drained) }
                    # Removed only once the dispose has actually returned, walking backwards so the removal
                    # does not disturb the indices still to be visited. Anything that throws stays on the
                    # list and goes back on the bag, so no call is dropped from the count or leaked.
                    for ($Idx = $StillRunning.Count - 1; $Idx -ge 0; $Idx--)
                    {
                        if ($StillRunning[$Idx].Handle.IsCompleted)
                        {
                            $StillRunning[$Idx].Call.Dispose()
                            $StillRunning.RemoveAt($Idx)
                            $MetricAbandonedDrained++
                        }
                    }
                }
                finally
                {
                    # Everything taken off the bag and not confirmed released goes back on it.
                    foreach ($Pending in $StillRunning) { $MetricAbandonedCalls.Add($Pending) }
                }

                $RangeIdx++
            }
        }
    }
    finally
    {
        # BeginClose, not Close: the latter waits for a call still blocked in a network read.
        $MetricAbandonedCount = $MetricAbandonedDrained + $MetricAbandonedCalls.Count
        if ($null -ne $MetricCallPool)
        {
            try
            {
                # Closed before the disposal walk, not after: closing the pool is what actually releases
                # the runspaces, and the walk below is best-effort bookkeeping. A throw in the walk must
                # not be what skips the close, or the per-subscription leak is back with the failure
                # swallowed by the catch below.
                # Before closing, give every worker a bounded chance to finish. The pool itself is the
                # authority on that: while it is open, every runspace is free exactly when
                # GetAvailableRunspaces equals GetMaxRunspaces. That also covers a call the batch loop
                # holds no handle to, such as one left in flight when a stop or a throw interrupted the
                # batch. Thread.Sleep rather than Start-Sleep, so the wait still runs while a pipeline
                # stop is unwinding through this finally.
                $PoolGraceClock = [System.Diagnostics.Stopwatch]::StartNew()
                $PoolIdle = $false
                $PoolBroken = $false
                $PoolCloseHandle = $null
                while ($true)
                {
                    # GetAvailableRunspaces is only valid on an open pool; a broken pool is never idle.
                    if ($MetricCallPool.RunspacePoolStateInfo.State -ne [System.Management.Automation.Runspaces.RunspacePoolState]::Opened)
                    {
                        $PoolIdle = $false
                        break
                    }
                    $PoolIdle = ($MetricCallPool.GetAvailableRunspaces() -eq $MetricCallPool.GetMaxRunspaces())
                    $AbandonedOutstanding = @($MetricAbandonedCalls | Where-Object { -not $_.Handle.IsCompleted }).Count
                    if (($PoolIdle -and $AbandonedOutstanding -eq 0) -or $PoolGraceClock.Elapsed.TotalSeconds -ge $MetricPoolReleaseGraceSeconds)
                    {
                        break
                    }
                    [System.Threading.Thread]::Sleep(100)
                }

                $PoolKept = ($ReuseWorkerPool -and $PoolIdle -and $AbandonedOutstanding -eq 0)
                if ($PoolKept)
                {
                    # Every worker has finished, so the pool stays open for the next subscription in this
                    # process. The wrappers release it once, at the end of the run
                    # (Close-RdaMetricWorkerPool).
                    Write-MetricsDiag ("Metric worker pool kept open for the next subscription: every worker had finished (waited {0} ms)." -f $PoolGraceClock.ElapsedMilliseconds)
                }
                else
                {
                    # A pool with a worker still busy is never handed to the next subscription: it is
                    # retired here and released only if the checks below prove every worker has ended.
                    if ($ReuseWorkerPool -and [object]::ReferenceEquals($Global:MetricCallPool, $MetricCallPool))
                    {
                        $Global:MetricCallPool = $null
                    }

                    # A broken pool cannot be closed and has no running call to protect, so it is not asked
                    # to close; it is disposed below, which is what removes its cleanup timer.
                    $PoolBroken = ($MetricCallPool.RunspacePoolStateInfo.State -eq [System.Management.Automation.Runspaces.RunspacePoolState]::Broken)
                    if (-not $PoolBroken)
                    {
                        $PoolCloseHandle = $MetricCallPool.BeginClose($null, $null)
                    }
                }
                foreach ($Abandoned in $MetricAbandonedCalls)
                {
                    if ($Abandoned.Handle.IsCompleted) { $Abandoned.Call.Dispose() } else { $MetricAbandonedRunning++ }
                }

                if (-not $PoolKept)
                {
                    # Closing alone is not enough: an opened pool registers a cleanup timer in the
                    # process-wide timer queue, and only Dispose removes it. Until then the timer keeps the
                    # pool reachable, and with it a runspace holding the Az modules and its last results, so
                    # every subscription under the wrapper added one to the heap for the life of the process.
                    # Dispose runs only once it is PROVEN that every worker has ended: the close has finished
                    # (it does not finish while any runspace still runs a call), the pool reports Closed, and
                    # no abandoned call is still running. A Broken pool is the one exception: it cannot be
                    # closed and has no call running, so it is disposed without a close. Otherwise the pool is
                    # kept and the debug log says so:
                    # that costs one pool of memory for this subscription, never a hang or a torn-down worker.
                    $PoolCloseRemainingMs = [int][math]::Max(0, ($MetricPoolReleaseGraceSeconds * 1000) - $PoolGraceClock.ElapsedMilliseconds)
                    $PoolClosed = $false
                    if ($PoolIdle -and $MetricAbandonedRunning -eq 0 -and $null -ne $PoolCloseHandle)
                    {
                        $PoolClosed = $PoolCloseHandle.AsyncWaitHandle.WaitOne($PoolCloseRemainingMs) -and $MetricCallPool.RunspacePoolStateInfo.State -eq [System.Management.Automation.Runspaces.RunspacePoolState]::Closed
                    }
                    elseif ($PoolBroken -and $MetricAbandonedRunning -eq 0)
                    {
                        # Same rule as Close-RdaMetricWorkerPool: a Broken pool has no worker left to protect
                        # and cannot be closed, so it goes straight to Dispose. The abandoned count is still
                        # checked here rather than assumed, so the code enforces what the comment claims.
                        $PoolClosed = $true
                    }

                    if ($PoolClosed)
                    {
                        $MetricCallPool.Dispose()
                        if ($PoolBroken)
                        {
                            Write-MetricsDiag "Metric worker pool was Broken: disposed without a close so it does not stay registered in the process."
                        }
                        else
                        {
                            Write-MetricsDiag ("Metric worker pool released: every worker had finished (waited {0} ms)." -f $PoolGraceClock.ElapsedMilliseconds)
                        }
                    }
                    else
                    {
                        Write-MetricsDiag ("WARNING: metric worker pool NOT released after {0}s - idle={1}, abandoned calls still running={2}, pool state={3}. It stays in memory until the process ends; the run itself is unaffected." -f $MetricPoolReleaseGraceSeconds, $PoolIdle, $MetricAbandonedRunning, $MetricCallPool.RunspacePoolStateInfo.State)
                    }
                }
            }
            catch
            {
                # Reaching here on the throw path means an exception is already in flight, and it may be
                # the out-of-memory this pooling exists to survive. A teardown failure must not replace
                # the exception the operator needs to see, but it must not vanish either: Write-Verbose
                # would be discarded at the default preference.
                Write-MetricsDiag ("Pool teardown reported: {0}" -f $_.Exception.Message)
            }
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
    Write-MetricsDiag ("Total calls: {0} | Success: {1} | Timeout: {2} | Throttled: {3} | Error: {4} | NotFound: {5} | BadRequest: {6} | Unauthorized: {8} | Forbidden: {9} | Elapsed: {7}s" -f $DiagRecords.Count, $OkCount, $TimeoutCount, $ThrottledCount, $ErrorCount, $NotFoundCount, $BadRequestCount, ([math]::Round($PhaseStopwatch.Elapsed.TotalSeconds, 1)).ToString('0.0', [cultureinfo]::InvariantCulture), $UnauthorizedCount, $ForbiddenCount)

    if ($MetricAbandonedCount -gt 0)
    {
        Write-MetricsDiag ("{0} timed-out call(s) were stopped without waiting for them; {1} had still not returned at phase end and hold a pool runspace until they do." -f $MetricAbandonedCount, $MetricAbandonedRunning)
    }

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
            Write-MetricsDiag ("  {0} idx={1} {2}/{3}/{4} interval={5} attempts={6} {7}s {8}{9}" -f $rec.Outcome, $rec.MetricIndex, $rec.Service, $rec.Name, $rec.Metric, $rec.Interval, $rec.Attempts, ([double]$rec.ElapsedSec).ToString('0.##', [cultureinfo]::InvariantCulture), $rec.Error, $StuckBodyNote)
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
            Write-MetricsDiag ("  {0}s idx={1} {2}/{3}/{4} interval={5} ({6})" -f ([double]$rec.ElapsedSec).ToString('0.##', [cultureinfo]::InvariantCulture), $rec.MetricIndex, $rec.Service, $rec.Name, $rec.Metric, $rec.Interval, $rec.Outcome)
        }
    }

    $WarningPreference = "Continue"

    $MetricDefs = $null;
}

