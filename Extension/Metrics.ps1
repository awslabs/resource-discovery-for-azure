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
