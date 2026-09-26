# Obfuscation Tests for Resource Discovery for Azure
# Run with: Invoke-Pester ./Tests/Obfuscation.Tests.ps1 -Output Detailed

BeforeAll {
    # Get-DeterminismViolation: given a (token -> real-value) map and a selector, return the real values reachable from MORE THAN ONE distinct token - a non-empty result means one real value produced two tokens, breaking obfuscation determinism (P1). In BeforeAll so the It blocks can see it.
    function Get-DeterminismViolation
    {
        param(
            [Parameter(Mandatory)] $Map,
            [Parameter(Mandatory)] [scriptblock] $RealValueSelector
        )

        $Pairs = foreach ($property in $Map.PSObject.Properties)
        {
            $Real = & $RealValueSelector $property.Value
            if (-not [string]::IsNullOrEmpty([string]$Real))
            {
                [PSCustomObject]@{ Real = [string]$Real; Token = $property.Name }
            }
        }

        @($Pairs | Group-Object Real | Where-Object { @($_.Group.Token | Sort-Object -Unique).Count -gt 1 })
    }

    # Find the zip
    $ZipPath = if ($env:TEST_ZIP_PATH) { $env:TEST_ZIP_PATH } else
    {
        Get-ChildItem -Path $PSScriptRoot -Filter "ResourcesReport_*.zip" |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1 -ExpandProperty FullName
    }

    if ([string]::IsNullOrEmpty($ZipPath) -or -not (Test-Path $ZipPath))
    {
        throw "No test zip found. Copy a ResourcesReport_*.zip to the Tests/ folder or set `$env:TEST_ZIP_PATH"
    }

    # Extract to temp folder
    $TmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { "/tmp" }
    $script:ExtractPath = Join-Path $TmpBase ("ObfuscationTest_" + [guid]::NewGuid().ToString().Substring(0, 8))
    New-Item -ItemType Directory -Path $script:ExtractPath -Force | Out-Null
    Expand-Archive -Path $ZipPath -DestinationPath $script:ExtractPath -Force

    # Load files
    $script:InventoryFile = Get-ChildItem -Path $script:ExtractPath -Filter "Inventory_*.json" | Select-Object -First 1
    $script:MetricsFiles = @(Get-ChildItem -Path $script:ExtractPath -Filter "Metrics_*.json")
    $script:ConsumptionFile = Get-ChildItem -Path $script:ExtractPath -Filter "Consumption_*.csv" | Select-Object -First 1
    $script:AllFiles = Get-ChildItem -Path $script:ExtractPath -File

    # Parse inventory JSON
    if ($script:InventoryFile)
    {
        $script:Inventory = Get-Content $script:InventoryFile.FullName -Raw | ConvertFrom-Json
    }

    # Read all file contents once for PII scanning
    $script:AllContent = @{}
    foreach ($file in $script:AllFiles)
    {
        $script:AllContent[$file.Name] = Get-Content $file.FullName -Raw
    }

    # Obfuscation token pattern: prod_/nonprod_, an optional type-tag (databricks_/aks_/vmss_), then a GUID. The type-tagged variants are legitimate output for IDs that do not fit the standard ARM shape (AKS-managed RGs, Databricks clusters, VMSS-in-AKS instances).
    $script:ObfuscationPattern = '^(prod|nonprod)_(databricks_|aks_|vmss_)?[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

    # Helper: get all resources from inventory as flat list
    $script:AllResources = @()
    if ($script:Inventory)
    {
        $Props = $script:Inventory.PSObject.Properties | Where-Object { $null -ne $_.Value -and $_.Name -ne 'Version' }
        foreach ($prop in $Props)
        {
            $script:AllResources += @($prop.Value)
        }
    }

    # Locate the reverse-lookup dictionary for the determinism (P1) checks.
    # Same discovery convention as DictionaryValidation.Tests.ps1: prefer
    # $env:TEST_DICT_PATH, then the Tests/ folder, then next to the zip. The
    # dictionary is LOCAL-ONLY and is never inside the shared zip.
    $DictPath = if ($env:TEST_DICT_PATH) { $env:TEST_DICT_PATH } else
    {
        $Found = Get-ChildItem -Path $PSScriptRoot -Filter "ObfuscationDictionary_*.json" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
        if ([string]::IsNullOrEmpty($Found))
        {
            $ZipDir = if ($env:TEST_ZIP_PATH) { Split-Path $env:TEST_ZIP_PATH -Parent } else { $PSScriptRoot }
            Get-ChildItem -Path $ZipDir -Filter "ObfuscationDictionary_*.json" -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
        }
        else { $Found }
    }
    $script:DictionaryAvailable = -not [string]::IsNullOrEmpty($DictPath) -and (Test-Path $DictPath)
    $script:Dictionary = if ($script:DictionaryAvailable) { Get-Content $DictPath -Raw | ConvertFrom-Json } else { $null }
}

AfterAll {
    if (Test-Path $script:ExtractPath)
    {
        Remove-Item -Path $script:ExtractPath -Recurse -Force
    }
}

# ============================================================
# 1. Transcript excluded from zip
# ============================================================
Describe "Transcript Exclusion" {
    It "Should not contain any transcript log files in the zip" {
        $TranscriptFiles = $script:AllFiles | Where-Object { $_.Name -like "Transcript_*" }
        $TranscriptFiles | Should -BeNullOrEmpty
    }
}

# ============================================================
# 2. No email addresses in any file
# ============================================================
Describe "Email Address Leak Check" {
    It "Should not contain any email addresses in any output file" {
        $EmailPattern = '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}'
        foreach ($fileName in $script:AllContent.Keys)
        {
            if ([string]::IsNullOrEmpty($script:AllContent[$fileName])) { continue }
            $EmailMatches = [regex]::Matches($script:AllContent[$fileName], $EmailPattern)
            $EmailMatches.Count | Should -Be 0 -Because "File '$fileName' should not contain email addresses (found: $($EmailMatches.Value -join ', '))"
        }
    }
}

