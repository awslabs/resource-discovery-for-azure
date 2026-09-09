# Output Completeness Tests
# Validates the output zip contains all expected files with correct structure
# Run with: Invoke-Pester ./Tests/OutputCompleteness.Tests.ps1 -Output Detailed

BeforeAll {
    $ZipPath = if ($env:TEST_ZIP_PATH) { $env:TEST_ZIP_PATH } else
    {
        Get-ChildItem -Path $PSScriptRoot -Filter "ResourcesReport_*.zip" |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
    if ([string]::IsNullOrEmpty($ZipPath) -or -not (Test-Path $ZipPath))
    {
        throw "No test zip found. Copy a ResourcesReport_*.zip to Tests/ or set `$env:TEST_ZIP_PATH"
    }
    $TmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { "/tmp" }
    $script:ExtractPath = Join-Path $TmpBase ("CompleteTest_" + [guid]::NewGuid().ToString().Substring(0, 8))
    New-Item -ItemType Directory -Path $script:ExtractPath -Force | Out-Null
    Expand-Archive -Path $ZipPath -DestinationPath $script:ExtractPath -Force

    $script:AllFiles = Get-ChildItem -Path $script:ExtractPath -File
    $InvFile = Get-ChildItem -Path $script:ExtractPath -Filter "Inventory_*.json" | Select-Object -First 1
    $script:Inventory = if ($InvFile) { Get-Content $InvFile.FullName -Raw | ConvertFrom-Json } else { $null }

    # Determine obfuscation state FROM THE BUNDLE rather than from an env var, so
    # the rule holds for any zip a human points the suite at. Every run - both
    # branches - ships a Diagnostics_*.log whose first line states which mode
    # produced it (Write-RdaShareableDiagnosticsLog). Absent that header the
    # bundle is treated as OBFUSCATED, i.e. fail closed to the stricter rule.
    $DiagFile = Get-ChildItem -Path $script:ExtractPath -Filter "Diagnostics_*.log" | Select-Object -First 1
    $script:IsObfuscatedBundle = $true
    if ($DiagFile)
    {
        $DiagHead = Get-Content -LiteralPath $DiagFile.FullName -TotalCount 5 -ErrorAction SilentlyContinue
        if (($DiagHead -join ' ') -match 'non-obfuscated') { $script:IsObfuscatedBundle = $false }
    }
}

AfterAll {
    if (Test-Path $script:ExtractPath) { Remove-Item -Path $script:ExtractPath -Recurse -Force }
}

Describe "Zip File Contents" {
    It "Should contain an HTML report file" {
        $Html = $script:AllFiles | Where-Object { $_.Extension -eq '.html' }
        $Html | Should -Not -BeNullOrEmpty
    }

    It "Should contain an inventory JSON file" {
        $Json = $script:AllFiles | Where-Object { $_.Name -like 'Inventory_*' }
        $Json | Should -Not -BeNullOrEmpty
    }

    It "Should contain at least one metrics JSON file" {
        $Metrics = $script:AllFiles | Where-Object { $_.Name -like 'Metrics_*' }
        $Metrics | Should -Not -BeNullOrEmpty
    }

    It "Should contain a consumption CSV file" {
        $Csv = $script:AllFiles | Where-Object { $_.Name -like 'Consumption_*' }
        $Csv | Should -Not -BeNullOrEmpty
    }

    It "Should not contain any unexpected file types" {
        # The report members are .html / .json / .csv. Permitted .log files depend
        # on whether the bundle is obfuscated:
        #
        #   Diagnostics_*.log - ALWAYS allowed. Curated + dictionary-scrubbed, and
        #     deliberately kept as .log so the ingestion pipeline does not
        #     table-ingest it.
        #   DebugLog_*.log    - allowed ONLY in a NON-obfuscated bundle. It carries
        #     real service/resource names and raw exception text, which adds no new
        #     class of identifier to a bundle whose report is already
        #     non-obfuscated, and it is what makes a thin report diagnosable
        #     without a second Collect-SupportLogs round-trip. In an OBFUSCATED
        #     bundle it must NEVER appear - that bundle's whole guarantee is that it
        #     carries no real identifiers, and the debug log is not scrubbed.
        #
        # Every other .log (ErrorLog_*, Heartbeat_*) and the transcript .txt stay
        # LOCAL-only in both modes.
        $AllowedExtensions = @('.html', '.json', '.csv')
        foreach ($file in $script:AllFiles)
        {
            if ($file.Extension -eq '.log')
            {
                if ($script:IsObfuscatedBundle)
                {
                    $file.Name | Should -BeLike 'Diagnostics_*.log' -Because "the only .log allowed in an OBFUSCATED bundle is Diagnostics_*.log; '$($file.Name)' is not dictionary-scrubbed and must not ship"
                }
                else
                {
                    ($file.Name -like 'Diagnostics_*.log' -or $file.Name -like 'DebugLog_*.log') | Should -BeTrue -Because "a non-obfuscated bundle may ship Diagnostics_*.log and DebugLog_*.log only; '$($file.Name)' is a local-only log that must not ship"
                }
            }
            else
            {
                $file.Extension | Should -BeIn $AllowedExtensions -Because "File '$($file.Name)' has unexpected extension"
            }
        }
    }

    It "Should never ship the debug log in an obfuscated bundle" {
        # Dedicated assertion so the security-relevant half of the rule above
        # fails with an unmistakable message rather than as a generic
        # unexpected-file-type failure.
        if (-not $script:IsObfuscatedBundle)
        {
            Set-ItResult -Skipped -Because 'this bundle is not obfuscated; the debug log is permitted here by design'
            return
        }
        $LeakedDebug = $script:AllFiles | Where-Object { $_.Name -like 'DebugLog_*' }
        $LeakedDebug | Should -BeNullOrEmpty -Because 'the debug log is not dictionary-scrubbed and must never ship in an obfuscated bundle'
    }

    It "Should not contain dictionary or transcript files" {
        $Leaked = $script:AllFiles | Where-Object { $_.Name -like 'ObfuscationDictionary_*' -or $_.Name -like 'Transcript_*' }
        $Leaked | Should -BeNullOrEmpty
    }
}

Describe "Inventory JSON Structure" {
    It "Should have a Version field" {
        $script:Inventory.Version | Should -Not -BeNullOrEmpty
    }

    It "Should have at least one resource type with data" {
        $Populated = $script:Inventory.PSObject.Properties | Where-Object { $null -ne $_.Value -and $_.Name -ne 'Version' }
        $Populated.Count | Should -BeGreaterThan 0 -Because "At least one service should have discovered resources"
    }

    # Title says ID and Location ONLY, and deliberately does not claim Name. A plain
    # 'Name' column is NOT universal: Services/Compute/ARO.ps1 and
    # Services/Storage/NetApp.ps1 emit none, and Services/Infrastructure/AutomationAcc.ps1
    # uses the domain-specific AutomationAccountName / RunbookName instead. So asserting
    # Name here would fail on real output.
    #
    # The previous title read "ID, Name, and Location" while the body checked only two of
    # the three, which is the worse failure of the two available: a reader trusts the
    # title, and the obvious "fix" is to add the missing assertion - which then breaks on
    # three legitimate collectors and looks like a collector bug rather than a test bug.
    It "Every resource should have ID and Location fields" {
        $script:Inventory.PSObject.Properties | Where-Object { $null -ne $_.Value -and $_.Name -ne 'Version' } | ForEach-Object {
            @($_.Value) | ForEach-Object {
                if ($null -ne $_)
                {
                    $_.PSObject.Properties.Name | Should -Contain 'ID' -Because "Resource in $($_.Name) should have ID"
                    $_.PSObject.Properties.Name | Should -Contain 'Location' -Because "Resource should have Location"
                }
            }
        }
    }
}

Describe "Metrics JSON Structure" {
    It "Every metrics file should have a Metrics array" {
        $MetricsFiles = Get-ChildItem -Path $script:ExtractPath -Filter "Metrics_*.json"
        foreach ($mf in $MetricsFiles)
        {
            $Data = Get-Content $mf.FullName -Raw | ConvertFrom-Json
            $Data.PSObject.Properties.Name | Should -Contain 'Metrics'
        }
    }

    It "Each metric entry should have Service, Metric, and MetricValue fields" {
        $MetricsFiles = Get-ChildItem -Path $script:ExtractPath -Filter "Metrics_*.json"
        foreach ($mf in $MetricsFiles)
        {
            $Data = Get-Content $mf.FullName -Raw | ConvertFrom-Json
            foreach ($m in @($Data.Metrics))
            {
                if ($null -ne $m)
                {
                    $m.PSObject.Properties.Name | Should -Contain 'Service'
                    $m.PSObject.Properties.Name | Should -Contain 'Metric'
                    $m.PSObject.Properties.Name | Should -Contain 'MetricValue'
                }
            }
        }
    }
}

Describe "Non-Sensitive Fields Preserved" {
    It "VM Location should be a real Azure region (not obfuscated)" {
        $Vms = @($script:Inventory.VirtualMachines)
        foreach ($vm in $Vms)
        {
            if ($null -ne $vm)
            {
                $vm.Location | Should -Not -Match '^(prod|nonprod)_' -Because "Location should be a real region, not obfuscated"
            }
        }
    }

    It "VM Size should be a real Azure VM size" {
        $Vms = @($script:Inventory.VirtualMachines)
        foreach ($vm in $Vms)
        {
            if ($null -ne $vm -and ![string]::IsNullOrEmpty($vm.Size))
            {
                # Same rationale as DataIntegrity.Tests.ps1: VM SKUs include
                # Standard_*, Basic_*, M*, N* etc. The invariant under test is
                # "not obfuscated", not a particular naming convention.
                $vm.Size | Should -Not -Match '^(prod|nonprod)_' -Because "VM Size should not be obfuscated"
            }
        }
    }

    It "VM OS should be a real OS type" {
        $Vms = @($script:Inventory.VirtualMachines)
        foreach ($vm in $Vms)
        {
            if ($null -ne $vm -and ![string]::IsNullOrEmpty($vm.OSType))
            {
                $vm.OSType | Should -BeIn @('windows', 'linux') -Because "OSType should be windows or linux"
            }
        }
    }

    It "Storage SKU should be a real Azure storage SKU" {
        $Storage = @($script:Inventory.StorageAcc)
        foreach ($sa in $Storage)
        {
            if ($null -ne $sa -and ![string]::IsNullOrEmpty($sa.SKU))
            {
                $sa.SKU | Should -Not -Match '^(prod|nonprod)_' -Because "Storage SKU should be real, not obfuscated"
            }
        }
    }
}
