#Requires -Version 7.0
<#
    MetricsErrorClassification.Tests.ps1

    Locks two properties of Extension/Metrics.ps1's per-call failure handling that
    were each raised as a WARNING, fixed, and then left with NOTHING guarding them.

    1. CLASSIFICATION ORDER (review finding #489).
       The permanent check is anchored on the quoted status phrase:
           "invalid status code '(?<Status>NotFound|BadRequest)'"
       The throttle check is a LOOSE substring match:
           '429|throttl|TooManyRequests|rate limit'
       The exception message echoes the full ARM resource id, so a resource whose
       id merely CONTAINS '429' would be read as throttling if the loose test ran
       first - dragging a terminal 404/400 back onto the 4-attempt retry path with
       the doubled throttle backoff, which is exactly what the permanent branch
       exists to avoid. The file's own comment says "the permanent check MUST stay
       first"; this test is what makes that enforceable rather than aspirational.

    2. PERMANENT-FAILURE DIAGNOSABILITY (review finding #479).
       A 404 is nearly always the resource (deleted between discovery and the
       call), but a 400 may equally be OUR request being wrong - an unsupported
       TimeGrain from -MetricsIntervalMinutes, or a metric definition aimed at the
       wrong resource type. The status alone cannot separate those, so the listing
       must print what we ASKED FOR (metric, interval, aggregation) plus the first
       line of the Azure message. Without that, a tool-side 400 reads as a benign
       resource-side fact with no evidence to tell them apart.

    These are OFFLINE source assertions plus pure-logic checks of the two regexes.
    The classification is inline in a large loop rather than a function, so it
    cannot be invoked directly without refactoring working code; asserting on the
    source is the proportionate guard. Same approach as the source-audit tests in
    Tests/AzGraphQueryRetry.Tests.ps1.
#>

BeforeAll {
    $script:MetricsPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Extension/Metrics.ps1'
    $script:MetricsSrc = Get-Content -LiteralPath $script:MetricsPath -Raw
    $script:MetricsLines = Get-Content -LiteralPath $script:MetricsPath

    # Extract the permanent pattern FROM THE SOURCE rather than retyping it. A
    # hardcoded copy keeps passing after the real classifier is weakened, so every
    # logic case below would go green against broken code.
    # The classification lives in Get-RdaMetricFailureClass (pure, inside the -Parallel block); the loop consumes its result.
    $PermMatch = [regex]::Match($script:MetricsSrc, 'if \(\$(?:LastError|Message) -match "(?<Rx>invalid status code[^"]*)"\)')
    if (-not $PermMatch.Success)
    {
        throw 'Could not locate the permanent-failure classifier regex in Extension/Metrics.ps1; this test cannot verify what it cannot find.'
    }
    $script:PermanentPattern = $PermMatch.Groups['Rx'].Value
    $script:ThrottlePattern = '429|throttl|TooManyRequests|rate limit'
}

Describe 'Metrics per-call failure classification' {

    It 'still has both classification branches' {
        $script:MetricsSrc | Should -Match ([regex]::Escape("invalid status code '?(?<Status>NotFound|BadRequest")) -Because 'the anchored permanent check must exist (it may list further permanent statuses after these two)'
        $script:MetricsSrc | Should -Match ([regex]::Escape("'429|throttl|TooManyRequests|rate limit'")) -Because 'the throttle check must exist'
    }

    It 'evaluates the anchored permanent check BEFORE the loose throttle check' {
        # This is the whole finding. Compare source positions.
        $PermIdx = $script:MetricsSrc.IndexOf("invalid status code '?(?<Status>NotFound|BadRequest")
        $ThrottleIdx = $script:MetricsSrc.IndexOf("'429|throttl|TooManyRequests|rate limit'")

        $PermIdx | Should -BeGreaterThan -1
        $ThrottleIdx | Should -BeGreaterThan -1
        $PermIdx | Should -BeLessThan $ThrottleIdx -Because 'a loose throttle match running first would reclassify a terminal 404/400 as throttling and restore the 4-attempt burn with doubled backoff'
    }

    It 'a permanent classification wins outright: the classifier RETURNS before the loose throttle test runs' {
        # Ordering alone is not enough: two independent `if`s in the right order
        # would still let both run. Inside Get-RdaMetricFailureClass the permanent
        # branch must return, so the throttle test is never reached for a 404/400.
        $Fn = [regex]::Match($script:MetricsSrc, '(?s)function Get-RdaMetricFailureClass\s*\{.*?\n                \}').Value
        $Fn | Should -Not -BeNullOrEmpty
        $PermIdx = $Fn.IndexOf("invalid status code '?(?<Status>NotFound|BadRequest")
        $ThrottleIdx = $Fn.IndexOf("'429|throttl|TooManyRequests|rate limit'")
        $PermIdx | Should -BeGreaterThan -1; $ThrottleIdx | Should -BeGreaterThan $PermIdx
        $Fn.Substring($PermIdx, $ThrottleIdx - $PermIdx) | Should -Match 'return @\{ Permanent = \$true' -Because 'the permanent branch must return before the throttle test'
    }

    It 'takes the recorded outcome FROM the regex match, so it cannot drift from the branch' {
        $script:MetricsSrc | Should -Match 'Outcome\s*=\s*\$Matches\[''Status''\]' -Because 'a hardcoded outcome string could disagree with the status that actually matched'
        $script:MetricsSrc | Should -Match '\$PermanentOutcome\s*=\s*\$FailureClass\.Outcome' -Because 'the loop must take the outcome from the classifier, not restate it'
    }
}

Describe 'The anchored permanent pattern cannot be fooled by a resource id' {

    # Pure-logic checks of the SAME regex the file uses. These prove the anchoring
    # actually does the job the comment claims, independently of Azure.

    It 'matches a genuine NotFound and captures the status' {
        $Msg = "Operation returned an invalid status code 'NotFound'"
        $Msg -match $script:PermanentPattern | Should -BeTrue
        $Matches['Status'] | Should -Be 'NotFound'
    }

    It 'matches an UNQUOTED status too, so the classifier does not fail OPEN on a rendering change' {
        # The exposure this closes. The pattern used to REQUIRE the quotes, which made a
        # permanent classification depend on an SDK formatting detail nothing pins. If a
        # version or locale ever drops them, the status stops being recognised as
        # permanent and the call is retried for the full budget - silently, and in the
        # direction that burns wall-clock and Azure Monitor quota.
        foreach ($Status in @('NotFound', 'BadRequest'))
        {
            $Msg = 'Operation returned an invalid status code {0}' -f $Status
            $Msg -match $script:PermanentPattern | Should -BeTrue -Because 'the quotes are optional, the "invalid status code " prefix is the anchor'
            $Matches['Status'] | Should -Be $Status
        }
    }

    It 'still refuses every negative case now that the quotes are optional' {
        # Making the quotes optional must not widen what counts as permanent. Each of
        # these must stay unmatched, because none carries the status IMMEDIATELY after
        # the 'invalid status code ' prefix.
        $Negatives = @(
            "Operation returned an invalid status code 'TooManyRequests'"
            'Operation returned an invalid status code TooManyRequests'
            "Operation returned an invalid status code 'TooManyRequests'. Resource: /disks/disk404"
            'The operation has timed out for /resourceGroups/rg-404-prod/providers/x'
            'Timeout for /resourceGroups/rg-NotFound/providers/x'
        )
        foreach ($Msg in $Negatives)
        {
            $Msg -match $script:PermanentPattern | Should -BeFalse -Because ('"{0}" must not be classified permanent' -f $Msg)
        }
    }

    It 'matches a genuine BadRequest and captures the status' {
        $Msg = "Operation returned an invalid status code 'BadRequest'"
        $Msg -match $script:PermanentPattern | Should -BeTrue
        $Matches['Status'] | Should -Be 'BadRequest'
    }

    It 'does NOT match a TooManyRequests message, so real throttling still reaches the throttle branch' {
        $Msg = "Operation returned an invalid status code 'TooManyRequests'"
        $Msg -match $script:PermanentPattern | Should -BeFalse -Because 'genuine throttling must fall through to the retry path'
    }

    It 'is not fooled by a bare 404 substring inside a resource id' {
        # A resource group may legally contain digits and parentheses, so a looser
        # '404' or 'ResourceNotFound' substring test could match the id itself.
        $Msg = "Error on /subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-404-test/providers/Microsoft.Compute/virtualMachines/vm1"
        $Msg -match $script:PermanentPattern | Should -BeFalse -Because 'anchoring on the quoted status phrase is what prevents an id from being read as a status'
    }
}

Describe 'A resource id containing 429 is classified permanent, not throttled' {

    It 'is the exact case the ordering protects against' {
        # A REAL 404 whose echoed resource id happens to contain 429. With the
        # loose throttle test first, this is misread as throttling.
        $Msg = "Operation returned an invalid status code 'NotFound'. Resource: /subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-429/providers/Microsoft.Compute/disks/disk429"

        # Both patterns match this message - that is precisely why order decides.
        ($Msg -match $script:PermanentPattern) | Should -BeTrue -Because 'it is genuinely a NotFound'
        ($Msg -match $script:ThrottlePattern) | Should -BeTrue -Because 'the id contains 429, which is why the loose test must not run first'

        # Replay the file's own if/elseif in the file's own order.
        $Permanent = $false
        $Throttled = $false
        if ($Msg -match $script:PermanentPattern) { $Permanent = $true }
        elseif ($Msg -match $script:ThrottlePattern) { $Throttled = $true }

        $Permanent | Should -BeTrue -Because 'a terminal failure must be abandoned after one attempt'
        $Throttled | Should -BeFalse -Because 'classifying it as throttled would burn 4 attempts with doubled backoff for a call that can never succeed'
    }
}

Describe 'Permanent failures are reported diagnosably, not silently' {

    It 'lists NotFound and BadRequest resources rather than only counting them' {
        $script:MetricsSrc | Should -Match "Outcome -in @\('NotFound', 'BadRequest'\)" -Because 'a bare count gives an operator nothing to act on'
    }

    It 'carries the first line of the Azure error text through to the listing' {
        # Finding #479: without this, the raw Get-AzMetric message for these two
        # classes is logged NOWHERE, since the per-call Write-Error was removed.
        $script:MetricsSrc | Should -Match '\$FirstLine\s*=\s*if \(\[string\]::IsNullOrWhiteSpace\(\$rec\.Error\)\)' -Because 'the error text must be extracted with an empty-safe guard'
        $script:MetricsSrc | Should -Match "no error text captured" -Because 'an absent message must be stated as absent rather than rendering blank'
    }

    It 'prints what WE asked for, so a tool-side 400 is distinguishable from a resource-side one' {
        # The status alone cannot separate "resource does not support this" from
        # "we sent the wrong TimeGrain/aggregation". Interval and aggregation are
        # the evidence that separates them.
        $Block = [regex]::Match($script:MetricsSrc, "(?s)Metrics not collected for these resources.*?\r?\n\s*\}\r?\n\s*\}").Value
        $Block | Should -Not -BeNullOrEmpty -Because 'the permanent-failure listing block must be findable'
        $Block | Should -Match 'interval=' -Because 'an unsupported TimeGrain is a tool-side cause and only visible if the interval is printed'
        $Block | Should -Match 'aggregation=' -Because 'an unsupported aggregation is a tool-side cause and only visible if it is printed'
        $Block | Should -Match '\$FirstLine' -Because 'the Azure message must appear in the listing, not just be computed'
    }

    It 'keeps permanent outcomes OUT of the stuck/failed listing' {
        # They are not a run-health problem and not a place the run got stuck;
        # mixing them in would inflate the apparent failure count.
        $script:MetricsSrc | Should -Match "Outcome -in @\('Timeout', 'Throttled', 'Error'\)" -Because 'the non-success listing must not include NotFound/BadRequest'
    }
}
