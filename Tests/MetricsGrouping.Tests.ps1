# Requires -Modules Pester
# =============================================================================
# MetricsGrouping.Tests.ps1
#
# Tests for how Extension/Metrics.ps1 requests Azure Monitor metrics:
#   - definitions of one resource that share a time window, time grain and
#     aggregation are fetched with one Get-AzMetric call;
#   - the result records are the same as with one call per metric;
#   - a metric requested with the 'Count' aggregation is read from each data
#     point's Count, not from the number of data points;
#   - a group that Azure rejects with BadRequest is not retried and falls back to
#     one call per metric, so only the invalid metric is marked as an error;
#   - a group that fails for another reason (throttling, server error) is retried
#     and does not fall back to one call per metric;
#   - each metric's diagnostics time is the time of the request that answered it;
#   - a batch written to Metrics_*.json never splits one call's metrics, and
#     there are no more batches than with one definition at a time.
#
# Get-AzMetric runs inside ForEach-Object -Parallel and Start-ThreadJob
# runspaces, which Pester mocks do not reach. The tests therefore put a stand-in
# Az.Monitor module first on PSModulePath. It records every call as a file and
# returns data points derived from the resource id and metric name, so results
# are deterministic and a metric mapped to the wrong definition is detected.
# A test can instead give the points of a resource and metric; like the real
# cmdlet, it then returns .Data as a typed collection with a Count property of
# its own (the number of points).
#
# No live Azure. Run with:
#   Invoke-Pester ./Tests/MetricsGrouping.Tests.ps1 -Output Detailed
# =============================================================================

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $script:MetricsScript = Join-Path $script:RepoRoot 'Extension/Metrics.ps1'
    if (-not (Test-Path $script:MetricsScript)) { throw "Metrics.ps1 not found at $script:MetricsScript" }
    . (Join-Path $script:RepoRoot 'Functions/Common.Functions.ps1')

    # Metrics.ps1 reads the current Az context once. Returning none keeps the run
    # offline and independent of any saved login on the machine.
    function Get-AzContext { return $null }

    $script:SubscriptionId = '12345678-1234-1234-1234-123456789012'
    $script:Subscriptions = @([PSCustomObject]@{ id = $script:SubscriptionId; Name = 'test-subscription' })
    $script:DiskMetricNames = @(
        'Composite Disk Read Operations/sec',
        'Composite Disk Write Operations/sec',
        'Composite Disk Read Bytes/sec',
        'Composite Disk Write Bytes/sec'
    )

    $script:ModuleRoot = Join-Path $TestDrive 'modules'
    $FakeModuleDir = Join-Path $script:ModuleRoot 'Az.Monitor'
    New-Item -ItemType Directory -Path $FakeModuleDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $FakeModuleDir 'Az.Monitor.psm1') -Encoding utf8 -Value @'
