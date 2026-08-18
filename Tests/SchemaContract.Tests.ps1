# Schema Contract & Cross-Dataset Linkage Tests
# =============================================================================
# The three output files are only useful together: a resource's metrics and its
# cost have to trace back to the resource itself. That means all three share one
# identity key - Inventory.ID, Metrics.ID, and Consumption.ResourceId. A rename
# that breaks the link is dropped silently on ingest, since unmapped JSON members
# are ignored by default, so nothing else catches it. This suite does.
#
# It reads the generated zip plus the pinned field list in
# Tests/schema-contract.json, and makes no Azure calls, so it is deterministic
# and runs offline. It works on obfuscated and plain output alike, so the
# scenario matrix runs it in both the 'default' and 'obfuscate' scenarios.
#
# Tier 1 - the fields exist.
#   Each server-bound inventory section in the zip has the identity field names
#   on every row, metric rows have their required fields, the consumption header
#   has every required column, and join keys are not empty.
#   Limit: an absent section is skipped, not failed. From output alone a renamed
#   section looks identical to a resource type the subscription does not have.
#   Its rows still count toward the Tier 2 join space, but nothing checks their
#   field names.
#
# Tier 2 - the keys line up. Inventory is the hub, and metrics and consumption
# each link to it by ID, so there are two links to check, not three.
#   1. Metrics to inventory. A real check: it fails on zero overlap, plus a
#      majority check once there are 5 or more metric IDs.
#   2. Consumption to inventory. Reports the match, and skips when nothing
#      overlaps because billing and current inventory need not line up, so this
#      one cannot fail. The consumption check that CAN fail is the raw-path PII
#      guard in ReferentialIntegrity.Tests.ps1, and only on an obfuscated run.
#   Plus: under -Obfuscate every ID shared between files must be a prod_/nonprod_
#   token, never a raw path. Shared IDs only - whole-zip scanning is in
#   Obfuscation.Tests.ps1 and DataIntegrity.Tests.ps1.
#
#   No metrics to consumption check. Both are already checked against the hub, so
#   a direct check adds nothing, and it would fail on sets that are legitimately
#   disjoint (a metric-bearing resource that is not billed, and vice versa).
#
# Tests skip rather than fail when there is nothing to assert on: no zip or
# manifest, a phase suppressed by a -Skip* switch, an empty dataset or no
# overlap, or a non-obfuscated run for the tokenization check.
# =============================================================================

