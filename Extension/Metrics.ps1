#requires -Version 7.0
param($Subscriptions, $Resources, $Task, $ConcurrencyLimit, $FilePath, $ResourceIdDictionary, $ResourceNameDictionary, [Alias('ResourceSubscriptionDictionary')]$ResourceSubDictionary, [Alias('ResourceResourceGroupDictionary')]$ResourceGroupDictionary, $Obfuscate, $MetricsLookbackDays = 31)

if ($Task -eq 'Processing')
{
    $tmp = New-Object PSObject
    $tmp | Add-Member -MemberType NoteProperty -Name Metrics -Value NotSet
    $tmp.Metrics = [System.Collections.Concurrent.ConcurrentBag[psobject]]::new()

    $metricDefs = [System.Collections.Generic.List[object]]::new()

    $metricsLookbackPeriodDays = -1 * [math]::Abs([int]$MetricsLookbackDays)
    $metricStartTime = (Get-Date).AddDays($metricsLookbackPeriodDays)
    $metricEndTime = (Get-Date)

    $metricTimeOneDay = (Get-Date).AddDays(-1)
    $metricTimeSevenDay = (Get-Date).AddDays(-7)

    # Build a fast id -> subscription lookup once. The per-resource loops below
    # previously scanned the entire $Subscriptions list with Where-Object for
    # every resource (O(N*M)); on a large estate that is thousands of linear
    # scans. A hashtable makes each lookup O(1). The full subscription object
    # is stored so existing `$subscription.Name` references keep working.
    $subLookup = @{}
    foreach ($subItem in $Subscriptions)
    {
        if ($null -ne $subItem -and ![string]::IsNullOrEmpty($subItem.id))
        {
            $subLookup[$subItem.id] = $subItem
        }
    }

    # Define VM Metrics
    $virtualMachines =  $Resources | Where-Object {$_.TYPE -eq 'microsoft.compute/virtualmachines'}

    $metricCountId = 1;

    if($virtualMachines)
    {
        foreach ($virtualMachine in $virtualMachines) 
        {
            $subscription = $subLookup[$virtualMachine.subscriptionId]
            $metricDefs.Add([PSCustomObject]@{ MetricIndex = $metricCountId++; 
            MetricName = 'Percentage CPU'; StartTime = $metricStartTime;  EndTime = $metricEndTime; 
            Interval = '00:15:00'; Aggregation = 'Maximum'; Measure = 'Average'; 
            Id = $virtualMachine.Id; 
            SubName = $subscription.Name; ResourceGroup = $virtualMachine.ResourceGroup; 
            Name = $virtualMachine.Name; Location = $virtualMachine.Location; 
            Service = 'Virtual Machines'; Series = 'true' })
            $metricDefs.Add([PSCustomObject]@{ MetricIndex = $metricCountId++; 
            MetricName = 'Available Memory Bytes'; 
            StartTime = $metricStartTime;  
            EndTime = $metricEndTime; 
            Interval = '00:15:00';  Aggregation = 'Minimum'; Measure = 'Average'; 
            Id = $virtualMachine.Id; SubName = $subscription.Name; 
            ResourceGroup = $virtualMachine.ResourceGroup; 
            Name = $virtualMachine.Name; Location = $virtualMachine.Location; Service = 'Virtual Machines'; 
            Series = 'true' })
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
    $managedDisks = $Resources | Where-Object { $_.TYPE -eq 'microsoft.compute/disks' -and -not [string]::IsNullOrEmpty($_.ManagedBy) }

    if($managedDisks)
    {
        foreach ($managedDisk in $managedDisks)
        {
            $subscription = $subLookup[$managedDisk.subscriptionId]

            $metricDefs.Add([PSCustomObject]@{ MetricIndex = $metricCountId++; MetricName = 'Composite Disk Read Operations/sec';  StartTime = $metricStartTime;  EndTime = $metricEndTime; Interval = '00:15:00';  Aggregation = 'Maximum'; Measure = 'Average'; Id = $managedDisk.Id; SubName = $subscription.Name; ResourceGroup = $managedDisk.ResourceGroup; Name = $managedDisk.Name; Location = $managedDisk.Location; Service = 'Managed Disk'; Series = 'true' })
            $metricDefs.Add([PSCustomObject]@{ MetricIndex = $metricCountId++; MetricName = 'Composite Disk Write Operations/sec'; StartTime = $metricStartTime;  EndTime = $metricEndTime; Interval = '00:15:00';  Aggregation = 'Maximum'; Measure = 'Average'; Id = $managedDisk.Id; SubName = $subscription.Name; ResourceGroup = $managedDisk.ResourceGroup; Name = $managedDisk.Name; Location = $managedDisk.Location; Service = 'Managed Disk'; Series = 'true' })
            $metricDefs.Add([PSCustomObject]@{ MetricIndex = $metricCountId++; MetricName = 'Composite Disk Read Bytes/sec';       StartTime = $metricStartTime;  EndTime = $metricEndTime; Interval = '00:15:00';  Aggregation = 'Maximum'; Measure = 'Average'; Id = $managedDisk.Id; SubName = $subscription.Name; ResourceGroup = $managedDisk.ResourceGroup; Name = $managedDisk.Name; Location = $managedDisk.Location; Service = 'Managed Disk'; Series = 'true' })
            $metricDefs.Add([PSCustomObject]@{ MetricIndex = $metricCountId++; MetricName = 'Composite Disk Write Bytes/sec';      StartTime = $metricStartTime;  EndTime = $metricEndTime; Interval = '00:15:00';  Aggregation = 'Maximum'; Measure = 'Average'; Id = $managedDisk.Id; SubName = $subscription.Name; ResourceGroup = $managedDisk.ResourceGroup; Name = $managedDisk.Name; Location = $managedDisk.Location; Service = 'Managed Disk'; Series = 'true' })
        }
    }

    #Define Storage Account Metrics

    $storageAccounts = $Resources | Where-Object { $_.TYPE -eq 'microsoft.storage/storageaccounts' }

    if($storageAccounts)
    {
        foreach ($storageAccount in $storageAccounts) 
         {
             $subscription = $subLookup[$storageAccount.subscriptionId]

             $metricDefs.Add([PSCustomObject]@{ MetricIndex = $metricCountId++; MetricName = 'UsedCapacity'; StartTime = $metricTimeOneDay;  EndTime = $metricEndTime; Interval = '01:00:00';  Aggregation = 'Maximum'; Measure = 'Largest'; Id = $storageAccount.Id; SubName = $subscription.Name; ResourceGroup = $storageAccount.ResourceGroup; Name = $storageAccount.Name; Location = $storageAccount.Location; Service = 'Storage Account'; Series = 'false' })                              
         }
    }

    #Define SQL Metrics

    $sqlDatabases = $Resources | Where-Object { $_.TYPE -eq 'microsoft.sql/servers/databases' -and $_.name -ne 'master' }

    if($sqlDatabases)
    {
        foreach ($sqlDb in $sqlDatabases) 
        {
            $subscription = $subLookup[$sqlDb.subscriptionId]
            
            if ($sqlDb.kind -match 'vcore') 
            {
                $metricDefs.Add([PSCustomObject]@{ MetricIndex = $metricCountId++; MetricName = 'cpu_limit'; StartTime = $metricTimeOneDay;  EndTime = $metricEndTime; Interval = '1.00:00:00';  Aggregation = 'Maximum'; Measure = 'Largest'; Id = $sqlDb.Id; SubName = $subscription.Name; ResourceGroup = $sqlDb.ResourceGroup; Name = $sqlDb.Name; Location = $sqlDb.Location; Service = 'SQL Database'; Series = 'false' })
                $metricDefs.Add([PSCustomObject]@{ MetricIndex = $metricCountId++; MetricName = 'cpu_used'; StartTime = $metricStartTime;  EndTime = $metricEndTime; Interval = '00:30:00';  Aggregation = 'Maximum'; Measure = 'Average'; Id = $sqlDb.Id; SubName = $subscription.Name; ResourceGroup = $sqlDb.ResourceGroup; Name = $sqlDb.Name; Location = $sqlDb.Location; Service = 'SQL Database'; Series = 'true' })             

                if ($sqlDb.kind -match 'serverless')
                {
                    $metricDefs.Add([PSCustomObject]@{ MetricIndex = $metricCountId++; MetricName = 'app_cpu_billed'; StartTime = $metricTimeOneDay;  EndTime = $metricEndTime; Interval = '0.00:01:00';  Aggregation = 'Total'; Measure = 'Sum'; Id = $sqlDb.Id; SubName = $subscription.Name; ResourceGroup = $sqlDb.ResourceGroup; Name = $sqlDb.Name; Location = $sqlDb.Location; Service = 'SQL Database'; Series = 'false' })
                }
            }
            else 
            {
                $metricDefs.Add([PSCustomObject]@{ MetricIndex = $metricCountId++; MetricName = 'dtu_limit'; StartTime = $metricTimeOneDay;  EndTime = $metricEndTime; Interval = '1.00:00:00';  Aggregation = 'Maximum'; Measure = 'Largest'; Id = $sqlDb.Id; SubName = $subscription.Name; ResourceGroup = $sqlDb.ResourceGroup; Name = $sqlDb.Name; Location = $sqlDb.Location; Service = 'SQL Database'; Series = 'false' })
                $metricDefs.Add([PSCustomObject]@{ MetricIndex = $metricCountId++; MetricName = 'dtu_used'; StartTime = $metricStartTime;  EndTime = $metricEndTime; Interval = '00:30:00';  Aggregation = 'Maximum'; Measure = 'Average'; Id = $sqlDb.Id; SubName = $subscription.Name; ResourceGroup = $sqlDb.ResourceGroup; Name = $sqlDb.Name; Location = $sqlDb.Location; Service = 'SQL Database'; Series = 'true' })
            }

            $metricDefs.Add([PSCustomObject]@{ MetricIndex = $metricCountId++; MetricName = 'cpu_percent'; StartTime = $metricStartTime;  EndTime = $metricEndTime; Interval = '00:30:00';  Aggregation = 'Maximum'; Measure = 'Largest'; Id = $sqlDb.Id; SubName = $subscription.Name; ResourceGroup = $sqlDb.ResourceGroup; Name = $sqlDb.Name; Location = $sqlDb.Location; Service = 'SQL Database'; Series = 'true' })
            $metricDefs.Add([PSCustomObject]@{ MetricIndex = $metricCountId++; MetricName = 'allocated_data_storage'; StartTime = $metricTimeOneDay;  EndTime = $metricEndTime; Interval = '1.00:00:00';  Aggregation = 'Average'; Measure = 'Largest'; Id = $sqlDb.Id; SubName = $subscription.Name; ResourceGroup = $sqlDb.ResourceGroup; Name = $sqlDb.Name; Location = $sqlDb.Location; Service = 'SQL Database'; Series = 'false' })
            
            $metricDefs.Add([PSCustomObject]@{ MetricIndex = $metricCountId++; MetricName = 'storage'; StartTime = $metricTimeOneDay;  EndTime = $metricEndTime; Interval = '1.00:00:00';  Aggregation = 'Maximum'; Measure = 'Largest'; Id = $sqlDb.Id; SubName = $subscription.Name; ResourceGroup = $sqlDb.ResourceGroup; Name = $sqlDb.Name; Location = $sqlDb.Location; Service = 'SQL Database'; Series = 'false' })
            $metricDefs.Add([PSCustomObject]@{ MetricIndex = $metricCountId++; MetricName = 'storage_percent'; StartTime = $metricTimeOneDay;  EndTime = $metricEndTime; Interval = '1.00:00:00';  Aggregation = 'Maximum'; Measure = 'Largest'; Id = $sqlDb.Id; SubName = $subscription.Name; ResourceGroup = $sqlDb.ResourceGroup; Name = $sqlDb.Name; Location = $sqlDb.Location; Service = 'SQL Database'; Series = 'false' })

            $metricDefs.Add([PSCustomObject]@{ MetricIndex = $metricCountId++; MetricName = 'physical_data_read_percent'; StartTime = $metricStartTime;  EndTime = $metricEndTime; Interval = '01:00:00';  Aggregation = 'Average'; Measure = 'Largest'; Id = $sqlDb.Id; SubName = $subscription.Name; ResourceGroup = $sqlDb.ResourceGroup; Name = $sqlDb.Name; Location = $sqlDb.Location; Service = 'SQL Database'; Series = 'false' })
            $metricDefs.Add([PSCustomObject]@{ MetricIndex = $metricCountId++; MetricName = 'log_write_percent'; StartTime = $metricStartTime;  EndTime = $metricEndTime; Interval = '01:00:00';  Aggregation = 'Average'; Measure = 'Largest'; Id = $sqlDb.Id; SubName = $subscription.Name; ResourceGroup = $sqlDb.ResourceGroup; Name = $sqlDb.Name; Location = $sqlDb.Location; Service = 'SQL Database'; Series = 'false' })
        }
    }

    # Define App Service Metrics

    $appServices = $Resources | Where-Object { $_.TYPE -eq 'microsoft.web/sites' }
    
    if($appServices)
    {
        foreach ($app in $appServices) 
        {
            $subscription = $subLookup[$app.subscriptionId]
            
            if ($app.kind -match 'functionapp') 
            {
                $metricDefs.Add([PSCustomObject]@{ MetricIndex = $metricCountId++; MetricName = 'FunctionExecutionCount'; StartTime = $metricStartTime;  EndTime = $metricEndTime; Interval = '1.00:00:00';  Aggregation = 'Total'; Measure = 'Sum'; Id = $app.Id; SubName = $subscription.Name; ResourceGroup = $app.ResourceGroup; Name = $app.Name; Location = $app.Location; Service = 'Functions'; Series = 'false' })
                $metricDefs.Add([PSCustomObject]@{ MetricIndex = $metricCountId++; MetricName = 'FunctionExecutionUnits'; StartTime = $metricStartTime;  EndTime = $metricEndTime; Interval = '1.00:00:00';  Aggregation = 'Total'; Measure = 'Sum'; Id = $app.Id; SubName = $subscription.Name; ResourceGroup = $app.ResourceGroup; Name = $app.Name; Location = $app.Location; Service = 'Functions'; Series = 'false'})              
            }
        }
    }

    # Define MariaDB Metrics

    $mariaDbs = $Resources | Where-Object { $_.TYPE -eq 'microsoft.dbformariadb/servers' }
    
    if($mariaDbs)
    {
        foreach ($mariaDb in $mariaDbs) 
        {
            $subscription = $subLookup[$mariaDb.subscriptionId]
            
            $metricDefs.Add([PSCustomObject]@{ MetricIndex = $metricCountId++; MetricName = 'cpu_percent'; StartTime = $metricStartTime;  EndTime = $metricEndTime; Interval = '01:00:00';  Aggregation = 'Maximum'; Measure = 'Maximum'; Id = $mariaDb.Id; SubName = $subscription.Name; ResourceGroup = $mariaDb.ResourceGroup; Name = $mariaDb.Name; Location = $mariaDb.Location; Service = 'MariaDB'; Series = 'true' })
            $metricDefs.Add([PSCustomObject]@{ MetricIndex = $metricCountId++; MetricName = 'memory_percent'; StartTime = $metricStartTime;  EndTime = $metricEndTime; Interval = '01:00:00';  Aggregation = 'Maximum'; Measure = 'Maximum'; Id = $mariaDb.Id; SubName = $subscription.Name; ResourceGroup = $mariaDb.ResourceGroup; Name = $mariaDb.Name; Location = $mariaDb.Location; Service = 'MariaDB'; Series = 'true' })
            $metricDefs.Add([PSCustomObject]@{ MetricIndex = $metricCountId++; MetricName = 'storage_percent'; StartTime = $metricTimeOneDay;  EndTime = $metricEndTime; Interval = '01:00:00';  Aggregation = 'Average'; Measure = 'Maximum'; Id = $mariaDb.Id; SubName = $subscription.Name; ResourceGroup = $mariaDb.ResourceGroup; Name = $mariaDb.Name; Location = $mariaDb.Location; Service = 'MariaDB'; Series = 'false' })
        }
    }

    # Define PostgreSQL Metrics

    $postgresDbs = $Resources | Where-Object { $_.TYPE -eq 'microsoft.dbforpostgresql/servers' }
    
    if($postgresDbs)
    {
        foreach ($postgreDb in $postgresDbs) 
        {
            $subscription = $subLookup[$postgreDb.subscriptionId]
            
            $metricDefs.Add([PSCustomObject]@{ MetricIndex = $metricCountId++; MetricName = 'cpu_percent'; StartTime = $metricStartTime;  EndTime = $metricEndTime; Interval = '01:00:00';  Aggregation = 'Maximum'; Measure = 'Maximum'; Id = $postgreDb.Id; SubName = $subscription.Name; ResourceGroup = $postgreDb.ResourceGroup; Name = $postgreDb.Name; Location = $postgreDb.Location; Service = 'PostgreSQL'; Series = 'true' })
            $metricDefs.Add([PSCustomObject]@{ MetricIndex = $metricCountId++; MetricName = 'memory_percent'; StartTime = $metricStartTime;  EndTime = $metricEndTime; Interval = '01:00:00';  Aggregation = 'Maximum'; Measure = 'Maximum'; Id = $postgreDb.Id; SubName = $subscription.Name; ResourceGroup = $postgreDb.ResourceGroup; Name = $postgreDb.Name; Location = $postgreDb.Location; Service = 'PostgreSQL'; Series = 'true' })
            $metricDefs.Add([PSCustomObject]@{ MetricIndex = $metricCountId++; MetricName = 'storage_percent'; StartTime = $metricTimeOneDay;  EndTime = $metricEndTime; Interval = '01:00:00';  Aggregation = 'Average'; Measure = 'Maximum'; Id = $postgreDb.Id; SubName = $subscription.Name; ResourceGroup = $postgreDb.ResourceGroup; Name = $postgreDb.Name; Location = $postgreDb.Location; Service = 'PostgreSQL'; Series = 'false' })
        }
    }

    # Define MySQL Metrics

    $mySqldbs = $Resources | Where-Object { $_.TYPE -eq 'microsoft.DBforMySQL/servers' }
    
    if($mySqldbs)
    {
        foreach ($mysqlDb in $mySqldbs) 
        {
            $subscription = $subLookup[$mysqlDb.subscriptionId]
            
            $metricDefs.Add([PSCustomObject]@{ MetricIndex = $metricCountId++; MetricName = 'cpu_percent'; StartTime = $metricStartTime;  EndTime = $metricEndTime; Interval = '01:00:00';  Aggregation = 'Maximum'; Measure = 'Maximum'; Id = $mysqlDb.Id; SubName = $subscription.Name; ResourceGroup = $mysqlDb.ResourceGroup; Name = $mysqlDb.Name; Location = $mysqlDb.Location; Service = 'MySQL'; Series = 'true' })
            $metricDefs.Add([PSCustomObject]@{ MetricIndex = $metricCountId++; MetricName = 'memory_percent'; StartTime = $metricStartTime;  EndTime = $metricEndTime; Interval = '01:00:00';  Aggregation = 'Maximum'; Measure = 'Maximum'; Id = $mysqlDb.Id; SubName = $subscription.Name; ResourceGroup = $mysqlDb.ResourceGroup; Name = $mysqlDb.Name; Location = $mysqlDb.Location; Service = 'MySQL'; Series = 'true' })
            $metricDefs.Add([PSCustomObject]@{ MetricIndex = $metricCountId++; MetricName = 'storage_percent'; StartTime = $metricTimeOneDay;  EndTime = $metricEndTime; Interval = '01:00:00';  Aggregation = 'Average'; Measure = 'Maximum'; Id = $mysqlDb.Id; SubName = $subscription.Name; ResourceGroup = $mysqlDb.ResourceGroup; Name = $mysqlDb.Name; Location = $mysqlDb.Location; Service = 'MySQL'; Series = 'false' })
        }
    }

    # Define MySQL Flexible Metrics

    $mySqldbs = $Resources | Where-Object { $_.TYPE -eq 'microsoft.DBforMySQL/flexibleServers' }
    
    if($mySqldbs)
    {
        foreach ($mysqlDb in $mySqldbs) 
        {
            $subscription = $subLookup[$mysqlDb.subscriptionId]
            
            $metricDefs.Add([PSCustomObject]@{ MetricIndex = $metricCountId++; MetricName = 'cpu_percent'; StartTime = $metricStartTime;  EndTime = $metricEndTime; Interval = '01:00:00';  Aggregation = 'Maximum'; Measure = 'Maximum'; Id = $mysqlDb.Id; SubName = $subscription.Name; ResourceGroup = $mysqlDb.ResourceGroup; Name = $mysqlDb.Name; Location = $mysqlDb.Location; Service = 'MySQL Flexible'; Series = 'true' })
            $metricDefs.Add([PSCustomObject]@{ MetricIndex = $metricCountId++; MetricName = 'memory_percent'; StartTime = $metricStartTime;  EndTime = $metricEndTime; Interval = '01:00:00';  Aggregation = 'Maximum'; Measure = 'Maximum'; Id = $mysqlDb.Id; SubName = $subscription.Name; ResourceGroup = $mysqlDb.ResourceGroup; Name = $mysqlDb.Name; Location = $mysqlDb.Location; Service = 'MySQL Flexible'; Series = 'true' })
            $metricDefs.Add([PSCustomObject]@{ MetricIndex = $metricCountId++; MetricName = 'storage_percent'; StartTime = $metricTimeOneDay;  EndTime = $metricEndTime; Interval = '01:00:00';  Aggregation = 'Average'; Measure = 'Maximum'; Id = $mysqlDb.Id; SubName = $subscription.Name; ResourceGroup = $mysqlDb.ResourceGroup; Name = $mysqlDb.Name; Location = $mysqlDb.Location; Service = 'MySQL Flexible'; Series = 'false' })
        }
    }

    # Define PostgreSQL Flexible Metrics

    $postgresDbs = $Resources | Where-Object { $_.TYPE -eq 'microsoft.DBforPostgreSQL/flexibleServers' }
    
    if($postgresDbs)
    {
        foreach ($postgreDb in $postgresDbs) 
        {
            $subscription = $subLookup[$postgreDb.subscriptionId]
            
            $metricDefs.Add([PSCustomObject]@{ MetricIndex = $metricCountId++; MetricName = 'cpu_percent'; StartTime = $metricStartTime;  EndTime = $metricEndTime; Interval = '01:00:00';  Aggregation = 'Maximum'; Measure = 'Maximum'; Id = $postgreDb.Id; SubName = $subscription.Name; ResourceGroup = $postgreDb.ResourceGroup; Name = $postgreDb.Name; Location = $postgreDb.Location; Service = 'PostgreSQL Flexible'; Series = 'true' })
            $metricDefs.Add([PSCustomObject]@{ MetricIndex = $metricCountId++; MetricName = 'memory_percent'; StartTime = $metricStartTime;  EndTime = $metricEndTime; Interval = '01:00:00';  Aggregation = 'Maximum'; Measure = 'Maximum'; Id = $postgreDb.Id; SubName = $subscription.Name; ResourceGroup = $postgreDb.ResourceGroup; Name = $postgreDb.Name; Location = $postgreDb.Location; Service = 'PostgreSQL Flexible'; Series = 'true' })
            $metricDefs.Add([PSCustomObject]@{ MetricIndex = $metricCountId++; MetricName = 'storage_percent'; StartTime = $metricTimeOneDay;  EndTime = $metricEndTime; Interval = '01:00:00';  Aggregation = 'Average'; Measure = 'Maximum'; Id = $postgreDb.Id; SubName = $subscription.Name; ResourceGroup = $postgreDb.ResourceGroup; Name = $postgreDb.Name; Location = $postgreDb.Location; Service = 'PostgreSQL Flexible'; Series = 'false' })
        }
    }

    # Define Scale Set Metrics

    $vmScaleSets = $Resources | Where-Object { $_.TYPE -eq 'microsoft.compute/virtualmachinescalesets' }
    
    if($vmScaleSets)
    {
        foreach ($vmss in $vmScaleSets) 
        {
            $subscription = $subLookup[$vmss.subscriptionId]
            
            $metricDefs.Add([PSCustomObject]@{ MetricIndex = $metricCountId++; MetricName = 'Percentage CPU'; StartTime = $metricStartTime;  EndTime = $metricEndTime; Interval = '01:00:00';  Aggregation = 'Maximum'; Measure = 'Average'; Id = $vmss.Id; SubName = $subscription.Name; ResourceGroup = $vmss.ResourceGroup; Name = $vmss.Name; Location = $vmss.Location; Service = 'Virtual Machines Scale Sets'; Series = 'false' })
            $metricDefs.Add([PSCustomObject]@{ MetricIndex = $metricCountId++; MetricName = 'Available Memory Bytes'; StartTime = $metricStartTime;  EndTime = $metricEndTime; Interval = '01:00:00';  Aggregation = 'Minimum'; Measure = 'Average'; Id = $vmss.Id; SubName = $subscription.Name; ResourceGroup = $vmss.ResourceGroup; Name = $vmss.Name; Location = $vmss.Location; Service = 'Virtual Machines Scale Sets'; Series = 'false' })
        }
    }

    # Define CosmosDB Metrics

    $cosmosDbs = $Resources | Where-Object { $_.TYPE -eq 'microsoft.documentdb/databaseaccounts' }
    
    if($cosmosDbs)
    {
        foreach ($cosmosDb in $cosmosDbs) 
        {
            $subscription = $subLookup[$cosmosDb.subscriptionId]

            $metricDefs.Add([PSCustomObject]@{ MetricIndex = $metricCountId++; MetricName = 'TotalRequests'; StartTime = $metricTimeOneDay;  EndTime = $metricEndTime; Interval = '00:01:00';  Aggregation = 'Count'; Measure = 'Largest'; Id = $cosmosDb.Id; SubName = $subscription.Name; ResourceGroup = $cosmosDb.ResourceGroup; Name = $cosmosDb.Name; Location = $cosmosDb.Location; Service = 'CosmosDB'; Series = 'false' })
            $metricDefs.Add([PSCustomObject]@{ MetricIndex = $metricCountId++; MetricName = 'TotalRequestUnits'; StartTime = $metricTimeOneDay;  EndTime = $metricEndTime; Interval = '00:01:00';  Aggregation = 'Total'; Measure = 'Sum'; Id = $cosmosDb.Id; SubName = $subscription.Name; ResourceGroup = $cosmosDb.ResourceGroup; Name = $cosmosDb.Name; Location = $cosmosDb.Location; Service = 'CosmosDB'; Series = 'false' })
            $metricDefs.Add([PSCustomObject]@{ MetricIndex = $metricCountId++; MetricName = 'DataUsage'; StartTime = $metricTimeOneDay;  EndTime = $metricEndTime; Interval = '01:00:00';  Aggregation = 'Total'; Measure = 'Largest'; Id = $cosmosDb.Id; SubName = $subscription.Name; ResourceGroup = $cosmosDb.ResourceGroup; Name = $cosmosDb.Name; Location = $cosmosDb.Location; Service = 'CosmosDB'; Series = 'false' })
            $metricDefs.Add([PSCustomObject]@{ MetricIndex = $metricCountId++; MetricName = 'ProvisionedThroughput'; StartTime = $metricTimeOneDay;  EndTime = $metricEndTime; Interval = '01:00:00';  Aggregation = 'Maximum'; Measure = 'Largest'; Id = $cosmosDb.Id; SubName = $subscription.Name; ResourceGroup = $cosmosDb.ResourceGroup; Name = $cosmosDb.Name; Location = $cosmosDb.Location; Service = 'CosmosDB'; Series = 'false' })
        }
    }

    # Define Container Registry Metrics

    $containerRegistry = $Resources | Where-Object { $_.TYPE -eq 'microsoft.containerregistry/registries' }
    
    if($containerRegistry)
    {
        foreach ($registry in $containerRegistry) 
        {
            $subscription = $subLookup[$registry.subscriptionId]

            $metricDefs.Add([PSCustomObject]@{ MetricIndex = $metricCountId++; MetricName = 'StorageUsed'; StartTime = $metricTimeOneDay;  EndTime = $metricEndTime; Interval = '01:00:00';  Aggregation = 'Maximum'; Measure = 'Largest'; Id = $registry.Id; SubName = $subscription.Name; ResourceGroup = $registry.ResourceGroup; Name = $registry.Name; Location = $registry.Location; Service = 'ContainerRegistry'; Series = 'false' })
        }
    }
    

    $metricCount = $metricDefs.Count

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
    $metricAzContext = $null
    try
    {
        $metricAzContext = (Get-AzContext)
    }
    catch
    {
        # The Azure PowerShell module (Az) has a built-in feature that saves your login tokens to a secure file on your local hard drive. 
        # When a new, blank runspace spins up, Azure PowerShell will automatically look at this local file to log itself in.
        Write-Host "[Metrics] WARNING: could not capture Az context for parallel runspaces; metric calls will rely on per-runspace context autosave." -ForegroundColor Yellow
    }

    # Resilience knobs for the per-call Get-AzMetric wrapper. These are stable
    # internals rather than script parameters: a 120s client-side timeout per
    # call and up to 3 retries (exponential backoff) handles transient ARM
    # throttling/hangs without exposing extra knobs to the operator. Adjust here
    # if Azure Monitor behaviour changes; they were deliberately NOT promoted to
    # parameters to keep the script surface small.
    $metricTimeoutSeconds = 120
    $metricMaxRetries     = 3

    # Thread-safe diagnostics: each parallel runspace appends one record so the
    # parent can summarise where time went and which calls timed out / were
    # throttled / errored. This is the "where exactly is it getting stuck"
    # instrumentation - it survives the runspace boundary via $using.
    $metricDiagnostics = [System.Collections.Concurrent.ConcurrentBag[psobject]]::new()

    $phaseStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Host ("[Metrics] Starting metrics collection: {0} metric definition(s), ThrottleLimit={1}, per-call timeout={2}s, max retries={3}, lookback={4} day(s)." -f $metricCount, $ConcurrencyLimit, $metricTimeoutSeconds, $metricMaxRetries, [math]::Abs($metricsLookbackPeriodDays)) -ForegroundColor Cyan

    $rangeBatch = [math]::Min($metricCount , 250)
    $rangeIdx = 1
    $metricsProcessed = 0
    $defs = [System.Collections.Generic.List[object]]::new()

    for($i = 0; $i -lt $metricCount; $i++)    
    {
        $defs.Add($metricDefs[$i])
        $metricsProcessed++

        if($defs.Count -ge $rangeBatch -or $metricsProcessed -ge $metricCount)
        {
            $batchStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            Write-Host ("[Metrics] Batch {0}: dispatching {1} metric call(s) (processed {2}/{3})." -f $rangeIdx, $defs.Count, $metricsProcessed, $metricCount) -ForegroundColor Cyan

            $defs | ForEach-Object -Parallel {
                $totalCount = $using:metricCount
                $azContext            = $using:metricAzContext
                $callTimeoutSeconds   = $using:metricTimeoutSeconds
                $callMaxRetries       = $using:metricMaxRetries
                $diagBag              = $using:metricDiagnostics

                # Per-call progress was previously written to the console with
                # Write-Host for EVERY metric definition (thousands per sub). From
                # concurrent runspaces that flood is what made the terminal appear
                # frozen until a keypress forced a repaint. The per-call outcome
                # (including this "processing" detail) is still recorded in
                # $diagBag below and surfaced in the end-of-phase diagnostics
                # summary, so nothing is lost from the log - only the live console
                # spam is removed. Warnings (retry) and errors (giving up) below
                # are intentionally kept on the console.

                #$metricQuery = (az monitor metrics list --resource $_.Id --metric $_.MetricName --start-time $_.StartTime  --end-time $_.EndTime --interval $_.Interval --aggregation $_.Aggregation | ConvertFrom-Json)
    
                $metricError = $false
                $metricName = $_.MetricName
                $metricId = $_.Id
                $metricService = $_.Service

                # Per-call diagnostics: outcome is one of Success / Timeout /
                # Throttled / Error and is reported back to the parent so the
                # metrics phase can show exactly which calls stalled.
                $callStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                $callOutcome   = 'Success'
                $callAttempts  = 0
                $callErrorMsg  = $null

                # Common args for every attempt. -DefaultProfile forces the call
                # to use the parent's captured Az context instead of relying on
                # the fresh runspace inheriting a session (which it does not).
                $metricArgs = @{
                    ResourceId      = $_.Id
                    MetricName      = $_.MetricName
                    StartTime       = $_.StartTime
                    EndTime         = $_.EndTime
                    TimeGrain       = $_.Interval
                    AggregationType = $_.Aggregation
                    ErrorAction     = 'Stop'
                    WarningAction   = 'SilentlyContinue'
                }
                if ($null -ne $azContext)
                {
                    $metricArgs['DefaultProfile'] = $azContext
                }

                try 
                {
                    # Retry loop with exponential backoff. Attempt 0 is the first
                    # try; up to $callMaxRetries additional attempts follow. Each
                    # attempt is bounded by a client-side timeout implemented with
                    # a thread job so a single hung HTTP call can never wedge the
                    # whole metrics phase the way an un-timed Get-AzMetric can.
                    $attempt = 0
                    $succeeded = $false
                    $lastError = $null
                    $metricQuery = $null

                    while (-not $succeeded -and $attempt -le $callMaxRetries)
                    {
                        $callAttempts = $attempt + 1
                        $attemptStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                        $timedOut = $false
                        $throttled = $false

                        $job = Start-ThreadJob -ScriptBlock {
                            param($mArgs)
                            Get-AzMetric @mArgs
                        } -ArgumentList $metricArgs

                        if (Wait-Job -Job $job -Timeout $callTimeoutSeconds)
                        {
                            try
                            {
                                $metricQuery = Receive-Job -Job $job -ErrorAction Stop
                                $succeeded = $true
                            }
                            catch
                            {
                                $lastError = $_.Exception.Message
                                if ($lastError -match '429|throttl|TooManyRequests|rate limit')
                                {
                                    $throttled = $true
                                }
                            }
                            finally
                            {
                                Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
                            }
                        }
                        else
                        {
                            # Timed out: stop the hung job and treat as a failed attempt.
                            $timedOut = $true
                            $lastError = ("Timed out after {0}s" -f $callTimeoutSeconds)
                            Stop-Job -Job $job -ErrorAction SilentlyContinue
                            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
                        }

                        $attemptStopwatch.Stop()

                        if ($succeeded)
                        {
                            # Per-call success was previously logged to the console
                            # (one DarkGreen line per metric). Removed to stop the
                            # concurrent-runspace console flood; the success is still
                            # recorded in $diagBag below (Outcome='Success') and
                            # counted in the end-of-phase summary. The break MUST stay
                            # - it is the retry-loop exit on a successful call.
                            break
                        }

                        # Failed attempt - decide whether to retry.
                        $reason = if ($timedOut) { 'TIMEOUT' } elseif ($throttled) { 'THROTTLED' } else { 'ERROR' }
                        if ($attempt -lt $callMaxRetries)
                        {
                            # Exponential backoff: 2^attempt seconds, capped, plus
                            # jitter so a wave of throttled calls does not retry in
                            # lockstep. Throttled calls wait a bit longer.
                            $backoff = [math]::Min([math]::Pow(2, $attempt), 30)
                            if ($throttled) { $backoff = [math]::Min($backoff * 2, 60) }
                            $jitter = (Get-Random -Minimum 0 -Maximum 1000) / 1000.0
                            $sleepSeconds = [math]::Round($backoff + $jitter, 2)
                            Write-Host ("[Metrics]   {0} idx={1} attempt={2} ({3}) - retrying in {4}s. {5}/{6}" -f $reason, $_.MetricIndex, $callAttempts, $lastError, $sleepSeconds, $metricService, $metricName) -ForegroundColor Yellow
                            Start-Sleep -Seconds $sleepSeconds
                        }
                        else
                        {
                            Write-Host ("[Metrics]   {0} idx={1} attempt={2} ({3}) - giving up after {4} attempt(s). {5}/{6}" -f $reason, $_.MetricIndex, $callAttempts, $lastError, $callAttempts, $metricService, $metricName) -ForegroundColor Red
                            $callOutcome = if ($timedOut) { 'Timeout' } elseif ($throttled) { 'Throttled' } else { 'Error' }
                        }

                        $attempt++
                    }

                    if (-not $succeeded)
                    {
                        throw ("Get-AzMetric failed after {0} attempt(s): {1}" -f $callAttempts, $lastError)
                    }

                    # Total interval count Azure Monitor returned for this metric,
                    # including intervals that carry no datapoint. This is the
                    # denominator for coverage / %TimeOn-style derivations: for a VM's
                    # 'Percentage CPU' series, MetricCount / MetricTotalCount * 100 is
                    # the fraction of the window the VM was actually running (%TimeOn).
                    # Captured here, before the Measure switch below collapses
                    # $metricQueryResults to a scalar.
                    $metricTotalCount = @($metricQuery.Data).Count

                    $metricQueryResults = 0
                    $metricTimeSeries = 0
            
                    switch ($_.Aggregation)
                    {
                        'Average'   
                            { 
                                $metricQueryResults = $metricQuery.Data.Average
                            }
                        'Maximum'   
                            { 
                                $metricQueryResults = $metricQuery.Data.Maximum 
                            }
                        'Count'     
                            { 
                                $metricQueryResults = $metricQuery.Data.Count 
                            }
                        'Total'     
                            { 
                                $metricQueryResults = $metricQuery.Data.Total 
                            }
                        'Minimum'   
                            { 
                                $metricQueryResults = $metricQuery.Data.Minimum 
                            }
                    }
            
                    $metricQueryResultsCount = ($metricQueryResults.Where({$_ -ne $null}).Count)
            
                    if($metricQueryResultsCount -eq 0)
                    {
                        $metricQueryResults = 0
                        $metricQueryResultsCount = 0
                        $metricPercentileIndex = 0
                        $metricPercentile = 0
                    }
                    else
                    {
                        $metricQueryResultsSorted = $metricQueryResults | Sort-Object
                        $metricPercentileIndex = [math]::Ceiling(0.95 * $metricQueryResultsSorted.Count) - 1
                        $metricPercentile = $metricQueryResultsSorted[$metricPercentileIndex]
            
                        if ($_.Series -eq 'true')
                        {                
                            $metricTimeSeries = $metricQueryResults.Where({$_ -ne $null})
                        }
                        
                        switch ($_.Measure)
                        {
                            'Average'   { $metricQueryResults = ($metricQueryResults | Measure-Object -Average).Average }
                            'Maximum'   { $metricQueryResults = ($metricQueryResults | Measure-Object -Maximum).Maximum }
                            'Sum'       { $metricQueryResults = ($metricQueryResults | Measure-Object -Sum).Sum }
                            'Minimum'   { $metricQueryResults = ($metricQueryResults | Measure-Object -Minimum).Minimum }
                            'Largest'   { $metricQueryResults = ($metricQueryResults | Sort-Object -Descending)[0] }
                        }
                    }
                }
                catch 
                {
                    $metricQueryResults = 0
                    $metricQueryResultsCount = 0
                    $metricTotalCount = 0
                    $metricPercentileIndex = 0
                    $metricPercentile = 0
    
                    $metricError = $true
                    if ($callOutcome -eq 'Success') { $callOutcome = 'Error' }
                    $callErrorMsg = $_.Exception.Message
                    #Write-Error $metricError
                    Write-Error ("Error collecting Metric: {0}-{1}-{2} ({3})" -f $metricId, $metricService, $metricName, $callErrorMsg)
                }

                $callStopwatch.Stop()
                $diagBag.Add([PSCustomObject]@{
                    MetricIndex = $_.MetricIndex
                    Service     = $metricService
                    Name        = $_.Name
                    Metric      = $metricName
                    Interval    = $_.Interval
                    Outcome     = $callOutcome
                    Attempts    = $callAttempts
                    ElapsedSec  = [math]::Round($callStopwatch.Elapsed.TotalSeconds, 2)
                    Error       = $callErrorMsg
                })
    
                
                $obj = @{
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
                    'MetricPercentile'     = $metricPercentile;
                    'MetricValue'          = $metricQueryResults;
                    'MetricCount'          = $metricQueryResultsCount;
                    'MetricTotalCount'     = $metricTotalCount;
                    'MetricSeries'         = $metricTimeSeries;
                    'MetricError'          = $metricError;
                }
                
                ($using:tmp).Metrics.Add($obj)
    
                $metricQuery = $null
                $metricQueryResults = $null
                $metricQueryResultsCount = $null
                $metricTotalCount = $null
                $metricTimeSeries = $null
                $metricQueryResultsSorted = $null
                $metricPercentile = $null;
    
            } -ThrottleLimit $ConcurrencyLimit

            $defs.Clear()

            $batchStopwatch.Stop()
            Write-Host ("[Metrics] Batch {0} complete in {1}s. Cumulative diagnostics: {2} call record(s) so far." -f $rangeIdx, [math]::Round($batchStopwatch.Elapsed.TotalSeconds, 1), $metricDiagnostics.Count) -ForegroundColor Cyan

            if($Obfuscate)
            {
                foreach ($metric in $tmp.Metrics) 
                {
                    $originalId = $metric.ID
                    if (![string]::IsNullOrEmpty($originalId) -and $ResourceIdDictionary.ContainsKey($originalId)) {
                        $metric.ID = $ResourceIdDictionary[$originalId]
                        $metric.Name = $ResourceNameDictionary[$originalId]
                        $metric.Subscription = $ResourceSubDictionary[$originalId]
                        $metric.ResourceGroup = $ResourceGroupDictionary[$originalId]
                    } else {
                        # Fallback: resource not in main dictionary (e.g., deleted/transient resource)
                        # Cache the obfuscated value so same resource correlates across metrics
                        if (![string]::IsNullOrEmpty($originalId)) {
                            $fbPrefix = if ($originalId -match '\b(dev|test|qa|tst|development|non-prod|uat|nonprod)\b') { 'nonprod_' } else { 'prod_' }
                            $ResourceIdDictionary[$originalId] = $fbPrefix + [guid]::NewGuid().ToString()
                            $ResourceNameDictionary[$originalId] = $fbPrefix + [guid]::NewGuid().ToString()
                            $ResourceSubDictionary[$originalId] = $fbPrefix + 'sub_' + [guid]::NewGuid().ToString()
                            $ResourceGroupDictionary[$originalId] = $fbPrefix + 'rg_' + [guid]::NewGuid().ToString()
                            $metric.ID = $ResourceIdDictionary[$originalId]
                            $metric.Name = $ResourceNameDictionary[$originalId]
                            $metric.Subscription = $ResourceSubDictionary[$originalId]
                            $metric.ResourceGroup = $ResourceGroupDictionary[$originalId]
                        }
                    }
                }
            }

            $outputPath = $FilePath + "_" + $rangeIdx + ".json"
            $tmp | ConvertTo-Json -depth 5 -compress | Out-File $outputPath -Encoding utf8
            $tmp.Metrics.Clear()

            $rangeIdx++
        }
    }

    $phaseStopwatch.Stop()

    # ---------------------------------------------------------------------
    # Metrics phase summary - the "where did it get stuck" report.
    # Groups every per-call diagnostic record by outcome, and surfaces the
    # slowest calls so a hang or throttling hotspot is obvious at a glance.
    # ---------------------------------------------------------------------
    $diagRecords = @($metricDiagnostics)
    $okCount        = @($diagRecords | Where-Object { $_.Outcome -eq 'Success' }).Count
    $timeoutCount   = @($diagRecords | Where-Object { $_.Outcome -eq 'Timeout' }).Count
    $throttledCount = @($diagRecords | Where-Object { $_.Outcome -eq 'Throttled' }).Count
    $errorCount     = @($diagRecords | Where-Object { $_.Outcome -eq 'Error' }).Count

    Write-Host ("[Metrics] ===== Metrics phase summary =====") -ForegroundColor Cyan
    Write-Host ("[Metrics] Total calls: {0} | Success: {1} | Timeout: {2} | Throttled: {3} | Error: {4} | Elapsed: {5}s" -f $diagRecords.Count, $okCount, $timeoutCount, $throttledCount, $errorCount, [math]::Round($phaseStopwatch.Elapsed.TotalSeconds, 1)) -ForegroundColor Cyan

    if (($timeoutCount + $throttledCount + $errorCount) -gt 0)
    {
        Write-Host ("[Metrics] Non-success calls (where it got stuck):") -ForegroundColor Yellow
        foreach ($rec in ($diagRecords | Where-Object { $_.Outcome -ne 'Success' } | Sort-Object ElapsedSec -Descending))
        {
            Write-Host ("[Metrics]   {0} idx={1} {2}/{3}/{4} interval={5} attempts={6} {7}s {8}" -f $rec.Outcome, $rec.MetricIndex, $rec.Service, $rec.Name, $rec.Metric, $rec.Interval, $rec.Attempts, $rec.ElapsedSec, $rec.Error) -ForegroundColor Yellow
        }
    }

    if ($diagRecords.Count -gt 0)
    {
        $slowest = $diagRecords | Sort-Object ElapsedSec -Descending | Select-Object -First 5
        Write-Host ("[Metrics] Slowest 5 calls:") -ForegroundColor Cyan
        foreach ($rec in $slowest)
        {
            Write-Host ("[Metrics]   {0}s idx={1} {2}/{3}/{4} interval={5} ({6})" -f $rec.ElapsedSec, $rec.MetricIndex, $rec.Service, $rec.Name, $rec.Metric, $rec.Interval, $rec.Outcome) -ForegroundColor Cyan
        }
    }

    $WarningPreference = "Continue"

    $metricDefs = $null;
}
