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

    # Write-Log lives in Common.Functions.ps1 and is a real dependency of the
    # oversized-window path, which warns the operator when it has to split a page.
    # ResourceInventory.ps1 dot-sources Common before any of this runs, so loading
    # it here matches production rather than papering over a missing command.
    $CommonFile = Join-Path (Split-Path $PSScriptRoot -Parent) 'Functions/Common.Functions.ps1'
    if (-not (Test-Path $CommonFile)) { throw "Common.Functions.ps1 not found at $CommonFile" }
    . $CommonFile

    # Offline-portability shim: Pester's `Mock -CommandName Search-AzGraph`
    # resolves the command at mock-setup time. On a clean box / CI without the
    # Az.ResourceGraph module installed that would throw CommandNotFoundException
    # before any test runs. Declaring a no-op `Search-AzGraph` function here gives
    # Mock something to intercept, so the suite is a genuine offline unit test
    # that does not depend on Az.ResourceGraph being installed.
    # [CmdletBinding()] so the shim accepts the common parameters the function under
    # test passes (-ErrorAction Stop); a simple function would reject them. The
    # named parameters are declared so a Mock body can assert on the WINDOW being
    # requested (First/Skip), which the oversized-response tests below rely on.
    function Search-AzGraph
    {
        [CmdletBinding()]
        param($Query, $Subscription, $First, $Skip, $ManagementGroup)
    }
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

# =============================================================================
# Oversized-response handling, and the retry bound under the PRODUCTION
# error preference.
#
# WHY THESE EXIST
# ---------------
# The tests above validate the retry ceiling, and they passed - while the ceiling
# was inert in production. Pester runs at the default $ErrorActionPreference of
# 'Continue', and every assertion above reaches the function through
# `{ ... } | Should -Throw` or a `try { } catch { }`. Under either of those a
# `throw` is terminating, so the ceiling appeared to work.
#
# A normal run is different: ResourceInventory.ps1 sets
# $ErrorActionPreference = 'SilentlyContinue', and the discovery loops call the
# wrapper with no local guard. Under that preference a terminating error with no
# catch anywhere up the stack does NOT stop anything - execution continues at the
# next statement. The retry loop used to be `for (;;)` whose only exits were
# `break` on success and a `throw` on failure, so on a permanent failure the
# throw fell through, the backoff ran, and the loop went round again forever. A
# subscription holding an unfetchable page hung indefinitely.
#
# So the first Context below pins the bound at the preference production actually
# uses, with no caller guard - the condition the old tests never reproduced.
#
# The rest cover Resource Graph's 16 MB response cap. A full page normally sits
# well under it, but a type whose payload is hundreds of KB each
# (microsoft.resources/templatespecs/versions, up to ~794 KB) can push one page
# over. `order by id asc` makes those resources contiguous, so the whole
# oversize lands in a single page that can never succeed. The wrapper now
# re-fetches that window as smaller sub-windows and still returns the FULL window,
# because the callers advance their offset by the page size they asked for - a
# short page would silently skip resources.
# =============================================================================

