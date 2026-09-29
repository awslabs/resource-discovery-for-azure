#Requires -Version 7.0
<#
    MetricsErrorClassification.Tests.ps1

    Locks three properties of Extension/Metrics.ps1's diagnostic output: two of
    its per-call failure handling, plus culture-invariant seconds rendering.

    1. CLASSIFICATION ORDER.
       The permanent check is anchored on the status phrase, "invalid status code"
       followed by the status name, quotes optional; the regex is read from the
       file itself below.
       The throttle check is a LOOSE substring match:
           '429|throttl|TooManyRequests|rate limit'
       The exception message echoes the full ARM resource id, so a resource whose
       id merely CONTAINS '429' would be read as throttling if the loose test ran
       first - dragging a terminal 404/400 back onto the 4-attempt retry path with
       the doubled throttle backoff, which is exactly what the permanent branch
       exists to avoid. The file's own comment says "the permanent check MUST stay
       first"; this test is what makes that enforceable rather than aspirational.

    2. PERMANENT-FAILURE DIAGNOSABILITY.
       A 404 is nearly always the resource (deleted between discovery and the
       call), but a 400 may equally be OUR request being wrong - an unsupported
       TimeGrain from -MetricsIntervalMinutes, or a metric definition aimed at the
       wrong resource type. The status alone cannot separate those, so the listing
       must print what we ASKED FOR (metric, interval, aggregation) plus the first
       line of the Azure message. Without that, a tool-side 400 reads as a benign
       resource-side fact with no evidence to tell them apart.

    These are OFFLINE source assertions plus pure-logic checks of the two regexes.
    The classification now lives in the pure function Get-RdaMetricFailureClass
    (Extension/Metrics.ps1), which Tests/MetricsThrottleRetryAfter.Tests.ps1 invokes
    directly; this suite keeps the source-level ORDERING guards (anchored permanent
    check returns before the loose throttle test) that a behavioural test cannot
    express. Same approach as the source-audit tests in Tests/AzGraphQueryRetry.Tests.ps1.
#>

BeforeAll {
    $script:MetricsPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Extension/Metrics.ps1'
    $script:MetricsSrc = Get-Content -LiteralPath $script:MetricsPath -Raw

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
        # The ordering is the property under test, so compare source positions.
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
        $Msg = "Error on /subscriptions/12345678-1234-1234-1234-123456789012/resourceGroups/rg-404-test/providers/Microsoft.Compute/virtualMachines/vm1"
        $Msg -match $script:PermanentPattern | Should -BeFalse -Because 'anchoring on the status phrase is what prevents an id from being read as a status'
    }
}

