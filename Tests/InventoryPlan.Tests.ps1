#Requires -Version 7.0
# Offline unit tests for Get-InventoryPlan (pure capacity planner behind -Plan): decides one machine vs
# how many shards fit under the single-machine wall-time ceiling, and that the shards cover every subscription.

BeforeAll {
    $RepoRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $RepoRoot 'Functions/RunAllSubscriptions.Functions.ps1')
}

Describe 'Get-InventoryPlan' {

    Context 'Single-machine recommendation' {
        It 'recommends a single machine for a small tenant well under the ceiling' {
            $Plan = Get-InventoryPlan -SubscriptionCount 20 -Streams 5 -PerSubSeconds 20 -MaxSingleMachineHours 2
            $Plan.Mode | Should -Be 'Single'
            $Plan.ShardCount | Should -Be 1
            # ceil(20/5)=4 batches * 20s = 80s
            $Plan.EstimatedSeconds | Should -Be 80
            $Plan.PerMachineSubscriptions | Should -Be 20
        }

        It 'returns a Single/empty plan for zero subscriptions without throwing' {
            $Plan = Get-InventoryPlan -SubscriptionCount 0 -Streams 4 -PerSubSeconds 60 -MaxSingleMachineHours 2
            $Plan.Mode | Should -Be 'Single'
            $Plan.ShardCount | Should -Be 1
            $Plan.EstimatedSeconds | Should -Be 0
        }

        It 'stays single-machine at exactly the ceiling (boundary is inclusive)' {
            # Choose numbers whose single-machine estimate equals the ceiling exactly:
            # 1 stream, 3600s/sub, 2 subs -> ceil(2/1)*3600 = 7200s = 2h.
            $Plan = Get-InventoryPlan -SubscriptionCount 2 -Streams 1 -PerSubSeconds 3600 -MaxSingleMachineHours 2
            $Plan.Mode | Should -Be 'Single'
            $Plan.EstimatedSeconds | Should -Be 7200
        }
    }

    Context 'Sharded recommendation' {
        It 'recommends sharding for a very large tenant over the ceiling' {
            $Plan = Get-InventoryPlan -SubscriptionCount 10000 -Streams 5 -PerSubSeconds 60 -MaxSingleMachineHours 2
            $Plan.Mode | Should -Be 'Sharded'
            $Plan.ShardCount | Should -BeGreaterThan 1
        }

        It 'sizes the shard count so each machine finishes within the ceiling' {
            foreach ($n in 500, 2000, 10000, 50000)
            {
                $Plan = Get-InventoryPlan -SubscriptionCount $n -Streams 5 -PerSubSeconds 60 -MaxSingleMachineHours 2
                if ($Plan.Mode -eq 'Sharded')
                {
                    $Plan.EstimatedPerMachineSeconds | Should -BeLessOrEqual (2 * 3600)
                }
            }
        }

        It 'produces shards that collectively cover every subscription (exhaustive)' {
            foreach ($n in 500, 2000, 10000, 50000)
            {
                $Plan = Get-InventoryPlan -SubscriptionCount $n -Streams 5 -PerSubSeconds 60 -MaxSingleMachineHours 2
                # ShardCount machines each taking ~PerMachineSubscriptions must be
                # able to cover the whole tenant.
                ($Plan.ShardCount * $Plan.PerMachineSubscriptions) | Should -BeGreaterOrEqual $n
            }
        }

        It 'uses fewer machines when each machine is faster (higher streams / lower per-sub time)' {
            $Slow = Get-InventoryPlan -SubscriptionCount 10000 -Streams 2 -PerSubSeconds 60 -MaxSingleMachineHours 2
            $Fast = Get-InventoryPlan -SubscriptionCount 10000 -Streams 8 -PerSubSeconds 20 -MaxSingleMachineHours 2
            $Fast.ShardCount | Should -BeLessThan $Slow.ShardCount
        }
    }

    Context 'Input guards' {
        It 'treats Streams < 1 as 1 rather than dividing by zero' {
            $Plan = Get-InventoryPlan -SubscriptionCount 10 -Streams 0 -PerSubSeconds 20 -MaxSingleMachineHours 2
            $Plan.Streams | Should -Be 1
            # ceil(10/1)=10 batches * 20s = 200s
            $Plan.EstimatedSeconds | Should -Be 200
        }

        It 'honors a tighter wall-time ceiling by recommending more machines' {
            $TwoHr = Get-InventoryPlan -SubscriptionCount 5000 -Streams 5 -PerSubSeconds 60 -MaxSingleMachineHours 2
            $OneHr = Get-InventoryPlan -SubscriptionCount 5000 -Streams 5 -PerSubSeconds 60 -MaxSingleMachineHours 1
            $OneHr.ShardCount | Should -BeGreaterOrEqual $TwoHr.ShardCount
        }

        It 'treats PerSubSeconds <= 0 as 1 rather than dividing by zero' {
            $Plan = Get-InventoryPlan -SubscriptionCount 10 -Streams 5 -PerSubSeconds 0 -MaxSingleMachineHours 2
            $Plan.PerSubSeconds | Should -Be 1
            # ceil(10/5)=2 batches * 1s = 2s, well under the ceiling => Single.
            $Plan.Mode | Should -Be 'Single'
            $Plan.EstimatedSeconds | Should -Be 2
        }

        It 'treats MaxSingleMachineHours <= 0 as the 2-hour default rather than making everything over-ceiling' {
            $Plan = Get-InventoryPlan -SubscriptionCount 20 -Streams 5 -PerSubSeconds 20 -MaxSingleMachineHours 0
            $Plan.MaxSingleMachineHours | Should -Be 2
            # Same as the 2h case: 80s single-machine estimate, under the ceiling.
            $Plan.Mode | Should -Be 'Single'
        }
    }
}

