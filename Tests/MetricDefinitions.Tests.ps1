# Metric request definition tests (Extension/Metrics.ps1)
# Run with: Invoke-Pester ./Tests/MetricDefinitions.Tests.ps1 -Output Detailed
#
# Extension/Metrics.ps1 builds one request definition per metric for the whole
# estate before it makes the first Azure Monitor call, and keeps them all until
# the metrics phase ends, so the size of one definition sets the memory floor
# of that phase (four per attached disk, two per VM, up to nine per SQL
# database).
#
# These tests invoke the REAL Extension/Metrics.ps1 with no Azure sign-in and
# no Azure calls:
#   - Get-AzMetric is replaced by a stand-in module, put first on PSModulePath
#     so the script's parallel runspaces and thread jobs load it. Its data is
#     derived only from the request (resource id, metric name, aggregation,
#     time grain, lookback), so every run returns the same values. BeforeAll
#     refuses to run if Get-AzMetric resolves to anything else.
#   - Get-AzContext is replaced by a function that returns $null and records
#     the definitions its caller has built (Metrics.ps1 calls it once, after
#     building every definition and before the first metric call).
#
# The fixture holds one resource of every type Metrics.ps1 defines metrics for,
# plus resources it must skip. The metrics output files are compared record for
# record and field for field with Tests/Fixtures/MetricDefinitions.Output.json
# (records keyed by ID and metric, fields in ordinal order, because the output
# order inside a file depends on thread timing). On a mismatch the actual output
# is written to the temp directory in the same format and its path is shown.

