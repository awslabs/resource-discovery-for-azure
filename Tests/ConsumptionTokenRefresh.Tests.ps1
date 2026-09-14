#Requires -Version 7.0
<#
    ConsumptionTokenRefresh.Tests.ps1

    Covers the mid-loop token refresh in the consumption paging retry loop
    (ResourceInventory.ps1, around the Get-UsageAggregates paging call) and its
    classifier, Test-RdaAuthExpiry (Functions/Common.Functions.ps1).

    THE DEFECT THIS GUARDS. On a very large subscription the consumption paging
    loop can run for well over an hour. An interactive sign-in whose token
    reaches its policy lifetime part-way through fails every remaining page with
    an expired/invalid-token error. That is deliberately NOT an authorization
    denial (Test-RdaConsumptionDenial returns false for it), so the loop retries
    - but it used to retry the SAME dead token with no re-authentication, burning
    the whole 30-attempt budget and then failing the subscription. A service
    principal / managed identity / workload identity re-issues its own token, so
    only an interactive session was bitten.

    THE FIX. The retry catch now, after the denial short-circuit, recognises an
    auth-expiry error (Test-RdaAuthExpiry) and re-establishes the Azure context
    ONCE per page (Test-DataPlaneAuthReady) before the existing backoff retries
    the SAME page. The ContinuationToken guard re-sends the previous page's
    token, so no rows are skipped or duplicated.

    WHAT MUST NOT REGRESS.
      - A genuine 403 denial must still short-circuit BEFORE any refresh.
      - The refresh is at most ONCE per page (a permanent 401 must ride out the
        budget and fail loud, not reconnect on every attempt).
      - Test-RdaAuthExpiry must not false-positive on an id/RG/URL echoed back in
        a billing exception (the same anchoring hazard the denial predicate has).

    Fully offline. The classifier is pure; the loop's structure is asserted from
    source (it is inline in a paging loop, not a separately callable function).
#>

BeforeAll {
    $script:Repo = Split-Path $PSScriptRoot -Parent
    $script:CommonPath = Join-Path $script:Repo 'Functions/Common.Functions.ps1'
    $script:InvPath = Join-Path $script:Repo 'ResourceInventory.ps1'

    . $script:CommonPath

    $script:InvSrc = Get-Content -LiteralPath $script:InvPath -Raw
}

Describe 'Test-RdaAuthExpiry: an expired/invalid token, distinct from a denial' {

    It 'classifies <Label> as an auth-expiry (so the loop refreshes and retries)' -ForEach @(
        @{ Label = 'the ARM ExpiredAuthenticationToken code'; Msg = 'ExpiredAuthenticationToken: The access token expiry UTC time is earlier than current UTC time' }
        @{ Label = 'the ARM InvalidAuthenticationToken code'; Msg = 'InvalidAuthenticationToken: The access token is invalid' }
        @{ Label = 'an access-token-expiry sentence'; Msg = 'The access token expiry cannot be determined' }
        @{ Label = 'a token-has-expired sentence'; Msg = 'The access token has expired. Renew the token and try again' }
        @{ Label = 'a 401 Unauthorized status'; Msg = "Operation returned an invalid status code 'Unauthorized'" }
        @{ Label = 'a numeric (401) rendering'; Msg = 'The remote server returned an error: (401).' }
        @{ Label = 'a .NET status-code 401 rendering'; Msg = 'Response status code does not indicate success: 401 (Unauthorized).' }
    ) {
        Test-RdaAuthExpiry -ErrorMessage $Msg | Should -BeTrue
    }

    It 'does NOT classify <Label> as an auth-expiry' -ForEach @(
        # A genuine authorization DENIAL is owned by Test-RdaConsumptionDenial and
        # must be abandoned, not refreshed.
        @{ Label = 'a 403 Forbidden'; Msg = 'Response status code does not indicate success: 403 (Forbidden).' }
        @{ Label = 'AuthorizationFailed'; Msg = "The client does not have authorization to perform action; AuthorizationFailed" }
        # Throttling backs off but does not re-auth.
        @{ Label = 'a 429 throttle'; Msg = 'Operation returned an invalid status code 429 TooManyRequests' }
        # Ordinary transients are retried by the existing backoff, no refresh needed.
        @{ Label = 'the transient stream-copy error'; Msg = 'Error while copying content to a stream' }
        @{ Label = 'a socket reset'; Msg = 'An existing connection was forcibly closed by the remote host' }
        @{ Label = 'an empty message'; Msg = '' }
        @{ Label = 'a null message'; Msg = $null }

        # Anchoring guards. A hyphen is a non-word character, so a plain \b on
        # 'unauthorized' would fire on an id / resource group / URL echoed back in
        # a transient billing exception. These must NOT be read as auth-expiry, or
        # a spurious reconnect would be attempted on an unrelated transient error.
        @{ Label = 'a resource group named rg-unauthorized-01'; Msg = 'Error while copying content to a stream for rg-unauthorized-01' }
        @{ Label = 'a storage account named unauthorized-data'; Msg = 'The operation has timed out for unauthorized-data' }
        # A request id that merely contains 401 must not read as a 401 status.
        @{ Label = 'a request id containing 401'; Msg = 'Operation timed out. x-ms-request-id: req9f401ab1' }
    ) {
        Test-RdaAuthExpiry -ErrorMessage $Msg | Should -BeFalse
    }

    It 'never throws on hostile input' {
        { Test-RdaAuthExpiry -ErrorMessage $null } | Should -Not -Throw
        { Test-RdaAuthExpiry -ErrorMessage '' } | Should -Not -Throw
    }
}

