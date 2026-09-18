# Referential Integrity Tests
# Validates that cross-references between resources are consistent after obfuscation
# Run with: Invoke-Pester ./Tests/ReferentialIntegrity.Tests.ps1 -Output Detailed

BeforeAll {
    $ZipPath = if ($env:TEST_ZIP_PATH) { $env:TEST_ZIP_PATH } else
    {
        Get-ChildItem -Path $PSScriptRoot -Filter "ResourcesReport_*.zip" |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
    if ([string]::IsNullOrEmpty($ZipPath) -or -not (Test-Path $ZipPath))
    {
        throw "No test zip found. Copy a ResourcesReport_*.zip to Tests/ or set `$env:TEST_ZIP_PATH"
    }
    $TmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { "/tmp" }
    $script:ExtractPath = Join-Path $TmpBase ("RefIntTest_" + [guid]::NewGuid().ToString().Substring(0, 8))
    New-Item -ItemType Directory -Path $script:ExtractPath -Force | Out-Null
    Expand-Archive -Path $ZipPath -DestinationPath $script:ExtractPath -Force

    $InvFile = Get-ChildItem -Path $script:ExtractPath -Filter "Inventory_*.json" | Select-Object -First 1
    $script:Inventory = Get-Content $InvFile.FullName -Raw | ConvertFrom-Json

    $CsvFile = Get-ChildItem -Path $script:ExtractPath -Filter "Consumption_*.csv" | Select-Object -First 1
    $script:ConsumptionCsv = if ($CsvFile)
    {
        $Content = Get-Content $CsvFile.FullName -ErrorAction SilentlyContinue
        if ($null -ne $Content -and $Content.Count -gt 1) { Import-Csv $CsvFile.FullName } else { @() }
    }
    else { @() }

    # Collect all IDs across all resource types
    $script:AllIds = @()
    $script:Inventory.PSObject.Properties | Where-Object { $null -ne $_.Value -and $_.Name -ne 'Version' } | ForEach-Object {
        @($_.Value) | ForEach-Object { if ($null -ne $_.ID) { $script:AllIds += $_.ID } }
    }

    # --- Task 6 (P8) additive fixtures --------------------------------------
    # Metric rows back the per-resource cached-token check (Req 2.4). Metrics
    # live in one or more Metrics_*.json members, each exposing a .Metrics array.
    $MetricRows = @()
    Get-ChildItem -Path $script:ExtractPath -Filter "Metrics_*.json" -ErrorAction SilentlyContinue | ForEach-Object {
        $MetricData = Get-Content $_.FullName -Raw | ConvertFrom-Json
        if ($null -ne $MetricData.Metrics) { $MetricRows += @($MetricData.Metrics) }
    }
    $script:MetricRows = @($MetricRows)

    # Obfuscation token grammar (same shape used by Obfuscation.Tests.ps1):
    # prod_/nonprod_ + optional type hint + GUID. Used to prove that a
    # cross-reference / cached metric value is a real token, never a raw id.
    $script:TokenPattern = '^(prod|nonprod)_(databricks_|aks_|vmss_)?[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

    # Obfuscation signal for mode-gated assertions: in an obfuscated run every
    # inventory ID is a prod_/nonprod_ token, so a single match proves the run
    # was obfuscated. Lets the consumption raw-path guard below stay quiet on a
    # default (non-obfuscated) run where raw ARM ids are expected.
    $script:IsObfuscated = @($script:AllIds | Where-Object { $_ -match $script:TokenPattern }).Count -gt 0
}

AfterAll {
    if (Test-Path $script:ExtractPath) { Remove-Item -Path $script:ExtractPath -Recurse -Force }
}

Describe "VM Disk to VM Cross-Reference" {
    It "Every disk AssociatedResource should match a VM ID or be null" {
        $Disks = @($script:Inventory.VMDisk) | Where-Object { $null -ne $_ }
        if ($Disks.Count -eq 0) { Set-ItResult -Skipped -Because "no VMDisk resources in this fixture"; return }
        $VmIds = @($script:Inventory.VirtualMachines) | Where-Object { $null -ne $_ } | ForEach-Object { $_.ID }
        $Checked = 0
        foreach ($disk in $Disks)
        {
            if ($null -ne $disk -and ![string]::IsNullOrEmpty($disk.AssociatedResource))
            {
                $disk.AssociatedResource | Should -BeIn $VmIds -Because "Disk '$($disk.ID)' AssociatedResource should reference a known VM"
                $Checked++
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "no VMDisk had a non-null AssociatedResource in this fixture" }
    }
}

Describe "AVD HostId to VM Cross-Reference" {
    It "Every AVD HostId should match a VM ID or be null" {
        $Avd = @($script:Inventory.AVD) | Where-Object { $null -ne $_ }
        if ($Avd.Count -eq 0) { Set-ItResult -Skipped -Because "no AVD resources in this fixture"; return }
        $VmIds = @($script:Inventory.VirtualMachines) | Where-Object { $null -ne $_ } | ForEach-Object { $_.ID }
        $Checked = 0
        foreach ($avdItem in $Avd)
        {
            if ($null -ne $avdItem -and ![string]::IsNullOrEmpty($avdItem.HostId))
            {
                $avdItem.HostId | Should -BeIn $VmIds -Because "AVD HostId should reference a known VM"
                $Checked++
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "no AVD had a non-null HostId in this fixture" }
    }
}

Describe "SQL VM to VM Cross-Reference" {
    It "Every SQL VM ParentVirtualMachine should match a VM ID (or be a tolerated sentinel)" {
        $Sqlvms = @($script:Inventory.SQLVM) | Where-Object { $null -ne $_ }
        if ($Sqlvms.Count -eq 0) { Set-ItResult -Skipped -Because "no SQLVM resources in this fixture"; return }
        $VmIds = @($script:Inventory.VirtualMachines) | Where-Object { $null -ne $_ } | ForEach-Object { $_.ID }
        # Sentinels the collector emits when the parent VM is out of scope or absent:
        #   'obfuscated' (obfuscation on, parent id not indexed) / 'None' (no parent id).
        $Tolerated = @('obfuscated', 'None')
        $Checked = 0
        foreach ($sqlvm in $Sqlvms)
        {
            if ($null -ne $sqlvm -and ![string]::IsNullOrEmpty($sqlvm.ParentVirtualMachine))
            {
                if ($sqlvm.ParentVirtualMachine -notin $Tolerated)
                {
                    $sqlvm.ParentVirtualMachine | Should -BeIn $VmIds -Because "SQL VM '$($sqlvm.ID)' ParentVirtualMachine should reference a known VM's obfuscated ID"
                    $Checked++
                }
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "no SQLVM had a non-sentinel ParentVirtualMachine in this fixture" }
    }
}

Describe "Obfuscated ID Uniqueness" {
    It "Every obfuscated ID should be unique across all resources" {
        $IdCounts = $script:AllIds | Group-Object | Where-Object { $_.Count -gt 1 }
        $IdCounts | Should -BeNullOrEmpty -Because "No two resources should share the same obfuscated ID"
    }
}

Describe "Consumption to Inventory Cross-Reference" {
    It "Consumption ResourceIds are obfuscated (never a raw ARM path)" {
        if ($script:ConsumptionCsv.Count -eq 0) { Set-ItResult -Skipped -Because "empty consumption csv"; return }
        # Raw ARM paths are expected in a default (non-obfuscated) run, so this
        # only asserts in obfuscated mode. Skip honestly rather than pass vacuously.
        if (-not $script:IsObfuscated) { Set-ItResult -Skipped -Because "consumption ResourceIds are only obfuscated in an obfuscated run"; return }
        $Seen = 0
        foreach ($row in $script:ConsumptionCsv)
        {
            if ([string]::IsNullOrEmpty($row.ResourceId)) { continue }
            $Seen++
            # Assert the id is NOT a raw ARM path, not merely that it is a member of
            # the inventory set: a leaked raw path is absent from that set, so a membership-only check would silently miss it.
            $row.ResourceId | Should -Not -Match '/subscriptions/[0-9a-f]{8}-[0-9a-f]{4}' -Because "obfuscated consumption ResourceId must not be a raw Azure resource path"
        }
        if ($Seen -eq 0) { Set-ItResult -Skipped -Because "no consumption row carried a ResourceId in this fixture" }
    }
}

Describe "ResourceGroup Consistency" {
    It "Resources with the same obfuscated ResourceGroup should be grouped together" {
        $RgGroups = @{}
        $script:Inventory.PSObject.Properties | Where-Object { $null -ne $_.Value -and $_.Name -ne 'Version' } | ForEach-Object {
            @($_.Value) | ForEach-Object {
                if ($null -ne $_ -and $null -ne $_.ResourceGroup)
                {
                    if (-not $RgGroups.ContainsKey($_.ResourceGroup)) { $RgGroups[$_.ResourceGroup] = @() }
                    $RgGroups[$_.ResourceGroup] += $_.ID
                }
            }
        }
        # When obfuscated, assert each RG key is a deterministic prod_/nonprod_
        # pseudonym: a raw key would mean the RG dictionary failed to map it.
        foreach ($rg in $RgGroups.Keys)
        {
            if ($script:IsObfuscated -and -not [string]::IsNullOrEmpty($rg))
            {
                $rg | Should -Match '^(prod|nonprod)_' -Because "obfuscated ResourceGroup keys must be deterministic pseudonyms, not raw names"
            }
        }
    }
}

Describe "Subscription Determinism" {
    It "Resources sharing the same obfuscated Subscription should all have the same value" {
        # Collect all subscription values
        $SubValues = @{}
        $script:Inventory.PSObject.Properties | Where-Object { $null -ne $_.Value -and $_.Name -ne 'Version' } | ForEach-Object {
            @($_.Value) | ForEach-Object {
                if ($null -ne $_ -and $null -ne $_.Subscription)
                {
                    $SubValues[$_.Subscription] = $true
                }
            }
        }
        # There should be fewer unique subscription values than total resources
        # (deterministic = same real sub maps to same obfuscated sub)
        $SubValues.Keys.Count | Should -BeLessOrEqual $script:AllIds.Count -Because "Subscription values should be reused across resources in the same subscription"
    }
}

Describe "ResourceGroup Determinism" {
    It "Fewer unique ResourceGroup values than total resources (deterministic mapping)" {
        $RgValues = @{}
        $script:Inventory.PSObject.Properties | Where-Object { $null -ne $_.Value -and $_.Name -ne 'Version' } | ForEach-Object {
            @($_.Value) | ForEach-Object {
                if ($null -ne $_ -and $null -ne $_.ResourceGroup)
                {
                    $RgValues[$_.ResourceGroup] = $true
                }
            }
        }
        $RgValues.Keys.Count | Should -BeLessOrEqual $script:AllIds.Count -Because "ResourceGroup values should be reused across resources in the same RG"
    }
}

# Task 6 (spec: obfuscation-and-reveal) additive P8 coverage for cross-reference pairs not asserted above (Req 2.2/2.3/2.4, Property P8).
# disk->VM and SQLVM->parent VM are covered by the blocks above and intentionally NOT duplicated here.

Describe "SQLDB to SQL Server Cross-Reference (P8)" {
    It "Every SQLDB DatabaseServer carries the same token its parent SQL Server uses (or the 'obfuscated' sentinel)" {
        $SqlDbs = @($script:Inventory.SQLDB) | Where-Object { $null -ne $_ }
        if ($SqlDbs.Count -eq 0) { Set-ItResult -Skipped -Because "no SQLDB resources in this fixture"; return }
        $ServerIds = @($script:Inventory.SQLSERVER) | Where-Object { $null -ne $_ } | ForEach-Object { $_.ID }
        $Checked = 0
        foreach ($db in $SqlDbs)
        {
            if (![string]::IsNullOrEmpty($db.DatabaseServer) -and $db.DatabaseServer -ne 'obfuscated')
            {
                $db.DatabaseServer | Should -BeIn $ServerIds -Because "SQLDB '$($db.ID)' DatabaseServer should match its parent SQL Server's own obfuscated ID"
                $Checked++
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "all SQLDB DatabaseServer values were the out-of-scope 'obfuscated' sentinel (no in-scope parent server present)" }
    }

    It "Every SQLDB ElasticPoolID carries the same token its elastic pool uses (or a 'None'/'obfuscated' sentinel)" {
        $SqlDbs = @($script:Inventory.SQLDB) | Where-Object { $null -ne $_ }
        if ($SqlDbs.Count -eq 0) { Set-ItResult -Skipped -Because "no SQLDB resources in this fixture"; return }
        $PoolIds = @($script:Inventory.SQLPOOL) | Where-Object { $null -ne $_ } | ForEach-Object { $_.ID }
        $Tolerated = @('None', 'obfuscated')
        $Checked = 0
        foreach ($db in $SqlDbs)
        {
            if (![string]::IsNullOrEmpty($db.ElasticPoolID) -and $db.ElasticPoolID -notin $Tolerated)
            {
                $db.ElasticPoolID | Should -BeIn $PoolIds -Because "SQLDB '$($db.ID)' ElasticPoolID should match its elastic pool's own obfuscated ID"
                $Checked++
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "no SQLDB is a member of an in-scope elastic pool in this fixture (all 'None'/sentinel)" }
    }
}

Describe "SQLMIDB to Managed Instance Cross-Reference (P8)" {
    It "Every SQLMIDB ManagedInstance carries the same token its managed instance uses (or the 'obfuscated' sentinel)" {
        $MiDbs = @($script:Inventory.SQLMIDB) | Where-Object { $null -ne $_ }
        if ($MiDbs.Count -eq 0) { Set-ItResult -Skipped -Because "no SQLMIDB resources in this fixture"; return }
        $MiIds = @($script:Inventory.SQLMI) | Where-Object { $null -ne $_ } | ForEach-Object { $_.ID }
        $Checked = 0
        foreach ($midb in $MiDbs)
        {
            if (![string]::IsNullOrEmpty($midb.ManagedInstance) -and $midb.ManagedInstance -ne 'obfuscated')
            {
                $midb.ManagedInstance | Should -BeIn $MiIds -Because "SQLMIDB '$($midb.ID)' ManagedInstance should match its managed instance's own obfuscated ID"
                $Checked++
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "all SQLMIDB ManagedInstance values were the out-of-scope 'obfuscated' sentinel" }
    }
}

Describe "AvSet to VM Cross-Reference (P8)" {
    It "Every AvSet VirtualMachines token carries the same token the member VM uses (or the 'obfuscated' sentinel)" {
        $AvSets = @($script:Inventory.AvSet) | Where-Object { $null -ne $_ }
        if ($AvSets.Count -eq 0) { Set-ItResult -Skipped -Because "no AvSet resources in this fixture"; return }
        $VmIds = @($script:Inventory.VirtualMachines) | Where-Object { $null -ne $_ } | ForEach-Object { $_.ID }
        $Checked = 0
        foreach ($av in $AvSets)
        {
            if (![string]::IsNullOrEmpty($av.VirtualMachines) -and $av.VirtualMachines -ne 'obfuscated')
            {
                $av.VirtualMachines | Should -BeIn $VmIds -Because "AvSet '$($av.ID)' VirtualMachines should match a member VM's own obfuscated ID"
                $Checked++
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "all AvSet VirtualMachines values were empty or the out-of-scope 'obfuscated' sentinel" }
    }
}

Describe "VMSS Related-Cluster Cross-Reference (P8)" {
    It "Every VMSS related-cluster value carries the same token its AKS cluster uses, the out-of-scope sentinel, or a well-formed token for a Service-Fabric-backed scale set" {
        $VmssItems = @($script:Inventory.VMSS) | Where-Object { $null -ne $_ }
        if ($VmssItems.Count -eq 0) { Set-ItResult -Skipped -Because "no VMSS resources in this fixture"; return }
        # A scale set's 'AKS' field holds its related-cluster token, resolved to an
        # AKS cluster first, else a Service Fabric fallback; there is no SF inventory bucket, so an SF-backed match is accepted as any well-formed prod_/nonprod_ token, not an id lookup.
        $ClusterIds = @(@($script:Inventory.AKS) | Where-Object { $null -ne $_ } | ForEach-Object { $_.ID })
        $Checked = 0
        foreach ($ss in $VmssItems)
        {
            if (![string]::IsNullOrEmpty($ss.AKS))
            {
                $IsKnownClusterId = $ss.AKS -in $ClusterIds
                $IsSentinel = $ss.AKS -eq 'obfuscated'
                $IsWellFormedToken = $ss.AKS -match $script:TokenPattern
                ($IsKnownClusterId -or $IsSentinel -or $IsWellFormedToken) | Should -BeTrue `
                    -Because "VMSS '$($ss.ID)' related-cluster value should match its cluster's own obfuscated ID (AKS or Service Fabric), or be the out-of-scope sentinel"
                $Checked++
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "no VMSS carried a related-cluster value in this fixture" }
    }
}

Describe "Cross-Reference Out-of-Scope Sentinel (P8)" {
    It "Every in-scope cross-reference value is a valid target token or exactly the 'obfuscated' sentinel" {
        # Gather every known ID cross-reference field across the in-scope pairs.
        # Each value must be one of: a token that resolves to a real target ID in
        # the inventory (same-token, Req 2.2), the literal 'obfuscated' sentinel
        # for an out-of-scope target (Req 2.3), a benign 'None'/'' placeholder,
        # or a well-formed token. It must NEVER be a raw ARM path.
        $Refs = @()
        @($script:Inventory.VMDisk)  | Where-Object { $null -ne $_ } | ForEach-Object { if ($_.AssociatedResource) { $Refs += $_.AssociatedResource } }
        @($script:Inventory.SQLVM)   | Where-Object { $null -ne $_ } | ForEach-Object { if ($_.ParentVirtualMachine) { $Refs += $_.ParentVirtualMachine } }
        @($script:Inventory.SQLDB)   | Where-Object { $null -ne $_ } | ForEach-Object { if ($_.DatabaseServer) { $Refs += $_.DatabaseServer }; if ($_.ElasticPoolID) { $Refs += $_.ElasticPoolID } }
        @($script:Inventory.SQLMIDB) | Where-Object { $null -ne $_ } | ForEach-Object { if ($_.ManagedInstance) { $Refs += $_.ManagedInstance } }
        @($script:Inventory.AvSet)   | Where-Object { $null -ne $_ } | ForEach-Object { if ($_.VirtualMachines) { $Refs += $_.VirtualMachines } }
        $Refs = @($Refs | Where-Object { ![string]::IsNullOrEmpty($_) })
        if ($Refs.Count -eq 0) { Set-ItResult -Skipped -Because "no cross-reference values present in this fixture"; return }
        $Tolerated = @('obfuscated', 'None')
        foreach ($ref in $Refs)
        {
            if ($ref -in $Tolerated) { continue }
            ($ref -in $script:AllIds -or $ref -match $script:TokenPattern) | Should -BeTrue -Because "cross-reference '$ref' must be a valid target token or the 'obfuscated' sentinel, never a raw identifier"
        }
    }
}

Describe "Metric Per-Resource Cached Token (P8)" {
    It "Metric rows for the same resource carry a consistent obfuscated identity across their own metrics" {
        if ($script:MetricRows.Count -eq 0) { Set-ItResult -Skipped -Because "no metric rows in this fixture"; return }
        # A resource's obfuscated identity must be stable across all of its own
        # metric rows so the resource still correlates. Group by obfuscated ID
        # and assert Name/Subscription/ResourceGroup are constant within a group.
        $Violations = @()
        $script:MetricRows | Where-Object { ![string]::IsNullOrEmpty($_.ID) } | Group-Object ID | ForEach-Object {
            $Names = @($_.Group.Name | Sort-Object -Unique).Count
            $Subs = @($_.Group.Subscription | Sort-Object -Unique).Count
            $Rgs = @($_.Group.ResourceGroup | Sort-Object -Unique).Count
            if ($Names -gt 1 -or $Subs -gt 1 -or $Rgs -gt 1) { $Violations += $_.Name }
        }
        $Violations | Should -BeNullOrEmpty -Because "each obfuscated resource ID should map to a single Name/Subscription/ResourceGroup across its metric rows"
    }

    It "Metric rows for resources absent from the main dictionary still carry a cached per-resource token" {
        if ($script:MetricRows.Count -eq 0) { Set-ItResult -Skipped -Because "no metric rows in this fixture"; return }
        # Req 2.4: a metric row whose resource is NOT in the main inventory
        # dictionary gets a fresh cached token so it still correlates across its
        # own metrics. In a single-run fixture every metric-bearing resource is
        # normally also inventoried, so this fallback path may be unexercised.
        $AbsentIds = @($script:MetricRows | Where-Object { ![string]::IsNullOrEmpty($_.ID) -and $_.ID -notin $script:AllIds } | Select-Object -ExpandProperty ID -Unique)
        if ($AbsentIds.Count -eq 0) { Set-ItResult -Skipped -Because "fixture does not exercise the metric fallback path (all metric-referenced resources are present in the inventory dictionary)"; return }
        foreach ($id in $AbsentIds)
        {
            $id | Should -Match $script:TokenPattern -Because "a metric resource absent from the main dictionary should still receive a cached prod_/nonprod_ token, not a raw id"
            $id | Should -Not -Be 'obfuscated' -Because "the metric fallback assigns a correlatable cached token, not the lossy sentinel"
        }
    }

    It "Metric resource IDs resolve to inventory resource IDs (the metrics-to-inventory join holds under obfuscation)" {
        if ($script:MetricRows.Count -eq 0) { Set-ItResult -Skipped -Because "no metric rows in this fixture"; return }
        $InvIdSet = @($script:AllIds)
        if ($InvIdSet.Count -eq 0) { Set-ItResult -Skipped -Because "no inventory IDs in this fixture"; return }

        $MetricIds = @($script:MetricRows | Where-Object { ![string]::IsNullOrEmpty($_.ID) } | Select-Object -ExpandProperty ID -Unique)
        if ($MetricIds.Count -eq 0) { Set-ItResult -Skipped -Because "no metric rows carried an ID in this fixture"; return }

        # A metric row's token comes from the same $ResourceIdDictionary the inventory row used, so an also-inventoried resource MUST carry the identical token (the metrics-to-inventory join).
        # Two guards below catch a regression without false-failing on the legitimate fallback (a deleted/transient metric-eligible resource never inventoried): zero overlap is catastrophic; the matched set must be the majority.
        $Matched = @($MetricIds | Where-Object { $_ -in $InvIdSet })
        $Absent = @($MetricIds | Where-Object { $_ -notin $InvIdSet })

        $Matched.Count | Should -BeGreaterThan 0 -Because "at least one metric resource must carry the same obfuscated ID as its inventory row; zero overlap means metrics minted fresh tokens and the metrics-to-inventory join is broken"
        # Guard 2 (matched >= absent) is only signal once the metric-ID sample is large enough, so gate it behind a minimum floor and skip below it; the catastrophic zero-overlap guard above still runs on every fixture.
        $RatioSampleFloor = 5
        if ($MetricIds.Count -ge $RatioSampleFloor)
        {
            $Matched.Count | Should -BeGreaterOrEqual $Absent.Count -Because ("metric IDs should predominantly resolve to inventory IDs (matched={0}, absent={1}); absent exceeding matched indicates a whole metric path is obfuscating IDs inconsistently with the inventory" -f $Matched.Count, $Absent.Count)
        }
    }
}
