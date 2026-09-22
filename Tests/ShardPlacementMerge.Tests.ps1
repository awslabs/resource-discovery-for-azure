#Requires -Version 7.0
<#
    ShardPlacementMerge.Tests.ps1

    Guards the multi-shard merge sequence documented in docs/horizontal-sharding.md
    against silently losing the tenant-wide VM placement CSV.

    WHY THIS EXISTS. VMPlacement.csv is a capacity-planning input: it carries the
    availability-zone of every VM and scale set so a planner can size how many nodes
    are needed per AZ. Every shard's outer zip carries it at the root under the SAME
    FIXED NAME, alongside MainSummary.html and RunSummary.log.

    The originally documented merge extracted every shard into ONE shared folder and
    then re-zipped only '*.zip'. REPRODUCED with real archives: that loses the data
    twice over - N-1 shard copies are overwritten on disk by the shared extract, and
    the single survivor is then excluded from the merged bundle by the *.zip glob, so
    the merged tenant bundle contained NO placement member at all. Silent, and worst
    in exactly the large tenants sharding exists for.

    These tests are OFFLINE and self-contained: they build synthetic shard bundles in
    a temp directory and execute the merge steps against them. No Azure, no network.

    The suite asserts BOTH directions:
      - the naive shared-destination extract really does clobber (so the guard below
        is not vacuous and the reason for the per-shard folder stays documented), and
      - the documented sequence preserves every shard's rows, writes the header once,
        and lands the CSV at the merged bundle root.
#>

BeforeAll {
    $script:Root = Join-Path ([IO.Path]::GetTempPath()) ('ShardMerge_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:Root -Force | Out-Null

    # The real emitter's column order (Extension/VMPlacement.ps1). Only the columns a
    # capacity total needs are exercised here; the full 22-column contract is pinned
    # by Tests/VMPlacementCsv.Tests.ps1.
    $script:Header = 'ResourceKind,Subscription,ResourceGroup,Name,Location,Zone,Size,Instances,CPU,MemoryGB'

    function script:New-ShardBundle
    {
        param([string]$ShardName, [string[]]$PlacementRows, [string]$InnerZipName)

        $Work = Join-Path $script:Root ('work_' + $ShardName)
        New-Item -ItemType Directory -Path $Work -Force | Out-Null

        # Root member 1: the shard's placement CSV, at the FIXED name every shard uses.
        $Csv = Join-Path $Work 'VMPlacement.csv'
        (@($script:Header) + $PlacementRows) | Set-Content -LiteralPath $Csv -Encoding utf8

        # Root member 2: a fixed-name presentation file, to show the collision is not
        # unique to the CSV.
        $Summary = Join-Path $Work 'MainSummary.html'
        ('<html>' + $ShardName + '</html>') | Set-Content -LiteralPath $Summary -Encoding utf8

        # Root member 3: one inner per-subscription data archive. Disjoint slices, so
        # these names ARE unique across shards.
        $InnerSrc = Join-Path $Work 'payload.txt'
        $ShardName | Set-Content -LiteralPath $InnerSrc -Encoding utf8
        $InnerZip = Join-Path $Work $InnerZipName
        Compress-Archive -LiteralPath $InnerSrc -DestinationPath $InnerZip -Force

        $Bundles = Join-Path $script:Root 'shard-zips'
        New-Item -ItemType Directory -Path $Bundles -Force | Out-Null
        $Outer = Join-Path $Bundles ('AllSubscriptions_ResourcesReport_{0}.zip' -f $ShardName)
        Compress-Archive -LiteralPath @($Csv, $Summary, $InnerZip) -DestinationPath $Outer -Force
        return $Outer
    }

    function script:Get-ZipRootEntry
    {
        param([string]$ZipPath)
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $Archive = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $ZipPath).Path)
        try { return @($Archive.Entries | ForEach-Object { $_.FullName } | Where-Object { $_ -notmatch '[\\/]' }) }
        finally { $Archive.Dispose() }
    }

    # Two shards, disjoint subscriptions, each with capacity a planner must total.
    $script:Shard0 = script:New-ShardBundle -ShardName 'shard0' -InnerZipName 'ResourcesReport_A.zip' -PlacementRows @(
        'VirtualMachine,prod_subA,rg1,vm1,westeurope,1,Standard_D4s_v5,1,4,16'
        'VirtualMachine,prod_subA,rg1,vm2,westeurope,2,Standard_D4s_v5,1,4,16'
    )
    $script:Shard1 = script:New-ShardBundle -ShardName 'shard1' -InnerZipName 'ResourcesReport_B.zip' -PlacementRows @(
        'VirtualMachine,prod_subB,rg2,vm3,northeurope,3,Standard_D8s_v5,1,8,32'
    )
    $script:ShardDir = Join-Path $script:Root 'shard-zips'
}

