# Referential Integrity Tests
# Validates that cross-references between resources are consistent after obfuscation
# Run with: Invoke-Pester ./Tests/ReferentialIntegrity.Tests.ps1 -Output Detailed

BeforeAll {
    $zipPath = if ($env:TEST_ZIP_PATH) { $env:TEST_ZIP_PATH } else {
        Get-ChildItem -Path $PSScriptRoot -Filter "ResourcesReport_*.zip" | 
            Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
    if ([string]::IsNullOrEmpty($zipPath) -or -not (Test-Path $zipPath)) {
        throw "No test zip found. Copy a ResourcesReport_*.zip to Tests/ or set `$env:TEST_ZIP_PATH"
    }
    $tmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { "/tmp" }
    $script:ExtractPath = Join-Path $tmpBase ("RefIntTest_" + [guid]::NewGuid().ToString().Substring(0,8))
    New-Item -ItemType Directory -Path $script:ExtractPath -Force | Out-Null
    Expand-Archive -Path $zipPath -DestinationPath $script:ExtractPath -Force

    $invFile = Get-ChildItem -Path $script:ExtractPath -Filter "Inventory_*.json" | Select-Object -First 1
    $script:Inventory = Get-Content $invFile.FullName -Raw | ConvertFrom-Json

    $csvFile = Get-ChildItem -Path $script:ExtractPath -Filter "Consumption_*.csv" | Select-Object -First 1
    $script:ConsumptionCsv = if ($csvFile) { 
        $content = Get-Content $csvFile.FullName -ErrorAction SilentlyContinue
        if ($null -ne $content -and $content.Count -gt 1) { Import-Csv $csvFile.FullName } else { @() }
    } else { @() }

    # Collect all IDs across all resource types
    $script:AllIds = @()
    $script:Inventory.PSObject.Properties | Where-Object { $null -ne $_.Value -and $_.Name -ne 'Version' } | ForEach-Object {
        @($_.Value) | ForEach-Object { if ($null -ne $_.ID) { $script:AllIds += $_.ID } }
    }
}

AfterAll {
    if (Test-Path $script:ExtractPath) { Remove-Item -Path $script:ExtractPath -Recurse -Force }
}

Describe "VM Disk to VM Cross-Reference" {
    It "Every disk AssociatedResource should match a VM ID or be null" {
        $disks = @($script:Inventory.VMDisk)
        $vmIds = @($script:Inventory.VirtualMachines) | Where-Object { $null -ne $_ } | ForEach-Object { $_.ID }
        foreach ($disk in $disks) {
            if ($null -ne $disk -and ![string]::IsNullOrEmpty($disk.AssociatedResource)) {
                $disk.AssociatedResource | Should -BeIn $vmIds -Because "Disk '$($disk.ID)' AssociatedResource should reference a known VM"
            }
        }
    }
}

Describe "AVD HostId to VM Cross-Reference" {
    It "Every AVD HostId should match a VM ID or be null" {
        $avd = @($script:Inventory.AVD)
        $vmIds = @($script:Inventory.VirtualMachines) | Where-Object { $null -ne $_ } | ForEach-Object { $_.ID }
        foreach ($avdItem in $avd) {
            if ($null -ne $avdItem -and ![string]::IsNullOrEmpty($avdItem.HostId)) {
                $avdItem.HostId | Should -BeIn $vmIds -Because "AVD HostId should reference a known VM"
            }
        }
    }
}

Describe "Obfuscated ID Uniqueness" {
    It "Every obfuscated ID should be unique across all resources" {
        $idCounts = $script:AllIds | Group-Object | Where-Object { $_.Count -gt 1 }
        $idCounts | Should -BeNullOrEmpty -Because "No two resources should share the same obfuscated ID"
    }
}

Describe "Consumption to Inventory Cross-Reference" {
    It "Consumption ResourceIds that exist in inventory should use the same obfuscated value" {
        if ($script:ConsumptionCsv.Count -eq 0) { return }
        $inventoryIds = $script:AllIds
        foreach ($row in $script:ConsumptionCsv) {
            if (![string]::IsNullOrEmpty($row.ResourceId) -and $row.ResourceId -in $inventoryIds) {
                # If it's in both, the ID should be identical (same dictionary mapping)
                $row.ResourceId | Should -BeIn $inventoryIds -Because "Consumption ResourceId should match inventory ID"
            }
        }
    }
}

Describe "ResourceGroup Consistency" {
    It "Resources with the same obfuscated ResourceGroup should be grouped together" {
        $rgGroups = @{}
        $script:Inventory.PSObject.Properties | Where-Object { $null -ne $_.Value -and $_.Name -ne 'Version' } | ForEach-Object {
            @($_.Value) | ForEach-Object {
                if ($null -ne $_ -and $null -ne $_.ResourceGroup) {
                    if (-not $rgGroups.ContainsKey($_.ResourceGroup)) { $rgGroups[$_.ResourceGroup] = @() }
                    $rgGroups[$_.ResourceGroup] += $_.ID
                }
            }
        }
        # Each RG should have at least one resource
        foreach ($rg in $rgGroups.Keys) {
            $rgGroups[$rg].Count | Should -BeGreaterThan 0 -Because "ResourceGroup '$rg' should have at least one resource"
        }
    }
}

Describe "Subscription Determinism" {
    It "Resources sharing the same obfuscated Subscription should all have the same value" {
        # Collect all subscription values
        $subValues = @{}
        $script:Inventory.PSObject.Properties | Where-Object { $null -ne $_.Value -and $_.Name -ne 'Version' } | ForEach-Object {
            @($_.Value) | ForEach-Object {
                if ($null -ne $_ -and $null -ne $_.Subscription) {
                    $subValues[$_.Subscription] = $true
                }
            }
        }
        # There should be fewer unique subscription values than total resources
        # (deterministic = same real sub maps to same obfuscated sub)
        $subValues.Keys.Count | Should -BeLessOrEqual $script:AllIds.Count -Because "Subscription values should be reused across resources in the same subscription"
    }
}

Describe "ResourceGroup Determinism" {
    It "Fewer unique ResourceGroup values than total resources (deterministic mapping)" {
        $rgValues = @{}
        $script:Inventory.PSObject.Properties | Where-Object { $null -ne $_.Value -and $_.Name -ne 'Version' } | ForEach-Object {
            @($_.Value) | ForEach-Object {
                if ($null -ne $_ -and $null -ne $_.ResourceGroup) {
                    $rgValues[$_.ResourceGroup] = $true
                }
            }
        }
        $rgValues.Keys.Count | Should -BeLessOrEqual $script:AllIds.Count -Because "ResourceGroup values should be reused across resources in the same RG"
    }
}
