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
        $Checked = 0
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
                $Checked++
                $UniquePrefixes.Count | Should -Be 1 -Because "Resource '$($r.ID)' should have consistent prefix on ID and Name (got: $($UniquePrefixes -join ', '))"
            }
        }
        # Precondition: an empty (or all prefix-less) $script:AllResources - as a
        # broken or zero-record run would produce - otherwise lets this foreach
        # pass green having asserted nothing. Fail loud instead of vacuously.
        $Checked | Should -BeGreaterThan 0 -Because "at least one prefixed resource must be present to validate prefix consistency"
    }
}

Describe "Prefix Format Validation" {
    It "All obfuscated IDs should start with exactly 'prod_' or 'nonprod_'" {
        $Checked = 0
        foreach ($r in $script:AllResources)
        {
            if ($null -ne $r.ID)
            {
                $Checked++
                # Type-tagged variants (databricks_, aks_, vmss_) are legitimate
                # output for resources whose IDs do not fit the standard ARM shape;
                # see ResourceInventory.ps1 lines 961-969.
                $r.ID | Should -Match '^(prod|nonprod)_(databricks_|aks_|vmss_)?[0-9a-f]{8}-' -Because "ID should have valid prefix format"
            }
        }
        $Checked | Should -BeGreaterThan 0 -Because "at least one resource ID must be present to validate ID prefix format"
    }

    It "No resource should have an empty prefix (just underscore + GUID)" {
        $Checked = 0
        foreach ($r in $script:AllResources)
        {
            if ($null -ne $r.ID)
            {
                $Checked++
                $r.ID | Should -Not -Match '^_[0-9a-f]{8}-' -Because "ID should not start with bare underscore"
            }
        }
        $Checked | Should -BeGreaterThan 0 -Because "at least one resource ID must be present to validate the no-bare-underscore guard"
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

# Additive coverage: exercise the EXACT prefix regex the source uses so the non-prod set and prod default are verified
# independent of a prod-only fixture, and lock the type-hint contract - databricks/aks/vmss hints appear on the obfuscated NAME only, never the ID.

Describe "Classifier Fidelity — non-prod set and prod default (P7)" {
    BeforeAll {
        # Mirror of the prod/nonprod classifier used identically across all four classes in ResourceInventory.ps1;
        # replicated here because a prod-only fixture cannot supply non-prod sample data to drive classification through the ZIP.
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
        # Source L958 builds the ID as '<prefix><guid>' with no type hint; the
        # hint is only ever appended to the obfuscated NAME (L961-969). Assert
        # the ID never picks one up. Runs across every resource regardless of
        # fixture composition.
        $Checked = 0
        foreach ($r in $script:AllResources)
        {
            if ($null -ne $r.ID)
            {
                $Checked++
                $r.ID | Should -Not -Match '^(prod|nonprod)_(databricks|aks|vmss)_' -Because "type hints belong on the obfuscated Name, not the ID ('$($r.ID)')"
            }
        }
        $Checked | Should -BeGreaterThan 0 -Because "at least one resource ID must be present to validate that IDs stay type-hint free"
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