BeforeAll {
    $script:MetricsScript = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'Extension', 'Metrics.ps1' | Resolve-Path | Select-Object -ExpandProperty Path
    $script:ExpectedOutputPath = Join-Path -Path $PSScriptRoot -ChildPath 'Fixtures' -AdditionalChildPath 'MetricDefinitions.Output.json'
    $script:ActualOutputPath = Join-Path ([System.IO.Path]::GetTempPath()) 'MetricDefinitions.Output.actual.json'
    $script:SubscriptionId = '12345678-1234-1234-1234-123456789012'

    # Shared with the Get-AzContext stand-in below, which reaches it through the
    # caller chain (Metrics.ps1 runs in a child scope of the test).
    $script:RdaMetricsTestHook = @{
        StopAfterDefinitions = $false
        Definitions          = $null
        DefinitionCount      = 0
        HeapAfterDefinitions = 0
    }

    function Get-AzContext
    {
        $Hook = $RdaMetricsTestHook
        if ($Hook.StopAfterDefinitions)
        {
            # Skip the metric calls: with no definitions to send, the batch loop does not run.
            Set-Variable -Name 'MetricCount' -Value 0 -Scope 1
        }
        $Defs = Get-Variable -Name 'MetricDefs' -Scope 1 -ValueOnly
        $Hook.DefinitionCount = $Defs.Count
        if ($Hook.StopAfterDefinitions)
        {
            $Defs = $null
            [System.GC]::Collect()
            [System.GC]::WaitForPendingFinalizers()
            [System.GC]::Collect()
            $Hook.HeapAfterDefinitions = [System.GC]::GetTotalMemory($true)
        }
        else
        {
            $Hook.Definitions = $Defs.ToArray()
        }
        return $null
    }

    $StandInSource = {
        function Get-AzMetric
        {
            [CmdletBinding()]
            param($ResourceId, $MetricName, $StartTime, $EndTime, $TimeGrain, $AggregationType, $DefaultProfile)

            if ($StartTime -isnot [datetime] -or $EndTime -isnot [datetime])
            {
                throw 'StartTime and EndTime must be DateTime values.'
            }
            $LookbackDays = [int][math]::Round(($EndTime - $StartTime).TotalDays)
            $Seed = 17
            foreach ($Char in ('{0}|{1}|{2}|{3}|{4}' -f $ResourceId, $MetricName, $AggregationType, $TimeGrain, $LookbackDays).ToCharArray())
            {
                $Seed = ($Seed * 31 + [int]$Char) % 1000003
            }

            # 0 to 4 points; some points carry no values, as Azure Monitor returns for gaps.
            $Points = [System.Collections.Generic.List[object]]::new()
            for ($Index = 0; $Index -lt ($Seed % 5); $Index++)
            {
                if ((($Seed + $Index) % 4) -eq 0)
                {
                    $Points.Add([PSCustomObject]@{ Average = $null; Maximum = $null; Minimum = $null; Total = $null; Count = $null })
                    continue
                }
                $Value = [double](($Seed + 37 * $Index) % 100)
                $Points.Add([PSCustomObject]@{ Average = $Value; Maximum = $Value + 2; Minimum = $Value / 2; Total = $Value * 60; Count = [double]($Value % 13) })
            }
            return [PSCustomObject]@{ Data = $Points.ToArray() }
        }
    }

    $script:ModuleRoot = Join-Path $TestDrive 'Modules'
    $StandInDir = Join-Path $script:ModuleRoot 'RdaMetricsStandIn'
    New-Item -ItemType Directory -Path $StandInDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $StandInDir 'RdaMetricsStandIn.psm1') -Value $StandInSource.ToString() -Encoding utf8

    $script:SavedModulePath = $env:PSModulePath
    $env:PSModulePath = $script:ModuleRoot + [System.IO.Path]::PathSeparator + $env:PSModulePath

    $ProbeJob = Start-ThreadJob -ScriptBlock { (Get-Command -Name 'Get-AzMetric' -ErrorAction Stop).Source }
    $Resolved = Receive-Job -Job $ProbeJob -Wait -AutoRemoveJob
    if ($Resolved -ne 'RdaMetricsStandIn')
    {
        throw "Get-AzMetric resolves to '$Resolved' in a new runspace, not to the stand-in; refusing to run Metrics.ps1."
    }

    function New-TestResource
    {
        param([string]$Type, [string]$Provider, [string]$Name, [string]$Kind = '', [string]$ManagedBy = '', [string]$SubscriptionId = $script:SubscriptionId)

        [PSCustomObject]@{
            id             = '/subscriptions/{0}/resourceGroups/rg-metrics/providers/{1}/{2}' -f $script:SubscriptionId, $Provider, $Name
            name           = $Name
            type           = $Type
            kind           = $Kind
            location       = 'eastus'
            resourceGroup  = 'rg-metrics'
            subscriptionId = $SubscriptionId
            managedBy      = $ManagedBy
        }
    }

    function New-MetricsFixture
    {
        $VmId = '/subscriptions/{0}/resourceGroups/rg-metrics/providers/Microsoft.Compute/virtualMachines/vm-01' -f $script:SubscriptionId
        @(
            New-TestResource -Type 'microsoft.compute/virtualmachines' -Provider 'Microsoft.Compute/virtualMachines' -Name 'vm-01'
            # Subscription missing from the subscription list: SubName stays $null.
            New-TestResource -Type 'microsoft.compute/virtualmachines' -Provider 'Microsoft.Compute/virtualMachines' -Name 'vm-02' -SubscriptionId 'not-in-subscription-list'
            New-TestResource -Type 'microsoft.compute/disks' -Provider 'Microsoft.Compute/disks' -Name 'disk-01' -ManagedBy $VmId
            New-TestResource -Type 'microsoft.compute/disks' -Provider 'Microsoft.Compute/disks' -Name 'disk-02-unattached'
            New-TestResource -Type 'microsoft.sql/servers/databases' -Provider 'Microsoft.Sql/servers/sql-01/databases' -Name 'sqldb-dtu' -Kind 'v12.0,user'
            New-TestResource -Type 'microsoft.sql/servers/databases' -Provider 'Microsoft.Sql/servers/sql-01/databases' -Name 'sqldb-vcore' -Kind 'v12.0,user,vcore'
            New-TestResource -Type 'microsoft.sql/servers/databases' -Provider 'Microsoft.Sql/servers/sql-01/databases' -Name 'sqldb-serverless' -Kind 'v12.0,user,vcore,serverless'
            New-TestResource -Type 'microsoft.sql/servers/databases' -Provider 'Microsoft.Sql/servers/sql-01/databases' -Name 'master' -Kind 'v12.0,system'
            New-TestResource -Type 'microsoft.web/sites' -Provider 'Microsoft.Web/sites' -Name 'func-01' -Kind 'functionapp,linux'
            New-TestResource -Type 'microsoft.web/sites' -Provider 'Microsoft.Web/sites' -Name 'web-01' -Kind 'app'
            New-TestResource -Type 'microsoft.dbformariadb/servers' -Provider 'Microsoft.DBforMariaDB/servers' -Name 'mariadb-01'
            New-TestResource -Type 'microsoft.dbforpostgresql/servers' -Provider 'Microsoft.DBforPostgreSQL/servers' -Name 'pg-01'
            New-TestResource -Type 'microsoft.dbformysql/servers' -Provider 'Microsoft.DBforMySQL/servers' -Name 'mysql-01'
            New-TestResource -Type 'microsoft.dbformysql/flexibleservers' -Provider 'Microsoft.DBforMySQL/flexibleServers' -Name 'mysqlflex-01'
            New-TestResource -Type 'microsoft.dbforpostgresql/flexibleservers' -Provider 'Microsoft.DBforPostgreSQL/flexibleServers' -Name 'pgflex-01'
            New-TestResource -Type 'microsoft.compute/virtualmachinescalesets' -Provider 'Microsoft.Compute/virtualMachineScaleSets' -Name 'vmss-01'
            New-TestResource -Type 'microsoft.documentdb/databaseaccounts' -Provider 'Microsoft.DocumentDB/databaseAccounts' -Name 'cosmos-01'
            New-TestResource -Type 'microsoft.containerregistry/registries' -Provider 'Microsoft.ContainerRegistry/registries' -Name 'acr01'
            New-TestResource -Type 'microsoft.storage/storageaccounts' -Provider 'Microsoft.Storage/storageAccounts' -Name 'storage01'
        )
    }

    function Invoke-MetricsScript
    {
        param([object[]]$Resources, [string]$OutputDirectory)

        New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
        $Subscriptions = @([PSCustomObject]@{ id = $script:SubscriptionId; Name = 'Metrics Test Subscription' })
        $ProgressPreference = 'SilentlyContinue'
        & $script:MetricsScript -Subscriptions $Subscriptions -Resources $Resources -Task 'Processing' -ConcurrencyLimit 4 -FilePath (Join-Path $OutputDirectory 'Metrics') -Obfuscate $false -MetricsLookbackDays 31 | Out-Null
    }

    # Maps "<ID>|<Metric>" to the record as compact JSON with its fields in
    # ordinal order. Throws on a duplicate key.
    function ConvertTo-CanonicalRecordSet
    {
        param([object[]]$Records)

        $Set = [System.Collections.Generic.SortedDictionary[string, string]]::new([System.StringComparer]::Ordinal)
        foreach ($Record in $Records)
        {
            $Names = [string[]]@($Record.PSObject.Properties.Name)
            [System.Array]::Sort($Names, [System.StringComparer]::Ordinal)
            $Ordered = [ordered]@{}
            foreach ($Name in $Names)
            {
                $Ordered[$Name] = $Record.$Name
            }
            $Set.Add(('{0}|{1}' -f $Record.ID, $Record.Metric), ($Ordered | ConvertTo-Json -Compress -Depth 5))
        }
        return , $Set
    }

    # File name -> canonical record set, for every Metrics_*.json in a directory.
    function Get-CanonicalMetricsOutput
    {
        param([string]$Directory)

        $Output = [ordered]@{}
        foreach ($File in (Get-ChildItem -LiteralPath $Directory -Filter 'Metrics_*.json' | Sort-Object -Property Name))
        {
            $Records = @((Get-Content -LiteralPath $File.FullName -Raw | ConvertFrom-Json).Metrics)
            $Output[$File.Name] = ConvertTo-CanonicalRecordSet -Records $Records
        }
        return $Output
    }

    function Read-ExpectedMetricsOutput
    {
        param([string]$Path)

        $Parsed = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        $Output = [ordered]@{}
        foreach ($FileName in $Parsed.PSObject.Properties.Name)
        {
            $Output[$FileName] = ConvertTo-CanonicalRecordSet -Records @($Parsed.$FileName)
        }
        return $Output
    }

    # Same layout as the expected file: one record per line.
    function Write-CanonicalMetricsOutput
    {
        param($Output, [string]$Path)

        $Lines = [System.Collections.Generic.List[string]]::new()
        $Lines.Add('{')
        $FileNames = @($Output.Keys)
        for ($FileIndex = 0; $FileIndex -lt $FileNames.Count; $FileIndex++)
        {
            $Lines.Add(('  "{0}": [' -f $FileNames[$FileIndex]))
            $RecordJson = @($Output[$FileNames[$FileIndex]].Values)
            for ($RecordIndex = 0; $RecordIndex -lt $RecordJson.Count; $RecordIndex++)
            {
                $Separator = if ($RecordIndex -lt $RecordJson.Count - 1) { ',' } else { '' }
                $Lines.Add('    ' + $RecordJson[$RecordIndex] + $Separator)
            }
            $Separator = if ($FileIndex -lt $FileNames.Count - 1) { ',' } else { '' }
            $Lines.Add('  ]' + $Separator)
        }
        $Lines.Add('}')
        Set-Content -LiteralPath $Path -Value $Lines -Encoding utf8
    }
}

