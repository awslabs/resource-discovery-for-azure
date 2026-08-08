#Requires -Version 7.0
# =============================================================================
# WeightedInventoryPlan.Tests.ps1
#
# OFFLINE unit tests for the composition-aware -Plan sizing helpers in
# Functions/RunAllSubscriptions.Functions.ps1:
#   - Get-MetricQueryWeightMap   (authoritative per-type metric-query weights)
#   - Get-PlanWeightKql          (KQL builder, honors -Skip*Metrics gating)
#   - Get-SubscriptionHashValue  (must agree with Get-ShardKeyForSubscription)
#   - Get-WeightedInventoryPlan  (busiest-shard sizing over the real partition)
#
# All pure - no Azure calls - so they run anywhere with Pester v5+.
# =============================================================================

BeforeAll {
    $RepoRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $RepoRoot 'Functions/RunAllSubscriptions.Functions.ps1')
}

Describe 'Get-MetricQueryWeightMap' {

    It 'weights the dominant types per Extension/Metrics.ps1 (disk 4, VM 2, SQL 9, storage 1)' {
        $map = Get-MetricQueryWeightMap
        ($map | Where-Object { $_.Type -eq 'microsoft.compute/disks' }).Weight            | Should -Be 4
        ($map | Where-Object { $_.Type -eq 'microsoft.compute/virtualmachines' }).Weight  | Should -Be 2
        # SQL is the serverless worst case (9: the 8 every DB issues + app_cpu_billed).
        ($map | Where-Object { $_.Type -eq 'microsoft.sql/servers/databases' }).Weight    | Should -Be 9
        ($map | Where-Object { $_.Type -eq 'microsoft.storage/storageaccounts' }).Weight  | Should -Be 1
    }

    It 'gates disks and storage so the -Skip*Metrics switches can drop them' {
        $map = Get-MetricQueryWeightMap
        ($map | Where-Object { $_.Type -eq 'microsoft.compute/disks' }).Gate           | Should -Be 'Disk'
        ($map | Where-Object { $_.Type -eq 'microsoft.storage/storageaccounts' }).Gate | Should -Be 'Storage'
    }

    It 'scopes disks to attached and SQL to non-master via ExtraFilter' {
        $map = Get-MetricQueryWeightMap
        ($map | Where-Object { $_.Type -eq 'microsoft.compute/disks' }).ExtraFilter         | Should -Match 'managedBy'
        ($map | Where-Object { $_.Type -eq 'microsoft.sql/servers/databases' }).ExtraFilter | Should -Match 'master'
    }

    It 'locks the full type->weight set (drift here must be a deliberate sync with Extension/Metrics.ps1)' {
        # Golden lock: the metric-query count per type mirrors the MetricDefs.Add
        # calls in Extension/Metrics.ps1. If a metric name is added/removed there,
        # update BOTH and this expectation - a silent change would skew -Plan sizing.
        $expected = @{
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
        $map = Get-MetricQueryWeightMap
        $map.Count | Should -Be $expected.Count
        foreach ($entry in $map) {
            $expected.ContainsKey($entry.Type) | Should -BeTrue -Because "$($entry.Type) should be an expected metric-eligible type"
            $entry.Weight | Should -Be $expected[$entry.Type] -Because "weight for $($entry.Type) must match Extension/Metrics.ps1"
        }
    }

    It 'marks exactly the batchable services (VM, disk, storage, SQL, VMSS, Cosmos) as Batched' {
        # Must mirror $BatchNamespaceMap in Extension/Metrics.ps1 - only these
        # types are fetched via metrics:getBatch, so -Plan applies the batch
        # discount to just their weight and leaves the rest per-call.
        $batched = @{
            'microsoft.compute/virtualmachines'         = $true
            'microsoft.compute/disks'                   = $true
            'microsoft.storage/storageaccounts'         = $true
            'microsoft.sql/servers/databases'           = $true
            'microsoft.compute/virtualmachinescalesets' = $true
            'microsoft.documentdb/databaseaccounts'     = $true
        }
        $map = Get-MetricQueryWeightMap
        foreach ($entry in $map) {
            $expectBatched = [bool]$batched[$entry.Type]
            [bool]$entry.Batched | Should -Be $expectBatched -Because "Batched flag for $($entry.Type) must match Extension/Metrics.ps1 BatchNamespaceMap"
        }
        # Lock the batch-discount surface cardinality directly, so an accidental
        # extra Batched=$true entry is caught even if it is a new/unexpected type.
        (@($map | Where-Object { $_.Batched }).Count) | Should -Be 6
    }
}

Describe 'Get-PlanWeightKql' {

    It 'summarizes both the total and batched-only per-subscription weight' {
        $kql = Get-PlanWeightKql
        $kql | Should -Match 'summarize QueryWeight = sum\(__w\), BatchWeight = sum\(__bw\) by subscriptionId'
        $kql | Should -Match '__bw = case'
        $kql | Should -Match "microsoft.compute/virtualmachines"
    }

    It 'includes the disk and storage terms by default' {
        $kql = Get-PlanWeightKql
        $kql | Should -Match 'microsoft.compute/disks'
        $kql | Should -Match 'microsoft.storage/storageaccounts'
    }

    It 'drops the disk term under -SkipDiskMetrics' {
        $kql = Get-PlanWeightKql -SkipDiskMetrics
        $kql | Should -Not -Match 'microsoft.compute/disks'
        $kql | Should -Match 'microsoft.compute/virtualmachines'
    }

    It 'drops the storage term under -SkipStorageMetrics' {
        $kql = Get-PlanWeightKql -SkipStorageMetrics
        $kql | Should -Not -Match 'microsoft.storage/storageaccounts'
    }
}

Describe 'Get-SubscriptionHashValue' {

    It 'is deterministic for the same id' {
        $id = '11111111-1111-1111-1111-111111111111'
        (Get-SubscriptionHashValue -SubscriptionId $id) | Should -Be (Get-SubscriptionHashValue -SubscriptionId $id)
    }

    It 'agrees with Get-ShardKeyForSubscription for every shard count (value % N == shard key)' {
        $ids = @(
            '11111111-1111-1111-1111-111111111111',
            '22222222-2222-2222-2222-222222222222',
            '33333333-3333-3333-3333-333333333333',
            '44444444-4444-4444-4444-444444444444'
        )
        foreach ($id in $ids) {
            $v = Get-SubscriptionHashValue -SubscriptionId $id
            foreach ($n in 2, 3, 5, 28, 40, 100) {
                [int]($v % [uint32]$n) | Should -Be (Get-ShardKeyForSubscription -SubscriptionId $id -ShardCount $n)
            }
        }
    }
}

Describe 'Get-WeightedInventoryPlan' {

    It 'returns a Single/empty plan for zero subscriptions without throwing' {
        $p = Get-WeightedInventoryPlan -SubSeconds @{} -Streams 4 -MaxSingleMachineHours 2
        $p.Mode | Should -Be 'Single'
        $p.ShardCount | Should -Be 1
        $p.SubscriptionCount | Should -Be 0
    }

    It 'recommends a single machine for a small aggregate load' {
        $subs = @{}
        1..10 | ForEach-Object { $subs[[guid]::NewGuid().ToString()] = 60.0 }  # 10 x 60s
        $p = Get-WeightedInventoryPlan -SubSeconds $subs -Streams 5 -MaxSingleMachineHours 2
        $p.Mode | Should -Be 'Single'
        $p.BusiestShardSeconds | Should -BeLessOrEqual 7200
    }

    It 'shards a large load so the busiest shard fits under the ceiling' {
        # Per-sub 300s is small vs the 7200s ceiling, so the busiest shard fits
        # with wide margin regardless of hash imbalance (it would take >24 subs in
        # ONE bucket to breach, impossible with 200) - keeping this robust now
        # that the shard count is capped at the subscription count.
        # Deterministic ids (not random GUIDs) so this absolute-threshold check
        # cannot flake on an unlucky hash partition.
        $subs = @{}
        1..200 | ForEach-Object { $subs[('{0:d8}-0000-4000-8000-000000000000' -f $_)] = 300.0 }  # 200 x 5m
        $p = Get-WeightedInventoryPlan -SubSeconds $subs -Streams 1 -MaxSingleMachineHours 2
        $p.Mode | Should -Be 'Sharded'
        $p.ShardCount | Should -BeGreaterThan 1
        $p.ShardCount | Should -BeLessOrEqual $p.SubscriptionCount
        $p.BusiestShardSeconds | Should -BeLessOrEqual 7200
        $p.CeilingUnreachable | Should -BeFalse
    }

    It 'flags CeilingUnreachable when one subscription alone exceeds the ceiling' {
        $subs = @{
            (([guid]::NewGuid()).ToString()) = 10000.0   # ~2.78h, over a 2h ceiling
            (([guid]::NewGuid()).ToString()) = 60.0
            (([guid]::NewGuid()).ToString()) = 60.0
        }
        $p = Get-WeightedInventoryPlan -SubSeconds $subs -Streams 1 -MaxSingleMachineHours 2
        $p.CeilingUnreachable | Should -BeTrue
        $p.CeilingUnreachableReason | Should -Be 'single-subscription-exceeds-ceiling'
        $p.BusiestShardSeconds | Should -BeGreaterOrEqual 10000
        $p.LargestSingleSubSeconds | Should -Be 10000
        # Never recommend more shards than there are subscriptions.
        $p.ShardCount | Should -BeLessOrEqual $p.SubscriptionCount
    }

    It 'never recommends more shards than there are subscriptions (even for a hopeless load)' {
        $subs = @{
            (([guid]::NewGuid()).ToString()) = 100000.0
            (([guid]::NewGuid()).ToString()) = 100000.0
            (([guid]::NewGuid()).ToString()) = 100000.0
        }
        $p = Get-WeightedInventoryPlan -SubSeconds $subs -Streams 1 -MaxSingleMachineHours 2 -MaxShards 1000
        $p.CeilingUnreachable | Should -BeTrue
        $p.ShardCount | Should -BeLessOrEqual $p.SubscriptionCount
        $p.SubscriptionCount | Should -Be 3
    }

    It 'uses fewer or equal shards when more streams are available' {
        $subs = @{}
        1..300 | ForEach-Object { $subs[[guid]::NewGuid().ToString()] = 1800.0 }  # 300 x 30m
        $one = Get-WeightedInventoryPlan -SubSeconds $subs -Streams 1 -MaxSingleMachineHours 2
        $six = Get-WeightedInventoryPlan -SubSeconds $subs -Streams 6 -MaxSingleMachineHours 2
        $six.ShardCount | Should -BeLessOrEqual $one.ShardCount
    }

    It 'honors a tighter ceiling by recommending more (or equal) shards' {
        $subs = @{}
        1..200 | ForEach-Object { $subs[[guid]::NewGuid().ToString()] = 1800.0 }
        $twoHr = Get-WeightedInventoryPlan -SubSeconds $subs -Streams 2 -MaxSingleMachineHours 2
        $oneHr = Get-WeightedInventoryPlan -SubSeconds $subs -Streams 2 -MaxSingleMachineHours 1
        $oneHr.ShardCount | Should -BeGreaterOrEqual $twoHr.ShardCount
    }
}
