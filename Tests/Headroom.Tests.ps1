#Requires -Version 7.0
# Offline unit tests for Get-HeadroomAdjustedConcurrency (pure, behind -HeadRoom): scales concurrency DOWN
# to reserve that % of the API throttle budget - floored, never below 1, % clamped to [0,90], 0 a no-op.

BeforeAll {
    $RepoRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $RepoRoot 'Functions/RunAllSubscriptions.Functions.ps1')
}

Describe 'Get-HeadroomAdjustedConcurrency' {

    Context 'No-op and basic scaling' {
        It 'returns the concurrency unchanged when HeadRoom is 0 (default no-op)' {
            Get-HeadroomAdjustedConcurrency -Concurrency 16 -HeadRoomPercent 0 | Should -Be 16
        }

        It 'leaves ~20% in reserve (floor of 80% of 16 = 12)' {
            Get-HeadroomAdjustedConcurrency -Concurrency 16 -HeadRoomPercent 20 | Should -Be 12
        }

        It 'leaves ~50% in reserve (floor of 50% of 6 = 3)' {
            Get-HeadroomAdjustedConcurrency -Concurrency 6 -HeadRoomPercent 50 | Should -Be 3
        }

        It 'floors rather than rounds (80% of 6 = 4.8 -> 4)' {
            Get-HeadroomAdjustedConcurrency -Concurrency 6 -HeadRoomPercent 20 | Should -Be 4
        }

        It 'is monotonic - more headroom never increases the result' {
            $Prev = [int]::MaxValue
            foreach ($h in 0, 10, 20, 30, 50, 70, 90)
            {
                $Cur = Get-HeadroomAdjustedConcurrency -Concurrency 16 -HeadRoomPercent $h
                $Cur | Should -BeLessOrEqual $Prev
                $Prev = $Cur
            }
        }
    }

    Context 'Floors and clamps' {
        It 'never returns less than 1 even at maximum headroom on a small concurrency' {
            Get-HeadroomAdjustedConcurrency -Concurrency 1 -HeadRoomPercent 90 | Should -Be 1
        }

        It 'never returns less than 1 for a mid concurrency at max headroom (10% of 6 = 0.6 -> floored 0 -> clamped 1)' {
            Get-HeadroomAdjustedConcurrency -Concurrency 6 -HeadRoomPercent 90 | Should -Be 1
        }

        It 'clamps a HeadRoomPercent above 90 down to 90' {
            $AtNinety = Get-HeadroomAdjustedConcurrency -Concurrency 100 -HeadRoomPercent 90
            $Above = Get-HeadroomAdjustedConcurrency -Concurrency 100 -HeadRoomPercent 999
            $Above | Should -Be $AtNinety
            $AtNinety | Should -Be 10
        }

        It 'clamps a negative HeadRoomPercent up to 0 (no reduction)' {
            Get-HeadroomAdjustedConcurrency -Concurrency 16 -HeadRoomPercent -50 | Should -Be 16
        }

        It 'treats a concurrency below 1 as 1' {
            Get-HeadroomAdjustedConcurrency -Concurrency 0 -HeadRoomPercent 20 | Should -Be 1
        }
    }
}

