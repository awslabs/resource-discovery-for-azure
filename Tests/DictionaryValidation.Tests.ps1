# Dictionary Validation Tests
# Validates the obfuscation dictionary file is correct and complete
# Run with: $env:TEST_DICT_PATH = "./path/to/ObfuscationDictionary_*.json"; Invoke-Pester ./Tests/DictionaryValidation.Tests.ps1 -Output Detailed

BeforeAll {
    $dictPath = if ($env:TEST_DICT_PATH) { $env:TEST_DICT_PATH } else {
        # Look in Tests/ folder first
        $found = Get-ChildItem -Path $PSScriptRoot -Filter "ObfuscationDictionary_*.json" | 
            Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
        if ([string]::IsNullOrEmpty($found)) {
            # Try next to the zip file
            $zipDir = if ($env:TEST_ZIP_PATH) { Split-Path $env:TEST_ZIP_PATH -Parent } else { $PSScriptRoot }
            Get-ChildItem -Path $zipDir -Filter "ObfuscationDictionary_*.json" -ErrorAction SilentlyContinue | 
                Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
        } else { $found }
    }
    if ([string]::IsNullOrEmpty($dictPath) -or -not (Test-Path $dictPath)) {
        throw "No dictionary file found. Copy an ObfuscationDictionary_*.json to Tests/ or next to the zip, or set `$env:TEST_DICT_PATH"
    }
    $script:Dictionary = Get-Content $dictPath -Raw | ConvertFrom-Json

    # Also load inventory if available
    $zipPath = if ($env:TEST_ZIP_PATH) { $env:TEST_ZIP_PATH } else {
        Get-ChildItem -Path $PSScriptRoot -Filter "ResourcesReport_*.zip" | 
            Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
    $script:Inventory = $null
    if (![string]::IsNullOrEmpty($zipPath) -and (Test-Path $zipPath)) {
        $tmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { "/tmp" }
        $script:ExtractPath = Join-Path $tmpBase ("DictTest_" + [guid]::NewGuid().ToString().Substring(0,8))
        New-Item -ItemType Directory -Path $script:ExtractPath -Force | Out-Null
        Expand-Archive -Path $zipPath -DestinationPath $script:ExtractPath -Force
        $invFile = Get-ChildItem -Path $script:ExtractPath -Filter "Inventory_*.json" | Select-Object -First 1
        if ($invFile) { $script:Inventory = Get-Content $invFile.FullName -Raw | ConvertFrom-Json }
    }

    $script:ObfuscationPattern = '^(prod|nonprod)_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    $script:AzureIdPattern = '/subscriptions/[0-9a-f]{8}-[0-9a-f]{4}'
}

AfterAll {
    if ($script:ExtractPath -and (Test-Path $script:ExtractPath)) { Remove-Item -Path $script:ExtractPath -Recurse -Force }
}

Describe "Dictionary Structure" {
    It "Should be valid JSON with all four maps" {
        $script:Dictionary | Should -Not -BeNullOrEmpty
        $script:Dictionary.PSObject.Properties.Name | Should -Contain 'ResourceIdMap'
        $script:Dictionary.PSObject.Properties.Name | Should -Contain 'ResourceNameMap'
        $script:Dictionary.PSObject.Properties.Name | Should -Contain 'SubscriptionMap'
        $script:Dictionary.PSObject.Properties.Name | Should -Contain 'ResourceGroupMap'
    }

    It "Should have a GeneratedAt timestamp" {
        $script:Dictionary.GeneratedAt | Should -Not -BeNullOrEmpty
    }

    It "ResourceIdMap keys should be obfuscated values" {
        $keys = $script:Dictionary.ResourceIdMap.PSObject.Properties.Name
        foreach ($key in $keys) {
            $key | Should -Match $script:ObfuscationPattern -Because "Dictionary key '$key' should be an obfuscated ID"
        }
    }

    It "ResourceIdMap values should be real Azure resource IDs" {
        $values = $script:Dictionary.ResourceIdMap.PSObject.Properties.Value
        foreach ($val in $values) {
            $val | Should -Match $script:AzureIdPattern -Because "Dictionary value should be a real Azure resource ID"
        }
    }
}

Describe "Dictionary Completeness" {
    It "Every obfuscated ID in inventory should have a dictionary entry" {
        if ($null -eq $script:Inventory) { Set-ItResult -Skipped -Because "No inventory zip provided"; return }
        $dictKeys = $script:Dictionary.ResourceIdMap.PSObject.Properties.Name
        $script:Inventory.PSObject.Properties | Where-Object { $null -ne $_.Value -and $_.Name -ne 'Version' } | ForEach-Object {
            @($_.Value) | ForEach-Object {
                if ($null -ne $_.ID) {
                    $_.ID | Should -BeIn $dictKeys -Because "Inventory ID '$($_.ID)' should have a dictionary entry"
                }
            }
        }
    }
}

Describe "No Double Obfuscation" {
    It "No obfuscated value should appear as a dictionary value (real ID)" {
        $values = $script:Dictionary.ResourceIdMap.PSObject.Properties.Value
        foreach ($val in $values) {
            $val | Should -Not -Match $script:ObfuscationPattern -Because "Real ID '$val' should not look like an obfuscated value"
        }
    }
}
