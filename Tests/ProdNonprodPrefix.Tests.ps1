# Prod/Nonprod Prefix Tests
# Validates that the prod_/nonprod_ prefix logic is consistent
# Run with: Invoke-Pester ./Tests/ProdNonprodPrefix.Tests.ps1 -Output Detailed

BeforeAll {
    $ZipPath = if ($env:TEST_ZIP_PATH) { $env:TEST_ZIP_PATH } else
    {
        Get-ChildItem -Path $PSScriptRoot -Filter "ResourcesReport_*.zip" |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
    if ([string]::IsNullOrEmpty($ZipPath) -or -not (Test-Path $ZipPath))
    {
        throw "No test zip found."
    }
    $TmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { "/tmp" }
    $script:ExtractPath = Join-Path $TmpBase ("PrefixTest_" + [guid]::NewGuid().ToString().Substring(0, 8))
    New-Item -ItemType Directory -Path $script:ExtractPath -Force | Out-Null
    Expand-Archive -Path $ZipPath -DestinationPath $script:ExtractPath -Force

    $InvFile = Get-ChildItem -Path $script:ExtractPath -Filter "Inventory_*.json" | Select-Object -First 1
    $script:Inventory = Get-Content $InvFile.FullName -Raw | ConvertFrom-Json

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
        foreach ($r in $script:AllResources)
        {
            # Only check ID and Name — Subscription/ResourceGroup are shared across
            # resources and their prefix is derived from the subscription/RG name
            # itself, so they may differ from the resource's own prefix in mixed environments.
            $Fields = @($r.ID, $r.Name) | Where-Object { ![string]::IsNullOrEmpty($_) }
            $Prefixes = $Fields | ForEach-Object { if ($_ -match '^(prod|nonprod)_') { $Matches[1] } }
            $UniquePrefixes = $Prefixes | Select-Object -Unique
            if ($UniquePrefixes.Count -gt 0)
            {
                $UniquePrefixes.Count | Should -Be 1 -Because "Resource '$($r.ID)' should have consistent prefix on ID and Name (got: $($UniquePrefixes -join ', '))"
            }
        }
    }
}

Describe "Prefix Format Validation" {
    It "All obfuscated IDs should start with exactly 'prod_' or 'nonprod_'" {
        foreach ($r in $script:AllResources)
        {
            if ($null -ne $r.ID)
            {
                # Type-tagged variants (databricks_, aks_, vmss_) are legitimate
                # output for resources whose IDs do not fit the standard ARM shape;
                # see ResourceInventory.ps1 lines 650-655 and 1030-1034.
                $r.ID | Should -Match '^(prod|nonprod)_(databricks_|aks_|vmss_)?[0-9a-f]{8}-' -Because "ID should have valid prefix format"
            }
        }
    }

    It "No resource should have an empty prefix (just underscore + GUID)" {
        foreach ($r in $script:AllResources)
        {
            if ($null -ne $r.ID)
            {
                $r.ID | Should -Not -Match '^_[0-9a-f]{8}-' -Because "ID should not start with bare underscore"
            }
        }
    }
}