function Get-AzMetric
{
    [CmdletBinding()]
    param(
        [string]$ResourceId,
        [string[]]$MetricName,
        [datetime]$StartTime,
        [datetime]$EndTime,
        [timespan]$TimeGrain,
        [string]$AggregationType,
        $DefaultProfile,
        [switch]$DetailedOutput
    )

    $Names = @($MetricName)
    $Call = [ordered]@{
        ResourceId      = $ResourceId
        MetricName      = $Names
        StartTime       = $StartTime.ToString('o')
        EndTime         = $EndTime.ToString('o')
        TimeGrain       = $TimeGrain.ToString()
        AggregationType = $AggregationType
    }
    $CallFile = Join-Path $env:RDA_TEST_METRIC_CALL_DIR ([guid]::NewGuid().ToString() + '.json')
    $Call | ConvertTo-Json -Compress | Set-Content -LiteralPath $CallFile -Encoding utf8
    # RDA_TEST_SINGLE_DELAY_MS makes every single-metric request take at least that long.
    if ($Names.Count -eq 1 -and $env:RDA_TEST_SINGLE_DELAY_MS) { Start-Sleep -Milliseconds ([int]$env:RDA_TEST_SINGLE_DELAY_MS) }

    # Azure rejects the whole request when one requested name is not valid for the resource.
    foreach ($Rule in @($env:RDA_TEST_METRIC_INVALID -split ';' | Where-Object { $_ }))
    {
        $Parts = $Rule -split '\|', 2
        if ($ResourceId.EndsWith('/' + $Parts[0]) -and $Names -contains $Parts[1])
        {
            throw "Operation returned an invalid status code 'BadRequest'"
        }
    }
    # RDA_TEST_METRIC_MULTI_ERROR makes every multi-name request fail in a chosen way.
    switch ($(if ($Names.Count -gt 1) { $env:RDA_TEST_METRIC_MULTI_ERROR } else { '' }))
    {
        'BadRequest' { throw "Operation returned an invalid status code 'BadRequest'" }
        'Status400' { throw [System.Net.Http.HttpRequestException]::new('The request was rejected.', $null, [System.Net.HttpStatusCode]::BadRequest) }
        'Status500Wrapping400' { throw [System.Net.Http.HttpRequestException]::new('The server failed.', [System.Net.Http.HttpRequestException]::new('The request was rejected.', $null, [System.Net.HttpStatusCode]::BadRequest), [System.Net.HttpStatusCode]::InternalServerError) }
        'Status500Wrapping503' { throw [System.Net.Http.HttpRequestException]::new('The server failed.', [System.Net.Http.HttpRequestException]::new('The service is unavailable.', $null, [System.Net.HttpStatusCode]::ServiceUnavailable), [System.Net.HttpStatusCode]::InternalServerError) }
        'ServerError' { throw "Operation returned an invalid status code 'InternalServerError'" }
        'Throttled' { throw "Operation returned an invalid status code 'TooManyRequests'" }
    }

    $Omitted = @($env:RDA_TEST_METRIC_OMIT -split ';' | Where-Object { $_ })
    # RDA_TEST_METRIC_POINTS names a JSON file that maps 'resource name|metric name'
    # to the points to return; a field a point does not list is null, and a field
    # named in its 'Omit' is left off the point.
    $GivenPoints = if ($env:RDA_TEST_METRIC_POINTS) { Get-Content -LiteralPath $env:RDA_TEST_METRIC_POINTS -Raw | ConvertFrom-Json -AsHashtable } else { @{} }
    foreach ($Name in $Names)
    {
        # A name listed in RDA_TEST_METRIC_OMIT is left out of multi-name responses only.
        if ($Names.Count -gt 1 -and $Omitted -contains $Name) { continue }

        $GivenKey = ($ResourceId -split '/')[-1] + '|' + $Name
        if ($GivenPoints.ContainsKey($GivenKey))
        {
            $Data = [System.Collections.Generic.List[object]]::new()
            $Minute = 0
            foreach ($Fields in @($GivenPoints[$GivenKey]))
            {
                $Point = [ordered]@{ TimeStamp = $StartTime.AddMinutes($Minute++) }
                foreach ($Field in 'Average', 'Minimum', 'Maximum', 'Total', 'Count')
                {
                    if (@($Fields['Omit']) -notcontains $Field) { $Point[$Field] = $Fields[$Field] }
                }
                $Data.Add([PSCustomObject]$Point)
            }
            [PSCustomObject]@{
                Id   = $ResourceId + '/providers/Microsoft.Insights/metrics/' + $Name
                Name = [PSCustomObject]@{ Value = $Name; LocalizedValue = $Name }
                Data = $Data
            }
            continue
        }

        $Seed = 0
        foreach ($Char in ($ResourceId + '|' + $Name).ToCharArray()) { $Seed = ($Seed * 31 + [int]$Char) % 100003 }
        $Points = for ($P = 0; $P -lt 30; $P++)
        {
            $Value = if ($P % 7 -eq 3) { $null } else { [double](($Seed + $P * 37) % 1000) / 10 }
            [PSCustomObject]@{
                TimeStamp = $StartTime.AddHours($P)
                Average   = $Value
                Minimum   = if ($null -ne $Value) { $Value - 0.5 } else { $null }
                Maximum   = if ($null -ne $Value) { $Value + 0.5 } else { $null }
                Total     = if ($null -ne $Value) { $Value * 3 } else { $null }
                Count     = if ($null -ne $Value) { [double](($Seed + $P) % 50) } else { $null }
            }
        }
        [PSCustomObject]@{
            Id   = $ResourceId + '/providers/Microsoft.Insights/metrics/' + $Name
            Name = [PSCustomObject]@{ Value = $Name; LocalizedValue = $Name }
            Data = $Points
        }
    }
}
Export-ModuleMember -Function Get-AzMetric
'@

    $script:OriginalModulePath = $env:PSModulePath
    $script:OriginalDebugLogFile = $Global:DebugLogFile
    $env:PSModulePath = $script:ModuleRoot + [System.IO.Path]::PathSeparator + $env:PSModulePath

    function New-TestResource
    {
        param([string]$Type, [string]$Provider, [string]$Name, [string]$Kind = '', [string]$ManagedBy = '')

        return [PSCustomObject]@{
            TYPE           = $Type
            Id             = '/subscriptions/{0}/resourceGroups/rg-metrics-test/providers/{1}/{2}' -f $script:SubscriptionId, $Provider, $Name
            subscriptionId = $script:SubscriptionId
            ResourceGroup  = 'rg-metrics-test'
            Name           = $Name
            Location       = 'westeurope'
            kind           = $Kind
            ManagedBy      = $ManagedBy
        }
    }

    function New-TestDisk
    {
        param([string]$Name)

        return New-TestResource -Type 'microsoft.compute/disks' -Provider 'Microsoft.Compute/disks' -Name $Name -ManagedBy ('/subscriptions/{0}/resourceGroups/rg-metrics-test/providers/Microsoft.Compute/virtualMachines/vm-owner' -f $script:SubscriptionId)
    }

    # Runs Metrics.ps1 against the stand-in module and returns the calls it made,
    # the records it wrote (per Metrics_*.json file and in total) and its
    # diagnostics lines.
    function Invoke-MetricsRun
    {
        param([object[]]$Resources, [string]$RunName, [string]$Invalid = '', [string]$Omit = '', [string]$MultiError = '', [int]$SingleDelayMs = 0, [hashtable]$Points = @{})

        $RunDir = Join-Path $TestDrive $RunName
        $CallDir = Join-Path $RunDir 'calls'
        New-Item -ItemType Directory -Path $CallDir -Force | Out-Null
        $PointsFile = ''
        if ($Points.Count -gt 0)
        {
            $PointsFile = Join-Path $RunDir 'points.json'
            $Points | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $PointsFile -Encoding utf8
        }

        $env:RDA_TEST_METRIC_CALL_DIR = $CallDir
        $env:RDA_TEST_METRIC_INVALID = $Invalid
        $env:RDA_TEST_METRIC_OMIT = $Omit
        $env:RDA_TEST_METRIC_MULTI_ERROR = $MultiError
        $env:RDA_TEST_SINGLE_DELAY_MS = $(if ($SingleDelayMs -gt 0) { [string]$SingleDelayMs } else { '' })
        $env:RDA_TEST_METRIC_POINTS = $PointsFile
        $Global:DebugLogFile = Join-Path $RunDir 'debug.log'

        try
        {
            $null = & $script:MetricsScript -Subscriptions $script:Subscriptions -Resources $Resources -Task 'Processing' -ConcurrencyLimit 16 -FilePath (Join-Path $RunDir 'Metrics_test') -Obfuscate $false *>&1
        }
        finally
        {
            $Global:DebugLogFile = $script:OriginalDebugLogFile
        }

        $Files = @(Get-ChildItem -LiteralPath $RunDir -Filter 'Metrics_test_*.json' |
                Sort-Object { [int]($_.BaseName -replace '^.*_', '') } |
                ForEach-Object { [PSCustomObject]@{ Name = $_.Name; Records = @((Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json).Metrics) } })

        return [PSCustomObject]@{
            Calls      = @(Get-ChildItem -LiteralPath $CallDir -Filter '*.json' | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json })
            Files      = $Files
            Records    = @($Files | ForEach-Object { $_.Records })
            DebugLines = @(if (Test-Path -LiteralPath (Join-Path $RunDir 'debug.log')) { Get-Content -LiteralPath (Join-Path $RunDir 'debug.log') })
        }
    }

    # Maps 'ID|Metric' to the record's fields as canonical JSON (sorted names).
    function ConvertTo-RecordMap
    {
        param([object[]]$Records)

        $Map = @{}
        foreach ($Record in $Records)
        {
            $Sorted = [ordered]@{}
            foreach ($Property in ($Record.PSObject.Properties | Sort-Object Name)) { $Sorted[$Property.Name] = $Property.Value }
            $Map[('{0}|{1}' -f $Record.ID, $Record.Metric)] = ($Sorted | ConvertTo-Json -Depth 5 -Compress)
        }
        return $Map
    }
}

