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
    # Scale knobs for large tenants that cut Azure Monitor call count:
    # -IncludeStorageMetrics is opt-in (1 call/storage account); -SkipDiskMetrics is opt-out (4 calls/attached disk).
    [switch]$IncludeStorageMetrics,
    [switch]$SkipDiskMetrics,
    # Sampling grain for the VM/SQL/OSS-DB utilization series; 0 (default) keeps each
    # family's native cadence (byte-identical), a set 5/15/30/60 applies uniformly and changes data-point volume only, not API-call count.
    [ValidateSet(0, 5, 15, 30, 60)][int]$MetricsIntervalMinutes = 0,
    # EXPERIMENTAL (default OFF): fetch batchable services via metrics:getBatch; falls back to per-call on any failure (no data lost) and is byte-identical when omitted.
    # SIDE-EFFECT of opting in: attempts to register the Microsoft.Insights RP (a control-plane write), which getBatch requires.
    [switch]$UseMetricsBatch
)

# Re-load Write-RdaProgress from Common.Functions when not already defined, so progress
# does not no-op when this extension is invoked via `& $MetricPath`; best-effort, a missing file must not break the metrics phase.
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
    # Metrics diagnostics go to the LOCAL debug log, never the terminal: per-call lines
    # from concurrent runspaces flooded the console. Thin '[Metrics] ' prefix delegating to Write-Log.
    function Write-MetricsDiag([string]$Line)
    {
        Write-Log -Message ('[Metrics] ' + $Line) -NoConsole -ToDebugLog
    }

    # Read one obfuscation map, returning the 'obfuscated' sentinel on a missing key -
    # a missing key yields a silent $null (not a throw), which the PII no-null assertion flags. Shared per-call/batch so both obfuscate identically (divergent copies break determinism).
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
                # ContainsKey is checked on the ID map ONLY; the three companion maps use the
                # per-field 'obfuscated' sentinel because a missing key yields a silent $null (tokenised ID + null Name/Sub/RG), reachable via -ObfuscationDictionary with non-parallel maps.
                $metric.ID = $ResourceIdDictionary[$OriginalId]
                $metric.Name = Get-RdaMappedValue $ResourceNameDictionary $OriginalId
                $metric.Subscription = Get-RdaMappedValue $ResourceSubDictionary $OriginalId
                $metric.ResourceGroup = Get-RdaMappedValue $ResourceGroupDictionary $OriginalId
            }
            else
            {
                # Fallback: resource not in main dictionary (e.g., deleted/transient resource)
                # Cache the obfuscated value so same resource correlates across metrics
                if (![string]::IsNullOrEmpty($OriginalId) -and $null -ne $ResourceIdDictionary)
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
                else
                {
                    # No usable resource id or no dictionary: blank the descriptive fields to the
                    # 'obfuscated' sentinel so a missing id fails closed (no real PII in the shared JSON) rather than falling through unmasked.
                    $metric.ID = 'obfuscated'
                    $metric.Name = 'obfuscated'
                    $metric.Subscription = 'obfuscated'
                    $metric.ResourceGroup = 'obfuscated'
                }
            }
        }
    }

    # Build one 16-field metric record from a getBatch per-metric result using the SAME
    # math as the per-call path (aggregation column, keep nulls, 95th-percentile + Measure), so batch output matches the frozen Metrics_*.json schema.
    function New-RdaMetricObject
    {
        param($Def, $MetricResult)

        $MetricError = $false
        $DataPoints = @()
        # Also guard against a present-but-null .data: @($null).Count is 1, which
        # would report MetricTotalCount=1 for an empty series where the per-call
        # path (@($MetricQuery.Data).Count over an empty array) reports 0. Requiring
        # .data to be non-null keeps the batch denominator identical to per-call.
        if ($null -ne $MetricResult -and $MetricResult.timeseries -and $null -ne $MetricResult.timeseries[0].data)
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
            # 95th percentile over NON-null values only: Sort-Object places nulls first, so
            # including them skews the index low and can serialize MetricPercentile as null once nulls exceed ~5% of the window.
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
                    # Mirror the per-call Measure switch: an unhandled Measure would put the RAW
                    # per-interval array into the scalar MetricValue field, so throw to keep batch/per-call parity. ($_ is the switched-on Measure value, not a pipeline item.)
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

    # Fetch same-namespace metric defs via the Azure Monitor metrics:getBatch API: group by
    # subscription+region, chunk ids to 50/call, request all names+aggregations at once; THROWS on any failure so the caller falls back. Uses raw REST (not Get-AzMetricsBatch, which ignores the Az context).
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
            # InvariantCulture is REQUIRED: without it a non-Gregorian CurrentCulture (e.g. th-TH,
            # ar-SA) sends a wrong-calendar timespan that Azure rejects or answers empty, silently writing zeroed metrics.
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
                # Pre-emptive token refresh before each chunk (tokens expire ~60-75 min; the loop
                # can run 30+ min): refresh only within 5 min of expiry to avoid failing mid-batch and falling back to per-call.
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
                        # Emit only when the metric was RETURNED: an absent metric is left
                        # unsatisfied so the caller re-queues it per-call (not a silent zero). A present-but-empty window still yields a legitimate zeroed record.
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

    # Opt-in helper (only when -UseMetricsBatch): best-effort register Microsoft.Insights on the
    # current-context subscription, a hard prerequisite for getBatch (an unregistered RP 403s even an Owner).
    # Never throws and does NOT pre-check permission (ARM checkAccess gives false negatives) - the batch attempt is the real permission check.
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

    # High-frequency utilization-series grain (VM/SQL/OSS-DB). 0 (default) keeps each family's
    # native cadence (VM 15 / SQL 30 / OSS-DB 60 min; byte-identical); a set 5/15/30/60 applies uniformly, honoured as-is (all validated at Azure's PT1M base grain).
    # Only these utilization series are affected; the daily/storage/VMSS/CosmosDB reads keep their own literals.
    $VmMetricInterval = if ($MetricsIntervalMinutes -gt 0) { ([TimeSpan]::FromMinutes($MetricsIntervalMinutes)).ToString() } else { '00:15:00' }
    $SqlMetricInterval = if ($MetricsIntervalMinutes -gt 0) { ([TimeSpan]::FromMinutes($MetricsIntervalMinutes)).ToString() } else { '00:30:00' }
    $DbMetricInterval = if ($MetricsIntervalMinutes -gt 0) { ([TimeSpan]::FromMinutes($MetricsIntervalMinutes)).ToString() } else { '01:00:00' }
    Write-MetricsDiag ("Metric grain (requested {0} min): VM={1} SQL={2} OSS-DB={3} (0 = each family's native default; a set value is applied uniformly, honoured as-is)." -f $MetricsIntervalMinutes, $VmMetricInterval, $SqlMetricInterval, $DbMetricInterval)

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
            # Construct and append an additional layout tracking object focused strictly on VM memory capacity
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
    # (ManagedBy populated) - unattached disks have no meaningful I/O and querying them burns the ~12k reads/hour/subscription budget. Series='true' emits 95th-percentile peak + average.
    $ManagedDisks = $Resources | Where-Object { $_.TYPE -eq 'microsoft.compute/disks' -and -not [string]::IsNullOrEmpty($_.ManagedBy) }

    if ($ManagedDisks -and -not $SkipDiskMetrics)
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

    # OPT-IN: the capacity metric is collected only when explicitly asked for.
    if ($StorageAccounts)
    {
        # State the decision, so a report with no storage capacity figure is
        # explainable from the log instead of looking like a collection failure.
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

            # Do NOT narrow on 'kind': a Flex Consumption app and a working Linux Dedicated app
            # share identical kind/reserved values yet need opposite answers, so '-notmatch linux' would silently drop valid Linux metrics (the real discriminator is the plan SKU).
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

    # Running count of Azure Monitor metrics:getBatch HTTP calls issued this run
    # (stays 0 unless -UseMetricsBatch is set and a batchable service is present).
    # Combined with the per-call Get-AzMetric attempts in the end-of-phase summary
    # so each subscription's run self-reports its metric-query API-call impact
    # against the Azure Monitor "metric queries" billing meter.
    $script:MetricsBatchHttpCalls = 0

    # OPTIONAL batch fast-path (default OFF): with -UseMetricsBatch, fetch batchable services via
    # metrics:getBatch per OWN namespace into the "_0" chunk. Any def not satisfied (failure, partial, or non-batchable) stays on the per-call loop below so metrics are never lost.
    if ($UseMetricsBatch)
    {
        # Batchable service -> its Azure Monitor metric namespace. Ordered so the
        # "_0" chunk is deterministic. Add a service here to batch it (its metric
        # defs must be attached to a resource whose ARM id yields the namespace).
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

    # Capture the Az context ONCE in the parent: ForEach-Object -Parallel runspaces do NOT inherit
    # the parent's Az session, so without passing it via -DefaultProfile ($using below) the first Get-AzMetric can stall or fail - the prime cause of the metrics phase "hanging".
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

    # Resilience knobs (120s per-call timeout, 3 retries w/ backoff) for the Get-AzMetric wrapper:
    # deliberately internal constants, NOT operator parameters, to keep the script surface small.
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
            # Bar-only progress: a per-batch stdout line would clutter the parent's demuxed output;
            # -BarOnly renders the bar interactively (no-op otherwise) while the detail stays in Write-Verbose and the diagnostics summary.
            Write-RdaProgress -Activity 'Metrics collection' -CurrentItem ("batch {0} ({1} call(s))" -f $RangeIdx, $Defs.Count) -Index $MetricsProcessed -Total $MetricCount -BarOnly
            Write-Verbose ("[Metrics] Batch {0}: dispatching {1} metric call(s) (processed {2}/{3})." -f $RangeIdx, $Defs.Count, $MetricsProcessed, $MetricCount)

            $Defs | ForEach-Object -Parallel {
                $AzContext = $using:MetricAzContext
                $CallTimeoutSeconds = $using:MetricTimeoutSeconds
                $CallMaxRetries = $using:MetricMaxRetries
                $DiagBag = $using:MetricDiagnostics

                # Per-call progress is deliberately NOT written to the console here: Write-Host per
                # metric from concurrent runspaces froze the terminal. The outcome is still recorded in $diagBag and the end-of-phase summary; retry warnings/errors below stay on the console.

                $MetricError = $false
                $MetricName = $_.MetricName
                $MetricService = $_.Service

                # Per-call diagnostics reported to the parent. Outcome contract the phase summary
                # counts on: Success; Timeout/Throttled/Error (retried up to $CallMaxRetries); NotFound/BadRequest (permanent, one attempt). Keep in step with the retry-loop classification.
                $CallStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                $CallOutcome = 'Success'
                $CallAttempts = 0
                $CallErrorMsg = $null
                # Azure's own response body for a failed call. DIAGNOSTICS ONLY - it
                # is never read to make a retry or skip decision, and it never reaches
                # Metrics_*.json. See Get-RdaMetricErrorBody below for why it matters.
                $CallErrorBody = $null

                # Pull Azure Monitor's response body out of a failed call: $_.Exception.Message only
                # says a request was refused, the body says WHY (metric invalid vs unsupported grain (our bug via -MetricsIntervalMinutes) vs resource deleted). Defined INSIDE the -Parallel block (file-scope functions are invisible in these runspaces).
                # CONTRACT: never throws, returns $null when it finds nothing - a diagnostic aid must not break the phase it describes.
                function Get-RdaMetricErrorBody
                {
                    param($ErrorRecord)

                    try
                    {
                        if ($null -eq $ErrorRecord) { return $null }

                        $Found = $null

                        # ErrorDetails often carries the raw body verbatim and is the
                        # cheapest place to look, so try it before walking the chain.
                        try
                        {
                            $Details = $ErrorRecord.ErrorDetails.Message
                            if (-not [string]::IsNullOrWhiteSpace($Details)) { $Found = [string]$Details }
                        }
                        catch { }

                        # Walk the exception chain. Depth-bounded AND visited-tracked:
                        # a bound alone is not enough because a cyclic InnerException
                        # would still be re-inspected at every level, and some SDK
                        # wrappers do self-reference.
                        if ([string]::IsNullOrWhiteSpace($Found))
                        {
                            $Visited = [System.Collections.Generic.HashSet[int]]::new()
                            $Current = $ErrorRecord.Exception
                            $Depth = 0

                            while ($null -ne $Current -and $Depth -lt 10)
                            {
                                # Reference identity, so two distinct exceptions with
                                # equal messages are still both inspected.
                                $Key = [System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($Current)
                                if (-not $Visited.Add($Key)) { break }

                                # Only text-bearing members: a [System.IO.Stream] is rejected by the
                                # guard below, and draining the SDK's (usually already-consumed) response stream inside a diagnostic helper could disturb the error being described.
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

                        # Prefer the structured code/message pair when the body is JSON -
                        # that is the part a human reads - and fall back to the raw text
                        # when it is not JSON or the shape is unfamiliar.
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

                        # Collapse newlines so one record stays one log line, then cap.
                        $Rendered = ([string]$Rendered) -replace '\s+', ' '
                        $Rendered = $Rendered.Trim()

                        # Keep HEAD and TAIL when capping: Azure's actionable "Valid metrics: a,b,c..."
                        # list is often at the END, which a head-only cap discarded. Only truncate when it saves bytes (head+tail+marker exceeds a body just past the cap).
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
                        # Deliberately swallowed: this is a diagnostic aid, and a
                        # failure to describe an error must never become an error.
                        return $null
                    }
                }

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
                        $TimedOut = $false
                        $Throttled = $false
                        # Reset the captured body PER ATTEMPT: otherwise a body from a failed attempt 1
                        # lingers into a successful attempt 2, reporting Outcome='Success' with a stale ErrorBody. Keeps the retained body tied to the final (reported) attempt.
                        $CallErrorBody = $null
                        # A PERMANENT failure (404 deleted-after-discovery, 400 metric-invalid) can never
                        # succeed on retry, so skip the retries; $PermanentOutcome carries the observed HTTP status forward as the recorded Outcome.
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

                                # Azure's response body, diagnostics log only: deliberately NOT read by the
                                # classification below (permanent-vs-throttle stays a function of $LastError alone), so it cannot change retry behaviour.
                                $CallErrorBody = Get-RdaMetricErrorBody -ErrorRecord $_

                                # Permanent check MUST stay first: the throttle pattern is a loose substring
                                # and the message echoes the ARM id, so a GUID containing '429' would misclassify. The anchor is the literal 'invalid status code ' prefix; quotes are optional ('?) so an unquoted render still matches (else a permanent BadRequest fails open and burns the full retry budget).
                                # $PermanentOutcome is taken FROM the match; an unmatched failure falls through to retry (slower, never wrong).
                                if ($LastError -match "invalid status code '?(?<Status>NotFound|BadRequest)'?")
                                {
                                    $Permanent = $true
                                    $PermanentOutcome = $Matches['Status']
                                }
                                elseif ($LastError -match '429|throttl|TooManyRequests|rate limit')
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

                        if ($Succeeded)
                        {
                            # Per-call success is no longer logged to the console (it flooded concurrent
                            # runspaces); still recorded in $diagBag. The break MUST stay - it is the retry-loop exit on success.
                            break
                        }

                        # Failed attempt - decide whether to retry. Retry/giving-up detail is deliberately
                        # NOT written to the console (concurrent-runspace flood); the final Outcome/Attempts/Error land in the diagnostics bag and summary.
                        if (-not $Permanent -and $Attempt -lt $CallMaxRetries)
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
                            $CallOutcome = if ($Permanent) { $PermanentOutcome } elseif ($TimedOut) { 'Timeout' } elseif ($Throttled) { 'Throttled' } else { 'Error' }

                            # Give up NOW on a permanent failure rather than spending the
                            # remaining attempts (and their backoff) on a call that cannot
                            # succeed. The throw below still runs, so the metric is still
                            # recorded as having no data - only the futile retries are cut.
                            if ($Permanent) { break }
                        }

                        $Attempt++
                    }

                    if (-not $Succeeded)
                    {
                        throw ("Get-AzMetric failed after {0} attempt(s): {1}" -f $CallAttempts, $LastError)
                    }

                    # Total interval count (incl. empty intervals) - the denominator for %TimeOn/coverage
                    # (MetricCount / MetricTotalCount). Captured before the Measure switch collapses the results to a scalar.
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
                            # An unhandled Aggregation would leave $MetricQueryResults at its 0 initialiser -
                            # a real-looking zero after a successful call (reads as "idle", not "not measured"). Unreachable today (all 5 aggregations covered); exists so a misspelled Aggregation fails visibly.
                            # THROW (not null): the catch is the canonical failure shape, nulling hits the count-eq-0 branch that re-creates the silent zero, and MetricValue must stay numeric. ($_ is the switched-on value, not the pipeline item.)
                            throw ("Unhandled Aggregation '{0}' for metric '{1}' - no value could be read from the response." -f $_, $MetricName)
                        }
                    }

                    # $null -ne $_ , not '$_ -ne $null'. The reversed form is an array
                    # FILTER in PowerShell rather than a scalar comparison, so an element
                    # that is itself a collection yields a filtered array whose
                    # truthiness depends on its length. Matches the canonical order used
                    # a few lines below.
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
                        # Percentile over NON-null values only (see the batch path's note):
                        # Sort-Object places nulls first, so including them skewed the index
                        # low and could land it in the null region. The count>0 guard above
                        # ensures at least one non-null remains; $MetricQueryResults itself
                        # keeps its nulls for the Measure/Series step below.
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
                                # Same silent-wrong-value seam as the Aggregation switch: an unhandled Measure
                                # left $MetricQueryResults as the RAW per-interval array instead of a scalar. Throw for the same reasons (canonical catch, nulling doesn't fail visibly, MetricValue stays numeric). ($_ is the switched-on Measure value.)
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
                    # No Write-Error here: in a ForEach-Object -Parallel worker it surfaced one error-stream
                    # record per failed metric (the flood this removes). The failure still lands in $diagBag (Outcome='Error') and $MetricError flags the record below.
                }

                $CallStopwatch.Stop()
                $DiagBag.Add([PSCustomObject]@{
                        MetricIndex = $_.MetricIndex
                        Service     = $MetricService
                        Name        = $_.Name
                        Metric      = $MetricName
                        Interval    = $_.Interval
                        # Diagnostics only (this record never reaches Metrics_*.json).
                        # Carried so the BadRequest reporting below can show BOTH halves
                        # of a request Azure Monitor may have rejected on our side - a
                        # wrong interval and a wrong aggregation fail identically.
                        Aggregation = $_.Aggregation
                        Outcome     = $CallOutcome
                        Attempts    = $CallAttempts
                        ElapsedSec  = [math]::Round($CallStopwatch.Elapsed.TotalSeconds, 2)
                        Error       = $CallErrorMsg
                        # Azure's own response body, capped and newline-collapsed.
                        # Diagnostics only - like every other field here it never
                        # reaches Metrics_*.json, and nothing reads it to make a
                        # decision. $null when the call succeeded or no body was found.
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
    # Permanent, non-retried outcomes. Counted and reported SEPARATELY from
    # Timeout/Throttled/Error because they are not a run health problem and not a
    # place the run "got stuck": NotFound means the resource was deleted between
    # the Resource Graph snapshot and the metric call, BadRequest means Azure
    # Monitor rejected the request for that resource. Neither is retried.
    $NotFoundCount = @($DiagRecords | Where-Object { $_.Outcome -eq 'NotFound' }).Count
    $BadRequestCount = @($DiagRecords | Where-Object { $_.Outcome -eq 'BadRequest' }).Count

    Write-MetricsDiag ("===== Metrics phase summary =====")
    Write-MetricsDiag ("Total calls: {0} | Success: {1} | Timeout: {2} | Throttled: {3} | Error: {4} | NotFound: {5} | BadRequest: {6} | Elapsed: {7}s" -f $DiagRecords.Count, $OkCount, $TimeoutCount, $ThrottledCount, $ErrorCount, $NotFoundCount, $BadRequestCount, [math]::Round($PhaseStopwatch.Elapsed.TotalSeconds, 1))

    # Self-reported metric-query API-call impact for THIS subscription: per-call = sum of recorded
    # Attempts (one Get-AzMetric per attempt incl. retries); batch = $script:MetricsBatchHttpCalls (one POST per <=50 resources). Both count toward the Azure Monitor "metric queries" meter.
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
        foreach ($rec in ($DiagRecords | Where-Object { $_.Outcome -in @('Timeout', 'Throttled', 'Error') } | Sort-Object ElapsedSec -Descending))
        {
            # Azure's response body is appended here too, not only on the permanent
            # NotFound/BadRequest path. These are the calls that burned the FULL retry
            # budget, so they are the most expensive failures in the phase and the ones
            # where knowing the cause matters most. Omitting it here was an oversight
            # that left the costly failures the least explained.
            $StuckBodyNote = if ([string]::IsNullOrWhiteSpace($rec.ErrorBody)) { '' } else { (' | azure: ' + $rec.ErrorBody) }
            Write-MetricsDiag ("  {0} idx={1} {2}/{3}/{4} interval={5} attempts={6} {7}s {8}{9}" -f $rec.Outcome, $rec.MetricIndex, $rec.Service, $rec.Name, $rec.Metric, $rec.Interval, $rec.Attempts, $rec.ElapsedSec, $rec.Error, $StuckBodyNote)
        }
    }

    # Permanent rejections (abandoned after one attempt), reported separately but NOT silently:
    # a 404 is usually a deleted resource, but a 400 may be OUR request (bad TimeGrain/aggregation/metric), so the report prints the metric, interval and aggregation asked for to make a tool-side 400 diagnosable.
    if (($NotFoundCount + $BadRequestCount) -gt 0)
    {
        Write-MetricsDiag ("Metrics not collected for these resources (permanent, not retried - no data was available to collect):")
        foreach ($rec in ($DiagRecords | Where-Object { $_.Outcome -in @('NotFound', 'BadRequest') } | Sort-Object Service, Name))
        {
            $FirstLine = if ([string]::IsNullOrWhiteSpace($rec.Error)) { '(no error text captured)' } else { (([string]$rec.Error) -split "`r?`n")[0].Trim() }

            # Azure's own response body is what actually separates the causes the
            # status cannot: "metric not defined for this resource type" vs
            # "unsupported time grain" (a TOOL-side fault, reachable via
            # -MetricsIntervalMinutes) vs "resource not found". Appended when
            # present, and silently omitted when Azure gave us nothing to show.
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
