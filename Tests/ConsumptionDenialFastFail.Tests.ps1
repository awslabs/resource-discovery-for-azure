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

    OUT OF MEMORY. Backing off cannot free memory, so an out-of-memory failure,
    as classified by Test-RdaOutOfMemory (also in Functions/Common.Functions.ps1),
    gets one heap compaction and one retry of the same page, then ends that
    subscription's consumption loudly instead of riding out the 30-attempt budget.

    THE MARKETPLACE ENVELOPE IS ASSERTED HERE TOO. GetMarketplaceConsumption runs the
    same retry envelope around Get-AzConsumptionMarketplace, so it carried the same
    defect; its out-of-memory branch is guarded by the last Describe below. That call
    is UNPAGED - the endpoint returns the whole window in one response - so its retry
    re-requests the same size and can only recover a fragmented heap, and the
    per-subscription guard is reset per SUBSCRIPTION rather than per page.

    SCOPING. Several call shapes (the denial check, the DENIED wording, the Retry-After
    read, Get-RdaRetryAfterSeconds) now appear in BOTH envelopes, so an assertion about
    one of them matches $script:ConsumptionFnText or $script:MarketplaceFnText - the
    function's own source - never the whole file, which either envelope alone would
    satisfy.

    Fully offline. The classifiers are pure, and most of the loop's structure is
    asserted from source (it is inline in a paging loop, not a function). The
    out-of-memory tests go further: they lift the real page loop, the whole paging
    try/catch and the outer catch's out-of-memory report out of ResourceInventory.ps1
    by AST and run them with the billing call, Export-Csv, Write-Log and Start-Sleep
    replaced and Get-RdaRetryAfterSeconds stubbed. None of the injected errors is an
    expired token, so the re-authentication branch never runs; Test-DataPlaneAuthReady
    is stubbed to throw so that stays loud if it ever does.
#>

BeforeAll {
    $script:Repo = Split-Path $PSScriptRoot -Parent
    $script:CommonPath = Join-Path $script:Repo 'Functions/Common.Functions.ps1'
    $script:WrapperFnPath = Join-Path $script:Repo 'Functions/RunAllSubscriptions.Functions.ps1'
    $script:InvPath = Join-Path $script:Repo 'ResourceInventory.ps1'

    . $script:CommonPath
    . $script:WrapperFnPath

    $script:InvSrc = Get-Content -LiteralPath $script:InvPath -Raw

    # Per-function source. A whole-file match is satisfied by EITHER billing envelope, so
    # deleting the assertion's real subject would leave it green; these keep each assertion
    # answerable only by the function it names.
    $script:InvAstTop = [System.Management.Automation.Language.Parser]::ParseFile($script:InvPath, [ref]$null, [ref]$null)
    foreach ($Pair in @(@{ Name = 'GetResourceConsumption'; Var = 'ConsumptionFnText' }, @{ Name = 'GetMarketplaceConsumption'; Var = 'MarketplaceFnText' }))
    {
        $Found = $script:InvAstTop.Find([scriptblock]::Create(('param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq ''{0}''' -f $Pair.Name)), $true)
        if (-not $Found) { throw ('{0} was not found in ResourceInventory.ps1.' -f $Pair.Name) }
        Set-Variable -Name $Pair.Var -Scope Script -Value $Found.Extent.Text
    }
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
        $script:ConsumptionFnText | Should -Match 'Test-RdaConsumptionDenial -ErrorMessage \$_\.Exception\.Message' -Because 'without this the untyped catch retries a 403 for the full budget'
    }

    It 'evaluates the denial check BEFORE the loose throttle test' {
        # Same ordering hazard as the metrics classifier: the throttle test is a
        # loose substring match and a billing exception echoes ids/URLs that can
        # contain 429, so checking it first could reclassify a terminal denial.
        $DenialIdx = $script:ConsumptionFnText.IndexOf('Test-RdaConsumptionDenial -ErrorMessage $_.Exception.Message')
        $ThrottleIdx = $script:ConsumptionFnText.IndexOf('$ConsumptionThrottled = $_.Exception.Message -match')

        $DenialIdx | Should -BeGreaterThan -1
        $ThrottleIdx | Should -BeGreaterThan -1
        $DenialIdx | Should -BeLessThan $ThrottleIdx -Because 'a denial must be settled before any loose throttle matching runs'
    }

    It 'rethrows on a denial instead of sleeping' {
        $Block = [regex]::Match($script:ConsumptionFnText, '(?s)if \(Test-RdaConsumptionDenial.*?\r?\n\s*\}').Value
        $Block | Should -Not -BeNullOrEmpty
        $Block | Should -Match 'throw' -Because 'the denial path must propagate immediately'
        $Block | Should -Not -Match 'Start-Sleep' -Because 'there is nothing to wait for'
    }

    It 'tells the operator it will NOT retry, and what to do' {
        $script:ConsumptionFnText | Should -Match 'DENIED for' -Because 'the log must distinguish a denial from a retryable failure'
        $script:ConsumptionFnText | Should -Match 'Cost Management Reader' -Because 'a fail-loud message must name the fix'
    }

    It 'KEEPS the 30-attempt budget for transient failures' {
        # Guards the opposite regression. The Cost Management limit is shared
        # tenant-wide, so shrinking this budget truncates billing data during a
        # sustained throttle - the exact failure the large budget exists to survive.
        $script:InvSrc | Should -Match '\$ConsumptionMaxRetries = 30' -Because 'a smaller budget can expire while another pipeline still drains the shared bucket'
    }

    It 'KEEPS honouring the server-directed Retry-After' {
        $script:ConsumptionFnText | Should -Match 'Get-RdaRetryAfterSeconds -ErrorRecord \$_' -Because 'the server tells us how long to wait; guessing is worse'
    }
}

Describe 'Cost of the defect this fixes' {

    It 'would have burned about 26 minutes per subscription on a 403' {
        # Derive BOTH inputs from source so this stays a guard, not documentation:
        # the budget and the backoff cap are read out of the live loop, so shrinking
        # either in ResourceInventory.ps1 changes the computed wall time here (and,
        # for a large enough shrink, fails this assertion) instead of leaving a
        # hard-coded ~26 that passes regardless of the implementation.
        $MaxRetries = [int]([regex]::Match($script:InvSrc, '\$ConsumptionMaxRetries = (\d+)').Groups[1].Value)
        $BackoffCap = [int]([regex]::Match($script:InvSrc, '\[math\]::Min\(\[math\]::Pow\(2,\s*\$ConsumptionAttempt\),\s*(\d+)\)').Groups[1].Value)

        $MaxRetries | Should -BeGreaterThan 0 -Because 'the retry budget must be read out of the loop, not assumed'
        $BackoffCap | Should -BeGreaterThan 0 -Because 'the exponential backoff cap must be read out of the loop, not assumed'

        $Total = 0
        for ($Attempt = 1; $Attempt -le $MaxRetries; $Attempt++)
        {
            $Total += [math]::Min([math]::Pow(2, $Attempt), $BackoffCap)
        }
        [math]::Round($Total / 60, 0) | Should -BeGreaterThan 20 -Because 'this is the wasted wall time the fast-fail removes, per subscription'
    }
}

