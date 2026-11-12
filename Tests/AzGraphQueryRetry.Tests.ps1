# Requires -Modules Pester
# =============================================================================
# AzGraphQueryRetry.Tests.ps1
#
# Unit tests for the error handling and bounded retry of
# Invoke-AzGraphQuerySafe (Functions/ResourceInventory.Functions.ps1) - the
# single wrapper every resource-discovery Resource Graph query goes through.
#
# WHY THIS TEST EXISTS
# --------------------
# A dropped/changed network mid-run (VPN switch), Resource Graph throttling,
# or a 5xx blip during discovery used to throw on the first failure and fail
# the whole subscription. The wrapper retries TRANSIENT failures (408, 429,
# 5xx, a request that throws) with backoff, honouring Retry-After, but fails
# FAST + LOUD on clearly-permanent ones (400, 401, 403, 404). A response too
# large for one page is asked for again with half the page size, down to one
# row. Invoke-AzRestMethod does not throw on an HTTP error, so the wrapper
# reads the status code itself.
#
# The retry cap must hold under the production $ErrorActionPreference of
# 'SilentlyContinue', which suppresses a bare `throw`: a loop that relied on
# throw to leave would run forever, and a failure that throws only once could
# be swallowed and continue with an empty page. The last Describe runs the
# wrapper in a child pwsh under that preference to prove both.
#
# The seam: Invoke-AzRestMethod is mocked with canned responses, and
# Start-Sleep is mocked so backoff waits are not incurred. Assertions are on
# OBSERVABLE behaviour: how many requests were made, how long it slept, and
# what was thrown.
#
# No live Azure. Run with:
#   Invoke-Pester ./Tests/AzGraphQueryRetry.Tests.ps1 -Output Detailed
# =============================================================================

BeforeAll {
    $FunctionsFile = Join-Path (Split-Path $PSScriptRoot -Parent) 'Functions/ResourceInventory.Functions.ps1'
    if (-not (Test-Path $FunctionsFile)) { throw "ResourceInventory.Functions.ps1 not found at $FunctionsFile" }
    . $FunctionsFile

    # Something for Mock to replace, so the suite never loads Az.Accounts.
    function Invoke-AzRestMethod { param($Method, $Path, $Payload, $Uri) }

    $script:Sub = '12345678-1234-1234-1234-123456789012'

    function New-GraphResponse
    {
        param([object[]]$Rows = @(), [string]$SkipToken, [int]$Status = 200, [string]$Content, $Headers = @{})
        if (-not $PSBoundParameters.ContainsKey('Content'))
        {
            $Body = [ordered]@{ totalRecords = $Rows.Count; count = $Rows.Count; data = @($Rows); facets = @(); resultTruncated = 'false' }
            if ($SkipToken) { $Body['$skipToken'] = $SkipToken }
            $Content = $Body | ConvertTo-Json -Depth 10 -Compress
        }
        [pscustomobject]@{ StatusCode = $Status; Content = $Content; Headers = $Headers }
    }

    function New-GraphError
    {
        param([int]$Status, [string]$Code, [string]$Message, [string]$DetailCode, $Headers = @{})
        $Err = [ordered]@{ code = $Code; message = $Message }
        if ($DetailCode) { $Err.details = @(@{ code = $DetailCode; message = ('{0} detail' -f $DetailCode) }) }
        New-GraphResponse -Status $Status -Content (@{ error = $Err } | ConvertTo-Json -Depth 5 -Compress) -Headers $Headers
    }
}

