#Requires -Version 7.0
# =============================================================================
# Sharding.Tests.ps1
#
# OFFLINE unit tests for the horizontal-sharding partition helpers in
# Functions/RunAllSubscriptions.Functions.ps1 (Get-ShardKeyForSubscription /
# Select-ShardSubscriptions). No Azure calls, no zip - the helpers are pure, so
# these run anywhere with just Pester v5+.
#
# The properties proven here are the correctness contract horizontal scaling
# relies on: N machines each run the same command with a different -ShardIndex,
# and their slices must be disjoint, exhaustive, deterministic, and stable to a
# drifting visible-subscription set - WITHOUT the machines coordinating.
# =============================================================================

BeforeAll {
    $RepoRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $RepoRoot 'Functions/RunAllSubscriptions.Functions.ps1')

    # Synthetic subscription objects: only .Id matters to the partitioner. Build a
    # deterministic set of DISTINCT real-shaped GUIDs by embedding the per-item
    # seed in the first 4 bytes (guarantees uniqueness for 0..499), so the tests
    # are fully reproducible run-to-run with no id collisions.
    $script:Subs = 0..499 | ForEach-Object {
        $bytes = [byte[]]::new(16)
        [System.BitConverter]::GetBytes([int]$_).CopyTo($bytes, 0)
        [pscustomobject]@{ Id = ([guid]::new($bytes)).ToString() }
    }
}

Describe 'Horizontal sharding partition helpers' {

    Context 'Get-ShardKeyForSubscription' {
        It 'returns 0 for the no-sharding case (ShardCount <= 1)' {
            Get-ShardKeyForSubscription -SubscriptionId ([guid]::NewGuid().ToString()) -ShardCount 1 | Should -Be 0
            Get-ShardKeyForSubscription -SubscriptionId ([guid]::NewGuid().ToString()) -ShardCount 0 | Should -Be 0
        }

        It 'always returns a shard in [0, ShardCount-1]' {
            foreach ($n in 2, 3, 5, 8) {
                foreach ($s in $script:Subs) {
                    $k = Get-ShardKeyForSubscription -SubscriptionId $s.Id -ShardCount $n
                    $k | Should -BeGreaterOrEqual 0
                    $k | Should -BeLessThan $n
                }
            }
        }

        It 'is deterministic - same id + count always yields the same shard' {
            foreach ($s in $script:Subs) {
                $a = Get-ShardKeyForSubscription -SubscriptionId $s.Id -ShardCount 7
                $b = Get-ShardKeyForSubscription -SubscriptionId $s.Id -ShardCount 7
                $a | Should -Be $b
            }
        }

        It 'is case-insensitive on the subscription id' {
            $id = [guid]::NewGuid().ToString()
            $lower = Get-ShardKeyForSubscription -SubscriptionId $id.ToLower() -ShardCount 6
            $upper = Get-ShardKeyForSubscription -SubscriptionId $id.ToUpper() -ShardCount 6
            $lower | Should -Be $upper
        }
    }

    Context 'Select-ShardSubscriptions' {
        It 'ShardCount <= 1 returns the full list unchanged' {
            $out = Select-ShardSubscriptions -Subscriptions $script:Subs -ShardIndex 0 -ShardCount 1
            $out.Count | Should -Be $script:Subs.Count
        }

        It 'partitions the tenant into DISJOINT and EXHAUSTIVE slices across all shards' {
            foreach ($n in 2, 3, 4, 6) {
                $union = @()
                for ($i = 0; $i -lt $n; $i++) {
                    $slice = Select-ShardSubscriptions -Subscriptions $script:Subs -ShardIndex $i -ShardCount $n
                    $union += @($slice.Id)
                }
                # Exhaustive: union covers every subscription exactly once.
                $union.Count | Should -Be $script:Subs.Count
                # Disjoint: no id appears in more than one shard.
                ($union | Sort-Object -Unique).Count | Should -Be $script:Subs.Count
                # Every original id is present in the union.
                $missing = @($script:Subs.Id | Where-Object { $union -notcontains $_ })
                $missing.Count | Should -Be 0
            }
        }

        It 'is STABLE to a drifting subscription set - removing one sub does not move any other' {
            $n = 5
            # Baseline: which shard each surviving sub lands in.
            $baseline = @{}
            foreach ($s in $script:Subs) { $baseline[$s.Id] = Get-ShardKeyForSubscription -SubscriptionId $s.Id -ShardCount $n }

            # Drop one sub and add a brand-new one (simulates tenant drift between
            # two machines' Get-AzSubscription snapshots).
            $drifted = @($script:Subs | Select-Object -Skip 1)
            $drifted += [pscustomobject]@{ Id = [guid]::NewGuid().ToString() }

            foreach ($s in $drifted) {
                if ($baseline.ContainsKey($s.Id)) {
                    # A surviving sub must map to the SAME shard as before.
                    (Get-ShardKeyForSubscription -SubscriptionId $s.Id -ShardCount $n) | Should -Be $baseline[$s.Id]
                }
            }
        }

        It 'distributes subscriptions across shards with rough balance (no empty shard for a large set)' {
            $n = 5
            $counts = @{}
            for ($i = 0; $i -lt $n; $i++) {
                $counts[$i] = (Select-ShardSubscriptions -Subscriptions $script:Subs -ShardIndex $i -ShardCount $n).Count
            }
            # Uniform hash over 500 ids into 5 shards => ~100 each. Assert every
            # shard is non-empty and within a generous tolerance (not exact
            # balance - SHA-256 mod N is uniform, not perfectly even).
            foreach ($i in 0..($n - 1)) {
                $counts[$i] | Should -BeGreaterThan 40
                $counts[$i] | Should -BeLessThan 160
            }
        }
    }
}