Describe 'Retry bound under the production error preference' {

    It 'never uses throw as loop control in either Graph loop' {
        # The regression this pins: a `throw` is not a reliable exit under
        # 'SilentlyContinue', so neither the retry ceiling nor the window splitter
        # may depend on one. A throw inside either loop body lets execution fall
        # through and keep looping - unbounded, which is the whole bug.
        $Src = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'Functions/ResourceInventory.Functions.ps1') -Raw

        $RequestFn = [regex]::Match($Src, '(?s)function Invoke-AzGraphRequest\r?\n\{.*?\r?\n\}').Value
        $RequestFn | Should -Not -BeNullOrEmpty -Because 'the single-request retry helper must exist to be checked'
        $RequestFn | Should -Match '\$Attempt -ge \$GraphMaxRetries' -Because 'the ceiling condition must still be there'
        $RetryLoop = [regex]::Match($RequestFn, '(?s)for \(\$Attempt = 0; ; \$Attempt\+\+\)\r?\n    \{.*?\r?\n    \}').Value
        $RetryLoop | Should -Not -BeNullOrEmpty
        $RetryLoop | Should -Not -Match '\bthrow\b' -Because 'a throw inside the retry loop is what made the ceiling inert'

        $WindowFn = [regex]::Match($Src, '(?s)function Get-AzGraphRowWindow\r?\n\{.*?\r?\n\}').Value
        $WindowFn | Should -Not -BeNullOrEmpty
        $SplitLoop = [regex]::Match($WindowFn, '(?s)while \(\$Pending\.Count -gt 0\)\r?\n    \{.*?\r?\n    \}').Value
        $SplitLoop | Should -Not -BeNullOrEmpty
        $SplitLoop | Should -Not -Match '\bthrow\b' -Because 'a throw inside the split loop lets a non-payload failure fall through into the split branch and loop forever'
        $WindowFn | Should -Match '\$FatalMessage' -Because 'fatal paths must record and break, then throw after the loop'
    }

    It 'stops at 31 attempts in a real process at SilentlyContinue with no caller catch' {
        # Pester always catches, so the production condition - a terminating error
        # with NOTHING catching it anywhere up the stack - cannot be reproduced
        # in-process. Run it in a child pwsh instead, which is the only faithful way.
        # The mock has a hard ceiling so an unbounded loop ends the child rather than
        # hanging this suite; a bounded implementation never reaches it.
        $Repo = Split-Path $PSScriptRoot -Parent
        $Script = @'
$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path $args[0] 'Functions/Common.Functions.ps1')
. (Join-Path $args[0] 'Functions/ResourceInventory.Functions.ps1')
$global:Calls = 0
function Search-AzGraph { [CmdletBinding()] param($Query,$Subscription,$First,$Skip,$ManagementGroup)
    $global:Calls++
    if ($global:Calls -gt 200) { return @([pscustomobject]@{ id = 'ceiling' }) }
    throw 'ServiceUnavailable (503) - transient'
}
function Start-Sleep { param([int]$Seconds, [switch]$Milliseconds) }
# NO try/catch - production parity.
$null = Invoke-AzGraphQuerySafe -Query 'resources | order by id asc' -First 1000
"CALLS=$($global:Calls)"
'@
        $Tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("argbound-{0}.ps1" -f [guid]::NewGuid().ToString('N').Substring(0, 8))
        try
        {
            Set-Content -LiteralPath $Tmp -Value $Script -Encoding utf8
            $Out = & pwsh -NoProfile -File $Tmp $Repo 2>&1
            $Line = @($Out | Where-Object { $_ -match '^CALLS=\d+$' }) | Select-Object -Last 1
            $Line | Should -Not -BeNullOrEmpty -Because 'the child process must reach the end, which an unbounded loop never would'
            [int]($Line -replace '^CALLS=', '') | Should -Be 31 -Because 'the ceiling is 30 retries plus the initial attempt, and it must hold with nothing catching the throw'
        }
        finally
        {
            Remove-Item -LiteralPath $Tmp -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Oversized Resource Graph response (16 MB cap)' {

    BeforeAll {
        Mock -CommandName Start-Sleep -MockWith { }
        $script:PayloadError = 'BadRequest : ResponsePayloadTooLarge : Response payload size is 33455366, exceeded the limit of 16777216'
    }

    Context 'A window Azure refuses as too large is re-fetched in smaller pieces' {

        BeforeAll {
            # Refuse anything wider than 250 rows; otherwise return exactly the rows
            # for the requested window so the caller's window can be reassembled.
            $script:Requests = [System.Collections.ArrayList]::new()
            Mock -CommandName Search-AzGraph -MockWith {
                # $First / $Skip bind from the shim's param block. The wrapper omits
                # -Skip when the offset is 0, so treat an unbound $Skip as 0.
                $Offset = if ($null -eq $Skip) { 0 } else { [int]$Skip }
                $Count = [int]$First
                [void]$script:Requests.Add([pscustomobject]@{ Skip = $Offset; First = $Count })
                if ($Count -gt 250) { throw $script:PayloadError }
                return @(0..($Count - 1) | ForEach-Object { [pscustomobject]@{ id = "/r/$($Offset + $_)" } })
            }
        }

        It 'returns the FULL requested window, not a short page' {
            $script:Requests.Clear()
            $Result = Invoke-AzGraphQuerySafe -Query 'resources | order by id asc' -First 1000 -Skip 116000
            @($Result.data).Count | Should -Be 1000 -Because 'the caller advances its offset by the page size it asked for, so a short page would silently skip resources'
        }

        It 'covers the window exactly once, with no gap and no overlap' {
            $script:Requests.Clear()
            $Result = Invoke-AzGraphQuerySafe -Query 'resources | order by id asc' -First 1000 -Skip 116000
            $Ids = @($Result.data | ForEach-Object { $_.id })
            @($Ids | Select-Object -Unique).Count | Should -Be 1000 -Because 'overlapping sub-windows would duplicate rows'
            $Ids[0] | Should -Be '/r/116000'
            $Ids[-1] | Should -Be '/r/116999'
        }

        It 'returns rows in ascending order, as a single successful request would' {
            $script:Requests.Clear()
            $Result = Invoke-AzGraphQuerySafe -Query 'resources | order by id asc' -First 1000 -Skip 0
            $Offsets = @($Result.data | ForEach-Object { [int]($_.id -replace '^/r/', '') })
            ($Offsets -join ',') | Should -Be (($Offsets | Sort-Object) -join ',')
        }

        It 'does not burn the transient-retry budget on the oversized attempts' {
            # An oversized response is not transient; retrying it unchanged is futile.
            # Each refused window must be attempted once, then split.
            # 1000 is refused and splits to 500+500; each 500 is refused and splits
            # to 250+250. So exactly 3 refused attempts (1000, 500, 500) and 4
            # accepted (four 250s) - 7 requests in total. Each refused window is
            # attempted ONCE; retrying an oversized response unchanged is futile.
            $script:Requests.Clear()
            $null = Invoke-AzGraphQuerySafe -Query 'resources | order by id asc' -First 1000 -Skip 0
            @($script:Requests | Where-Object { $_.First -gt 250 }).Count | Should -Be 3
            @($script:Requests).Count | Should -Be 7
            Should -Invoke -CommandName Start-Sleep -Times 0 -Because 'no backoff should be incurred for an oversized response'
        }
    }

    Context 'A single resource larger than the cap fails loudly' {

        BeforeAll {
            Mock -CommandName Search-AzGraph -MockWith { throw $script:PayloadError }
        }

        It 'throws naming the offset, rather than dropping the resource' {
            $Msg = $null
            try { Invoke-AzGraphQuerySafe -Query 'resources | order by id asc' -First 1 -Skip 500 | Out-Null }
            catch { $Msg = $_.Exception.Message }
            $Msg | Should -Not -BeNullOrEmpty -Because 'an unfetchable resource must never be silently skipped'
            $Msg | Should -Match 'SINGLE resource'
            $Msg | Should -Match '500'
        }
    }

    Context 'An unordered query is not split' {

        BeforeAll {
            Mock -CommandName Search-AzGraph -MockWith { throw $script:PayloadError }
        }

        It 'refuses to split, because sub-windows of an unordered result are not stable' {
            $Msg = $null
            try { Invoke-AzGraphQuerySafe -Query 'resources | project id' -First 1000 | Out-Null }
            catch { $Msg = $_.Exception.Message }
            $Msg | Should -Not -BeNullOrEmpty
            $Msg | Should -Match 'not ordered'
        }
    }
}

