# Consumption zero-record warning tests
#
# OFFLINE and self-contained: dot-sources the two pure builders and asserts the
# gate on the "consumption requested but ZERO records collected" warning. Makes
# NO Azure calls and needs no generated zip.
#
# Why this suite exists. A partner submitted a report whose Consumption CSV held
# only its header row. Nothing flagged it:
#   - The up-front access gate (Test-ConsumptionAccess) classifies the billing
#     probe's EXCEPTION text, and an empty-but-successful response raises no
#     exception, so the probe returned 'Ok'.
#   - The wrapper's console block printed NOTHING, because its condition was
#     ($Records -gt 0 -or $Failures.Count -gt 0) - excluding the exact 0/0 case
#     it existed to make loud.
#   - The shipped RunSummary.log and Diagnostics_*.log carried only a bare
#     "Consumption records collected : 0", which reads like an idle tenant.
# These tests pin the gate so that regression cannot return silently.
#
# The warning must fire ONLY when all of these hold, because each guard prevents
# a specific false positive:
#   requested (no -SkipConsumption) - a skipped phase legitimately has 0 records
#   record count == 0               - obviously
#   zero consumption failures       - a reported failure is already surfaced
#   at least one subscription ran   - a -Resume run where everything was already
#                                     completed must not claim the CSV is empty
#
# Run with: Invoke-Pester ./Tests/ConsumptionZeroRecordWarning.Tests.ps1 -Output Detailed

BeforeAll {
    $script:RepoRoot = Split-Path -Path $PSScriptRoot -Parent

    . (Join-Path $script:RepoRoot 'Functions/Common.Functions.ps1')
    . (Join-Path $script:RepoRoot 'Functions/RunAllSubscriptions.Functions.ps1')
    . (Join-Path $script:RepoRoot 'Functions/ResourceInventory.Functions.ps1')

    # Fail loudly here rather than with a confusing "command not found" mid-test
    # if a future change renames either builder.
    foreach ($Fn in @('Get-RunSummaryLogContent', 'Write-RdaShareableDiagnosticsLog'))
    {
        if (-not (Get-Command -Name $Fn -ErrorAction SilentlyContinue))
        {
            throw "Required function '$Fn' not found after dot-sourcing."
        }
    }

    # The marker both artifacts share. Asserting on this exact phrase keeps the
    # two surfaces from drifting apart silently.
    $script:WarnMarker = 'ZERO usage records were collected'

    # The skip cause, shared verbatim by BOTH surfaces. Declared once here so the
    # phrase has a single owner and the assertions below cannot drift from each
    # other. Deliberately does NOT include the label or its column padding: the
    # Health block is hand-aligned to its longest label, and an approved pending
    # addition ($Global:ConsumptionRowsFetchedCount adds a 'Consumption rows
    # fetched' row) will re-pad every line in it. Pinning the padding would break
    # these tests on a benign re-alignment with no real regression.
    $script:SkipCausePhrase = 'n/a (-SkipConsumption was passed)'

    # Line-anchored patterns. Anchoring to the label matters for the NEGATIVE
    # assertions: a bare 'n/a' negative is a whole-document match, and both
    # builders interpolate caller-supplied strings (valued parameters, phase-timing
    # key names), so any path or label containing 'n/a' would fail a consumption
    # test for an unrelated reason - and a future 'n/a' on the metric-query line
    # would be reported as a consumption failure.
    $script:SummaryNaPattern = 'Consumption records collected\s*:\s*' + [regex]::Escape($script:SkipCausePhrase)
    $script:DiagNaPattern = 'Consumption records collected:\s*' + [regex]::Escape($script:SkipCausePhrase)
    $script:SummaryAnyNaPattern = 'Consumption records collected\s*:\s*n/a'
    $script:DiagAnyNaPattern = 'Consumption records collected:\s*n/a'

    $TmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { '/tmp' }
    $script:DiagDir = Join-Path $TmpBase ('ConsumpWarn_' + [guid]::NewGuid().ToString().Substring(0, 8))
    New-Item -ItemType Directory -Path $script:DiagDir -Force | Out-Null
    $script:DiagPathPrefix = $script:DiagDir + [IO.Path]::DirectorySeparatorChar

    # Build a diagnostics log and return its text. $RunTag keeps each call's file
    # distinct so cases cannot read each other's output.
    function script:GetDiagText
    {
        param(
            [int]$RecordCount,
            [bool]$Requested,
            [switch]$Obfuscated,
            [string]$RunTag
        )
        $Params = @{
            DefaultPath            = $script:DiagPathPrefix
            ReportName             = 'R'
            RunDateTime            = $RunTag
            Version                = '0.0.0-test'
            PhaseTimings           = $null
            ConsumptionRecordCount = $RecordCount
            ConsumptionRequested   = $Requested
        }
        if ($Obfuscated) { $Params.Obfuscated = $true }
        $File = Write-RdaShareableDiagnosticsLog @Params
        if ([string]::IsNullOrEmpty($File) -or -not (Test-Path -LiteralPath $File))
        {
            throw 'Write-RdaShareableDiagnosticsLog did not return a written file.'
        }
        return (Get-Content -LiteralPath $File -Raw)
    }

    # $Requested / $MetricsRequested mirror the builder's own -ConsumptionRequested /
    # -MetricsRequested booleans and default to $true, matching its safe default.
    # $InvocationParameters stays UNTYPED on purpose: it feeds the Parameters echo
    # block, which enumerates .Keys, and the dictionary-shape test below relies on the
    # fixtures reaching the builder as their original types rather than being coerced.
    function script:GetSummaryText
    {
        param(
            [int]$RecordCount,
            [int]$Processed,
            $InvocationParameters = @{},
            $ConsumptionFailedSubs = @(),
            [bool]$Requested = $true,
            [bool]$MetricsRequested = $true,
            [int]$MetricsApiCallCount = 0,
            [switch]$Obfuscated
        )
        $Params = @{
            InvocationParameters   = $InvocationParameters
            Version                = '0.0.0-test'
            Processed              = $Processed
            ConsumptionRecordCount = $RecordCount
            ConsumptionFailedSubs  = $ConsumptionFailedSubs
            ConsumptionRequested   = $Requested
            MetricsRequested       = $MetricsRequested
            MetricsApiCallCount    = $MetricsApiCallCount
        }
        if ($Obfuscated) { $Params.Obfuscated = $true }
        return ((Get-RunSummaryLogContent @Params) -join [Environment]::NewLine)
    }
}

