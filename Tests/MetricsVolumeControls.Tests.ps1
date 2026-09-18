# Output-level proof of Metrics.ps1 volume controls (-IncludeStorageMetrics/-SkipDiskMetrics/
# -MetricsIntervalMinutes), each env-gated so inert when unset; necessary-not-sufficient (no with/without baseline).

BeforeAll {
    # The sampled series the -MetricsIntervalMinutes knob overrides, kept in lockstep
    # with Extension/Metrics.ps1; scoped by BOTH Service and Metric so only knob-controlled series match.
    $script:GrainTargetServices = @('Virtual Machines', 'SQL Database', 'MariaDB', 'MySQL', 'MySQL Flexible', 'PostgreSQL', 'PostgreSQL Flexible')
    $script:GrainTargetMetrics = @('Percentage CPU', 'Available Memory Bytes', 'cpu_used', 'dtu_used', 'cpu_percent', 'memory_percent')

    $ZipPath = $env:TEST_ZIP_PATH
    # Only extract/parse when a zip is present AND at least one expectation is set
    # (mirrors ServiceScope.Tests.ps1). Avoids parsing every Metrics_*.json just to
    # Skip every It when this suite is inert for the current scenario.
    $script:AnyExpectation = ($env:TEST_EXPECT_NO_STORAGE_METRICS -eq '1') -or ($env:TEST_EXPECT_STORAGE_METRICS -eq '1') -or ($env:TEST_EXPECT_NO_DISK_METRICS -eq '1') -or (-not [string]::IsNullOrEmpty($env:TEST_EXPECT_METRIC_GRAIN_MINUTES))
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

        # Storage-account count from the same bundle: the positive assertion must not
        # hard-fail on a tenant that owns none, and it stops the absence assertion passing vacuously.
        $script:StorageAccountCount = 0
        foreach ($InvFile in @(Get-ChildItem -Path $script:ExtractPath -Filter 'Inventory_*.json' -Recurse))
        {
            $Inv = Get-Content $InvFile.FullName -Raw | ConvertFrom-Json
            if ($null -ne $Inv.StorageAcc) { $script:StorageAccountCount += @($Inv.StorageAcc).Count }
        }
    }
}

AfterAll {
    if ($script:ExtractPath -and (Test-Path $script:ExtractPath)) { Remove-Item -Path $script:ExtractPath -Recurse -Force }
}

Describe 'Metrics Volume Controls' {
    It 'emits no Storage Account metrics when the capacity metric was not opted into' {
        if ($env:TEST_EXPECT_NO_STORAGE_METRICS -ne '1') { Set-ItResult -Skipped -Because 'TEST_EXPECT_NO_STORAGE_METRICS not set'; return }
        if (-not $script:Active) { Set-ItResult -Skipped -Because 'TEST_ZIP_PATH not set / missing'; return }
        if ($script:StorageAccountCount -eq 0) { Set-ItResult -Skipped -Because 'this subscription owns no storage account, so an absence of storage metrics would prove nothing'; return }
        $Storage = @($script:Metrics | Where-Object { $_.Service -eq 'Storage Account' })
        $Storage.Count | Should -Be 0 -Because 'the UsedCapacity def must be absent by DEFAULT (it is opt-in)'
    }

    # The counterpart to the assertion above. Without this, that absence test would
    # pass TRIVIALLY now that the metric is opt-in: a zip with no storage metrics
    # proves nothing unless something also proves the opt-in turns them ON. This is
    # the assertion that makes -IncludeStorageMetrics meaningful.
    It 'emits Storage Account UsedCapacity metrics when -IncludeStorageMetrics was set' {
        if ($env:TEST_EXPECT_STORAGE_METRICS -ne '1') { Set-ItResult -Skipped -Because 'TEST_EXPECT_STORAGE_METRICS not set'; return }
        if (-not $script:Active) { Set-ItResult -Skipped -Because 'TEST_ZIP_PATH not set / missing'; return }
        if ($script:StorageAccountCount -eq 0) { Set-ItResult -Skipped -Because 'this subscription owns no storage account, so there is no capacity metric to collect'; return }
        $Storage = @($script:Metrics | Where-Object { $_.Service -eq 'Storage Account' })
        $Storage.Count | Should -BeGreaterThan 0 -Because '-IncludeStorageMetrics must add the UsedCapacity def back'
        # The emitted record names the metric in 'Metric'. ('MetricName' is the field
        # on the internal $MetricDefs definition inside Extension/Metrics.ps1, not on
        # the record that reaches Metrics_*.json - asserting that name silently
        # matches nothing.)
        @($Storage | Where-Object { $_.Metric -eq 'UsedCapacity' }).Count | Should -BeGreaterThan 0 -Because 'the opted-in storage metric is specifically UsedCapacity'
    }

    It 'emits no Managed Disk metrics when -SkipDiskMetrics was set' {
        if ($env:TEST_EXPECT_NO_DISK_METRICS -ne '1') { Set-ItResult -Skipped -Because 'TEST_EXPECT_NO_DISK_METRICS not set'; return }
        if (-not $script:Active) { Set-ItResult -Skipped -Because 'TEST_ZIP_PATH not set / missing'; return }
        $Disk = @($script:Metrics | Where-Object { $_.Service -eq 'Managed Disk' })
        $Disk.Count | Should -Be 0 -Because '-SkipDiskMetrics must drop the four composite disk-I/O defs entirely'
    }

    It 'applies the requested grain uniformly to the VM/SQL/OSS-DB sampled series when -MetricsIntervalMinutes was set' {
        if ([string]::IsNullOrEmpty($env:TEST_EXPECT_METRIC_GRAIN_MINUTES)) { Set-ItResult -Skipped -Because 'TEST_EXPECT_METRIC_GRAIN_MINUTES not set'; return }
        if (-not $script:Active) { Set-ItResult -Skipped -Because 'TEST_ZIP_PATH not set / missing'; return }

        # -MetricsIntervalMinutes applies the operator's chosen grain UNIFORMLY to
        # every knob-controlled sampled series (VM / SQL / OSS-DB) and honours it
        # as-is (not clamped), so all of them must carry exactly the requested grain.
        $ExpectedGrain = ([TimeSpan]::FromMinutes([int]$env:TEST_EXPECT_METRIC_GRAIN_MINUTES)).ToString()
        $Sampled = @($script:Metrics | Where-Object { $_.Service -in $script:GrainTargetServices -and $_.Metric -in $script:GrainTargetMetrics })
        if ($Sampled.Count -eq 0) { Set-ItResult -Skipped -Because 'this subscription produced no VM/SQL/OSS-DB sampled-series metrics to inspect'; return }

        $Wrong = @($Sampled | Where-Object { $_.MetricTimeGrain -ne $ExpectedGrain })
        $Wrong.Count | Should -Be 0 -Because ("every VM/SQL/OSS-DB sampled series should carry the requested grain {0}; found {1} record(s) with a different grain (e.g. Service '{2}' grain '{3}')" -f $ExpectedGrain, $Wrong.Count, ($Wrong | Select-Object -First 1 -ExpandProperty Service), ($Wrong | Select-Object -First 1 -ExpandProperty MetricTimeGrain))
    }
}