AfterAll {
    $env:PSModulePath = $script:OriginalModulePath
    $Global:DebugLogFile = $script:OriginalDebugLogFile
    Remove-Item -Path 'Env:RDA_TEST_METRIC_CALL_DIR', 'Env:RDA_TEST_METRIC_INVALID', 'Env:RDA_TEST_METRIC_OMIT', 'Env:RDA_TEST_METRIC_MULTI_ERROR', 'Env:RDA_TEST_SINGLE_DELAY_MS', 'Env:RDA_TEST_METRIC_POINTS' -ErrorAction SilentlyContinue
}

Describe 'Metrics.ps1 Azure Monitor requests per resource' {

    It 'requests the four metrics of one attached disk in a single call' {
        $Run = Invoke-MetricsRun -Resources @(New-TestDisk -Name 'disk-01') -RunName 'disk-single'

        $Run.Calls.Count | Should -Be 1
        @($Run.Calls[0].MetricName | Sort-Object) | Should -Be @($script:DiskMetricNames | Sort-Object)
        $Run.Calls[0].AggregationType | Should -Be 'Maximum'
        $Run.Records.Count | Should -Be 4
        @($Run.Records | Where-Object { $_.MetricError }).Count | Should -Be 0
    }

    It 'keeps the VM Maximum and Minimum metrics as two calls' {
        $Vm = New-TestResource -Type 'microsoft.compute/virtualmachines' -Provider 'Microsoft.Compute/virtualMachines' -Name 'vm-01'
        $Run = Invoke-MetricsRun -Resources @($Vm) -RunName 'vm-single'

        $Run.Calls.Count | Should -Be 2
        $Maximum = @($Run.Calls | Where-Object { $_.AggregationType -eq 'Maximum' })
        $Minimum = @($Run.Calls | Where-Object { $_.AggregationType -eq 'Minimum' })
        $Maximum.Count | Should -Be 1
        $Minimum.Count | Should -Be 1
        @($Maximum[0].MetricName) | Should -Be @('Percentage CPU')
        @($Minimum[0].MetricName) | Should -Be @('Available Memory Bytes')
        $Run.Records.Count | Should -Be 2
    }

    It 'groups SQL database metrics by time window, time grain and aggregation' {
        $Dtu = New-TestResource -Type 'microsoft.sql/servers/databases' -Provider 'Microsoft.Sql/servers/sql-test/databases' -Name 'db-dtu' -Kind 'v12.0,user'
        $Serverless = New-TestResource -Type 'microsoft.sql/servers/databases' -Provider 'Microsoft.Sql/servers/sql-test/databases' -Name 'db-serverless' -Kind 'v12.0,user,vcore,serverless'
        $Run = Invoke-MetricsRun -Resources @($Dtu, $Serverless) -RunName 'sql'

        # DTU: 8 definitions in 4 calls. vCore serverless: 9 definitions in 5 calls.
        $Run.Records.Count | Should -Be 17
        @($Run.Calls | Where-Object { $_.ResourceId -eq $Dtu.Id }).Count | Should -Be 4
        @($Run.Calls | Where-Object { $_.ResourceId -eq $Serverless.Id }).Count | Should -Be 5

        $DtuDaily = @($Run.Calls | Where-Object { $_.ResourceId -eq $Dtu.Id -and $_.AggregationType -eq 'Maximum' -and $_.TimeGrain -eq '1.00:00:00' })
        $DtuDaily.Count | Should -Be 1
        @($DtuDaily[0].MetricName | Sort-Object) | Should -Be @('dtu_limit', 'storage', 'storage_percent')
    }
}