AfterAll {
    if ($script:DiagDir -and (Test-Path -LiteralPath $script:DiagDir))
    {
        Remove-Item -LiteralPath $script:DiagDir -Recurse -Force
    }
}

Describe 'RunSummary.log consumption zero-record warning' {

    It 'Warns when consumption was requested, 0 records, no failures, and a subscription ran' {
        # The exact partner signature.
        $Text = script:GetSummaryText -RecordCount 0 -Processed 1
        $Text | Should -Match $script:WarnMarker
    }

    It 'Reports the record count when consumption was requested' {
        # Retitled from 'Always reports...': the count is now conditional, so the
        # old title described a contract the code no longer offers.
        $Text = script:GetSummaryText -RecordCount 0 -Processed 1
        $Text | Should -Match 'Consumption records collected\s*:\s*0'
    }

    It 'Reports n/a instead of a bare 0 when consumption was not requested' {
        # The defect this pins: a bare "0" sitting under a Parameters block that
        # names -SkipConsumption reads as a billing-access failure, and it
        # contradicted the Diagnostics_*.log in the same bundle. Pinning the CAUSE
        # phrase on the labelled line (not merely 'n/a' anywhere) is what stops a
        # silent regression to '0' without coupling to column alignment.
        $Text = script:GetSummaryText -RecordCount 0 -Processed 1 -Requested $false
        $Text | Should -Match $script:SummaryNaPattern
        $Text | Should -Not -Match 'Consumption records collected\s*:\s*0'
    }

    It 'Still prints the count when the skip was passed but records nonetheless arrived' {
        # Records from a phase that was supposed to be skipped is a contradiction.
        # Printing 'n/a' over a non-zero figure would hide exactly that anomaly.
        $Text = script:GetSummaryText -RecordCount 7 -Processed 1 -Requested $false
        $Text | Should -Match 'Consumption records collected\s*:\s*7'
        $Text | Should -Not -Match $script:SummaryAnyNaPattern
    }

    It 'Reports n/a for the metric-query count when metrics were not requested' {
        # Same defect one line down: a bare 0 under a Parameters block naming
        # -SkipMetrics reads as a metrics failure rather than a deliberate skip.
        $Text = script:GetSummaryText -RecordCount 0 -Processed 1 -MetricsRequested $false
        $Text | Should -Match ('Metric-query API calls issued\s*:\s*' + [regex]::Escape('n/a (-SkipMetrics was passed)'))
        $Text | Should -Not -Match 'Metric-query API calls issued\s*:\s*0'
    }

    It 'Still prints the metric count when metrics were skipped but calls were nonetheless issued' {
        $Text = script:GetSummaryText -RecordCount 0 -Processed 1 -MetricsRequested $false -MetricsApiCallCount 12
        $Text | Should -Match 'Metric-query API calls issued\s*:\s*12\b'
        $Text | Should -Not -Match 'Metric-query API calls issued\s*:\s*n/a'
    }

    It 'Prints a real 0 for the metric count when metrics WERE requested and issued none' {
        # Without this the requested-and-zero direction is open: dropping the
        # '-not $MetricsRequested' term from the gate would still satisfy both tests
        # above, yet a run that ASKED for metrics and issued no calls would print
        # 'n/a (-SkipMetrics was passed)' - a false claim about the operator's own
        # flags, in a shipped RunSummary.log.
        $Text = script:GetSummaryText -RecordCount 0 -Processed 1 -MetricsRequested $true -MetricsApiCallCount 0
        $Text | Should -Match 'Metric-query API calls issued\s*:\s*0\b'
        $Text | Should -Not -Match 'Metric-query API calls issued\s*:\s*n/a'
    }

    It 'Groups both Health figures with InvariantCulture at four digits and above' {
        # Pins the N0 + InvariantCulture provider on BOTH numeric branches. Every other
        # fixture in this file is under 1000, where N0 emits no separator - so without
        # this case a revert to a bare -f would leave the whole suite green.
        $Text = script:GetSummaryText -RecordCount 1234567 -Processed 1 -MetricsApiCallCount 89012
        $Text | Should -Match 'Consumption records collected\s*:\s*1,234,567\b'
        $Text | Should -Match 'Metric-query API calls issued\s*:\s*89,012\b'
        # The en-NL separator must never appear: that is what CurrentCulture would give
        # on this host, and it misreads 1234567 by six orders of magnitude.
        $Text | Should -Not -Match '1\.234\.567'
    }

    It 'Treats both phases as REQUESTED when the caller omits the flags' {
        # The builder defaults both to $true, which is the safe reading: report the real
        # figures and leave the zero-record warning armed, rather than inventing a skip
        # the operator never asked for. Bypasses the helper (which supplies its own
        # defaults) so the BUILDER's defaults are what get exercised.
        $Lines = Get-RunSummaryLogContent -Version '0.0.0-test' -Processed 1 -ConsumptionRecordCount 0 -MetricsApiCallCount 0
        $Text = $Lines -join [Environment]::NewLine

        $Text | Should -Match 'Consumption records collected\s*:\s*0\b'
        $Text | Should -Match 'Metric-query API calls issued\s*:\s*0\b'
        $Text | Should -Not -Match $script:SummaryAnyNaPattern
        $Text | Should -Not -Match 'Metric-query API calls issued\s*:\s*n/a'
    }

    It 'The wrapper derives both requested flags from the skip switches (source guard)' {
        # The '(-not $SkipConsumption.IsPresent)' conversion lives in the script BODY of
        # Run-AllSubscriptions.ps1, not in a function, so no behavioural test can reach
        # it. A source guard is the idiomatic answer in this repo (see the equivalent in
        # Tests/WeightedInventoryPlan.Tests.ps1). Of the two possible regressions only
        # one is dangerous: omitting the argument fails SAFE via the $true default,
        # whereas inverting the polarity would put a false skip claim in a shipped log.
        # That inversion is exactly what this catches.
        $WrapperSrc = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'Run-AllSubscriptions.ps1') -Raw
        $WrapperSrc | Should -Match '-ConsumptionRequested \(-not \$SkipConsumption\.IsPresent\)'
        $WrapperSrc | Should -Match '-MetricsRequested \(-not \$SkipMetrics\.IsPresent\)'

        # The same conversion feeds Write-RdaShareableDiagnosticsLog from the inner
        # script, and has run unpinned there all along. Cover both sites so the two
        # surfaces cannot drift apart at the call site either.
        $InnerSrc = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'ResourceInventory.ps1') -Raw
        @([regex]::Matches($InnerSrc, '-ConsumptionRequested \(-not \$SkipConsumption\.IsPresent\)')).Count |
            Should -BeGreaterOrEqual 2 -Because 'both packaging branches pass the flag the same way'
    }

    It 'Renders the Parameters block for every dictionary shape a caller can pass' {
        # RUNTIME REGRESSION GUARD, kept after a real one.
        #
        # History: the skip flag used to be dug back out of $InvocationParameters, and
        # no single membership method binds across the shapes this
        # [System.Collections.IDictionary] parameter accepts - $PSBoundParameters
        # (PSBoundParametersDictionary : Dictionary[string,object]) has no one-argument
        # Contains(), [ordered]@{} has no ContainsKey(), and Hashtable has both. A
        # Hashtable-only fixture set therefore stayed green while the shipped
        # RunSummary.log silently failed to generate at all.
        #
        # The digging is now gone - the builder receives -ConsumptionRequested directly -
        # so this no longer guards the consumption line. It is retained and re-aimed
        # because the Parameters echo block STILL enumerates $InvocationParameters.Keys,
        # so the shape sensitivity still exists on that path.
        #
        # The Parameters assertion is LINE-ANCHORED, and that is load-bearing. An
        # unanchored 'Should -Match ''-SkipConsumption''' is satisfied by the Health
        # line this very test forces into existence ('n/a (-SkipConsumption was
        # passed)'), so it would pass even if the Parameters loop emitted nothing for
        # the non-Hashtable shapes - vacuous in exactly the way this test exists to
        # prevent. The echo emits the flag alone on its own line ('  -{0}'), so
        # anchoring to a line containing only the flag can only be satisfied there.
        # '\s*$' rather than a bare '$' because the helper joins with
        # [Environment]::NewLine, and a trailing \r would defeat '$' on Windows.
        #
        # Deliberately NOT script:-scoped - in Pester v5 'script:' inside an It resolves
        # to the FILE scope, so the definition would outlive the test and become
        # order-dependent shared state. A plain function dies with the test.
        function MakeBoundParams { param([switch]$SkipConsumption) return $PSBoundParameters }

        $Shapes = @(
            @{ TypeName = 'Hashtable'; Value = @{ SkipConsumption = [switch]$true } }
            @{ TypeName = 'PSBoundParametersDictionary'; Value = (MakeBoundParams -SkipConsumption) }
            @{ TypeName = 'OrderedDictionary'; Value = ([ordered]@{ SkipConsumption = [switch]$true }) }
        )

        foreach ($Shape in $Shapes)
        {
            # Guard the guard. These shapes only reach the builder untransformed
            # because script:GetSummaryText's -InvocationParameters is UNTYPED. If
            # anyone ever types it [hashtable], all three coerce to Hashtable and
            # this whole test goes vacuous while staying green - which is exactly the
            # failure mode it exists to prevent.
            $Shape.Value.GetType().Name | Should -Be $Shape.TypeName -Because 'the fixture must reach the builder as its original dictionary type'

            $Text = script:GetSummaryText -RecordCount 0 -Processed 1 -Requested $false -InvocationParameters $Shape.Value
            $Text | Should -Match '(?m)^\s*-SkipConsumption\s*$' -Because ('the {0} shape must render on its own line in the Parameters block' -f $Shape.TypeName)
            $Text | Should -Match $script:SummaryNaPattern -Because ('the {0} shape must not disturb the Health block' -f $Shape.TypeName)
        }
    }

    # COVERAGE NOTE. Three tests here previously fed the skip in as a [switch] / [bool]
    # inside -InvocationParameters ('as a switch', 'as a bool', 'present but explicitly
    # false') to exercise the builder's unwrap of the dug-out value. That unwrap no
    # longer exists: the builder now receives a plain [bool] -ConsumptionRequested, and
    # the switch-to-bool conversion moved to the call site in Run-AllSubscriptions.ps1
    # as '(-not $SkipConsumption.IsPresent)'.
    #
    # That conversion is not reachable by a behavioural test - it sits in a script body,
    # not a function - so it is pinned by the source guard below plus the end-to-end
    # wrapper run. Worth noting the refactor introduced no NEW untested pattern: the
    # identical expression already fed Write-RdaShareableDiagnosticsLog from two sites
    # in ResourceInventory.ps1 and had been running unpinned there all along; the guard
    # now covers those too. What remains testable at this level is the contract the
    # builder actually has - requested vs not - which the two tests below pin from both
    # directions.
    It 'Stays silent when consumption was not requested' {
        $Text = script:GetSummaryText -RecordCount 0 -Processed 1 -Requested $false
        $Text | Should -Not -Match $script:WarnMarker
    }

    It 'Warns when consumption WAS requested (the -SkipConsumption:$false case)' {
        # Passing -SkipConsumption:$false at the wrapper means consumption was
        # requested, so the call site hands this builder $true and the warning arms.
        $Text = script:GetSummaryText -RecordCount 0 -Processed 1 -Requested $true
        $Text | Should -Match $script:WarnMarker
    }

    It 'Stays silent when no subscription actually ran (resume with nothing to do)' {
        # Guards the false positive where a prior pass already produced populated
        # CSVs and this invocation processed nothing.
        $Text = script:GetSummaryText -RecordCount 0 -Processed 0
        $Text | Should -Not -Match $script:WarnMarker
    }

    It 'Stays silent when records were collected' {
        $Text = script:GetSummaryText -RecordCount 42 -Processed 1
        $Text | Should -Not -Match $script:WarnMarker
    }

    It 'Stays silent when a consumption failure was already reported' {
        # A reported failure is surfaced by its own block; warning too would
        # double-report and misattribute the cause.
        $Failed = @([pscustomobject]@{ Name = 'x'; Id = 'y'; Message = 'boom' })
        $Text = script:GetSummaryText -RecordCount 0 -Processed 1 -ConsumptionFailedSubs $Failed
        $Text | Should -Not -Match $script:WarnMarker
    }

    It 'Emits the warning in an obfuscated run too' {
        # Obfuscated bundles are the ones normally shared, so this is the case
        # that actually reaches a report consumer.
        $Text = script:GetSummaryText -RecordCount 0 -Processed 1 -Obfuscated
        $Text | Should -Match $script:WarnMarker
    }

    It 'Names the CSP cost-visibility cause and does not claim RBAC will fix it' {
        # The bare `Should -Match 'not'` this replaces was vacuous: 'not', 'nothing',
        # 'cannot' or 'Otherwise' anywhere in a ~40-line document satisfied it, so it
        # could only fail if the whole warning block vanished - which the two
        # assertions above already catch. Pin the actual claim instead.
        $Text = script:GetSummaryText -RecordCount 0 -Processed 1
        $Text | Should -Match 'CSP'
        $Text | Should -Match 'Partner Center'
        $Text | Should -Match 'Cost Management\s+Reader does not'
    }

    It 'Carries no identifier of its own (safe for an obfuscated bundle)' {
        # The warning text must be static guidance. A GUID here would leak.
        $Text = script:GetSummaryText -RecordCount 0 -Processed 1 -Obfuscated
        $Text | Should -Not -Match '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
    }
}

