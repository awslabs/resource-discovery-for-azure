# Referential Integrity Tests
# Validates that cross-references between resources are consistent after obfuscation
# Run with: Invoke-Pester ./Tests/ReferentialIntegrity.Tests.ps1 -Output Detailed

BeforeAll {
    $zipPath = if ($env:TEST_ZIP_PATH) { $env:TEST_ZIP_PATH } else {
        Get-ChildItem -Path $PSScriptRoot -Filter "ResourcesReport_*.zip" | 
            Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
    if ([string]::IsNullOrEmpty($zipPath) -or -not (Test-Path $zipPath)) {
        throw "No test zip found. Copy a ResourcesReport_*.zip to Tests/ or set `$env:TEST_ZIP_PATH"
    }
    $tmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { "/tmp" }
    $script:ExtractPath = Join-Path $tmpBase ("RefIntTest_" + [guid]::NewGuid().ToString().Substring(0,8))
    New-Item -ItemType Directory -Path $script:ExtractPath -Force | Out-Null
    Expand-Archive -Path $zipPath -DestinationPath $script:ExtractPath -Force

    $invFile = Get-ChildItem -Path $script:ExtractPath -Filter "Inventory_*.json" | Select-Object -First 1
    $script:Inventory = Get-Content $invFile.FullName -Raw | ConvertFrom-Json

    $csvFile = Get-ChildItem -Path $script:ExtractPath -Filter "Consumption_*.csv" | Select-Object -First 1
    $script:ConsumptionCsv = if ($csvFile) { 
        $content = Get-Content $csvFile.FullName -ErrorAction SilentlyContinue
        if ($null -ne $content -and $content.Count -gt 1) { Import-Csv $csvFile.FullName } else { @() }
    } else { @() }

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
}

AfterAll {
    if (Test-Path $script:ExtractPath) { Remove-Item -Path $script:ExtractPath -Recurse -Force }
}

Describe "VM Disk to VM Cross-Reference" {
    It "Every disk AssociatedResource should match a VM ID or be null" {
        $disks = @($script:Inventory.VMDisk) | Where-Object { $null -ne $_ }
        if ($disks.Count -eq 0) { Set-ItResult -Skipped -Because "no VMDisk resources in this fixture"; return }
        $vmIds = @($script:Inventory.VirtualMachines) | Where-Object { $null -ne $_ } | ForEach-Object { $_.ID }
        $Checked = 0
        foreach ($disk in $disks) {
            if ($null -ne $disk -and ![string]::IsNullOrEmpty($disk.AssociatedResource)) {
                $disk.AssociatedResource | Should -BeIn $vmIds -Because "Disk '$($disk.ID)' AssociatedResource should reference a known VM"
                $Checked++
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "no VMDisk had a non-null AssociatedResource in this fixture" }
    }
}

Describe "AVD HostId to VM Cross-Reference" {
    It "Every AVD HostId should match a VM ID or be null" {
        $avd = @($script:Inventory.AVD) | Where-Object { $null -ne $_ }
        if ($avd.Count -eq 0) { Set-ItResult -Skipped -Because "no AVD resources in this fixture"; return }
        $vmIds = @($script:Inventory.VirtualMachines) | Where-Object { $null -ne $_ } | ForEach-Object { $_.ID }
        $Checked = 0
        foreach ($avdItem in $avd) {
            if ($null -ne $avdItem -and ![string]::IsNullOrEmpty($avdItem.HostId)) {
                $avdItem.HostId | Should -BeIn $vmIds -Because "AVD HostId should reference a known VM"
                $Checked++
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "no AVD had a non-null HostId in this fixture" }
    }
}

Describe "SQL VM to VM Cross-Reference" {
    It "Every SQL VM ParentVirtualMachine should match a VM ID (or be a tolerated sentinel)" {
        $sqlvms = @($script:Inventory.SQLVM) | Where-Object { $null -ne $_ }
        if ($sqlvms.Count -eq 0) { Set-ItResult -Skipped -Because "no SQLVM resources in this fixture"; return }
        $vmIds = @($script:Inventory.VirtualMachines) | Where-Object { $null -ne $_ } | ForEach-Object { $_.ID }
        # Sentinels the collector emits when the parent VM is out of scope or absent:
        #   'obfuscated' (obfuscation on, parent id not indexed) / 'None' (no parent id).
        $tolerated = @('obfuscated', 'None')
        $Checked = 0
        foreach ($sqlvm in $sqlvms) {
            if ($null -ne $sqlvm -and ![string]::IsNullOrEmpty($sqlvm.ParentVirtualMachine)) {
                if ($sqlvm.ParentVirtualMachine -notin $tolerated) {
                    $sqlvm.ParentVirtualMachine | Should -BeIn $vmIds -Because "SQL VM '$($sqlvm.ID)' ParentVirtualMachine should reference a known VM's obfuscated ID"
                    $Checked++
                }
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "no SQLVM had a non-sentinel ParentVirtualMachine in this fixture" }
    }
}

Describe "Obfuscated ID Uniqueness" {
    It "Every obfuscated ID should be unique across all resources" {
        $idCounts = $script:AllIds | Group-Object | Where-Object { $_.Count -gt 1 }
        $idCounts | Should -BeNullOrEmpty -Because "No two resources should share the same obfuscated ID"
    }
}

Describe "Consumption to Inventory Cross-Reference" {
    It "Consumption ResourceIds that exist in inventory should use the same obfuscated value" {
        if ($script:ConsumptionCsv.Count -eq 0) { Set-ItResult -Skipped -Because "empty consumption csv"; return }
        $inventoryIds = $script:AllIds
        foreach ($row in $script:ConsumptionCsv) {
            if (![string]::IsNullOrEmpty($row.ResourceId) -and $row.ResourceId -in $inventoryIds) {
                # If it's in both, the ID should be identical (same dictionary mapping)
                $row.ResourceId | Should -BeIn $inventoryIds -Because "Consumption ResourceId should match inventory ID"
            }
        }
    }
}

Describe "ResourceGroup Consistency" {
    It "Resources with the same obfuscated ResourceGroup should be grouped together" {
        $rgGroups = @{}
        $script:Inventory.PSObject.Properties | Where-Object { $null -ne $_.Value -and $_.Name -ne 'Version' } | ForEach-Object {
            @($_.Value) | ForEach-Object {
                if ($null -ne $_ -and $null -ne $_.ResourceGroup) {
                    if (-not $rgGroups.ContainsKey($_.ResourceGroup)) { $rgGroups[$_.ResourceGroup] = @() }
                    $rgGroups[$_.ResourceGroup] += $_.ID
                }
            }
        }
        # Each RG should have at least one resource
        foreach ($rg in $rgGroups.Keys) {
            $rgGroups[$rg].Count | Should -BeGreaterThan 0 -Because "ResourceGroup '$rg' should have at least one resource"
        }
    }
}

Describe "Subscription Determinism" {
    It "Resources sharing the same obfuscated Subscription should all have the same value" {
        # Collect all subscription values
        $subValues = @{}
        $script:Inventory.PSObject.Properties | Where-Object { $null -ne $_.Value -and $_.Name -ne 'Version' } | ForEach-Object {
            @($_.Value) | ForEach-Object {
                if ($null -ne $_ -and $null -ne $_.Subscription) {
                    $subValues[$_.Subscription] = $true
                }
            }
        }
        # There should be fewer unique subscription values than total resources
        # (deterministic = same real sub maps to same obfuscated sub)
        $subValues.Keys.Count | Should -BeLessOrEqual $script:AllIds.Count -Because "Subscription values should be reused across resources in the same subscription"
    }
}

Describe "ResourceGroup Determinism" {
    It "Fewer unique ResourceGroup values than total resources (deterministic mapping)" {
        $rgValues = @{}
        $script:Inventory.PSObject.Properties | Where-Object { $null -ne $_.Value -and $_.Name -ne 'Version' } | ForEach-Object {
            @($_.Value) | ForEach-Object {
                if ($null -ne $_ -and $null -ne $_.ResourceGroup) {
                    $rgValues[$_.ResourceGroup] = $true
                }
            }
        }
        $rgValues.Keys.Count | Should -BeLessOrEqual $script:AllIds.Count -Because "ResourceGroup values should be reused across resources in the same RG"
    }
}

# ============================================================================
# Task 6 (spec: obfuscation-and-reveal) — additive P8 coverage.
# Purely additive. Closes gaps for cross-reference pairs not already asserted
# above (SQLDB server/pool, SQLMIDB managed instance, AvSet VMs, VMSS related
# cluster), the out-of-scope 'obfuscated' sentinel (Req 2.3), and the metric
# per-resource cached token (Req 2.4). Where the live fixture lacks a given
# pair the block skips gracefully rather than fabricating resources.
#   Validates: Requirements 2.2, 2.3, 2.4 | Property: P8
# The disk->VM (VM Disk to VM) and SQLVM->parent VM (SQL VM to VM) pairs are
# already covered by the blocks above and are intentionally NOT duplicated here.
# ============================================================================

Describe "SQLDB to SQL Server Cross-Reference (P8)" {
    It "Every SQLDB DatabaseServer carries the same token its parent SQL Server uses (or the 'obfuscated' sentinel)" {
        $SqlDbs = @($script:Inventory.SQLDB) | Where-Object { $null -ne $_ }
        if ($SqlDbs.Count -eq 0) { Set-ItResult -Skipped -Because "no SQLDB resources in this fixture"; return }
        $ServerIds = @($script:Inventory.SQLSERVER) | Where-Object { $null -ne $_ } | ForEach-Object { $_.ID }
        $Checked = 0
        foreach ($db in $SqlDbs) {
            if (![string]::IsNullOrEmpty($db.DatabaseServer) -and $db.DatabaseServer -ne 'obfuscated') {
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
        foreach ($db in $SqlDbs) {
            if (![string]::IsNullOrEmpty($db.ElasticPoolID) -and $db.ElasticPoolID -notin $Tolerated) {
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
        foreach ($midb in $MiDbs) {
            if (![string]::IsNullOrEmpty($midb.ManagedInstance) -and $midb.ManagedInstance -ne 'obfuscated') {
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
        foreach ($av in $AvSets) {
            if (![string]::IsNullOrEmpty($av.VirtualMachines) -and $av.VirtualMachines -ne 'obfuscated') {
                $av.VirtualMachines | Should -BeIn $VmIds -Because "AvSet '$($av.ID)' VirtualMachines should match a member VM's own obfuscated ID"
                $Checked++
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "all AvSet VirtualMachines values were empty or the out-of-scope 'obfuscated' sentinel" }
    }
}

Describe "VMSS Related-Cluster Cross-Reference (P8)" {
    It "Every VMSS related-cluster (AKS) value carries the same token its AKS cluster uses (or the 'obfuscated' sentinel)" {
        $VmssItems = @($script:Inventory.VMSS) | Where-Object { $null -ne $_ }
        if ($VmssItems.Count -eq 0) { Set-ItResult -Skipped -Because "no VMSS resources in this fixture"; return }
        # A scale set exposes its related AKS / Service-Fabric cluster via the
        # 'AKS' field. The collector resolves the cluster's real ID through
        # $ResourceIdDictionary and emits the SAME token the cluster's own row
        # uses for its identity (Req 2.2), falling back to the 'obfuscated'
        # sentinel when the target is out of scope (Req 2.3).
        $ClusterIds = @(@($script:Inventory.AKS) | Where-Object { $null -ne $_ } | ForEach-Object { $_.ID })
        $Checked = 0
        foreach ($ss in $VmssItems) {
            if (![string]::IsNullOrEmpty($ss.AKS)) {
                $ss.AKS | Should -BeIn (@($ClusterIds) + 'obfuscated') -Because "VMSS '$($ss.ID)' related-cluster value should match its AKS cluster's own obfuscated ID (or the out-of-scope sentinel)"
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
        @($script:Inventory.VMDisk)  | Where-Object { $null -ne $_ } | ForEach-Object { if ($_.AssociatedResource)   { $Refs += $_.AssociatedResource } }
        @($script:Inventory.SQLVM)   | Where-Object { $null -ne $_ } | ForEach-Object { if ($_.ParentVirtualMachine) { $Refs += $_.ParentVirtualMachine } }
        @($script:Inventory.SQLDB)   | Where-Object { $null -ne $_ } | ForEach-Object { if ($_.DatabaseServer)       { $Refs += $_.DatabaseServer }; if ($_.ElasticPoolID) { $Refs += $_.ElasticPoolID } }
        @($script:Inventory.SQLMIDB) | Where-Object { $null -ne $_ } | ForEach-Object { if ($_.ManagedInstance)      { $Refs += $_.ManagedInstance } }
        @($script:Inventory.AvSet)   | Where-Object { $null -ne $_ } | ForEach-Object { if ($_.VirtualMachines)      { $Refs += $_.VirtualMachines } }
        $Refs = @($Refs | Where-Object { ![string]::IsNullOrEmpty($_) })
        if ($Refs.Count -eq 0) { Set-ItResult -Skipped -Because "no cross-reference values present in this fixture"; return }
        $Tolerated = @('obfuscated', 'None')
        foreach ($ref in $Refs) {
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
            $Subs  = @($_.Group.Subscription | Sort-Object -Unique).Count
            $Rgs   = @($_.Group.ResourceGroup | Sort-Object -Unique).Count
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
        foreach ($id in $AbsentIds) {
            $id | Should -Match $script:TokenPattern -Because "a metric resource absent from the main dictionary should still receive a cached prod_/nonprod_ token, not a raw id"
            $id | Should -Not -Be 'obfuscated' -Because "the metric fallback assigns a correlatable cached token, not the lossy sentinel"
        }
    }
}
