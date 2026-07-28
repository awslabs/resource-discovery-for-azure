# Metrics Volume Controls Tests
# =============================================================================
# Output-level proof of the opt-in metric-volume controls on Metrics.ps1
# (threaded through ResourceInventory.ps1 / the wrappers):
#   -SkipStorageMetrics      : no Storage Account metric records are emitted.
#   -SkipDiskMetrics         : no Managed Disk metric records are emitted.
#   -MetricsIntervalMinutes N: the high-frequency SAMPLED utilization series - VM
#                              (Percentage CPU / Available Memory Bytes), Azure SQL
#                              DB (cpu_used / dtu_used / cpu_percent) and the OSS DBs
#                              MariaDB / MySQL / PostgreSQL + Flexible (cpu_percent /
#                              memory_percent) - carry the N-minute grain.
#
# Driven by environment variables (same pattern as the other suites):
#   $env:TEST_ZIP_PATH                    - the output zip to validate (required)
#   $env:TEST_EXPECT_NO_STORAGE_METRICS   - '1' => assert 0 'Storage Account' records
#   $env:TEST_EXPECT_NO_DISK_METRICS      - '1' => assert 0 'Managed Disk' records
#   $env:TEST_EXPECT_METRIC_GRAIN_MINUTES - e.g. '60' => assert the VM/SQL sampled
#                                           series carry that grain (hh:mm:ss)
#
# Each assertion is independently gated on its env var, so the suite is inert
# (all Skipped) for scenarios / standalone runs that do not set them.
#
# COVERAGE NOTE (these are necessary, not sufficient, checks): the absence
# assertions pass when there are 0 records of that Service, which is also true if
# the target subscription simply has no storage accounts / no attached disks - so
# a green result confirms "the flag did not leave any such records" but does NOT
# by itself prove the flag removed something that would otherwise be present
# (there is no with/without baseline here). Likewise the grain check Skips (not
# fails) when the subscription has no VM/SQL/OSS-DB sampled series to inspect.
# Treat these as output-shape smoke tests; the with/without proof is the
# scenario matrix generating a real zip per flag combination.
#
# The grain check deliberately targets ONLY the knob-controlled sampled series
# (scoped by BOTH Service and Metric) - it does NOT assert on Managed Disk (also
# 15-min but NOT covered by the interval knob), VM Scale Sets (fixed 1-hr), or
# the Series='false' capacity reads, which keep their native cadence.
#
# Run with (point TEST_ZIP_PATH at ONE concrete zip, not a wildcard):
#   $env:TEST_ZIP_PATH = '/path/to/ResourcesReport_<timestamp>.zip'
#   $env:TEST_EXPECT_NO_STORAGE_METRICS = '1'
#   Invoke-Pester ./Tests/MetricsVolumeControls.Tests.ps1 -Output Detailed
# =============================================================================

BeforeAll {
    # The high-frequency SAMPLED utilization series the -MetricsIntervalMinutes
    # knob overrides. Kept in lockstep with Extension/Metrics.ps1: these are the
    # only defs that reference $VmMetricInterval / $SqlMetricInterval / $DbMetricInterval.
    # The grain check scopes by BOTH Service and Metric name so it targets ONLY the
    # knob-controlled series: VM (Percentage CPU / Available Memory Bytes), Azure
    # SQL DB (cpu_used / dtu_used / cpu_percent), and the OSS DBs MariaDB / MySQL /
    # PostgreSQL + Flexible (cpu_percent / memory_percent). It deliberately excludes
    # the Series='false' capacity reads (storage_percent, physical_data_read_percent,
    # log_write_percent), the daily SQL limit reads, and the Managed Disk metrics -
    # none of which are governed by the knob.
    $script:GrainTargetServices = @('Virtual Machines', 'SQL Database', 'MariaDB', 'MySQL', 'MySQL Flexible', 'PostgreSQL', 'PostgreSQL Flexible')
    $script:GrainTargetMetrics = @('Percentage CPU', 'Available Memory Bytes', 'cpu_used', 'dtu_used', 'cpu_percent', 'memory_percent')

    $ZipPath = $env:TEST_ZIP_PATH
    # Only extract/parse when a zip is present AND at least one expectation is set
    # (mirrors ServiceScope.Tests.ps1). Avoids parsing every Metrics_*.json just to
    # Skip all three Its when this suite is inert for the current scenario.
    $script:AnyExpectation = ($env:TEST_EXPECT_NO_STORAGE_METRICS -eq '1') -or ($env:TEST_EXPECT_NO_DISK_METRICS -eq '1') -or (-not [string]::IsNullOrEmpty($env:TEST_EXPECT_METRIC_GRAIN_MINUTES))
    $script:Active = (-not [string]::IsNullOrEmpty($ZipPath)) -and (Test-Path $ZipPath) -and $script:AnyExpectation

    $script:Metrics = @()
    if ($script:Active)
    {
        $TmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { '/tmp' }
        $script:ExtractPath = Join-Path $TmpBase ("MetricsVolCtrlTest_" + [guid]::NewGuid().ToString().Substring(0, 8))
        New-Item -ItemType Directory -Path $script:ExtractPath -Force | Out-Null
        Expand-Archive -Path $ZipPath -DestinationPath $script:ExtractPath -Force

        # Metrics are written in one or more chunk files (Metrics_..._N.json), each
        # an object with a .Metrics array. Aggregate every chunk's records.
        foreach ($MetricsFile in @(Get-ChildItem -Path $script:ExtractPath -Filter 'Metrics_*.json' -Recurse))
        {
            $Doc = Get-Content $MetricsFile.FullName -Raw | ConvertFrom-Json
            if ($null -ne $Doc.Metrics) { $script:Metrics += @($Doc.Metrics) }
        }
    }
}