Describe 'Invoke-AzGraphQuerySafe retry behavior' {

    BeforeAll {
        Mock -CommandName Start-Sleep -MockWith { }
    }

    Context 'Success path (HTTP 200, valid JSON)' {

        BeforeAll {
            Mock -CommandName Invoke-AzRestMethod -MockWith { New-GraphResponse -Rows @(@{ count_ = 42 }) }
        }

        It 'returns the parsed object' {
            $Result = Invoke-AzGraphQuerySafe -Query 'resources | summarize count()' -SubscriptionId $script:Sub
            $Result.data.count_ | Should -Be 42
        }

        It 'sends one POST to the Resource Graph resources endpoint (no retries on success)' {
            Invoke-AzGraphQuerySafe -Query 'resources | summarize count()' -SubscriptionId $script:Sub | Out-Null
            Should -Invoke -CommandName Invoke-AzRestMethod -Exactly -Times 1
            Should -Invoke -CommandName Invoke-AzRestMethod -Exactly -Times 1 -ParameterFilter { $Method -eq 'POST' -and $Path -eq '/providers/Microsoft.ResourceGraph/resources?api-version=2021-03-01' }
        }

        It 'never sleeps on success' {
            Invoke-AzGraphQuerySafe -Query 'resources | summarize count()' -SubscriptionId $script:Sub | Out-Null
            Should -Invoke -CommandName Start-Sleep -Exactly -Times 0
        }
    }

    Context '-Lowercase lowercases the payload before parsing' {

        BeforeAll {
            Mock -CommandName Invoke-AzRestMethod -MockWith { New-GraphResponse -Content '{"totalRecords":1,"count":1,"data":[{"Name":"MyResource"}],"facets":[],"resultTruncated":"false"}' }
        }

        It 'returns lowercased keys and values' {
            $Result = Invoke-AzGraphQuerySafe -Query 'resources' -SubscriptionId $script:Sub -Lowercase
            $Result.data.name | Should -Be 'myresource'
            $Result.data[0].PSObject.Properties.Name | Should -Be @('name')
        }
    }

    Context 'Transient failure (HTTP 503) retries then fails loud' {

        BeforeAll {
            Mock -CommandName Invoke-AzRestMethod -MockWith { New-GraphError -Status 503 -Code 'ServiceUnavailable' -Message 'connection reset (transient)' }
        }

        It 'throws after exhausting retries' {
            { Invoke-AzGraphQuerySafe -Query 'resources | summarize count()' -SubscriptionId $script:Sub } | Should -Throw
        }

        It 'attempts 4 times total (1 initial + 3 retries)' {
            try { Invoke-AzGraphQuerySafe -Query 'resources | summarize count()' -SubscriptionId $script:Sub | Out-Null } catch { }
            Should -Invoke -CommandName Invoke-AzRestMethod -Exactly -Times 4
        }

        It 'sleeps 3 times (once before each retry)' {
            try { Invoke-AzGraphQuerySafe -Query 'resources | summarize count()' -SubscriptionId $script:Sub | Out-Null } catch { }
            Should -Invoke -CommandName Start-Sleep -Exactly -Times 3
        }

        It 'surfaces the status, the error code and message, and the attempt count in the throw' {
            $Msg = $null
            try { Invoke-AzGraphQuerySafe -Query 'resources | summarize count()' -SubscriptionId $script:Sub | Out-Null }
            catch { $Msg = $_.Exception.Message }
            $Msg | Should -Match 'after 4 attempt\(s\)'
            $Msg | Should -Match 'HTTP 503'
            $Msg | Should -Match 'ServiceUnavailable'
            $Msg | Should -Match 'connection reset'
            $Msg | Should -Match ([regex]::Escape('Query: resources | summarize count()'))
        }
    }

    Context 'Other transient statuses (500, 502, 504, 408) and a request that throws are retried' {

        It 'retries HTTP <Status>' -TestCases @(@{ Status = 500 }, @{ Status = 502 }, @{ Status = 504 }, @{ Status = 408 }) {
            param($Status)
            $script:Answers = [System.Collections.Generic.Queue[object]]::new()
            $script:Answers.Enqueue((New-GraphError -Status $Status -Code 'Transient' -Message 'try again'))
            $script:Answers.Enqueue((New-GraphResponse -Rows @(@{ count_ = 1 })))
            Mock -CommandName Invoke-AzRestMethod -MockWith { $script:Answers.Dequeue() }

            $Result = Invoke-AzGraphQuerySafe -Query 'resources | summarize count()' -SubscriptionId $script:Sub
            $Result.data.count_ | Should -Be 1
            Should -Invoke -CommandName Invoke-AzRestMethod -Exactly -Times 2
        }

        It 'retries when Invoke-AzRestMethod itself throws (network failure)' {
            $script:Calls = 0
            Mock -CommandName Invoke-AzRestMethod -MockWith { $script:Calls++; if ($script:Calls -eq 1) { throw 'No such host is known.' }; New-GraphResponse -Rows @(@{ count_ = 5 }) }

            $Result = Invoke-AzGraphQuerySafe -Query 'resources | summarize count()' -SubscriptionId $script:Sub
            $Result.data.count_ | Should -Be 5
            Should -Invoke -CommandName Invoke-AzRestMethod -Exactly -Times 2
        }
    }

    Context 'Permanent failure (HTTP 403 AuthorizationFailed) fails fast, no retries' {

        BeforeAll {
            Mock -CommandName Invoke-AzRestMethod -MockWith { New-GraphError -Status 403 -Code 'AuthorizationFailed' -Message 'The client does not have authorization to perform action' }
        }

        It 'throws' {
            { Invoke-AzGraphQuerySafe -Query 'resources' -SubscriptionId $script:Sub } | Should -Throw
        }

        It 'makes exactly one request (no retries on a permanent error)' {
            try { Invoke-AzGraphQuerySafe -Query 'resources' -SubscriptionId $script:Sub | Out-Null } catch { }
            Should -Invoke -CommandName Invoke-AzRestMethod -Exactly -Times 1
        }

        It 'never sleeps (fails before any backoff)' {
            try { Invoke-AzGraphQuerySafe -Query 'resources' -SubscriptionId $script:Sub | Out-Null } catch { }
            Should -Invoke -CommandName Start-Sleep -Exactly -Times 0
        }

        It 'reports the status, code and message, and that it failed on the first attempt' {
            $Msg = $null
            try { Invoke-AzGraphQuerySafe -Query 'resources' -SubscriptionId $script:Sub | Out-Null } catch { $Msg = $_.Exception.Message }
            $Msg | Should -Match 'after 1 attempt\(s\)'
            $Msg | Should -Match 'HTTP 403'
            $Msg | Should -Match 'AuthorizationFailed'
            $Msg | Should -Match 'does not have authorization'
        }
    }

    Context 'Malformed KQL (HTTP 400 BadRequest) fails fast, no retries' {

        BeforeAll {
            Mock -CommandName Invoke-AzRestMethod -MockWith { New-GraphError -Status 400 -Code 'BadRequest' -Message 'Please provide below info when asking for support' -DetailCode 'InvalidQuery' }
        }

        It 'makes exactly one request and names the status and code' {
            $Msg = $null
            try { Invoke-AzGraphQuerySafe -Query 'this ||| is not valid' -SubscriptionId $script:Sub | Out-Null } catch { $Msg = $_.Exception.Message }
            Should -Invoke -CommandName Invoke-AzRestMethod -Exactly -Times 1
            $Msg | Should -Match 'HTTP 400'
            $Msg | Should -Match 'BadRequest'
            $Msg | Should -Match 'InvalidQuery'
        }
    }

    Context 'HTTP 401 and 404 are permanent too' {

        It 'fails HTTP <Status> on the first attempt' -TestCases @(@{ Status = 401 }, @{ Status = 404 }) {
            param($Status)
            Mock -CommandName Invoke-AzRestMethod -MockWith { New-GraphError -Status $Status -Code 'Nope' -Message 'not retried' }
            { Invoke-AzGraphQuerySafe -Query 'resources' -SubscriptionId $script:Sub } | Should -Throw -ExpectedMessage "*HTTP $Status*"
            Should -Invoke -CommandName Invoke-AzRestMethod -Exactly -Times 1
            Should -Invoke -CommandName Start-Sleep -Exactly -Times 0
        }
    }

    Context 'Throttling (HTTP 429) without Retry-After retries with a longer backoff' {

        BeforeAll {
            Mock -CommandName Invoke-AzRestMethod -MockWith { New-GraphError -Status 429 -Code 'RateLimiting' -Message 'request rate exceeded' }
        }

        It 'still attempts 4 times' {
            try { Invoke-AzGraphQuerySafe -Query 'resources' -SubscriptionId $script:Sub | Out-Null } catch { }
            Should -Invoke -CommandName Invoke-AzRestMethod -Exactly -Times 4
        }

        It 'every backoff is the doubled (throttled) duration, >= 2s' {
            # Non-throttled backoff would be 1,2,4 (first < 2). Throttled doubles
            # to 2,4,8, so ALL three sleeps must be >= 2s.
            try { Invoke-AzGraphQuerySafe -Query 'resources' -SubscriptionId $script:Sub | Out-Null } catch { }
            Should -Invoke -CommandName Start-Sleep -Exactly -Times 3 -ParameterFilter { $Seconds -ge 2 }
        }
    }

    Context 'Throttling (HTTP 429) with Retry-After waits as long as Azure asks, capped' {

        It 'sleeps the Retry-After seconds before the retry' {
            $script:Answers = [System.Collections.Generic.Queue[object]]::new()
            $script:Answers.Enqueue((New-GraphError -Status 429 -Code 'RateLimiting' -Message 'slow down' -Headers @{ 'Retry-After' = '7' }))
            $script:Answers.Enqueue((New-GraphResponse -Rows @(@{ count_ = 3 })))
            Mock -CommandName Invoke-AzRestMethod -MockWith { $script:Answers.Dequeue() }

            $Result = Invoke-AzGraphQuerySafe -Query 'resources | summarize count()' -SubscriptionId $script:Sub
            $Result.data.count_ | Should -Be 3
            Should -Invoke -CommandName Start-Sleep -Exactly -Times 1
            Should -Invoke -CommandName Start-Sleep -Exactly -Times 1 -ParameterFilter { $Seconds -eq 7 }
        }

        It 'reads Retry-After from real HTTP response headers' {
            $Headers = ([System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::TooManyRequests)).Headers
            $Headers.RetryAfter = [System.Net.Http.Headers.RetryConditionHeaderValue]::new([timespan]::FromSeconds(9))
            $script:Answers = [System.Collections.Generic.Queue[object]]::new()
            $script:Answers.Enqueue((New-GraphError -Status 429 -Code 'RateLimiting' -Message 'slow down' -Headers $Headers))
            $script:Answers.Enqueue((New-GraphResponse -Rows @(@{ count_ = 3 })))
            Mock -CommandName Invoke-AzRestMethod -MockWith { $script:Answers.Dequeue() }

            Invoke-AzGraphQuerySafe -Query 'resources | summarize count()' -SubscriptionId $script:Sub | Out-Null
            Should -Invoke -CommandName Start-Sleep -Exactly -Times 1 -ParameterFilter { $Seconds -eq 9 }
        }

        It 'caps a very long Retry-After at 60 seconds' {
            $script:Answers = [System.Collections.Generic.Queue[object]]::new()
            $script:Answers.Enqueue((New-GraphError -Status 429 -Code 'RateLimiting' -Message 'slow down' -Headers @{ 'Retry-After' = '3600' }))
            $script:Answers.Enqueue((New-GraphResponse -Rows @(@{ count_ = 3 })))
            Mock -CommandName Invoke-AzRestMethod -MockWith { $script:Answers.Dequeue() }

            Invoke-AzGraphQuerySafe -Query 'resources | summarize count()' -SubscriptionId $script:Sub | Out-Null
            Should -Invoke -CommandName Start-Sleep -Exactly -Times 1 -ParameterFilter { $Seconds -eq 60 }
        }
    }

    Context 'A response too large for one page (ResponsePayloadTooLarge)' {

        It 'asks again with half the page size and keeps the smaller size for the next page' {
            $script:Tops = [System.Collections.Generic.List[int]]::new()
            $script:Answers = [System.Collections.Generic.Queue[object]]::new()
            $script:Answers.Enqueue((New-GraphError -Status 400 -Code 'BadRequest' -Message 'too big' -DetailCode 'ResponsePayloadTooLarge'))
            $script:Answers.Enqueue((New-GraphResponse -Rows @(@{ id = 'a' }) -SkipToken 'next'))
            $script:Answers.Enqueue((New-GraphResponse -Rows @(@{ id = 'b' })))
            Mock -CommandName Invoke-AzRestMethod -MockWith { $script:Tops.Add([int](($Payload | ConvertFrom-Json).options.'$top')); $script:Answers.Dequeue() }

            $Result = Invoke-AzGraphQuerySafe -Query 'resources' -SubscriptionId $script:Sub
            @($Result.data.id) | Should -Be @('a', 'b')
            @($script:Tops) | Should -Be @(1000, 500, 500)
            Should -Invoke -CommandName Start-Sleep -Exactly -Times 0
        }

        It 'halves down to one row, then fails loud instead of returning a partial page' {
            $script:Tops = [System.Collections.Generic.List[int]]::new()
            Mock -CommandName Invoke-AzRestMethod -MockWith { $script:Tops.Add([int](($Payload | ConvertFrom-Json).options.'$top')); New-GraphError -Status 400 -Code 'BadRequest' -Message 'too big' -DetailCode 'ResponsePayloadTooLarge' }

            { Invoke-AzGraphQuerySafe -Query 'resources' -SubscriptionId $script:Sub } | Should -Throw -ExpectedMessage '*ResponsePayloadTooLarge*'
            @($script:Tops) | Should -Be @(1000, 500, 250, 125, 62, 31, 15, 7, 3, 1)
        }
    }

    Context 'HTTP 200 but unparseable output throws WITHOUT retrying' {

        BeforeAll {
            Mock -CommandName Invoke-AzRestMethod -MockWith { New-GraphResponse -Content 'not json {{{' }
        }

        It 'throws a parse error' {
            { Invoke-AzGraphQuerySafe -Query 'resources' -SubscriptionId $script:Sub } | Should -Throw -ExpectedMessage '*could not be parsed*'
        }

        It 'makes exactly one request (parse failures are not retried)' {
            try { Invoke-AzGraphQuerySafe -Query 'resources' -SubscriptionId $script:Sub | Out-Null } catch { }
            Should -Invoke -CommandName Invoke-AzRestMethod -Exactly -Times 1
        }
    }

    # The parse error goes to the log. A page holds resource names and ids
    # and can be megabytes long, so the message carries only its start, and
    # none of it with -HideRawOutput (the inventory passes it under -Obfuscate).
    Context 'The parse error does not log the whole page' {

        BeforeAll {
            $script:Marker = 'SECRET-RESOURCE-NAME'
            $script:BigPage = 'not json {{{ ' + $script:Marker + (' x' * 50000)
            Mock -CommandName Invoke-AzRestMethod -MockWith { New-GraphResponse -Content $script:BigPage }
        }

        It 'includes at most the first 500 characters of the raw output' {
            $Message = try { Invoke-AzGraphQuerySafe -Query 'resources' -SubscriptionId $script:Sub | Out-Null; '' } catch { $_.Exception.Message }
            $Message | Should -Match 'could not be parsed'
            $Message | Should -Match $script:Marker -Because 'the start of the page helps diagnose the failure'
            $Message.Length | Should -BeLessThan 1500
            $Message | Should -Match ('of {0} characters' -f $script:BigPage.Length)
        }

        It 'includes none of the raw output with -HideRawOutput' {
            $Message = try { Invoke-AzGraphQuerySafe -Query 'resources' -SubscriptionId $script:Sub -HideRawOutput | Out-Null; '' } catch { $_.Exception.Message }
            $Message | Should -Match 'could not be parsed'
            $Message | Should -Not -Match $script:Marker
            $Message | Should -Not -Match 'not json'
        }

        It 'is passed -HideRawOutput under -Obfuscate by every inventory query' {
            $Script = Join-Path (Split-Path $PSScriptRoot -Parent) 'ResourceInventory.ps1'
            $Ast = [System.Management.Automation.Language.Parser]::ParseFile($Script, [ref]$null, [ref]$null)
            $Calls = @($Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.CommandAst] -and $N.GetCommandName() -eq 'Invoke-AzGraphQuerySafe' }, $true))
            $Calls.Count | Should -BeGreaterThan 0
            foreach ($Call in $Calls) { $Call.Extent.Text | Should -Match '-HideRawOutput:\$Obfuscate\.IsPresent' }
        }
    }

    Context 'A truncated answer with no skip token is a failure, not a partial page' {

        It 'throws' {
            Mock -CommandName Invoke-AzRestMethod -MockWith { New-GraphResponse -Content '{"totalRecords":5000,"count":1,"data":[{"id":"a"}],"facets":[],"resultTruncated":"true"}' }
            { Invoke-AzGraphQuerySafe -Query 'resources' -SubscriptionId $script:Sub } | Should -Throw -ExpectedMessage '*truncated*'
        }
    }
}