Describe 'Get-ParallelismForHost' {
    # The sizing rules behind the wrapper's auto-tuning, free of host reads.

    It 'starts from half the vCPUs, between 1 and 6' {
        (Get-ParallelismForHost -VCpu 1).Streams | Should -Be 1
        (Get-ParallelismForHost -VCpu 8).Streams | Should -Be 4
        (Get-ParallelismForHost -VCpu 32).Streams | Should -Be 6
        (Get-ParallelismForHost -VCpu 8).StreamsLimitedBy | Should -Be 'vCPU'
    }

    It 'caps streams by AVAILABLE memory, keeping 1 GB back, at -StreamMemoryGB per stream' {
        # 8 vCPU wants 4 streams; 5 GB available - 1 GB = 4 GB, at 2 GB each = 2 streams.
        $R = Get-ParallelismForHost -VCpu 8 -RamGB 32 -AvailableGB 5 -StreamMemoryGB 2
        $R.Streams | Should -Be 2
        $R.StreamsByMemory | Should -Be 2
        $R.MemoryBasis | Should -Be 'available'
        $R.StreamsLimitedBy | Should -Be 'memory'
        # The same host with more memory free is limited by vCPU again.
        (Get-ParallelismForHost -VCpu 8 -RamGB 32 -AvailableGB 20 -StreamMemoryGB 2).Streams | Should -Be 4
        # A smaller per-stream allowance admits more streams.
        (Get-ParallelismForHost -VCpu 8 -RamGB 32 -AvailableGB 5 -StreamMemoryGB 1).Streams | Should -Be 4
    }

    It 'falls back to total RAM less 2 GB when available memory is unreadable' {
        $R = Get-ParallelismForHost -VCpu 8 -RamGB 6 -AvailableGB 0 -StreamMemoryGB 2
        $R.MemoryBasis | Should -Be 'total'
        $R.Streams | Should -Be 2
    }

    It 'never goes below 1 stream, however little memory is free' {
        (Get-ParallelismForHost -VCpu 8 -AvailableGB 1.2 -StreamMemoryGB 2).Streams | Should -Be 1
    }

    It 'uses vCPU alone when no memory figure is known' {
        $R = Get-ParallelismForHost -VCpu 8
        $R.MemoryBasis | Should -Be 'none'
        $R.Streams | Should -Be 4
    }

    It 'never starts more streams than there are subscriptions' {
        $R = Get-ParallelismForHost -VCpu 16 -AvailableGB 64 -SubscriptionCount 3
        $R.Streams | Should -Be 3
        $R.StreamsLimitedBy | Should -Be 'subscriptions'
    }

    It 'gives each stream 2 calls per vCPU (6-16), as a single stream has always had' {
        (Get-ParallelismForHost -VCpu 8 -AvailableGB 64 -SubscriptionCount 1).Concurrency | Should -Be 16
        (Get-ParallelismForHost -VCpu 2 -AvailableGB 64).Concurrency | Should -Be 6
        (Get-ParallelismForHost -VCpu 32 -AvailableGB 64 -SubscriptionCount 1).PerStreamConcurrency | Should -Be 16
    }

    It 'cuts the per-stream figure only when the streams together would pass the 48-call host cap' {
        # 8 vCPU, 4 streams: 4 x 16 = 64 > 48, so each stream gets 12 (48 in flight; was 64).
        $R = Get-ParallelismForHost -VCpu 8 -AvailableGB 64
        $R.Streams | Should -Be 4
        $R.TotalConcurrencyCap | Should -Be 48
        $R.Concurrency | Should -Be 12
        # 6 vCPU, 3 streams: 3 x 12 = 36, under the cap, so nothing is cut.
        (Get-ParallelismForHost -VCpu 6 -AvailableGB 64).Concurrency | Should -Be 12
        # 32 vCPU, 6 streams: 6 x 16 = 96 > 48, so 8 each (48 in flight), not 2 each.
        $Big = Get-ParallelismForHost -VCpu 32 -AvailableGB 64
        $Big.Streams | Should -Be 6
        $Big.Concurrency | Should -Be 8
        ($Big.Concurrency * $Big.Streams) | Should -BeLessOrEqual $Big.TotalConcurrencyCap
    }
}

Describe 'Get-PerStreamConcurrency' {
    It 'returns the per-stream figure while the streams fit under the cap' {
        Get-PerStreamConcurrency -PerStreamConcurrency 16 -Streams 3 -TotalCap 48 | Should -Be 16
        Get-PerStreamConcurrency -PerStreamConcurrency 16 -Streams 1 -TotalCap 48 | Should -Be 16
    }

    It 'cuts to an equal share of the cap when the streams would pass it, rounding down' {
        Get-PerStreamConcurrency -PerStreamConcurrency 16 -Streams 4 -TotalCap 48 | Should -Be 12
        Get-PerStreamConcurrency -PerStreamConcurrency 16 -Streams 5 -TotalCap 48 | Should -Be 9
    }

    It 'never gives a stream fewer than 2 calls, and treats 0 streams as 1' {
        Get-PerStreamConcurrency -PerStreamConcurrency 16 -Streams 40 -TotalCap 48 | Should -Be 2
        Get-PerStreamConcurrency -PerStreamConcurrency 6 -Streams 0 -TotalCap 48 | Should -Be 6
    }
}

Describe 'Get-RecommendedParallelism on this host' {
    It 'reads the host and returns a usable recommendation' {
        $R = Get-RecommendedParallelism -StreamMemoryGB 2 -SubscriptionCount 5
        $R.VCpu | Should -BeGreaterOrEqual 1
        $R.Streams | Should -BeGreaterOrEqual 1
        $R.Streams | Should -BeLessOrEqual 5
        $R.Concurrency | Should -BeGreaterOrEqual 2
        $R.AvailableGB | Should -BeGreaterOrEqual 0
    }
}