AfterAll {
    if ($script:Root -and (Test-Path -LiteralPath $script:Root))
    {
        Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'The naive shared-destination extract loses shard placement data' {

    # Negative control. If this ever stops clobbering, the per-shard-subfolder step in
    # the documented sequence is no longer load-bearing and the docs should say so.

    BeforeAll {
        # Shared naive extract: every shard into ONE folder, so both It blocks are
        # independent of each other's execution and order.
        $script:NaiveStaging = Join-Path $script:Root 'naive'
        New-Item -ItemType Directory -Path $script:NaiveStaging -Force | Out-Null

        foreach ($Shard in Get-ChildItem -LiteralPath $script:ShardDir -Filter 'AllSubscriptions_ResourcesReport_*.zip')
        {
            Expand-Archive -LiteralPath $Shard.FullName -DestinationPath $script:NaiveStaging -Force
        }
    }

    It 'overwrites all but one shard copy when every shard extracts to the same folder' {
        $Rows = @(Import-Csv -LiteralPath (Join-Path $script:NaiveStaging 'VMPlacement.csv'))
        $Subs = @($Rows | ForEach-Object { $_.Subscription } | Select-Object -Unique)

        # 3 rows across 2 subscriptions exist in total; a clobbered merge sees only one
        # shard's worth.
        $Subs.Count | Should -Be 1 -Because 'the shared destination keeps only the last-extracted shard, which is the data loss this guard documents'
        $Rows.Count | Should -BeLessThan 3
    }

    It 'and the *.zip-only re-zip then excludes even the survivor' {
        $Merged = Join-Path $script:Root 'naive-merged.zip'
        Compress-Archive -Path (Join-Path $script:NaiveStaging '*.zip') -DestinationPath $Merged -Force

        $RootEntries = script:Get-ZipRootEntry -ZipPath $Merged
        @($RootEntries | Where-Object { $_ -like '*.csv' }).Count |
            Should -Be 0 -Because 'the naive merge produced a tenant bundle with NO placement member at all'
    }
}

Describe 'The documented merge sequence preserves the tenant-wide placement view' {

    BeforeAll {
        # This mirrors the sequence in docs/horizontal-sharding.md step for step. It is
        # duplicated here rather than invoked, because the sequence lives in a markdown
        # fenced block; the doc-parity assertion at the end is what keeps them aligned.
        $script:Staging = Join-Path $script:Root 'tenant-merge'
        New-Item -ItemType Directory -Path $script:Staging -Force | Out-Null
        $PlacementParts = @()

        # 1. Per-shard subfolder, so fixed root names cannot collide.
        foreach ($Shard in Get-ChildItem -LiteralPath $script:ShardDir -Filter 'AllSubscriptions_ResourcesReport_*.zip')
        {
            $ShardDir = Join-Path $script:Staging $Shard.BaseName
            Expand-Archive -LiteralPath $Shard.FullName -DestinationPath $ShardDir -Force
            $Csv = Join-Path $ShardDir 'VMPlacement.csv'
            if (Test-Path -LiteralPath $Csv) { $PlacementParts += $Csv }
        }

        # 2. Lift the inner per-subscription zips to the staging root.
        Get-ChildItem -LiteralPath $script:Staging -Recurse -Filter 'ResourcesReport_*.zip' |
            ForEach-Object { Move-Item -LiteralPath $_.FullName -Destination (Join-Path $script:Staging $_.Name) -Force }

        # 3. Concatenate via Import-Csv/Export-Csv so the header is written once.
        $script:MergedRows = @()
        foreach ($Part in $PlacementParts) { $script:MergedRows += @(Import-Csv -LiteralPath $Part) }
        if ($script:MergedRows.Count -gt 0)
        {
            $script:MergedRows | Export-Csv -LiteralPath (Join-Path $script:Staging 'VMPlacement.csv') -Encoding utf8 -NoTypeInformation
        }

        # 4. Re-zip inner zips PLUS the merged CSV.
        $script:Merged = Join-Path $script:Root 'tenant-merged.zip'
        $Members = @(Get-ChildItem -LiteralPath $script:Staging -File | Where-Object { $_.Extension -in @('.zip', '.csv') })
        Compress-Archive -LiteralPath $Members.FullName -DestinationPath $script:Merged -Force

        $script:MergedRootEntries = script:Get-ZipRootEntry -ZipPath $script:Merged
    }

    It 'keeps every shard subscription, losing none' {
        $Subs = @($script:MergedRows | ForEach-Object { $_.Subscription } | Select-Object -Unique | Sort-Object)
        $Subs | Should -Be @('prod_subA', 'prod_subB')
    }

    It 'keeps every placement row' {
        $script:MergedRows.Count | Should -Be 3
    }

    It 'writes the header exactly once, so no shard header becomes a data row' {
        $Lines = @(Get-Content -LiteralPath (Join-Path $script:Staging 'VMPlacement.csv'))
        @($Lines | Where-Object { $_ -match '(^|,)"?ResourceKind"?,' }).Count |
            Should -Be 1 -Because 'a text append would repeat the header once per shard and corrupt the row count'
        @($script:MergedRows | Where-Object { $_.ResourceKind -eq 'ResourceKind' }).Count | Should -Be 0
    }

    It 'produces a summable capacity total across the whole tenant' {
        # The number the file exists to produce: tenant-wide SUM(CPU * Instances).
        $Total = 0
        foreach ($Row in $script:MergedRows) { $Total += ([double]$Row.CPU * [double]$Row.Instances) }
        $Total | Should -Be 16 -Because '4 + 4 from shard0 and 8 from shard1'

        $Zones = @($script:MergedRows | ForEach-Object { $_.Zone } | Select-Object -Unique | Sort-Object)
        $Zones | Should -Be @('1', '2', '3') -Because 'per-AZ planning needs every shard zone represented'
    }

    It 'lands VMPlacement.csv at the merged bundle root under the fixed name' {
        $script:MergedRootEntries | Should -Contain 'VMPlacement.csv' -Because 'the merged bundle must match the shape a single non-sharded run produces'
        @($script:MergedRootEntries | Where-Object { $_ -match '^VMPlacement_\d' }).Count | Should -Be 0
    }

    It 'still carries every inner per-subscription archive' {
        @($script:MergedRootEntries | Where-Object { $_ -like 'ResourcesReport_*.zip' }).Count | Should -Be 2
    }

    It 'keeps VMPlacement.csv the only loose CSV at the merged root' {
        # Same ingestion-contract rule the single-run bundle obeys.
        foreach ($Csv in @($script:MergedRootEntries | Where-Object { $_ -like '*.csv' }))
        {
            $Csv | Should -Be 'VMPlacement.csv'
        }
    }
}

Describe 'The documented sequence and this test cannot drift apart' {

    # The merge lives in a markdown fenced block, so it cannot be invoked directly.
    # Assert the doc still teaches each load-bearing step; if someone simplifies the
    # doc back to a shared extract, this fails.

    BeforeAll {
        $script:DocPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'docs/horizontal-sharding.md'
        $script:DocSrc = Get-Content -LiteralPath $script:DocPath -Raw
    }

    It 'documents the per-shard extraction subfolder' {
        $script:DocSrc | Should -Match 'Join-Path \$staging \$shard\.BaseName' -Because 'a shared destination silently overwrites all but the last shard'
    }

    It 'documents the placement concatenation' {
        $script:DocSrc | Should -Match 'Import-Csv -LiteralPath \$part'
        $script:DocSrc | Should -Match "Export-Csv -LiteralPath \(Join-Path \`$staging 'VMPlacement\.csv'\)"
    }

    It 'includes the CSV in the re-zip, not just the inner zips' {
        # The original defect: Compress-Archive over '*.zip' only.
        $script:DocSrc | Should -Match "Extension -in @\('\.zip', '\.csv'\)" -Because 'the merged bundle must include the placement CSV'
    }

    It 'explains WHY the per-shard folder is needed, so it is not simplified away' {
        # The three load-bearing facts, in the doc's own words: the names collide, a
        # shared folder overwrites, and for the placement CSV that loss is silent.
        $script:DocSrc | Should -Match 'fixed names at its root' -Because 'the collision is the reason for the per-shard folder'
        $script:DocSrc | Should -Match "overwrite the previous one's copies"
        $script:DocSrc | Should -Match 'silent data loss' -Because 'the consequence must be stated, or the step reads as ceremony'
    }
}