Describe 'Discovery failure is not survivable (source guard)' {

    # The behaviour under test is in ResourceInventory.ps1's orchestration, which
    # cannot be dot-sourced (its body authenticates and runs a whole inventory).
    # These assert the guard is present in the source, because its absence is what
    # allowed a failed page to produce a quietly incomplete report.
    BeforeAll {
        $script:InvSrc = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'ResourceInventory.ps1') -Raw
    }

    It 'wraps the discovery loops in a try/catch that hard-fails' {
        $script:InvSrc | Should -Match '(?s)try\s*\{\s*ResourceInventoryLoop\s*ResourceInventoryAvd\s*\}\s*catch'
    }

    It 'exits non-zero on a discovery failure rather than continuing to report' {
        $script:InvSrc | Should -Match '(?s)FAILED to complete resource discovery.*?exit 1'
    }
}

# =============================================================================
# Structured error classification (Get-AzGraphErrorInfo)
#
# WHY THIS EXISTS
# ---------------
# The native cmdlet's exception .Message carries NO detail. Verified against live
# Azure: a malformed query, a denied subscription and an oversized response all
# produce the same line -
#     Operation returned an invalid status code 'BadRequest'
# The reason is only in the typed body:
#     $Exception.Body.Error.Code            -> 'BadRequest'
#     $Exception.Body.Error.Details[].Code  -> 'ResponsePayloadTooLarge', 'InvalidQuery', ...
#     $Exception.Response.StatusCode        -> 400
# So a message-text match for 'ResponsePayloadTooLarge' would NEVER fire on the
# native path, and the page-splitting fix would never engage. These tests pin the
# classification to codes and HTTP status.
#
# The exceptions here are duck-typed stand-ins carrying the same property shape,
# because constructing a real ErrorResponseException offline is not possible. The
# shape itself was confirmed against a live Search-AzGraph failure.
# =============================================================================