Describe 'Diagnostics_*.log consumption zero-record warning' {

    It 'Warns when consumption was requested, 0 records, and no failures' {
        $Text = script:GetDiagText -RecordCount 0 -Requested $true -RunTag 'd1'
        $Text | Should -Match $script:WarnMarker
    }

    It 'Reports the record count when consumption was requested' {
        $Text = script:GetDiagText -RecordCount 12 -Requested $true -RunTag 'd2'
        $Text | Should -Match 'Consumption records collected:\s*12'
    }

    It 'Stays silent and reports n/a when -SkipConsumption was passed' {
        # Pins the CAUSE on the labelled line, not a bare 'n/a' anywhere in the
        # document: the loose form would still pass if the cause were dropped, and
        # this Describe should state its own contract rather than leaning on the
        # cross-surface test below to do it.
        $Text = script:GetDiagText -RecordCount 0 -Requested $false -RunTag 'd3'
        $Text | Should -Match $script:DiagNaPattern
        $Text | Should -Not -Match $script:WarnMarker
    }

    It 'Still prints the count when the skip was passed but records nonetheless arrived' {
        # Mirrors the RunSummary gate exactly: 'n/a' must not mask a non-zero
        # figure, because records from a skipped phase are the anomaly worth seeing.
        $Text = script:GetDiagText -RecordCount 9 -Requested $false -RunTag 'd8'
        $Text | Should -Match 'Consumption records collected:\s*9'
        $Text | Should -Not -Match $script:DiagAnyNaPattern
    }

    It 'Never invents the skip cause when -ConsumptionRequested was not supplied' {
        # The builder declares [bool]$ConsumptionRequested = $true - a deliberately
        # SAFE default, so a caller that forgets the parameter gets the numeric form
        # rather than a false '-SkipConsumption was passed' claim. Nothing pinned
        # that default, and inventing a cause the log does not know is the same
        # defect class as the bare-0 this change fixed.
        $Params = @{
            DefaultPath            = $script:DiagPathPrefix
            ReportName             = 'R'
            RunDateTime            = 'd9'
            Version                = '0.0.0-test'
            PhaseTimings           = $null
            ConsumptionRecordCount = 0
        }
        $File = Write-RdaShareableDiagnosticsLog @Params
        $Text = Get-Content -LiteralPath $File -Raw

        $Text | Should -Not -Match $script:DiagAnyNaPattern -Because 'an omitted -ConsumptionRequested must not be reported as a deliberate skip'
        $Text | Should -Match 'Consumption records collected:\s*0'
    }

    It 'Stays silent when records were collected' {
        $Text = script:GetDiagText -RecordCount 46 -Requested $true -RunTag 'd4'
        $Text | Should -Not -Match $script:WarnMarker
    }

    It 'Emits the warning in the OBFUSCATED diagnostics log' {
        # This is the surface that made the partner case undiagnosable.
        $Text = script:GetDiagText -RecordCount 0 -Requested $true -Obfuscated -RunTag 'd5'
        $Text | Should -Match $script:WarnMarker
    }

    It 'Declares the run mode in the first five lines so consumers can detect it' {
        # Tests/OutputCompleteness.Tests.ps1 derives bundle mode from this header
        # within a 5-line window; if that contract breaks, its DebugLog rule
        # silently falls back to the stricter branch.
        $Obf = (script:GetDiagText -RecordCount 0 -Requested $true -Obfuscated -RunTag 'd6') -split "`r?`n"
        $Def = (script:GetDiagText -RecordCount 0 -Requested $true -RunTag 'd7') -split "`r?`n"
        (($Def | Select-Object -First 5) -join ' ') | Should -Match 'non-obfuscated'
        (($Obf | Select-Object -First 5) -join ' ') | Should -Not -Match 'non-obfuscated'
    }
}