Describe 'A resource id containing 429 is classified permanent, not throttled' {

    It 'is the exact case the ordering protects against' {
        # A REAL 404 whose echoed resource id happens to contain 429. With the
        # loose throttle test first, this is misread as throttling.
        $Msg = "Operation returned an invalid status code 'NotFound'. Resource: /subscriptions/12345678-1234-1234-1234-123456789012/resourceGroups/rg-429/providers/Microsoft.Compute/disks/disk429"

        # Both patterns match this message - that is precisely why order decides.
        ($Msg -match $script:PermanentPattern) | Should -BeTrue -Because 'it is genuinely a NotFound'
        ($Msg -match $script:ThrottlePattern) | Should -BeTrue -Because 'the id contains 429, which is why the loose test must not run first'

        # Replay the file's own sequential checks in the file's own order.
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
        # Without this, the raw Get-AzMetric message for these two classes is
        # logged NOWHERE, since the per-call Write-Error was removed.
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

Describe 'Diagnostic seconds figures are culture-invariant' {
    # A diagnostic that renders 8,6s on a comma-decimal host and 8.6s elsewhere is ambiguous to
    # whoever reads the log, and the repo already fixed this class for the disk-space and memory
    # figures. The culture is forced here rather than inherited, so the test still fails on a
    # dot-decimal CI host where the bug would otherwise be invisible.
    BeforeAll {
        $script:ClAst = [System.Management.Automation.Language.Parser]::ParseInput($script:MetricsSrc, [ref]$null, [ref]$null)

        function script:Get-DiagCall([string]$Needle)
        {
            $Hit = @($script:ClAst.FindAll({ param($N)
                        $N -is [System.Management.Automation.Language.CommandAst] -and
                        $N.GetCommandName() -in @('Write-MetricsDiag', 'Write-Verbose') -and
                        $N.Extent.Text -match $Needle }, $true))
            if ($Hit.Count -ne 1) { throw ('expected exactly one diagnostic call matching {0}, found {1}' -f $Needle, $Hit.Count) }
            # The parenthesised format expression the command is called with. Asserted rather than
            # assumed: called as 'Write-MetricsDiag -Line (...)' the second element would be the
            # parameter name, and [scriptblock]::Create would then fail with an opaque error.
            $Arg = $Hit[0].CommandElements[1]
            if (-not ($Arg -is [System.Management.Automation.Language.ParenExpressionAst]))
            {
                throw ('the diagnostic matching {0} is no longer called with a single parenthesised expression' -f $Needle)
            }
            return $Arg.Extent.Text
        }

        function script:Invoke-UnderCulture([string]$Expression, [hashtable]$Vars, [string]$Culture)
        {
            $Prev = [System.Threading.Thread]::CurrentThread.CurrentCulture
            try
            {
                [System.Threading.Thread]::CurrentThread.CurrentCulture = [cultureinfo]::GetCultureInfo($Culture)
                $Sb = [scriptblock]::Create(($Vars.Keys | ForEach-Object { '${0} = $Vars[''{0}'']' -f $_ }) -join "`n")
                . $Sb
                return [string](& ([scriptblock]::Create($Expression)))
            }
            finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $Prev }
        }
    }

    It 'renders the phase-summary Elapsed with a dot on a comma-decimal culture (<Culture>)' -ForEach @(
        @{ Culture = 'de-DE' }, @{ Culture = 'nl-NL' }, @{ Culture = 'en-US' }
    ) {
        $Expr = script:Get-DiagCall 'Total calls: \{0\}'
        $Vars = @{
            DiagRecords = @(1, 2, 3); OkCount = 3; TimeoutCount = 0; ThrottledCount = 0; ErrorCount = 0
            NotFoundCount = 0; BadRequestCount = 0; UnauthorizedCount = 0; ForbiddenCount = 0
            PhaseStopwatch = [pscustomobject]@{ Elapsed = [timespan]::FromSeconds(8.6) }
        }
        $Line = script:Invoke-UnderCulture -Expression $Expr -Vars $Vars -Culture $Culture
        $Line | Should -Match 'Elapsed: 8\.6s'
        $Line | Should -Not -Match 'Elapsed: 8,6s'
    }

    It 'renders a per-call seconds figure with a dot on <Culture> (<Needle>)' -ForEach @(
        foreach ($CultureName in @('de-DE', 'nl-NL', 'en-US'))
        {
            # Both per-call listings print ElapsedSec: the non-success one and the slowest-calls one.
            @{ Culture = $CultureName; Needle = 'attempts=\{6\}' }
            @{ Culture = $CultureName; Needle = '\{0\}s idx=\{1\}' }
        }
    ) {
        $Expr = script:Get-DiagCall $Needle
        $Vars = @{
            rec = [pscustomobject]@{ Outcome = 'Timeout'; MetricIndex = 1; Service = 'vm'; Name = 'n'
                Metric = 'm'; Interval = 'PT1H'; Attempts = 2; ElapsedSec = 12.34; Error = 'e'
            }
            StuckBodyNote = ''
        }
        $Line = script:Invoke-UnderCulture -Expression $Expr -Vars $Vars -Culture $Culture
        $Line | Should -Match '12\.34s'
        $Line | Should -Not -Match '12,34s'
    }

    It 'never interpolates a raw seconds value straight into a diagnostic format string' {
        # The record keeps ElapsedSec as a double on purpose, because the listing sorts on it
        # numerically. That makes it the easy thing to pass to -f unformatted.
        $script:MetricsSrc | Should -Not -Match ',\s*\$rec\.ElapsedSec\s*[,)]' -Because 'it has to be formatted invariantly at the point it is printed'
        $script:MetricsSrc | Should -Not -Match '-f\s*\$rec\.ElapsedSec\s*[,)]'
        foreach ($Sw in @('PhaseStopwatch', 'BatchStopwatch'))
        {
            # Positive form: find every place the figure is produced and require each one to be
            # formatted invariantly. A 'Should -Not -Match' on the raw shape cannot express this,
            # because the correct wrapped form '...TotalSeconds, 1)).ToString(' also ends in ')'.
            # The pattern must be single-quoted and composed with -f: in a DOUBLE-quoted string '$$'
            # parses as the automatic last-token variable, which yields a pattern that cannot match
            # and an assertion that cannot fail.
            $Rx = '\[math\]::Round\(\${0}\.Elapsed\.TotalSeconds[^\r\n]{{0,24}}\)\)\.ToString\([^)]*\)' -f $Sw
            $Hits = @([regex]::Matches($script:MetricsSrc, $Rx))
            $Hits.Count | Should -BeGreaterThan 0 -Because ('{0} must still produce a seconds figure for this to be worth asserting' -f $Sw)
            foreach ($H in $Hits)
            {
                $H.Value | Should -Match 'InvariantCulture' -Because ('{0} seconds must be rendered with a dot on every host culture' -f $Sw)
            }
        }
    }
}
