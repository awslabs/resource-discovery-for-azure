# Prod/Nonprod Prefix Tests
# Validates that the prod_/nonprod_ prefix logic is consistent
# Run with: Invoke-Pester ./Tests/ProdNonprodPrefix.Tests.ps1 -Output Detailed

BeforeAll {
    $zipPath = if ($env:TEST_ZIP_PATH) { $env:TEST_ZIP_PATH } else {
        Get-ChildItem -Path $PSScriptRoot -Filter "ResourcesReport_*.zip" | 
            Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
    if ([string]::IsNullOrEmpty($zipPath) -or -not (Test-Path $zipPath)) {
        throw "No test zip found."
    }
    $tmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { "/tmp" }
    $script:ExtractPath = Join-Path $tmpBase ("PrefixTest_" + [guid]::NewGuid().ToString().Substring(0,8))
    New-Item -ItemType Directory -Path $script:ExtractPath -Force | Out-Null
    Expand-Archive -Path $zipPath -DestinationPath $script:ExtractPath -Force

    $invFile = Get-ChildItem -Path $script:ExtractPath -Filter "Inventory_*.json" | Select-Object -First 1
    $script:Inventory = Get-Content $invFile.FullName -Raw | ConvertFrom-Json

    $script:AllResources = @()
    $script:Inventory.PSObject.Properties | Where-Object { $null -ne $_.Value -and $_.Name -ne 'Version' } | ForEach-Object {
        @($_.Value) | ForEach-Object { if ($null -ne $_) { $script:AllResources += $_ } }
    }
}

AfterAll {
    if (Test-Path $script:ExtractPath) { Remove-Item -Path $script:ExtractPath -Recurse -Force }
}

Describe "Prefix Consistency Per Resource" {
    It "ID and Name should have the same prefix for each resource" {
        foreach ($r in $script:AllResources) {
            # Only check ID and Name — Subscription/ResourceGroup are shared across
            # resources and their prefix is derived from the subscription/RG name
            # itself, so they may differ from the resource's own prefix in mixed environments.
            $fields = @($r.ID, $r.Name) | Where-Object { ![string]::IsNullOrEmpty($_) }
            $prefixes = $fields | ForEach-Object { if ($_ -match '^(prod|nonprod)_') { $Matches[1] } }
            $uniquePrefixes = $prefixes | Select-Object -Unique
            if ($uniquePrefixes.Count -gt 0) {
                $uniquePrefixes.Count | Should -Be 1 -Because "Resource '$($r.ID)' should have consistent prefix on ID and Name (got: $($uniquePrefixes -join ', '))"
            }
        }
    }
}

Describe "Prefix Format Validation" {
    It "All obfuscated IDs should start with exactly 'prod_' or 'nonprod_'" {
        foreach ($r in $script:AllResources) {
            if ($null -ne $r.ID) {
                $r.ID | Should -Match '^(prod|nonprod)_[0-9a-f]{8}-' -Because "ID should have valid prefix format"
            }
        }
    }

    It "No resource should have an empty prefix (just underscore + GUID)" {
        foreach ($r in $script:AllResources) {
            if ($null -ne $r.ID) {
                $r.ID | Should -Not -Match '^_[0-9a-f]{8}-' -Because "ID should not start with bare underscore"
            }
        }
    }
}

Describe "Consumption Prefix Consistency" {
    It "Consumption ResourceIds should have prod_ or nonprod_ prefix" {
        $csvFile = Get-ChildItem -Path $script:ExtractPath -Filter "Consumption_*.csv" | Select-Object -First 1
        if ($null -eq $csvFile) { return }
        $content = Get-Content $csvFile.FullName -ErrorAction SilentlyContinue
        if ($null -eq $content -or $content.Count -le 1) { return }
        $csv = Import-Csv $csvFile.FullName
        foreach ($row in $csv) {
            if (![string]::IsNullOrEmpty($row.ResourceId)) {
                $row.ResourceId | Should -Match '^(prod|nonprod)_' -Because "Consumption ResourceId should have prefix"
            }
        }
    }
}