Describe 'The two surfaces agree' {

    It 'Uses the same marker phrase in RunSummary.log and Diagnostics_*.log' {
        # Prevents one surface being reworded and the other left behind.
        $Summary = script:GetSummaryText -RecordCount 0 -Processed 1
        $Diag = script:GetDiagText -RecordCount 0 -Requested $true -RunTag 'a1'
        $Summary | Should -Match $script:WarnMarker
        $Diag | Should -Match $script:WarnMarker
    }

    It 'Uses the same n/a phrase on both surfaces when -SkipConsumption was passed' {
        # These two lines ship in the SAME bundle. Before this was pinned, the
        # diagnostics log said "n/a (-SkipConsumption was passed)" while the run
        # summary said a bare "0", so a reader got two different answers to
        # "is the billing data missing?". Pin the shared phrase, not each wording -
        # the two full lines differ by design (the Health block pads for column
        # alignment), so only the cause phrase is common to both.
        $Summary = script:GetSummaryText -RecordCount 0 -Processed 1 -Requested $false
        $Diag = script:GetDiagText -RecordCount 0 -Requested $false -RunTag 'a3'
        $Summary | Should -Match ([regex]::Escape($script:SkipCausePhrase))
        $Diag | Should -Match ([regex]::Escape($script:SkipCausePhrase))
    }

    It 'Both surfaces fall through to the count when the skip was passed but records arrived' {
        # The anomalous case must be reported identically on both surfaces, or the
        # bundle again says two different things about the same run.
        $Summary = script:GetSummaryText -RecordCount 5 -Processed 1 -Requested $false
        $Diag = script:GetDiagText -RecordCount 5 -Requested $false -RunTag 'a4'
        $Summary | Should -Match 'Consumption records collected\s*:\s*5'
        $Diag | Should -Match 'Consumption records collected:\s*5'
        $Summary | Should -Not -Match $script:SummaryAnyNaPattern
        $Diag | Should -Not -Match $script:DiagAnyNaPattern
    }

    It 'Does not describe the query window as UTC (the consumption phase uses host local time)' {
        # ResourceInventory.ps1's consumption phase uses (Get-Date).AddDays(...).Date
        # - LOCAL midnight. Only the access PROBE was moved to UTC midnight. Saying
        # "UTC" here would be a factual error about the window actually queried.
        $Summary = script:GetSummaryText -RecordCount 0 -Processed 1
        $Diag = script:GetDiagText -RecordCount 0 -Requested $true -RunTag 'a2'
        $Summary | Should -Not -Match 'midnight UTC'
        $Diag | Should -Not -Match 'midnight UTC'
    }
}
