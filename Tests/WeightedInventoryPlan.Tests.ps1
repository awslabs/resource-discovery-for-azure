#Requires -Version 7.0
# Offline unit tests for the composition-aware -Plan sizing helpers in Functions/RunAllSubscriptions.Functions.ps1
# (weight map, KQL builder, hash value - must agree with Get-ShardKeyForSubscription - and busiest-shard sizing); all pure, no Azure.

BeforeAll {
    $RepoRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $RepoRoot 'Functions/RunAllSubscriptions.Functions.ps1')
}

Describe 'Get-MetricQueryWeightMap' {

    It 'weights the dominant types per Extension/Metrics.ps1 (disk 4, VM 2, SQL 9, storage 1)' {
        $Map = Get-MetricQueryWeightMap
        ($Map | Where-Object { $_.Type -eq 'microsoft.compute/disks' }).Weight            | Should -Be 4
        ($Map | Where-Object { $_.Type -eq 'microsoft.compute/virtualmachines' }).Weight  | Should -Be 2
        # SQL is the serverless worst case (9: the 8 every DB issues + app_cpu_billed).
        ($Map | Where-Object { $_.Type -eq 'microsoft.sql/servers/databases' }).Weight    | Should -Be 9
        ($Map | Where-Object { $_.Type -eq 'microsoft.storage/storageaccounts' }).Weight  | Should -Be 1
    }

    It 'gates disks and storage so the -Skip*Metrics switches can drop them' {
        $Map = Get-MetricQueryWeightMap
        ($Map | Where-Object { $_.Type -eq 'microsoft.compute/disks' }).Gate           | Should -Be 'Disk'
        ($Map | Where-Object { $_.Type -eq 'microsoft.storage/storageaccounts' }).Gate | Should -Be 'Storage'
    }

    It 'scopes disks to attached and SQL to non-master via ExtraFilter' {
        $Map = Get-MetricQueryWeightMap
        ($Map | Where-Object { $_.Type -eq 'microsoft.compute/disks' }).ExtraFilter         | Should -Match 'managedBy'
        ($Map | Where-Object { $_.Type -eq 'microsoft.sql/servers/databases' }).ExtraFilter | Should -Match 'master'
    }

    It 'locks the full type->weight set (drift here must be a deliberate sync with Extension/Metrics.ps1)' {
        # Golden lock: the metric-query count per type mirrors the MetricDefs.Add
        # calls in Extension/Metrics.ps1. If a metric name is added/removed there,
        # update BOTH and this expectation - a silent change would skew -Plan sizing.
        $Expected = @{
            'microsoft.compute/virtualmachines'        = 2
            'microsoft.compute/disks'                  = 4
            'microsoft.storage/storageaccounts'        = 1
            'microsoft.sql/servers/databases'          = 9
            'microsoft.web/sites'                      = 2
            'microsoft.dbformariadb/servers'           = 3
            'microsoft.dbforpostgresql/servers'        = 3
            'microsoft.dbformysql/servers'             = 3
            'microsoft.dbformysql/flexibleservers'     = 3
            'microsoft.dbforpostgresql/flexibleservers' = 3
            'microsoft.compute/virtualmachinescalesets' = 2
            'microsoft.documentdb/databaseaccounts'    = 4
            'microsoft.containerregistry/registries'   = 1
        }
        $Map = Get-MetricQueryWeightMap
        $Map.Count | Should -Be $Expected.Count
        foreach ($entry in $Map)
        {
            $Expected.ContainsKey($entry.Type) | Should -BeTrue -Because "$($entry.Type) should be an expected metric-eligible type"
            $entry.Weight | Should -Be $Expected[$entry.Type] -Because "weight for $($entry.Type) must match Extension/Metrics.ps1"
        }
    }

    It 'marks exactly the batchable services (VM, disk, storage, SQL, VMSS, Cosmos) as Batched' {
        # Must mirror $BatchNamespaceMap in Extension/Metrics.ps1 - only these
        # types are fetched via metrics:getBatch, so -Plan applies the batch
        # discount to just their weight and leaves the rest per-call.
        $Batched = @{
            'microsoft.compute/virtualmachines'         = $true
            'microsoft.compute/disks'                   = $true
            'microsoft.storage/storageaccounts'         = $true
            'microsoft.sql/servers/databases'           = $true
            'microsoft.compute/virtualmachinescalesets' = $true
            'microsoft.documentdb/databaseaccounts'     = $true
        }
        $Map = Get-MetricQueryWeightMap
        foreach ($entry in $Map)
        {
            $ExpectBatched = [bool]$Batched[$entry.Type]
            [bool]$entry.Batched | Should -Be $ExpectBatched -Because "Batched flag for $($entry.Type) must match Extension/Metrics.ps1 BatchNamespaceMap"
        }
        # Lock the batch-discount surface cardinality directly, so an accidental
        # extra Batched=$true entry is caught even if it is a new/unexpected type.
        (@($Map | Where-Object { $_.Batched }).Count) | Should -Be 6
    }
}