Describe 'Auth-expiry and denial are mutually exclusive on the classes that matter' {

    It 'an expired token is an auth-expiry and NOT a denial' {
        # This is the whole point of the split: a denial is abandoned, an expiry is
        # refreshed and retried. If a future edit let the denial predicate match an
        # expired token again, the fast-fail would throw away recoverable billing
        # data - the exact regression the split exists to prevent.
        $Expired = 'ExpiredAuthenticationToken: The access token expiry UTC time is earlier than current UTC time'
        Test-RdaAuthExpiry -ErrorMessage $Expired | Should -BeTrue
        Test-RdaConsumptionDenial -ErrorMessage $Expired | Should -BeFalse
    }

    It 'a 403 denial is a denial and NOT an auth-expiry' {
        $Denied = 'Response status code does not indicate success: 403 (Forbidden). AuthorizationFailed'
        Test-RdaConsumptionDenial -ErrorMessage $Denied | Should -BeTrue
        Test-RdaAuthExpiry -ErrorMessage $Denied | Should -BeFalse
    }
}

Describe 'The retry loop refreshes a lapsed token before retrying the page' {

    It 'checks for an auth-expiry inside the consumption retry catch' {
        $script:InvSrc | Should -Match 'Test-RdaAuthExpiry -ErrorMessage \$_\.Exception\.Message' -Because 'the loop must recognise an expired token to know to refresh it'
    }

    It 'refreshes via the existing reconnect helper, not a new auth path' {
        $script:InvSrc | Should -Match "Test-DataPlaneAuthReady -Phase 'Consumption'" -Because 'the refresh must reuse the phase reconnect helper (SP/device/browser), not introduce a new sign-in path'
    }

    It 'settles a denial BEFORE attempting an auth-expiry refresh' {
        # A message that is both (rare) must be treated as a denial: a denial is
        # abandoned, and reconnecting for it would be pointless work.
        $DenialIdx = $script:InvSrc.IndexOf('Test-RdaConsumptionDenial -ErrorMessage $_.Exception.Message')
        $AuthIdx = $script:InvSrc.IndexOf('Test-RdaAuthExpiry -ErrorMessage $_.Exception.Message')

        $DenialIdx | Should -BeGreaterThan -1
        $AuthIdx | Should -BeGreaterThan -1
        $DenialIdx | Should -BeLessThan $AuthIdx -Because 'a denial must short-circuit before any reconnect is attempted'
    }

    It 'attempts the reconnect at most ONCE per page (guarded)' {
        # A genuinely permanent 401 (revoked / interaction-required refresh token)
        # cannot be fixed by reconnecting. Without the guard it would reconnect on
        # every one of the 30 attempts; with it, it reconnects once, then rides out
        # the remaining budget and fails loud exactly as before.
        $script:InvSrc | Should -Match '\$ConsumptionAuthRefreshedThisPage = \$false' -Because 'the guard must be reset per page so each page gets its own single reconnect'
        $script:InvSrc | Should -Match '\(-not \$ConsumptionAuthRefreshedThisPage\) -and \(Test-RdaAuthExpiry' -Because 'the reconnect must be gated by the per-page guard'
        $script:InvSrc | Should -Match '\$ConsumptionAuthRefreshedThisPage = \$true' -Because 'the guard must be set once a reconnect has been attempted for this page'
    }

    It 'KEEPS the 30-attempt budget and the same-page retry after a refresh' {
        # The refresh does not replace the existing retry mechanics; it precedes
        # them. The ContinuationToken is read from the previous page, so the retried
        # call re-requests the SAME page (no skipped/duplicated rows).
        $script:InvSrc | Should -Match '\$ConsumptionMaxRetries = 30' -Because 'the refresh must not shrink the transient-retry budget'
        $script:InvSrc | Should -Match '\$Params\.ContinuationToken = if \(\$null -ne \$UsageData\)' -Because 'retry-same-page semantics must be preserved so a refreshed retry does not skip or duplicate rows'
    }

    It 'does not introduce a new global for the guard' {
        # The per-page guard is a plain local. A $Global: here would violate the
        # project global-variable rule and leak across subscriptions.
        $script:InvSrc | Should -Not -Match '\$Global:ConsumptionAuthRefreshedThisPage' -Because 'the guard is per-page local state, not a run-wide global'
    }
}