Describe 'Metrics.ps1 metric grouping key' {

    BeforeAll {
        # With no -Task the script only defines its functions.
        . $script:MetricsScript
        $script:Start = (Get-Date).AddDays(-31)
        $script:End = Get-Date
    }

    It "treats '1:00:00' and '01:00:00' as the same time grain" {
        $Id = '/subscriptions/{0}/resourceGroups/rg-metrics-test/providers/Microsoft.Sql/servers/sql-test/databases/db-01' -f $script:SubscriptionId
        $Defs = @(
            [PSCustomObject]@{ MetricName = 'm1'; Id = $Id; StartTime = $script:Start; EndTime = $script:End; Interval = '1:00:00'; Aggregation = 'Maximum' },
            [PSCustomObject]@{ MetricName = 'm2'; Id = $Id; StartTime = $script:Start; EndTime = $script:End; Interval = '01:00:00'; Aggregation = 'Maximum' },
            [PSCustomObject]@{ MetricName = 'm3'; Id = $Id; StartTime = $script:Start; EndTime = $script:End; Interval = '01:00:00'; Aggregation = 'Average' },
            [PSCustomObject]@{ MetricName = 'm4'; Id = $Id; StartTime = $script:End.AddDays(-1); EndTime = $script:End; Interval = '1:00:00'; Aggregation = 'Maximum' },
            [PSCustomObject]@{ MetricName = 'm5'; Id = $Id; StartTime = $script:Start; EndTime = $script:End; Interval = '1.00:00:00'; Aggregation = 'Maximum' }
        )

        $Groups = Group-MetricDefinition -MetricDefs $Defs

        $Groups.Count | Should -Be 4
        @($Groups[0] | ForEach-Object { $_.MetricName }) | Should -Be @('m1', 'm2')
        @($Groups[1] | ForEach-Object { $_.MetricName }) | Should -Be @('m3')
        @($Groups[2] | ForEach-Object { $_.MetricName }) | Should -Be @('m4')
        @($Groups[3] | ForEach-Object { $_.MetricName }) | Should -Be @('m5')
    }

    It 'never groups definitions of different resources' {
        $Defs = @('disk-a', 'disk-b') | ForEach-Object {
            [PSCustomObject]@{ MetricName = 'm1'; Id = ('/subscriptions/{0}/resourceGroups/rg-metrics-test/providers/Microsoft.Compute/disks/{1}' -f $script:SubscriptionId, $_); StartTime = $script:Start; EndTime = $script:End; Interval = '1:00:00'; Aggregation = 'Maximum' }
        }

        $Groups = Group-MetricDefinition -MetricDefs $Defs

        $Groups.Count | Should -Be 2
    }
}