# The production preference ($ErrorActionPreference = 'SilentlyContinue', set by
# ResourceInventory.ps1) suppresses a bare `throw`. Run the wrapper in a child
# pwsh under that preference, with no try/catch around the call, against a
# Resource Graph that always answers 503.
Describe 'Invoke-AzGraphQuerySafe retry cap under SilentlyContinue' {

    BeforeAll {
        $script:Harness = Join-Path $TestDrive 'silent-harness.ps1'
        @'
param([string]$Root, [string]$CallLog)
$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path $Root 'Functions/ResourceInventory.Functions.ps1')
function global:Start-Sleep { param($Seconds) }
function global:Invoke-AzRestMethod
{
    param($Method, $Path, $Payload, $Uri)
    Add-Content -Path $CallLog -Value 'call'
    # Stop a runaway loop from hanging the suite.
    if (@(Get-Content -Path $CallLog).Count -gt 50) { Add-Content -Path $CallLog -Value 'runaway'; exit 9 }
    [pscustomobject]@{ StatusCode = 503; Content = '{"error":{"code":"ServiceUnavailable","message":"down"}}'; Headers = @{} }
}
$Result = Invoke-AzGraphQuerySafe -Query 'resources | summarize count()' -SubscriptionId '12345678-1234-1234-1234-123456789012'
Add-Content -Path $CallLog -Value ('continued with {0} row(s)' -f @($Result.data).Count)
exit 0
'@ | Set-Content -Path $script:Harness -Encoding utf8
        $script:CallLog = Join-Path $TestDrive 'silent-calls.log'
        $script:Output = & (Join-Path $PSHOME 'pwsh') -NoProfile -NonInteractive -File $script:Harness -Root (Split-Path $PSScriptRoot -Parent) -CallLog $script:CallLog 2>&1 | Out-String
        $script:ExitCode = $LASTEXITCODE
        $script:Calls = @(Get-Content -Path $script:CallLog -ErrorAction SilentlyContinue)
    }

    It 'never makes more than 4 requests' {
        @($script:Calls | Where-Object { $_ -eq 'call' }).Count | Should -Be 4
        $script:Calls | Should -Not -Contain 'runaway'
    }

    It 'stops the script instead of continuing with an empty result' {
        @($script:Calls | Where-Object { $_ -like 'continued*' }).Count | Should -Be 0 -Because 'a suppressed throw would hand the caller an empty page'
        $script:ExitCode | Should -Not -Be 0
        # The console error view wraps long lines and frames them with '|'.
        $Flat = $script:Output -replace '\e\[[0-9;]*m', '' -replace '\s*\|\s*', ' ' -replace '\s+', ' '
        $Flat | Should -Match 'after 4 attempt\(s\)'
    }
}