# ============================================================
# 3. No home directory paths in any file
# ============================================================
Describe "Home Directory Path Leak Check" {
    It "Should not contain Unix home directory paths" {
        foreach ($fileName in $script:AllContent.Keys)
        {
            $script:AllContent[$fileName] | Should -Not -Match '/home/[a-zA-Z]' -Because "File '$fileName' should not contain Unix home paths"
        }
    }

    It "Should not contain Windows user directory paths" {
        foreach ($fileName in $script:AllContent.Keys)
        {
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
        $SubIdPattern = '/subscriptions/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
        if ($script:InventoryFile)
        {
            $Content = $script:AllContent[$script:InventoryFile.Name]
            $Content | Should -Not -Match $SubIdPattern -Because "Inventory JSON should not contain raw Azure resource ID paths"
        }
    }

    It "Should not contain raw Azure subscription ID patterns in consumption CSV" {
        $SubIdPattern = '/subscriptions/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
        if ($script:ConsumptionFile)
        {
            $Content = $script:AllContent[$script:ConsumptionFile.Name]
            $Content | Should -Not -Match $SubIdPattern -Because "Consumption CSV should not contain raw Azure resource ID paths"
        }
    }

    It "Should not contain raw Azure subscription ID patterns in metrics JSON" {
        $SubIdPattern = '/subscriptions/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
        foreach ($metricsFile in $script:MetricsFiles)
        {
            $Content = $script:AllContent[$metricsFile.Name]
            $Content | Should -Not -Match $SubIdPattern -Because "Metrics JSON should not contain raw Azure resource ID paths"
        }
    }
}

# ============================================================
# 5. All inventory resource IDs are obfuscated
# ============================================================
Describe "Inventory ID Obfuscation" {
    It "Should have all resource IDs matching the obfuscation pattern" {
        $script:AllResources.Count | Should -BeGreaterThan 0 -Because "There should be at least one resource in the inventory"
        foreach ($resource in $script:AllResources)
        {
            if ($null -ne $resource.ID)
            {
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
        $Checked = 0
        foreach ($resource in $script:AllResources)
        {
            if ($null -ne $resource.Name)
            {
                $Checked++
                $resource.Name | Should -Match $script:ObfuscationPattern -Because "Resource Name '$($resource.Name)' should be obfuscated"
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "no resource carried a non-null Name to assert against" }
    }
}

# ============================================================
# 7. All inventory subscriptions are obfuscated
# ============================================================
Describe "Inventory Subscription Obfuscation" {
    It "Should have all subscription fields matching the obfuscation pattern" {
        $Checked = 0
        foreach ($resource in $script:AllResources)
        {
            if ($null -ne $resource.Subscription)
            {
                $Checked++
                $resource.Subscription | Should -Match $script:ObfuscationPattern -Because "Subscription '$($resource.Subscription)' should be obfuscated"
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "no resource carried a non-null Subscription to assert against" }
    }
}

# ============================================================
# 8. All inventory resource groups are obfuscated
# ============================================================
Describe "Inventory ResourceGroup Obfuscation" {
    It "Should have all resource group fields matching the obfuscation pattern" {
        $Checked = 0
        foreach ($resource in $script:AllResources)
        {
            if ($null -ne $resource.ResourceGroup)
            {
                $Checked++
                $resource.ResourceGroup | Should -Match $script:ObfuscationPattern -Because "ResourceGroup '$($resource.ResourceGroup)' should be obfuscated"
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "no resource carried a non-null ResourceGroup to assert against" }
    }
}

# ============================================================
# 9. Metrics IDs are obfuscated
# ============================================================
Describe "Metrics Obfuscation" {
    It "Should have all metric IDs and names matching the obfuscation pattern" {
        $Checked = 0
        foreach ($metricsFile in $script:MetricsFiles)
        {
            $MetricsData = Get-Content $metricsFile.FullName -Raw | ConvertFrom-Json
            foreach ($metric in @($MetricsData.Metrics))
            {
                if ($null -ne $metric.ID)
                {
                    $Checked++
                    $metric.ID | Should -Match $script:ObfuscationPattern -Because "Metric ID should be obfuscated"
                }
                if ($null -ne $metric.Name)
                {
                    $Checked++
                    $metric.Name | Should -Match $script:ObfuscationPattern -Because "Metric Name should be obfuscated"
                }
                if ($null -ne $metric.Subscription)
                {
                    $Checked++
                    $metric.Subscription | Should -Match $script:ObfuscationPattern -Because "Metric Subscription should be obfuscated"
                }
                if ($null -ne $metric.ResourceGroup)
                {
                    $Checked++
                    $metric.ResourceGroup | Should -Match $script:ObfuscationPattern -Because "Metric ResourceGroup should be obfuscated"
                }
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "no metric carried an obfuscatable field to assert against" }
    }
}

# ============================================================
# 10. Consumption ResourceIds are obfuscated
# ============================================================
Describe "Consumption Obfuscation" {
    # Consumption ResourceUri keeps the ARM path structure (/subscriptions/<obf-sub>/resourcegroups/<obf-rg>/providers/<rp>/<type>/<obf-name>) so the dashboard can categorise by provider+type; a flat token broke AKS/VMSS/Container/Kusto detection. Tests accept BOTH the flat legacy token and the ARM shape.
    # This derivation MUST run at RUN time, not discovery: it depends on $script:ObfuscationPattern (set by the top-level BeforeAll), so a bare assignment in the Describe body would run at discovery when the pattern is still $null and crash the block, silently dropping the assertions. Keep it inside BeforeAll.
    BeforeAll {
        $script:ConsumptionSafePattern = '^(' + $script:ObfuscationPattern.TrimStart('^').TrimEnd('$') + '|/subscriptions/(prod|nonprod)_sub_)'
    }

    It "Should have all consumption ResourceIds matching the obfuscation pattern" {
        if ($null -eq $script:ConsumptionFile) { Set-ItResult -Skipped -Because "no consumption file in fixture"; return }
        $Csv = Import-Csv $script:ConsumptionFile.FullName
        if ($Csv.Count -eq 0) { Set-ItResult -Skipped -Because "empty consumption csv"; return }

        foreach ($row in $Csv)
        {
            if (![string]::IsNullOrEmpty($row.ResourceId))
            {
                $row.ResourceId | Should -Match $script:ConsumptionSafePattern -Because "Consumption ResourceId should be obfuscated (flat token or structure-preserving ARM path)"
                $row.ResourceId | Should -Not -Match '/subscriptions/[0-9a-f]{8}-[0-9a-f]{4}' -Because "Consumption ResourceId must not contain a real subscription GUID"
            }
        }
    }

    It "Should have obfuscated ResourceUri inside AdditionalInfo JSON" {
        if ($null -eq $script:ConsumptionFile) { Set-ItResult -Skipped -Because "no consumption file in fixture"; return }
        $Csv = Import-Csv $script:ConsumptionFile.FullName
        if ($Csv.Count -eq 0) { Set-ItResult -Skipped -Because "empty consumption csv"; return }

        foreach ($row in $Csv)
        {
            if (![string]::IsNullOrEmpty($row.AdditionalInfo))
            {
                $InstanceData = $row.AdditionalInfo | ConvertFrom-Json
                $Uri = $InstanceData.'Microsoft.Resources'.ResourceUri
                if (![string]::IsNullOrEmpty($Uri))
                {
                    $Uri | Should -Match $script:ConsumptionSafePattern -Because "AdditionalInfo ResourceUri should be obfuscated (flat token or structure-preserving ARM path)"
                    $Uri | Should -Not -Match '/subscriptions/[0-9a-f]{8}-[0-9a-f]{4}' -Because "AdditionalInfo ResourceUri must not contain a real subscription GUID"
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
        $PlainGuidPattern = '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        foreach ($resource in $script:AllResources)
        {
            if ($null -ne $resource.ID)
            {
                $resource.ID | Should -Not -Match $PlainGuidPattern -Because "ID should have prod_/nonprod_ prefix"
            }
        }
    }
}

# ============================================================
# 12. Valid metrics JSON structure
# ============================================================
Describe "Metrics JSON Structure" {
    It "Should have valid metrics JSON with a Metrics array property" {
        foreach ($metricsFile in $script:MetricsFiles)
        {
            $Raw = Get-Content $metricsFile.FullName -Raw
            $Parsed = $Raw | ConvertFrom-Json
            $Parsed | Should -Not -BeNullOrEmpty -Because "Metrics file should be valid JSON"
            $Parsed.PSObject.Properties.Name | Should -Contain 'Metrics' -Because "Metrics JSON should have a Metrics property"
        }
    }
}

# ============================================================
# 13. Consumption CSV has valid headers
# ============================================================
Describe "Consumption CSV Headers" {
    It "Should have a consumption CSV with the correct header columns" {
        if ($null -eq $script:ConsumptionFile)
        {
            Set-ItResult -Skipped -Because "No consumption CSV in this report"
            return
        }
        $FirstLine = Get-Content $script:ConsumptionFile.FullName -TotalCount 1
        if ([string]::IsNullOrEmpty($FirstLine))
        {
            Set-ItResult -Skipped -Because "Consumption CSV is empty (no usage data in this subscription)"
            return
        }

        $ExpectedHeaders = @('AdditionalInfo', 'MeterCategory', 'MeterId', 'MeterName', 'MeterRegion', 'MeterSubCategory', 'Quantity', 'Unit', 'UsageStartTime', 'UsageEndTime', 'ResourceId', 'ResourceLocation', 'ConsumptionMeter', 'ReservationId', 'ReservationOrderId')
        foreach ($header in $ExpectedHeaders)
        {
            $FirstLine | Should -Match $header -Because "CSV should contain header '$header'"
        }
    }
}

# ============================================================
# 14. No Azure tenant IDs leaked
# ============================================================
Describe "Tenant ID Leak Check" {
    It "Should not contain Azure tenant ID patterns in output files" {
        # Tenant IDs appear as: "tenantId":"<guid>" or tenantID
        $TenantPattern = '"tenant[Ii][Dd]"\s*:\s*"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"'
        foreach ($fileName in $script:AllContent.Keys)
        {
            $script:AllContent[$fileName] | Should -Not -Match $TenantPattern -Because "File '$fileName' should not contain tenant IDs"
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
        if ($script:NonObfZip -and (Test-Path $script:NonObfZip))
        {
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
        if ($script:NoObfExtract -and (Test-Path $script:NoObfExtract))
        {
            Remove-Item -Path $script:NoObfExtract -Recurse -Force
        }
    }

    It "Should not contain 'obfuscated' in any output file when run without -Obfuscate" {
        if (-not $script:NoObfContent)
        {
            Set-ItResult -Skipped -Because "No non-obfuscated zip provided"
            return
        }
        foreach ($file in $script:NoObfContent.Keys)
        {
            if ($file -like "Transcript_*") { continue }
            $script:NoObfContent[$file] | Should -Not -Match 'obfuscated' -Because "File '$file' should contain real data, not obfuscated placeholders"
        }
    }

    It "Should not contain obfuscation GUID patterns in non-obfuscated output" {
        if (-not $script:NoObfContent)
        {
            Set-ItResult -Skipped -Because "No non-obfuscated zip provided"
            return
        }
        $GuidPattern = '(prod|nonprod)_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
        foreach ($file in $script:NoObfContent.Keys)
        {
            $script:NoObfContent[$file] | Should -Not -Match $GuidPattern -Because "File '$file' should not contain obfuscation GUIDs"
        }
    }
}
Describe "Cross-Reference Field Obfuscation" {
    # Each It asserts a cross-reference field is an obfuscation token ($script:ObfuscationPattern, defined once in the file-level BeforeAll) or a tolerated sentinel ('None'/'obfuscated'/null).
    # A duplicate $script:SafePattern was removed rather than fixed: it restated the contract, was never referenced by any It, and had drifted (omitting the (databricks_|aks_|vmss_)? segment, so it would reject legitimate AKS/Databricks/VMSS tokens). $script:ObfuscationPattern is the single owner.
    BeforeAll {
        $script:AzureIdPattern = '/subscriptions/[0-9a-f]{8}-[0-9a-f]{4}'
    }

    It "AppServices: ServerFarmId should be obfuscated or null" {
        $Resources = @($script:Inventory.AppServices) | Where-Object { $null -ne $_ }
        if ($Resources.Count -eq 0) { Set-ItResult -Skipped -Because "no AppServices resources in this fixture"; return }
        $Checked = 0
        foreach ($r in $Resources)
        {
            if ($null -ne $r -and ![string]::IsNullOrEmpty($r.ServerFarmId))
            {
                $r.ServerFarmId | Should -Not -Match $script:AzureIdPattern -Because "ServerFarmId should not contain raw Azure resource ID"
                $Checked++
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "no AppServices had a non-null ServerFarmId in this fixture" }
    }

    It "VirtualMachines: Set (VMSS ID) should be obfuscated or null" {
        $Resources = @($script:Inventory.VirtualMachines) | Where-Object { $null -ne $_ }
        if ($Resources.Count -eq 0) { Set-ItResult -Skipped -Because "no VirtualMachines resources in this fixture"; return }
        $Checked = 0
        foreach ($r in $Resources)
        {
            if ($null -ne $r -and ![string]::IsNullOrEmpty($r.Set))
            {
                $r.Set | Should -Match $script:ObfuscationPattern -Because "VMSS Set ID should be obfuscated"
                $Checked++
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "no VirtualMachines had a non-null Set (VMSS ID) in this fixture" }
    }

    It "VirtualMachines: Tags keys are preserved and values are obfuscated when obfuscated" {
        $ObfPattern = '^(prod|nonprod)_'
        $Resources = @($script:Inventory.VirtualMachines) | Where-Object { $null -ne $_ }
        if ($Resources.Count -eq 0) { Set-ItResult -Skipped -Because "no VirtualMachines resources in this fixture"; return }
        $Checked = 0
        foreach ($r in $Resources)
        {
            if ($null -ne $r -and $null -ne $r.Tags)
            {
                foreach ($tag in @($r.Tags))
                {
                    if ($null -ne $tag -and -not [string]::IsNullOrEmpty([string]$tag.Value))
                    {
                        # Key (Name) is kept verbatim; value must be a prod_/nonprod_ token.
                        $tag.Name  | Should -Not -BeNullOrEmpty -Because "tag keys are preserved for analytics"
                        $tag.Value | Should -Match $ObfPattern -Because "tag values must be obfuscated, not raw"
                        $Checked++
                    }
                }
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "no VirtualMachines had a tag with a non-empty value in this fixture" }
    }

    It "Purview: CreatedBy is obfuscated (tokenized, never raw identity)" {
        $Resources = @($script:Inventory.Purview) | Where-Object { $null -ne $_ }
        if ($Resources.Count -eq 0) { Set-ItResult -Skipped -Because "no Purview resources in this fixture"; return }
        $Checked = 0
        foreach ($r in $Resources)
        {
            if ($null -ne $r -and ![string]::IsNullOrEmpty($r.CreatedBy))
            {
                $r.CreatedBy | Should -Match '^(prod|nonprod)_' -Because "CreatedBy contains user identity and must be obfuscated to a token, never raw"
                $Checked++
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "no Purview had a non-null CreatedBy in this fixture" }
    }

    It "SQLDB: DatabaseServer should not contain raw resource names" {
        $Resources = @($script:Inventory.SQLDB) | Where-Object { $null -ne $_ }
        if ($Resources.Count -eq 0) { Set-ItResult -Skipped -Because "no SQLDB resources in this fixture"; return }
        $Checked = 0
        foreach ($r in $Resources)
        {
            if ($null -ne $r -and ![string]::IsNullOrEmpty($r.DatabaseServer))
            {
                $r.DatabaseServer | Should -Not -Match $script:AzureIdPattern -Because "DatabaseServer should not contain raw Azure resource ID"
                # ARM-path check alone lets a raw SHORT name (no /subscriptions/ prefix)
                # pass. Require an obfuscation token unless it is a tolerated sentinel.
                if ($r.DatabaseServer -notin @('obfuscated', 'None'))
                {
                    $r.DatabaseServer | Should -Match $script:ObfuscationPattern -Because "DatabaseServer must be an obfuscation token, not a raw short name"
                }
                $Checked++
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "no SQLDB had a non-null DatabaseServer in this fixture" }
    }

    It "SQLDB: ElasticPoolID should be obfuscated or 'None'" {
        $Resources = @($script:Inventory.SQLDB) | Where-Object { $null -ne $_ }
        if ($Resources.Count -eq 0) { Set-ItResult -Skipped -Because "no SQLDB resources in this fixture"; return }
        $Checked = 0
        foreach ($r in $Resources)
        {
            if ($null -ne $r -and ![string]::IsNullOrEmpty($r.ElasticPoolID))
            {
                $r.ElasticPoolID | Should -Not -Match $script:AzureIdPattern -Because "ElasticPoolID should not contain raw Azure resource ID"
                $Checked++
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "no SQLDB had a non-null ElasticPoolID in this fixture" }
    }

    It "AppInsights: WorkspaceResourceId should be obfuscated or 'None'" {
        $Resources = @($script:Inventory.AppInsights) | Where-Object { $null -ne $_ }
        if ($Resources.Count -eq 0) { Set-ItResult -Skipped -Because "no AppInsights resources in this fixture"; return }
        $Checked = 0
        foreach ($r in $Resources)
        {
            if ($null -ne $r -and ![string]::IsNullOrEmpty($r.WorkspaceResourceId))
            {
                $r.WorkspaceResourceId | Should -Not -Match $script:AzureIdPattern -Because "WorkspaceResourceId is a full ARM id in a non-obfuscated run and must be tokenized here"
                # An ARM-path check alone would let a raw workspace NAME through, so
                # require a token unless it is a tolerated sentinel. This asserts the
                # SHAPE of the value only - that it is a token rather than any real
                # identifier. It deliberately does not assert WHICH token: matching it
                # against the WrkSpace row's own ID is a join, covered separately.
                if ($r.WorkspaceResourceId -notin @('obfuscated', 'None'))
                {
                    $r.WorkspaceResourceId | Should -Match $script:ObfuscationPattern -Because "a resolved workspace link must be an obfuscation token, not a raw name or id"
                }
                $Checked++
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "no AppInsights had a non-null WorkspaceResourceId in this fixture" }
    }

    It "SQLMI: InstancePoolName should not contain raw resource IDs" {
        $Resources = @($script:Inventory.SQLMI) | Where-Object { $null -ne $_ }
        if ($Resources.Count -eq 0) { Set-ItResult -Skipped -Because "no SQLMI resources in this fixture"; return }
        $Checked = 0
        foreach ($r in $Resources)
        {
            if ($null -ne $r -and ![string]::IsNullOrEmpty($r.InstancePoolName))
            {
                $r.InstancePoolName | Should -Not -Match $script:AzureIdPattern -Because "InstancePoolName should not contain raw Azure resource ID"
                # ARM-path check alone lets a raw SHORT name pass. Require an
                # obfuscation token unless it is a tolerated sentinel.
                if ($r.InstancePoolName -notin @('obfuscated', 'None'))
                {
                    $r.InstancePoolName | Should -Match $script:ObfuscationPattern -Because "InstancePoolName must be an obfuscation token, not a raw short name"
                }
                $Checked++
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "no SQLMI had a non-null InstancePoolName in this fixture" }
    }

    It "SQLMIDB: ManagedInstance should be obfuscated or null" {
        $Resources = @($script:Inventory.SQLMIDB) | Where-Object { $null -ne $_ }
        if ($Resources.Count -eq 0) { Set-ItResult -Skipped -Because "no SQLMIDB resources in this fixture"; return }
        $Checked = 0
        foreach ($r in $Resources)
        {
            if ($null -ne $r -and ![string]::IsNullOrEmpty($r.ManagedInstance))
            {
                $r.ManagedInstance | Should -Not -Match $script:AzureIdPattern -Because "ManagedInstance should not contain raw Azure resource ID"
                $Checked++
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "no SQLMIDB had a non-null ManagedInstance in this fixture" }
    }

    It "PublicIP: AssociatedResource should not contain raw resource names" {
        $Resources = @($script:Inventory.PublicIP) | Where-Object { $null -ne $_ }
        if ($Resources.Count -eq 0) { Set-ItResult -Skipped -Because "no PublicIP resources in this fixture"; return }
        $Checked = 0
        foreach ($r in $Resources)
        {
            if ($null -ne $r -and ![string]::IsNullOrEmpty($r.AssociatedResource) -and $r.AssociatedResource -ne 'None')
            {
                $r.AssociatedResource | Should -Not -Match $script:AzureIdPattern -Because "AssociatedResource should not contain raw Azure resource ID"
                # ARM-path check alone lets a raw SHORT name pass. Require an
                # obfuscation token unless it is a tolerated sentinel.
                if ($r.AssociatedResource -notin @('obfuscated', 'None'))
                {
                    $r.AssociatedResource | Should -Match $script:ObfuscationPattern -Because "AssociatedResource must be an obfuscation token, not a raw short name"
                }
                $Checked++
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "no PublicIP had a non-null/non-'None' AssociatedResource in this fixture" }
    }

    It "VMDisk: AssociatedResource should be obfuscated or null" {
        $Resources = @($script:Inventory.VMDisk) | Where-Object { $null -ne $_ }
        if ($Resources.Count -eq 0) { Set-ItResult -Skipped -Because "no VMDisk resources in this fixture"; return }
        $Checked = 0
        foreach ($r in $Resources)
        {
            if ($null -ne $r -and ![string]::IsNullOrEmpty($r.AssociatedResource))
            {
                $r.AssociatedResource | Should -Not -Match $script:AzureIdPattern -Because "Disk AssociatedResource should not contain raw Azure resource ID"
                # ARM-path check alone lets a raw SHORT name pass. Require an
                # obfuscation token unless it is a tolerated sentinel.
                if ($r.AssociatedResource -notin @('obfuscated', 'None'))
                {
                    $r.AssociatedResource | Should -Match $script:ObfuscationPattern -Because "Disk AssociatedResource must be an obfuscation token, not a raw short name"
                }
                $Checked++
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "no VMDisk had a non-null AssociatedResource in this fixture" }
    }

    It "ComputeSnapshots: SourceResourceId should be obfuscated or null" {
        $Resources = @($script:Inventory.ComputeSnapshots) | Where-Object { $null -ne $_ }
        if ($Resources.Count -eq 0) { Set-ItResult -Skipped -Because "no ComputeSnapshots resources in this fixture"; return }
        $Checked = 0
        foreach ($r in $Resources)
        {
            if ($null -ne $r -and ![string]::IsNullOrEmpty($r.SourceResourceId))
            {
                $r.SourceResourceId | Should -Not -Match $script:AzureIdPattern -Because "SourceResourceId should not contain raw Azure resource ID"
                $Checked++
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "no ComputeSnapshots had a non-null SourceResourceId in this fixture" }
    }

    It "ComputeSnapshots: DiskEncryptionSet should be obfuscated or null" {
        $Resources = @($script:Inventory.ComputeSnapshots) | Where-Object { $null -ne $_ }
        if ($Resources.Count -eq 0) { Set-ItResult -Skipped -Because "no ComputeSnapshots resources in this fixture"; return }
        $Checked = 0
        foreach ($r in $Resources)
        {
            if ($null -ne $r -and ![string]::IsNullOrEmpty($r.DiskEncryptionSet))
            {
                $r.DiskEncryptionSet | Should -Not -Match $script:AzureIdPattern -Because "DiskEncryptionSet should not contain raw Azure resource ID"
                $Checked++
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "no ComputeSnapshots had a non-null DiskEncryptionSet in this fixture" }
    }

    It "AVD: HostId should be obfuscated or null" {
        $Resources = @($script:Inventory.AVD) | Where-Object { $null -ne $_ }
        if ($Resources.Count -eq 0) { Set-ItResult -Skipped -Because "no AVD resources in this fixture"; return }
        $Checked = 0
        foreach ($r in $Resources)
        {
            if ($null -ne $r -and ![string]::IsNullOrEmpty($r.HostId))
            {
                $r.HostId | Should -Not -Match $script:AzureIdPattern -Because "AVD HostId should not contain raw Azure resource ID"
                $Checked++
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "no AVD had a non-null HostId in this fixture" }
    }

    It "AVD: Hostname should be obfuscated or null" {
        $Resources = @($script:Inventory.AVD) | Where-Object { $null -ne $_ }
        if ($Resources.Count -eq 0) { Set-ItResult -Skipped -Because "no AVD resources in this fixture"; return }
        $Checked = 0
        foreach ($r in $Resources)
        {
            if ($null -ne $r -and ![string]::IsNullOrEmpty($r.Hostname))
            {
                $r.Hostname | Should -Not -Match $script:AzureIdPattern -Because "AVD Hostname should not contain raw Azure resource ID"
                $r.Hostname | Should -Match $script:ObfuscationPattern -Because "AVD Hostname should be obfuscated"
                $Checked++
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "no AVD had a non-null Hostname in this fixture" }
    }

    It "AVD: Hostname should differ from HostId" {
        $Resources = @($script:Inventory.AVD) | Where-Object { $null -ne $_ }
        if ($Resources.Count -eq 0) { Set-ItResult -Skipped -Because "no AVD resources in this fixture"; return }
        $Checked = 0
        foreach ($r in $Resources)
        {
            if ($null -ne $r -and ![string]::IsNullOrEmpty($r.Hostname) -and ![string]::IsNullOrEmpty($r.HostId))
            {
                $r.Hostname | Should -Not -Be $r.HostId -Because "Hostname and HostId should be different obfuscated values"
                $Checked++
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "no AVD had both a non-null Hostname and HostId in this fixture" }
    }

    It "MachineLearning: StorageAccount should be obfuscated or null" {
        $Resources = @($script:Inventory.MachineLearning) | Where-Object { $null -ne $_ }
        if ($Resources.Count -eq 0) { Set-ItResult -Skipped -Because "no MachineLearning resources in this fixture"; return }
        $Checked = 0
        foreach ($r in $Resources)
        {
            if ($null -ne $r -and ![string]::IsNullOrEmpty($r.StorageAccount))
            {
                $r.StorageAccount | Should -Not -Match $script:AzureIdPattern -Because "ML StorageAccount should not contain raw Azure resource ID"
                # ARM-path check alone lets a raw SHORT name pass. Require an
                # obfuscation token unless it is a tolerated sentinel.
                if ($r.StorageAccount -notin @('obfuscated', 'None'))
                {
                    $r.StorageAccount | Should -Match $script:ObfuscationPattern -Because "ML StorageAccount must be an obfuscation token, not a raw short name"
                }
                $Checked++
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "no MachineLearning had a non-null StorageAccount in this fixture" }
    }

    It "MachineLearning: KeyVault should be obfuscated or null" {
        $Resources = @($script:Inventory.MachineLearning) | Where-Object { $null -ne $_ }
        if ($Resources.Count -eq 0) { Set-ItResult -Skipped -Because "no MachineLearning resources in this fixture"; return }
        $Checked = 0
        foreach ($r in $Resources)
        {
            if ($null -ne $r -and ![string]::IsNullOrEmpty($r.KeyVault))
            {
                $r.KeyVault | Should -Not -Match $script:AzureIdPattern -Because "ML KeyVault should not contain raw Azure resource ID"
                # ARM-path check alone lets a raw SHORT name pass. Require an
                # obfuscation token unless it is a tolerated sentinel.
                if ($r.KeyVault -notin @('obfuscated', 'None'))
                {
                    $r.KeyVault | Should -Match $script:ObfuscationPattern -Because "ML KeyVault must be an obfuscation token, not a raw short name"
                }
                $Checked++
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "no MachineLearning had a non-null KeyVault in this fixture" }
    }

    It "Databricks: ManagedResourceGroup should be obfuscated or null" {
        $Resources = @($script:Inventory.Databricks) | Where-Object { $null -ne $_ }
        if ($Resources.Count -eq 0) { Set-ItResult -Skipped -Because "no Databricks resources in this fixture"; return }
        $Checked = 0
        foreach ($r in $Resources)
        {
            if ($null -ne $r -and ![string]::IsNullOrEmpty($r.ManagedResourceGroup))
            {
                $r.ManagedResourceGroup | Should -BeIn @('obfuscated') -Because "Databricks ManagedResourceGroup should be obfuscated"
                $Checked++
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "no Databricks had a non-null ManagedResourceGroup in this fixture" }
    }

    It "Databricks: StorageAccount should be obfuscated or null" {
        $Resources = @($script:Inventory.Databricks) | Where-Object { $null -ne $_ }
        if ($Resources.Count -eq 0) { Set-ItResult -Skipped -Because "no Databricks resources in this fixture"; return }
        $Checked = 0
        foreach ($r in $Resources)
        {
            if ($null -ne $r -and ![string]::IsNullOrEmpty($r.StorageAccount))
            {
                $r.StorageAccount | Should -BeIn @('obfuscated') -Because "Databricks StorageAccount should be obfuscated"
                $Checked++
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "no Databricks had a non-null StorageAccount in this fixture" }
    }

    It "Purview: FriendlyName is obfuscated (tokenized, never raw)" {
        $Resources = @($script:Inventory.Purview) | Where-Object { $null -ne $_ }
        if ($Resources.Count -eq 0) { Set-ItResult -Skipped -Because "no Purview resources in this fixture"; return }
        $Checked = 0
        foreach ($r in $Resources)
        {
            if ($null -ne $r -and ![string]::IsNullOrEmpty($r.FriendlyName))
            {
                $r.FriendlyName | Should -Match '^(prod|nonprod)_' -Because "Purview FriendlyName must be obfuscated to a token, never raw"
                $Checked++
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "no Purview had a non-null FriendlyName in this fixture" }
    }

    It "Frontdoor: WebApplicationFirewall should be obfuscated or a known marker" {
        $Resources = @($script:Inventory.FRONTDOOR) | Where-Object { $null -ne $_ }
        if ($Resources.Count -eq 0) { Set-ItResult -Skipped -Because "no FRONTDOOR resources in this fixture"; return }
        # Skip known non-ID markers: 'False' (Classic, no WAF), 'Unknown' (Std/Premium,
        # not detectable from the profile). Any remaining value must not leak an Azure path.
        $Checked = 0
        foreach ($r in $Resources)
        {
            if ($null -ne $r -and ![string]::IsNullOrEmpty($r.WebApplicationFirewall) -and $r.WebApplicationFirewall -notin @('False', 'Unknown'))
            {
                $r.WebApplicationFirewall | Should -Not -Match $script:AzureIdPattern -Because "Frontdoor WAF should not contain raw Azure resource ID"
                $Checked++
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "no FRONTDOOR had a non-null WebApplicationFirewall value outside the known 'False'/'Unknown' markers in this fixture" }
    }
}

# ============================================================
# 16. Dictionary file excluded from zip
# ============================================================
Describe "Dictionary File Exclusion" {
    It "Should not contain the obfuscation dictionary in the zip" {
        $DictFiles = $script:AllFiles | Where-Object { $_.Name -like "ObfuscationDictionary_*" }
        $DictFiles | Should -BeNullOrEmpty -Because "Dictionary file should stay local, not in the zip"
    }
}

# 16b. Full (raw) resource dump excluded from zip (P10): the -Obfuscate run also writes a LOCAL Full_*.json ($Global:AllResourceFile) of the RAW dump; the packaging json filter excludes both ObfuscationDictionary_* and Full_* (ResourceInventory.ps1 L1671). Asserts the shared ZIP carries no Full_* member, whose presence would leak every real identifier.
# Validates: Requirements 12.1 | Property: P10
Describe "Full Resource Dump Exclusion (P10)" {
    It "Should not contain the raw Full_* resource dump in the zip" {
        $FullDumpFiles = $script:AllFiles | Where-Object { $_.Name -like "Full_*" }
        $FullDumpFiles | Should -BeNullOrEmpty -Because "Full_* raw resource dump should stay local, not in the shared zip (P10)"
    }
}

# 17. Obfuscation determinism (P1): within a run the same real value must map to the SAME token. Asserted against the reverse-lookup dictionary (token -> real value) - a real value reachable from two DISTINCT tokens means two outputs for one input. Skips when no dictionary fixture; count-independent.
# Validates: Requirements 2.1, 2.5 | Property: P1
Describe "Obfuscation Determinism (P1)" {
    It "ResourceGroup: each real resource group maps to exactly one token" {
        if (-not $script:DictionaryAvailable) { Set-ItResult -Skipped -Because "No ObfuscationDictionary fixture available; set `$env:TEST_DICT_PATH"; return }
        $Map = $script:Dictionary.ResourceGroupMap
        if ($null -eq $Map -or @($Map.PSObject.Properties).Count -eq 0) { Set-ItResult -Skipped -Because "ResourceGroupMap absent/empty in this dictionary"; return }
        $Violations = Get-DeterminismViolation -Map $Map -RealValueSelector { param($v) if ($v -match '/resourceGroups/([^/]+)') { $Matches[1] } }
        $Violations | Should -BeNullOrEmpty -Because "no real resource group may yield two different tokens within a run (P1)"
    }

    It "Subscription: each real subscription maps to exactly one token" {
        if (-not $script:DictionaryAvailable) { Set-ItResult -Skipped -Because "No ObfuscationDictionary fixture available; set `$env:TEST_DICT_PATH"; return }
        $Map = $script:Dictionary.SubscriptionMap
        if ($null -eq $Map -or @($Map.PSObject.Properties).Count -eq 0) { Set-ItResult -Skipped -Because "SubscriptionMap absent/empty in this dictionary"; return }
        $Violations = Get-DeterminismViolation -Map $Map -RealValueSelector { param($v) if ($v -match '/subscriptions/([0-9a-fA-F-]+)') { $Matches[1] } }
        $Violations | Should -BeNullOrEmpty -Because "no real subscription may yield two different tokens within a run (P1)"
    }

    It "ResourceId: each real resource id maps to exactly one token" {
        if (-not $script:DictionaryAvailable) { Set-ItResult -Skipped -Because "No ObfuscationDictionary fixture available; set `$env:TEST_DICT_PATH"; return }
        $Map = $script:Dictionary.ResourceIdMap
        if ($null -eq $Map -or @($Map.PSObject.Properties).Count -eq 0) { Set-ItResult -Skipped -Because "ResourceIdMap absent/empty in this dictionary"; return }
        $Violations = Get-DeterminismViolation -Map $Map -RealValueSelector { param($v) $v }
        $Violations | Should -BeNullOrEmpty -Because "no real resource id may yield two different tokens within a run (P1)"
    }

    It "ResourceName: each real resource id maps to exactly one name token" {
        if (-not $script:DictionaryAvailable) { Set-ItResult -Skipped -Because "No ObfuscationDictionary fixture available; set `$env:TEST_DICT_PATH"; return }
        $Map = $script:Dictionary.ResourceNameMap
        if ($null -eq $Map -or @($Map.PSObject.Properties).Count -eq 0) { Set-ItResult -Skipped -Because "ResourceNameMap absent/empty in this dictionary"; return }
        # Name tokens are keyed per real resource id (two resources sharing a
        # display name in different RGs legitimately get different name tokens),
        # so determinism is asserted against the real resource id, not the name.
        $Violations = Get-DeterminismViolation -Map $Map -RealValueSelector { param($v) $v }
        $Violations | Should -BeNullOrEmpty -Because "no real resource id may yield two different name tokens within a run (P1)"
    }

    It "Tag: each real tag value maps to exactly one token" {
        if (-not $script:DictionaryAvailable) { Set-ItResult -Skipped -Because "No ObfuscationDictionary fixture available; set `$env:TEST_DICT_PATH"; return }
        $Map = $script:Dictionary.TagMap
        if ($null -eq $Map -or @($Map.PSObject.Properties).Count -eq 0) { Set-ItResult -Skipped -Because "TagMap absent/empty in this dictionary"; return }
        $Violations = Get-DeterminismViolation -Map $Map -RealValueSelector { param($v) $v }
        $Violations | Should -BeNullOrEmpty -Because "no real tag value may yield two different tokens within a run (P1)"
    }

    It "FreeText: each real free-text value maps to exactly one token" {
        if (-not $script:DictionaryAvailable) { Set-ItResult -Skipped -Because "No ObfuscationDictionary fixture available; set `$env:TEST_DICT_PATH"; return }
        $Map = $script:Dictionary.FreeTextMap
        if ($null -eq $Map -or @($Map.PSObject.Properties).Count -eq 0) { Set-ItResult -Skipped -Because "FreeTextMap absent/empty in this dictionary"; return }
        $Violations = Get-DeterminismViolation -Map $Map -RealValueSelector { param($v) $v }
        $Violations | Should -BeNullOrEmpty -Because "no real free-text value may yield two different tokens within a run (P1)"
    }
}

# 18. Obfuscation injectivity / no token collisions (P2): distinct real values must produce DISTINCT tokens. Tokens are unique map keys by construction, so an injectivity failure surfaces as the SAME real value reachable from >1 token - the converse of P1, so Get-DeterminismViolation is reused per map. Selectors mirror P1 (ResourceName keyed on real id). Skips when no dictionary fixture; count-independent.
# Validates: Requirements 2.1 | Property: P2
Describe "Obfuscation Injectivity (P2)" {
    It "ResourceGroup: no two tokens share the same real resource group" {
        if (-not $script:DictionaryAvailable) { Set-ItResult -Skipped -Because "No ObfuscationDictionary fixture available; set `$env:TEST_DICT_PATH"; return }
        $Map = $script:Dictionary.ResourceGroupMap
        if ($null -eq $Map -or @($Map.PSObject.Properties).Count -eq 0) { Set-ItResult -Skipped -Because "ResourceGroupMap absent/empty in this dictionary"; return }
        $Collisions = Get-DeterminismViolation -Map $Map -RealValueSelector { param($v) if ($v -match '/resourceGroups/([^/]+)') { $Matches[1] } }
        $Collisions | Should -BeNullOrEmpty -Because "distinct real resource groups must map to distinct tokens; no token may cover two real values (P2)"
    }

    It "Subscription: no two tokens share the same real subscription" {
        if (-not $script:DictionaryAvailable) { Set-ItResult -Skipped -Because "No ObfuscationDictionary fixture available; set `$env:TEST_DICT_PATH"; return }
        $Map = $script:Dictionary.SubscriptionMap
        if ($null -eq $Map -or @($Map.PSObject.Properties).Count -eq 0) { Set-ItResult -Skipped -Because "SubscriptionMap absent/empty in this dictionary"; return }
        $Collisions = Get-DeterminismViolation -Map $Map -RealValueSelector { param($v) if ($v -match '/subscriptions/([0-9a-fA-F-]+)') { $Matches[1] } }
        $Collisions | Should -BeNullOrEmpty -Because "distinct real subscriptions must map to distinct tokens; no token may cover two real values (P2)"
    }

    It "ResourceId: no two tokens share the same real resource id" {
        if (-not $script:DictionaryAvailable) { Set-ItResult -Skipped -Because "No ObfuscationDictionary fixture available; set `$env:TEST_DICT_PATH"; return }
        $Map = $script:Dictionary.ResourceIdMap
        if ($null -eq $Map -or @($Map.PSObject.Properties).Count -eq 0) { Set-ItResult -Skipped -Because "ResourceIdMap absent/empty in this dictionary"; return }
        $Collisions = Get-DeterminismViolation -Map $Map -RealValueSelector { param($v) $v }
        $Collisions | Should -BeNullOrEmpty -Because "distinct real resource ids must map to distinct tokens; no token may cover two real values (P2)"
    }

    It "ResourceName: no two name tokens share the same real resource id" {
        if (-not $script:DictionaryAvailable) { Set-ItResult -Skipped -Because "No ObfuscationDictionary fixture available; set `$env:TEST_DICT_PATH"; return }
        $Map = $script:Dictionary.ResourceNameMap
        if ($null -eq $Map -or @($Map.PSObject.Properties).Count -eq 0) { Set-ItResult -Skipped -Because "ResourceNameMap absent/empty in this dictionary"; return }
        # Name tokens are keyed per real resource id (mirrors the P1 selector),
        # so injectivity is asserted against the real resource id, not the name.
        $Collisions = Get-DeterminismViolation -Map $Map -RealValueSelector { param($v) $v }
        $Collisions | Should -BeNullOrEmpty -Because "distinct real resource ids must map to distinct name tokens; no name token may cover two real values (P2)"
    }

    It "Tag: no two tokens share the same real tag value" {
        if (-not $script:DictionaryAvailable) { Set-ItResult -Skipped -Because "No ObfuscationDictionary fixture available; set `$env:TEST_DICT_PATH"; return }
        $Map = $script:Dictionary.TagMap
        if ($null -eq $Map -or @($Map.PSObject.Properties).Count -eq 0) { Set-ItResult -Skipped -Because "TagMap absent/empty in this dictionary"; return }
        $Collisions = Get-DeterminismViolation -Map $Map -RealValueSelector { param($v) $v }
        $Collisions | Should -BeNullOrEmpty -Because "distinct real tag values must map to distinct tokens; no token may cover two real values (P2)"
    }

    It "FreeText: no two tokens share the same real free-text value" {
        if (-not $script:DictionaryAvailable) { Set-ItResult -Skipped -Because "No ObfuscationDictionary fixture available; set `$env:TEST_DICT_PATH"; return }
        $Map = $script:Dictionary.FreeTextMap
        if ($null -eq $Map -or @($Map.PSObject.Properties).Count -eq 0) { Set-ItResult -Skipped -Because "FreeTextMap absent/empty in this dictionary"; return }
        $Collisions = Get-DeterminismViolation -Map $Map -RealValueSelector { param($v) $v }
        $Collisions | Should -BeNullOrEmpty -Because "distinct real free-text values must map to distinct tokens; no token may cover two real values (P2)"
    }
}

# 19. Tag tokenization - keys kept, values masked, determinism, and the mixed-case tag-key regression. This fixture carries no tagged resources (TagMap empty, VM Tags loop has no rows), so two fixture-independent layers close Req 4.1-4.5: (1) a logic-level exercise of the EXACT tag-obfuscation loop (ResourceInventory.ps1 L1002-1017) against a MIXED-CASE Tags hashtable, and (2) a SOURCE-AUDIT regression that fails if the case-sensitive tag-scrub bug returns.
# Validates: Requirements 4.1, 4.2, 4.3, 4.4, 4.5 | Property: P1
Describe "Tag Tokenization — keys kept, values masked, mixed-case regression (P1)" {
    BeforeAll {
        # Faithful mirror of the tag-value classifier + tokenizer in ResourceInventory.ps1 L1002-1017 (same non-prod regex set, Req 3.3) over the shape collectors produce: a case-insensitive [hashtable] $ResourceItem whose 'Tags' value is an array of { Name, Value }. Replicated (not invoked) because the real block lives in the module-loop and the prod-only fixture cannot drive tag data through the ZIP; the source-audit Context below guards the real source.
        function script:Invoke-TagObfuscation
        {
            param(
                [Parameter(Mandatory)] $ResourceItem,
                [Parameter(Mandatory)] $TagValueDictionary
            )

            if ($ResourceItem.ContainsKey('Tags') -and $null -ne $ResourceItem.Tags)
            {
                foreach ($tag in $ResourceItem.Tags)
                {
                    if ($null -ne $tag -and -not [string]::IsNullOrEmpty([string]$tag.Value))
                    {
                        $RealTagValue = [string]$tag.Value
                        if (-not $TagValueDictionary.ContainsKey($RealTagValue))
                        {
                            $TagPrefix = if ($RealTagValue -match '\b(dev|test|qa|tst|development|non-prod|uat|nonprod)\b' -or $RealTagValue -match '(^|-)([dts])-') { 'nonprod_' } else { 'prod_' }
                            $TagValueDictionary[$RealTagValue] = $TagPrefix + [guid]::NewGuid().ToString()
                        }
                        $tag.Value = $TagValueDictionary[$RealTagValue]
                    }
                }
            }
        }

        $script:TagTokenPattern = '^(prod|nonprod)_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        $script:RiSourcePath = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'ResourceInventory.ps1'
    }

    It "keeps mixed-case tag KEYS verbatim and masks VALUES to tokens (Req 4.1, 4.2, 4.5)" {
        # Mixed-case keys on purpose (Environment / CostCenter / Owner) to guard
        # the case-insensitive handling. Values are synthetic only (no real ids).
        $ResourceItem = @{
            ID   = 'prod_' + [guid]::NewGuid().ToString()
            Tags = @(
                [PSCustomObject]@{ Name = 'Environment'; Value = 'production' }
                [PSCustomObject]@{ Name = 'CostCenter'; Value = 'finance-ops' }
                [PSCustomObject]@{ Name = 'Owner'; Value = 'platform-team' }
            )
        }
        $Dict = New-Object 'System.Collections.Generic.Dictionary[string,string]'

        script:Invoke-TagObfuscation -ResourceItem $ResourceItem -TagValueDictionary $Dict

        # 4.5: structured Tags survives (not nulled / not dropped by a scrub)
        $ResourceItem.Tags | Should -Not -BeNullOrEmpty -Because "structured Tags must survive tokenization, not be nulled (Req 4.5)"
        @($ResourceItem.Tags).Count | Should -Be 3 -Because "no tag row may be dropped by a mixed-case scrub (Req 4.5)"

        $ExpectedKeys = @('Environment', 'CostCenter', 'Owner')
        for ($i = 0; $i -lt 3; $i++)
        {
            # 4.1: key kept verbatim, including its original mixed casing
            $ResourceItem.Tags[$i].Name  | Should -BeExactly $ExpectedKeys[$i] -Because "tag KEY '$($ExpectedKeys[$i])' must be preserved verbatim, casing intact (Req 4.1)"
            # 4.2: value replaced with a prod_/nonprod_ token
            $ResourceItem.Tags[$i].Value | Should -Match $script:TagTokenPattern -Because "tag VALUE must be a prod_/nonprod_ token, not raw (Req 4.2)"
        }
    }

    It "emits the SAME token for the same tag value across resources (Req 4.3 | P1)" {
        $Dict = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $ItemA = @{ ID = 'a'; Tags = @([PSCustomObject]@{ Name = 'Env'; Value = 'shared-value' }) }
        $ItemB = @{ ID = 'b'; Tags = @([PSCustomObject]@{ Name = 'Tier'; Value = 'shared-value' }) }

        script:Invoke-TagObfuscation -ResourceItem $ItemA -TagValueDictionary $Dict
        script:Invoke-TagObfuscation -ResourceItem $ItemB -TagValueDictionary $Dict

        $ItemA.Tags[0].Value | Should -Be $ItemB.Tags[0].Value -Because "the same real tag value must map to one token within a run (Req 4.3 / P1)"
    }

    It "derives the prod/nonprod prefix from the tag VALUE (Req 4.2 environment signal)" {
        $Dict = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Item = @{
            ID   = 'x'
            Tags = @(
                [PSCustomObject]@{ Name = 'Stage'; Value = 'qa' }           # non-prod set member
                [PSCustomObject]@{ Name = 'Stage'; Value = 'core-billing' } # neutral -> prod
            )
        }
        script:Invoke-TagObfuscation -ResourceItem $Item -TagValueDictionary $Dict
        $Item.Tags[0].Value | Should -Match '^nonprod_' -Because "'qa' matches the non-prod set"
        $Item.Tags[1].Value | Should -Match '^prod_'    -Because "'core-billing' is neutral -> prod"
    }

    It "records each token -> real tag value mapping so TagMap can be inverted (Req 4.4)" {
        # TagMap is built by inverting $Global:TagValueDictionary
        # (ResourceInventory.ps1 L1582-1586). Assert the dictionary this loop
        # populates carries the real value under the emitted token, which is
        # exactly what the inversion serializes into TagMap.
        $Dict = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Item = @{ ID = 'y'; Tags = @([PSCustomObject]@{ Name = 'Team'; Value = 'analytics-platform' }) }

        script:Invoke-TagObfuscation -ResourceItem $Item -TagValueDictionary $Dict

        $Token = $Item.Tags[0].Value
        $Dict.ContainsKey('analytics-platform') | Should -BeTrue -Because "the real tag value must be keyed in the dictionary that TagMap inverts (Req 4.4)"
        $Dict['analytics-platform'] | Should -Be $Token -Because "token <-> real value must round-trip through TagMap (Req 4.4)"
    }

    # ---- Source-audit regression: the mixed-case / lowercase-scrub bug (Req 4.5) ----
    # Reads the shipped source and fails if the case-insensitive tag handling is
    # regressed. This is the assertion that genuinely guards the already-fixed
    # bug: if a future edit reintroduced a lowercase-only / case-sensitive scrub
    # that nulled structured Tags, one of these fails.
    Context "Source case-insensitive tag handling (Req 4.5)" {
        BeforeAll {
            $script:RiSourcePresent = Test-Path $script:RiSourcePath
            $script:RiSource = if ($script:RiSourcePresent) { Get-Content $script:RiSourcePath -Raw } else { '' }
        }

        It "ResourceInventory.ps1 is present for source audit" {
            $script:RiSourcePresent | Should -BeTrue -Because "the regression audits the shipped obfuscation source"
        }

        It "malformed-row scrub clears BOTH 'tags' and 'Tags' key variants (case-insensitive) (Req 4.5)" {
            # -cmatch is case-SENSITIVE and anchors on the SCRUB ASSIGNMENT STATEMENT ($resourceItem.<case>.tags/Tags = $null), unique to the malformed-row path (L948-949); the bare ContainsKey('Tags') token also appears at the L1002 obfuscation guard, so matching the token alone would be a false guard. Dropping either case variant (a lowercase-only / case-sensitive scrub) fails here.
            ($script:RiSource -cmatch '\$resourceItem\.tags = \$null') | Should -BeTrue -Because "lowercase tag key variant must be scrubbed on the malformed-row path (Req 4.5)"
            ($script:RiSource -cmatch '\$resourceItem\.Tags = \$null') | Should -BeTrue -Because "PascalCase tag key variant must be scrubbed on the malformed-row path (Req 4.5)"
        }

        It "structured-tag obfuscation is guarded by ContainsKey('Tags') and tokenizes in place (Req 4.2, 4.5)" {
            ($script:RiSource -cmatch "ContainsKey\('Tags'\) -and") | Should -BeTrue -Because "structured Tags must be tokenized in place, never scrubbed to null (Req 4.5)"
            $script:RiSource | Should -Match '\$tag\.Value = \$Global:TagValueDictionary' -Because "the tag VALUE is what gets tokenized (Req 4.2)"
        }

        It "never reassigns a tag KEY (`$tag.Name), so keys are kept verbatim (Req 4.1)" {
            $script:RiSource | Should -Not -Match '\$tag\.Name\s*=[^=]' -Because "tag KEYS must be preserved verbatim; reassigning `$tag.Name would rewrite a key (Req 4.1)"
        }
    }
}

# 20. AKS multi-node-pool Tags: no shared-reference aliasing (P1, P2). AKS.ps1 emits one row per node pool; if the Select-Object that builds 'Tags' were hoisted outside the inner loop the rows would share ONE Tags object, and the in-place obfuscation ($tag.Value = $Global:TagValueDictionary[$realTagValue]) would let row 1's mutation corrupt row 2 - re-keying an already-tokenized value into the dictionary (P2 violation) and breaking TagMap. Invokes the ACTUAL collector against a synthetic two-node-pool cluster.
# Validates: Requirements 2.1, 4.1, 4.2, 4.3 | Properties: P1, P2
Describe "AKS Multi-Node-Pool Tags — no cross-row aliasing (P1, P2)" {
    BeforeAll {
        # Minimal synthetic managedClusters resource with TWO node pools and
        # ONE real tag value shared by the whole cluster. No real identifiers.
        $script:AksCluster = [PSCustomObject]@{
            id             = 'prod_' + [guid]::NewGuid().ToString()
            RESOURCEGROUP  = 'rg-aks-regress'
            NAME           = 'aks-regress'
            LOCATION       = 'eastus'
            TYPE           = 'microsoft.containerservice/managedclusters'
            subscriptionId = 'sub-regress'
            sku            = [PSCustomObject]@{ name = 'Base'; tier = 'Free' }
            tags           = [PSCustomObject]@{ environment = 'dev' }
            PROPERTIES     = [PSCustomObject]@{
                kubernetesVersion = '1.29'
                networkProfile    = [PSCustomObject]@{ loadBalancerSku = 'Standard' }
                agentPoolProfiles = @(
                    [PSCustomObject]@{ name = 'nodepool1'; type = 'VirtualMachineScaleSets'; mode = 'System'; osType = 'Linux'; vmSize = 'Standard_B2s'; osDiskSizeGB = 30; count = 1; maxPods = 30; orchestratorVersion = '1.29' }
                    [PSCustomObject]@{ name = 'nodepool2'; type = 'VirtualMachineScaleSets'; mode = 'User'; osType = 'Linux'; vmSize = 'Standard_B2s'; osDiskSizeGB = 30; count = 1; maxPods = 30; orchestratorVersion = '1.29' }
                )
            }
        }
        $script:AksSub = @([PSCustomObject]@{ id = 'sub-regress'; Name = 'sub-regress' })
        $script:AksModule = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'Services', 'Containers', 'AKS.ps1'
    }

    It "AKS.ps1 module file is present for direct invocation" {
        Test-Path $script:AksModule | Should -BeTrue
    }

    It "emits one row per node pool, each with its OWN Tags object instance (no aliasing)" {
        $Rows = & $script:AksModule -Sub $script:AksSub -Resources @($script:AksCluster) -Task 'Processing' -ResourceIdDictionary $null
        @($Rows).Count | Should -Be 2 -Because "one row per node pool"
        [object]::ReferenceEquals($Rows[0].Tags, $Rows[1].Tags) | Should -BeFalse -Because "each node-pool row must get its own Tags object instance, not a shared reference"
    }

    It "the real tag-obfuscation loop yields exactly ONE dictionary entry and ONE shared token across both rows (P1, P2)" {
        $Rows = & $script:AksModule -Sub $script:AksSub -Resources @($script:AksCluster) -Task 'Processing' -ResourceIdDictionary $null
        $Dict = New-Object 'System.Collections.Generic.Dictionary[string,string]'

        # Run the SAME tag-obfuscation loop ResourceInventory.ps1 runs per
        # resourceItem (L1002-1017), once per row, exactly as production does.
        foreach ($ResourceItem in $Rows)
        {
            if ($ResourceItem.ContainsKey('Tags') -and $null -ne $ResourceItem.Tags)
            {
                foreach ($tag in $ResourceItem.Tags)
                {
                    if ($null -ne $tag -and -not [string]::IsNullOrEmpty([string]$tag.Value))
                    {
                        $RealTagValue = [string]$tag.Value
                        if (-not $Dict.ContainsKey($RealTagValue))
                        {
                            $TagPrefix = if ($RealTagValue -match '\b(dev|test|qa|tst|development|non-prod|uat|nonprod)\b' -or $RealTagValue -match '(^|-)([dts])-') { 'nonprod_' } else { 'prod_' }
                            $Dict[$RealTagValue] = $TagPrefix + [guid]::NewGuid().ToString()
                        }
                        $tag.Value = $Dict[$RealTagValue]
                    }
                }
            }
        }

        # P2 injectivity: exactly one real value went in, so exactly one entry
        # must come out. A count of 2 here is the aliasing bug's signature (the
        # already-tokenized value on row 2 gets misread as a second "real" value).
        $Dict.Count | Should -Be 1 -Because "one real tag value must yield exactly one dictionary entry, even across multiple node-pool rows for the same cluster (P2)"

        # P1 determinism across rows: both rows' tag must resolve to the SAME
        # token, and that token must actually be present as a dictionary value.
        $Rows[0].Tags[0].Value | Should -Be $Rows[1].Tags[0].Value -Because "the same real tag value on two rows of the same cluster must yield the same token (P1)"
        $Dict.Values | Should -Contain $Rows[0].Tags[0].Value -Because "the shared token must be the one real dictionary entry produced, not a spurious second entry"
    }
}

# 21. AKS Autoscale field: the emitted 'Autoscale' column must reflect enableAutoScaling
# faithfully. The collector compares against the string 'true' (AKS.ps1) rather than a bare
# truth test, because enableAutoScaling can arrive as a real bool, as $null (pool omits it),
# or as the stringified 'false'. A bare truth test would treat the non-empty string 'false'
# as $true and report autoscale ON for a pool that has it OFF. This exercises the ACTUAL
# collector against pools covering all three shapes.
Describe "AKS Autoscale field reflects enableAutoScaling faithfully" {
    BeforeAll {
        $script:AksModule = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'Services', 'Containers', 'AKS.ps1'
        $script:AutoSub = @([PSCustomObject]@{ id = 'sub-auto'; Name = 'sub-auto' })
        $script:AutoCluster = [PSCustomObject]@{
            id             = 'prod_' + [guid]::NewGuid().ToString()
            RESOURCEGROUP  = 'rg-aks-auto'
            NAME           = 'aks-auto'
            LOCATION       = 'eastus'
            TYPE           = 'microsoft.containerservice/managedclusters'
            subscriptionId = 'sub-auto'
            sku            = [PSCustomObject]@{ name = 'Base'; tier = 'Free' }
            tags           = [PSCustomObject]@{ environment = 'prod' }
            PROPERTIES     = [PSCustomObject]@{
                kubernetesVersion = '1.29'
                networkProfile    = [PSCustomObject]@{ loadBalancerSku = 'Standard' }
                agentPoolProfiles = @(
                    # Pool with autoscale genuinely ON, with bounds.
                    [PSCustomObject]@{ name = 'poolon'; type = 'VirtualMachineScaleSets'; mode = 'System'; osType = 'Linux'; vmSize = 'Standard_B2s'; osDiskSizeGB = 30; count = 3; maxPods = 30; orchestratorVersion = '1.29'; enableAutoScaling = $true; maxCount = 5; minCount = 1 }
                    # Pool with autoscale explicitly OFF as the stringified 'false'.
                    [PSCustomObject]@{ name = 'pooloff'; type = 'VirtualMachineScaleSets'; mode = 'User'; osType = 'Linux'; vmSize = 'Standard_B2s'; osDiskSizeGB = 30; count = 1; maxPods = 30; orchestratorVersion = '1.29'; enableAutoScaling = 'false' }
                    # Pool that omits enableAutoScaling entirely (property is $null).
                    [PSCustomObject]@{ name = 'poolabsent'; type = 'VirtualMachineScaleSets'; mode = 'User'; osType = 'Linux'; vmSize = 'Standard_B2s'; osDiskSizeGB = 30; count = 1; maxPods = 30; orchestratorVersion = '1.29' }
                )
            }
        }
        $script:AutoRows = & $script:AksModule -Sub $script:AutoSub -Resources @($script:AutoCluster) -Task 'Processing' -ResourceIdDictionary $null
    }

    It "reports Autoscale 'true' for a pool with enableAutoScaling `$true" {
        $Row = @($script:AutoRows) | Where-Object { $_.NodePoolName -eq 'poolon' }
        $Row.Autoscale | Should -Be 'true'
        $Row.AutoscaleMax | Should -Be 5
        $Row.AutoscaleMin | Should -Be 1
    }

    It "reports Autoscale 'false' for a pool whose enableAutoScaling is the string 'false' (not treated as truthy)" {
        $Row = @($script:AutoRows) | Where-Object { $_.NodePoolName -eq 'pooloff' }
        $Row.Autoscale | Should -Be 'false' -Because "the non-empty string 'false' must NOT be read as autoscale ON"
        $Row.AutoscaleMax | Should -Be '0'
        $Row.AutoscaleMin | Should -Be '0'
    }

    It "reports Autoscale 'false' with '0' bounds for a pool that omits enableAutoScaling" {
        $Row = @($script:AutoRows) | Where-Object { $_.NodePoolName -eq 'poolabsent' }
        $Row.Autoscale | Should -Be 'false'
        $Row.AutoscaleMax | Should -Be '0'
        $Row.AutoscaleMin | Should -Be '0'
    }
}
