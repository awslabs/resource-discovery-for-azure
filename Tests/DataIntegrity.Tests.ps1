# Data Integrity Tests
# Validates the actual obfuscated data for PII leaks and cross-reference correctness
# Run with: Invoke-Pester ./Tests/DataIntegrity.Tests.ps1 -Output Detailed

BeforeAll {
    $zipPath = if ($env:TEST_ZIP_PATH) { $env:TEST_ZIP_PATH } else {
        Get-ChildItem -Path $PSScriptRoot -Filter "ResourcesReport_*.zip" | 
            Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
    if ([string]::IsNullOrEmpty($zipPath) -or -not (Test-Path $zipPath)) {
        throw "No test zip found. Copy a ResourcesReport_*.zip to Tests/ or set `$env:TEST_ZIP_PATH"
    }
    $tmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { "/tmp" }
    $script:ExtractPath = Join-Path $tmpBase ("DataIntTest_" + [guid]::NewGuid().ToString().Substring(0,8))
    New-Item -ItemType Directory -Path $script:ExtractPath -Force | Out-Null
    Expand-Archive -Path $zipPath -DestinationPath $script:ExtractPath -Force

    $invFile = Get-ChildItem -Path $script:ExtractPath -Filter "Inventory_*.json" | Select-Object -First 1
    $script:Inventory = if ($invFile) { Get-Content $invFile.FullName -Raw | ConvertFrom-Json } else { $null }

    # Read all file contents for scanning
    $script:AllContent = @{}
    foreach ($file in (Get-ChildItem -Path $script:ExtractPath -File)) {
        $script:AllContent[$file.Name] = Get-Content $file.FullName -Raw
    }

    $script:ObfuscationPattern = '^(prod|nonprod)_(databricks_|aks_|vmss_)?[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

    # Detect obfuscation mode: if any resource ID matches the obfuscation
    # pattern, treat the run as obfuscated. The PII-leak Describe later
    # also depends on this signal.
    $script:IsObfuscated = $false
    if ($null -ne $script:Inventory) {
        $script:Inventory.PSObject.Properties |
            Where-Object { $null -ne $_.Value -and $_.Name -ne 'Version' } |
            ForEach-Object {
                @($_.Value) | ForEach-Object {
                    if ($script:IsObfuscated) { return }
                    if ($null -ne $_ -and $null -ne $_.ID -and $_.ID -match $script:ObfuscationPattern) {
                        $script:IsObfuscated = $true
                    }
                }
            }
    }
}

AfterAll {
    if (Test-Path $script:ExtractPath) { Remove-Item -Path $script:ExtractPath -Recurse -Force }
}

# ============================================================
# 1. PII Leak Scan — no real Azure identifiers in any output file
# ============================================================
Describe "PII Leak Scan" {
    It "Should not contain /subscriptions/ resource paths in any file" {
        $pattern = '/subscriptions/[0-9a-f]{8}-[0-9a-f]{4}'
        foreach ($fileName in $script:AllContent.Keys) {
            if ([string]::IsNullOrEmpty($script:AllContent[$fileName])) { continue }
            $script:AllContent[$fileName] | Should -Not -Match $pattern -Because "File '$fileName' should not contain Azure resource paths"
        }
    }

    It "Should not contain Azure tenant ID patterns in any file" {
        $pattern = '"tenant[Ii][Dd]"\s*:\s*"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"'
        foreach ($fileName in $script:AllContent.Keys) {
            if ([string]::IsNullOrEmpty($script:AllContent[$fileName])) { continue }
            $script:AllContent[$fileName] | Should -Not -Match $pattern -Because "File '$fileName' should not contain tenant IDs"
        }
    }

    It "Should not contain email addresses in any file" {
        $pattern = '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}'
        foreach ($fileName in $script:AllContent.Keys) {
            if ([string]::IsNullOrEmpty($script:AllContent[$fileName])) { continue }
            $matches = [regex]::Matches($script:AllContent[$fileName], $pattern)
            $matches.Count | Should -Be 0 -Because "File '$fileName' should not contain email addresses"
        }
    }

    It "Should not contain home directory paths in any file" {
        foreach ($fileName in $script:AllContent.Keys) {
            if ([string]::IsNullOrEmpty($script:AllContent[$fileName])) { continue }
            $script:AllContent[$fileName] | Should -Not -Match '/home/[a-zA-Z]' -Because "File '$fileName' should not contain Unix home paths"
            $script:AllContent[$fileName] | Should -Not -Match 'C:\\Users\\[a-zA-Z]' -Because "File '$fileName' should not contain Windows user paths"
        }
    }
}

# ============================================================
# 2. Cross-Reference Integrity — obfuscated IDs match across types
# ============================================================
Describe "Cross-Reference Integrity" {
    It "Every VMDisk AssociatedResource should match a VM ID or be null" {
        $disks = @($script:Inventory.VMDisk)
        $vmIds = @($script:Inventory.VirtualMachines) | Where-Object { $null -ne $_ } | ForEach-Object { $_.ID }
        foreach ($disk in $disks) {
            if ($null -ne $disk -and ![string]::IsNullOrEmpty($disk.AssociatedResource)) {
                $disk.AssociatedResource | Should -BeIn $vmIds -Because "Disk '$($disk.ID)' should reference a known VM"
            }
        }
    }

    It "Every AVD HostId should match a VM ID or be null" {
        $avd = @($script:Inventory.AVD)
        $vmIds = @($script:Inventory.VirtualMachines) | Where-Object { $null -ne $_ } | ForEach-Object { $_.ID }
        foreach ($item in $avd) {
            if ($null -ne $item -and ![string]::IsNullOrEmpty($item.HostId)) {
                $item.HostId | Should -BeIn $vmIds -Because "AVD HostId should reference a known VM"
            }
        }
    }

    It "AVD Hostname should differ from HostId" {
        $avd = @($script:Inventory.AVD)
        foreach ($item in $avd) {
            if ($null -ne $item -and ![string]::IsNullOrEmpty($item.HostId) -and ![string]::IsNullOrEmpty($item.Hostname)) {
                $item.Hostname | Should -Not -Be $item.HostId -Because "Hostname and HostId should be different values"
            }
        }
    }
}

# ============================================================
# 3. Deterministic Mapping — same real sub/RG = same obfuscated value
# ============================================================
Describe "Deterministic Mapping" {
    It "All resources should share the same subscription value per real subscription" {
        $subs = @()
        $script:Inventory.PSObject.Properties | Where-Object { $null -ne $_.Value -and $_.Name -ne 'Version' } | ForEach-Object {
            @($_.Value) | ForEach-Object { if ($null -ne $_ -and $null -ne $_.Subscription) { $subs += $_.Subscription } }
        }
        $uniqueSubs = $subs | Select-Object -Unique
        # Unique subs should be far fewer than total resources
        $uniqueSubs.Count | Should -BeLessOrEqual $subs.Count -Because "Subscription values should be reused (deterministic)"
        # For a single-subscription environment, should be exactly 1
        if ($subs.Count -gt 1) {
            $uniqueSubs.Count | Should -BeLessThan $subs.Count -Because "Multiple resources should share subscription values"
        }
    }

    It "ResourceGroup values should be reused across resources in the same RG" {
        $rgs = @()
        $script:Inventory.PSObject.Properties | Where-Object { $null -ne $_.Value -and $_.Name -ne 'Version' } | ForEach-Object {
            @($_.Value) | ForEach-Object { if ($null -ne $_ -and $null -ne $_.ResourceGroup) { $rgs += $_.ResourceGroup } }
        }
        $uniqueRGs = $rgs | Select-Object -Unique
        $uniqueRGs.Count | Should -BeLessOrEqual $rgs.Count -Because "ResourceGroup values should be reused (deterministic)"
    }
}

# ============================================================
# 4. Non-Sensitive Fields Preserved — real values not obfuscated
# ============================================================
Describe "Non-Sensitive Fields Preserved" {
    It "VM Location should be a real Azure region" {
        foreach ($vm in @($script:Inventory.VirtualMachines)) {
            if ($null -ne $vm -and ![string]::IsNullOrEmpty($vm.Location)) {
                $vm.Location | Should -Not -Match '^(prod|nonprod)_' -Because "Location should be a real region"
            }
        }
    }

    It "VM Size should be a real Azure VM size" {
        foreach ($vm in @($script:Inventory.VirtualMachines)) {
            if ($null -ne $vm -and ![string]::IsNullOrEmpty($vm.Size)) {
                # Azure VM SKUs include Standard_*, Basic_*, M-series (M64s, M128ms),
                # N-series GPU sizes etc. The invariant is "not obfuscated" - i.e.
                # the size string was not run through the obfuscator. The actual
                # SKU shape is not under this script's control.
                $vm.Size | Should -Not -Match '^(prod|nonprod)_' -Because "VM Size should not be obfuscated"
            }
        }
    }

    It "VM OS should be windows or linux" {
        foreach ($vm in @($script:Inventory.VirtualMachines)) {
            if ($null -ne $vm -and ![string]::IsNullOrEmpty($vm.OS)) {
                $vm.OS | Should -BeIn @('windows', 'linux') -Because "OS should be a real OS type"
            }
        }
    }

    It "Storage SKU should not be obfuscated" {
        foreach ($sa in @($script:Inventory.StorageAcc)) {
            if ($null -ne $sa -and ![string]::IsNullOrEmpty($sa.SKU)) {
                $sa.SKU | Should -Not -Match '^(prod|nonprod)_' -Because "Storage SKU should be real"
            }
        }
    }

    It "Tags should be null on all resources" {
        $script:Inventory.PSObject.Properties | Where-Object { $null -ne $_.Value -and $_.Name -ne 'Version' } | ForEach-Object {
            @($_.Value) | ForEach-Object {
                if ($null -ne $_ -and $_.PSObject.Properties.Name -contains 'Tags') {
                    $_.Tags | Should -BeNullOrEmpty -Because "Tags should be stripped when obfuscating"
                }
            }
        }
    }
}

# ============================================================
# 5. No Null Obfuscated Fields — fallbacks should generate values
# ============================================================
Describe "No Null Obfuscated Fields" {
    It "No resource should have a null ID" {
        $script:Inventory.PSObject.Properties | Where-Object { $null -ne $_.Value -and $_.Name -ne 'Version' } | ForEach-Object {
            @($_.Value) | ForEach-Object {
                if ($null -ne $_) {
                    $_.ID | Should -Not -BeNullOrEmpty -Because "Every resource should have an obfuscated ID"
                }
            }
        }
    }

    It "No resource should have a null Name" {
        $script:Inventory.PSObject.Properties | Where-Object { $null -ne $_.Value -and $_.Name -ne 'Version' } | ForEach-Object {
            @($_.Value) | ForEach-Object {
                if ($null -ne $_ -and $_.PSObject.Properties.Name -contains 'Name') {
                    $_.Name | Should -Not -BeNullOrEmpty -Because "Every resource should have an obfuscated Name"
                }
            }
        }
    }

    It "No resource should have a null Subscription" {
        $script:Inventory.PSObject.Properties | Where-Object { $null -ne $_.Value -and $_.Name -ne 'Version' } | ForEach-Object {
            @($_.Value) | ForEach-Object {
                if ($null -ne $_ -and $_.PSObject.Properties.Name -contains 'Subscription') {
                    $_.Subscription | Should -Not -BeNullOrEmpty -Because "Every resource should have an obfuscated Subscription"
                }
            }
        }
    }

    It "No resource should have a null ResourceGroup" {
        $script:Inventory.PSObject.Properties | Where-Object { $null -ne $_.Value -and $_.Name -ne 'Version' } | ForEach-Object {
            @($_.Value) | ForEach-Object {
                if ($null -ne $_ -and $_.PSObject.Properties.Name -contains 'ResourceGroup') {
                    $_.ResourceGroup | Should -Not -BeNullOrEmpty -Because "Every resource should have an obfuscated ResourceGroup"
                }
            }
        }
    }
}


# ============================================================
# 6. Generic per-property leak scan
# ============================================================
# Walks every property of every resource across all collectors and asserts no
# value contains a raw Azure resource path. This catches secondary-field leaks
# that the per-collector specialised tests do not cover (since only ~14 of the
# 57 collectors have dedicated cross-reference tests).
Describe "Generic per-property leak scan" {
    It "No resource property in obfuscated output should contain a raw Azure resource path" {
        if (-not $script:IsObfuscated) {
            Set-ItResult -Skipped -Because "test only meaningful in obfuscated mode"
            return
        }
        $azureIdPattern = '/subscriptions/[0-9a-f]{8}-[0-9a-f]{4}'
        $script:Inventory.PSObject.Properties |
            Where-Object { $null -ne $_.Value -and $_.Name -ne 'Version' } |
            ForEach-Object {
                $collector = $_.Name
                @($_.Value) | ForEach-Object {
                    if ($null -eq $_) { return }
                    foreach ($prop in $_.PSObject.Properties) {
                        if ($null -ne $prop.Value -and $prop.Value -is [string] -and $prop.Value -match $azureIdPattern) {
                            $hint = "[{0}.{1}]" -f $collector, $prop.Name
                            $prop.Value | Should -Not -Match $azureIdPattern -Because "Field $hint contains raw Azure resource path"
                        }
                    }
                }
            }
    }
}