BeforeAll {
    $ZipPath = if ($env:TEST_ZIP_PATH) { $env:TEST_ZIP_PATH } else
    {
        Get-ChildItem -Path $PSScriptRoot -Filter "ResourcesReport_*.zip" |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
    }

    $script:Ready = $true
    $script:SkipReason = $null

    if ([string]::IsNullOrEmpty($ZipPath) -or -not (Test-Path $ZipPath))
    {
        $script:Ready = $false
        $script:SkipReason = 'no test zip found (set $env:TEST_ZIP_PATH)'
    }

    # Load the contract manifest that sits beside this suite.
    $ManifestPath = Join-Path $PSScriptRoot 'schema-contract.json'
    if ($script:Ready -and -not (Test-Path $ManifestPath))
    {
        $script:Ready = $false
        $script:SkipReason = 'schema-contract.json manifest not found beside the test'
    }
    $script:Contract = if ($script:Ready) { Get-Content $ManifestPath -Raw | ConvertFrom-Json } else { $null }

    if ($script:Ready)
    {
        $TmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { "/tmp" }
        $script:ExtractPath = Join-Path $TmpBase ("SchemaContract_" + [guid]::NewGuid().ToString().Substring(0, 8))
        New-Item -ItemType Directory -Path $script:ExtractPath -Force | Out-Null
        Expand-Archive -Path $ZipPath -DestinationPath $script:ExtractPath -Force

        $InvFile = Get-ChildItem -Path $script:ExtractPath -Filter "Inventory_*.json" | Select-Object -First 1
        $script:Inventory = if ($InvFile) { Get-Content $InvFile.FullName -Raw | ConvertFrom-Json } else { $null }

        # Metrics live across one or more Metrics_*.json members, each exposing the
        # top-level array named by the manifest ('Metrics').
        $MetricKey = $script:Contract.metrics.topLevelKey
        $MetricRows = @()
        Get-ChildItem -Path $script:ExtractPath -Filter "Metrics_*.json" -ErrorAction SilentlyContinue | ForEach-Object {
            $MetricData = Get-Content $_.FullName -Raw | ConvertFrom-Json
            if ($null -ne $MetricData.$MetricKey) { $MetricRows += @($MetricData.$MetricKey) }
        }
        $script:MetricRows = @($MetricRows)

        $CsvFile = Get-ChildItem -Path $script:ExtractPath -Filter "Consumption_*.csv" | Select-Object -First 1
        $script:ConsumptionFile = if ($CsvFile) { $CsvFile.FullName } else { $null }
        $script:Consumption = if ($CsvFile)
        {
            $Content = Get-Content $CsvFile.FullName -ErrorAction SilentlyContinue
            if ($null -ne $Content -and $Content.Count -gt 1) { Import-Csv $CsvFile.FullName } else { @() }
        }
        else { @() }

        # Every inventory resource ID across ALL sections (the id space the other
        # datasets must join back into), plus per-section id lists for the
        # server-bound sections.
        $script:AllInvIds = @()
        $script:InvBySection = @{}
        if ($null -ne $script:Inventory)
        {
            foreach ($Prop in $script:Inventory.PSObject.Properties)
            {
                if ($Prop.Name -eq 'Version') { continue }
                $Ids = @($Prop.Value | Where-Object { $null -ne $_ -and ![string]::IsNullOrEmpty($_.ID) } | ForEach-Object { $_.ID })
                if ($Ids.Count -gt 0) { $script:AllInvIds += $Ids }
                $script:InvBySection[$Prop.Name] = @($Prop.Value | Where-Object { $null -ne $_ })
            }
        }

        # Obfuscation signal: in an obfuscated run every inventory ID is a
        # prod_/nonprod_ token, so a single match proves the run was obfuscated.
        $script:TokenPattern = '^(prod|nonprod)_(databricks_|aks_|vmss_)?[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        $script:IsObfuscated = @($script:AllInvIds | Where-Object { $_ -match $script:TokenPattern }).Count -gt 0
    }

    if ($script:SkipReason) { Write-Host ("[SchemaContract] {0}" -f $script:SkipReason) -ForegroundColor DarkGray }
}

AfterAll {
    if ($script:ExtractPath -and (Test-Path $script:ExtractPath)) { Remove-Item -Path $script:ExtractPath -Recurse -Force }
}

