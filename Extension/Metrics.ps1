#requires -Version 7.0
param(
    $Subscriptions,
    $Resources, # The massive list of raw discovered infrastructure items (VMs, Disks, DBs)
    $Task, # String tracking the script task mode (e.g., 'Processing')
    $ConcurrencyLimit, # Number of concurrent threads allowed to run simultaneously
    $FilePath, # Root destination directory path for saving JSON data chunks
    $ResourceIdDictionary, # Map dictionary to replace original Resource IDs with obfuscated GUID values
    $ResourceNameDictionary, # Map dictionary to mask the actual human-readable names of the items
    [Alias('ResourceSubscriptionDictionary')]$ResourceSubDictionary, # Map dictionary to obfuscate subscription names
    [Alias('ResourceResourceGroupDictionary')]$ResourceGroupDictionary, # Map dictionary to obfuscate resource group names
    $Obfuscate, # Boolean flag toggle indicating whether sensitive infrastructure details should be masked
    $MetricsLookbackDays = 31, # Default tracking duration window determining how far back to ask Azure for data
    # EXPERIMENTAL (default OFF): fetch VM CPU/memory metrics through the Azure
    # Monitor data-plane metrics:getBatch API (one REST call per <=50 resources,
    # all aggregations in one request) instead of one Get-AzMetric per
    # (resource, metric). Falls back to the per-call path on ANY batch failure
    # (e.g. Microsoft.Insights RP not registered, narrow RBAC, regional issue),
    # so metrics are never lost. When omitted, behaviour is byte-identical to the
    # established per-call path.
    #
    # SIDE-EFFECT (opt-in only): because getBatch REQUIRES the Microsoft.Insights
    # resource provider, passing this switch makes the tool ATTEMPT to register
    # that provider on the subscription if it is not already registered (a
    # control-plane write). This is intentional - opting in is the operator's
    # consent to "help enable" the data plane. It is best-effort and idempotent:
    # if the identity/org policy disallows the registration it is logged and the
    # run falls back to the per-call path (no failure, no data loss).
    [switch]$UseMetricsBatch
)

# Shared cross-cutting helpers (Write-RdaProgress). This extension is invoked via
# `& $MetricPath` from ResourceInventory.ps1, which already dot-sources this file,
# so the function is normally in scope. Re-load it here (only if not already
# defined) so the extension stays self-contained and progress never no-ops just
# because of how it was invoked. Best-effort: a missing file must not break the
# metrics phase.
if (-not (Get-Command -Name 'Write-RdaProgress' -ErrorAction SilentlyContinue))
{
    $CommonFunctionsFile = Join-Path (Split-Path $PSScriptRoot -Parent) 'Functions/Common.Functions.ps1'
    if (Test-Path -Path $CommonFunctionsFile -PathType Leaf)
    {
        . $CommonFunctionsFile
    }
}