Describe 'Get-AzGraphErrorInfo' {

    BeforeAll {
        function script:New-GraphError
        {
            param([string]$Message = "Operation returned an invalid status code 'BadRequest'",
                [string]$Code, [string[]]$DetailCodes = @(), $Status)
            $Err = $null
            if ($Code -or $DetailCodes.Count -gt 0)
            {
                $Err = [pscustomobject]@{
                    Code    = $Code
                    Message = 'Please provide below info when asking for support: timestamp = ..., correlationId = ...'
                    Details = @($DetailCodes | ForEach-Object { [pscustomobject]@{ Code = $_; Message = $_ } })
                }
            }
            return [pscustomobject]@{
                Message        = $Message
                Body           = if ($null -ne $Err) { [pscustomobject]@{ Error = $Err } } else { $null }
                Response       = if ($null -ne $Status) { [pscustomobject]@{ StatusCode = $Status } } else { $null }
                InnerException = $null
            }
        }
    }

    It 'detects an oversized response from the structured detail, despite a generic message' {
        # THE case that message matching cannot see.
        $Ex = script:New-GraphError -Code 'BadRequest' -DetailCodes @('ResponsePayloadTooLarge') -Status 400
        $Ex.Message | Should -Not -Match 'ResponsePayloadTooLarge' -Because 'the native message genuinely carries no detail'
        $Info = Get-AzGraphErrorInfo -Exception $Ex
        $Info.IsPayloadTooLarge | Should -BeTrue
        $Info.IsPermanent | Should -BeFalse -Because 'it arrives as a 400 but a SMALLER request can satisfy it, so it must not be given up on'
        $Info.Codes | Should -Contain 'ResponsePayloadTooLarge'
        $Info.HttpStatus | Should -Be 400
    }

    It 'classifies a malformed query as permanent' {
        $Info = Get-AzGraphErrorInfo -Exception (script:New-GraphError -Code 'BadRequest' -DetailCodes @('InvalidQuery', 'ParserFailure') -Status 400)
        $Info.IsPermanent | Should -BeTrue
        $Info.IsPayloadTooLarge | Should -BeFalse
        $Info.IsThrottled | Should -BeFalse
    }

    It 'classifies authorization failure as permanent' {
        $Info = Get-AzGraphErrorInfo -Exception (script:New-GraphError -Code 'AuthorizationFailed' -Status 403)
        $Info.IsPermanent | Should -BeTrue
    }

    It 'classifies 429 as throttled, never as permanent' {
        $Info = Get-AzGraphErrorInfo -Exception (script:New-GraphError -Code 'TooManyRequests' -Status 429)
        $Info.IsThrottled | Should -BeTrue
        $Info.IsPermanent | Should -BeFalse -Because 'a 429 is a wait-and-retry signal, not a give-up'
    }

    It 'treats a 5xx as transient (neither permanent nor throttled)' {
        $Info = Get-AzGraphErrorInfo -Exception (script:New-GraphError -Message 'Operation returned an invalid status code ServiceUnavailable' -Code 'ServiceUnavailable' -Status 503)
        $Info.IsPermanent | Should -BeFalse
        $Info.IsThrottled | Should -BeFalse
        $Info.IsPayloadTooLarge | Should -BeFalse
    }

    It 'treats a 408 request timeout as retryable, not permanent' {
        $Info = Get-AzGraphErrorInfo -Exception (script:New-GraphError -Status 408)
        $Info.IsPermanent | Should -BeFalse
    }

    It 'falls back to message text when there is no structured body at all' {
        # A socket/DNS/TLS failure is a plain exception with no Body and no Response.
        $Ex = script:New-GraphError -Message 'The remote name could not be resolved: management.azure.com'
        $Info = Get-AzGraphErrorInfo -Exception $Ex
        $Info.HasStructuredBody | Should -BeFalse
        $Info.HttpStatus | Should -Be 0
        $Info.IsPermanent | Should -BeFalse -Because 'an unrecognised network-level failure is worth retrying'
    }

    It 'uses the text fallback for a payload error that carries no structured body' {
        $Info = Get-AzGraphErrorInfo -Exception (script:New-GraphError -Message 'ResponsePayloadTooLarge : Response payload size is 33455366, exceeded the limit of 16777216')
        $Info.IsPayloadTooLarge | Should -BeTrue
    }

    It 'never throws on a null or shapeless exception' {
        { Get-AzGraphErrorInfo -Exception $null } | Should -Not -Throw
        (Get-AzGraphErrorInfo -Exception $null).IsPermanent | Should -BeFalse
        { Get-AzGraphErrorInfo -Exception ([pscustomobject]@{ Message = 'x' }) } | Should -Not -Throw
    }

    It 'reads codes and status through an InnerException wrapper' {
        $Inner = script:New-GraphError -Code 'BadRequest' -DetailCodes @('ResponsePayloadTooLarge') -Status 400
        $Outer = [pscustomobject]@{ Message = 'wrapped'; Body = $null; Response = $null; InnerException = $Inner }
        $Info = Get-AzGraphErrorInfo -Exception $Outer
        $Info.IsPayloadTooLarge | Should -BeTrue
        $Info.HttpStatus | Should -Be 400
    }
}

