#Requires -Version 7.0
<#
    ConsumptionDenialFastFail.Tests.ps1

    Covers the permanent-vs-transient split in the consumption retry loop
    (ResourceInventory.ps1, around the Get-UsageAggregates paging call) and the
    single owner of the denial signatures, Test-RdaConsumptionDenial
    (Functions/Common.Functions.ps1).

    THE DEFECT THIS GUARDS. The retry catch is untyped and retries everything up
    to $ConsumptionMaxRetries = 30. With backoff of min(2^attempt, 60) seconds
    that is roughly 26 MINUTES of escalating waiting PER SUBSCRIPTION on a 403,
    before propagating to exactly the place it would have gone immediately.

    WHAT MUST NOT REGRESS THE OTHER WAY. The 30-attempt budget is deliberate, not
    excessive: the Cost Management / Consumption rate limit is shared tenant-wide,
    so a short 3-attempt budget can expire while another pipeline is still
    draining the bucket, truncating this subscription's billing data. So the tests
    below assert BOTH directions - a denial must abandon immediately, and every
    transient class must still retry.

    Fully offline. The denial classifier is pure, and the loop's structure is
    asserted from source (it is inline in a paging loop, not a function, so it
    cannot be invoked without a live billing subscription).
#>

BeforeAll {
    $script:Repo = Split-Path $PSScriptRoot -Parent
    $script:CommonPath = Join-Path $script:Repo 'Functions/Common.Functions.ps1'
    $script:WrapperFnPath = Join-Path $script:Repo 'Functions/RunAllSubscriptions.Functions.ps1'
    $script:InvPath = Join-Path $script:Repo 'ResourceInventory.ps1'

    . $script:CommonPath
    . $script:WrapperFnPath

    $script:InvSrc = Get-Content -LiteralPath $script:InvPath -Raw
}