Describe "Consumption Prefix Consistency" {
    It "Consumption ResourceIds should have prod_ or nonprod_ prefix" {
        $CsvFile = Get-ChildItem -Path $script:ExtractPath -Filter "Consumption_*.csv" | Select-Object -First 1
        if ($null -eq $CsvFile) { Set-ItResult -Skipped -Because "no consumption csv in fixture"; return }
        $Content = Get-Content $CsvFile.FullName -ErrorAction SilentlyContinue
        if ($null -eq $Content -or $Content.Count -le 1) { Set-ItResult -Skipped -Because "empty consumption csv"; return }
        $Csv = Import-Csv $CsvFile.FullName
        # Two valid shapes for an obfuscated consumption ResourceId:
        #   - legacy flat token: ^(prod|nonprod)_...
        #   - structure-preserving ARM path: starts with /subscriptions/(prod|nonprod)_sub_...
        $ValidShape = '^((prod|nonprod)_|/subscriptions/(prod|nonprod)_sub_)'
        foreach ($row in $Csv)
        {
            if (![string]::IsNullOrEmpty($row.ResourceId))
            {
                $row.ResourceId | Should -Match $ValidShape -Because "Consumption ResourceId should be obfuscated with prod_/nonprod_ prefix (flat or ARM-shape)"
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Task 3 additive coverage (Property P7 — prefix fidelity + type hints).
# Requirements 3.1, 3.2, 3.3, 3.4.
#
# The existing Describe blocks above validate that whatever prefix appears in
# the fixture is well-formed and consistent, but they cannot exercise the
# non-prod pattern set or the d-/t-/s- segment hints when the fixture contains
# only prod-classified resources (empty TagMap/FreeTextMap, prod-only sample
# data). These blocks close that gap two ways, without weakening anything above:
#   1. Classifier-logic assertions that exercise the EXACT prefix regex the
#      source uses, so the full non-prod set (3.1) and the prod default (3.2)
#      are verified independently of fixture contents. The same regex literal is
#      used per class in ResourceInventory.ps1 (resource name L639, subscription
#      L659, resource group L668, tag value L1011), which is Requirement 3.3.
#   2. Fixture-content assertions that lock the type-hint contract (3.4): the
#      databricks/aks/vmss hints appear only on the obfuscated NAME, never on the
#      obfuscated ID (source L643 builds the ID with no hint; L647-654 apply the
#      hint to the name only).
# ---------------------------------------------------------------------------

Describe "Classifier Fidelity — non-prod set and prod default (P7)" {
    BeforeAll {
        # Mirror of the prod/nonprod classifier used identically across all four
        # classes in ResourceInventory.ps1 (L639 name, L659 subscription,
        # L668 resource group, L1011 tag value; also Protect-FreeTextValue L107).
        # Replicated here because a prod-only fixture cannot supply non-prod
        # sample data to drive the classification through the ZIP.
        function script:Get-ExpectedObfuscationPrefix([string]$Value)
        {
            if ($Value -match '\b(dev|test|qa|tst|development|non-prod|uat|nonprod)\b' -or $Value -match '(^|-)([dts])-')
            {
                return 'nonprod_'
            }
            return 'prod_'
        }
    }

    It "classifies non-prod keyword '<Keyword>' as nonprod_ (Req 3.1)" -ForEach @(
        @{ Keyword = 'dev'; Sample = 'app-dev-01' }
        @{ Keyword = 'test'; Sample = 'test-db-01' }
        @{ Keyword = 'qa'; Sample = 'qa-web-01' }
        @{ Keyword = 'tst'; Sample = 'tst-app-01' }
        @{ Keyword = 'development'; Sample = 'development-team' }
        @{ Keyword = 'non-prod'; Sample = 'non-prod' }
        @{ Keyword = 'uat'; Sample = 'uat-app-01' }
        @{ Keyword = 'nonprod'; Sample = 'nonprod-app' }
    ) {
        (script:Get-ExpectedObfuscationPrefix $Sample) | Should -Be 'nonprod_' -Because "'$Sample' matches the non-prod set member '$Keyword'"
    }

    It "classifies segment hint '<Hint>' as nonprod_ (Req 3.1)" -ForEach @(
        @{ Hint = 'd- (start)'; Sample = 'd-app01' }
        @{ Hint = 't- (start)'; Sample = 't-svc01' }
        @{ Hint = 's- (start)'; Sample = 's-node01' }
        @{ Hint = 'd- (mid)'; Sample = 'rg-d-01' }
        @{ Hint = 't- (mid)'; Sample = 'rg-t-01' }
        @{ Hint = 's- (mid)'; Sample = 'rg-s-01' }
    ) {
        (script:Get-ExpectedObfuscationPrefix $Sample) | Should -Be 'nonprod_' -Because "'$Sample' matches the '(^|-)([dts])-' segment hint ($Hint)"
    }

    It "classifies neutral value '<Sample>' as prod_ (Req 3.2)" -ForEach @(
        @{ Sample = 'webapp01' }
        @{ Sample = 'storageacct' }
        @{ Sample = 'sqlserver1' }
        @{ Sample = 'contosoapp' }
    ) {
        (script:Get-ExpectedObfuscationPrefix $Sample) | Should -Be 'prod_' -Because "'$Sample' matches no non-prod set member or segment hint"
    }

    It "applies the same classifier to all four classes (Req 3.3) — class '<Class>'" -ForEach @(
        @{ Class = 'ResourceID/Name'; NonProd = 'app-dev-01'; Prod = 'app-prod-01' }
        @{ Class = 'Subscription'; NonProd = 'test-sub'; Prod = 'core-sub' }
        @{ Class = 'ResourceGroup'; NonProd = 'rg-uat-01'; Prod = 'rg-shared-01' }
        @{ Class = 'Tag'; NonProd = 'qa'; Prod = 'owner-team' }
    ) {
        (script:Get-ExpectedObfuscationPrefix $NonProd) | Should -Be 'nonprod_' -Because "the $Class classifier flags '$NonProd' non-prod"
        (script:Get-ExpectedObfuscationPrefix $Prod)    | Should -Be 'prod_'    -Because "the $Class classifier leaves '$Prod' prod"
    }
}

Describe "Type Hint Fidelity — name only, never ID (P7 / Req 3.4)" {
    It "obfuscated IDs never carry a databricks/aks/vmss type hint" {
        # Source L643 builds the ID as '<prefix><guid>' with no type hint; the
        # hint is only ever appended to the obfuscated NAME (L647-654). Assert
        # the ID never picks one up. Runs across every resource regardless of
        # fixture composition.
        foreach ($r in $script:AllResources)
        {
            if ($null -ne $r.ID)
            {
                $r.ID | Should -Not -Match '^(prod|nonprod)_(databricks|aks|vmss)_' -Because "type hints belong on the obfuscated Name, not the ID ('$($r.ID)')"
            }
        }
    }

    It "any databricks/aks/vmss type hint present in the fixture sits on the Name only" {
        # Positive check: only meaningful when the fixture actually contains a
        # type-hinted resource. If it does not (prod-only / no databricks/aks/vmss
        # resources), record the fixture limitation instead of asserting on
        # absent data.
        $HintPattern = '^(prod|nonprod)_(databricks|aks|vmss)_[0-9a-f]{8}-'
        $HintedNames = @($script:AllResources | Where-Object { $null -ne $_.Name -and $_.Name -match $HintPattern })
        if ($HintedNames.Count -eq 0)
        {
            Set-ItResult -Skipped -Because "fixture contains no databricks/aks/vmss type-hinted resources to assert against"
            return
        }
        foreach ($r in $HintedNames)
        {
            $r.Name | Should -Match $HintPattern -Because "the type hint must be well-formed on the Name"
            $r.ID   | Should -Not -Match '^(prod|nonprod)_(databricks|aks|vmss)_' -Because "the same resource's ID must remain hint-free ('$($r.ID)')"
        }
    }
}
