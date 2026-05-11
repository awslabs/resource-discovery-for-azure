# Obfuscation Tests for Resource Discovery for Azure
# Run with: Invoke-Pester ./Tests/Obfuscation.Tests.ps1 -Output Detailed

BeforeAll {
    # Find the zip
    $zipPath = if ($env:TEST_ZIP_PATH) { $env:TEST_ZIP_PATH } else {
        Get-ChildItem -Path $PSScriptRoot -Filter "ResourcesReport_*.zip" | 
            Sort-Object LastWriteTime -Descending | 
            Select-Object -First 1 -ExpandProperty FullName
    }

    if ([string]::IsNullOrEmpty($zipPath) -or -not (Test-Path $zipPath)) {
        throw "No test zip found. Copy a ResourcesReport_*.zip to the Tests/ folder or set `$env:TEST_ZIP_PATH"
    }

    # Extract to temp folder
    $tmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { "/tmp" }
    $script:ExtractPath = Join-Path $tmpBase ("ObfuscationTest_" + [guid]::NewGuid().ToString().Substring(0,8))
    New-Item -ItemType Directory -Path $script:ExtractPath -Force | Out-Null
    Expand-Archive -Path $zipPath -DestinationPath $script:ExtractPath -Force

    # Load files
    $script:InventoryFile = Get-ChildItem -Path $script:ExtractPath -Filter "Inventory_*.json" | Select-Object -First 1
    $script:MetricsFiles = @(Get-ChildItem -Path $script:ExtractPath -Filter "Metrics_*.json")
    $script:ConsumptionFile = Get-ChildItem -Path $script:ExtractPath -Filter "Consumption_*.csv" | Select-Object -First 1
    $script:AllFiles = Get-ChildItem -Path $script:ExtractPath -File

    # Parse inventory JSON
    if ($script:InventoryFile) {
        $script:Inventory = Get-Content $script:InventoryFile.FullName -Raw | ConvertFrom-Json
    }

    # Read all file contents once for PII scanning
    $script:AllContent = @{}
    foreach ($file in $script:AllFiles) {
        $script:AllContent[$file.Name] = Get-Content $file.FullName -Raw
    }

    # Obfuscation pattern: prod_ or nonprod_ followed by a GUID
    $script:ObfuscationPattern = '^(prod|nonprod)_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

    # Helper: get all resources from inventory as flat list
    $script:AllResources = @()
    if ($script:Inventory) {
        $props = $script:Inventory.PSObject.Properties | Where-Object { $null -ne $_.Value -and $_.Name -ne 'Version' }
        foreach ($prop in $props) {
            $script:AllResources += @($prop.Value)
        }
    }
}

AfterAll {
    if (Test-Path $script:ExtractPath) {
        Remove-Item -Path $script:ExtractPath -Recurse -Force
    }
}

# ============================================================
# 1. Transcript excluded from zip
# ============================================================
Describe "Transcript Exclusion" {
    It "Should not contain any transcript log files in the zip" {
        $transcriptFiles = $script:AllFiles | Where-Object { $_.Name -like "Transcript_*" }
        $transcriptFiles | Should -BeNullOrEmpty
    }
}

# ============================================================
# 2. No email addresses in any file
# ============================================================
Describe "Email Address Leak Check" {
    It "Should not contain any email addresses in any output file" {
        $emailPattern = '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}'
        foreach ($fileName in $script:AllContent.Keys) {
            if ([string]::IsNullOrEmpty($script:AllContent[$fileName])) { continue }
            $matches = [regex]::Matches($script:AllContent[$fileName], $emailPattern)
            $matches.Count | Should -Be 0 -Because "File '$fileName' should not contain email addresses (found: $($matches.Value -join ', '))"
        }
    }
}

# ============================================================
# 3. No home directory paths in any file
# ============================================================
Describe "Home Directory Path Leak Check" {
    It "Should not contain Unix home directory paths" {
        foreach ($fileName in $script:AllContent.Keys) {
            $script:AllContent[$fileName] | Should -Not -Match '/home/[a-zA-Z]' -Because "File '$fileName' should not contain Unix home paths"
        }
    }

    It "Should not contain Windows user directory paths" {
        foreach ($fileName in $script:AllContent.Keys) {
            $script:AllContent[$fileName] | Should -Not -Match 'C:\\Users\\[a-zA-Z]' -Because "File '$fileName' should not contain Windows user paths"
        }
    }
}