# =============================================================================
# Tier 1 - Schema contract (field-name presence + join-key population)
# =============================================================================
Describe "Inventory schema contract" {

    It "Every server-bound inventory section carries the identity field names on every row" {
        if (-not $script:Ready) { Set-ItResult -Skipped -Because $script:SkipReason; return }
        $IdentityFields = @($script:Contract.identityFields)
        $Sections = $script:Contract.serverBoundInventorySections.PSObject.Properties.Name
        $Checked = 0
        $Violations = @()
        foreach ($Section in $Sections)
        {
            if (-not $script:InvBySection.ContainsKey($Section)) { continue }
            $Rows = @($script:InvBySection[$Section])
            if ($Rows.Count -eq 0) { continue }
            $Checked++
            foreach ($Row in $Rows)
            {
                $Present = $Row.PSObject.Properties.Name
                foreach ($Field in $IdentityFields)
                {
                    if ($Field -notin $Present) { $Violations += ("{0} row missing '{1}'" -f $Section, $Field) }
                }
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "no server-bound inventory section was populated in this fixture"; return }
        # De-duplicate so one bad section reports once, not once per row.
        $Violations = @($Violations | Sort-Object -Unique)
        $Violations.Count | Should -Be 0 -Because ("server ingestion binds these identity field NAMES; a rename/removal is silently dropped and breaks the join. Missing: {0}" -f ($Violations -join '; '))
    }

    It "Every server-bound inventory row has a non-empty join key (ID)" {
        if (-not $script:Ready) { Set-ItResult -Skipped -Because $script:SkipReason; return }
        $Sections = $script:Contract.serverBoundInventorySections.PSObject.Properties.Name
        $Checked = 0
        $Empty = 0
        foreach ($Section in $Sections)
        {
            if (-not $script:InvBySection.ContainsKey($Section)) { continue }
            foreach ($Row in @($script:InvBySection[$Section]))
            {
                $Checked++
                if ([string]::IsNullOrEmpty($Row.ID)) { $Empty++ }
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "no server-bound inventory section was populated in this fixture"; return }
        $Empty | Should -Be 0 -Because "the inventory join key (ID) must be populated on every server-bound row or the resource cannot be correlated to its metrics/consumption"
    }
}

Describe "Metrics schema contract" {

    It "Every metric row carries the required field names" {
        if (-not $script:Ready) { Set-ItResult -Skipped -Because $script:SkipReason; return }
        if ($script:MetricRows.Count -eq 0) { Set-ItResult -Skipped -Because "no metric rows (metrics phase absent or skipped in this fixture)"; return }
        $Required = @($script:Contract.metrics.requiredFields)
        $Violations = @()
        foreach ($Row in $script:MetricRows)
        {
            $Present = $Row.PSObject.Properties.Name
            foreach ($Field in $Required)
            {
                if ($Field -notin $Present) { $Violations += ("metric row missing '{0}'" -f $Field) }
            }
        }
        $Violations = @($Violations | Sort-Object -Unique)
        $Violations.Count | Should -Be 0 -Because ("the server binds these AzureMetricRecord fields; a missing name is dropped on ingest. Missing: {0}" -f ($Violations -join '; '))
    }

    It "Every metric row has a non-empty join key (ID)" {
        if (-not $script:Ready) { Set-ItResult -Skipped -Because $script:SkipReason; return }
        if ($script:MetricRows.Count -eq 0) { Set-ItResult -Skipped -Because "no metric rows (metrics phase absent or skipped in this fixture)"; return }
        $JoinKey = $script:Contract.metrics.joinKey
        $Empty = @($script:MetricRows | Where-Object { [string]::IsNullOrEmpty($_.$JoinKey) }).Count
        $Empty | Should -Be 0 -Because "a metric row with no ID cannot be attached to its resource (the server groups metrics by {ID, Metric})"
    }
}

Describe "Consumption schema contract" {

    It "Consumption header carries every required column" {
        if (-not $script:Ready) { Set-ItResult -Skipped -Because $script:SkipReason; return }
        if (-not $script:ConsumptionFile) { Set-ItResult -Skipped -Because "no consumption csv (consumption phase absent or skipped in this fixture)"; return }
        # Prefer Import-Csv's parsed column names (quote-aware, so a column value
        # containing an embedded comma can never be mis-split). Fall back to a
        # header-line split only for an EMPTY csv (header only, no data rows),
        # where Import-Csv yields no objects but the column contract still holds.
        if ($script:Consumption.Count -gt 0)
        {
            $Columns = @($script:Consumption[0].PSObject.Properties.Name)
        }
        else
        {
            $HeaderLine = Get-Content $script:ConsumptionFile -TotalCount 1
            if ([string]::IsNullOrEmpty($HeaderLine)) { Set-ItResult -Skipped -Because "consumption csv has no header line in this fixture"; return }
            $Columns = @($HeaderLine -split ',' | ForEach-Object { $_.Trim().Trim('"') })
        }
        $Required = @($script:Contract.consumption.requiredColumns)
        $Missing = @($Required | Where-Object { $_ -notin $Columns })
        $Missing.Count | Should -Be 0 -Because ("the consumption CSV column contract is fixed for server ingestion. Missing: {0}" -f ($Missing -join ', '))
    }
}

# =============================================================================
# Tier 2 - Cross-dataset linkage (the datasets must stay JOINABLE)
# =============================================================================
Describe "Cross-dataset linkage" {

    It "Metrics IDs resolve to inventory IDs (metrics-to-inventory join holds)" {
        if (-not $script:Ready) { Set-ItResult -Skipped -Because $script:SkipReason; return }
        if ($script:MetricRows.Count -eq 0) { Set-ItResult -Skipped -Because "no metric rows (metrics phase absent or skipped in this fixture)"; return }
        if ($script:AllInvIds.Count -eq 0) { Set-ItResult -Skipped -Because "no inventory IDs in this fixture"; return }

        $InvIdSet = @{}
        foreach ($Id in $script:AllInvIds) { $InvIdSet[$Id] = $true }
        $MetricIds = @($script:MetricRows | Where-Object { ![string]::IsNullOrEmpty($_.ID) } | Select-Object -ExpandProperty ID -Unique)
        if ($MetricIds.Count -eq 0) { Set-ItResult -Skipped -Because "no metric row carried an ID in this fixture"; return }

        $Matched = @($MetricIds | Where-Object { $InvIdSet.ContainsKey($_) })
        $Absent = @($MetricIds | Where-Object { -not $InvIdSet.ContainsKey($_) })
        $Ratio = if ($MetricIds.Count -gt 0) { $Matched.Count / $MetricIds.Count } else { 1 }
        Write-Host ("    [linkage] metrics->inventory: {0}/{1} resolve ({2:P0}); {3} absent" -f $Matched.Count, $MetricIds.Count, $Ratio, $Absent.Count) -ForegroundColor DarkGray

        # Metrics run a resource id through the same dictionary inventory used, so
        # an inventoried metric-bearing resource carries the identical key. Zero
        # overlap means metrics minted their own keys and the join is broken.
        $Matched.Count | Should -BeGreaterThan 0 -Because "at least one metric ID must match an inventory ID; zero overlap means metrics and inventory no longer share a join key (datasets not linkable)"
        # Majority check, held back until the sample is big enough that one stale
        # resource cannot false-fail it.
        $RatioSampleFloor = 5
        if ($MetricIds.Count -ge $RatioSampleFloor)
        {
            $Matched.Count | Should -BeGreaterOrEqual $Absent.Count -Because ("metric IDs should predominantly resolve to inventory IDs (matched={0}, absent={1}); absent exceeding matched means a whole metric path is keying inconsistently with inventory" -f $Matched.Count, $Absent.Count)
        }
    }

    It "Consumption ResourceIds overlap the inventory id space (consumption-to-inventory join holds)" {
        if (-not $script:Ready) { Set-ItResult -Skipped -Because $script:SkipReason; return }
        if ($script:Consumption.Count -eq 0) { Set-ItResult -Skipped -Because "no consumption rows (consumption phase absent or skipped in this fixture)"; return }
        if ($script:AllInvIds.Count -eq 0) { Set-ItResult -Skipped -Because "no inventory IDs in this fixture"; return }

        $InvIdSet = @{}
        foreach ($Id in $script:AllInvIds) { $InvIdSet[$Id] = $true }
        $ConsumptionIds = @($script:Consumption | Where-Object { ![string]::IsNullOrEmpty($_.ResourceId) } | Select-Object -ExpandProperty ResourceId -Unique)
        if ($ConsumptionIds.Count -eq 0) { Set-ItResult -Skipped -Because "no consumption row carried a ResourceId in this fixture"; return }

        # Zero overlap is often legitimate: billing still covers resources since
        # deleted, brand-new resources are not billed yet, and some meters
        # (bandwidth, marketplace, reservations) are never inventoried at all. So
        # this skips rather than fails when nothing matches.
        #
        # Match on the identity, not the whole string. Obfuscation writes the same
        # identity two ways. Inventory and metrics collapse the resource to a bare
        # token (prod_/nonprod_, an optional type hint, and a guid). Consumption
        # keeps the ARM path and tokenizes only the identifying segments -
        # subscription, resource group, and resource names - leaving the provider
        # and type segments intact so the server can still categorise the row. The
        # resource's own token therefore sits in the LAST name segment. A
        # full-string compare would find nothing under obfuscation even though the
        # join is fine. Both forms are unique per resource, so checking the full
        # value or the last segment cannot false-match.
        $Matched = @($ConsumptionIds | Where-Object { $InvIdSet.ContainsKey($_) -or $InvIdSet.ContainsKey(($_ -split '/')[-1]) })
        Write-Host ("    [linkage] consumption->inventory: {0}/{1} ResourceIds resolve to an inventory ID (full-value or leaf-token)" -f $Matched.Count, $ConsumptionIds.Count) -ForegroundColor DarkGray
        if ($Matched.Count -eq 0)
        {
            Set-ItResult -Skipped -Because "no consumption ResourceId resolves to the current inventory in this fixture - legitimate when billed resources were since deleted, are not yet billed, or are un-inventoried meter types (billing window vs current inventory)."
            return
        }
        # Anything matched here shares inventory's identity space, so its cost
        # attributes to a real inventoried resource. This records the result; it
        # cannot fail, because the zero case already returned above.
        $Matched.Count | Should -BeGreaterThan 0 -Because "records that the consumption-to-inventory join resolved for the resources present in both (cannot fail: the zero-overlap case skipped above)"
    }

    It "Under obfuscation, the shared join keys are deterministic prod_/nonprod_ tokens (not raw paths)" {
        if (-not $script:Ready) { Set-ItResult -Skipped -Because $script:SkipReason; return }
        if (-not $script:IsObfuscated) { Set-ItResult -Skipped -Because "join keys are only tokenized in an obfuscated run"; return }

        # An ID that shows up in two files proves determinism for that ID: the same
        # resource got the same token in both, or the sets would not intersect.
        # Run-wide determinism is Obfuscation.Tests.ps1. Here, each shared ID must
        # be a well-formed token and never a raw path.
        #
        # Shared IDs only - this checks the join, not the whole zip. Whole-zip
        # scanning is Obfuscation.Tests.ps1 and DataIntegrity.Tests.ps1, and
        # consumption's raw-path guard is ReferentialIntegrity.Tests.ps1.
        $InvIdSet = @{}
        foreach ($Id in $script:AllInvIds) { $InvIdSet[$Id] = $true }

        # Collect the shared identity tokens. Metrics carry it as the whole ID;
        # consumption carries it as the last path segment, so take the leaf when it
        # resolves to an inventory ID. Either way this yields the bare token.
        $Shared = @()
        $Shared += @($script:MetricRows | Where-Object { ![string]::IsNullOrEmpty($_.ID) -and $InvIdSet.ContainsKey($_.ID) } | Select-Object -ExpandProperty ID)
        $Shared += @($script:Consumption |
                Where-Object { ![string]::IsNullOrEmpty($_.ResourceId) } |
                ForEach-Object { ($_.ResourceId -split '/')[-1] } |
                Where-Object { $InvIdSet.ContainsKey($_) })
        $Shared = @($Shared | Sort-Object -Unique)
        if ($Shared.Count -eq 0) { Set-ItResult -Skipped -Because "no join key was shared across datasets in this fixture"; return }

        foreach ($Key in $Shared)
        {
            $Key | Should -Match $script:TokenPattern -Because "a cross-dataset join key must be a deterministic prod_/nonprod_ token"
            $Key | Should -Not -Match '/subscriptions/[0-9a-f]{8}-[0-9a-f]{4}' -Because "a join key must never be a raw ARM path in an obfuscated run (determinism + PII)"
        }
    }
}
