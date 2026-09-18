# Offline unit tests for Invoke-AzGraphQuerySafe's bounded retry: transient failures retry with
# backoff, permanent ones fail fast. Search-AzGraph and Start-Sleep are mocked so the suite runs offline in ms with no live Azure.

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

    # No-op Search-AzGraph shim so Mock has something to intercept without Az.ResourceGraph installed
    # (Mock resolves the command at setup time); [CmdletBinding()] and named params let it accept -ErrorAction and assert the requested First/Skip window.
    function Search-AzGraph
    {
        [CmdletBinding()]
        param($Query, $Subscription, $First, $Skip, $ManagementGroup, $SkipToken)
    }

    # Emit rows as the real cmdlet does - ONE IEnumerable object (unary comma), not an array: a mock
    # returning an array streams as N outputs and flattens under test, hiding the unflattened-in-production data-loss bug. Data is a separate list (not self-referential) to stay non-circular under ConvertTo-Json.
    function script:New-FakeGraphResponse
    {
        param([object[]]$Rows, [string]$SkipToken = $null)

        $Response = [System.Collections.Generic.List[object]]::new()
        foreach ($R in $Rows) { $Response.Add($R) }

        $DataView = [System.Collections.Generic.List[object]]::new()
        foreach ($R in $Rows) { $DataView.Add($R) }

        Add-Member -InputObject $Response -MemberType NoteProperty -Name 'Data' -Value $DataView -Force
        Add-Member -InputObject $Response -MemberType NoteProperty -Name 'SkipToken' -Value $SkipToken -Force
        return , $Response
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
            # Response-SHAPED so the summarize count() probe is pinned against the
            # real single-object output rather than a plain array.
            Mock -CommandName Search-AzGraph -MockWith { script:New-FakeGraphResponse -Rows @([pscustomobject]@{ count_ = 42 }) }
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
            # Response-SHAPED, so the -Lowercase round-trip is exercised against the
            # real single-object output rather than a plain array.
            Mock -CommandName Search-AzGraph -MockWith { script:New-FakeGraphResponse -Rows @([pscustomobject]@{ Name = 'MyResource' }) }
        }

        It 'returns lowercased keys and values' {
            $Result = Invoke-AzGraphQuerySafe -Query 'resources' -Lowercase
            # PowerShell property access is case-insensitive, so $Result.data.name
            # alone resolves the original 'Name' key whether or not keys were
            # lowercased - a regression that lowercased values but left keys
            # uppercased would still pass. Assert the actual key set with a
            # case-sensitive comparison to pin the KEY-lowercasing the test name promises.
            $Row = @($Result.data)[0]
            $Row.PSObject.Properties.Name | Should -BeExactly 'name'
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
            # Assert every one of the 30 throttled sleeps is >= 2s: throttling doubles the non-throttled
            # 1,2,4 backoff, proving the throttle branch ran (string-throw mocks carry no .Response, so the exponential fallback is used unchanged).
            try { Invoke-AzGraphQuerySafe -Query 'resources' | Out-Null } catch { }
            Should -Invoke -CommandName Start-Sleep -Exactly -Times 30 -ParameterFilter { $Seconds -ge 2 }
        }
    }
}

