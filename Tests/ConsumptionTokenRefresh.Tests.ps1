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
        # The AuthenticationFailed code + 'Authentication failed.' message are the
        # VERBATIM 401 body the LIVE ARM server returns for a rejected/unusable
        # bearer (captured against the real management endpoint, not synthesised).
        # This is a 401 authentication failure, so the loop must refresh + retry.
        @{ Label = 'the real ARM AuthenticationFailed code'; Msg = '{ "error": { "code": "AuthenticationFailed", "message": "Authentication failed." } }' }
        @{ Label = 'the AuthenticationFailed message form alone'; Msg = 'Authentication failed.' }
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

Describe 'A mid-loop reconnect must re-pin the subscription scope before retrying' {

    # THE DEFECT THIS GUARDS. Test-DataPlaneAuthReady reconnects with
    # Connect-AzAccount and NO -Subscription, and its success test only checks
    # that a context plus a mintable token exist - never the selected
    # subscription. A SUCCESSFUL mid-loop reconnect can therefore leave the
    # context on the identity's default subscription. Get-UsageAggregates reads
    # the context's subscription, so retrying the page without re-pinning would
    # write ANOTHER subscription's usage rows into this one's Consumption_*.csv -
    # a cross-subscription billing-data leak. The per-sub loop already pins with
    # Set-AzContext -Subscription $sub.id and verifies the match before its first
    # page; the reconnect path must restore that same scope.

    It 're-pins the context to $sub.id after a successful reconnect' {
        $script:InvSrc | Should -Match 'Set-AzContext -Subscription \$sub\.id' -Because 'the reconnect can reset the context to the identity default subscription, so the loop must re-pin to the current subscription before retrying'
    }

    It 're-verifies the context actually matched $sub.id after re-pinning' {
        $script:InvSrc | Should -Match '\(Get-AzContext\)\.Subscription\.Id -eq \$sub\.id' -Because 'Set-AzContext succeeding is not proof the scope is correct; the loop must confirm the context matches the target subscription'
    }

    It 'the re-pin happens INSIDE the auth-expiry refresh branch (after the reconnect helper)' {
        # The re-pin must sit after the Test-DataPlaneAuthReady success check, so
        # it corrects the scope that the reconnect may have moved. If the ONLY
        # Set-AzContext re-pin were the one at the top of the per-sub loop, a
        # reconnect could still silently move the scope for the rest of the page's
        # retries.
        $RefreshIdx = $script:InvSrc.IndexOf("Test-DataPlaneAuthReady -Phase 'Consumption'")
        $RepinAfter = $script:InvSrc.IndexOf('Set-AzContext -Subscription $sub.id', $RefreshIdx)
        $RefreshIdx | Should -BeGreaterThan -1
        $RepinAfter | Should -BeGreaterThan $RefreshIdx -Because 'the scope re-pin must follow the reconnect it is correcting for'
    }

    It 'abandons the subscription when the scope cannot be restored (throws, not retries)' {
        # If the reconnect cannot be re-scoped to $sub, retrying would attribute
        # the wrong subscription's billing to this one. Abandoning (throw) routes
        # the subscription into the failed-subs list instead of writing a
        # mis-attributed Consumption_*.csv - the same fail-closed choice the
        # first-page context switch makes.
        $RefreshIdx = $script:InvSrc.IndexOf("Test-DataPlaneAuthReady -Phase 'Consumption'")
        $Tail = $script:InvSrc.Substring($RefreshIdx)
        $Tail | Should -Match 'could not be re-pinned' -Because 'a failed re-pin must be logged as an error explaining the abandonment'
        $Tail | Should -Match 'avoid attributing another subscription' -Because 'the abandonment reason must name the cross-subscription-attribution hazard it prevents'
    }
}