# =============================================================================
# Consumption paging token isolation (source guard)
#
# $UsageData holds the LAST page fetched and is the source of the paging token for
# the next request. It is not scoped to a single subscription's paging loop, so a
# subscription that failed part-way through its pages used to leave its live
# ContinuationToken in place - and the NEXT subscription's first billing request
# went out carrying a token belonging to a different subscription. That either
# fails outright or, worse, resumes another subscription's page sequence and
# attributes its billing rows to the wrong subscription.
#
# The behaviour lives in ResourceInventory.ps1's orchestration, which cannot be
# dot-sourced (its body authenticates and runs a whole inventory), so this is a
# source guard - the same approach the discovery-failure guard above uses.
# =============================================================================

Describe 'Consumption paging token does not leak between subscriptions' {

    BeforeAll {
        $script:InvSource = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'ResourceInventory.ps1') -Raw
    }

    It 'clears $UsageData before each subscription paging loop' {
        $script:InvSource | Should -Match '(?s)\$UsageData = \$null\s*\r?\n\s*try\s*\r?\n\s*\{\s*\r?\n\s*do' -Because 'the reset must sit immediately before the paging loop it protects'
    }

    It 'guards the token read so a null previous page cannot be dereferenced' {
        $script:InvSource | Should -Match '\$Params\.ContinuationToken = if \(\$null -ne \$UsageData\)' -Because 'the first request of a subscription must send no token'
    }

    It 'never reads the token from an unguarded previous page' {
        $Unguarded = @($script:InvSource -split "`n" | Where-Object {
                $_ -match '\$Params\.ContinuationToken\s*=\s*\$UsageData\.ContinuationToken'
            })
        $Unguarded.Count | Should -Be 0 -Because 'that exact form is the leak: it carries the previous subscription token into the next subscription'
    }
}