AfterAll {
    if ($null -ne $script:SavedModulePath)
    {
        $env:PSModulePath = $script:SavedModulePath
    }
}

Describe 'Metrics.ps1 metric request definitions' {

    BeforeAll {
        $script:RdaMetricsTestHook.StopAfterDefinitions = $false
        $script:OutputDirectory = Join-Path $TestDrive 'fixture-output'
        Invoke-MetricsScript -Resources (New-MetricsFixture) -OutputDirectory $script:OutputDirectory
        $script:Definitions = @($script:RdaMetricsTestHook.Definitions)
    }

    It 'builds one definition per metric for every resource type it covers' {
        $script:Definitions.Count | Should -Be 57
        $Services = @($script:Definitions | ForEach-Object { $_.Service } | Sort-Object -Unique)
        $Services | Should -Be @('ContainerRegistry', 'CosmosDB', 'Functions', 'Managed Disk', 'MariaDB', 'MySQL', 'MySQL Flexible', 'PostgreSQL', 'PostgreSQL Flexible', 'SQL Database', 'Virtual Machines', 'Virtual Machines Scale Sets')
    }

    It 'builds every definition as an RdaMetricDefinition' {
        $Types = @($script:Definitions | ForEach-Object { $_.GetType().Name } | Sort-Object -Unique)
        $Types | Should -Be @('RdaMetricDefinition')
    }

    It 'keeps a missing subscription name as $null, not an empty string' {
        $Vm02 = @($script:Definitions | Where-Object { $_.Name -eq 'vm-02' })
        $Vm02.Count | Should -Be 2
        foreach ($Def in $Vm02)
        {
            $null -eq $Def.SubName | Should -BeTrue
        }
    }

    It 'writes metrics output identical to the expected records' {
        $Actual = Get-CanonicalMetricsOutput -Directory $script:OutputDirectory
        $Problems = [System.Collections.Generic.List[string]]::new()

        if (-not (Test-Path -LiteralPath $script:ExpectedOutputPath))
        {
            $Problems.Add("Expected output file not found: $script:ExpectedOutputPath")
        }
        else
        {
            $Expected = Read-ExpectedMetricsOutput -Path $script:ExpectedOutputPath
            $FileNames = @(@($Expected.Keys) + @($Actual.Keys) | Sort-Object -Unique)
            foreach ($FileName in $FileNames)
            {
                if (-not $Actual.Contains($FileName)) { $Problems.Add("Missing output file: $FileName"); continue }
                if (-not $Expected.Contains($FileName)) { $Problems.Add("Unexpected output file: $FileName"); continue }
                $ExpectedSet = $Expected[$FileName]
                $ActualSet = $Actual[$FileName]
                foreach ($Key in $ExpectedSet.Keys)
                {
                    if (-not $ActualSet.ContainsKey($Key)) { $Problems.Add("$FileName missing record $Key") }
                    elseif ($ActualSet[$Key] -cne $ExpectedSet[$Key]) { $Problems.Add("$FileName record $Key differs:`n  expected $($ExpectedSet[$Key])`n  actual   $($ActualSet[$Key])") }
                }
                foreach ($Key in $ActualSet.Keys)
                {
                    if (-not $ExpectedSet.ContainsKey($Key)) { $Problems.Add("$FileName unexpected record $Key") }
                }
            }
        }

        if ($Problems.Count -gt 0)
        {
            Write-CanonicalMetricsOutput -Output $Actual -Path $script:ActualOutputPath
            $Problems.Add("Actual output written to $script:ActualOutputPath")
        }
        $Problems | Should -BeNullOrEmpty
    }
}

