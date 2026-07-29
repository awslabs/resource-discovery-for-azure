#Requires -Version 7.0
# =============================================================================
# InventoryPlan.Tests.ps1
#
# OFFLINE unit tests for Get-InventoryPlan in
# Functions/RunAllSubscriptions.Functions.ps1 - the pure capacity planner behind
# the -Plan "getting started" switch. No Azure calls; the function is pure, so
# these run anywhere with Pester v5+.
#
# The contract under test: given the eligible subscription count, this host's
# recommended parallel-stream count, and a per-subscription time estimate, decide
# whether ONE machine finishes within the single-machine wall-time ceiling, or
# how many shards to split across so each machine's slice fits under it - and the
# shards must collectively cover every subscription.
# =============================================================================

BeforeAll {
    $RepoRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $RepoRoot 'Functions/RunAllSubscriptions.Functions.ps1')
}

Describe 'Get-InventoryPlan' {

    Context 'Single-machine recommendation' {
        It 'recommends a single machine for a small tenant well under the ceiling' {
            $p = Get-InventoryPlan -SubscriptionCount 20 -Streams 5 -PerSubSeconds 20 -MaxSingleMachineHours 2
            $p.Mode | Should -Be 'Single'
            $p.ShardCount | Should -Be 1
            # ceil(20/5)=4 batches * 20s = 80s
            $p.EstimatedSeconds | Should -Be 80
            $p.PerMachineSubscriptions | Should -Be 20
        }

        It 'returns a Single/empty plan for zero subscriptions without throwing' {
            $p = Get-InventoryPlan -SubscriptionCount 0 -Streams 4 -PerSubSeconds 60 -MaxSingleMachineHours 2
            $p.Mode | Should -Be 'Single'
            $p.ShardCount | Should -Be 1
            $p.EstimatedSeconds | Should -Be 0
        }

        It 'stays single-machine at exactly the ceiling (boundary is inclusive)' {
            # Choose numbers whose single-machine estimate equals the ceiling exactly:
            # 1 stream, 3600s/sub, 2 subs -> ceil(2/1)*3600 = 7200s = 2h.
            $p = Get-InventoryPlan -SubscriptionCount 2 -Streams 1 -PerSubSeconds 3600 -MaxSingleMachineHours 2
            $p.Mode | Should -Be 'Single'
            $p.EstimatedSeconds | Should -Be 7200
        }
    }

    Context 'Sharded recommendation' {
        It 'recommends sharding for a very large tenant over the ceiling' {
            $p = Get-InventoryPlan -SubscriptionCount 10000 -Streams 5 -PerSubSeconds 60 -MaxSingleMachineHours 2
            $p.Mode | Should -Be 'Sharded'
            $p.ShardCount | Should -BeGreaterThan 1
        }

        It 'sizes the shard count so each machine finishes within the ceiling' {
            foreach ($n in 500, 2000, 10000, 50000) {
                $p = Get-InventoryPlan -SubscriptionCount $n -Streams 5 -PerSubSeconds 60 -MaxSingleMachineHours 2
                if ($p.Mode -eq 'Sharded') {
                    $p.EstimatedPerMachineSeconds | Should -BeLessOrEqual (2 * 3600)
                }
            }
        }

        It 'produces shards that collectively cover every subscription (exhaustive)' {
            foreach ($n in 500, 2000, 10000, 50000) {
                $p = Get-InventoryPlan -SubscriptionCount $n -Streams 5 -PerSubSeconds 60 -MaxSingleMachineHours 2
                # ShardCount machines each taking ~PerMachineSubscriptions must be
                # able to cover the whole tenant.
                ($p.ShardCount * $p.PerMachineSubscriptions) | Should -BeGreaterOrEqual $n
            }
        }

        It 'uses fewer machines when each machine is faster (higher streams / lower per-sub time)' {
            $slow = Get-InventoryPlan -SubscriptionCount 10000 -Streams 2 -PerSubSeconds 60 -MaxSingleMachineHours 2
            $fast = Get-InventoryPlan -SubscriptionCount 10000 -Streams 8 -PerSubSeconds 20 -MaxSingleMachineHours 2
            $fast.ShardCount | Should -BeLessThan $slow.ShardCount
        }
    }

    Context 'Input guards' {
        It 'treats Streams < 1 as 1 rather than dividing by zero' {
            $p = Get-InventoryPlan -SubscriptionCount 10 -Streams 0 -PerSubSeconds 20 -MaxSingleMachineHours 2
            $p.Streams | Should -Be 1
            # ceil(10/1)=10 batches * 20s = 200s
            $p.EstimatedSeconds | Should -Be 200
        }

        It 'honors a tighter wall-time ceiling by recommending more machines' {
            $twoHr = Get-InventoryPlan -SubscriptionCount 5000 -Streams 5 -PerSubSeconds 60 -MaxSingleMachineHours 2
            $oneHr = Get-InventoryPlan -SubscriptionCount 5000 -Streams 5 -PerSubSeconds 60 -MaxSingleMachineHours 1
            $oneHr.ShardCount | Should -BeGreaterOrEqual $twoHr.ShardCount
        }

        It 'treats PerSubSeconds <= 0 as 1 rather than dividing by zero' {
            $p = Get-InventoryPlan -SubscriptionCount 10 -Streams 5 -PerSubSeconds 0 -MaxSingleMachineHours 2
            $p.PerSubSeconds | Should -Be 1
            # ceil(10/5)=2 batches * 1s = 2s, well under the ceiling => Single.
            $p.Mode | Should -Be 'Single'
            $p.EstimatedSeconds | Should -Be 2
        }

        It 'treats MaxSingleMachineHours <= 0 as the 2-hour default rather than making everything over-ceiling' {
            $p = Get-InventoryPlan -SubscriptionCount 20 -Streams 5 -PerSubSeconds 20 -MaxSingleMachineHours 0
            $p.MaxSingleMachineHours | Should -Be 2
            # Same as the 2h case: 80s single-machine estimate, under the ceiling.
            $p.Mode | Should -Be 'Single'
        }
    }
}
