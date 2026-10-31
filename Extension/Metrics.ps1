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
    $MetricsLookbackDays = 31 # Default tracking duration window determining how far back to ask Azure for data
)


if (-not (Get-Command -Name 'Write-RdaProgress' -ErrorAction SilentlyContinue))
{
    $CommonFunctionsFile = Join-Path (Split-Path $PSScriptRoot -Parent) 'Functions/Common.Functions.ps1'
    if (Test-Path -Path $CommonFunctionsFile -PathType Leaf)
    {
        . $CommonFunctionsFile
    }
}


if (-not (Get-Command -Name 'Resolve-ObfuscationToken' -ErrorAction SilentlyContinue))
{
    function Resolve-ObfuscationToken
    {
        param(
            [string]$RealValue,
            [string]$LookupKey,
            $SharedDictionary,
            [hashtable]$LocalCache,
            [string]$TokenPrefix
        )

        if ($null -ne $SharedDictionary -and $SharedDictionary.ContainsKey($LookupKey)) { return $SharedDictionary[$LookupKey] }
        if ($LocalCache.ContainsKey($RealValue)) { return $LocalCache[$RealValue] }

        $Token = $TokenPrefix + [guid]::NewGuid().ToString()
        $LocalCache[$RealValue] = $Token
        return $Token
    }
}

if (-not (Get-Command -Name 'Build-ObfuscatedResourceUri' -ErrorAction SilentlyContinue))
{
    function Build-ObfuscatedResourceUri
    {
        param(
            [string]$RawUri,
            [string]$Prefix,
            $SubscriptionDictionary,
            $ResourceGroupDictionary,
            $NameDictionary,
            [hashtable]$SubCache,
            [hashtable]$RgCache,
            [hashtable]$NameCache
        )

        if ([string]::IsNullOrEmpty($RawUri))
        {
            return 'obfuscated'
        }

        if ($RawUri -notmatch '^/subscriptions/([^/]+)(/resourcegroups/([^/]+))?(/providers/(.+))?$')
        {
            if (-not $NameCache.ContainsKey($RawUri))
            {
                $NameCache[$RawUri] = $Prefix + [guid]::NewGuid().ToString()
            }
            return $NameCache[$RawUri]
        }

        $RealSub = $Matches[1]
        $RealRg = $Matches[3]
        $RealProv = $Matches[5]

        $ObfSub = Resolve-ObfuscationToken -RealValue $RealSub -LookupKey $RawUri -SharedDictionary $SubscriptionDictionary -LocalCache $SubCache -TokenPrefix ($Prefix + 'sub_')

        $RebuiltUri = '/subscriptions/' + $ObfSub

        if (-not [string]::IsNullOrEmpty($RealRg))
        {
            $RgTag = if ($RealRg -match '^mc_') { 'mc_' } else { '' }
            $ObfRg = Resolve-ObfuscationToken -RealValue $RealRg -LookupKey $RawUri -SharedDictionary $ResourceGroupDictionary -LocalCache $RgCache -TokenPrefix ($Prefix + 'rg_' + $RgTag)
            $RebuiltUri += '/resourcegroups/' + $ObfRg
        }

        if (-not [string]::IsNullOrEmpty($RealProv))
        {
            $ProvParts = $RealProv -split '/'
            $Rebuilt = @()
            for ($Pi = 0; $Pi -lt $ProvParts.Count; $Pi++)
            {
                $Part = $ProvParts[$Pi]
                $IsNameSegment = ($Pi -ge 2 -and ($Pi % 2 -eq 0))
                if ($IsNameSegment -and -not [string]::IsNullOrEmpty($Part) -and $Part -ne '$system')
                {
                    $NameSharedDict = if ($Pi -eq $ProvParts.Count - 1) { $NameDictionary } else { $null }
                    $Rebuilt += Resolve-ObfuscationToken -RealValue $Part -LookupKey $RawUri -SharedDictionary $NameSharedDict -LocalCache $NameCache -TokenPrefix $Prefix
                }
                else
                {
                    $Rebuilt += $Part
                }
            }
            $RebuiltUri += '/providers/' + ($Rebuilt -join '/')
        }

        return $RebuiltUri
    }
}