Describe 'Metrics.ps1 result records' {

    It 'writes the same records as one call per metric for a mixed fixture' {
        $Resources = @(
            (New-TestResource -Type 'microsoft.compute/virtualmachines' -Provider 'Microsoft.Compute/virtualMachines' -Name 'vm-01'),
            (New-TestDisk -Name 'disk-01'),
            (New-TestDisk -Name 'disk-02'),
            (New-TestResource -Type 'microsoft.sql/servers/databases' -Provider 'Microsoft.Sql/servers/sql-test/databases' -Name 'db-dtu' -Kind 'v12.0,user'),
            (New-TestResource -Type 'microsoft.sql/servers/databases' -Provider 'Microsoft.Sql/servers/sql-test/databases' -Name 'db-vcore' -Kind 'v12.0,user,vcore'),
            (New-TestResource -Type 'microsoft.web/sites' -Provider 'Microsoft.Web/sites' -Name 'func-01' -Kind 'functionapp,linux'),
            (New-TestResource -Type 'microsoft.dbforpostgresql/servers' -Provider 'Microsoft.DBforPostgreSQL/servers' -Name 'pg-01'),
            (New-TestResource -Type 'microsoft.compute/virtualmachinescalesets' -Provider 'Microsoft.Compute/virtualMachineScaleSets' -Name 'vmss-01'),
            (New-TestResource -Type 'microsoft.documentdb/databaseaccounts' -Provider 'Microsoft.DocumentDB/databaseAccounts' -Name 'cosmos-01'),
            (New-TestResource -Type 'microsoft.containerregistry/registries' -Provider 'Microsoft.ContainerRegistry/registries' -Name 'acr01')
        )

        $Grouped = Invoke-MetricsRun -Resources $Resources -RunName 'mixed-grouped'
        # Rejecting every multi-name request makes each metric come from a call of its own.
        $Single = Invoke-MetricsRun -Resources $Resources -RunName 'mixed-single' -MultiError 'BadRequest'

        # 2 VM + 8 disk + 8 DTU + 8 vCore + 2 function + 3 PostgreSQL + 2 scale set + 4 Cosmos DB + 1 registry
        $Grouped.Records.Count | Should -Be 38
        $Single.Records.Count | Should -Be 38
        @($Grouped.Records | Where-Object { $_.MetricError }).Count | Should -Be 0
        @($Single.Records | Where-Object { $_.MetricError }).Count | Should -Be 0
        @($Single.Calls | Where-Object { @($_.MetricName).Count -eq 1 }).Count | Should -Be 38
        # The stand-in returns 30 points per metric, so every record carries data.
        @($Grouped.Records | Where-Object { $_.MetricTotalCount -ne 30 }).Count | Should -Be 0

        $GroupedMap = ConvertTo-RecordMap -Records $Grouped.Records
        $SingleMap = ConvertTo-RecordMap -Records $Single.Records
        @($GroupedMap.Keys | Sort-Object) | Should -Be @($SingleMap.Keys | Sort-Object)
        foreach ($Key in $SingleMap.Keys)
        {
            $GroupedMap[$Key] | Should -Be $SingleMap[$Key] -Because "record $Key must not depend on how it was requested"
        }
    }

    It 'reads each data point''s Count for a Count-aggregated metric, not the number of data points' {
        # Cosmos DB 'TotalRequests' is the only 'Count' definition, so its group holds
        # it alone. Measure 'Largest' over the per-point counts 3, null, 7, 0 and a
        # point without a Count property, which reads as no value rather than as 1.
        $Cosmos = New-TestResource -Type 'microsoft.documentdb/databaseaccounts' -Provider 'Microsoft.DocumentDB/databaseAccounts' -Name 'cosmos-count' -Kind 'GlobalDocumentDB'
        $Points = @{ 'cosmos-count|TotalRequests' = @(@{ Count = 3 }, @{ Count = $null }, @{ Omit = 'Count' }, @{ Count = 7 }, @{ Count = 0 }) }
        $Run = Invoke-MetricsRun -Resources @($Cosmos) -RunName 'cosmos-count' -Points $Points

        $CountCalls = @($Run.Calls | Where-Object { $_.AggregationType -eq 'Count' })
        $CountCalls.Count | Should -Be 1
        @($CountCalls[0].MetricName) | Should -Be @('TotalRequests')
        $Run.Records.Count | Should -Be 4
        @($Run.Records | Where-Object { $_.MetricError }).Count | Should -Be 0

        $Record = @($Run.Records | Where-Object { $_.Metric -eq 'TotalRequests' })
        $Record.Count | Should -Be 1
        $Record[0].MetricValue | Should -Be 7
        $Record[0].MetricCount | Should -Be 3
        $Record[0].MetricTotalCount | Should -Be 5
        $Record[0].MetricPercentile | Should -Be 7
    }
}

