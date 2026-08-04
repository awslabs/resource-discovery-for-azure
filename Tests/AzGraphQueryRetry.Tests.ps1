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
# run in ms, not the many minutes of real backoff a full 30-retry exhaustion
# would incur). Assertions are on OBSERVABLE
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

        It 'attempts 31 times total (1 initial + 30 retries)' {
            try { Invoke-AzGraphQuerySafe -Query 'resources | summarize count()' | Out-Null } catch { }
            Should -Invoke -CommandName Search-AzGraph -Exactly -Times 31
        }

        It 'sleeps 30 times (once before each retry)' {
            try { Invoke-AzGraphQuerySafe -Query 'resources | summarize count()' | Out-Null } catch { }
            Should -Invoke -CommandName Start-Sleep -Exactly -Times 30
        }

        It 'surfaces the real error text and the attempt count in the throw' {
            $Msg = $null
            try { Invoke-AzGraphQuerySafe -Query 'resources | summarize count()' | Out-Null }
            catch { $Msg = $_.Exception.Message }
            $Msg | Should -Match 'after 31 attempt\(s\)'
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

        It 'still attempts 31 times' {
            try { Invoke-AzGraphQuerySafe -Query 'resources' | Out-Null } catch { }
            Should -Invoke -CommandName Search-AzGraph -Exactly -Times 31
        }

        It 'every backoff is the doubled (throttled) duration, >= 2s' {
            # Non-throttled backoff starts 1,2,4 (first < 2). Throttled doubles it,
            # so the FIRST sleep is >= 2s; assert every one of the 30 throttled
            # sleeps is >= 2s. Proves the throttle branch took the longer-backoff
            # path (the per-attempt cap means later sleeps sit at the 60s ceiling).
            # These string-throw mocks carry no .Response, so Get-RetryWaitSeconds
            # finds no server header and returns the exponential fallback unchanged
            # - the timing assertion still holds.
            try { Invoke-AzGraphQuerySafe -Query 'resources' | Out-Null } catch { }
            Should -Invoke -CommandName Start-Sleep -Exactly -Times 30 -ParameterFilter { $Seconds -ge 2 }
        }
    }
}

Describe 'Get-RetryWaitSeconds header honoring' {

    BeforeAll {
        # Build a synthetic throttling exception whose .Response.Headers (or
        # .InnerException.Response.Headers) mimics the real shape: each header
        # value is an IEnumerable[string] (a single-element string array).
        # PSCustomObject property access with no StrictMode returns $null for
        # absent members, so the helper's null guards exercise the same fallback
        # path they do in production. Defined in BeforeAll so it is available to
        # the It scriptblocks at run time (Pester v5 scoping).
        function New-FakeThrottleException
        {
            param([hashtable]$Headers, [switch]$OnInner)

            # A PowerShell [hashtable] is NOT auto-enumerated by foreach, but the
            # real ARG/consumption/metrics header containers are a
            # Dictionary[string,IEnumerable[string]] / HttpResponseHeaders, which
            # DO enumerate as KeyValuePair<string,IEnumerable[string]>. Convert to
            # a generic Dictionary (values as string[]) so the fake faithfully
            # matches the shape Get-RetryWaitSeconds walks in production.
            $Dict = [System.Collections.Generic.Dictionary[string, object]]::new()
            foreach ($Key in $Headers.Keys) { $Dict[$Key] = [string[]]@($Headers[$Key]) }
            $ResponseObj = [pscustomobject]@{ Headers = $Dict }
            if ($OnInner)
            {
                [pscustomobject]@{ InnerException = [pscustomobject]@{ Response = $ResponseObj } }
            }
            else
            {
                [pscustomobject]@{ Response = $ResponseObj }
            }
        }
    }

    It 'honors an integer Retry-After header (in seconds)' {
        $Ex = New-FakeThrottleException -Headers @{ 'Retry-After' = @('5') }
        Get-RetryWaitSeconds -Exception $Ex -FallbackSeconds 30 | Should -Be 5
    }

    It 'honors the consumption ratelimit header' {
        $Ex = New-FakeThrottleException -Headers @{ 'x-ms-ratelimit-microsoft.consumption-retry-after' = @('12') }
        Get-RetryWaitSeconds -Exception $Ex -FallbackSeconds 30 | Should -Be 12
    }

    It 'parses the ARG quota-resets-after hh:mm:ss window into seconds' {
        $Ex = New-FakeThrottleException -Headers @{ 'x-ms-user-quota-resets-after' = @('00:00:08') }
        Get-RetryWaitSeconds -Exception $Ex -FallbackSeconds 30 | Should -Be 8
    }

    It 'matches header names case-insensitively' {
        $Ex = New-FakeThrottleException -Headers @{ 'RETRY-AFTER' = @('7') }
        Get-RetryWaitSeconds -Exception $Ex -FallbackSeconds 30 | Should -Be 7
    }

    It 'reads the header off InnerException.Response (the metrics wrap)' {
        $Ex = New-FakeThrottleException -Headers @{ 'Retry-After' = @('9') } -OnInner
        Get-RetryWaitSeconds -Exception $Ex -FallbackSeconds 30 | Should -Be 9
    }

    It 'prefers Retry-After over the quota header (global type-first precedence)' {
        $Ex = New-FakeThrottleException -Headers @{ 'Retry-After' = @('3'); 'x-ms-user-quota-resets-after' = @('00:01:00') }
        Get-RetryWaitSeconds -Exception $Ex -FallbackSeconds 30 | Should -Be 3
    }

    It 'clamps an oversized header value to MaxSeconds' {
        $Ex = New-FakeThrottleException -Headers @{ 'Retry-After' = @('999') }
        Get-RetryWaitSeconds -Exception $Ex -FallbackSeconds 30 -MaxSeconds 120 | Should -Be 120
    }

    It 'returns the exponential fallback when no usable header is present' {
        $Ex = New-FakeThrottleException -Headers @{ 'Content-Type' = @('application/json') }
        Get-RetryWaitSeconds -Exception $Ex -FallbackSeconds 42 | Should -Be 42
    }

    It 'returns the fallback when the exception exposes no Response at all' {
        $Ex = [pscustomobject]@{ Message = 'ServiceUnavailable' }
        Get-RetryWaitSeconds -Exception $Ex -FallbackSeconds 17 | Should -Be 17
    }

    It 'ignores a non-positive Retry-After and falls back' {
        $Ex = New-FakeThrottleException -Headers @{ 'Retry-After' = @('0') }
        Get-RetryWaitSeconds -Exception $Ex -FallbackSeconds 25 | Should -Be 25
    }
}