Describe 'Test-RdaOutOfMemory: out-of-memory text only' {

    It 'classifies <Label> as out of memory, and not as a denial' -ForEach @(
        @{ Label = 'the allocation failure, from the runtime''s own message template'; Msg = (([System.Exception]::new([NullString]::Value).Message) -replace 'System\.Exception', 'System.OutOfMemoryException') }
        @{ Label = 'the allocation failure as seen in the field'; Msg = "Exception of type 'System.OutOfMemoryException' was thrown." }
        @{ Label = 'the Az cmdlet wrapper around it'; Msg = "One or more errors occurred. (Exception of type 'System.OutOfMemoryException' was thrown.)" }
        @{ Label = 'the default text of a constructed exception'; Msg = ([System.OutOfMemoryException]::new().Message) }
        @{ Label = 'an aggregate around a constructed exception'; Msg = ([System.AggregateException]::new([System.Exception[]]@([System.OutOfMemoryException]::new())).Message) }
        @{ Label = 'an InsufficientMemoryException'; Msg = ([System.InsufficientMemoryException]::new().Message) }
    ) {
        Test-RdaOutOfMemory -ErrorMessage $Msg | Should -BeTrue
        Test-RdaConsumptionDenial -ErrorMessage $Msg | Should -BeFalse -Because 'the page loop checks for a denial first, and a denial is abandoned without any retry'
    }

    It 'does NOT classify <Label> as out of memory' -ForEach @(
        @{ Label = 'a 403 denial'; Msg = 'Response status code does not indicate success: 403 (Forbidden).' }
        @{ Label = 'a 429 throttle'; Msg = 'Operation returned an invalid status code 429 TooManyRequests' }
        @{ Label = 'the transient stream-copy error'; Msg = 'Error while copying content to a stream' }
        @{ Label = 'an expired token'; Msg = 'ExpiredAuthenticationToken: The access token expiry UTC time is earlier than current UTC time' }
        @{ Label = 'a resource group named rg-OutOfMemoryException-01'; Msg = 'Error while copying content to a stream for rg-OutOfMemoryException-01' }
        @{ Label = 'a lower-cased echo of the type name'; Msg = 'The operation has timed out for outofmemoryexception' }
        @{ Label = 'the runtime sentence in lower case'; Msg = "exception of type 'system.outofmemoryexception' was thrown." }
        @{ Label = 'a resource named OutOfMemoryException-01'; Msg = 'Error while copying content to a stream for OutOfMemoryException-01' }
        @{ Label = 'a resource named MyOutOfMemoryException'; Msg = 'The operation has timed out for MyOutOfMemoryException' }
        @{ Label = 'a resource named OutOfMemoryExceptionHandler'; Msg = 'Error while copying content to a stream for OutOfMemoryExceptionHandler' }
        @{ Label = 'the bare type name without the runtime message'; Msg = 'The operation has timed out for System.OutOfMemoryException' }
        @{ Label = 'a server that reports running out of memory'; Msg = 'Operation returned an invalid status code 500. The server ran out of memory, retry later' }
        @{ Label = 'an empty message'; Msg = '' }
        @{ Label = 'a null message'; Msg = $null }
    ) {
        Test-RdaOutOfMemory -ErrorMessage $Msg | Should -BeFalse
    }
}

