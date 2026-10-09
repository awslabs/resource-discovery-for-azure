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
    once per expiry episode, bounded per page (Test-DataPlaneAuthReady), before
    the existing backoff retries the SAME page. The ContinuationToken guard re-sends the previous page's
    token, so no rows are skipped or duplicated.

    WHAT MUST NOT REGRESS.
      - A genuine 403 denial must still short-circuit BEFORE any refresh.
      - The refresh is bounded per page: at most once per expiry episode, re-armed
        only by a successful reconnect, so a permanent 401 reconnects at most once
        and then rides out the budget to fail loud rather than reconnecting on
        every attempt.
      - Test-RdaAuthExpiry must not false-positive on an id/RG/URL echoed back in
        a billing exception (the same anchoring hazard the denial predicate has).

    Fully offline. The classifier is pure; the loop's structure is asserted from
    source (it is inline in a paging loop, not a separately callable function).
    The Describe on per-subscription scoping also runs Get-RdaSubscriptionProfile
    itself against mocked Az.Accounts reads (Get-AzContext, Get-AzSubscription):
    they make no network call, and those tests skip when Az.Accounts is absent.
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

    It 'attempts the reconnect at most once per expiry episode (guarded per page)' {
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
    # a cross-subscription billing-data leak. The per-sub loop already scopes its
    # Az calls to $sub.id (Get-RdaSubscriptionProfile through $PSDefaultParameterValues)
    # and verifies the match before its first page; the reconnect path must restore that same scope.

    It 're-pins the context to $sub.id after a successful reconnect' {
        $script:InvSrc | Should -Match "\`$PSDefaultParameterValues\['\*:DefaultProfile'\] = Get-RdaSubscriptionProfile -SubscriptionId \`$sub\.id" -Because 'the reconnect can reset the context to the identity default subscription, so the loop must re-pin to the current subscription before retrying'
    }

    It 're-verifies the context actually matched $sub.id after re-pinning' {
        $script:InvSrc | Should -Match '\(Get-AzContext\)\.Subscription\.Id -eq \$sub\.id' -Because 'Set-AzContext succeeding is not proof the scope is correct; the loop must confirm the context matches the target subscription'
    }

    It 'the re-pin happens INSIDE the auth-expiry refresh branch (after the reconnect helper)' {
        # The re-pin must sit after the Test-DataPlaneAuthReady success check, so
        # it corrects the scope that the reconnect may have moved. If the ONLY
        # re-pin were the one at the top of the per-sub loop, a
        # reconnect could still silently move the scope for the rest of the page's
        # retries.
        $RefreshIdx = $script:InvSrc.IndexOf("Test-DataPlaneAuthReady -Phase 'Consumption'")
        $RepinAfter = $script:InvSrc.IndexOf("`$PSDefaultParameterValues['*:DefaultProfile'] = Get-RdaSubscriptionProfile -SubscriptionId `$sub.id", $RefreshIdx)
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

    # THE DEFECT THIS GUARDS. The per-page guard above stops a
    # PERMANENT 401 from reconnecting on every one of the 30 attempts. But the
    # retry loop can run long on its own: each retry sleeps a server-directed
    # Retry-After clamped to 300s, so up to $ConsumptionMaxRetries attempts is
    # ~150 minutes worst case - long enough for even a freshly reconnected token to
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
            function Invoke-RefreshModel
            {
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
            # The core of the defect: a second lapse after a good reconnect gets a second
            # refresh (the old boolean stopped at exactly one).
            $Result = Invoke-RefreshModel -RefreshMax 3 -ReconnectSucceeds { param($n) $true }
            $Result.RefreshCount | Should -BeGreaterThan 1
        }

        It 'never exceeds the bounded refresh budget even if every attempt lapses' {
            $Result = Invoke-RefreshModel -RefreshMax 3 -ReconnectSucceeds { param($n) $true }
            $Result.RefreshCount | Should -Be 3
            $Result.Reconnects | Should -Be 3
        }

        It 'reconnects at most ONCE when the reconnect never yields a usable token (permanent 401)' {
            # A permanent 401: the reconnect "returns" but Test-DataPlaneAuthReady
            # reports no usable token, so the guard is never re-armed and the loop
            # rides out its budget without a reconnect storm.
            $Result = Invoke-RefreshModel -RefreshMax 3 -ReconnectSucceeds { param($n) $false }
            $Result.Reconnects | Should -Be 1
            $Result.RefreshCount | Should -Be 1
        }
    }
}

