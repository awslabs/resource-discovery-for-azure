# Output Completeness Tests
# Validates the output zip contains all expected files with correct structure
# Run with: Invoke-Pester ./Tests/OutputCompleteness.Tests.ps1 -Output Detailed

BeforeAll {
    $zipPath = if ($env:TEST_ZIP_PATH) { $env:TEST_ZIP_PATH } else {
        Get-ChildItem -Path $PSScriptRoot -Filter "ResourcesReport_*.zip" | 
            Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
    if ([string]::IsNullOrEmpty($zipPath) -or -not (Test-Path $zipPath)) {
        throw "No test zip found. Copy a ResourcesReport_*.zip to Tests/ or set `$env:TEST_ZIP_PATH"
    }
    $tmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { "/tmp" }
    $script:ExtractPath = Join-Path $tmpBase ("CompleteTest_" + [guid]::NewGuid().ToString().Substring(0,8))
    New-Item -ItemType Directory -Path $script:ExtractPath -Force | Out-Null
    Expand-Archive -Path $zipPath -DestinationPath $script:ExtractPath -Force

    $script:AllFiles = Get-ChildItem -Path $script:ExtractPath -File
    $invFile = Get-ChildItem -Path $script:ExtractPath -Filter "Inventory_*.json" | Select-Object -First 1
    $script:Inventory = if ($invFile) { Get-Content $invFile.FullName -Raw | ConvertFrom-Json } else { $null }
}

AfterAll {
    if (Test-Path $script:ExtractPath) { Remove-Item -Path $script:ExtractPath -Recurse -Force }
}

Describe "Zip File Contents" {
    It "Should contain an Excel report file" {
        $xlsx = $script:AllFiles | Where-Object { $_.Extension -eq '.xlsx' }
        $xlsx | Should -Not -BeNullOrEmpty
    }

    It "Should contain an inventory JSON file" {
        $json = $script:AllFiles | Where-Object { $_.Name -like 'Inventory_*' }
        $json | Should -Not -BeNullOrEmpty
    }

    It "Should contain at least one metrics JSON file" {
        $metrics = $script:AllFiles | Where-Object { $_.Name -like 'Metrics_*' }
        $metrics | Should -Not -BeNullOrEmpty
    }

    It "Should contain a consumption CSV file" {
        $csv = $script:AllFiles | Where-Object { $_.Name -like 'Consumption_*' }
        $csv | Should -Not -BeNullOrEmpty
    }

    It "Should not contain any unexpected file types" {
        $allowedExtensions = @('.xlsx', '.json', '.csv')
        foreach ($file in $script:AllFiles) {
            $file.Extension | Should -BeIn $allowedExtensions -Because "File '$($file.Name)' has unexpected extension"
        }
    }

    It "Should not contain dictionary or transcript files" {
        $leaked = $script:AllFiles | Where-Object { $_.Name -like 'ObfuscationDictionary_*' -or $_.Name -like 'Transcript_*' }
        $leaked | Should -BeNullOrEmpty
    }
}

Describe "Inventory JSON Structure" {
    It "Should have a Version field" {
        $script:Inventory.Version | Should -Not -BeNullOrEmpty
    }

    It "Should have at least one resource type with data" {
        $populated = $script:Inventory.PSObject.Properties | Where-Object { $null -ne $_.Value -and $_.Name -ne 'Version' }
        $populated.Count | Should -BeGreaterThan 0 -Because "At least one service should have discovered resources"
    }

    It "Every resource should have ID, Name, and Location fields" {
        $script:Inventory.PSObject.Properties | Where-Object { $null -ne $_.Value -and $_.Name -ne 'Version' } | ForEach-Object {
            @($_.Value) | ForEach-Object {
                if ($null -ne $_) {
                    $_.PSObject.Properties.Name | Should -Contain 'ID' -Because "Resource in $($_.Name) should have ID"
                    $_.PSObject.Properties.Name | Should -Contain 'Location' -Because "Resource should have Location"
                }
            }
        }
    }
}

Describe "Metrics JSON Structure" {
    It "Every metrics file should have a Metrics array" {
        $metricsFiles = Get-ChildItem -Path $script:ExtractPath -Filter "Metrics_*.json"
        foreach ($mf in $metricsFiles) {
            $data = Get-Content $mf.FullName -Raw | ConvertFrom-Json
            $data.PSObject.Properties.Name | Should -Contain 'Metrics'
        }
    }

    It "Each metric entry should have Service, Metric, and MetricValue fields" {
        $metricsFiles = Get-ChildItem -Path $script:ExtractPath -Filter "Metrics_*.json"
        foreach ($mf in $metricsFiles) {
            $data = Get-Content $mf.FullName -Raw | ConvertFrom-Json
            foreach ($m in @($data.Metrics)) {
                if ($null -ne $m) {
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
        $vms = @($script:Inventory.VirtualMachines)
        foreach ($vm in $vms) {
            if ($null -ne $vm) {
                $vm.Location | Should -Not -Match '^(prod|nonprod)_' -Because "Location should be a real region, not obfuscated"
            }
        }
    }

    It "VM Size should be a real Azure VM size" {
        $vms = @($script:Inventory.VirtualMachines)
        foreach ($vm in $vms) {
            if ($null -ne $vm -and ![string]::IsNullOrEmpty($vm.Size)) {
                $vm.Size | Should -Match '^standard_' -Because "VM Size should be a real Azure size like standard_d2s_v5"
            }
        }
    }

    It "VM OS should be a real OS type" {
        $vms = @($script:Inventory.VirtualMachines)
        foreach ($vm in $vms) {
            if ($null -ne $vm -and ![string]::IsNullOrEmpty($vm.OS)) {
                $vm.OS | Should -BeIn @('windows', 'linux') -Because "OS should be windows or linux"
            }
        }
    }

    It "Storage SKU should be a real Azure storage SKU" {
        $storage = @($script:Inventory.StorageAcc)
        foreach ($sa in $storage) {
            if ($null -ne $sa -and ![string]::IsNullOrEmpty($sa.SKU)) {
                $sa.SKU | Should -Not -Match '^(prod|nonprod)_' -Because "Storage SKU should be real, not obfuscated"
            }
        }
    }
}