Describe 'The page loop gives an out-of-memory error one compacted retry, then stops' {

    BeforeAll {
        # Execute the SHIPPED code rather than a copy of it: lift the page loop (with every
        # statement that precedes it in the page body) and the whole paging try/catch out of
        # GetResourceConsumption by AST, and replace only the leaf commands they call. The inputs
        # they read from their caller are set at the top of the lifted code so every test starts
        # equal; the previous page's continuation token is 'token-page-2'.
        $ParseErrors = $null
        $InvAst = [System.Management.Automation.Language.Parser]::ParseFile($script:InvPath, [ref]$null, [ref]$ParseErrors)
        if ($ParseErrors) { throw ('ResourceInventory.ps1 does not parse: ' + (($ParseErrors | ForEach-Object { $_.Message }) -join '; ')) }
        $Fn = $InvAst.Find({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq 'GetResourceConsumption' }, $true)
        if (-not $Fn) { throw 'GetResourceConsumption was not found in ResourceInventory.ps1.' }
        $Loop = $Fn.Find({ param($N) $N -is [System.Management.Automation.Language.WhileStatementAst] -and $N.Condition.Extent.Text -eq '$true' -and $N.Extent.Text -match 'Get-UsageAggregates' }, $true)
        if (-not $Loop) { throw 'The page loop (while ($true) around Get-UsageAggregates) was not found in GetResourceConsumption.' }
        $Setup = @($Loop.Parent.Statements | Where-Object { $_.Extent.EndOffset -le $Loop.Extent.StartOffset })
        $script:PageSetup = @($Setup | Where-Object { $_ -is [System.Management.Automation.Language.AssignmentStatementAst] })
        if ($script:PageSetup.Count -eq 0) { throw 'No per-page assignments were found ahead of the page loop.' }
        # The statement that owns the setup: it has to be the paging do/while, so the setup runs once per page.
        $script:PageScope = $Loop.Parent.Parent
        $Inputs = @(
            '$sub = [pscustomobject]@{ Name = ''test-sub''; Id = ''12345678-1234-1234-1234-123456789012'' }'
            '$ReportedStartTime = ''2026-08-01'''
            '$ReportedEndTime = ''2026-08-31'''
            '$ConsumptionPageIndex = 1'
            '$UsageData = [pscustomobject]@{ ContinuationToken = ''token-page-2'' }'
        )
        $script:PageLoop = [scriptblock]::Create(((@($Inputs) + @($Setup | ForEach-Object { $_.Extent.Text }) + $Loop.Extent.Text) -join [Environment]::NewLine))
        $script:OomClause = $Loop.Find({ param($N) $N -is [System.Management.Automation.Language.IfStatementAst] -and $N.Clauses[0].Item1.Extent.Text -match '^Test-RdaOutOfMemory\b' }, $true)

        # The per-subscription catch and the try it closes: the whole paging try/catch runs with the
        # per-subscription counters that precede it, so an error after the fetch can be followed
        # into the outer catch.
        $OuterCatch = $Fn.Find({ param($N) $N -is [System.Management.Automation.Language.CatchClauseAst] -and $N.Extent.Text -match 'stopped at consumption page' }, $true)
        if (-not $OuterCatch) { throw 'The per-subscription consumption catch was not found in GetResourceConsumption.' }
        $PagingTry = $OuterCatch.Parent
        $PerSubscription = @($PagingTry.Parent.Statements | Where-Object {
                $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $_.Extent.EndOffset -le $PagingTry.Extent.StartOffset -and
                $_.Left.Extent.Text -match '^\$(Consumption\w+|UsageData)$'
            })
        $SubscriptionInputs = @(
            '$sub = [pscustomobject]@{ Name = ''test-sub''; Id = ''12345678-1234-1234-1234-123456789012'' }'
            '$ReportedStartTime = ''2026-08-01'''
            '$ReportedEndTime = ''2026-08-31'''
            '$ResourceGroup = $null'
            '$Obfuscate = [switch]$false'
            '$SubscriptionID = ''12345678-1234-1234-1234-123456789012'''
            '$DefaultPath = ''report-folder/'''
        )
        $script:PagingBlock = [scriptblock]::Create(((@($SubscriptionInputs) + @($PerSubscription | ForEach-Object { $_.Extent.Text }) + $PagingTry.Extent.Text) -join [Environment]::NewLine))

        # The out-of-memory report in the per-subscription catch, run inside a catch of its own so
        # $_ carries the error it inspects. Its inputs are parameters of the lifted block.
        $script:OuterOomClause = $OuterCatch.Body.Find({ param($N) $N -is [System.Management.Automation.Language.IfStatementAst] -and $N.Clauses[0].Item1.Extent.Text -match '^Test-RdaOutOfMemory\b' }, $true)
        if ($script:OuterOomClause)
        {
            $script:OuterOomBlock = [scriptblock]::Create((@(
                        'param($sub, $Obfuscate, $SubscriptionID, $DefaultPath)'
                        'try { throw "Exception of type ''System.OutOfMemoryException'' was thrown." }'
                        'catch'
                        '{'
                        $script:OuterOomClause.Extent.Text
                        '}'
                    ) -join [Environment]::NewLine))
        }

        # Lives in Functions/ResourceInventory.Functions.ps1, which this file does not load; the
        # backoff length is irrelevant here because Start-Sleep is mocked.
        function Get-RdaRetryAfterSeconds { 0 }
        # The re-authentication branch must never run here; if a test ever reaches it, fail loudly
        # instead of opening a real sign-in from an offline suite.
        function Test-DataPlaneAuthReady { throw 'The re-authentication branch ran in an offline test.' }

        # Get-UsageAggregates is an ALIAS exported by Az.Billing, and in PowerShell an alias
        # OUTRANKS a function - so every 'function Get-UsageAggregates' shadow below is silently
        # ignored once anything in the same session has imported that module, and the real cmdlet
        # runs and asks for its mandatory parameters. This Describe passed alone and failed in a
        # batched run because of it. Removed once for the Describe and restored in AfterAll, so
        # there is no per-test window and any suite that legitimately resolves the alias still can.
        # The whole alias item is kept, not just its definition: rebuilding from -Value alone would
        # drop Options such as ReadOnly.
        $script:SavedUsageAlias = $null
        if (Test-Path -LiteralPath 'Alias:Get-UsageAggregates')
        {
            $script:SavedUsageAlias = Get-Item -LiteralPath 'Alias:Get-UsageAggregates'
            Remove-Item -LiteralPath 'Alias:Get-UsageAggregates' -Force
        }
    }

    AfterAll {
        if ($script:SavedUsageAlias -and -not (Test-Path -LiteralPath 'Alias:Get-UsageAggregates'))
        {
            Set-Alias -Name 'Get-UsageAggregates' -Value $script:SavedUsageAlias.Definition -Option $script:SavedUsageAlias.Options -Scope Global
        }
    }

    BeforeEach {
        $script:Fetches = 0
        $script:Tokens = @()
        Mock Start-Sleep { }
        Mock Write-Log { }
    }

    It 'resets the out-of-memory guard on every page, with the other per-page retry state' {
        $script:PageScope | Should -BeOfType ([System.Management.Automation.Language.DoWhileStatementAst]) -Because 'the setup has to run once per page, inside the paging do/while'
        $Guard = @($script:PageSetup | Where-Object { $_.Left.Extent.Text -eq '$ConsumptionOutOfMemoryRetried' })
        $Guard.Count | Should -Be 1
        $Guard[0].Right.Extent.Text | Should -Be '$false' -Because 'each page must get its own single retry'
    }

    It 'releases the previous page and forces a full compacting collection before it retries' {
        $script:OomClause | Should -Not -BeNullOrEmpty -Because 'the retry catch must single out an out-of-memory error'
        $Body = $script:OomClause.Clauses[0].Item2
        $Continue = $Body.Find({ param($N) $N -is [System.Management.Automation.Language.ContinueStatementAst] }, $true)
        $CompactOnce = $Body.Find({ param($N) $N -is [System.Management.Automation.Language.AssignmentStatementAst] -and $N.Left.Extent.Text -eq '[System.Runtime.GCSettings]::LargeObjectHeapCompactionMode' -and $N.Right.Extent.Text -match '::CompactOnce$' }, $true)
        $Collect = $Body.Find({ param($N) $N -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $N.Expression.Extent.Text -eq '[System.GC]' -and $N.Member.Extent.Text -eq 'Collect' }, $true)
        $Released = @($Body.FindAll({ param($N) $N -is [System.Management.Automation.Language.AssignmentStatementAst] -and $N.Right.Extent.Text -eq '$null' }, $true))

        $Continue | Should -Not -BeNullOrEmpty
        $CompactOnce | Should -Not -BeNullOrEmpty
        $Collect | Should -Not -BeNullOrEmpty
        (@($Collect.Arguments | ForEach-Object { $_.Extent.Text }) -join ', ') | Should -Be '[System.GC]::MaxGeneration, [System.GCCollectionMode]::Forced, $true, $true' -Because 'only a forced, blocking, compacting full collection applies the compaction mode'
        foreach ($Name in '$UsageData', '$UsageDataExport', '$NewUsageDataExport')
        {
            $Release = $Released | Where-Object { $_.Left.Extent.Text -eq $Name } | Select-Object -First 1
            $Release | Should -Not -BeNullOrEmpty -Because "$Name holds the previous page"
            $Release.Extent.StartOffset | Should -BeLessThan $Collect.Extent.StartOffset -Because 'a page still referenced cannot be collected'
        }
        $CompactOnce.Extent.StartOffset | Should -BeLessThan $Collect.Extent.StartOffset -Because 'the compaction mode applies to the next full collection'
        $Collect.Extent.StartOffset | Should -BeLessThan $Continue.Extent.StartOffset
    }

    It 'retries the same page once after an out-of-memory error, without backing off, and carries on' {
        function Get-UsageAggregates
        {
            param($ContinuationToken)
            $script:Fetches++
            $script:Tokens += , $ContinuationToken
            if ($script:Fetches -eq 1) { throw "Exception of type 'System.OutOfMemoryException' was thrown." }
            [pscustomobject]@{ Marker = 'page-2'; ContinuationToken = $null }
        }

        . $script:PageLoop

        $script:Fetches | Should -Be 2 -Because 'one retry after the compaction'
        ($script:Tokens -join ',') | Should -Be 'token-page-2,token-page-2' -Because 'the retry asks for the same page, not page 1 again'
        $UsageData.Marker | Should -Be 'page-2' -Because 'the retried page is handed on to the export'
        Should -Invoke Start-Sleep -Exactly -Times 0 -Because 'backing off cannot free memory'
        Should -Invoke Write-Log -Exactly -Times 1 -ParameterFilter { $Severity -eq 'Warning' -and $Message -match 'ran out of memory' -and $Message -notmatch '\.\.' }
    }

    It 'checks for a denial before the out-of-memory test, so a denial is never retried' {
        $Text = $script:PageLoop.ToString()
        $Denial = $Text.IndexOf('Test-RdaConsumptionDenial -ErrorMessage $_.Exception.Message', [System.StringComparison]::Ordinal)
        $Oom = $Text.IndexOf('Test-RdaOutOfMemory -ErrorMessage $_.Exception.Message', [System.StringComparison]::Ordinal)
        $Denial | Should -BeGreaterThan -1
        $Oom | Should -BeGreaterThan $Denial -Because 'a denial is abandoned outright; only a non-denial gets the compacted retry'
    }
    It 'stops after a second out-of-memory error instead of spending the retry budget' {
        function Get-UsageAggregates
        {
            $script:Fetches++
            # Serves the page from the third call on, so a regression that spends the normal retry
            # budget on out-of-memory completes the page instead and fails the assertions below.
            if ($script:Fetches -ge 3) { return [pscustomobject]@{ ContinuationToken = $null } }
            throw "One or more errors occurred. (Exception of type 'System.OutOfMemoryException' was thrown.)"
        }

        $Thrown = { . $script:PageLoop } | Should -Throw -PassThru
        Test-RdaOutOfMemory -ErrorMessage $Thrown.Exception.Message | Should -BeTrue -Because 'the outer catch recognises the stop with the same classifier'
        $script:Fetches | Should -Be 2 -Because 'one compacted retry, not the 30-attempt budget'
        Should -Invoke Start-Sleep -Exactly -Times 0
    }

    It 'still retries an ordinary transient error with backoff' {
        function Get-UsageAggregates
        {
            $script:Fetches++
            if ($script:Fetches -le 2) { throw 'Error while copying content to a stream' }
            [pscustomobject]@{ ContinuationToken = $null }
        }

        . $script:PageLoop

        $script:Fetches | Should -Be 3
        Should -Invoke Start-Sleep -Exactly -Times 2 -Because 'transient errors keep the existing backoff'
    }

    It 'does not retry an out-of-memory error raised while a page is written' {
        # Export-Csv may already have appended part of the page, so a retry here could write the
        # same billing rows twice; the error must go straight to the per-subscription catch.
        function Get-UsageAggregates
        {
            $script:Fetches++
            [pscustomobject]@{
                ContinuationToken = $null
                UsageAggregations = @([pscustomobject]@{ Properties = [pscustomobject]@{
                            InstanceData     = '{"Microsoft.Resources":{"resourceUri":"/subscriptions/12345678-1234-1234-1234-123456789012/resourceGroups/rg-test/providers/Microsoft.Compute/virtualMachines/vm-test","location":"westeurope","additionalInfo":{}}}'
                            MeterCategory    = 'Virtual Machines'
                            MeterId          = 'meter-1'
                            MeterName        = 'D2s v3'
                            MeterRegion      = 'EU West'
                            MeterSubCategory = ''
                            Quantity         = 24
                            Unit             = '1 Hour'
                            UsageStartTime   = '2026-08-01T00:00:00Z'
                            UsageEndTime     = '2026-08-02T00:00:00Z'
                        }
                    })
            }
        }
        # The lifted block leaves the CSV path unset and passes -Encoding as a string, so the mock
        # drops the path validation and the Encoding type the real cmdlet converts it with.
        Mock Export-Csv { throw "Exception of type 'System.OutOfMemoryException' was thrown." } -RemoveParameterType Encoding -RemoveParameterValidation LiteralPath

        . $script:PagingBlock

        $script:Fetches | Should -Be 1 -Because 'the fetch succeeded, so it is not repeated'
        Should -Invoke Export-Csv -Exactly -Times 1 -Because 'the page is not written a second time'
        $ConsumptionFailedThisSub | Should -BeTrue
        $ConsumptionFailureMessage | Should -Match 'stopped at consumption page 1, after 0 record\(s\)'
        Should -Invoke Write-Log -Exactly -Times 0 -ParameterFilter { $Message -match 'retrying this page once' }
        Should -Invoke Write-Log -Exactly -Times 1 -ParameterFilter { $Severity -eq 'Error' -and $Message -match 'ran out of memory' -and $Message -match 'fresh PowerShell process' }
    }
    It 'reports a second out-of-memory fetch failure through the per-subscription catch' {
        function Get-UsageAggregates
        {
            $script:Fetches++
            throw "Exception of type 'System.OutOfMemoryException' was thrown."
        }
        . $script:PagingBlock
        $script:Fetches | Should -Be 2 -Because 'one compacted retry, then the stop'
        $ConsumptionFailedThisSub | Should -BeTrue
        $ConsumptionFailureMessage | Should -Match 'stopped at consumption page 1, after 0 record\(s\)'
        Should -Invoke Write-Log -Exactly -Times 1 -ParameterFilter { $Severity -eq 'Warning' -and $Message -match 'retrying this page once' }
        Should -Invoke Write-Log -Exactly -Times 1 -ParameterFilter { $Severity -eq 'Error' -and $Message -match 'ran out of memory' -and $Message -match 'fresh PowerShell process' }
    }

    It 'reports an out-of-memory stop at Error severity, with how to recover (<Label>)' -ForEach @(
        @{ Label = 'one identifiable subscription'; Obfuscated = $false; SubscriptionID = '12345678-1234-1234-1234-123456789012' }
        @{ Label = 'one obfuscated subscription'; Obfuscated = $true; SubscriptionID = '12345678-1234-1234-1234-123456789012' }
        @{ Label = 'a standalone report over every subscription'; Obfuscated = $false; SubscriptionID = '' }
        @{ Label = 'an obfuscated standalone report over every subscription'; Obfuscated = $true; SubscriptionID = '' }
    ) {
        $script:OuterOomClause | Should -Not -BeNullOrEmpty -Because 'the per-subscription catch must single out an out-of-memory stop'

        & $script:OuterOomBlock -sub ([pscustomobject]@{ Name = 'test-sub'; Id = '12345678-1234-1234-1234-123456789012' }) -Obfuscate ([switch]$Obfuscated) -SubscriptionID $SubscriptionID -DefaultPath 'report-folder/'

        Should -Invoke Write-Log -Exactly -Times 1 -ParameterFilter { $Severity -eq 'Error' -and $Message -match 'ran out of memory' -and $Message -match 'fresh PowerShell process' }
        $MergeAdvice = if ($SubscriptionID) { 1 } else { 0 }
        Should -Invoke Write-Log -Exactly -Times $MergeAdvice -ParameterFilter { $Message -match '-SubscriptionID 12345678-1234-1234-1234-123456789012 -SkipMetrics' -and $Message -match 'docs/recovery-and-diagnostics\.md' } -Because 'only a one-subscription report can take back a merged re-run'
        $Seeded = if ($Obfuscated -and $SubscriptionID) { 1 } else { 0 }
        Should -Invoke Write-Log -Exactly -Times $Seeded -ParameterFilter { $Message -match ([regex]::Escape(' -Obfuscate -ObfuscationDictionary <the ObfuscationDictionary_*.json this run writes to report-folder/>')) } -Because 'an obfuscated one-subscription re-run is seeded with its own dictionary so its tokens still join; a whole-report re-run starts a fresh dictionary'
        $WholeReport = if ($SubscriptionID) { 0 } else { 1 }
        Should -Invoke Write-Log -Exactly -Times $WholeReport -ParameterFilter { $Severity -eq 'Error' -and $Message -match 're-run the whole report in a fresh PowerShell process' } -Because 'a bundle over every subscription cannot take back one subscription''s merged re-run'
    }
}