Describe 'Phases scope their Az calls per subscription without Set-AzContext' {
    # Set-AzContext moves the context every runspace in the process shares, and with context autosave
    # it rewrites the saved default subscription the operator's next session starts on. The billing,
    # Marketplace and Foundry phases now pass a per-subscription profile through a FUNCTION-LOCAL
    # $PSDefaultParameterValues instead, and the wrapper's consumption probe does the same.
    BeforeAll {
        $Repo = Split-Path $PSScriptRoot -Parent
        $script:InvAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Repo 'ResourceInventory.ps1'), [ref]$null, [ref]$null)
        $script:WrapFnAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Repo 'Functions/RunAllSubscriptions.Functions.ps1'), [ref]$null, [ref]$null)
        . (Join-Path $Repo 'Functions/Common.Functions.ps1')
        function Get-SetAzContextCalls($Ast)
        {
            @($Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.CommandAst] -and $N.GetCommandName() -eq 'Set-AzContext' }, $true))
        }
        function Get-Fn($Ast, [string]$Name)
        {
            $Ast.Find({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq $Name }, $true)
        }
    }

    It 'no longer calls Set-AzContext in ResourceInventory.ps1 or the wrapper functions' {
        (Get-SetAzContextCalls $script:InvAst).Count | Should -Be 0
        (Get-SetAzContextCalls $script:WrapFnAst).Count | Should -Be 0
    }

    It 'gives each scoping phase a function-local PSDefaultParameterValues before it sets the profile' {
        foreach ($Name in 'GetResourceConsumption', 'GetMarketplaceConsumption', 'GetFoundryTokenConsumption', 'GetFoundryModelCoverage')
        {
            $Fn = Get-Fn $script:InvAst $Name
            $Fn | Should -Not -BeNullOrEmpty -Because $Name
            $Text = $Fn.Body.Extent.Text
            $Local = $Text.IndexOf('$PSDefaultParameterValues = [System.Management.Automation.DefaultParameterDictionary]::new($PSDefaultParameterValues)')
            $Scope = $Text.IndexOf("`$PSDefaultParameterValues['*:DefaultProfile'] = Get-RdaSubscriptionProfile -SubscriptionId `$sub.id")
            $Local | Should -BeGreaterThan -1 -Because "$Name must copy PSDefaultParameterValues into its own scope"
            $Scope | Should -BeGreaterThan $Local -Because "$Name must scope only after the copy, so the scope cannot leak to the caller"
        }
        $Probe = (Get-Fn $script:WrapFnAst 'Test-ConsumptionAccess').Body.Extent.Text
        $Probe.IndexOf('$PSDefaultParameterValues = [System.Management.Automation.DefaultParameterDictionary]::new($PSDefaultParameterValues)') | Should -BeLessThan $Probe.IndexOf("`$PSDefaultParameterValues['*:DefaultProfile'] = Get-RdaSubscriptionProfile")
    }

    It 'reconnects against the process context, not the per-subscription copy' {
        $Text = (Get-Fn $script:InvAst 'Test-DataPlaneAuthReady').Body.Extent.Text
        $Text | Should -Match ([regex]::Escape("`$PSDefaultParameterValues.Remove('*:DefaultProfile')"))
        $Text.IndexOf("Remove('*:DefaultProfile')") | Should -BeLessThan $Text.IndexOf('Connect-AzAccount')
    }

    It 'keeps a function-local scope out of its caller and reaches nested calls' {
        # PSDefaultParameterValues reaches cmdlets and advanced functions, which is what the Az commands are.
        function Read-Profile { [CmdletBinding()] [OutputType([string])] param($DefaultProfile) "$DefaultProfile" }
        function Invoke-Scoped
        {
            $PSDefaultParameterValues = [System.Management.Automation.DefaultParameterDictionary]::new($PSDefaultParameterValues)
            $PSDefaultParameterValues['*:DefaultProfile'] = 'sub-B'
            function Inner { Read-Profile }
            '{0}/{1}' -f (Read-Profile), (Inner)
        }
        Invoke-Scoped | Should -Be 'sub-B/sub-B'
        Read-Profile | Should -Be '' -Because 'the scope must vanish when the phase function returns'
    }

    It 'builds a profile for the target subscription and leaves the current context as it was' -Skip:($null -eq (Get-Module -ListAvailable -Name Az.Accounts)) {
        Import-Module Az.Accounts -ErrorAction Stop
        $Current = [Microsoft.Azure.Commands.Profile.Models.Core.PSAzureContext]::new()
        $Current.Account = [Microsoft.Azure.Commands.Profile.Models.PSAzureRmAccount]::new()
        $Current.Tenant = [Microsoft.Azure.Commands.Profile.Models.PSAzureTenant]::new()
        $HomeSub = [Microsoft.Azure.Commands.Profile.Models.PSAzureSubscription]::new(); $HomeSub.Id = [guid]::NewGuid().ToString()
        $Target = [Microsoft.Azure.Commands.Profile.Models.PSAzureSubscription]::new(); $Target.Id = [guid]::NewGuid().ToString()
        $Current.Subscription = $HomeSub
        Mock Get-AzContext { $Current }
        Mock Get-AzSubscription { $Target }
        $Built = Get-RdaSubscriptionProfile -SubscriptionId $Target.Id
        ($Built -is ('Microsoft.Azure.Commands.Common.Authentication.Abstractions.Core.IAzureContextContainer' -as [type])) | Should -BeTrue
        $Built.DefaultContext.Subscription.Id | Should -Be $Target.Id
        $Current.Subscription.Id | Should -Be $HomeSub.Id -Because 'the signed-in context must not be modified'
    }

    It 'copies the current process context, not an older scoped profile that is still pinned (the re-pin after a reconnect)' -Skip:($null -eq (Get-Module -ListAvailable -Name Az.Accounts)) {
        # A reconnect replaces the process context, but the pin in $PSDefaultParameterValues still points at the
        # profile built BEFORE it. Get-AzContext and Get-AzSubscription honour that pin, so a helper that does not
        # opt out of it on both reads copies the pre-reconnect context or looks the subscription up through it.
        Import-Module Az.Accounts -ErrorAction Stop
        $ContainerType = 'Microsoft.Azure.Commands.Common.Authentication.Abstractions.Core.IAzureContextContainer' -as [type]
        $NewContext = {
            param([string]$AccountId)
            $Context = [Microsoft.Azure.Commands.Profile.Models.Core.PSAzureContext]::new()
            $Context.Account = [Microsoft.Azure.Commands.Profile.Models.PSAzureRmAccount]::new()
            $Context.Account.Id = $AccountId
            $Context.Tenant = [Microsoft.Azure.Commands.Profile.Models.PSAzureTenant]::new()
            $Context.Subscription = [Microsoft.Azure.Commands.Profile.Models.PSAzureSubscription]::new()
            $Context.Subscription.Id = [guid]::NewGuid().ToString()
            $Context
        }
        $Stale = & $NewContext 'stale-account'
        $Fresh = & $NewContext 'fresh-account'
        $Target = [Microsoft.Azure.Commands.Profile.Models.PSAzureSubscription]::new(); $Target.Id = [guid]::NewGuid().ToString()
        $StalePin = [System.Management.Automation.LanguagePrimitives]::ConvertTo($Stale, $ContainerType)
        Mock Get-AzContext { if ($null -ne $DefaultProfile) { $Stale } else { $Fresh } }
        Mock Get-AzSubscription { if ($null -ne $DefaultProfile) { throw 'looked up through the stale pin' } $Target }
        # A copy of the session dictionary, as the phases make one, so the pin set here leaves with this test and
        # any pin the session itself holds is untouched.
        $PSDefaultParameterValues = [System.Management.Automation.DefaultParameterDictionary]::new($PSDefaultParameterValues)
        $PSDefaultParameterValues['*:DefaultProfile'] = $StalePin
        $Built = Get-RdaSubscriptionProfile -SubscriptionId $Target.Id
        Should -Invoke Get-AzSubscription -Times 0 -Exactly -ParameterFilter { $null -ne $DefaultProfile } -Because 'neither lookup may go through the stale pin, not even one whose failure the other would cover'
        $Built.DefaultContext.Account.Id | Should -Be 'fresh-account' -Because 'the helper must build from the context the process holds now, not from a pin that predates the reconnect'
        $Built.DefaultContext.Subscription.Id | Should -Be $Target.Id
    }

    It 'finds a subscription that lives in another tenant than the signed-in context, and scopes the profile to that tenant' -Skip:($null -eq (Get-Module -ListAvailable -Name Az.Accounts)) {
        # Get-AzSubscription -TenantId <the context's tenant> throws for a subscription that belongs to a
        # different tenant, which made the helper refuse every billing call for it ("not visible to the
        # signed-in identity") although the identity can read it.
        Import-Module Az.Accounts -ErrorAction Stop
        $HomeTenantId = [guid]::NewGuid().ToString()
        $OtherTenantId = [guid]::NewGuid().ToString()
        $Current = [Microsoft.Azure.Commands.Profile.Models.Core.PSAzureContext]::new()
        $Current.Account = [Microsoft.Azure.Commands.Profile.Models.PSAzureRmAccount]::new()
        $Current.Tenant = [Microsoft.Azure.Commands.Profile.Models.PSAzureTenant]::new()
        $Current.Tenant.Id = $HomeTenantId
        $Current.Subscription = [Microsoft.Azure.Commands.Profile.Models.PSAzureSubscription]::new()
        $Current.Subscription.Id = [guid]::NewGuid().ToString()
        $Target = [Microsoft.Azure.Commands.Profile.Models.PSAzureSubscription]::new()
        $Target.Id = [guid]::NewGuid().ToString()
        $Target.TenantId = $OtherTenantId
        Mock Get-AzContext { $Current }
        Mock Get-AzSubscription {
            if ($TenantId -and $TenantId -ne $OtherTenantId) { throw 'SubscriptionNotFound: the subscription was not found in this tenant' }
            $Target
        }
        { Get-RdaSubscriptionProfile -SubscriptionId $Target.Id } | Should -Not -Throw -Because 'the subscription exists in another tenant the identity can read'
        $Built = Get-RdaSubscriptionProfile -SubscriptionId $Target.Id
        $Built.DefaultContext.Subscription.Id | Should -Be $Target.Id
        $Built.DefaultContext.Tenant.Id | Should -Be $OtherTenantId -Because 'the profile must be scoped to the tenant the subscription belongs to'
        $Current.Tenant.Id | Should -Be $HomeTenantId -Because 'the signed-in context must not be modified'
    }

    It 'takes the signed-in tenant''s copy when the lookup without a tenant returns the subscription once per tenant' -Skip:($null -eq (Get-Module -ListAvailable -Name Az.Accounts)) {
        # A subscription reachable through two tenants comes back twice from the lookup without a tenant. If the
        # first lookup failed only for a moment, the profile must keep the tenant the run names.
        Import-Module Az.Accounts -ErrorAction Stop
        $HomeTenantId = [guid]::NewGuid().ToString()
        $OtherTenantId = [guid]::NewGuid().ToString()
        $SharedId = [guid]::NewGuid().ToString()
        $Current = [Microsoft.Azure.Commands.Profile.Models.Core.PSAzureContext]::new()
        $Current.Account = [Microsoft.Azure.Commands.Profile.Models.PSAzureRmAccount]::new()
        $Current.Tenant = [Microsoft.Azure.Commands.Profile.Models.PSAzureTenant]::new()
        $Current.Tenant.Id = $HomeTenantId
        $Current.Subscription = [Microsoft.Azure.Commands.Profile.Models.PSAzureSubscription]::new()
        $Current.Subscription.Id = [guid]::NewGuid().ToString()
        $OtherCopy = [Microsoft.Azure.Commands.Profile.Models.PSAzureSubscription]::new()
        $OtherCopy.Id = $SharedId
        $OtherCopy.TenantId = $OtherTenantId
        $HomeCopy = [Microsoft.Azure.Commands.Profile.Models.PSAzureSubscription]::new()
        $HomeCopy.Id = $SharedId
        $HomeCopy.TenantId = $HomeTenantId
        Mock Get-AzContext { $Current }
        Mock Get-AzSubscription {
            if ($TenantId) { throw 'a transient failure of the first lookup' }
            @($OtherCopy, $HomeCopy)
        }
        $Built = Get-RdaSubscriptionProfile -SubscriptionId $SharedId
        $Built.DefaultContext.Subscription.TenantId | Should -Be $HomeTenantId -Because 'the copy in the signed-in tenant is taken, although it came second'
        $Built.DefaultContext.Tenant.Id | Should -Be $HomeTenantId -Because 'the profile keeps the tenant the run names'
    }

    It 'keeps the signed-in tenant failure in the debug log, not in the error, when the lookup without a tenant also fails' -Skip:($null -eq (Get-Module -ListAvailable -Name Az.Accounts)) {
        # The lookup without a tenant reports what that lookup found, which can be a bare "not found" even
        # when the signed-in tenant actually failed on a token: per-tenant token failures come out of that
        # lookup as warnings, which -WarningAction SilentlyContinue hides, so the first failure is what names
        # the real cause. Its text can name the tenant, its domain or a local path, and callers copy the
        # error message into skip entries that ship in Diagnostics_*.log, so that text goes to the debug log
        # only (kept local in an -Obfuscate run) and the message says where it went.
        Import-Module Az.Accounts -ErrorAction Stop
        $HomeTenantId = [guid]::NewGuid().ToString()
        $Current = [Microsoft.Azure.Commands.Profile.Models.Core.PSAzureContext]::new()
        $Current.Account = [Microsoft.Azure.Commands.Profile.Models.PSAzureRmAccount]::new()
        $Current.Tenant = [Microsoft.Azure.Commands.Profile.Models.PSAzureTenant]::new()
        $Current.Tenant.Id = $HomeTenantId
        $Current.Subscription = [Microsoft.Azure.Commands.Profile.Models.PSAzureSubscription]::new()
        $Current.Subscription.Id = [guid]::NewGuid().ToString()
        Mock Get-AzContext { $Current }
        Mock Get-AzSubscription {
            if ($TenantId) { throw 'AADSTS50076: the refresh token for the signed-in tenant has expired' }
            throw 'SubscriptionNotFound: the subscription was not found'
        }
        $DebugLog = Join-Path $TestDrive 'debug-first-lookup.log'
        $ErrorLog = Join-Path $TestDrive 'error-first-lookup.log'
        $SavedLogs = @($Global:DebugLogFile, $Global:ErrorLogFile)
        $Global:DebugLogFile = $DebugLog
        $Global:ErrorLogFile = $ErrorLog
        $Thrown = $null
        try { $null = Get-RdaSubscriptionProfile -SubscriptionId ([guid]::NewGuid().ToString()) } catch { $Thrown = $_ }
        finally { $Global:DebugLogFile = $SavedLogs[0]; $Global:ErrorLogFile = $SavedLogs[1] }
        $Thrown | Should -Not -BeNullOrEmpty -Because 'the caller keeps its skip path'
        $Thrown.Exception.Message | Should -Be 'SubscriptionNotFound: the subscription was not found (the lookup in the signed-in tenant had also failed; its error is in the debug log)' -Because 'the second lookup is the real answer, in its own words as before, and the message says where the first failure went'
        $Thrown.Exception.Message | Should -Not -BeLike '*AADSTS50076*' -Because 'the first failure''s text can name the tenant, its domain or a local path, and this message reaches Diagnostics_*.log'
        $Thrown.Exception.Message | Should -Not -BeLike ('*{0}*' -f $HomeTenantId)
        $Debug = Get-Content -LiteralPath $DebugLog -Raw
        $Debug | Should -BeLike '*AADSTS50076: the refresh token for the signed-in tenant has expired*' -Because 'the first failure is what names the real cause'
        $Debug | Should -BeLike ('*tenant {0}*' -f $HomeTenantId) -Because 'the operator needs to know which tenant that first lookup used'
        Test-Path -LiteralPath $ErrorLog | Should -BeFalse -Because 'the detail belongs in the debug log, not in the error log'
        $Thrown.Exception.InnerException | Should -Not -BeNullOrEmpty -Because 'the original failure is kept for anything that inspects the exception rather than its text'
        $Thrown.Exception.InnerException.Message | Should -Be 'SubscriptionNotFound: the subscription was not found'
    }

    It 'does not point at a debug log when none is being written' -Skip:($null -eq (Get-Module -ListAvailable -Name Az.Accounts)) {
        # The wrapper's consumption probe looks its subscription up before any inner run has opened a debug log.
        Import-Module Az.Accounts -ErrorAction Stop
        $Current = [Microsoft.Azure.Commands.Profile.Models.Core.PSAzureContext]::new()
        $Current.Account = [Microsoft.Azure.Commands.Profile.Models.PSAzureRmAccount]::new()
        $Current.Tenant = [Microsoft.Azure.Commands.Profile.Models.PSAzureTenant]::new()
        $Current.Tenant.Id = [guid]::NewGuid().ToString()
        $Current.Subscription = [Microsoft.Azure.Commands.Profile.Models.PSAzureSubscription]::new()
        $Current.Subscription.Id = [guid]::NewGuid().ToString()
        Mock Get-AzContext { $Current }
        Mock Get-AzSubscription {
            if ($TenantId) { throw 'AADSTS50076: the refresh token for the signed-in tenant has expired' }
            throw 'SubscriptionNotFound: the subscription was not found'
        }
        $SavedDebugLog = $Global:DebugLogFile
        $Global:DebugLogFile = $null
        $Thrown = $null
        try { $null = Get-RdaSubscriptionProfile -SubscriptionId ([guid]::NewGuid().ToString()) } catch { $Thrown = $_ }
        finally { $Global:DebugLogFile = $SavedDebugLog }
        $Thrown.Exception.Message | Should -Be 'SubscriptionNotFound: the subscription was not found (the lookup in the signed-in tenant had also failed)' -Because 'a pointer to a log that does not exist sends the operator looking for nothing'
    }

    It 'passes the second lookup''s error on untouched when the signed-in tenant simply did not have the subscription' -Skip:($null -eq (Get-Module -ListAvailable -Name Az.Accounts)) {
        # The first lookup found nothing without failing, so there is no first error to keep or point at.
        Import-Module Az.Accounts -ErrorAction Stop
        $Current = [Microsoft.Azure.Commands.Profile.Models.Core.PSAzureContext]::new()
        $Current.Account = [Microsoft.Azure.Commands.Profile.Models.PSAzureRmAccount]::new()
        $Current.Tenant = [Microsoft.Azure.Commands.Profile.Models.PSAzureTenant]::new()
        $Current.Tenant.Id = [guid]::NewGuid().ToString()
        $Current.Subscription = [Microsoft.Azure.Commands.Profile.Models.PSAzureSubscription]::new()
        $Current.Subscription.Id = [guid]::NewGuid().ToString()
        Mock Get-AzContext { $Current }
        Mock Get-AzSubscription {
            if ($TenantId) { return $null }
            throw 'SubscriptionNotFound: the subscription was not found'
        }
        $DebugLog = Join-Path $TestDrive 'debug-no-first-error.log'
        $SavedDebugLog = $Global:DebugLogFile
        $Global:DebugLogFile = $DebugLog
        $Thrown = $null
        try { $null = Get-RdaSubscriptionProfile -SubscriptionId ([guid]::NewGuid().ToString()) } catch { $Thrown = $_ }
        finally { $Global:DebugLogFile = $SavedDebugLog }
        $Thrown.Exception.Message | Should -Be 'SubscriptionNotFound: the subscription was not found'
        Test-Path -LiteralPath $DebugLog | Should -BeFalse -Because 'there is no first failure to record'
    }

    It 'throws when there is no signed-in context, so the phase takes its skip path' -Skip:($null -eq (Get-Module -ListAvailable -Name Az.Accounts)) {
        Import-Module Az.Accounts -ErrorAction Stop
        Mock Get-AzContext { $null }
        { Get-RdaSubscriptionProfile -SubscriptionId 'x' } | Should -Throw '*no signed-in Azure context*'
    }
}