Describe 'Get-PlanWeightKql' {

    It 'summarizes both the total and batched-only per-subscription weight' {
        $Kql = Get-PlanWeightKql
        $Kql | Should -Match 'summarize QueryWeight = sum\(__w\), BatchWeight = sum\(__bw\) by subscriptionId'
        $Kql | Should -Match '__bw = case'
        $Kql | Should -Match "microsoft.compute/virtualmachines"
    }

    It 'includes the disk and storage terms by default' {
        $Kql = Get-PlanWeightKql
        $Kql | Should -Match 'microsoft.compute/disks'
        $Kql | Should -Match 'microsoft.storage/storageaccounts'
    }

    It 'drops the disk term under -SkipDiskMetrics' {
        $Kql = Get-PlanWeightKql -SkipDiskMetrics
        $Kql | Should -Not -Match 'microsoft.compute/disks'
        $Kql | Should -Match 'microsoft.compute/virtualmachines'
    }

    It 'drops the storage term under -SkipStorageMetrics' {
        $Kql = Get-PlanWeightKql -SkipStorageMetrics
        $Kql | Should -Not -Match 'microsoft.storage/storageaccounts'
        $Kql | Should -Match 'microsoft.compute/virtualmachines'
    }

    # SOURCE GUARD: the storage metric is opt-in, so -Plan must derive its storage weight from -IncludeStorageMetrics.
    # If the wrapper stops doing so, -Plan silently oversizes (invisible in output), hence a guard on the source not a value.
    It 'the wrapper derives the plan storage term from the opt-in' {
        $WrapperSrc = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'Run-AllSubscriptions.ps1') -Raw

        # Mirrors the runtime gate in Extension/Metrics.ps1: collect only when opted in.
        $WrapperSrc | Should -Match '\$PlanSkipStorage\s*=\s*-not\s+\$IncludeStorageMetrics'

        # ...and that derived value is what reaches the sizer's internal switch.
        $WrapperSrc | Should -Match 'Get-PlanSubscriptionWeights[^\r\n]*-SkipStorageMetrics:\$PlanSkipStorage'
    }
}

Describe 'Get-SubscriptionHashValue' {

    It 'is deterministic for the same id' {
        $Id = '11111111-1111-1111-1111-111111111111'
        (Get-SubscriptionHashValue -SubscriptionId $Id) | Should -Be (Get-SubscriptionHashValue -SubscriptionId $Id)
    }

    It 'agrees with Get-ShardKeyForSubscription for every shard count (value % N == shard key)' {
        $Ids = @(
            '11111111-1111-1111-1111-111111111111',
            '22222222-2222-2222-2222-222222222222',
            '33333333-3333-3333-3333-333333333333',
            '44444444-4444-4444-4444-444444444444'
        )
        foreach ($Id in $Ids)
        {
            $V = Get-SubscriptionHashValue -SubscriptionId $Id
            foreach ($n in 2, 3, 5, 28, 40, 100)
            {
                [int]($V % [uint32]$n) | Should -Be (Get-ShardKeyForSubscription -SubscriptionId $Id -ShardCount $n)
            }
        }
    }
}

