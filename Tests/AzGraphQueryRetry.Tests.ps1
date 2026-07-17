# Requires -Modules Pester
# =============================================================================
# AzGraphQueryRetry.Tests.ps1
#
# Unit tests for the bounded-retry behavior of Invoke-AzGraphQuerySafe
# (Functions/ResourceInventory.Functions.ps1) - the single wrapper every
# resource-discovery Search-AzGraph call goes through.
#
# WHY THIS TEST EXISTS
# --------------------
# A dropped/changed network mid-run (VPN switch), ARM throttling, or a 5xx blip
# during discovery used to throw on the first failure and fail the whole
# subscription. The wrapper now retries TRANSIENT failures with exponential
# backoff + jitter, but fails FAST + LOUD on clearly-permanent failures (auth
# denied, malformed KQL). None of that is observable in the output zip, so -
# unlike the collector/output tests - this is a function-level unit test in the
# same style as DiagnosticScrub.Tests.ps1 (which dot-sources this same file).
#
# The seam: `Search-AzGraph` is mocked to simulate each failure class (it THROWS
# on failure, unlike the old az CLI which set a non-zero exit code), and
# `Start-Sleep` is mocked so the backoff waits are not actually incurred (tests
# run in ms, not the ~7s of real 1+2+4 backoff). Assertions are on OBSERVABLE
# behavior: how many times Search-AzGraph was invoked, whether/how long it
# slept, and what was thrown.
#
# No live Azure. Run with:
#   Invoke-Pester ./Tests/AzGraphQueryRetry.Tests.ps1 -Output Detailed
# =============================================================================

BeforeAll {
    $FunctionsFile = Join-Path (Split-Path $PSScriptRoot -Parent) 'Functions/ResourceInventory.Functions.ps1'
    if (-not (Test-Path $FunctionsFile)) { throw "ResourceInventory.Functions.ps1 not found at $FunctionsFile" }
    . $FunctionsFile

    # Offline-portability shim: Pester's `Mock -CommandName Search-AzGraph`
    # resolves the command at mock-setup time. On a clean box / CI without the
    # Az.ResourceGraph module installed that would throw CommandNotFoundException
    # before any test runs. Declaring a no-op `Search-AzGraph` function here gives
    # Mock something to intercept, so the suite is a genuine offline unit test
    # that does not depend on Az.ResourceGraph being installed.
    function Search-AzGraph { }
}