# ============================================================
# 4. No Azure subscription ID patterns (raw GUIDs in sub context)
# ============================================================
Describe "Subscription ID Leak Check" {
    It "Should not contain raw Azure subscription ID patterns in inventory JSON" {
        # Azure resource IDs follow: /subscriptions/<guid>/resourceGroups/...
        $subIdPattern = '/subscriptions/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
        if ($script:InventoryFile) {
            $content = $script:AllContent[$script:InventoryFile.Name]
            $content | Should -Not -Match $subIdPattern -Because "Inventory JSON should not contain raw Azure resource ID paths"
        }
    }

    It "Should not contain raw Azure subscription ID patterns in consumption CSV" {
        $subIdPattern = '/subscriptions/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
        if ($script:ConsumptionFile) {
            $content = $script:AllContent[$script:ConsumptionFile.Name]
            $content | Should -Not -Match $subIdPattern -Because "Consumption CSV should not contain raw Azure resource ID paths"
        }
    }

    It "Should not contain raw Azure subscription ID patterns in metrics JSON" {
        $subIdPattern = '/subscriptions/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
        foreach ($metricsFile in $script:MetricsFiles) {
            $content = $script:AllContent[$metricsFile.Name]
            $content | Should -Not -Match $subIdPattern -Because "Metrics JSON should not contain raw Azure resource ID paths"
        }
    }
}

# ============================================================
# 5. All inventory resource IDs are obfuscated
# ============================================================
Describe "Inventory ID Obfuscation" {
    It "Should have all resource IDs matching the obfuscation pattern" {
        $script:AllResources.Count | Should -BeGreaterThan 0 -Because "There should be at least one resource in the inventory"
        foreach ($resource in $script:AllResources) {
            if ($null -ne $resource.ID) {
                $resource.ID | Should -Match $script:ObfuscationPattern -Because "Resource ID '$($resource.ID)' should be obfuscated"
            }
        }
    }
}

# ============================================================
# 6. All inventory resource names are obfuscated
# ============================================================
Describe "Inventory Name Obfuscation" {
    It "Should have all resource names matching the obfuscation pattern" {
        foreach ($resource in $script:AllResources) {
            if ($null -ne $resource.Name) {
                $resource.Name | Should -Match $script:ObfuscationPattern -Because "Resource Name '$($resource.Name)' should be obfuscated"
            }
        }
    }
}

# ============================================================
# 7. All inventory subscriptions are obfuscated
# ============================================================
Describe "Inventory Subscription Obfuscation" {
    It "Should have all subscription fields matching the obfuscation pattern" {
        foreach ($resource in $script:AllResources) {
            if ($null -ne $resource.Subscription) {
                $resource.Subscription | Should -Match $script:ObfuscationPattern -Because "Subscription '$($resource.Subscription)' should be obfuscated"
            }
        }
    }
}

# ============================================================
# 8. All inventory resource groups are obfuscated
# ============================================================
Describe "Inventory ResourceGroup Obfuscation" {
    It "Should have all resource group fields matching the obfuscation pattern" {
        foreach ($resource in $script:AllResources) {
            if ($null -ne $resource.ResourceGroup) {
                $resource.ResourceGroup | Should -Match $script:ObfuscationPattern -Because "ResourceGroup '$($resource.ResourceGroup)' should be obfuscated"
            }
        }
    }
}

