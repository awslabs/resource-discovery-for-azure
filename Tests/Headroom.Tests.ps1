#Requires -Version 7.0
# =============================================================================
# Headroom.Tests.ps1
#
# OFFLINE unit tests for Get-HeadroomAdjustedConcurrency in
# Functions/RunAllSubscriptions.Functions.ps1 - the pure helper behind the
# -HeadRoom API-throttle knob. No Azure calls; the function is pure, so these
# run anywhere with Pester v5+.
#
# Contract under test: given a chosen metrics-collection concurrency and an
# API-headroom percentage, return the concurrency scaled DOWN to leave that
# percentage of the shared Azure API throttle budget in reserve - floored, never
# below 1, with the percentage clamped to [0,90] and 0 a no-op.
# =============================================================================

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