Describe 'Test-RdaConsumptionDenial: unambiguous denials only' {

    It 'classifies <Label> as a denial' -ForEach @(
        @{ Label = 'AuthorizationFailed'; Msg = "The client 'x' does not have authorization to perform action" }
        @{ Label = 'a bare 403'; Msg = 'Operation returned an invalid status code 403' }
        @{ Label = 'Forbidden'; Msg = "Operation returned an invalid status code 'Forbidden'" }
        @{ Label = 'not authorized'; Msg = 'The caller is not authorized to read usage data' }
        @{ Label = 'access is denied'; Msg = 'Access is denied for this scope' }
        @{ Label = 'insufficient privileges'; Msg = 'Insufficient privileges to complete the operation' }
        @{ Label = 'an RBAC mention'; Msg = 'RBAC does not permit this operation' }
    ) {
        Test-RdaConsumptionDenial -ErrorMessage $Msg | Should -BeTrue
    }

    It 'does NOT classify <Label> as a denial, so it still retries' -ForEach @(
        @{ Label = 'the transient stream-copy error'; Msg = 'Error while copying content to a stream' }
        @{ Label = 'a 429 throttle'; Msg = 'Operation returned an invalid status code 429 TooManyRequests' }
        @{ Label = 'a throttle by word'; Msg = 'Request was throttled, please retry' }
        @{ Label = 'a 503'; Msg = "Operation returned an invalid status code 'ServiceUnavailable'" }
        @{ Label = 'a 500'; Msg = 'Operation returned an invalid status code 500' }
        @{ Label = 'a socket reset'; Msg = 'An existing connection was forcibly closed by the remote host' }
        @{ Label = 'a timeout'; Msg = 'The operation has timed out' }
        @{ Label = 'an expired token'; Msg = 'The access token expiry cannot be determined' }
        @{ Label = 'an empty message'; Msg = '' }
        @{ Label = 'a null message'; Msg = $null }

        # --- Regressions. Each of these was classified as a DENIAL by the earlier
        # loose pattern, which abandoned billing data that a retry would have got.

        # HTTP 401 is a failed AUTHENTICATION, not an authorization denial: the
        # token is missing, expired or invalid, which is precisely the class that
        # succeeds after a refresh. The old '(?i)authoriz' matched the 'authoriz'
        # inside 'Unauthorized' and threw the subscription away.
        @{ Label = 'a 401 Unauthorized'; Msg = "Operation returned an invalid status code 'Unauthorized'" }
        @{ Label = 'a bare 401'; Msg = 'Operation returned an invalid status code 401' }
        @{ Label = 'an unauthorized client sentence'; Msg = 'The request is unauthorized; please re-authenticate and try again' }

        # 'does not have' on its own is a normal English fragment. A scope with no
        # billing rows, or a mid-run 5xx that quotes one, must still retry.
        @{ Label = 'a scope with no usage rows'; Msg = 'The subscription does not have any usage data for the requested period' }
        @{ Label = 'a missing-feature message'; Msg = 'This offer does not have support for the legacy usage API' }

        # \b treats '-' as a word boundary, so an id, resource group or URL echoed
        # back inside a transient billing exception read as an HTTP 403.
        @{ Label = 'a resource group whose name contains 403'; Msg = 'Error while copying content to a stream for rg-403-prod' }
        @{ Label = 'a request id containing 403'; Msg = 'Operation timed out. x-ms-request-id: req9f403ab1' }

        # 'RBAC' unbounded hit the letters inside a longer token.
        @{ Label = 'a token that merely contains the letters rbac'; Msg = 'Error while copying content to a stream for storage account crbaclogs01' }

        # --- A hyphen is a NON-word character, so \b gives no protection against a
        # resource name. These fired even after the first tightening, and are why the
        # forbidden / RBAC branches use (?<![\w-]) ... (?![\w-]) instead of \b.
        @{ Label = 'a resource group named rg-forbidden-01'; Msg = 'Error while copying content to a stream for rg-forbidden-01' }
        @{ Label = 'a storage account ending in -forbidden'; Msg = 'The operation has timed out for sa-forbidden' }
        @{ Label = 'a resource group named rg-rbac-prod'; Msg = 'Error while copying content to a stream for rg-rbac-prod' }
    ) {
        Test-RdaConsumptionDenial -ErrorMessage $Msg | Should -BeFalse
    }

    It 'catches LinkedAuthorizationFailed, a real ARM code that a \b anchor would miss' {
        # The first pass at fixing the 401 false-positive used '\bauthoriz', which
        # correctly excluded 'Unauthorized' but ALSO excluded this genuine denial code,
        # trading a false positive for a false negative. (?<!un) says what is meant.
        Test-RdaConsumptionDenial -ErrorMessage 'LinkedAuthorizationFailed: the client does not have access to linked scope' | Should -BeTrue
    }

    It 'catches the .NET status-code renderings whose gap is wider than it looks' {
        # 'does not indicate success: ' is 27 characters, which a {0,15} gap could not
        # span - so this real rendering was reachable only via the 'forbidden' branch,
        # and a numeric-only variant would have been missed entirely.
        Test-RdaConsumptionDenial -ErrorMessage 'Response status code does not indicate success: 403 (Forbidden).' | Should -BeTrue
        Test-RdaConsumptionDenial -ErrorMessage 'StatusCode: 403' | Should -BeTrue
    }

    It 'still refuses a 403 that is only ever part of a request id' {
        # The widened gap must not let \D reach across another number into a GUID.
        Test-RdaConsumptionDenial -ErrorMessage 'status code 500. x-ms-request-id: req9f403ab1' | Should -BeFalse
    }

    It 'still catches the real ARM permission sentence verbatim' {
        # The actual message ARM returns for a missing Cost Management role. If a
        # future tightening breaks this, the fast-fail stops working entirely.
        $Real = "The client 'a@b.com' with object id '00000000-0000-0000-0000-000000000000' " +
        "does not have authorization to perform action 'Microsoft.Commerce/UsageAggregates/read' " +
        "over scope '/subscriptions/00000000-0000-0000-0000-000000000000' or the scope is invalid."
        Test-RdaConsumptionDenial -ErrorMessage $Real | Should -BeTrue
    }

    It 'catches the .NET numeric-only 403 rendering' {
        Test-RdaConsumptionDenial -ErrorMessage 'The remote server returned an error: (403).' | Should -BeTrue
        Test-RdaConsumptionDenial -ErrorMessage 'Response status code does not indicate success: 403 (Forbidden).' | Should -BeTrue
    }

    It 'never throws on hostile input' {
        { Test-RdaConsumptionDenial -ErrorMessage $null } | Should -Not -Throw
        { Test-RdaConsumptionDenial -ErrorMessage '' } | Should -Not -Throw
    }
}

