#Requires -Version 7.0
# =============================================================================
# ConsumptionRetryAfter.Tests.ps1
#
# Unit tests for Get-RdaRetryAfterSeconds (Functions/ResourceInventory.Functions.ps1)
# - the helper that lets the consumption billing-pull retry HONOR Azure's
# server-directed wait instead of guessing with blind backoff.
#
# The consumption/Cost Management 429 carries the exact delay on
# 'x-ms-ratelimit-microsoft.consumption-retry-after' (and ARM generally on
# 'Retry-After'). Get-UsageAggregates surfaces the failure as a
# Microsoft.Rest.Azure.CloudException whose .Response.Headers is an
# IDictionary[string, IEnumerable[string]]. These tests build a REAL
# CloudException with a REAL populated header dictionary (the same types the
# live cmdlet throws) and assert the helper reads the delay correctly.
#
# No Azure calls, no network. Az.Billing is imported only to make the
# Microsoft.Rest.* types available; the whole real-type suite is skipped
# gracefully if they cannot be loaded (e.g. a minimal CI image).
# =============================================================================

# Detect whether the real Microsoft.Rest.Azure.CloudException type can be loaded.
# This MUST run at DISCOVERY time (top-level, not in BeforeAll) so the Context
# -Skip: expression below can see it - a BeforeAll assignment would run too late.
$script:RealTypesAvailable = $true
try
{
    Import-Module Az.Billing -ErrorAction Stop
    $null = [Microsoft.Rest.Azure.CloudException]
    $null = [Microsoft.Rest.HttpResponseMessageWrapper]
}
catch
{
    $script:RealTypesAvailable = $false
}

BeforeAll {
    $FunctionsFile = Join-Path (Split-Path $PSScriptRoot -Parent) 'Functions/ResourceInventory.Functions.ps1'
    if (-not (Test-Path $FunctionsFile)) { throw "ResourceInventory.Functions.ps1 not found at $FunctionsFile" }
    . $FunctionsFile

    # Build a real CloudException whose .Response.Headers carries the supplied
    # header name/value pairs - faithful to what Get-AzUsageAggregate throws.
    function New-ThrottleException([hashtable]$Headers)
    {
        $Msg = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::TooManyRequests)
        foreach ($Key in $Headers.Keys)
        {
            $null = $Msg.Headers.TryAddWithoutValidation($Key, [string]$Headers[$Key])
        }
        $Wrapper = [Microsoft.Rest.HttpResponseMessageWrapper]::new($Msg, 'throttled')
        $Ex = [Microsoft.Rest.Azure.CloudException]::new('Operation returned an invalid status code TooManyRequests')
        $Ex.Response = $Wrapper
        return $Ex
    }
}

Describe 'Get-RdaRetryAfterSeconds' {

    Context 'real CloudException header extraction' -Skip:(-not $script:RealTypesAvailable) {

        It 'reads the consumption-specific header (delta-seconds)' {
            $Ex = New-ThrottleException @{ 'x-ms-ratelimit-microsoft.consumption-retry-after' = '42' }
            Get-RdaRetryAfterSeconds -ErrorRecord $Ex | Should -Be 42
        }

        It 'reads the standard Retry-After header (delta-seconds)' {
            $Ex = New-ThrottleException @{ 'Retry-After' = '30' }
            Get-RdaRetryAfterSeconds -ErrorRecord $Ex | Should -Be 30
        }

        It 'prefers the consumption header over Retry-After when both are present' {
            $Ex = New-ThrottleException @{
                'x-ms-ratelimit-microsoft.consumption-retry-after' = '55'
                'Retry-After'                                      = '10'
            }
            Get-RdaRetryAfterSeconds -ErrorRecord $Ex | Should -Be 55
        }

        It 'is case-insensitive on the header name' {
            $Ex = New-ThrottleException @{ 'RETRY-AFTER' = '17' }
            Get-RdaRetryAfterSeconds -ErrorRecord $Ex | Should -Be 17
        }

        It 'clamps a negative delta-seconds value to 0' {
            $Ex = New-ThrottleException @{ 'Retry-After' = '-5' }
            Get-RdaRetryAfterSeconds -ErrorRecord $Ex | Should -Be 0
        }

        It 'handles an HTTP-date Retry-After in the future (returns a positive delta)' {
            $Future = ([datetimeoffset]::UtcNow.AddSeconds(90)).ToString('R')
            $Ex = New-ThrottleException @{ 'Retry-After' = $Future }
            $Result = Get-RdaRetryAfterSeconds -ErrorRecord $Ex
            $Result | Should -BeGreaterThan 60
            $Result | Should -BeLessOrEqual 91
        }

        It 'returns 0 for an HTTP-date Retry-After in the past' {
            $Past = ([datetimeoffset]::UtcNow.AddSeconds(-120)).ToString('R')
            $Ex = New-ThrottleException @{ 'Retry-After' = $Past }
            Get-RdaRetryAfterSeconds -ErrorRecord $Ex | Should -Be 0
        }

        It 'returns 0 when no retry header is present' {
            $Ex = New-ThrottleException @{ 'x-ms-request-id' = 'abc123' }
            Get-RdaRetryAfterSeconds -ErrorRecord $Ex | Should -Be 0
        }

        It 'walks the exception chain when the CloudException is wrapped in an ErrorRecord' {
            $Ex = New-ThrottleException @{ 'x-ms-ratelimit-microsoft.consumption-retry-after' = '63' }
            $Record = [System.Management.Automation.ErrorRecord]::new($Ex, 'Throttled', [System.Management.Automation.ErrorCategory]::LimitsExceeded, $null)
            Get-RdaRetryAfterSeconds -ErrorRecord $Record | Should -Be 63
        }
    }

    Context 'graceful fallback (no real types needed)' {

        It 'returns 0 for a plain exception with no Response' {
            $Ex = [System.InvalidOperationException]::new('some transient failure')
            Get-RdaRetryAfterSeconds -ErrorRecord $Ex | Should -Be 0
        }

        It 'reads a duck-typed Response/Headers object and never throws' {
            $Headers = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.IEnumerable[string]]]::new()
            $Headers['Retry-After'] = [string[]]@('21')
            $Fake = [pscustomobject]@{ Response = [pscustomobject]@{ Headers = $Headers } }
            Get-RdaRetryAfterSeconds -ErrorRecord $Fake | Should -Be 21
        }

        It 'returns 0 for an exception that has no Response property' {
            $Ex = [System.Exception]::new('no response property here')
            Get-RdaRetryAfterSeconds -ErrorRecord $Ex | Should -Be 0
        }
    }
}