# Definitions of one resource that share a time window, time grain and aggregation
# can be fetched with one Get-AzMetric call, since -MetricName takes several names.
# -AggregationType takes a single value, so different aggregations stay separate
# calls. Time grains are compared as TimeSpan, so '1:00:00' and '01:00:00' match.
function Get-MetricGroupKey
{
    param($Def)

    $Grain = [timespan]::Zero
    $GrainKey = if ([timespan]::TryParse([string]$Def.Interval, [cultureinfo]::InvariantCulture, [ref]$Grain)) { $Grain.Ticks } else { [string]$Def.Interval }
    return ('{0}|{1}|{2}|{3}' -f ([datetime]$Def.StartTime).Ticks, ([datetime]$Def.EndTime).Ticks, $GrainKey, $Def.Aggregation)
}

# Returns a list of groups; each group is an array of definitions, in their original
# order, that can share one Get-AzMetric call. A resource's definitions are added
# consecutively, so grouping only looks within a run of definitions that share the
# same resource Id. Azure Monitor accepts at most 20 metric names in one request, so
# a group holds at most $MaxMetricNames distinct names; definitions that share a
# metric name stay in the same group.
function Group-MetricDefinition
{
    param($MetricDefs, [int]$MaxMetricNames = 20)

    $MetricGroups = [System.Collections.Generic.List[object]]::new()
    $ResourceGroups = [ordered]@{}
    $GroupResourceId = $null
    foreach ($Def in $MetricDefs)
    {
        if (-not [string]::Equals([string]$Def.Id, $GroupResourceId, [System.StringComparison]::Ordinal))
        {
            foreach ($Members in $ResourceGroups.Values) { $MetricGroups.Add($Members.ToArray()) }
            $ResourceGroups.Clear()
            $GroupResourceId = [string]$Def.Id
        }
        $GroupKey = Get-MetricGroupKey -Def $Def
        if (-not $ResourceGroups.Contains($GroupKey)) { $ResourceGroups[$GroupKey] = [System.Collections.Generic.List[object]]::new() }
        $ResourceGroups[$GroupKey].Add($Def)
    }
    foreach ($Members in $ResourceGroups.Values) { $MetricGroups.Add($Members.ToArray()) }

    # Split every group that names more than $MaxMetricNames metrics.
    $Capped = [System.Collections.Generic.List[object]]::new()
    foreach ($Group in $MetricGroups)
    {
        $Chunks = [System.Collections.Generic.List[object]]::new()
        $ChunkOfName = [System.Collections.Generic.Dictionary[string, int]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $NamesInLast = 0
        foreach ($Def in $Group)
        {
            $Name = [string]$Def.MetricName
            if (-not $ChunkOfName.ContainsKey($Name))
            {
                if ($Chunks.Count -eq 0 -or $NamesInLast -ge $MaxMetricNames)
                {
                    $Chunks.Add([System.Collections.Generic.List[object]]::new())
                    $NamesInLast = 0
                }
                $ChunkOfName[$Name] = $Chunks.Count - 1
                $NamesInLast++
            }
            $Chunks[$ChunkOfName[$Name]].Add($Def)
        }
        foreach ($Chunk in $Chunks) { $Capped.Add($Chunk.ToArray()) }
    }

    Write-Output -NoEnumerate -InputObject $Capped
}

if ($Task -eq 'Processing')
{
    function Write-MetricsDiag([string]$Line)
    {
        Write-Log -Message ('[Metrics] ' + $Line) -NoConsole -ToDebugLog
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
                    Interval = '1:00:00';
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
                    Interval = '1:00:00';
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

    $ManagedDisks = $Resources | Where-Object { $_.TYPE -eq 'microsoft.compute/disks' -and -not [string]::IsNullOrEmpty($_.ManagedBy) }

    if ($ManagedDisks)
    {
        foreach ($managedDisk in $ManagedDisks)
        {
            $Subscription = $SubLookup[$managedDisk.subscriptionId]

            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'Composite Disk Read Operations/sec'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = '1:00:00'; Aggregation = 'Maximum'; Measure = 'Average'; Id = $managedDisk.Id; SubName = $Subscription.Name; ResourceGroup = $managedDisk.ResourceGroup; Name = $managedDisk.Name; Location = $managedDisk.Location; Service = 'Managed Disk'; Series = 'true' })
            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'Composite Disk Write Operations/sec'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = '1:00:00'; Aggregation = 'Maximum'; Measure = 'Average'; Id = $managedDisk.Id; SubName = $Subscription.Name; ResourceGroup = $managedDisk.ResourceGroup; Name = $managedDisk.Name; Location = $managedDisk.Location; Service = 'Managed Disk'; Series = 'true' })
            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'Composite Disk Read Bytes/sec'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = '1:00:00'; Aggregation = 'Maximum'; Measure = 'Average'; Id = $managedDisk.Id; SubName = $Subscription.Name; ResourceGroup = $managedDisk.ResourceGroup; Name = $managedDisk.Name; Location = $managedDisk.Location; Service = 'Managed Disk'; Series = 'true' })
            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'Composite Disk Write Bytes/sec'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = '1:00:00'; Aggregation = 'Maximum'; Measure = 'Average'; Id = $managedDisk.Id; SubName = $Subscription.Name; ResourceGroup = $managedDisk.ResourceGroup; Name = $managedDisk.Name; Location = $managedDisk.Location; Service = 'Managed Disk'; Series = 'true' })
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
                $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'cpu_used'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = '1:00:00'; Aggregation = 'Maximum'; Measure = 'Average'; Id = $sqlDb.Id; SubName = $Subscription.Name; ResourceGroup = $sqlDb.ResourceGroup; Name = $sqlDb.Name; Location = $sqlDb.Location; Service = 'SQL Database'; Series = 'true' })

                if ($sqlDb.kind -match 'serverless')
                {
                    $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'app_cpu_billed'; StartTime = $MetricTimeOneDay; EndTime = $MetricEndTime; Interval = '0.00:01:00'; Aggregation = 'Total'; Measure = 'Sum'; Id = $sqlDb.Id; SubName = $Subscription.Name; ResourceGroup = $sqlDb.ResourceGroup; Name = $sqlDb.Name; Location = $sqlDb.Location; Service = 'SQL Database'; Series = 'false' })
                }
            }
            else
            {
                $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'dtu_limit'; StartTime = $MetricTimeOneDay; EndTime = $MetricEndTime; Interval = '1.00:00:00'; Aggregation = 'Maximum'; Measure = 'Largest'; Id = $sqlDb.Id; SubName = $Subscription.Name; ResourceGroup = $sqlDb.ResourceGroup; Name = $sqlDb.Name; Location = $sqlDb.Location; Service = 'SQL Database'; Series = 'false' })
                $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'dtu_used'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = '1:00:00'; Aggregation = 'Maximum'; Measure = 'Average'; Id = $sqlDb.Id; SubName = $Subscription.Name; ResourceGroup = $sqlDb.ResourceGroup; Name = $sqlDb.Name; Location = $sqlDb.Location; Service = 'SQL Database'; Series = 'true' })
            }

            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'cpu_percent'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = '1:00:00'; Aggregation = 'Maximum'; Measure = 'Largest'; Id = $sqlDb.Id; SubName = $Subscription.Name; ResourceGroup = $sqlDb.ResourceGroup; Name = $sqlDb.Name; Location = $sqlDb.Location; Service = 'SQL Database'; Series = 'true' })
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


    $MetricDiagnostics = [System.Collections.Concurrent.ConcurrentBag[psobject]]::new()
    # Get-AzMetric request counts for the summary: [0] every request, [1] single-metric
    # fallback requests. The parallel runspaces share this array and update it under a
    # lock (Monitor) on the array itself.
    $MetricRequestCounts = [long[]]::new(2)

    # $MetricCount is the number of definitions to send, as it was when the batch
    # loop counted definitions: with none to send, no group and no call is made.
    if ($MetricCount -gt 0)
    {
        $MetricGroups = Group-MetricDefinition -MetricDefs $MetricDefs
    }
    else
    {
        $MetricGroups = [System.Collections.Generic.List[object]]::new()
    }

    $PhaseStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Write-MetricsDiag ("Starting metrics collection: {0} metric definition(s), ThrottleLimit={1}, per-call timeout={2}s, max retries={3}, lookback={4} day(s)." -f $MetricCount, $ConcurrencyLimit, $MetricTimeoutSeconds, $MetricMaxRetries, [math]::Abs($MetricsLookbackPeriodDays))

    $RangeBatch = [math]::Min($MetricCount , 250)
    $RangeIdx = 1
    $MetricsProcessed = 0
    $BatchGroups = [System.Collections.Generic.List[object]]::new()
    $BatchDefCount = 0

    # A batch is made of whole groups, so one call's metrics never land in different
    # Metrics_*.json files. A batch closes once it holds at least $RangeBatch
    # definitions, so it can exceed that by less than one group and there are never
    # more batches than with one definition at a time.
    for ($i = 0; $i -lt $MetricGroups.Count; $i++)
    {
        $BatchGroups.Add($MetricGroups[$i])
        $BatchDefCount += $MetricGroups[$i].Count
        $MetricsProcessed += $MetricGroups[$i].Count

        if ($BatchDefCount -ge $RangeBatch -or ($i + 1) -ge $MetricGroups.Count)
        {
            $BatchStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

            Write-RdaProgress -Activity 'Metrics collection' -CurrentItem ("batch {0} ({1} call(s))" -f $RangeIdx, $BatchGroups.Count) -Index $MetricsProcessed -Total $MetricCount -BarOnly
            Write-Verbose ("[Metrics] Batch {0}: dispatching {1} metric call(s) (processed {2}/{3})." -f $RangeIdx, $BatchGroups.Count, $MetricsProcessed, $MetricCount)

            # Each parallel item is one group of definitions.
            $BatchGroups | ForEach-Object -Parallel {
                $AzContext = $using:MetricAzContext
                $CallTimeoutSeconds = $using:MetricTimeoutSeconds
                $CallMaxRetries = $using:MetricMaxRetries
                $DiagBag = $using:MetricDiagnostics
                $MetricBag = ($using:Tmp).Metrics
                $RequestCounts = $using:MetricRequestCounts

                # True when Azure answered HTTP 400 (BadRequest), as it does when a requested
                # metric name is not valid for the resource. The status code and the message
                # of the exception and of every exception it wraps are checked, because an
                # outer exception can report a different status than the 400 it wraps.
                function Test-MetricBadRequest
                {
                    param([System.Exception]$Exception)

                    $Pending = [System.Collections.Generic.Queue[object]]::new()
                    $Pending.Enqueue($Exception)
                    $Checked = 0
                    while ($Pending.Count -gt 0 -and $Checked -lt 10)
                    {
                        $Ex = $Pending.Dequeue()
                        if ($null -eq $Ex) { continue }
                        $Checked++

                        $StatusCode = $null
                        if ($null -ne $Ex.PSObject.Properties['Response'] -and $null -ne $Ex.Response -and $null -ne $Ex.Response.PSObject.Properties['StatusCode'])
                        {
                            $StatusCode = $Ex.Response.StatusCode
                        }
                        elseif ($null -ne $Ex.PSObject.Properties['StatusCode'])
                        {
                            $StatusCode = $Ex.StatusCode
                        }
                        if ($null -ne $StatusCode -and "$StatusCode" -in @('400', 'BadRequest'))
                        {
                            return $true
                        }
                        if ([string]$Ex.Message -match 'BadRequest')
                        {
                            return $true
                        }

                        $Pending.Enqueue($Ex.InnerException)
                        if ($null -ne $Ex.PSObject.Properties['ErrorRecord'] -and $null -ne $Ex.ErrorRecord -and -not [object]::ReferenceEquals($Ex.ErrorRecord.Exception, $Ex))
                        {
                            $Pending.Enqueue($Ex.ErrorRecord.Exception)
                        }
                    }

                    return $false
                }

                # One Get-AzMetric request with the per-call timeout and retry/backoff.
                # Returns the outcome rather than throwing, so the caller decides how a
                # failure is recorded for each definition. With -StopOnBadRequest a
                # BadRequest answer ends the request at once: the same name set is
                # rejected the same way on every retry.
                function Invoke-MetricRequest
                {
                    param($Def, $MetricNames, [string]$Kind, [switch]$StopOnBadRequest)

                    [System.Threading.Monitor]::Enter($RequestCounts)
                    try
                    {
                        $RequestCounts[0]++
                        if ($Kind -eq 'Fallback') { $RequestCounts[1]++ }
                    }
                    finally
                    {
                        [System.Threading.Monitor]::Exit($RequestCounts)
                    }
                    $CallOutcome = 'Success'
                    $CallAttempts = 0
                    $Request = [PSCustomObject]@{ Succeeded = $false; Query = $null; Outcome = $null; Attempts = 0; ErrorMessage = $null; BadRequest = $false }

                    $MetricArgs = @{
                        ResourceId      = $Def.Id
                        MetricName      = $MetricNames
                        StartTime       = $Def.StartTime
                        EndTime         = $Def.EndTime
                        TimeGrain       = $Def.Interval
                        AggregationType = $Def.Aggregation
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
                        $Succeeded = $false
                        $LastError = $null
                        $MetricQuery = $null

                        while (-not $Succeeded -and $Attempt -le $CallMaxRetries)
                        {
                            $CallAttempts = $Attempt + 1
                            $AttemptStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                            $TimedOut = $false
                            $Throttled = $false
                            $BadRequest = $false

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
                                    elseif ($StopOnBadRequest)
                                    {
                                        $BadRequest = Test-MetricBadRequest -Exception $_.Exception
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
                                break
                            }

                            if ($BadRequest)
                            {
                                $CallOutcome = 'Error'
                                $Request.BadRequest = $true
                                break
                            }

                            if ($Attempt -lt $CallMaxRetries)
                            {
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

                        $Request.Succeeded = $true
                        $Request.Query = $MetricQuery
                    }
                    catch
                    {
                        if ($CallOutcome -eq 'Success') { $CallOutcome = 'Error' }
                        $Request.ErrorMessage = $_.Exception.Message
                    }

                    $Request.Outcome = $CallOutcome
                    $Request.Attempts = $CallAttempts
                    return $Request
                }

                # Adds the result record and the diagnostics record for one definition.
                # $MetricQuery is the response for this metric alone, whether it was
                # requested on its own or together with other metrics of the resource.
                # The reported time is $ExtraSeconds plus, when given, the time on
                # $CallStopwatch when the record is added.
                function Add-MetricRecord
                {
                    param($Def, $Request, $MetricQuery, [System.Diagnostics.Stopwatch]$CallStopwatch, [double]$ExtraSeconds = 0)

                    $ElapsedSeconds = $ExtraSeconds
                    $MetricError = $false
                    $CallOutcome = $Request.Outcome
                    $CallErrorMsg = $null
                    $MetricTimeSeries = $null

                    try
                    {
                        if (-not $Request.Succeeded)
                        {
                            throw $Request.ErrorMessage
                        }

                        $MetricTotalCount = @($MetricQuery.Data).Count

                        $MetricQueryResults = 0
                        $MetricTimeSeries = 0

                        switch ($Def.Aggregation)
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
                                # .Data has a Count of its own, the number of data points, so read the
                                # property of each point. A point without one reads as $null, not as 1.
                                $MetricQueryResults = foreach ($DataPoint in $MetricQuery.Data) { $DataPoint.PSObject.Properties['Count'].Value }
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

                            if ($Def.Series -eq 'true')
                            {
                                $MetricTimeSeries = $MetricQueryResults.Where({ $_ -ne $null })
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

                    if ($null -ne $CallStopwatch)
                    {
                        $ElapsedSeconds += $CallStopwatch.Elapsed.TotalSeconds
                    }

                    $DiagBag.Add([PSCustomObject]@{
                            MetricIndex = $Def.MetricIndex
                            Service     = $Def.Service
                            Name        = $Def.Name
                            Metric      = $Def.MetricName
                            Interval    = $Def.Interval
                            Outcome     = $CallOutcome
                            Attempts    = $Request.Attempts
                            ElapsedSec  = [math]::Round($ElapsedSeconds, 2)
                            Error       = $CallErrorMsg
                        })


                    $Obj = @{
                        'ID'                   = $Def.Id;
                        'Subscription'         = $Def.SubName;
                        'ResourceGroup'        = $Def.ResourceGroup;
                        'Name'                 = $Def.Name;
                        'Location'             = $Def.Location;
                        'Service'              = $Def.Service;
                        'Metric'               = $Def.MetricName;
                        'MetricAggregate'      = $Def.Aggregation;
                        'MetricTimeGrain'      = $Def.Interval;
                        'MetricMeasure'        = $Def.Measure;
                        'MetricPercentile'     = $MetricPercentile;
                        'MetricValue'          = $MetricQueryResults;
                        'MetricCount'          = $MetricQueryResultsCount;
                        'MetricTotalCount'     = $MetricTotalCount;
                        'MetricSeries'         = $MetricTimeSeries;
                        'MetricError'          = $MetricError;
                    }

                    $MetricBag.Add($Obj)
                }

                $GroupDefs = @($_)
                $CallStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

                if ($GroupDefs.Count -eq 1)
                {
                    $Request = Invoke-MetricRequest -Def $GroupDefs[0] -MetricNames $GroupDefs[0].MetricName -Kind 'Request'
                    Add-MetricRecord -Def $GroupDefs[0] -Request $Request -MetricQuery $Request.Query -CallStopwatch $CallStopwatch
                }
                else
                {
                    $MetricNames = [string[]]@($GroupDefs | ForEach-Object { [string]$_.MetricName } | Select-Object -Unique)
                    $Request = Invoke-MetricRequest -Def $GroupDefs[0] -MetricNames $MetricNames -Kind 'Request' -StopOnBadRequest
                    # The group request's own duration, read once: a metric answered by it
                    # reports this time even when it is recorded after a fallback request
                    # for another metric of the group.
                    $GroupSeconds = $CallStopwatch.Elapsed.TotalSeconds

                    # Index the response by metric name so each definition gets its own metric.
                    $ReturnedMetrics = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
                    if ($Request.Succeeded)
                    {
                        foreach ($ReturnedMetric in $Request.Query)
                        {
                            $ReturnedName = [string]$ReturnedMetric.Name.Value
                            if (-not [string]::IsNullOrEmpty($ReturnedName) -and -not $ReturnedMetrics.ContainsKey($ReturnedName))
                            {
                                $ReturnedMetrics[$ReturnedName] = $ReturnedMetric
                            }
                        }
                    }

                    foreach ($Def in $GroupDefs)
                    {
                        if ($Request.Succeeded -and $ReturnedMetrics.ContainsKey([string]$Def.MetricName))
                        {
                            Add-MetricRecord -Def $Def -Request $Request -MetricQuery $ReturnedMetrics[[string]$Def.MetricName] -ExtraSeconds $GroupSeconds
                        }
                        elseif (-not $Request.Succeeded -and -not $Request.BadRequest)
                        {
                            # The group failed after its retries for a reason that does not depend
                            # on the metric names (throttling, timeout, server error). Requesting
                            # each metric again would repeat the same failure once per metric, so
                            # every metric of the group records the group request's outcome.
                            Add-MetricRecord -Def $Def -Request $Request -MetricQuery $null -ExtraSeconds $GroupSeconds
                        }
                        else
                        {
                            # One invalid metric name makes Azure reject the whole request with
                            # BadRequest, so a rejected group is not retried and falls back to one
                            # request per metric; only a metric that also fails on its own is
                            # marked as an error. A metric missing from a successful response is
                            # requested on its own too. Its elapsed time includes the group request.
                            $SingleStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                            $SingleRequest = Invoke-MetricRequest -Def $Def -MetricNames $Def.MetricName -Kind 'Fallback'
                            Add-MetricRecord -Def $Def -Request $SingleRequest -MetricQuery $SingleRequest.Query -CallStopwatch $SingleStopwatch -ExtraSeconds $GroupSeconds
                        }
                    }
                }

                $Request = $null
                $ReturnedMetrics = $null
                $SingleRequest = $null

            } -ThrottleLimit $ConcurrencyLimit

            $BatchGroups.Clear()
            $BatchDefCount = 0

            $BatchStopwatch.Stop()
            Write-Verbose ("[Metrics] Batch {0} complete in {1}s. Cumulative diagnostics: {2} call record(s) so far." -f $RangeIdx, [math]::Round($BatchStopwatch.Elapsed.TotalSeconds, 1), $MetricDiagnostics.Count)

            if ($Obfuscate)
            {
                foreach ($metric in $Tmp.Metrics)
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
                        if (![string]::IsNullOrEmpty($OriginalId))
                        {
                            $FbPrefix = if ($OriginalId -match '\b(dev|test|qa|tst|development|non-prod|uat|nonprod)\b') { 'nonprod_' } else { 'prod_' }

                            if (-not $script:MetricsFallbackSubCache) { $script:MetricsFallbackSubCache = @{} }
                            if (-not $script:MetricsFallbackRgCache) { $script:MetricsFallbackRgCache = @{} }
                            if (-not $script:MetricsFallbackNameCache) { $script:MetricsFallbackNameCache = @{} }

                            $ObfuscatedId = Build-ObfuscatedResourceUri -RawUri $OriginalId -Prefix $FbPrefix -SubscriptionDictionary $ResourceSubDictionary -ResourceGroupDictionary $ResourceGroupDictionary -NameDictionary $ResourceNameDictionary -SubCache $script:MetricsFallbackSubCache -RgCache $script:MetricsFallbackRgCache -NameCache $script:MetricsFallbackNameCache

                            $ResourceIdDictionary[$OriginalId] = $ObfuscatedId
                            if (-not $ResourceNameDictionary.ContainsKey($OriginalId)) { $ResourceNameDictionary[$OriginalId] = $FbPrefix + [guid]::NewGuid().ToString() }
                            if (-not $ResourceSubDictionary.ContainsKey($OriginalId)) { $ResourceSubDictionary[$OriginalId] = $FbPrefix + 'sub_' + [guid]::NewGuid().ToString() }
                            if (-not $ResourceGroupDictionary.ContainsKey($OriginalId)) { $ResourceGroupDictionary[$OriginalId] = $FbPrefix + 'rg_' + [guid]::NewGuid().ToString() }

                            $metric.ID = $ObfuscatedId
                            $metric.Name = $ResourceNameDictionary[$OriginalId]
                            $metric.Subscription = $ResourceSubDictionary[$OriginalId]
                            $metric.ResourceGroup = $ResourceGroupDictionary[$OriginalId]
                        }
                    }
                }
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
    $DiagRecords = @($MetricDiagnostics)
    $OkCount = @($DiagRecords | Where-Object { $_.Outcome -eq 'Success' }).Count
    $TimeoutCount = @($DiagRecords | Where-Object { $_.Outcome -eq 'Timeout' }).Count
    $ThrottledCount = @($DiagRecords | Where-Object { $_.Outcome -eq 'Throttled' }).Count
    $ErrorCount = @($DiagRecords | Where-Object { $_.Outcome -eq 'Error' }).Count

    Write-MetricsDiag ("===== Metrics phase summary =====")
    Write-MetricsDiag ("Total calls: {0} | Success: {1} | Timeout: {2} | Throttled: {3} | Error: {4} | Elapsed: {5}s" -f $DiagRecords.Count, $OkCount, $TimeoutCount, $ThrottledCount, $ErrorCount, [math]::Round($PhaseStopwatch.Elapsed.TotalSeconds, 1))
    Write-MetricsDiag ("Azure Monitor requests: {0} for {1} metric definition(s), of which {2} single-metric fallback request(s); retries not counted" -f $MetricRequestCounts[0], $MetricCount, $MetricRequestCounts[1])

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
    $MetricGroups = $null
}