# ============================================================
# 9. Metrics IDs are obfuscated
# ============================================================
Describe "Metrics Obfuscation" {
    It "Should have all metric IDs and names matching the obfuscation pattern" {
        foreach ($metricsFile in $script:MetricsFiles) {
            $metricsData = Get-Content $metricsFile.FullName -Raw | ConvertFrom-Json
            foreach ($metric in @($metricsData.Metrics)) {
                if ($null -ne $metric.ID) {
                    $metric.ID | Should -Match $script:ObfuscationPattern -Because "Metric ID should be obfuscated"
                }
                if ($null -ne $metric.Name) {
                    $metric.Name | Should -Match $script:ObfuscationPattern -Because "Metric Name should be obfuscated"
                }
                if ($null -ne $metric.Subscription) {
                    $metric.Subscription | Should -Match $script:ObfuscationPattern -Because "Metric Subscription should be obfuscated"
                }
                if ($null -ne $metric.ResourceGroup) {
                    $metric.ResourceGroup | Should -Match $script:ObfuscationPattern -Because "Metric ResourceGroup should be obfuscated"
                }
            }
        }
    }
}

# ============================================================
# 10. Consumption ResourceIds are obfuscated
# ============================================================
Describe "Consumption Obfuscation" {
    It "Should have all consumption ResourceIds matching the obfuscation pattern" {
        if ($null -eq $script:ConsumptionFile) { return }
        $csv = Import-Csv $script:ConsumptionFile.FullName
        if ($csv.Count -eq 0) { return }

        foreach ($row in $csv) {
            if (![string]::IsNullOrEmpty($row.ResourceId)) {
                $row.ResourceId | Should -Match $script:ObfuscationPattern -Because "Consumption ResourceId should be obfuscated"
            }
        }
    }

    It "Should have obfuscated ResourceUri inside InstanceData JSON" {
        if ($null -eq $script:ConsumptionFile) { return }
        $csv = Import-Csv $script:ConsumptionFile.FullName
        if ($csv.Count -eq 0) { return }

        foreach ($row in $csv) {
            if (![string]::IsNullOrEmpty($row.InstanceData)) {
                $instanceData = $row.InstanceData | ConvertFrom-Json
                $uri = $instanceData.'Microsoft.Resources'.ResourceUri
                if (![string]::IsNullOrEmpty($uri)) {
                    $uri | Should -Match $script:ObfuscationPattern -Because "InstanceData ResourceUri should be obfuscated"
                }
            }
        }
    }
}

# ============================================================
# 11. Obfuscation prefix consistency (no plain GUIDs)
# ============================================================
Describe "Obfuscation Prefix Consistency" {
    It "Should use prod_ or nonprod_ prefix on all IDs (not plain GUIDs)" {
        $plainGuidPattern = '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        foreach ($resource in $script:AllResources) {
            if ($null -ne $resource.ID) {
                $resource.ID | Should -Not -Match $plainGuidPattern -Because "ID should have prod_/nonprod_ prefix"
            }
        }
    }
}

# ============================================================
# 12. Valid metrics JSON structure
# ============================================================
Describe "Metrics JSON Structure" {
    It "Should have valid metrics JSON with a Metrics array property" {
        foreach ($metricsFile in $script:MetricsFiles) {
            $raw = Get-Content $metricsFile.FullName -Raw
            $parsed = $raw | ConvertFrom-Json
            $parsed | Should -Not -BeNullOrEmpty -Because "Metrics file should be valid JSON"
            $parsed.PSObject.Properties.Name | Should -Contain 'Metrics' -Because "Metrics JSON should have a Metrics property"
        }
    }
}

# ============================================================
# 13. Consumption CSV has valid headers
# ============================================================
Describe "Consumption CSV Headers" {
    It "Should have a consumption CSV with the correct header columns" {
        if ($null -eq $script:ConsumptionFile) {
            Set-ItResult -Skipped -Because "No consumption CSV in this report"
            return
        }
        $firstLine = Get-Content $script:ConsumptionFile.FullName -TotalCount 1
        if ([string]::IsNullOrEmpty($firstLine)) {
            Set-ItResult -Skipped -Because "Consumption CSV is empty (no usage data in this subscription)"
            return
        }

        $expectedHeaders = @('InstanceData', 'MeterCategory', 'MeterId', 'MeterName', 'MeterRegion', 'MeterSubCategory', 'Quantity', 'Unit', 'UsageStartTime', 'UsageEndTime', 'ResourceId', 'ResourceLocation', 'ConsumptionMeter', 'ReservationId', 'ReservationOrderId')
        foreach ($header in $expectedHeaders) {
            $firstLine | Should -Match $header -Because "CSV should contain header '$header'"
        }
    }
}