Describe 'Get-PlanShardDirective' {

    Context 'Single-machine plan (ShardCount = 1)' {
        It 'emits the machine-readable token as 1 and NO IMPORTANT directive' {
            $Lines = @(Get-PlanShardDirective -ShardCount 1)
            $Lines | Should -Contain 'PLAN_SHARDCOUNT=1'
            ($Lines | Where-Object { $_ -like 'IMPORTANT:*' }).Count | Should -Be 0
        }

        It 'never recommends a shard count below 1 (guards ShardCount 0)' {
            $Lines = @(Get-PlanShardDirective -ShardCount 0)
            $Lines | Should -Contain 'PLAN_SHARDCOUNT=1'
        }
    }

    Context 'Sharded plan (ShardCount > 1)' {
        It 'emits the token equal to the shard count and an IMPORTANT full-range directive (large-tenant example: 28)' {
            $Lines = @(Get-PlanShardDirective -ShardCount 28)
            $Lines | Should -Contain 'PLAN_SHARDCOUNT=28'
            $Imp = @($Lines | Where-Object { $_ -like 'IMPORTANT:*' })
            $Imp.Count | Should -Be 1
            # The required range must be spelled out as 0 through N-1 / 0..N-1 so it
            # cannot be misread as the 10-line printed sample.
            $Imp[0] | Should -Match '0 through 27'
            $Imp[0] | Should -Match '0\.\.27'
            # And it must warn that un-run indices are silently dropped.
            $Imp[0] | Should -Match 'SILENTLY'
        }

        It 'spells the range end as ShardCount-1 at the sharding boundary (2 shards -> 0 through 1)' {
            $Lines = @(Get-PlanShardDirective -ShardCount 2)
            $Lines | Should -Contain 'PLAN_SHARDCOUNT=2'
            $Imp = @($Lines | Where-Object { $_ -like 'IMPORTANT:*' })
            $Imp[0] | Should -Match '0 through 1\b'
        }

        It 'the token line is always exactly parseable as PLAN_SHARDCOUNT=<int> (wrapper contract)' {
            foreach ($n in 2, 5, 28, 100)
            {
                $Token = @(Get-PlanShardDirective -ShardCount $n) | Where-Object { $_ -like 'PLAN_SHARDCOUNT=*' }
                $Token | Should -Be ("PLAN_SHARDCOUNT={0}" -f $n)
                # It must parse back to the exact integer a wrapper needs.
                [int]($Token -replace '^PLAN_SHARDCOUNT=', '') | Should -Be $n
            }
        }
    }
}
