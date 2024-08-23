param($Subscriptions, $Resources, $Task ,$File, $Metrics, $TableStyle, $ConcurrencyLimit, $FilePath)

if ($Task -eq 'Processing')
{
    $tmp = New-Object PSObject
    $tmp | Add-Member -MemberType NoteProperty -Name Metrics -Value NotSet
    $tmp.Metrics = [System.Collections.Concurrent.ConcurrentBag[psobject]]::new()

    $metricDefs = [System.Collections.Generic.List[object]]::new()

    $metricsLookbackPeriodDays = -31
    $metricStartTime = (Get-Date).AddDays($metricsLookbackPeriodDays)
    $metricEndTime = (Get-Date)

    $metricTimeOneDay = (Get-Date).AddDays(-1)
    $metricTimeSevenDay = (Get-Date).AddDays(-7)

    # Define VM Metrics
    $virtualMachines =  $Resources | Where-Object {$_.TYPE -eq 'microsoft.compute/virtualmachines'}

    $metricCountId = 1;

    if($virtualMachines)
    {
        foreach ($virtualMachine in $virtualMachines) 
        {
            $subscription = $Subscriptions | Where-Object { $_.id -eq $virtualMachine.subscriptionId }
            $metricDefs.Add([PSCustomObject]@{ MetricIndex = $metricCountId++; MetricName = 'Percentage CPU'; StartTime = $metricStartTime;  EndTime = $metricEndTime; Interval = '00:15:00';  Aggregation = 'Maximum'; Measure = 'Average'; Id = $virtualMachine.Id; SubName = $subscription.Name; ResourceGroup = $virtualMachine.ResourceGroup; Name = $virtualMachine.Name; Location = $virtualMachine.Location; Service = 'Virtual Machines'; Series = 'true' })
            $metricDefs.Add([PSCustomObject]@{ MetricIndex = $metricCountId++; MetricName = 'Available Memory Bytes'; StartTime = $metricStartTime;  EndTime = $metricEndTime; Interval = '00:15:00';  Aggregation = 'Minimum'; Measure = 'Average'; Id = $virtualMachine.Id; SubName = $subscription.Name; ResourceGroup = $virtualMachine.ResourceGroup; Name = $virtualMachine.Name; Location = $virtualMachine.Location; Service = 'Virtual Machines'; Series = 'true' })
        }
    }

    #Define Storage Account Metrics

    $storageAccounts = $Resources | Where-Object { $_.TYPE -eq 'microsoft.storage/storageaccounts' }

    if($storageAccounts)
    {
        foreach ($storageAccount in $storageAccounts) 
         {
             $subscription = $Subscriptions | Where-Object { $_.id -eq $storageAccount.subscriptionId }

             $metricDefs.Add([PSCustomObject]@{ MetricIndex = $metricCountId++; MetricName = 'UsedCapacity'; StartTime = $metricTimeOneDay;  EndTime = $metricEndTime; Interval = '01:00:00';  Aggregation = 'Maximum'; Measure = 'Largest'; Id = $storageAccount.Id; SubName = $subscription.Name; ResourceGroup = $storageAccount.ResourceGroup; Name = $storageAccount.Name; Location = $storageAccount.Location; Service = 'Storage Account'; Series = 'false' })                              
         }
    }

    #Define SQL Metrics

    $sqlDatabases = $Resources | Where-Object { $_.TYPE -eq 'microsoft.sql/servers/databases' -and $_.name -ne 'master' }

    if($sqlDatabases)
    {
        foreach ($sqlDb in $sqlDatabases) 
        {
            $subscription = $Subscriptions | Where-Object { $_.id -eq $sqlDb.subscriptionId }
            
            if ($sqlDb.kind.Contains("vcore")) 
            {
                $metricDefs.Add([PSCustomObject]@{ MetricIndex = $metricCountId++; MetricName = 'cpu_limit'; StartTime = $metricTimeOneDay;  EndTime = $metricEndTime; Interval = '1.00:00:00';  Aggregation = 'Maximum'; Measure = 'Largest'; Id = $sqlDb.Id; SubName = $subscription.Name; ResourceGroup = $sqlDb.ResourceGroup; Name = $sqlDb.Name; Location = $sqlDb.Location; Service = 'SQL Database'; Series = 'false' })
                $metricDefs.Add([PSCustomObject]@{ MetricIndex = $metricCountId++; MetricName = 'cpu_used'; StartTime = $metricStartTime;  EndTime = $metricEndTime; Interval = '00:30:00';  Aggregation = 'Maximum'; Measure = 'Average'; Id = $sqlDb.Id; SubName = $subscription.Name; ResourceGroup = $sqlDb.ResourceGroup; Name = $sqlDb.Name; Location = $sqlDb.Location; Service = 'SQL Database'; Series = 'true' })             

                if ($sqlDb.kind.Contains("serverless"))
                {
                    $metricDefs.Add([PSCustomObject]@{ MetricIndex = $metricCountId++; MetricName = 'app_cpu_billed'; StartTime = $metricStartTime;  EndTime = $metricEndTime; Interval = '0.00:01:00';  Aggregation = 'Total'; Measure = 'Sum'; Id = $sqlDb.Id; SubName = $subscription.Name; ResourceGroup = $sqlDb.ResourceGroup; Name = $sqlDb.Name; Location = $sqlDb.Location; Service = 'SQL Database'; Series = 'false' })
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
            $subscription = $Subscriptions | Where-Object { $_.id -eq $app.subscriptionId }
            
            if ($app.kind.Contains("functionapp")) 
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
            $subscription = $Subscriptions | Where-Object { $_.id -eq $mariaDb.subscriptionId }
            
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
            $subscription = $Subscriptions | Where-Object { $_.id -eq $postgreDb.subscriptionId }
            
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
            $subscription = $Subscriptions | Where-Object { $_.id -eq $mysqlDb.subscriptionId }
            
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
            $subscription = $Subscriptions | Where-Object { $_.id -eq $mysqlDb.subscriptionId }
            
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
            $subscription = $Subscriptions | Where-Object { $_.id -eq $postgreDb.subscriptionId }
            
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
            $subscription = $Subscriptions | Where-Object { $_.id -eq $vmss.subscriptionId }
            
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
            $subscription = $Subscriptions | Where-Object { $_.id -eq $cosmosDb.subscriptionId }

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
            $subscription = $Subscriptions | Where-Object { $_.id -eq $registry.subscriptionId }

            $metricDefs.Add([PSCustomObject]@{ MetricIndex = $metricCountId++; MetricName = 'StorageUsed'; StartTime = $metricTimeOneDay;  EndTime = $metricEndTime; Interval = '01:00:00';  Aggregation = 'Average'; Measure = 'Largest'; Id = $registry.Id; SubName = $subscription.Name; ResourceGroup = $registry.ResourceGroup; Name = $registry.Name; Location = $registry.Location; Service = 'ContainerRegistry'; Series = 'false' })
        }
    }
    

    $metricCount = $metricDefs.Count

    $WarningPreference = "SilentlyContinue"

    $rangeBatch = [math]::Min($metricCount , 250)
    $rangeIdx = 1
    $metricsProcessed = 0
    $defs = [System.Collections.Generic.List[object]]::new()

    for($i = 0; $i -lt $metricCount; $i++)    
    {
        $defs.Add($metricDefs[$i])
        $metricsProcessed++

        if($defs.Count -ge $rangeBatch -or $i -ge $metricCount -or $metricsProcessed -ge $metricCount)
        {
            Write-Host ("Writing Metrics File Batch: " + $defs.Count)

            $defs | ForEach-Object -Parallel {
                $totalCount = $using:metricCount
    
                Write-Host ("{0}/{1} Processing {2} Metrics: {3}-{4}-{5}-{6}" -f $_.MetricIndex, $totalCount, $_.Service, $_.Name, $_.MetricName, $_.Aggregation, $_.Interval) -BackgroundColor Black -ForegroundColor Green
    
                #$metricQuery = (az monitor metrics list --resource $_.Id --metric $_.MetricName --start-time $_.StartTime  --end-time $_.EndTime --interval $_.Interval --aggregation $_.Aggregation | ConvertFrom-Json)
    
                $metricError = 'None'
                $metricName = $_.MetricName
                $metricId = $_.Id
                $metricService = $_.Service
    
                try 
                {
                    $metricQuery = (Get-AzMetric -ResourceId $_.Id -MetricName $_.MetricName -StartTime $_.StartTime -EndTime $_.EndTime -TimeGrain $_.Interval -AggregationType $_.Aggregation -ErrorAction Stop)
    
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
                    $metricPercentileIndex = 0
                    $metricPercentile = 0
    
                    $metricError = $_.Exception.Message
                    #Write-Error $metricError
                    Write-Error ("Error collecting Metric: {0}-{1}-{2}" -f $metricId, $metricService, $metricName)
                }
    
                
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
                    'MetricSeries'         = $metricTimeSeries;
                    'MetricError'          = $metricError;
                }
                
                ($using:tmp).Metrics.Add($obj)
    
                if($_.MetricIndex % 100 -eq 0)
                {
                    Get-Job 
                }
    
                $metricQuery = $null
                $metricQueryResults = $null
                $metricQueryResultsCount = $null
                $metricTimeSeries = $null
                $metricQueryResultsSorted = $null
                $metricPercentile = $null;
    
            } -ThrottleLimit $ConcurrencyLimit

            $defs.Clear()

            $outputPath = $FilePath + "_" + $rangeIdx + ".json"
            $tmp | ConvertTo-Json -depth 5 -compress | Out-File $outputPath -Encoding utf8
            $tmp.Metrics.Clear()

            $rangeIdx++
        }
    }

    $WarningPreference = "Continue"

    $metricDefs = $null;
}
else 
{
    $TableName = ('Metrics_' + $Metrics.Metrics.Count)
    $Style = New-ExcelStyle -HorizontalAlignment Center -AutoSize -NumberFormat '0'
    
    $Metrics.Metrics | 
        ForEach-Object { [PSCustomObject]$_ } | 
        Select-Object 'Subscription',
        'ResourceGroup',
        'Name',
        'Location',
        'Service',
        'Metric',
        'MetricAggregate',
        'MetricMeasure',
        'MetricTimeGrain',
        'MetricValue',
        'MetricCount'| Export-Excel -Path $File -WorksheetName 'Metrics' -AutoSize -MaxAutoSizeRows 100 -TableName $TableName -TableStyle $tableStyle -Style $Style -Numberformat '0' -MoveToEnd 
}