Describe 'Metrics.ps1 fallback when Azure rejects a grouped request' {

    BeforeAll {
        $script:Disk = New-TestDisk -Name 'disk-bad'
        $script:Clean = Invoke-MetricsRun -Resources @($script:Disk) -RunName 'fallback-clean'
        $script:Rejected = Invoke-MetricsRun -Resources @($script:Disk) -RunName 'fallback-rejected' -Invalid 'disk-bad|Composite Disk Write Bytes/sec'
    }

    It 'marks only the invalid metric as an error and keeps the other records unchanged' {
        $script:Rejected.Records.Count | Should -Be 4
        $Errors = @($script:Rejected.Records | Where-Object { $_.MetricError })
        $Errors.Count | Should -Be 1
        $Errors[0].Metric | Should -Be 'Composite Disk Write Bytes/sec'
        $Errors[0].MetricValue | Should -Be 0
        $Errors[0].MetricTotalCount | Should -Be 0

        $CleanMap = ConvertTo-RecordMap -Records $script:Clean.Records
        $RejectedMap = ConvertTo-RecordMap -Records $script:Rejected.Records
        foreach ($Name in ($script:DiskMetricNames | Where-Object { $_ -ne 'Composite Disk Write Bytes/sec' }))
        {
            $Key = '{0}|{1}' -f $script:Disk.Id, $Name
            $RejectedMap[$Key] | Should -Be $CleanMap[$Key]
        }

        @($script:Rejected.DebugLines | Where-Object { $_ -match 'Composite Disk Write Bytes/sec' -and $_ -match 'BadRequest' }).Count | Should -BeGreaterThan 0
    }

    It 'does not retry a grouped request rejected with BadRequest and requests each metric on its own' {
        $Single = @($script:Rejected.Calls | Where-Object { @($_.MetricName).Count -eq 1 })
        $Grouped = @($script:Rejected.Calls | Where-Object { @($_.MetricName).Count -eq 4 })
        $Grouped.Count | Should -Be 1
        # A single-metric request keeps the full retry ladder (4 attempts), BadRequest included.
        @($Single | Where-Object { $_.MetricName -eq 'Composite Disk Write Bytes/sec' }).Count | Should -Be 4
        @($Single | Where-Object { $_.MetricName -ne 'Composite Disk Write Bytes/sec' }).Count | Should -Be 3
    }

    It 'recognises BadRequest from the status code when the message does not name it' {
        $Run = Invoke-MetricsRun -Resources @($script:Disk) -RunName 'fallback-status400' -MultiError 'Status400'

        @($Run.Calls | Where-Object { @($_.MetricName).Count -eq 4 }).Count | Should -Be 1
        @($Run.Calls | Where-Object { @($_.MetricName).Count -eq 1 }).Count | Should -Be 4
        $CleanMap = ConvertTo-RecordMap -Records $script:Clean.Records
        $RunMap = ConvertTo-RecordMap -Records $Run.Records
        @($RunMap.Keys | Sort-Object) | Should -Be @($CleanMap.Keys | Sort-Object)
        foreach ($Key in $CleanMap.Keys)
        {
            $RunMap[$Key] | Should -Be $CleanMap[$Key]
        }
    }

    It 'recognises a BadRequest wrapped in an exception that reports another status' {
        $Run = Invoke-MetricsRun -Resources @($script:Disk) -RunName 'fallback-wrapped400' -MultiError 'Status500Wrapping400'

        @($Run.Calls | Where-Object { @($_.MetricName).Count -eq 4 }).Count | Should -Be 1
        @($Run.Calls | Where-Object { @($_.MetricName).Count -eq 1 }).Count | Should -Be 4
        $CleanMap = ConvertTo-RecordMap -Records $script:Clean.Records
        $RunMap = ConvertTo-RecordMap -Records $Run.Records
        @($RunMap.Keys | Sort-Object) | Should -Be @($CleanMap.Keys | Sort-Object)
        foreach ($Key in $CleanMap.Keys)
        {
            $RunMap[$Key] | Should -Be $CleanMap[$Key]
        }
    }

    It 'retries a grouped request when no wrapped exception reports BadRequest' {
        $Run = Invoke-MetricsRun -Resources @($script:Disk) -RunName 'fallback-wrapped503' -MultiError 'Status500Wrapping503'

        @($Run.Calls | Where-Object { @($_.MetricName).Count -eq 4 }).Count | Should -Be 4
        # Not a BadRequest, so the group's metrics are not requested again one by one.
        @($Run.Calls | Where-Object { @($_.MetricName).Count -eq 1 }).Count | Should -Be 0
        $Run.Records.Count | Should -Be 4
        @($Run.Records | Where-Object { -not $_.MetricError }).Count | Should -Be 0
    }

    It 'retries a grouped request that fails for another reason and does not fall back to one request per metric' {
        $Run = Invoke-MetricsRun -Resources @($script:Disk) -RunName 'fallback-server-error' -MultiError 'ServerError'

        @($Run.Calls | Where-Object { @($_.MetricName).Count -eq 4 }).Count | Should -Be 4
        @($Run.Calls | Where-Object { @($_.MetricName).Count -eq 1 }).Count | Should -Be 0
        $Run.Records.Count | Should -Be 4
        @($Run.Records | Where-Object { $_.MetricError -and $_.MetricValue -eq 0 -and $_.MetricTotalCount -eq 0 }).Count | Should -Be 4
        @(($script:DiskMetricNames | Sort-Object)) | Should -Be @($Run.Records | ForEach-Object { $_.Metric } | Sort-Object)
        # Each metric carries the group request's outcome and attempts.
        foreach ($Name in $script:DiskMetricNames)
        {
            @($Run.DebugLines | Where-Object { $_ -match ('  Error idx=[0-9]+ .*/{0} interval=.* attempts=4 .*InternalServerError' -f [regex]::Escape($Name)) }).Count | Should -Be 1
        }
        @($Run.DebugLines | Where-Object { $_ -match 'Azure Monitor requests: 1 for 4 metric definition\(s\), of which 0 single-metric fallback request\(s\)' }).Count | Should -Be 1
    }

    It 'retries a throttled grouped request and does not fall back to one request per metric' {
        $Run = Invoke-MetricsRun -Resources @($script:Disk) -RunName 'fallback-throttled' -MultiError 'Throttled'

        @($Run.Calls | Where-Object { @($_.MetricName).Count -eq 4 }).Count | Should -Be 4
        @($Run.Calls | Where-Object { @($_.MetricName).Count -eq 1 }).Count | Should -Be 0
        $Run.Records.Count | Should -Be 4
        @($Run.Records | Where-Object { -not $_.MetricError }).Count | Should -Be 0
        foreach ($Name in $script:DiskMetricNames)
        {
            @($Run.DebugLines | Where-Object { $_ -match ('  Throttled idx=[0-9]+ .*/{0} interval=.* attempts=4 ' -f [regex]::Escape($Name)) }).Count | Should -Be 1
        }
    }

    It 'reports the number of Azure Monitor requests in the diagnostics summary' {
        @($script:Rejected.DebugLines | Where-Object { $_ -match 'Azure Monitor requests: 5 for 4 metric definition\(s\), of which 4 single-metric fallback request\(s\)' }).Count | Should -Be 1
        @($script:Clean.DebugLines | Where-Object { $_ -match 'Azure Monitor requests: 1 for 4 metric definition\(s\), of which 0 single-metric fallback request\(s\)' }).Count | Should -Be 1
    }

    It 'requests a metric on its own when a successful grouped response leaves it out' {
        $Run = Invoke-MetricsRun -Resources @($script:Disk) -RunName 'fallback-omitted' -Omit 'Composite Disk Read Bytes/sec'

        $Run.Calls.Count | Should -Be 2
        @($Run.Calls | Where-Object { @($_.MetricName).Count -eq 1 })[0].MetricName | Should -Be 'Composite Disk Read Bytes/sec'
        $CleanMap = ConvertTo-RecordMap -Records $script:Clean.Records
        $RunMap = ConvertTo-RecordMap -Records $Run.Records
        @($RunMap.Keys | Sort-Object) | Should -Be @($CleanMap.Keys | Sort-Object)
        foreach ($Key in $CleanMap.Keys)
        {
            $RunMap[$Key] | Should -Be $CleanMap[$Key]
        }
    }

    It 'reports the grouped request time for each metric it answered, also after a fallback request of the group' {
        # The second of the four disk metrics is left out of the grouped answer and its
        # own request takes at least 1.5 s; the third and fourth are recorded after it.
        $Omitted = 'Composite Disk Write Operations/sec'
        $Run = Invoke-MetricsRun -Resources @($script:Disk) -RunName 'elapsed-omitted' -Omit $Omitted -SingleDelayMs 1500

        # 'Slowest 5 calls' lists every record of this four-metric run with its time.
        $Elapsed = @{}
        foreach ($Name in $script:DiskMetricNames)
        {
            $Pattern = '\] +(?<Seconds>[0-9]+(\.[0-9]+)?)s idx=[0-9]+ .*/{0} interval=' -f [regex]::Escape($Name)
            foreach ($Line in $Run.DebugLines)
            {
                if ($Line -match $Pattern) { $Elapsed[$Name] = [double]::Parse($Matches['Seconds'], [cultureinfo]::InvariantCulture) }
            }
        }
        $Elapsed.Count | Should -Be 4

        $Answered = @($script:DiskMetricNames | Where-Object { $_ -ne $Omitted } | ForEach-Object { $Elapsed[$_] })
        @($Answered | Select-Object -Unique).Count | Should -Be 1 -Because 'metrics answered by one request report that request''s time'
        $Elapsed[$Omitted] | Should -BeGreaterOrEqual ($Answered[0] + 1.49) -Because 'a fallback metric reports the group request plus its own request'
    }
}