Describe 'The Marketplace pull gives an out-of-memory error one compacted retry, then stops' {

    BeforeAll {
        # Same approach as the page-loop Describe above, against the OTHER billing envelope:
        # lift the real fetch loop and the real per-subscription catch out of
        # GetMarketplaceConsumption by AST and replace only the leaf commands. Nothing here
        # re-implements the loop, so a test cannot pass against a model that has drifted from the
        # shipped code.
        #
        # The difference that matters: Get-AzConsumptionMarketplace is UNPAGED. There is no
        # continuation token to resume from, the retry re-requests the identical window, and the
        # once-only guard therefore belongs to the SUBSCRIPTION, not to a page.
        # Reuses the parse the file-level BeforeAll already did rather than re-parsing a ~4000-line
        # file a third time.
        $script:MpFn = $script:InvAstTop.Find({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq 'GetMarketplaceConsumption' }, $true)
        if (-not $script:MpFn) { throw 'GetMarketplaceConsumption was not found in ResourceInventory.ps1.' }

        $script:MpLoop = $script:MpFn.Find({ param($N) $N -is [System.Management.Automation.Language.WhileStatementAst] -and $N.Condition.Extent.Text -eq '$true' -and $N.Extent.Text -match 'Get-AzConsumptionMarketplace' }, $true)
        if (-not $script:MpLoop) { throw 'The Marketplace fetch loop (while ($true) around Get-AzConsumptionMarketplace) was not found.' }

        $MpSetup = @($script:MpLoop.Parent.Statements | Where-Object { $_.Extent.EndOffset -le $script:MpLoop.Extent.StartOffset })
        $script:MpRetryState = @($MpSetup | Where-Object { $_ -is [System.Management.Automation.Language.AssignmentStatementAst] })
        if ($script:MpRetryState.Count -eq 0) { throw 'No retry-state assignments were found ahead of the Marketplace fetch loop.' }

        $MpInputs = @(
            '$sub = [pscustomobject]@{ Name = ''test-sub''; Id = ''12345678-1234-1234-1234-123456789012'' }'
            '$MarketplaceStartDate = [datetime]''2026-08-01'''
            '$MarketplaceEndDate = [datetime]''2026-08-31'''
            '$MarketplaceData = $null'
            '$MarketplaceExport = $null'
        )
        $script:MpFetchLoop = [scriptblock]::Create(((@($MpInputs) + @($MpSetup | ForEach-Object { $_.Extent.Text }) + $script:MpLoop.Extent.Text) -join [Environment]::NewLine))

        $script:MpOomClause = $script:MpLoop.Find({ param($N) $N -is [System.Management.Automation.Language.IfStatementAst] -and $N.Clauses[0].Item1.Extent.Text -match '^Test-RdaOutOfMemory\b' }, $true)
        if (-not $script:MpOomClause) { throw 'The out-of-memory branch was not found in the Marketplace fetch loop.' }

        # The per-subscription catch. Anchored on the Marketplace wording, NOT on the consumption
        # catch's 'stopped at consumption page' - that phrase is how the page-loop Describe above
        # locates ITS clause, so the two anchors must stay distinct.
        $script:MpOuterCatch = $script:MpFn.Find({ param($N) $N -is [System.Management.Automation.Language.CatchClauseAst] -and $N.Extent.Text -match 'Marketplace data is INCOMPLETE' }, $true)
        if (-not $script:MpOuterCatch) { throw 'The per-subscription Marketplace catch was not found.' }
        $script:MpOuterBlock = [scriptblock]::Create((@(
                    'param($sub, $SubscriptionID, $Obfuscate, $DefaultPath)'
                    'try { throw "Exception of type ''System.OutOfMemoryException'' was thrown." }'
                    'catch'
                    '{'
                    ($script:MpOuterCatch.Body.Statements | ForEach-Object { $_.Extent.Text })
                    '}'
                ) -join [Environment]::NewLine))

        # Same reasons as the page-loop Describe: these live in another file this suite does not
        # load, and re-authentication must never open a real sign-in from an offline test.
        function Get-RdaRetryAfterSeconds { 0 }
        function Test-DataPlaneAuthReady { throw 'The re-authentication branch ran in an offline test.' }
        # The loop also asks whether an error is a permanent 4xx. Define the REAL helper, lifted from its
        # file, rather than a stub: the errors injected below carry no HTTP response, and the real check
        # is what must answer "not permanent" for them.
        $MpFnFile = Join-Path $script:Repo 'Functions/ResourceInventory.Functions.ps1'
        $MpFnAst = [System.Management.Automation.Language.Parser]::ParseFile($MpFnFile, [ref]$null, [ref]$null)
        $MpPermanentFn = $MpFnAst.Find({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq 'Get-RdaPermanentRequestError' }, $true)
        if (-not $MpPermanentFn) { throw 'Get-RdaPermanentRequestError was not found in Functions/ResourceInventory.Functions.ps1.' }
        . ([scriptblock]::Create($MpPermanentFn.Extent.Text))
    }

    BeforeEach {
        $script:MpFetches = 0
        $script:MpWindows = @()
        Mock Start-Sleep { }
        Mock Write-Log { }
    }

    It 'resets the out-of-memory guard once per SUBSCRIPTION, not once per run' {
        # Hoisted above the foreach, the whole run would share one retry and every subscription
        # after the first would abandon its Marketplace data without compacting at all.
        $Guard = @($script:MpRetryState | Where-Object { $_.Left.Extent.Text -eq '$MarketplaceOutOfMemoryRetried' })
        $Guard.Count | Should -Be 1 -Because 'exactly one reset, beside the other per-subscription retry state'
        $Guard[0].Right.Extent.Text | Should -Be '$false'

        $Scope = $Guard[0].Parent
        while ($null -ne $Scope -and -not ($Scope -is [System.Management.Automation.Language.LoopStatementAst])) { $Scope = $Scope.Parent }
        $Scope | Should -BeOfType ([System.Management.Automation.Language.ForEachStatementAst]) -Because 'the guard belongs to the per-subscription loop; this call is unpaged, so there is no page to reset it for'
    }

    It 'releases both result structures and forces a full compacting collection before it retries' {
        $script:MpOomClause | Should -Not -BeNullOrEmpty -Because 'the retry catch must single out an out-of-memory error'
        $Body = $script:MpOomClause.Clauses[0].Item2
        $Continue = $Body.Find({ param($N) $N -is [System.Management.Automation.Language.ContinueStatementAst] }, $true)
        $CompactOnce = $Body.Find({ param($N) $N -is [System.Management.Automation.Language.AssignmentStatementAst] -and $N.Left.Extent.Text -eq '[System.Runtime.GCSettings]::LargeObjectHeapCompactionMode' -and $N.Right.Extent.Text -match '::CompactOnce$' }, $true)
        $Collect = $Body.Find({ param($N) $N -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $N.Expression.Extent.Text -eq '[System.GC]' -and $N.Member.Extent.Text -eq 'Collect' }, $true)
        $Released = @($Body.FindAll({ param($N) $N -is [System.Management.Automation.Language.AssignmentStatementAst] -and $N.Right.Extent.Text -eq '$null' }, $true))

        $Continue | Should -Not -BeNullOrEmpty
        $CompactOnce | Should -Not -BeNullOrEmpty
        $Collect | Should -Not -BeNullOrEmpty
        (@($Collect.Arguments | ForEach-Object { $_.Extent.Text }) -join ', ') | Should -Be '[System.GC]::MaxGeneration, [System.GCCollectionMode]::Forced, $true, $true' -Because 'only a forced, blocking, compacting full collection applies the compaction mode'
        $Release = $Released | Where-Object { $_.Left.Extent.Text -eq '$MarketplaceData' } | Select-Object -First 1
        $Release | Should -Not -BeNullOrEmpty -Because '$MarketplaceData holds the fetched response, which is the allocation that failed'
        $Release.Extent.StartOffset | Should -BeLessThan $Collect.Extent.StartOffset -Because 'a structure still referenced cannot be collected'
        $CompactOnce.Extent.StartOffset | Should -BeLessThan $Collect.Extent.StartOffset -Because 'the compaction mode applies to the next full collection'
        $Collect.Extent.StartOffset | Should -BeLessThan $Continue.Extent.StartOffset

        $Wait = $Body.Find({ param($N) $N -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $N.Expression.Extent.Text -eq '[System.GC]' -and $N.Member.Extent.Text -eq 'WaitForPendingFinalizers' }, $true)
        $Wait | Should -Not -BeNullOrEmpty -Because 'Az response objects awaiting finalization are exactly what has to come back here'
    }

    It 'does NOT release the run-wide Marketplace token maps or caches' {
        # P0. These are keyed by real value and persist for the whole run. Dropping one would mint
        # a different token for a value already exported under its first token, so the CSV would
        # disagree with itself and with the rest of the bundle.
        $Body = $script:MpOomClause.Clauses[0].Item2
        $Released = @($Body.FindAll({ param($N) $N -is [System.Management.Automation.Language.AssignmentStatementAst] -and $N.Right.Extent.Text -eq '$null' }, $true) | ForEach-Object { $_.Left.Extent.Text })
        $Released.Count | Should -BeGreaterThan 0 -Because 'a positive control: the clause does release something, so the check below is reachable'
        foreach ($Forbidden in '$script:MarketplaceSubGuidTokenMap', '$script:MarketplaceRgTokenMap', '$script:MarketplaceSubCache', '$script:MarketplaceRgCache', '$script:MarketplaceNameCache', '$script:MarketplaceOrderCache')
        {
            $Released | Should -Not -Contain $Forbidden -Because 'dropping a token cache mid-run breaks obfuscation determinism'
        }
    }

    It 'retries the same window once after an out-of-memory error, without backing off' {
        function Get-AzConsumptionMarketplace
        {
            [CmdletBinding()]
            param($StartDate, $EndDate)
            $script:MpFetches++
            $script:MpWindows += , ('{0:yyyy-MM-dd}..{1:yyyy-MM-dd}' -f $StartDate, $EndDate)
            if ($script:MpFetches -eq 1) { throw "Exception of type 'System.OutOfMemoryException' was thrown." }
            [pscustomobject]@{ InstanceName = 'offer-row' }
        }

        # The shadow must actually be what the loop calls. Get-AzConsumptionMarketplace is a
        # cmdlet, so a function outranks it - unlike Get-UsageAggregates, which is an alias and
        # silently wins against its shadow. Assert it rather than assume it.
        (Get-Command Get-AzConsumptionMarketplace).CommandType | Should -Be 'Function'

        . $script:MpFetchLoop

        $script:MpFetches | Should -Be 2 -Because 'one retry after the compaction'
        ($script:MpWindows | Select-Object -Unique).Count | Should -Be 1 -Because 'the retry asks for the SAME window; this endpoint has no page to advance'
        @($MarketplaceData).Count | Should -Be 1 -Because 'the retried response is what the conversion loop then reads'
        Should -Invoke Start-Sleep -Exactly -Times 0 -Because 'backing off cannot free memory'
        Should -Invoke Write-Log -Exactly -Times 1 -ParameterFilter { $Severity -eq 'Warning' -and $Message -match 'ran out of memory' }
    }

    It 'stops after a second out-of-memory error instead of spending the retry budget' {
        # The shadow SUCCEEDS from the third call on, so a regression that spends $MpMaxRetries
        # would complete the pull and fail these assertions loudly rather than passing quietly.
        function Get-AzConsumptionMarketplace
        {
            [CmdletBinding()]
            param($StartDate, $EndDate)
            $script:MpFetches++
            if ($script:MpFetches -le 2) { throw "Exception of type 'System.OutOfMemoryException' was thrown." }
            [pscustomobject]@{ InstanceName = 'offer-row' }
        }

        (Get-Command Get-AzConsumptionMarketplace).CommandType | Should -Be 'Function'
        $Thrown = { . $script:MpFetchLoop } | Should -Throw -PassThru
        $script:MpFetches | Should -Be 2 -Because 'one compacted retry, then the stop'
        Test-RdaOutOfMemory -ErrorMessage $Thrown.Exception.Message | Should -BeTrue -Because 'the per-subscription catch recognises the stop with the same classifier'
        Should -Invoke Start-Sleep -Exactly -Times 0 -Because 'the out-of-memory path never enters the backoff'
        Should -Invoke Write-Log -Exactly -Times 1 -ParameterFilter { $Severity -eq 'Warning' -and $Message -match 'ran out of memory' } -Because 'the single retry is announced once; the second failure is reported by the catch, not here'
    }

    It 'orders the classifiers so a denial is abandoned and the retry never sleeps or spends the budget' {
        $Text = $script:MpFetchLoop.ToString()
        $Denial = $Text.IndexOf('Test-RdaConsumptionDenial -ErrorMessage $_.Exception.Message', [System.StringComparison]::Ordinal)
        $Oom = $Text.IndexOf('Test-RdaOutOfMemory -ErrorMessage $MpErrorText', [System.StringComparison]::Ordinal)
        $Auth = $Text.IndexOf('Test-RdaAuthExpiry -ErrorMessage $MpErrorText', [System.StringComparison]::Ordinal)
        $Budget = $Text.IndexOf('$MpAttempt++', [System.StringComparison]::Ordinal)

        $Denial | Should -BeGreaterThan -1
        $Oom | Should -BeGreaterThan $Denial -Because 'a denial is abandoned outright; only a non-denial gets the compacted retry'
        $Auth | Should -BeGreaterThan $Oom -Because 'an out-of-memory error is not an auth error, so it must not trigger a re-authentication'
        $Budget | Should -BeGreaterThan $Oom -Because 'the compacted retry must not consume an attempt from the transient budget'
    }

    It 'retries the fetch rather than skipping the subscription' {
        # The dangerous failure mode: if the branch were moved so 'continue' bound to the
        # per-subscription foreach instead of the fetch loop, that subscription's Marketplace data
        # would be dropped in silence. Placement IS the contract, so assert it structurally.
        $Continue = $script:MpOomClause.Clauses[0].Item2.Find({ param($N) $N -is [System.Management.Automation.Language.ContinueStatementAst] }, $true)
        $Continue | Should -Not -BeNullOrEmpty
        $Enclosing = $Continue.Parent
        while ($null -ne $Enclosing -and -not ($Enclosing -is [System.Management.Automation.Language.LoopStatementAst])) { $Enclosing = $Enclosing.Parent }
        $Enclosing | Should -BeOfType ([System.Management.Automation.Language.WhileStatementAst])
        $Enclosing.Extent.Text | Should -Match 'Get-AzConsumptionMarketplace' -Because 'continue has to land on the fetch loop'

        # The per-subscription foreach is the NEXT loop outwards, so that is the binding a moved
        # branch would actually get. Naming it here is what makes this assertion able to fail.
        $Outer = $Enclosing.Parent
        while ($null -ne $Outer -and -not ($Outer -is [System.Management.Automation.Language.LoopStatementAst])) { $Outer = $Outer.Parent }
        $Outer | Should -BeOfType ([System.Management.Automation.Language.ForEachStatementAst]) -Because 'the loop continue must NOT bind to is the per-subscription one, and it is one level out'
    }

    It 'KEEPS the 30-attempt budget for transient Marketplace failures' {
        $script:MarketplaceFnText | Should -Match '\$MpMaxRetries = 30' -Because 'the Cost Management limit is shared tenant-wide, so a short budget truncates billing data during a sustained throttle'
    }

    It 'clears the converted rows for every subscription, including the paths that throw' {
        # The release after the export is skipped by every throwing path, so the reset has to sit
        # ahead of the try - otherwise the previous subscription's converted rows stay alive
        # through this subscription's fetch, which is where memory is tightest.
        $Try = $script:MpOuterCatch.Parent
        $Reset = @($Try.Parent.Statements | Where-Object {
                $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $_.Left.Extent.Text -eq '$MarketplaceExport' -and
                $_.Right.Extent.Text -eq '$null' -and
                $_.Extent.EndOffset -le $Try.Extent.StartOffset
            })
        $Reset.Count | Should -Be 1 -Because 'one reset per subscription, before the try that can throw'
    }

    It 'still retries an ordinary transient Marketplace error with backoff' {
        # The positive control for the two 'Start-Sleep -Exactly -Times 0' assertions above: without
        # a test that DOES sleep, a mis-wired Start-Sleep mock would let both pass vacuously while
        # the real cmdlet slept. It also guards the opposite regression - a transient failure must
        # still get the budget and the backoff rather than being abandoned like an out-of-memory one.
        function Get-AzConsumptionMarketplace
        {
            [CmdletBinding()]
            param($StartDate, $EndDate)
            $script:MpFetches++
            if ($script:MpFetches -eq 1) { throw 'The operation timed out.' }
            [pscustomobject]@{ InstanceName = 'offer-row' }
        }

        (Get-Command Get-AzConsumptionMarketplace).CommandType | Should -Be 'Function'
        . $script:MpFetchLoop

        $script:MpFetches | Should -Be 2 -Because 'a transient failure is retried'
        Should -Invoke Start-Sleep -Exactly -Times 1 -Because 'a transient failure DOES back off, which is what proves the mock is reachable'
        Should -Invoke Write-Log -Exactly -Times 0 -ParameterFilter { $Message -match 'ran out of memory' } -Because 'a timeout is not an out-of-memory error'
    }

    It 'keeps the Marketplace denial fast-fail and its operator wording' {
        # Asserted per envelope now: the consumption pair lives in its own Describe above, and before
        # the narrowing a single whole-file match was satisfied by either of them.
        $script:MarketplaceFnText | Should -Match 'Marketplace query DENIED for' -Because 'the log must distinguish a denial from a retryable failure'
        $script:MarketplaceFnText | Should -Match 'Cost Management Reader' -Because 'a fail-loud message must name the fix'
        $DenialClause = [regex]::Match($script:MarketplaceFnText, '(?s)if \(Test-RdaConsumptionDenial.*?\r?\n\s*\}').Value
        $DenialClause | Should -Not -BeNullOrEmpty
        $DenialClause | Should -Match 'throw' -Because 'the denial path must propagate immediately'
        $DenialClause | Should -Not -Match 'Start-Sleep' -Because 'there is nothing to wait for'
    }

    It 'releases the fetched response and the converted rows on every exit from the pull' {
        # The out-of-memory clause is covered above. These are the other three releases, and nothing
        # else in the suite would notice if one were deleted: after the conversion loop, after the
        # count is taken, and in the per-subscription catch - the last being the point of greatest
        # memory pressure.
        $Fn = $script:MpFn
        # Keyed on the loop VARIABLE, not on the call text: the per-subscription foreach's extent
        # also contains ConvertTo-RdaMarketplaceRow, and Find returns the outermost match, so
        # matching on the text would silently resolve to the wrong loop.
        $Conversion = $Fn.Find({ param($N) $N -is [System.Management.Automation.Language.ForEachStatementAst] -and $N.Variable.Extent.Text -eq '$Row' }, $true)
        $Conversion | Should -Not -BeNullOrEmpty -Because 'the per-row conversion loop is the last reader of the fetched response'
        $Conversion.Extent.Text | Should -Match 'ConvertTo-RdaMarketplaceRow' -Because 'this must be the conversion loop, not some other per-row loop'
        $Count = $Fn.Find({ param($N) $N -is [System.Management.Automation.Language.AssignmentStatementAst] -and $N.Left.Extent.Text -eq '$MarketplaceRecordsThisSub' -and $N.Right.Extent.Text -match '\$MarketplaceExport\.Count' }, $true)
        $Count | Should -Not -BeNullOrEmpty -Because 'the count has to be taken before the rows are dropped'

        # Bounded ABOVE by the start of the per-subscription catch. Without that bound the catch's
        # own two releases sit after both anchors and satisfy these checks on their own, so deleting
        # either success-path release would leave this test green - which is what a mutation run of
        # exactly that deletion showed before this bound was added.
        $TryEnd = $script:MpOuterCatch.Extent.StartOffset
        $Releases = @($Fn.FindAll({ param($N) $N -is [System.Management.Automation.Language.AssignmentStatementAst] -and $N.Right.Extent.Text -eq '$null' }, $true))
        $AfterConversion = $Releases | Where-Object { $_.Left.Extent.Text -eq '$MarketplaceData' -and $_.Extent.StartOffset -gt $Conversion.Extent.EndOffset -and $_.Extent.StartOffset -lt $TryEnd } | Select-Object -First 1
        $AfterConversion | Should -Not -BeNullOrEmpty -Because 'the fetched response must not be retained past the conversion loop'
        $AfterCount = $Releases | Where-Object { $_.Left.Extent.Text -eq '$MarketplaceExport' -and $_.Extent.StartOffset -gt $Count.Extent.EndOffset -and $_.Extent.StartOffset -lt $TryEnd } | Select-Object -First 1
        $AfterCount | Should -Not -BeNullOrEmpty -Because 'the converted rows are on disk and counted; the health record carries the count, not the rows'

        $CatchText = $script:MpOuterCatch.Extent.Text
        $CatchText | Should -Match '\$MarketplaceData = \$null' -Because 'the failing path is where memory is tightest'
        $CatchText | Should -Match '\$MarketplaceExport = \$null' -Because 'both structures stay referenced through the health append otherwise'
    }

    It 'reports an out-of-memory stop at Error severity, with how to recover (<Label>)' -ForEach @(
        @{ Label = 'single subscription'; SubId = '12345678-1234-1234-1234-123456789012'; Obf = $false; Expect = '-SubscriptionID 12345678-1234-1234-1234-123456789012 -SkipMetrics' }
        @{ Label = 'single subscription, obfuscated'; SubId = '12345678-1234-1234-1234-123456789012'; Obf = $true; Expect = '-Obfuscate -ObfuscationDictionary' }
        @{ Label = 'whole report'; SubId = ''; Obf = $false; Expect = 'every subscription in scope' }
        @{ Label = 'whole report, obfuscated'; SubId = ''; Obf = $true; Expect = 'every subscription in scope' }
    ) {
        & $script:MpOuterBlock -sub ([pscustomobject]@{ Name = 'test-sub'; Id = '12345678-1234-1234-1234-123456789012' }) -SubscriptionID $SubId -Obfuscate ([switch]$Obf) -DefaultPath 'report-folder/'

        Should -Invoke Write-Log -Exactly -Times 1 -ParameterFilter {
            $Severity -eq 'Error' -and $Message -match 'ran out of memory' -and $Message -match 'fresh PowerShell process' -and $Message -match [regex]::Escape($Expect)
        } -Because 'an incomplete cost section has to say so at Error severity and say what to do about it'

        # Positive control for the zero-count assertion below: the clause does log, so the mock is
        # reachable and a -Times 0 that passes means the text really is absent.
        Should -Invoke Write-Log -Exactly -Times 1 -ParameterFilter { $Severity -eq 'Warning' } -Because 'the generic failure line is still emitted first'
        Should -Invoke Write-Log -Exactly -Times 0 -ParameterFilter {
            $Message -match 'recovery-and-diagnostics' -or $Message -match 'Merge-RecoveryData' -or $Message -match 'merge (it|them|the Marketplace CSV) back'
        } -Because 'there is no -RecoverMarketplace mode, so pointing at the merge procedure would send the operator after something that does not exist'

        # The other half: saying nothing about merging would leave an operator who knows the
        # consumption merge exists assuming this one does too.
        Should -Invoke Write-Log -Exactly -Times 1 -ParameterFilter {
            $Severity -eq 'Error' -and $Message -match 'cannot be merged back in|no way to merge'
        } -Because 'the absence of a merge path is the thing the operator has to be told'
    }
}