Describe 'Invoke-AzGraphQuerySafe retry behavior' {

    BeforeAll {
        # Backoff is real Start-Sleep in the function under test. Mock it so the
        # suite does not actually wait out 1+2+4s per transient case. Captured
        # invocations still let us assert retry COUNT and per-attempt duration.
        Mock -CommandName Start-Sleep -MockWith { }
    }

    Context 'Success path (Search-AzGraph returns rows)' {

        BeforeAll {
            Mock -CommandName Search-AzGraph -MockWith { [pscustomobject]@{ count_ = 42 } }
        }

        It 'returns an object exposing the .data row(s)' {
            $Result = Invoke-AzGraphQuerySafe -Query 'resources | summarize count()'
            $Result.data.count_ | Should -Be 42
        }

        It 'calls Search-AzGraph exactly once (no retries on success)' {
            Invoke-AzGraphQuerySafe -Query 'resources | summarize count()' | Out-Null
            Should -Invoke -CommandName Search-AzGraph -Exactly -Times 1
        }

        It 'never sleeps on success' {
            Invoke-AzGraphQuerySafe -Query 'resources | summarize count()' | Out-Null
            Should -Invoke -CommandName Start-Sleep -Exactly -Times 0
        }
    }

    Context '-Lowercase lowercases the payload (keys and values)' {

        BeforeAll {
            Mock -CommandName Search-AzGraph -MockWith { [pscustomobject]@{ Name = 'MyResource' } }
        }

        It 'returns lowercased keys and values' {
            $Result = Invoke-AzGraphQuerySafe -Query 'resources' -Lowercase
            $Result.data.name | Should -Be 'myresource'
        }
    }

    Context 'Transient failure (ServiceUnavailable) retries then fails loud' {

        BeforeAll {
            Mock -CommandName Search-AzGraph -MockWith { throw 'ServiceUnavailable (503) - connection reset (transient)' }
        }

        It 'throws after exhausting retries' {
            { Invoke-AzGraphQuerySafe -Query 'resources | summarize count()' } | Should -Throw
        }

        It 'attempts 4 times total (1 initial + 3 retries)' {
            try { Invoke-AzGraphQuerySafe -Query 'resources | summarize count()' | Out-Null } catch { }
            Should -Invoke -CommandName Search-AzGraph -Exactly -Times 4
        }

        It 'sleeps 3 times (once before each retry)' {
            try { Invoke-AzGraphQuerySafe -Query 'resources | summarize count()' | Out-Null } catch { }
            Should -Invoke -CommandName Start-Sleep -Exactly -Times 3
        }

        It 'surfaces the real error text and the attempt count in the throw' {
            $Msg = $null
            try { Invoke-AzGraphQuerySafe -Query 'resources | summarize count()' | Out-Null }
            catch { $Msg = $_.Exception.Message }
            $Msg | Should -Match 'after 4 attempt\(s\)'
            $Msg | Should -Match 'ServiceUnavailable'
        }
    }

    Context 'Permanent failure (AuthorizationFailed) fails fast, no retries' {

        BeforeAll {
            Mock -CommandName Search-AzGraph -MockWith { throw 'AuthorizationFailed - the client does not have authorization to perform action' }
        }

        It 'throws' {
            { Invoke-AzGraphQuerySafe -Query 'resources' } | Should -Throw
        }

        It 'calls Search-AzGraph exactly once (no retries on a permanent error)' {
            try { Invoke-AzGraphQuerySafe -Query 'resources' | Out-Null } catch { }
            Should -Invoke -CommandName Search-AzGraph -Exactly -Times 1
        }

        It 'never sleeps (fails before any backoff)' {
            try { Invoke-AzGraphQuerySafe -Query 'resources' | Out-Null } catch { }
            Should -Invoke -CommandName Start-Sleep -Exactly -Times 0
        }

        It 'reports it failed on the first attempt' {
            $Msg = $null
            try { Invoke-AzGraphQuerySafe -Query 'resources' | Out-Null } catch { $Msg = $_.Exception.Message }
            $Msg | Should -Match 'after 1 attempt\(s\)'
        }
    }

    Context 'Malformed KQL (BadRequest / SemanticError) fails fast, no retries' {

        BeforeAll {
            Mock -CommandName Search-AzGraph -MockWith { throw 'BadRequest - SemanticError: query could not be parsed' }
        }

        It 'calls Search-AzGraph exactly once' {
            try { Invoke-AzGraphQuerySafe -Query 'this ||| is not valid' | Out-Null } catch { }
            Should -Invoke -CommandName Search-AzGraph -Exactly -Times 1
        }
    }

    Context 'Throttling (429 / TooManyRequests) retries with a longer backoff' {

        BeforeAll {
            Mock -CommandName Search-AzGraph -MockWith { throw 'TooManyRequests (429) - request rate exceeded' }
        }

        It 'still attempts 4 times' {
            try { Invoke-AzGraphQuerySafe -Query 'resources' | Out-Null } catch { }
            Should -Invoke -CommandName Search-AzGraph -Exactly -Times 4
        }

        It 'every backoff is the doubled (throttled) duration, >= 2s' {
            # Non-throttled backoff would be 1,2,4 (first < 2). Throttled doubles
            # to 2,4,8, so ALL three sleeps must be >= 2s. Proves the throttle
            # branch actually took the longer-backoff path.
            try { Invoke-AzGraphQuerySafe -Query 'resources' | Out-Null } catch { }
            Should -Invoke -CommandName Start-Sleep -Exactly -Times 3 -ParameterFilter { $Seconds -ge 2 }
        }
    }
}
