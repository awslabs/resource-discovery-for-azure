# Front Door Collector Tests
# Validates the Frontdoor.ps1 collector handles Classic, Standard, and Premium tiers
# correctly and obfuscates WAF cross-references properly.
# Run with: Invoke-Pester ./Tests/Frontdoor.Tests.ps1 -Output Detailed

BeforeAll {
    $zipPath = if ($env:TEST_ZIP_PATH) { $env:TEST_ZIP_PATH } else {
        Get-ChildItem -Path $PSScriptRoot -Filter "ResourcesReport_*.zip" | 
            Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
    if ([string]::IsNullOrEmpty($zipPath) -or -not (Test-Path $zipPath)) {
        throw "No test zip found. Copy a ResourcesReport_*.zip to Tests/ or set `$env:TEST_ZIP_PATH"
    }
    $tmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { "/tmp" }
    $script:ExtractPath = Join-Path $tmpBase ("FrontdoorTest_" + [guid]::NewGuid().ToString().Substring(0,8))
    New-Item -ItemType Directory -Path $script:ExtractPath -Force | Out-Null
    Expand-Archive -Path $zipPath -DestinationPath $script:ExtractPath -Force

    $invFile = Get-ChildItem -Path $script:ExtractPath -Filter "Inventory_*.json" | Select-Object -First 1
    $script:Inventory = if ($invFile) { Get-Content $invFile.FullName -Raw | ConvertFrom-Json } else { $null }
    $script:FrontDoors = @($script:Inventory.FRONTDOOR) | Where-Object { $null -ne $_ }

    $script:ObfuscationPattern = '^(prod|nonprod)_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    $script:AzureIdPattern = '/subscriptions/[0-9a-f]{8}-[0-9a-f]{4}'

    # Detect whether this zip is from an obfuscated run (any ID matches the pattern)
    $script:IsObfuscated = $false
    if ($script:FrontDoors.Count -gt 0 -and $null -ne $script:FrontDoors[0].ID) {
        $script:IsObfuscated = $script:FrontDoors[0].ID -match $script:ObfuscationPattern
    }
}

AfterAll {
    if (Test-Path $script:ExtractPath) { Remove-Item -Path $script:ExtractPath -Recurse -Force }
}

Describe "Front Door Collector Schema" {
    It "Should produce entries with all expected fields" {
        if ($script:FrontDoors.Count -eq 0) { return }
        $expected = @('ID', 'Subscription', 'ResourceGroup', 'Name', 'Location', 'Type', 'State', 'WebApplicationFirewall', 'ResourceType')
        foreach ($fd in $script:FrontDoors) {
            foreach ($field in $expected) {
                $fd.PSObject.Properties.Name | Should -Contain $field -Because "Every Front Door entry should have a '$field' field"
            }
        }
    }
}

Describe "Front Door Tier Detection" {
    It "Type field should only contain known tier values" {
        if ($script:FrontDoors.Count -eq 0) { return }
        $validTypes = @('Classic', 'Standard/Premium')
        foreach ($fd in $script:FrontDoors) {
            $fd.Type | Should -BeIn $validTypes -Because "Type should be one of: $($validTypes -join ', ')"
        }
    }

    It "Type should not be null or empty on any Front Door" {
        if ($script:FrontDoors.Count -eq 0) { return }
        foreach ($fd in $script:FrontDoors) {
            $fd.Type | Should -Not -BeNullOrEmpty -Because "Type must always be populated"
        }
    }
}

Describe "Front Door State Field" {
    It "State should not be null (fallback chain must produce a value)" {
        if ($script:FrontDoors.Count -eq 0) { return }
        foreach ($fd in $script:FrontDoors) {
            $fd.State | Should -Not -BeNullOrEmpty -Because "State must fall back to provisioningState or 'Unknown'"
        }
    }
}

Describe "Front Door WAF Field" {
    It "WebApplicationFirewall field should always be populated" {
        if ($script:FrontDoors.Count -eq 0) { return }
        foreach ($fd in $script:FrontDoors) {
            # False, 'obfuscated', a WAF policy name, or 'Enabled' are all valid
            $fd.WebApplicationFirewall | Should -Not -BeNullOrEmpty -Because "WAF field should always have a value (False, name, or marker)"
        }
    }

    It "WAF value should not contain raw Azure resource paths in obfuscated mode" {
        if ($script:FrontDoors.Count -eq 0) { return }
        if (-not $script:IsObfuscated) { return }
        foreach ($fd in $script:FrontDoors) {
            if (![string]::IsNullOrEmpty([string]$fd.WebApplicationFirewall) -and $fd.WebApplicationFirewall -ne 'False') {
                [string]$fd.WebApplicationFirewall | Should -Not -Match $script:AzureIdPattern -Because "WAF should not expose Azure resource path in obfuscated mode"
            }
        }
    }
}

Describe "Front Door Non-Sensitive Field Preservation" {
    It "Location should be a real Azure region (not obfuscated)" {
        if ($script:FrontDoors.Count -eq 0) { return }
        foreach ($fd in $script:FrontDoors) {
            $fd.Location | Should -Not -Match '^(prod|nonprod)_' -Because "Location should be a real region like 'global' or 'westeurope'"
        }
    }

    It "Type should not be obfuscated" {
        if ($script:FrontDoors.Count -eq 0) { return }
        foreach ($fd in $script:FrontDoors) {
            $fd.Type | Should -Not -Match '^(prod|nonprod)_' -Because "Tier identifier should be preserved for analysis"
        }
    }

    It "State should not be obfuscated" {
        if ($script:FrontDoors.Count -eq 0) { return }
        foreach ($fd in $script:FrontDoors) {
            $fd.State | Should -Not -Match '^(prod|nonprod)_' -Because "State should be preserved for analysis"
        }
    }

    It "ResourceType should be a valid Azure resource type (not obfuscated)" {
        if ($script:FrontDoors.Count -eq 0) { return }
        $validTypes = @('microsoft.network/frontdoors', 'microsoft.cdn/profiles')
        foreach ($fd in $script:FrontDoors) {
            $fd.ResourceType | Should -BeIn $validTypes -Because "ResourceType should be the raw Azure type, not obfuscated"
        }
    }
}

Describe "Front Door Obfuscation in Obfuscated Mode" {
    It "ID should match obfuscation pattern" {
        if (-not $script:IsObfuscated -or $script:FrontDoors.Count -eq 0) { return }
        foreach ($fd in $script:FrontDoors) {
            $fd.ID | Should -Match $script:ObfuscationPattern -Because "Obfuscated mode: ID must be masked"
        }
    }

    It "Name should match obfuscation pattern" {
        if (-not $script:IsObfuscated -or $script:FrontDoors.Count -eq 0) { return }
        foreach ($fd in $script:FrontDoors) {
            $fd.Name | Should -Match $script:ObfuscationPattern -Because "Obfuscated mode: Name must be masked"
        }
    }

    It "Subscription should match obfuscation pattern" {
        if (-not $script:IsObfuscated -or $script:FrontDoors.Count -eq 0) { return }
        foreach ($fd in $script:FrontDoors) {
            $fd.Subscription | Should -Match $script:ObfuscationPattern -Because "Obfuscated mode: Subscription must be masked"
        }
    }

    It "ResourceGroup should match obfuscation pattern" {
        if (-not $script:IsObfuscated -or $script:FrontDoors.Count -eq 0) { return }
        foreach ($fd in $script:FrontDoors) {
            $fd.ResourceGroup | Should -Match $script:ObfuscationPattern -Because "Obfuscated mode: ResourceGroup must be masked"
        }
    }
}