Describe 'One owner: the wrapper gate and the retry loop share the same verdict' {

    It 'Get-ConsumptionAccessOutcome delegates rather than restating the pattern' {
        $Src = Get-Content -LiteralPath $script:WrapperFnPath -Raw
        $FnBlock = [regex]::Match($Src, '(?s)function Get-ConsumptionAccessOutcome\r?\n\{.*?\r?\n\}').Value

        $FnBlock | Should -Match 'Test-RdaConsumptionDenial' -Because 'the gate must use the shared classifier'
        $FnBlock | Should -Not -Match 'insufficient privileg' -Because 'a second copy of the signatures is what drifts; there must be exactly one'
    }

    It 'agrees with the gate on every denial case' {
        # The two callers act on this verdict in OPPOSITE ways (the gate stops the
        # run; the loop stops retrying), so a disagreement would make behaviour
        # depend on which code path saw the error first.
        foreach ($Msg in @(
                'does not have authorization to perform action',
                "invalid status code 'Forbidden'",
                'Error while copying content to a stream',
                'Request was throttled'
            ))
        {
            $Denied = Test-RdaConsumptionDenial -ErrorMessage $Msg
            $Outcome = Get-ConsumptionAccessOutcome -ErrorMessage $Msg
            if ($Denied) { $Outcome | Should -Be 'Denied' }
            else { $Outcome | Should -Be 'Unavailable' }
        }
    }
}

Describe 'The retry loop abandons a denial and keeps retrying transients' {

    It 'checks for a denial inside the consumption retry catch' {
        $script:InvSrc | Should -Match 'Test-RdaConsumptionDenial -ErrorMessage \$_\.Exception\.Message' -Because 'without this the untyped catch retries a 403 for the full budget'
    }

    It 'evaluates the denial check BEFORE the loose throttle test' {
        # Same ordering hazard as the metrics classifier: the throttle test is a
        # loose substring match and a billing exception echoes ids/URLs that can
        # contain 429, so checking it first could reclassify a terminal denial.
        $DenialIdx = $script:InvSrc.IndexOf('Test-RdaConsumptionDenial -ErrorMessage $_.Exception.Message')
        $ThrottleIdx = $script:InvSrc.IndexOf('$ConsumptionThrottled = $_.Exception.Message -match')

        $DenialIdx | Should -BeGreaterThan -1
        $ThrottleIdx | Should -BeGreaterThan -1
        $DenialIdx | Should -BeLessThan $ThrottleIdx -Because 'a denial must be settled before any loose throttle matching runs'
    }

    It 'rethrows on a denial instead of sleeping' {
        $Block = [regex]::Match($script:InvSrc, '(?s)if \(Test-RdaConsumptionDenial.*?\r?\n\s*\}').Value
        $Block | Should -Not -BeNullOrEmpty
        $Block | Should -Match 'throw' -Because 'the denial path must propagate immediately'
        $Block | Should -Not -Match 'Start-Sleep' -Because 'there is nothing to wait for'
    }

    It 'tells the operator it will NOT retry, and what to do' {
        $script:InvSrc | Should -Match 'DENIED for' -Because 'the log must distinguish a denial from a retryable failure'
        $script:InvSrc | Should -Match 'Cost Management Reader' -Because 'a fail-loud message must name the fix'
    }

    It 'KEEPS the 30-attempt budget for transient failures' {
        # Guards the opposite regression. The Cost Management limit is shared
        # tenant-wide, so shrinking this budget truncates billing data during a
        # sustained throttle - the exact failure the large budget exists to survive.
        $script:InvSrc | Should -Match '\$ConsumptionMaxRetries = 30' -Because 'a smaller budget can expire while another pipeline still drains the shared bucket'
    }

    It 'KEEPS honouring the server-directed Retry-After' {
        $script:InvSrc | Should -Match 'Get-RdaRetryAfterSeconds -ErrorRecord \$_' -Because 'the server tells us how long to wait; guessing is worse'
    }
}

Describe 'Cost of the defect this fixes' {

    It 'would have burned about 26 minutes per subscription on a 403' {
        # Documents WHY this matters, using the loop's real backoff formula.
        $Total = 0
        for ($Attempt = 1; $Attempt -le 30; $Attempt++)
        {
            $Total += [math]::Min([math]::Pow(2, $Attempt), 60)
        }
        [math]::Round($Total / 60, 0) | Should -BeGreaterThan 20 -Because 'this is the wasted wall time the fast-fail removes, per subscription'
    }
}