Describe 'Metrics.ps1 batches' {

    It "never splits one call's metrics across Metrics_*.json files and writes no more files than before" {
        # 125 disks x 4 metrics = 500 definitions: two 250-definition batches when
        # definitions are batched one at a time, which splits disk 63 across them.
        $Disks = @(1..125 | ForEach-Object { New-TestDisk -Name ('disk-{0:d3}' -f $_) })
        $Run = Invoke-MetricsRun -Resources $Disks -RunName 'batches'

        $Run.Records.Count | Should -Be 500
        $Run.Files.Count | Should -Be 2
        # Every batch but the last holds at least 250 definitions and less than one group more.
        for ($F = 0; $F -lt $Run.Files.Count - 1; $F++)
        {
            $Run.Files[$F].Records.Count | Should -BeGreaterOrEqual 250
            $Run.Files[$F].Records.Count | Should -BeLessThan 254
        }

        $FilesPerResource = @{}
        foreach ($File in $Run.Files)
        {
            foreach ($Record in $File.Records)
            {
                if (-not $FilesPerResource.ContainsKey($Record.ID)) { $FilesPerResource[$Record.ID] = [System.Collections.Generic.HashSet[string]]::new() }
                [void]$FilesPerResource[$Record.ID].Add($File.Name)
            }
        }
        $FilesPerResource.Count | Should -Be 125
        @($FilesPerResource.Keys | Where-Object { $FilesPerResource[$_].Count -ne 1 }) | Should -BeNullOrEmpty
        $Run.Calls.Count | Should -Be 125
    }
}