Describe 'Run-AllSubscriptions.ps1 applies the sizing' {
    BeforeAll {
        $WrapPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Run-AllSubscriptions.ps1'
        $script:WrapSrc = Get-Content -Raw -LiteralPath $WrapPath
        $script:WrapAst = [System.Management.Automation.Language.Parser]::ParseFile($WrapPath, [ref]$null, [ref]$null)
        function Get-WrapStatement([string]$StartsWith)
        {
            $Node = $script:WrapAst.Find({ param($N) $N -is [System.Management.Automation.Language.StatementAst] -and $N.Parent -is [System.Management.Automation.Language.NamedBlockAst] -and $N.Extent.Text.StartsWith($StartsWith) }, $true)
            if (-not $Node) { throw "statement not found: $StartsWith" }
            $Node.Extent.Text
        }
        # The three top-level statements that size the run, executed as written.
        $script:SizingText = (@(
                (Get-WrapStatement '$SubscriptionsToRun = '),
                (Get-WrapStatement '$ConcurrencyStreams = '),
                (Get-WrapStatement 'if ($ConcurrencyAuto) { $ConcurrencyLimit = ')
            ) -join [Environment]::NewLine)
        # Run them in a scriptblock whose parameters are the variables the statements read.
        $script:SizingBlock = [scriptblock]::Create(
            'param($Subscriptions, $CompletedIds, $Resume, $ParallelStreams, $ConcurrencyAuto, $ConcurrencyLimit, $AutoTune)' + [Environment]::NewLine +
            $script:SizingText + [Environment]::NewLine +
            '[pscustomobject]@{ ToRun = $SubscriptionsToRun; Streams = $ConcurrencyStreams; Limit = $ConcurrencyLimit }')
        function Invoke-Sizing([int]$Total, [string[]]$Completed, [bool]$Resume, [int]$Streams, [bool]$ConcurrencyAuto = $true)
        {
            $Subs = @(1..$Total | ForEach-Object { [pscustomobject]@{ Id = "s$_" } })
            $Tune = [pscustomobject]@{ PerStreamConcurrency = 16; TotalConcurrencyCap = 48 }
            & $script:SizingBlock $Subs @($Completed) $Resume $Streams $ConcurrencyAuto 6 $Tune
        }
    }

    It 'declares -StreamMemoryGB and sizes for the subscriptions still to run' {
        $script:WrapSrc | Should -Match '\[double\]\$StreamMemoryGB = 2'
        $script:WrapSrc | Should -Match 'Get-RecommendedParallelism -StreamMemoryGB \$StreamMemoryGB -SubscriptionCount \$SubscriptionsToRun'
    }

    It 'cuts each stream back only when 4 streams x 16 would pass the 48 cap' {
        $R = Invoke-Sizing -Total 84 -Completed @() -Resume $false -Streams 4
        $R.Streams | Should -Be 4
        $R.Limit | Should -Be 12
    }

    It 'counts only the subscriptions left to run under -Resume' {
        # 84 in scope, 83 done: one stream, never cut (was 4 calls when every subscription was counted).
        $Done = @(1..83 | ForEach-Object { "s$_" })
        $R = Invoke-Sizing -Total 84 -Completed $Done -Resume $true -Streams 4
        $R.ToRun | Should -Be 1
        $R.Streams | Should -Be 1
        $R.Limit | Should -Be 16
        # Without -Resume the completed list is ignored, as the launch loop ignores it.
        (Invoke-Sizing -Total 84 -Completed $Done -Resume $false -Streams 4).ToRun | Should -Be 84
    }

    It 'divides an explicit -ParallelStreams the same way, and leaves an explicit -ConcurrencyLimit alone' {
        (Invoke-Sizing -Total 84 -Completed @() -Resume $false -Streams 6).Limit | Should -Be 8
        (Invoke-Sizing -Total 84 -Completed @() -Resume $false -Streams 6 -ConcurrencyAuto $false).Limit | Should -Be 6
    }

    It 'never cuts the one stream left when Start-Job is unavailable' {
        $script:WrapSrc | Should -Match '(?s)\$ParallelStreams = 1\s*if \(\$ConcurrencyAuto\)\s*\{[^}]*Get-PerStreamConcurrency -PerStreamConcurrency \$AutoTune\.PerStreamConcurrency -Streams 1'
    }
}
