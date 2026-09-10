#Requires -Version 7.0
# Offline unit tests for the sharding helpers (Get-ShardKeyForSubscription / Select-ShardSubscriptions):
# per-ShardIndex slices must be disjoint, exhaustive, deterministic, and stable to a drifting set, uncoordinated.

BeforeAll {
    $RepoRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $RepoRoot 'Functions/RunAllSubscriptions.Functions.ps1')

    # Synthetic subscription objects: only .Id matters to the partitioner. Build a
    # deterministic set of DISTINCT real-shaped GUIDs by embedding the per-item
    # seed in the first 4 bytes (guarantees uniqueness for 0..499), so the tests
    # are fully reproducible run-to-run with no id collisions.
    $script:Subs = 0..499 | ForEach-Object {
        $Bytes = [byte[]]::new(16)
        [System.BitConverter]::GetBytes([int]$_).CopyTo($Bytes, 0)
        [pscustomobject]@{ Id = ([guid]::new($Bytes)).ToString() }
    }
}

Describe 'Horizontal sharding partition helpers' {

    Context 'Get-ShardKeyForSubscription' {
        It 'returns 0 for the no-sharding case (ShardCount <= 1)' {
            Get-ShardKeyForSubscription -SubscriptionId ([guid]::NewGuid().ToString()) -ShardCount 1 | Should -Be 0
            Get-ShardKeyForSubscription -SubscriptionId ([guid]::NewGuid().ToString()) -ShardCount 0 | Should -Be 0
        }

        It 'always returns a shard in [0, ShardCount-1]' {
            foreach ($n in 2, 3, 5, 8)
            {
                foreach ($s in $script:Subs)
                {
                    $k = Get-ShardKeyForSubscription -SubscriptionId $s.Id -ShardCount $n
                    $k | Should -BeGreaterOrEqual 0
                    $k | Should -BeLessThan $n
                }
            }
        }

        It 'is deterministic - same id + count always yields the same shard' {
            foreach ($s in $script:Subs)
            {
                $A = Get-ShardKeyForSubscription -SubscriptionId $s.Id -ShardCount 7
                $B = Get-ShardKeyForSubscription -SubscriptionId $s.Id -ShardCount 7
                $A | Should -Be $B
            }
        }

        It 'is case-insensitive on the subscription id' {
            $Id = [guid]::NewGuid().ToString()
            $Lower = Get-ShardKeyForSubscription -SubscriptionId $Id.ToLower() -ShardCount 6
            $Upper = Get-ShardKeyForSubscription -SubscriptionId $Id.ToUpper() -ShardCount 6
            $Lower | Should -Be $Upper
        }
    }

    Context 'Select-ShardSubscriptions' {
        It 'ShardCount <= 1 returns the full list unchanged' {
            $Out = Select-ShardSubscriptions -Subscriptions $script:Subs -ShardIndex 0 -ShardCount 1
            $Out.Count | Should -Be $script:Subs.Count

            # ShardCount 0 hits the same '$ShardCount -le 1' no-op branch and is the
            # value the wrapper passes when not sharding, so pin it explicitly.
            $Zero = Select-ShardSubscriptions -Subscriptions $script:Subs -ShardIndex 0 -ShardCount 0
            $Zero.Count | Should -Be $script:Subs.Count
        }

        It 'partitions the tenant into DISJOINT and EXHAUSTIVE slices across all shards' {
            foreach ($n in 2, 3, 4, 6)
            {
                $Union = @()
                for ($i = 0; $i -lt $n; $i++)
                {
                    $Slice = Select-ShardSubscriptions -Subscriptions $script:Subs -ShardIndex $i -ShardCount $n
                    $Union += @($Slice.Id)
                }
                # Exhaustive: union covers every subscription exactly once.
                $Union.Count | Should -Be $script:Subs.Count
                # Disjoint: no id appears in more than one shard.
                ($Union | Sort-Object -Unique).Count | Should -Be $script:Subs.Count
                # Every original id is present in the union.
                $Missing = @($script:Subs.Id | Where-Object { $Union -notcontains $_ })
                $Missing.Count | Should -Be 0
            }
        }

        It 'is STABLE to a drifting subscription set - removing one sub does not move any other' {
            $n = 5
            # Baseline: which shard SLICE each sub actually lands in, resolved
            # through Select-ShardSubscriptions itself (not just the key helper)
            # so an unstable/positional split would be caught here - the raw key
            # helper never sees the subscription set, so it cannot.
            $Baseline = @{}
            for ($i = 0; $i -lt $n; $i++)
            {
                foreach ($s in @(Select-ShardSubscriptions -Subscriptions $script:Subs -ShardIndex $i -ShardCount $n))
                {
                    $Baseline[$s.Id] = $i
                }
            }

            # Drop one sub and add a brand-new one (simulates tenant drift between
            # two machines' Get-AzSubscription snapshots).
            $Drifted = @($script:Subs | Select-Object -Skip 1)
            $Drifted += [pscustomobject]@{ Id = [guid]::NewGuid().ToString() }

            # Re-slice the DRIFTED set the same way: every surviving sub must land
            # in the SAME shard slice as before the drift (the added sub, absent
            # from the baseline, is ignored). A positional split would move most
            # subs by one slice once the first sub is dropped, and fail here.
            for ($i = 0; $i -lt $n; $i++)
            {
                foreach ($s in @(Select-ShardSubscriptions -Subscriptions $Drifted -ShardIndex $i -ShardCount $n))
                {
                    if ($Baseline.ContainsKey($s.Id))
                    {
                        $i | Should -Be $Baseline[$s.Id]
                    }
                }
            }
        }

        It 'distributes subscriptions across shards with rough balance (no empty shard for a large set)' {
            $n = 5
            $Counts = @{}
            for ($i = 0; $i -lt $n; $i++)
            {
                $Counts[$i] = (Select-ShardSubscriptions -Subscriptions $script:Subs -ShardIndex $i -ShardCount $n).Count
            }
            # Uniform hash over 500 ids into 5 shards => ~100 each. Assert every
            # shard is non-empty and within a generous tolerance (not exact
            # balance - SHA-256 mod N is uniform, not perfectly even).
            foreach ($i in 0..($n - 1))
            {
                $Counts[$i] | Should -BeGreaterThan 40
                $Counts[$i] | Should -BeLessThan 160
            }
        }
    }
}