Describe 'Get-WeightedInventoryPlan' {

    It 'returns a Single/empty plan for zero subscriptions without throwing' {
        $P = Get-WeightedInventoryPlan -SubSeconds @{} -Streams 4 -MaxSingleMachineHours 2
        $P.Mode | Should -Be 'Single'
        $P.ShardCount | Should -Be 1
        $P.SubscriptionCount | Should -Be 0
    }

    It 'recommends a single machine for a small aggregate load' {
        $Subs = @{}
        1..10 | ForEach-Object { $Subs[[guid]::NewGuid().ToString()] = 60.0 }  # 10 x 60s
        $P = Get-WeightedInventoryPlan -SubSeconds $Subs -Streams 5 -MaxSingleMachineHours 2
        $P.Mode | Should -Be 'Single'
        $P.BusiestShardSeconds | Should -BeLessOrEqual 7200
    }

    It 'shards a large load so the busiest shard fits under the ceiling' {
        # Per-sub 300s vs the 7200s ceiling: the busiest shard fits with wide margin regardless of hash imbalance.
        # Deterministic ids (not random GUIDs) so this absolute-threshold check cannot flake on an unlucky partition.
        $Subs = @{}
        1..200 | ForEach-Object { $Subs[('{0:d8}-0000-4000-8000-000000000000' -f $_)] = 300.0 }  # 200 x 5m
        $P = Get-WeightedInventoryPlan -SubSeconds $Subs -Streams 1 -MaxSingleMachineHours 2
        $P.Mode | Should -Be 'Sharded'
        $P.ShardCount | Should -BeGreaterThan 1
        $P.ShardCount | Should -BeLessOrEqual $P.SubscriptionCount
        $P.BusiestShardSeconds | Should -BeLessOrEqual 7200
        $P.CeilingUnreachable | Should -BeFalse
    }

    It 'flags CeilingUnreachable when one subscription alone exceeds the ceiling' {
        $Subs = @{
            (([guid]::NewGuid()).ToString()) = 10000.0   # ~2.78h, over a 2h ceiling
            (([guid]::NewGuid()).ToString()) = 60.0
            (([guid]::NewGuid()).ToString()) = 60.0
        }
        $P = Get-WeightedInventoryPlan -SubSeconds $Subs -Streams 1 -MaxSingleMachineHours 2
        $P.CeilingUnreachable | Should -BeTrue
        $P.CeilingUnreachableReason | Should -Be 'single-subscription-exceeds-ceiling'
        $P.BusiestShardSeconds | Should -BeGreaterOrEqual 10000
        $P.LargestSingleSubSeconds | Should -Be 10000
        # Never recommend more shards than there are subscriptions.
        $P.ShardCount | Should -BeLessOrEqual $P.SubscriptionCount
    }

    It 'never recommends more shards than there are subscriptions (even for a hopeless load)' {
        $Subs = @{
            (([guid]::NewGuid()).ToString()) = 100000.0
            (([guid]::NewGuid()).ToString()) = 100000.0
            (([guid]::NewGuid()).ToString()) = 100000.0
        }
        $P = Get-WeightedInventoryPlan -SubSeconds $Subs -Streams 1 -MaxSingleMachineHours 2 -MaxShards 1000
        $P.CeilingUnreachable | Should -BeTrue
        $P.ShardCount | Should -BeLessOrEqual $P.SubscriptionCount
        $P.SubscriptionCount | Should -Be 3
    }

    It 'uses fewer or equal shards when more streams are available' {
        $Subs = @{}
        1..300 | ForEach-Object { $Subs[[guid]::NewGuid().ToString()] = 1800.0 }  # 300 x 30m
        $One = Get-WeightedInventoryPlan -SubSeconds $Subs -Streams 1 -MaxSingleMachineHours 2
        $Six = Get-WeightedInventoryPlan -SubSeconds $Subs -Streams 6 -MaxSingleMachineHours 2
        $Six.ShardCount | Should -BeLessOrEqual $One.ShardCount
    }

    It 'honors a tighter ceiling by recommending more (or equal) shards' {
        $Subs = @{}
        1..200 | ForEach-Object { $Subs[[guid]::NewGuid().ToString()] = 1800.0 }
        $TwoHr = Get-WeightedInventoryPlan -SubSeconds $Subs -Streams 2 -MaxSingleMachineHours 2
        $OneHr = Get-WeightedInventoryPlan -SubSeconds $Subs -Streams 2 -MaxSingleMachineHours 1
        $OneHr.ShardCount | Should -BeGreaterOrEqual $TwoHr.ShardCount
    }
}