Describe 'Get-RetryWaitSeconds header honoring' {

    BeforeAll {
        # Build a synthetic throttling exception whose .Response.Headers mimics the real shape (values
        # as string arrays) so the helper's null guards hit the same fallback path; defined in BeforeAll for Pester v5 It-scope visibility.
        function New-FakeThrottleException
        {
            param([hashtable]$Headers, [switch]$OnInner)

            # Use a generic Dictionary (string[] values), not a hashtable: foreach does not enumerate a
            # hashtable, but the real header containers enumerate as KeyValuePairs - the shape Get-RetryWaitSeconds walks in production.
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

# Pins the retry bound under production's 'SilentlyContinue' preference with no caller guard - where the old
# for(;;) loop's throw fell through and hung forever - and covers the 16 MB response cap: an oversized page is re-fetched as sub-windows but still returns the FULL window (callers advance offset by the requested page size).

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
# -Milliseconds is an [int] on the real cmdlet, not a switch. The fake must match
# the real signature or a caller passing -Milliseconds <n> would bind <n> as a
# positional arg here and behave differently from production.
function Start-Sleep { param([int]$Seconds, [int]$Milliseconds) }
# NO try/catch - production parity.
$null = Invoke-AzGraphQuerySafe -Query 'resources | order by id asc' -First 1000
"CALLS=$($global:Calls)"
'@
        $Tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("argbound-{0}.ps1" -f [guid]::NewGuid().ToString('N').Substring(0, 8))
        try
        {
            Set-Content -LiteralPath $Tmp -Value $Script -Encoding utf8

            # Precondition: without this, a missing pwsh host produces an empty
            # $Out and the assertion below fails as though the retry bound were
            # broken - misattributing an environment problem to the code.
            (Get-Command pwsh -ErrorAction SilentlyContinue) |
                Should -Not -BeNullOrEmpty -Because 'this test needs a pwsh host on PATH to spawn the child process'

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
                # Response-SHAPED, not a plain array. These four tests are about the
                # split path, which is exactly where the unflattened-response bug
                # corrupted the row set - so the mock has to reproduce the real
                # single-object output or they only exercise the split arithmetic.
                script:New-FakeGraphResponse -Rows @(0..($Count - 1) | ForEach-Object { [pscustomobject]@{ id = "/r/$($Offset + $_)" } })
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
            # An oversized response is not transient: attempt each window once, then split.
            # 1000 -> 500+500 -> four 250s = 3 refused + 4 accepted = 7 requests; retrying an oversized window unchanged is futile.
            $script:Requests.Clear()
            $null = Invoke-AzGraphQuerySafe -Query 'resources | order by id asc' -First 1000 -Skip 0
            @($script:Requests | Where-Object { $_.First -gt 250 }).Count | Should -Be 3
            @($script:Requests).Count | Should -Be 7
            # -Exactly is REQUIRED here. Without it Pester's -Times means "at
            # least N", so '-Times 0' is trivially satisfied and the assertion can
            # never fail - the no-backoff claim would be unverified.
            Should -Invoke -CommandName Start-Sleep -Exactly -Times 0 -Because 'no backoff should be incurred for an oversized response'
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

# Pins Get-AzGraphErrorInfo to error CODES and HTTP status, not message text: the native .Message is identical
# ('invalid status code BadRequest') for malformed/denied/oversized, so a text match for 'ResponsePayloadTooLarge' would never fire and page-splitting would never engage. Exceptions are duck-typed stand-ins (a real one can't be built offline).

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

# Source guard: $UsageData's ContinuationToken must be reset per subscription. It holds the last page and is
# not sub-scoped, so a mid-page failure once leaked a live token into the NEXT subscription's first billing request, misattributing its rows. The behaviour lives in ResourceInventory.ps1 orchestration, which can't be dot-sourced.

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

# Regression: the response must be FLATTENED to rows at the boundary. Real Search-AzGraph returns ONE IEnumerable
# response (not N streamed rows); @(Search-AzGraph) collected the response, and after a 16 MB split ConvertTo-Json turned N responses into N nested arrays, silently dropping resources. Reproduced via the unary-comma single-object shape, the only way to catch it in-process.
Describe 'Search-AzGraph response is flattened to rows at the boundary' {

    BeforeAll {
        Mock -CommandName Start-Sleep -MockWith { }

        # New-FakeGraphResponse is defined once in the file-level BeforeAll, because
        # the earlier split-path and count-probe mocks need the same shape.
    }

    Context 'single window (no split)' {

        BeforeAll {
            Mock -CommandName Search-AzGraph -MockWith {
                $Offset = if ($null -eq $Skip) { 0 } else { [int]$Skip }
                $Count = [int]$First
                script:New-FakeGraphResponse -Rows @(0..($Count - 1) | ForEach-Object {
                        [pscustomobject]@{ id = "/r/$($Offset + $_)"; name = "Res$($Offset + $_)" }
                    })
            }
        }

        It 'returns flat rows, not a wrapped response object' {
            $Result = Invoke-AzGraphQuerySafe -Query 'resources | order by id asc' -First 5
            @($Result.data).Count | Should -Be 5 -Because '@($x.data).Count must be the ROW count, never 1 for the response'
        }

        It 'every element is a row, not a collection' {
            $Result = Invoke-AzGraphQuerySafe -Query 'resources | order by id asc' -First 5
            foreach ($Row in @($Result.data))
            {
                # Parenthesised so the assertion does not depend on -and vs pipeline
                # precedence being read correctly.
                (($Row -is [System.Collections.IEnumerable]) -and ($Row -isnot [string])) |
                    Should -BeFalse -Because 'a nested collection here is the corruption this guards against'
                $Row.id | Should -Not -BeNullOrEmpty
            }
        }

        It 'is flat WITHOUT -Lowercase too, so the shape does not depend on that switch' {
            $Plain = Invoke-AzGraphQuerySafe -Query 'resources | order by id asc' -First 5
            $Lower = Invoke-AzGraphQuerySafe -Query 'resources | order by id asc' -First 5 -Lowercase
            @($Plain.data).Count | Should -Be @($Lower.data).Count -Because '-Lowercase must control casing ONLY, never the shape'
        }
    }

    Context 'after a 16 MB payload split (the case that silently lost resources)' {

        BeforeAll {
            # Reuse the literal defined at the top of the pre-existing split
            # context rather than restating it, so the two cannot drift apart.
            $script:PayloadTooLarge = $script:PayloadError
            Mock -CommandName Search-AzGraph -MockWith {
                $Offset = if ($null -eq $Skip) { 0 } else { [int]$Skip }
                $Count = [int]$First
                # Force the splitter to run by refusing anything wider than 250.
                if ($Count -gt 250) { throw $script:PayloadTooLarge }
                script:New-FakeGraphResponse -Rows @(0..($Count - 1) | ForEach-Object {
                        [pscustomobject]@{ id = "/r/$($Offset + $_)"; name = "Res$($Offset + $_)" }
                    })
            }
        }

        It 'returns the full window as FLAT rows across every sub-window' {
            $Result = Invoke-AzGraphQuerySafe -Query 'resources | order by id asc' -First 1000 -Lowercase
            @($Result.data).Count | Should -Be 1000 -Because 'a split must concatenate ROWS; nested per-sub-window arrays are the bug'
        }

        It 'produces no nested collection anywhere in the result' {
            $Result = Invoke-AzGraphQuerySafe -Query 'resources | order by id asc' -First 1000 -Lowercase
            $Nested = @(@($Result.data) | Where-Object { $_ -is [System.Collections.IEnumerable] -and $_ -isnot [string] })
            $Nested.Count | Should -Be 0 -Because 'each nested array would append to $Global:Resources as one unusable object'
        }

        It 'covers the window exactly once, with no gap and no overlap' {
            $Result = Invoke-AzGraphQuerySafe -Query 'resources | order by id asc' -First 1000 -Skip 116000 -Lowercase
            # Index the FLAT array and assert element count / [0]/[-1]: piping $Result.data | ForEach-Object { $_.id }
            # would pass even against the nested-array bug because member enumeration reaches through the nesting, so it wouldn't discriminate.
            $Rows = @($Result.data)
            $Rows.Count | Should -Be 1000 -Because 'nested per-sub-window arrays would collapse this to the sub-window count'
            $Rows[0].id | Should -Be '/r/116000'
            $Rows[-1].id | Should -Be '/r/116999'
            @($Rows | ForEach-Object { $_.id } | Select-Object -Unique).Count | Should -Be 1000 -Because 'overlapping sub-windows would duplicate rows'
        }
    }

    Context 'empty result' {

        BeforeAll {
            Mock -CommandName Search-AzGraph -MockWith { script:New-FakeGraphResponse -Rows @() }
        }

        It 'yields 0 rows, not a 1-element array holding an empty response' {
            $Result = Invoke-AzGraphQuerySafe -Query 'resources | order by id asc' -First 5
            @($Result.data).Count | Should -Be 0 -Because 'an empty response must not present as one phantom row'
        }
    }

    Context 'source guard' {

        # Every file that calls Search-AzGraph directly is exposed to this
        # regression, not just the wrapper's own file. Guarding only the owner
        # would miss a reintroduction in the bypassing consumer - which is exactly
        # the search-by-capability point in change-protocol.md.
        It 'never collects the cmdlet output directly with @(Search-AzGraph ...) in ANY file' {
            $Repo = Split-Path $PSScriptRoot -Parent
            $Targets = @(
                'Functions/ResourceInventory.Functions.ps1'
                'Functions/RunAllSubscriptions.Functions.ps1'
                'Run-AllSubscriptions.ps1'
                'ResourceInventory.ps1'
            )
            $Offenders = @()
            foreach ($Rel in $Targets)
            {
                $Path = Join-Path $Repo $Rel
                if (-not (Test-Path -LiteralPath $Path)) { continue }

                # Strip comments before matching, so the fix's own explanatory
                # comment (which quotes the broken form deliberately) is not read as
                # an offence. Uses the PowerShell tokenizer rather than a regex, so
                # trailing comments and <# block comments #> are both handled -
                # a '^\s*#' filter catches neither.
                $Errors = $null
                $Tokens = $null
                [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$Tokens, [ref]$Errors)
                $CodeOnly = -join (@($Tokens |
                            Where-Object { $_.Kind -ne 'Comment' } |
                            ForEach-Object { $_.Text + ' ' }))

                if ($CodeOnly -match '@\(\s*Search-AzGraph') { $Offenders += $Rel }
            }
            $Offenders -join ', ' | Should -BeNullOrEmpty -Because 'that form wraps the response instead of enumerating its rows, which is exactly the regression'
        }

        It 'still assigns the response to a variable before enumerating it' {
            # Positive counterpart to the ban above: proving the broken form is
            # absent does not prove the correct form is present.
            $Path = Join-Path (Split-Path $PSScriptRoot -Parent) 'Functions/ResourceInventory.Functions.ps1'
            $Src = Get-Content -LiteralPath $Path -Raw
            $Src | Should -Match '\$Response\s*=\s*Search-AzGraph\s+@GraphParams' -Because 'the intermediate variable is what makes the enumeration happen'
            $Src | Should -Match '\$Rows\s*=\s*if \(\$null -eq \$Response\)' -Because 'the null guard prevents a phantom row when the cmdlet emits nothing'
        }
    }
}