AfterAll {
    if ($script:ExtractPath -and (Test-Path $script:ExtractPath)) { Remove-Item -Path $script:ExtractPath -Recurse -Force }
}

Describe 'Metrics Volume Controls' {
    It 'emits no Storage Account metrics when -SkipStorageMetrics was set' {
        if ($env:TEST_EXPECT_NO_STORAGE_METRICS -ne '1') { Set-ItResult -Skipped -Because 'TEST_EXPECT_NO_STORAGE_METRICS not set'; return }
        if (-not $script:Active) { Set-ItResult -Skipped -Because 'TEST_ZIP_PATH not set / missing'; return }
        $Storage = @($script:Metrics | Where-Object { $_.Service -eq 'Storage Account' })
        $Storage.Count | Should -Be 0 -Because '-SkipStorageMetrics must drop the UsedCapacity def entirely'
    }

    It 'emits no Managed Disk metrics when -SkipDiskMetrics was set' {
        if ($env:TEST_EXPECT_NO_DISK_METRICS -ne '1') { Set-ItResult -Skipped -Because 'TEST_EXPECT_NO_DISK_METRICS not set'; return }
        if (-not $script:Active) { Set-ItResult -Skipped -Because 'TEST_ZIP_PATH not set / missing'; return }
        $Disk = @($script:Metrics | Where-Object { $_.Service -eq 'Managed Disk' })
        $Disk.Count | Should -Be 0 -Because '-SkipDiskMetrics must drop the four composite disk-I/O defs entirely'
    }

    It 'applies the requested grain to the VM/SQL sampled series when -MetricsIntervalMinutes was set' {
        if ([string]::IsNullOrEmpty($env:TEST_EXPECT_METRIC_GRAIN_MINUTES)) { Set-ItResult -Skipped -Because 'TEST_EXPECT_METRIC_GRAIN_MINUTES not set'; return }
        if (-not $script:Active) { Set-ItResult -Skipped -Because 'TEST_ZIP_PATH not set / missing'; return }

        $ExpectedGrain = ([TimeSpan]::FromMinutes([int]$env:TEST_EXPECT_METRIC_GRAIN_MINUTES)).ToString()
        $Sampled = @($script:Metrics | Where-Object { $_.Service -in $script:GrainTargetServices -and $_.Metric -in $script:GrainTargetMetrics })
        if ($Sampled.Count -eq 0) { Set-ItResult -Skipped -Because 'this subscription produced no VM/SQL sampled-series metrics to inspect'; return }

        $Wrong = @($Sampled | Where-Object { $_.MetricTimeGrain -ne $ExpectedGrain })
        $Wrong.Count | Should -Be 0 -Because ("every VM/SQL sampled series should carry grain {0}; found {1} record(s) with a different grain (e.g. '{2}')" -f $ExpectedGrain, $Wrong.Count, ($Wrong | Select-Object -First 1 -ExpandProperty MetricTimeGrain))
    }
}
