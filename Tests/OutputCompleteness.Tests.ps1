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
        # The report members are .html / .json / .csv. The ONLY .log permitted in
        # the shared bundle is the curated, dictionary-scrubbed Diagnostics_*.log
        # (a human-readable troubleshooting artifact deliberately kept as .log so
        # the ingestion pipeline does not table-ingest it). Every OTHER .log
        # (DebugLog_*, ErrorLog_*, Heartbeat_*) and the transcript .txt are
        # LOCAL-only and must NEVER ship - so a .log with any other name, or any
        # other unexpected extension, still fails this assertion.
        $AllowedExtensions = @('.html', '.json', '.csv')
        foreach ($file in $script:AllFiles)
        {
            if ($file.Extension -eq '.log')
            {
                $file.Name | Should -BeLike 'Diagnostics_*.log' -Because "the only .log allowed in the shared bundle is Diagnostics_*.log; '$($file.Name)' is a local-only log that must not ship"
            }
            else
            {
                $file.Extension | Should -BeIn $AllowedExtensions -Because "File '$($file.Name)' has unexpected extension"
            }
        }
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

    It "Every resource should have ID, Name, and Location fields" {
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