if ($Task -eq 'Processing')
{
    # ---------------------------------------------------------------------
    # Metrics diagnostics -> consolidated LOCAL debug log, NOT the terminal.
    # ---------------------------------------------------------------------
    # On a large multi-subscription run the per-call and end-of-phase [Metrics]
    # lines flooded the console (and, coming from concurrent runspaces, made it
    # look frozen until a keypress forced a repaint). They now route through the
    # single shared logger with -NoConsole (off the terminal) + -ToDebugLog
    # (append to $Global:DebugLogFile, the same file the per-collector heartbeat
    # writes). Write-MetricsDiag is a THIN wrapper - it only prefixes '[Metrics] '
    # so the consolidated log stays readable, then delegates to Write-Log; it has
    # NO independent log-sink logic of its own. Write-Log is Global (defined in
    # Functions/Common.Functions.ps1) so it is in scope here even though this
    # extension is invoked via '& $MetricPath'. When no $Global:DebugLogFile is
    # set (e.g. a standalone extension run) Write-Log's -ToDebugLog is a silent
    # no-op, so nothing ever lands on the terminal either way.
    function Write-MetricsDiag([string]$Line)
    {
        Write-Log -Message ('[Metrics] ' + $Line) -NoConsole -ToDebugLog
    }

    # -----------------------------------------------------------------------
    # Obfuscation of metric records (shared by the per-call and batch paths).
    # Mutates each metric hashtable in place, mapping the real resource ID to
    # its deterministic obfuscated value via the shared dictionaries (with the
    # same prod_/nonprod_ fallback the per-call path has always used). Extracted
    # to a single implementation so the per-call and batch fast-path produce
    # IDENTICAL obfuscation - divergent copies could break determinism.
    # -----------------------------------------------------------------------
    function Protect-RdaMetrics
    {
        param($Metrics, $ResourceIdDictionary, $ResourceNameDictionary, $ResourceSubDictionary, $ResourceGroupDictionary)

        foreach ($metric in $Metrics)
        {
            $OriginalId = $metric.ID
            if (![string]::IsNullOrEmpty($OriginalId) -and $null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0 -and $ResourceIdDictionary.ContainsKey($OriginalId))
            {
                $metric.ID = $ResourceIdDictionary[$OriginalId]
                $metric.Name = $ResourceNameDictionary[$OriginalId]
                $metric.Subscription = $ResourceSubDictionary[$OriginalId]
                $metric.ResourceGroup = $ResourceGroupDictionary[$OriginalId]
            }
            else
            {
                # Fallback: resource not in main dictionary (e.g., deleted/transient resource)
                # Cache the obfuscated value so same resource correlates across metrics
                if (![string]::IsNullOrEmpty($OriginalId))
                {
                    $FbPrefix = if ($OriginalId -match '\b(dev|test|qa|tst|development|non-prod|uat|nonprod)\b') { 'nonprod_' } else { 'prod_' }
                    $ResourceIdDictionary[$OriginalId] = $FbPrefix + [guid]::NewGuid().ToString()
                    $ResourceNameDictionary[$OriginalId] = $FbPrefix + [guid]::NewGuid().ToString()
                    $ResourceSubDictionary[$OriginalId] = $FbPrefix + 'sub_' + [guid]::NewGuid().ToString()
                    $ResourceGroupDictionary[$OriginalId] = $FbPrefix + 'rg_' + [guid]::NewGuid().ToString()
                    $metric.ID = $ResourceIdDictionary[$OriginalId]
                    $metric.Name = $ResourceNameDictionary[$OriginalId]
                    $metric.Subscription = $ResourceSubDictionary[$OriginalId]
                    $metric.ResourceGroup = $ResourceGroupDictionary[$OriginalId]
                }
            }
        }
    }

    # -----------------------------------------------------------------------
    # Build ONE metric record (the 16-field hashtable) from a single getBatch
    # per-metric result, using the SAME downstream math as the per-call path:
    # pick the aggregation column named by the def, keep null intervals, then
    # 95th-percentile + Measure collapse. Kept identical to the inline per-call
    # computation so batch output matches the frozen Metrics_*.json schema.
    # -----------------------------------------------------------------------
    function New-RdaMetricObject
    {
        param($Def, $MetricResult)

        $MetricError = $false
        $DataPoints = @()
        if ($null -ne $MetricResult -and $MetricResult.timeseries)
        {
            $DataPoints = @($MetricResult.timeseries[0].data)
        }
        $MetricTotalCount = $DataPoints.Count

        $Agg = ([string]$Def.Aggregation).ToLower()
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
            $MetricQueryResultsSorted = $MetricQueryResults | Sort-Object
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

    # -----------------------------------------------------------------------
    # Fetch metrics for a set of same-namespace metric defs via the Azure
    # Monitor data-plane metrics:getBatch API. Groups by subscription + region
    # (the endpoint is regional, one subscription per call), chunks resource ids
    # to the 50-per-call limit, and requests all needed metric names + all
    # aggregations in a single call. Returns an array of metric hashtables in the
    # per-call shape. THROWS on any HTTP/parse failure so the caller can fall back.
    # The Get-AzMetricsBatch cmdlet is deliberately NOT used - it ignores the Az
    # context; we mint the data-plane token and call REST for portability.
    # -----------------------------------------------------------------------
    function Invoke-RdaMetricsBatch
    {
        param($Defs, $MetricNamespace)

        $Results = [System.Collections.Generic.List[object]]::new()
        if (-not $Defs -or @($Defs).Count -eq 0) { return $Results.ToArray() }

        # subscription id + region derive from each resource's ARM id / Location.
        # Group by subscription + region + timing so every def in a group shares
        # the StartTime/EndTime/Interval we read from $First (correct for the
        # uniform VM fast-path today, and safe if reused for mixed-interval defs).
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
            $Aggregations = @($Group.Group | Select-Object -ExpandProperty Aggregation -Unique | ForEach-Object { ([string]$_).ToLower() })
            $StartIso = ([datetime]$First.StartTime).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            $EndIso = ([datetime]$First.EndTime).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            $IntervalIso = [System.Xml.XmlConvert]::ToString([TimeSpan]$First.Interval)

            $TokenObj = Get-AzAccessToken -ResourceUrl 'https://metrics.monitor.azure.com' -WarningAction SilentlyContinue
            $BearerToken = if ($TokenObj.Token -is [securestring]) { [System.Net.NetworkCredential]::new('', $TokenObj.Token).Password } else { [string]$TokenObj.Token }

            $NamesParam = (($MetricNames | ForEach-Object { [uri]::EscapeDataString($_) }) -join ',')
            $NsParam = [uri]::EscapeDataString($MetricNamespace)
            $AggParam = ($Aggregations -join ',')

            $ResourceIds = @($Group.Group | Select-Object -ExpandProperty Id -Unique)
            for ($Offset = 0; $Offset -lt $ResourceIds.Count; $Offset += 50)
            {
                $Chunk = @($ResourceIds[$Offset..([math]::Min($Offset + 49, $ResourceIds.Count - 1))])
                $Uri = "{0}/subscriptions/{1}/metrics:getBatch?api-version=2023-10-01&metricnamespace={2}&metricnames={3}&aggregation={4}&interval={5}&starttime={6}&endtime={7}" -f `
                    $Endpoint, $SubscriptionId, $NsParam, $NamesParam, $AggParam, $IntervalIso, $StartIso, $EndIso
                $BodyJson = @{ resourceids = $Chunk } | ConvertTo-Json

                $Response = Invoke-RestMethod -Method Post -Uri $Uri -Headers @{ Authorization = "Bearer $BearerToken"; 'Content-Type' = 'application/json' } -Body $BodyJson -ErrorAction Stop
                # One metrics:getBatch REST call was issued. Count it (script scope so
                # the end-of-phase summary can report this run's metric-query API-call
                # impact). Placed AFTER the POST so only round-trips that reached Azure
                # are counted; a POST that throws is a fallback, tallied on the per-call
                # path instead.
                $script:MetricsBatchHttpCalls++

                foreach ($ResourceResult in @($Response.values))
                {
                    $ResId = [string]$ResourceResult.resourceid
                    $ResourceDefs = @($Group.Group | Where-Object { ([string]$_.Id) -ieq $ResId })
                    foreach ($Def in $ResourceDefs)
                    {
                        $MetricResult = @($ResourceResult.value | Where-Object { ([string]$_.name.value) -ieq ([string]$Def.MetricName) })[0]
                        # Only emit a record when the metric was actually RETURNED for
                        # this resource. A def whose metric is ABSENT from the response
                        # is left unsatisfied so the caller re-queues it to the per-call
                        # path (rather than emitting a silent zero). A metric that IS
                        # present but has an empty window still yields a legitimate
                        # zeroed record via New-RdaMetricObject.
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

    # -----------------------------------------------------------------------
    # Opt-in prerequisite helper: runs ONLY when -UseMetricsBatch is set, to
    # "help enable" the data-plane path the operator asked for. Best-effort:
    #   - Ensures the Microsoft.Insights resource provider is Registered on the
    #     current-context subscription (a HARD prerequisite for metrics:getBatch;
    #     an unregistered RP is what makes getBatch 403 even for an Owner).
    # SCOPE: acts on the CURRENT Az-context subscription. This extension is
    # invoked once per subscription by ResourceInventory.ps1 (the collector/
    # extension contract), with the context already set to that subscription and
    # $Resources scoped to it, so current-context registration is the correct
    # subscription. (If this ever runs for defs spanning multiple subscriptions,
    # registration would need to iterate them.)
    # Permission is deliberately NOT pre-checked with ARM checkAccess: that API
    # was observed to return false negatives for a valid Owner, so a pre-check
    # would wrongly disable batch. The batch attempt itself is the reliable
    # permission check; the caller classifies a 403 in its fallback path.
    # Never throws - on any problem it logs and lets the batch attempt proceed
    # (which falls back to per-call if the data plane is still unavailable).
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

            # Registration is asynchronous; poll briefly (bounded). This cost is
            # ONE-TIME per subscription - once Registered it persists, so future
            # runs hit the fast 'already registered' path above and never wait.
            # Not reaching Registered here is NON-fatal - the batch attempt falls
            # back to per-call.
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
            # Most likely the identity lacks Microsoft.Insights/register/action
            # (Reader can't register providers). Surface it, then let the batch
            # attempt proceed and fall back if the data plane is unavailable.
            Write-MetricsDiag ("[batch] could not ensure Microsoft.Insights registration ({0}). If batch fails, an admin must register the provider: Register-AzResourceProvider -ProviderNamespace Microsoft.Insights" -f $_.Exception.Message)
        }
    }

    # Instantiate a clean, empty generic PowerShell Custom Object container
    $Tmp = New-Object PSObject

    # Attach a custom note property placeholder string to hold metrics arrays later on
    $Tmp | Add-Member -MemberType NoteProperty -Name Metrics -Value NotSet

    # Swap the placeholder property value for a highly optimized, thread-safe concurrent collection bucket
    $Tmp.Metrics = [System.Collections.Concurrent.ConcurrentBag[psobject]]::new()

    # Create a dynamic, variable-length list array to track specific metric request definitions
    $MetricDefs = [System.Collections.Generic.List[object]]::new()

    # Convert the lookback parameter integer into a clean negative integer value for time calculations
    $MetricsLookbackPeriodDays = -1 * [math]::Abs([int]$MetricsLookbackDays)

    # Calculate the exact starting time date object by rolling back the calendar based on the lookback value
    $MetricStartTime = (Get-Date).AddDays($MetricsLookbackPeriodDays)

    # Record the precise real-time timestamp representing the current end time marker
    $MetricEndTime = (Get-Date)
    # Establish an offset timestamp rolled back exactly 24 hours ago
    $MetricTimeOneDay = (Get-Date).AddDays(-1)

    # Build a fast id -> subscription lookup once. The per-resource loops below
    # previously scanned the entire $Subscriptions list with Where-Object for
    # every resource (O(N*M)); on a large estate that is thousands of linear
    # scans. A hashtable makes each lookup O(1). The full subscription object
    # is stored so existing `$subscription.Name` references keep working.
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
            # Construct and append a custom configuration object onto the main definitions table for CPU metrics
            $MetricDefs.Add([PSCustomObject]@{
                    MetricIndex = $MetricCountId++;
                    MetricName = 'Percentage CPU';
                    StartTime = $MetricStartTime;
                    EndTime = $MetricEndTime;
                    Interval = '00:15:00';
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
            # Construct and append an additional layout tracking object focused strictly on VM memory capacity
            $MetricDefs.Add([PSCustomObject]@{
                    MetricIndex = $MetricCountId++;
                    MetricName = 'Available Memory Bytes';
                    StartTime = $MetricStartTime;
                    EndTime = $MetricEndTime;
                    Interval = '00:15:00';
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

    # Define Managed Disk Metrics
    #
    # Actual disk performance (IOPS + throughput) for ATTACHED managed disks.
    # VMDisk.ps1 already records each disk's PROVISIONED ceiling
    # (diskIOPSReadWrite / diskMBpsReadWrite); these metrics capture what the
    # disk actually DID, so the two together are what drive storage right-sizing.
    #
    # Scoped to attached disks (ManagedBy populated): unattached disks have no
    # meaningful I/O, and querying them only burns Azure Monitor read budget
    # against the ~12k reads/hour/subscription ceiling. The 'Composite Disk ...'
    # names are the per-disk composite metrics Azure Monitor exposes on the
    # microsoft.compute/disks scope (read+write split). Series='true' so the
    # engine produces both the 95th-percentile peak (MetricPercentile) and the
    # average (MetricValue) for each, exactly like the VM CPU/memory series.
    $ManagedDisks = $Resources | Where-Object { $_.TYPE -eq 'microsoft.compute/disks' -and -not [string]::IsNullOrEmpty($_.ManagedBy) }

    if ($ManagedDisks)
    {
        foreach ($managedDisk in $ManagedDisks)
        {
            $Subscription = $SubLookup[$managedDisk.subscriptionId]

            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'Composite Disk Read Operations/sec'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = '00:15:00'; Aggregation = 'Maximum'; Measure = 'Average'; Id = $managedDisk.Id; SubName = $Subscription.Name; ResourceGroup = $managedDisk.ResourceGroup; Name = $managedDisk.Name; Location = $managedDisk.Location; Service = 'Managed Disk'; Series = 'true' })
            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'Composite Disk Write Operations/sec'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = '00:15:00'; Aggregation = 'Maximum'; Measure = 'Average'; Id = $managedDisk.Id; SubName = $Subscription.Name; ResourceGroup = $managedDisk.ResourceGroup; Name = $managedDisk.Name; Location = $managedDisk.Location; Service = 'Managed Disk'; Series = 'true' })
            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'Composite Disk Read Bytes/sec'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = '00:15:00'; Aggregation = 'Maximum'; Measure = 'Average'; Id = $managedDisk.Id; SubName = $Subscription.Name; ResourceGroup = $managedDisk.ResourceGroup; Name = $managedDisk.Name; Location = $managedDisk.Location; Service = 'Managed Disk'; Series = 'true' })
            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'Composite Disk Write Bytes/sec'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = '00:15:00'; Aggregation = 'Maximum'; Measure = 'Average'; Id = $managedDisk.Id; SubName = $Subscription.Name; ResourceGroup = $managedDisk.ResourceGroup; Name = $managedDisk.Name; Location = $managedDisk.Location; Service = 'Managed Disk'; Series = 'true' })
        }
    }

    #Define Storage Account Metrics

    $StorageAccounts = $Resources | Where-Object { $_.TYPE -eq 'microsoft.storage/storageaccounts' }

    if ($StorageAccounts)
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
                $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'cpu_used'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = '00:30:00'; Aggregation = 'Maximum'; Measure = 'Average'; Id = $sqlDb.Id; SubName = $Subscription.Name; ResourceGroup = $sqlDb.ResourceGroup; Name = $sqlDb.Name; Location = $sqlDb.Location; Service = 'SQL Database'; Series = 'true' })

                if ($sqlDb.kind -match 'serverless')
                {
                    $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'app_cpu_billed'; StartTime = $MetricTimeOneDay; EndTime = $MetricEndTime; Interval = '0.00:01:00'; Aggregation = 'Total'; Measure = 'Sum'; Id = $sqlDb.Id; SubName = $Subscription.Name; ResourceGroup = $sqlDb.ResourceGroup; Name = $sqlDb.Name; Location = $sqlDb.Location; Service = 'SQL Database'; Series = 'false' })
                }
            }
            else
            {
                $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'dtu_limit'; StartTime = $MetricTimeOneDay; EndTime = $MetricEndTime; Interval = '1.00:00:00'; Aggregation = 'Maximum'; Measure = 'Largest'; Id = $sqlDb.Id; SubName = $Subscription.Name; ResourceGroup = $sqlDb.ResourceGroup; Name = $sqlDb.Name; Location = $sqlDb.Location; Service = 'SQL Database'; Series = 'false' })
                $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'dtu_used'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = '00:30:00'; Aggregation = 'Maximum'; Measure = 'Average'; Id = $sqlDb.Id; SubName = $Subscription.Name; ResourceGroup = $sqlDb.ResourceGroup; Name = $sqlDb.Name; Location = $sqlDb.Location; Service = 'SQL Database'; Series = 'true' })
            }

            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'cpu_percent'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = '00:30:00'; Aggregation = 'Maximum'; Measure = 'Largest'; Id = $sqlDb.Id; SubName = $Subscription.Name; ResourceGroup = $sqlDb.ResourceGroup; Name = $sqlDb.Name; Location = $sqlDb.Location; Service = 'SQL Database'; Series = 'true' })
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

            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'cpu_percent'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = '01:00:00'; Aggregation = 'Maximum'; Measure = 'Maximum'; Id = $mariaDb.Id; SubName = $Subscription.Name; ResourceGroup = $mariaDb.ResourceGroup; Name = $mariaDb.Name; Location = $mariaDb.Location; Service = 'MariaDB'; Series = 'true' })
            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'memory_percent'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = '01:00:00'; Aggregation = 'Maximum'; Measure = 'Maximum'; Id = $mariaDb.Id; SubName = $Subscription.Name; ResourceGroup = $mariaDb.ResourceGroup; Name = $mariaDb.Name; Location = $mariaDb.Location; Service = 'MariaDB'; Series = 'true' })
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

            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'cpu_percent'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = '01:00:00'; Aggregation = 'Maximum'; Measure = 'Maximum'; Id = $postgreDb.Id; SubName = $Subscription.Name; ResourceGroup = $postgreDb.ResourceGroup; Name = $postgreDb.Name; Location = $postgreDb.Location; Service = 'PostgreSQL'; Series = 'true' })
            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'memory_percent'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = '01:00:00'; Aggregation = 'Maximum'; Measure = 'Maximum'; Id = $postgreDb.Id; SubName = $Subscription.Name; ResourceGroup = $postgreDb.ResourceGroup; Name = $postgreDb.Name; Location = $postgreDb.Location; Service = 'PostgreSQL'; Series = 'true' })
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

            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'cpu_percent'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = '01:00:00'; Aggregation = 'Maximum'; Measure = 'Maximum'; Id = $mysqlDb.Id; SubName = $Subscription.Name; ResourceGroup = $mysqlDb.ResourceGroup; Name = $mysqlDb.Name; Location = $mysqlDb.Location; Service = 'MySQL'; Series = 'true' })
            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'memory_percent'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = '01:00:00'; Aggregation = 'Maximum'; Measure = 'Maximum'; Id = $mysqlDb.Id; SubName = $Subscription.Name; ResourceGroup = $mysqlDb.ResourceGroup; Name = $mysqlDb.Name; Location = $mysqlDb.Location; Service = 'MySQL'; Series = 'true' })
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

            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'cpu_percent'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = '01:00:00'; Aggregation = 'Maximum'; Measure = 'Maximum'; Id = $mysqlDb.Id; SubName = $Subscription.Name; ResourceGroup = $mysqlDb.ResourceGroup; Name = $mysqlDb.Name; Location = $mysqlDb.Location; Service = 'MySQL Flexible'; Series = 'true' })
            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'memory_percent'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = '01:00:00'; Aggregation = 'Maximum'; Measure = 'Maximum'; Id = $mysqlDb.Id; SubName = $Subscription.Name; ResourceGroup = $mysqlDb.ResourceGroup; Name = $mysqlDb.Name; Location = $mysqlDb.Location; Service = 'MySQL Flexible'; Series = 'true' })
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

            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'cpu_percent'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = '01:00:00'; Aggregation = 'Maximum'; Measure = 'Maximum'; Id = $postgreDb.Id; SubName = $Subscription.Name; ResourceGroup = $postgreDb.ResourceGroup; Name = $postgreDb.Name; Location = $postgreDb.Location; Service = 'PostgreSQL Flexible'; Series = 'true' })
            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'memory_percent'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = '01:00:00'; Aggregation = 'Maximum'; Measure = 'Maximum'; Id = $postgreDb.Id; SubName = $Subscription.Name; ResourceGroup = $postgreDb.ResourceGroup; Name = $postgreDb.Name; Location = $postgreDb.Location; Service = 'PostgreSQL Flexible'; Series = 'true' })
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

    # Running count of Azure Monitor metrics:getBatch HTTP calls issued this run
    # (stays 0 unless -UseMetricsBatch is set and a batchable service is present).
    # Combined with the per-call Get-AzMetric attempts in the end-of-phase summary
    # so each subscription's run self-reports its metric-query API-call impact
    # against the Azure Monitor "metric queries" billing meter.
    $script:MetricsBatchHttpCalls = 0

    # ---------------------------------------------------------------------
    # OPTIONAL data-plane batch fast-path for VM / disk / storage metrics (default OFF).
    # ---------------------------------------------------------------------
    # When -UseMetricsBatch is set, fetch these services' metrics through the
    # Azure Monitor metrics:getBatch API (one REST call per <=50 resources, all
    # aggregations in one request) instead of one Get-AzMetric per
    # (resource, metric). Each batchable service is fetched with its OWN metric
    # namespace; the produced records accumulate into the "_0" chunk. Every def
    # NOT satisfied by batch (a per-service failure, an empty/partial response,
    # or a non-batchable service) is left on the per-call loop below - metrics
    # are never lost (fail-safe, not fail-silent).
    if ($UseMetricsBatch)
    {
        # Batchable service -> its Azure Monitor metric namespace. Ordered so the
        # "_0" chunk is deterministic. Add a service here to batch it (its metric
        # defs must be attached to a resource whose ARM id yields the namespace).
        $BatchNamespaceMap = [ordered]@{
            'Virtual Machines' = 'microsoft.compute/virtualMachines'
            'Managed Disk'     = 'microsoft.compute/disks'
            'Storage Account'  = 'microsoft.storage/storageAccounts'
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
            # Operator opted into batch: help enable it by ensuring the
            # Microsoft.Insights RP is registered (best-effort, non-fatal).
            Initialize-RdaMetricsBatchPrereq

            # Fetch each batchable service independently: a failure for one service
            # re-queues ONLY that service's defs to the per-call path, leaving the
            # others batched (per-service fail-safe).
            foreach ($Service in $BatchGroups.Keys)
            {
                $ServiceDefs = $BatchGroups[$Service]
                $Namespace = $BatchNamespaceMap[$Service]
                try
                {
                    $BatchObjects = Invoke-RdaMetricsBatch -Defs $ServiceDefs -MetricNamespace $Namespace
                    # A 200 with zero records must NOT be treated as success - that
                    # would drop this service's metrics silently. Throw so the catch
                    # keeps this service's defs on the per-call path (fail-safe).
                    if (@($BatchObjects).Count -eq 0)
                    {
                        throw ("getBatch returned no metric records for {0} {1} metric def(s)." -f $ServiceDefs.Count, $Service)
                    }

                    # Re-queue any def NOT satisfied by a returned record (partial
                    # 200 / omitted resource / unmatched metric name). Keyed on the
                    # REAL id, before the obfuscation pass below rewrites $BatchObj.ID.
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
                    # This service falls back to per-call; OTHER services unaffected.
                    foreach ($Def in $ServiceDefs) { $RemainingDefs.Add($Def) }
                    $BatchErr = $_.Exception.Message
                    # Classify the failure so the operator who opted into batch gets
                    # an ACTIONABLE reason (this is the reliable permission check -
                    # the ARM checkAccess API gives false negatives, so we read it
                    # off the real attempt). An auth/403 => subscription-level read
                    # is missing.
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

            # Obfuscate + write the accumulated batch records ONCE as the "_0" chunk
            # (matches the Metrics_<name>_<stamp>__<idx>.json naming; the per-call
            # loop starts at 1, so downstream globbing picks up both with no clash).
            if ($Tmp.Metrics.Count -gt 0)
            {
                if ($Obfuscate)
                {
                    Protect-RdaMetrics -Metrics $Tmp.Metrics -ResourceIdDictionary $ResourceIdDictionary -ResourceNameDictionary $ResourceNameDictionary -ResourceSubDictionary $ResourceSubDictionary -ResourceGroupDictionary $ResourceGroupDictionary
                }
                $BatchOutputPath = $FilePath + "_0.json"
                $Tmp | ConvertTo-Json -depth 5 -compress | Out-File $BatchOutputPath -Encoding utf8
                $Tmp.Metrics.Clear()
            }

            # Everything not batched (per-service fallbacks + non-batchable
            # services) is processed by the per-call loop below.
            $MetricDefs = $RemainingDefs
            $MetricCount = $MetricDefs.Count
            Write-MetricsDiag ("Metrics batch fast-path: {0} metric def(s) remain on the per-call path." -f $MetricCount)
        }
    }

    $WarningPreference = "SilentlyContinue"

    # ---------------------------------------------------------------------
    # Metrics collection diagnostics + resilience configuration
    # ---------------------------------------------------------------------
    # Capture the Az context ONCE in the parent. ForEach-Object -Parallel runs
    # each item in a fresh runspace that does NOT inherit the parent's Az
    # session, so without passing this through explicitly (-DefaultProfile)
    # the first Get-AzMetric in each runspace can stall on an implicit token
    # acquisition or fail outright - a prime suspect for the metrics phase
    # appearing to "hang". Captured here, passed in via $using below.
    $MetricAzContext = $null
    try
    {
        $MetricAzContext = (Get-AzContext)
    }
    catch
    {
        # The Azure PowerShell module (Az) has a built-in feature that saves your login tokens to a secure file on your local hard drive.
        # When a new, blank runspace spins up, Azure PowerShell will automatically look at this local file to log itself in.
        Write-MetricsDiag "WARNING: could not capture Az context for parallel runspaces; metric calls will rely on per-runspace context autosave."
    }

    # Resilience knobs for the per-call Get-AzMetric wrapper. These are stable
    # internals rather than script parameters: a 120s client-side timeout per
    # call and up to 3 retries (exponential backoff) handles transient ARM
    # throttling/hangs without exposing extra knobs to the operator. Adjust here
    # if Azure Monitor behaviour changes; they were deliberately NOT promoted to
    # parameters to keep the script surface small.
    $MetricTimeoutSeconds = 120
    $MetricMaxRetries = 3

    # Thread-safe diagnostics: each parallel runspace appends one record so the
    # parent can summarise where time went and which calls timed out / were
    # throttled / errored. This is the "where exactly is it getting stuck"
    # instrumentation - it survives the runspace boundary via $using.
    $MetricDiagnostics = [System.Collections.Concurrent.ConcurrentBag[psobject]]::new()

    $PhaseStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Write-MetricsDiag ("Starting metrics collection: {0} metric definition(s), ThrottleLimit={1}, per-call timeout={2}s, max retries={3}, lookback={4} day(s)." -f $MetricCount, $ConcurrencyLimit, $MetricTimeoutSeconds, $MetricMaxRetries, [math]::Abs($MetricsLookbackPeriodDays))

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
            # Bar-only progress: the metrics phase runs inside the non-interactive
            # parallel stream worker, where one stdout line per batch would clutter
            # the parent's demuxed output on a large tenant. -BarOnly renders the
            # Write-Progress bar interactively (no-op otherwise, no stdout line).
            # The per-batch dispatch detail is preserved as Write-Verbose below and
            # in the end-of-phase diagnostics summary.
            Write-RdaProgress -Activity 'Metrics collection' -CurrentItem ("batch {0} ({1} call(s))" -f $RangeIdx, $Defs.Count) -Index $MetricsProcessed -Total $MetricCount -BarOnly
            Write-Verbose ("[Metrics] Batch {0}: dispatching {1} metric call(s) (processed {2}/{3})." -f $RangeIdx, $Defs.Count, $MetricsProcessed, $MetricCount)

            $Defs | ForEach-Object -Parallel {
                $AzContext = $using:MetricAzContext
                $CallTimeoutSeconds = $using:MetricTimeoutSeconds
                $CallMaxRetries = $using:MetricMaxRetries
                $DiagBag = $using:MetricDiagnostics

                # Per-call progress was previously written to the console with
                # Write-Host for EVERY metric definition (thousands per sub). From
                # concurrent runspaces that flood is what made the terminal appear
                # frozen until a keypress forced a repaint. The per-call outcome
                # (including this "processing" detail) is still recorded in
                # $diagBag below and surfaced in the end-of-phase diagnostics
                # summary, so nothing is lost from the log - only the live console
                # spam is removed. Warnings (retry) and errors (giving up) below
                # are intentionally kept on the console.

                $MetricError = $false
                $MetricName = $_.MetricName
                $MetricService = $_.Service

                # Per-call diagnostics: outcome is one of Success / Timeout /
                # Throttled / Error and is reported back to the parent so the
                # metrics phase can show exactly which calls stalled.
                $CallStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                $CallOutcome = 'Success'
                $CallAttempts = 0
                $CallErrorMsg = $null

                # Common args for every attempt. -DefaultProfile forces the call
                # to use the parent's captured Az context instead of relying on
                # the fresh runspace inheriting a session (which it does not).
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
                    # Retry loop with exponential backoff. Attempt 0 is the first
                    # try; up to $callMaxRetries additional attempts follow. Each
                    # attempt is bounded by a client-side timeout implemented with
                    # a thread job so a single hung HTTP call can never wedge the
                    # whole metrics phase the way an un-timed Get-AzMetric can.
                    $Attempt = 0
                    $Succeeded = $false
                    $LastError = $null
                    $MetricQuery = $null

                    while (-not $Succeeded -and $Attempt -le $CallMaxRetries)
                    {
                        $CallAttempts = $Attempt + 1
                        $AttemptStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                        $TimedOut = $false
                        $Throttled = $false

                        $Job = Start-ThreadJob -ScriptBlock {
                            param($mArgs)
                            Get-AzMetric @mArgs
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
                                if ($LastError -match '429|throttl|TooManyRequests|rate limit')
                                {
                                    $Throttled = $true
                                }
                            }
                            finally
                            {
                                Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue
                            }
                        }
                        else
                        {
                            # Timed out: stop the hung job and treat as a failed attempt.
                            $TimedOut = $true
                            $LastError = ("Timed out after {0}s" -f $CallTimeoutSeconds)
                            Stop-Job -Job $Job -ErrorAction SilentlyContinue
                            Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue
                        }

                        $AttemptStopwatch.Stop()

                        if ($Succeeded)
                        {
                            # Per-call success was previously logged to the console
                            # (one DarkGreen line per metric). Removed to stop the
                            # concurrent-runspace console flood; the success is still
                            # recorded in $diagBag below (Outcome='Success') and
                            # counted in the end-of-phase summary. The break MUST stay
                            # - it is the retry-loop exit on a successful call.
                            break
                        }

                        # Failed attempt - decide whether to retry. The per-call
                        # retry / giving-up detail is deliberately NOT written to
                        # the console: from concurrent runspaces it flooded the
                        # terminal. The final per-metric Outcome, Attempts and
                        # Error are recorded in the diagnostics bag below and
                        # surfaced in the end-of-phase summary (written to the
                        # debug log), so nothing diagnostic is lost.
                        if ($Attempt -lt $CallMaxRetries)
                        {
                            # Exponential backoff: 2^attempt seconds, capped, plus
                            # jitter so a wave of throttled calls does not retry in
                            # lockstep. Throttled calls wait a bit longer.
                            $Backoff = [math]::Min([math]::Pow(2, $Attempt), 30)
                            if ($Throttled) { $Backoff = [math]::Min($Backoff * 2, 60) }
                            $Jitter = (Get-Random -Minimum 0 -Maximum 1000) / 1000.0
                            $SleepSeconds = [math]::Round($Backoff + $Jitter, 2)
                            Start-Sleep -Seconds $SleepSeconds
                        }
                        else
                        {
                            $CallOutcome = if ($TimedOut) { 'Timeout' } elseif ($Throttled) { 'Throttled' } else { 'Error' }
                        }

                        $Attempt++
                    }

                    if (-not $Succeeded)
                    {
                        throw ("Get-AzMetric failed after {0} attempt(s): {1}" -f $CallAttempts, $LastError)
                    }

                    # Total interval count Azure Monitor returned for this metric,
                    # including intervals that carry no datapoint. This is the
                    # denominator for coverage / %TimeOn-style derivations: for a VM's
                    # 'Percentage CPU' series, MetricCount / MetricTotalCount * 100 is
                    # the fraction of the window the VM was actually running (%TimeOn).
                    # Captured here, before the Measure switch below collapses
                    # $metricQueryResults to a scalar.
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
                    }

                    $MetricQueryResultsCount = ($MetricQueryResults.Where({ $_ -ne $null }).Count)

                    if ($MetricQueryResultsCount -eq 0)
                    {
                        $MetricQueryResults = 0
                        $MetricQueryResultsCount = 0
                        $MetricPercentileIndex = 0
                        $MetricPercentile = 0
                    }
                    else
                    {
                        $MetricQueryResultsSorted = $MetricQueryResults | Sort-Object
                        $MetricPercentileIndex = [math]::Ceiling(0.95 * $MetricQueryResultsSorted.Count) - 1
                        $MetricPercentile = $MetricQueryResultsSorted[$MetricPercentileIndex]

                        if ($_.Series -eq 'true')
                        {
                            $MetricTimeSeries = $MetricQueryResults.Where({ $_ -ne $null })
                        }

                        switch ($_.Measure)
                        {
                            'Average' { $MetricQueryResults = ($MetricQueryResults | Measure-Object -Average).Average }
                            'Maximum' { $MetricQueryResults = ($MetricQueryResults | Measure-Object -Maximum).Maximum }
                            'Sum' { $MetricQueryResults = ($MetricQueryResults | Measure-Object -Sum).Sum }
                            'Minimum' { $MetricQueryResults = ($MetricQueryResults | Measure-Object -Minimum).Minimum }
                            'Largest' { $MetricQueryResults = ($MetricQueryResults | Sort-Object -Descending)[0] }
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
                    # No Write-Error here: this runs in a ForEach-Object -Parallel
                    # worker, so a Write-Error surfaced one error-stream record per
                    # failed metric - on a large multi-sub run that is exactly the
                    # noise this change removes. The failure is not lost: it is
                    # recorded in $diagBag below (Outcome='Error', Error=$callErrorMsg)
                    # and surfaced in the end-of-phase summary written to the debug
                    # log, and $metricError still flags the metric record ($obj) below.
                }

                $CallStopwatch.Stop()
                $DiagBag.Add([PSCustomObject]@{
                        MetricIndex = $_.MetricIndex
                        Service     = $MetricService
                        Name        = $_.Name
                        Metric      = $MetricName
                        Interval    = $_.Interval
                        Outcome     = $CallOutcome
                        Attempts    = $CallAttempts
                        ElapsedSec  = [math]::Round($CallStopwatch.Elapsed.TotalSeconds, 2)
                        Error       = $CallErrorMsg
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
            $Tmp | ConvertTo-Json -depth 5 -compress | Out-File $OutputPath -Encoding utf8
            $Tmp.Metrics.Clear()

            $RangeIdx++
        }
    }

    # Clear the progress bar now that every batch has been dispatched.
    Write-RdaProgress -Activity 'Metrics collection' -Completed

    $PhaseStopwatch.Stop()

    # ---------------------------------------------------------------------
    # Metrics phase summary - the "where did it get stuck" report.
    # Groups every per-call diagnostic record by outcome, and surfaces the
    # slowest calls so a hang or throttling hotspot is obvious at a glance.
    # ---------------------------------------------------------------------
    $DiagRecords = @($MetricDiagnostics)
    $OkCount = @($DiagRecords | Where-Object { $_.Outcome -eq 'Success' }).Count
    $TimeoutCount = @($DiagRecords | Where-Object { $_.Outcome -eq 'Timeout' }).Count
    $ThrottledCount = @($DiagRecords | Where-Object { $_.Outcome -eq 'Throttled' }).Count
    $ErrorCount = @($DiagRecords | Where-Object { $_.Outcome -eq 'Error' }).Count

    Write-MetricsDiag ("===== Metrics phase summary =====")
    Write-MetricsDiag ("Total calls: {0} | Success: {1} | Timeout: {2} | Throttled: {3} | Error: {4} | Elapsed: {5}s" -f $DiagRecords.Count, $OkCount, $TimeoutCount, $ThrottledCount, $ErrorCount, [math]::Round($PhaseStopwatch.Elapsed.TotalSeconds, 1))

    # Self-reported metric-query API-call impact for THIS subscription. The per-call
    # path issues one Get-AzMetric HTTP call per attempt (retries included), so sum
    # the recorded Attempts; the batch path issues one metrics:getBatch POST per
    # <=50-resource chunk ($script:MetricsBatchHttpCalls). Both count toward the
    # Azure Monitor "metric queries" meter (10,000,000 calls free per billing account
    # per month, then charged per Azure Monitor pricing). Use -SkipMetrics to issue
    # zero; -UseMetricsBatch lowers the count vs the per-call path.
    $PerCallHttpCalls = if ($DiagRecords.Count -gt 0) { [int]($DiagRecords | Measure-Object -Property Attempts -Sum).Sum } else { 0 }
    $BatchHttpCalls = [int]$script:MetricsBatchHttpCalls
    Write-MetricsDiag ("Metric-query API calls issued (this subscription): {0} total | per-call Get-AzMetric incl. retries: {1} | getBatch POSTs: {2}. Counts toward the Azure Monitor 'metric queries' meter (10,000,000 free/account/month)." -f ($PerCallHttpCalls + $BatchHttpCalls), $PerCallHttpCalls, $BatchHttpCalls)

    # Roll this subscription's total into the run-wide running total surfaced in
    # the wrapper RunSummary. Mirrors the $Global:ConsumptionRecordCount pattern:
    # nil-init once, then accumulate with += across every subscription processed
    # in this scope (the sequential wrapper's scope, or a parallel stream worker's
    # scope which reports the slice total in its per-stream summary JSON).
    if ($null -eq $Global:MetricsApiCallCount) { $Global:MetricsApiCallCount = 0 }
    $Global:MetricsApiCallCount = [int]$Global:MetricsApiCallCount + $PerCallHttpCalls + $BatchHttpCalls

    if (($TimeoutCount + $ThrottledCount + $ErrorCount) -gt 0)
    {
        Write-MetricsDiag ("Non-success calls (where it got stuck):")
        foreach ($rec in ($DiagRecords | Where-Object { $_.Outcome -ne 'Success' } | Sort-Object ElapsedSec -Descending))
        {
            Write-MetricsDiag ("  {0} idx={1} {2}/{3}/{4} interval={5} attempts={6} {7}s {8}" -f $rec.Outcome, $rec.MetricIndex, $rec.Service, $rec.Name, $rec.Metric, $rec.Interval, $rec.Attempts, $rec.ElapsedSec, $rec.Error)
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