# ============================================================
# 14. No Azure tenant IDs leaked
# ============================================================
Describe "Tenant ID Leak Check" {
    It "Should not contain Azure tenant ID patterns in output files" {
        # Tenant IDs appear as: "tenantId":"<guid>" or tenantID
        $tenantPattern = '"tenant[Ii][Dd]"\s*:\s*"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"'
        foreach ($fileName in $script:AllContent.Keys) {
            $script:AllContent[$fileName] | Should -Not -Match $tenantPattern -Because "File '$fileName' should not contain tenant IDs"
        }
    }
}

# ============================================================
# NON-OBFUSCATED MODE SAFETY NET
# This test catches guard pattern bugs where obfuscation
# logic fires even when -Obfuscate is not set.
# ============================================================
Describe "Non-Obfuscated Mode Safety" {
    BeforeAll {
        $script:NonObfZip = $env:TEST_NOOBF_ZIP_PATH
        if ($script:NonObfZip -and (Test-Path $script:NonObfZip)) {
            $script:NoObfExtract = Join-Path ([System.IO.Path]::GetTempPath()) "NoObfTest_$([guid]::NewGuid().ToString().Substring(0,8))"
            New-Item -ItemType Directory -Path $script:NoObfExtract -Force | Out-Null
            Expand-Archive -Path $script:NonObfZip -DestinationPath $script:NoObfExtract -Force
            $script:NoObfContent = @{}
            Get-ChildItem -Path $script:NoObfExtract -File | ForEach-Object {
                $script:NoObfContent[$_.Name] = Get-Content $_.FullName -Raw
            }
        }
    }

    AfterAll {
        if ($script:NoObfExtract -and (Test-Path $script:NoObfExtract)) {
            Remove-Item -Path $script:NoObfExtract -Recurse -Force
        }
    }

    It "Should not contain 'obfuscated' in any output file when run without -Obfuscate" {
        if (-not $script:NoObfContent) {
            Set-ItResult -Skipped -Because "No non-obfuscated zip provided"
            return
        }
        foreach ($file in $script:NoObfContent.Keys) {
            if ($file -like "Transcript_*") { continue }
            $script:NoObfContent[$file] | Should -Not -Match 'obfuscated' -Because "File '$file' should contain real data, not obfuscated placeholders"
        }
    }

    It "Should not contain obfuscation GUID patterns in non-obfuscated output" {
        if (-not $script:NoObfContent) {
            Set-ItResult -Skipped -Because "No non-obfuscated zip provided"
            return
        }
        $guidPattern = '(prod|nonprod)_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
        foreach ($file in $script:NoObfContent.Keys) {
            $script:NoObfContent[$file] | Should -Not -Match $guidPattern -Because "File '$file' should not contain obfuscation GUIDs"
        }
    }
}
Describe "Cross-Reference Field Obfuscation" {
    # Helper: field should be obfuscated, null, or a safe non-ID value like 'None' or 'obfuscated'
    BeforeAll {
        $script:SafePattern = '^((prod|nonprod)_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|None|obfuscated)$'
        $script:AzureIdPattern = '/subscriptions/[0-9a-f]{8}-[0-9a-f]{4}'
    }

    It "AppServices: ServerFarmId should be obfuscated or null" {
        $resources = @($script:Inventory.AppServices)
        foreach ($r in $resources) {
            if ($null -ne $r -and ![string]::IsNullOrEmpty($r.ServerFarmId)) {
                $r.ServerFarmId | Should -Not -Match $script:AzureIdPattern -Because "ServerFarmId should not contain raw Azure resource ID"
            }
        }
    }

    It "VirtualMachines: Set (VMSS ID) should be obfuscated or null" {
        $resources = @($script:Inventory.VirtualMachines)
        foreach ($r in $resources) {
            if ($null -ne $r -and ![string]::IsNullOrEmpty($r.Set)) {
                $r.Set | Should -Match $script:ObfuscationPattern -Because "VMSS Set ID should be obfuscated"
            }
        }
    }

    It "VirtualMachines: Tags should be null when obfuscated" {
        $resources = @($script:Inventory.VirtualMachines)
        foreach ($r in $resources) {
            if ($null -ne $r) {
                $r.Tags | Should -BeNullOrEmpty -Because "Tags should be stripped when obfuscating"
            }
        }
    }

    It "Purview: CreatedBy should be 'obfuscated' or null" {
        $resources = @($script:Inventory.Purview)
        foreach ($r in $resources) {
            if ($null -ne $r -and ![string]::IsNullOrEmpty($r.CreatedBy)) {
                $r.CreatedBy | Should -Be 'obfuscated' -Because "CreatedBy contains user identity and should be masked"
            }
        }
    }

    It "SQLDB: DatabaseServer should not contain raw resource names" {
        $resources = @($script:Inventory.SQLDB)
        foreach ($r in $resources) {
            if ($null -ne $r -and ![string]::IsNullOrEmpty($r.DatabaseServer)) {
                $r.DatabaseServer | Should -Not -Match $script:AzureIdPattern -Because "DatabaseServer should not contain raw Azure resource ID"
            }
        }
    }

    It "SQLDB: ElasticPoolID should be obfuscated or 'None'" {
        $resources = @($script:Inventory.SQLDB)
        foreach ($r in $resources) {
            if ($null -ne $r -and ![string]::IsNullOrEmpty($r.ElasticPoolID)) {
                $r.ElasticPoolID | Should -Not -Match $script:AzureIdPattern -Because "ElasticPoolID should not contain raw Azure resource ID"
            }
        }
    }

    It "SQLMI: InstancePoolName should not contain raw resource IDs" {
        $resources = @($script:Inventory.SQLMI)
        foreach ($r in $resources) {
            if ($null -ne $r -and ![string]::IsNullOrEmpty($r.InstancePoolName)) {
                $r.InstancePoolName | Should -Not -Match $script:AzureIdPattern -Because "InstancePoolName should not contain raw Azure resource ID"
            }
        }
    }

    It "SQLMIDB: ManagedInstance should be obfuscated or null" {
        $resources = @($script:Inventory.SQLMIDB)
        foreach ($r in $resources) {
            if ($null -ne $r -and ![string]::IsNullOrEmpty($r.ManagedInstance)) {
                $r.ManagedInstance | Should -Not -Match $script:AzureIdPattern -Because "ManagedInstance should not contain raw Azure resource ID"
            }
        }
    }

    It "PublicIP: AssociatedResource should not contain raw resource names" {
        $resources = @($script:Inventory.PublicIP)
        foreach ($r in $resources) {
            if ($null -ne $r -and ![string]::IsNullOrEmpty($r.AssociatedResource) -and $r.AssociatedResource -ne 'None') {
                $r.AssociatedResource | Should -Not -Match $script:AzureIdPattern -Because "AssociatedResource should not contain raw Azure resource ID"
            }
        }
    }

    It "VMDisk: AssociatedResource should be obfuscated or null" {
        $resources = @($script:Inventory.VMDisk)
        foreach ($r in $resources) {
            if ($null -ne $r -and ![string]::IsNullOrEmpty($r.AssociatedResource)) {
                $r.AssociatedResource | Should -Not -Match $script:AzureIdPattern -Because "Disk AssociatedResource should not contain raw Azure resource ID"
            }
        }
    }

    It "ComputeSnapshots: SourceResourceId should be obfuscated or null" {
        $resources = @($script:Inventory.ComputeSnapshots)
        foreach ($r in $resources) {
            if ($null -ne $r -and ![string]::IsNullOrEmpty($r.SourceResourceId)) {
                $r.SourceResourceId | Should -Not -Match $script:AzureIdPattern -Because "SourceResourceId should not contain raw Azure resource ID"
            }
        }
    }

    It "AVD: HostId should be obfuscated or null" {
        $resources = @($script:Inventory.AVD)
        foreach ($r in $resources) {
            if ($null -ne $r -and ![string]::IsNullOrEmpty($r.HostId)) {
                $r.HostId | Should -Not -Match $script:AzureIdPattern -Because "AVD HostId should not contain raw Azure resource ID"
            }
        }
    }

    It "AVD: Hostname should be obfuscated or null" {
        $resources = @($script:Inventory.AVD)
        foreach ($r in $resources) {
            if ($null -ne $r -and ![string]::IsNullOrEmpty($r.Hostname)) {
                $r.Hostname | Should -Not -Match $script:AzureIdPattern -Because "AVD Hostname should not contain raw Azure resource ID"
                $r.Hostname | Should -Match $script:ObfuscationPattern -Because "AVD Hostname should be obfuscated"
            }
        }
    }

    It "AVD: Hostname should differ from HostId" {
        $resources = @($script:Inventory.AVD)
        foreach ($r in $resources) {
            if ($null -ne $r -and ![string]::IsNullOrEmpty($r.Hostname) -and ![string]::IsNullOrEmpty($r.HostId)) {
                $r.Hostname | Should -Not -Be $r.HostId -Because "Hostname and HostId should be different obfuscated values"
            }
        }
    }

    It "MachineLearning: StorageAccount should be obfuscated or null" {
        $resources = @($script:Inventory.MachineLearning)
        foreach ($r in $resources) {
            if ($null -ne $r -and ![string]::IsNullOrEmpty($r.StorageAccount)) {
                $r.StorageAccount | Should -Not -Match $script:AzureIdPattern -Because "ML StorageAccount should not contain raw Azure resource ID"
            }
        }
    }

    It "MachineLearning: KeyVault should be obfuscated or null" {
        $resources = @($script:Inventory.MachineLearning)
        foreach ($r in $resources) {
            if ($null -ne $r -and ![string]::IsNullOrEmpty($r.KeyVault)) {
                $r.KeyVault | Should -Not -Match $script:AzureIdPattern -Because "ML KeyVault should not contain raw Azure resource ID"
            }
        }
    }

    It "Databricks: ManagedResourceGroup should be obfuscated or null" {
        $resources = @($script:Inventory.Databricks)
        foreach ($r in $resources) {
            if ($null -ne $r -and ![string]::IsNullOrEmpty($r.ManagedResourceGroup)) {
                $r.ManagedResourceGroup | Should -BeIn @('obfuscated') -Because "Databricks ManagedResourceGroup should be obfuscated"
            }
        }
    }

    It "Databricks: StorageAccount should be obfuscated or null" {
        $resources = @($script:Inventory.Databricks)
        foreach ($r in $resources) {
            if ($null -ne $r -and ![string]::IsNullOrEmpty($r.StorageAccount)) {
                $r.StorageAccount | Should -BeIn @('obfuscated') -Because "Databricks StorageAccount should be obfuscated"
            }
        }
    }

    It "Purview: FriendlyName should be obfuscated or null" {
        $resources = @($script:Inventory.Purview)
        foreach ($r in $resources) {
            if ($null -ne $r -and ![string]::IsNullOrEmpty($r.FriendlyName)) {
                $r.FriendlyName | Should -BeIn @('obfuscated') -Because "Purview FriendlyName should be obfuscated"
            }
        }
    }

    It "Frontdoor: WebApplicationFirewall should be obfuscated or False" {
        $resources = @($script:Inventory.FRONTDOOR)
        foreach ($r in $resources) {
            if ($null -ne $r -and ![string]::IsNullOrEmpty($r.WebApplicationFirewall) -and $r.WebApplicationFirewall -ne 'False') {
                $r.WebApplicationFirewall | Should -Not -Match $script:AzureIdPattern -Because "Frontdoor WAF should not contain raw Azure resource ID"
            }
        }
    }
}

# ============================================================
# 16. Dictionary file excluded from zip
# ============================================================
Describe "Dictionary File Exclusion" {
    It "Should not contain the obfuscation dictionary in the zip" {
        $dictFiles = $script:AllFiles | Where-Object { $_.Name -like "ObfuscationDictionary_*" }
        $dictFiles | Should -BeNullOrEmpty -Because "Dictionary file should stay local, not in the zip"
    }
}