Describe 'A token that lapses AGAIN mid-loop is refreshed a second time (intra-page gap)' {

    # THE DEFECT THIS GUARDS (WARNING 726). The per-page guard above stops a
    # PERMANENT 401 from reconnecting on every one of the 30 attempts. But the
    # retry loop can run long on its own: each retry sleeps a server-directed
    # Retry-After clamped to 300s, so up to $ConsumptionMaxRetries attempts is
    # ~26 minutes worst case - long enough for even a freshly reconnected token to
    # reach its own policy lifetime. The original once-per-page boolean, once set,
    # blocked ALL further refreshes: a token that lapsed a SECOND time mid-loop
    # could not be refreshed, so the loop burned its remaining budget against a
    # dead token and failed the subscription. Only interactive sessions were bitten
    # (a service principal / managed identity re-issues its own token silently).
    #
    # THE FIX. A SUCCESSFUL reconnect re-arms the per-page guard (its fresh token
    # can lapse again and deserves another refresh); a reconnect that yields NO
    # usable token leaves the guard closed (a permanent 401 rides out the budget and
    # fails loud, unchanged). The number of re-arms is bounded so an every-attempt
    # expiry that keeps "succeeding" then immediately lapsing still terminates
    # rather than reconnecting forever.
    #
    # The loop is inline in the paging code (not a separately callable function),
    # so the structure is asserted from source, matching this file's existing
    # approach; the bounded re-arm CONTRACT is then exercised behaviourally against
    # a faithful model of the exact guard-transition the source implements.

    It 'bounds the total mid-loop refreshes per page' {
        $script:InvSrc | Should -Match '\$ConsumptionAuthRefreshMax = \d+' -Because 'an every-attempt expiry that keeps succeeding-then-lapsing must be capped so it cannot reconnect forever'
        $script:InvSrc | Should -Match '\$ConsumptionAuthRefreshCount = 0' -Because 'the per-page refresh counter must be initialised per page, alongside the boolean guard'
        $script:InvSrc | Should -Match '\$ConsumptionAuthRefreshCount\+\+' -Because 'each refresh attempt must advance the bounded counter'
    }

    It 're-arms the per-page guard only AFTER a successful, correctly re-pinned reconnect' {
        # The re-arm ($ConsumptionAuthRefreshedThisPage = $false) must sit inside the
        # $RepinOk success branch, after the re-pin - not in the reconnect-failed
        # path, and not before the scope has been restored. Otherwise a permanent
        # 401 (no usable token) would keep reconnecting every attempt, the exact
        # storm the guard exists to prevent.
        $RepinOkIdx = $script:InvSrc.IndexOf('if ($RepinOk)')
        $RepinOkIdx | Should -BeGreaterThan -1
        $Tail = $script:InvSrc.Substring($RepinOkIdx)
        # The re-arm is gated by the bounded counter, inside the success branch.
        $Tail | Should -Match '\$ConsumptionAuthRefreshCount -lt \$ConsumptionAuthRefreshMax' -Because 'the guard may only re-arm while the bounded refresh budget remains'
    }

    It 'the re-arm is gated by the bounded counter, not unconditional' {
        # Guards against a future edit that re-opens the guard on every successful
        # reconnect with no cap - which would let an every-attempt succeed-then-lapse
        # token reconnect indefinitely.
        $ReArmIdx = $script:InvSrc.IndexOf('$ConsumptionAuthRefreshCount -lt $ConsumptionAuthRefreshMax')
        $ReArmIdx | Should -BeGreaterThan -1
        $Window = $script:InvSrc.Substring($ReArmIdx, [math]::Min(280, $script:InvSrc.Length - $ReArmIdx))
        $Window | Should -Match '\$ConsumptionAuthRefreshedThisPage = \$false' -Because 'the re-arm of the boolean guard must be the body governed by the bounded-counter check'
    }

    It 'a reconnect that yields no usable token does NOT re-arm the guard (permanent 401 rides out the budget)' {
        # The re-arm lives in the $RepinOk success branch only. The reconnect-failed
        # (else) branch must NOT re-open the guard, so a permanent 401 reconnects at
        # most once then fails loud, exactly as before the intra-page fix.
        $FailBranchIdx = $script:InvSrc.IndexOf('did not yield a usable token')
        $FailBranchIdx | Should -BeGreaterThan -1
        # From the failed-reconnect log to the end of the catch's auth branch there
        # must be no guard re-arm.
        $AttemptIdx = $script:InvSrc.IndexOf('$ConsumptionAttempt++', $FailBranchIdx)
        $AttemptIdx | Should -BeGreaterThan $FailBranchIdx
        $FailWindow = $script:InvSrc.Substring($FailBranchIdx, $AttemptIdx - $FailBranchIdx)
        $FailWindow | Should -Not -Match '\$ConsumptionAuthRefreshedThisPage = \$false' -Because 'a permanent 401 (no usable token after reconnect) must keep the guard closed and ride out the budget'
    }

    Context 'the bounded re-arm contract (behavioural model of the exact source transition)' {

        # A faithful model of the guard transition the source implements, so the
        # CONTRACT - not just the presence of tokens - is exercised: refresh only
        # when the guard is open and the error is an expiry; re-arm only after a
        # successful reconnect while budget remains; never re-arm after a failed
        # reconnect. This is a model, not the inline loop itself (which is not
        # separately callable); the source guards above pin that the real code
        # matches this shape.
        BeforeAll {
            function Invoke-RefreshModel {
                param(
                    [int]$RefreshMax = 3,
                    # A closure returning $true if the Nth reconnect attempt yields a usable token.
                    [scriptblock]$ReconnectSucceeds,
                    [int]$MaxAttempts = 30
                )
                $Refreshed = $false          # $ConsumptionAuthRefreshedThisPage
                $RefreshCount = 0            # $ConsumptionAuthRefreshCount
                $Reconnects = 0
                for ($Attempt = 1; $Attempt -le $MaxAttempts; $Attempt++)
                {
                    # Every attempt hits an auth-expiry (worst case for this model).
                    if ((-not $Refreshed))
                    {
                        $Refreshed = $true
                        $RefreshCount++
                        $Reconnects++
                        if (& $ReconnectSucceeds $RefreshCount)
                        {
                            if ($RefreshCount -lt $RefreshMax) { $Refreshed = $false }
                        }
                        # failed reconnect: guard stays closed (no re-arm).
                    }
                }
                [pscustomobject]@{ Reconnects = $Reconnects; RefreshCount = $RefreshCount }
            }
        }

        It 'refreshes more than once when the token keeps lapsing after successful reconnects' {
            # The core of 726: a second lapse after a good reconnect gets a second
            # refresh (the old boolean stopped at exactly one).
            $r = Invoke-RefreshModel -RefreshMax 3 -ReconnectSucceeds { param($n) $true }
            $r.RefreshCount | Should -BeGreaterThan 1
        }

        It 'never exceeds the bounded refresh budget even if every attempt lapses' {
            $r = Invoke-RefreshModel -RefreshMax 3 -ReconnectSucceeds { param($n) $true }
            $r.RefreshCount | Should -Be 3
            $r.Reconnects | Should -Be 3
        }

        It 'reconnects at most ONCE when the reconnect never yields a usable token (permanent 401)' {
            # A permanent 401: the reconnect "returns" but Test-DataPlaneAuthReady
            # reports no usable token, so the guard is never re-armed and the loop
            # rides out its budget without a reconnect storm.
            $r = Invoke-RefreshModel -RefreshMax 3 -ReconnectSucceeds { param($n) $false }
            $r.Reconnects | Should -Be 1
            $r.RefreshCount | Should -Be 1
        }
    }
}