Describe 'Metrics.ps1 metric request definition size' {

    It 'holds 40,000 disk metric definitions in under 1,000 bytes each' {
        $Resources = for ($Index = 1; $Index -le 10000; $Index++)
        {
            $Name = 'disk-{0:D5}' -f $Index
            $VmId = '/subscriptions/{0}/resourceGroups/rg-metrics/providers/Microsoft.Compute/virtualMachines/vm-{1:D5}' -f $script:SubscriptionId, $Index
            New-TestResource -Type 'microsoft.compute/disks' -Provider 'Microsoft.Compute/disks' -Name $Name -ManagedBy $VmId
        }

        $script:RdaMetricsTestHook.StopAfterDefinitions = $true
        try
        {
            [System.GC]::Collect()
            [System.GC]::WaitForPendingFinalizers()
            [System.GC]::Collect()
            $HeapBefore = [System.GC]::GetTotalMemory($true)
            Invoke-MetricsScript -Resources $Resources -OutputDirectory (Join-Path $TestDrive 'size-output')
        }
        finally
        {
            $script:RdaMetricsTestHook.StopAfterDefinitions = $false
        }

        $script:RdaMetricsTestHook.DefinitionCount | Should -Be 40000
        $BytesPerDefinition = ($script:RdaMetricsTestHook.HeapAfterDefinitions - $HeapBefore) / $script:RdaMetricsTestHook.DefinitionCount
        $BytesPerDefinition | Should -BeLessThan 1000 -Because 'every definition is held until the metrics phase ends'
    }
}
