# Offline tests pinning the "consumption requested but ZERO records collected" warning: a header-only
# Consumption CSV once shipped unflagged (the console gate excluded the exact 0/0 case). The warning must fire only when all five guards hold: requested, 0 records, 0 consumption failures, >=1 sub ran, and >=1 ran without recording a failure.

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

    # Single owner of the skip-cause phrase, shared verbatim by both surfaces so the assertions can't drift.
    # Excludes the label/column padding: the Health block re-pads to its longest label, so pinning padding would break on a benign re-alignment.
    $script:SkipCausePhrase = 'n/a (-SkipConsumption was passed)'

    # The metric-query equivalent, now that BOTH surfaces carry a 'Metric-query API
    # calls issued' line. Same single-owner reasoning as the phrase above: the
    # cross-surface test asserts this exact string against both artifacts, so a reword
    # on one side alone fails rather than silently drifting.
    $script:MetricsSkipCausePhrase = 'n/a (-SkipMetrics was passed)'

    # Anchor the patterns to their label: a bare 'n/a' negative matches the whole document, and both
    # builders interpolate caller-supplied strings, so an unrelated path/label containing 'n/a' would fail or misattribute these assertions.
    $script:SummaryNaPattern = 'Consumption records collected\s*:\s*' + [regex]::Escape($script:SkipCausePhrase)
    $script:DiagNaPattern = 'Consumption records collected:\s*' + [regex]::Escape($script:SkipCausePhrase)
    $script:SummaryAnyNaPattern = 'Consumption records collected\s*:\s*n/a'
    $script:DiagAnyNaPattern = 'Consumption records collected:\s*n/a'

    # The metric-query equivalents, hoisted here for the same reason as the consumption
    # four above: one owner per pattern, so the metric assertions cannot drift from each
    # other. Note the padding asymmetry is real and intentional - the RunSummary Health
    # block hand-pads to its longest label ('... issued : '), the diagnostics log is
    # flush ('... issued: ').
    $script:SummaryMetricNaPattern = 'Metric-query API calls issued\s*:\s*' + [regex]::Escape($script:MetricsSkipCausePhrase)
    $script:DiagMetricNaPattern = 'Metric-query API calls issued:\s*' + [regex]::Escape($script:MetricsSkipCausePhrase)
    $script:SummaryAnyMetricNaPattern = 'Metric-query API calls issued\s*:\s*n/a'
    $script:DiagAnyMetricNaPattern = 'Metric-query API calls issued:\s*n/a'

    $TmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { '/tmp' }
    $script:DiagDir = Join-Path $TmpBase ('ConsumpWarn_' + [guid]::NewGuid().ToString().Substring(0, 8))
    New-Item -ItemType Directory -Path $script:DiagDir -Force | Out-Null
    $script:DiagPathPrefix = $script:DiagDir + [IO.Path]::DirectorySeparatorChar

    # Build a diagnostics log and return its text. $RunTag keeps each call's file
    # distinct so cases cannot read each other's output.
    # $MetricsRequested / $MetricsApiCallCount mirror the builder's own booleans and
    # default to its safe defaults, so existing cases that care only about consumption
    # keep exercising the requested-metrics path unchanged.
    function script:GetDiagText
    {
        param(
            [int]$RecordCount,
            [bool]$Requested,
            [bool]$MetricsRequested = $true,
            [int]$MetricsApiCallCount = 0,
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
            MetricsRequested       = $MetricsRequested
            MetricsApiCallCount    = $MetricsApiCallCount
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
        # \b right-anchor, matching the sibling assertions. Deliberately NOT added to the
        # -Not -Match negative below: narrowing a negative pattern WEAKENS it, so that one
        # stays broad on purpose.
        $Text | Should -Match 'Consumption records collected\s*:\s*0\b'
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
        $Text | Should -Match $script:SummaryMetricNaPattern
        $Text | Should -Not -Match 'Metric-query API calls issued\s*:\s*0'
    }

    It 'Still prints the metric count when metrics were skipped but calls were nonetheless issued' {
        $Text = script:GetSummaryText -RecordCount 0 -Processed 1 -MetricsRequested $false -MetricsApiCallCount 12
        $Text | Should -Match '(?m)^\s*Metric-query API calls issued\s*:\s*12\s*$'
        $Text | Should -Not -Match $script:SummaryAnyMetricNaPattern
    }

    It 'Prints a real 0 for the metric count when metrics WERE requested and issued none' {
        # Without this the requested-and-zero direction is open: dropping the
        # '-not $MetricsRequested' term from the gate would still satisfy both tests
        # above, yet a run that ASKED for metrics and issued no calls would print
        # 'n/a (-SkipMetrics was passed)' - a false claim about the operator's own
        # flags, in a shipped RunSummary.log.
        $Text = script:GetSummaryText -RecordCount 0 -Processed 1 -MetricsRequested $true -MetricsApiCallCount 0
        $Text | Should -Match '(?m)^\s*Metric-query API calls issued\s*:\s*0\s*$'
        $Text | Should -Not -Match $script:SummaryAnyMetricNaPattern
    }

    It 'Groups both Health figures with InvariantCulture at four digits and above' {
        # Pins the N0 + InvariantCulture provider on BOTH numeric branches. Every other
        # fixture in this file is under 1000, where N0 emits no separator - so without
        # this case a revert to a bare -f would leave the whole suite green.
        $Text = script:GetSummaryText -RecordCount 1234567 -Processed 1 -MetricsApiCallCount 89012
        $Text | Should -Match 'Consumption records collected\s*:\s*1,234,567\b'
        $Text | Should -Match '(?m)^\s*Metric-query API calls issued\s*:\s*89,012\s*$'
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
        $Text | Should -Match '(?m)^\s*Metric-query API calls issued\s*:\s*0\s*$'
        $Text | Should -Not -Match $script:SummaryAnyNaPattern
        $Text | Should -Not -Match $script:SummaryAnyMetricNaPattern
    }

    # Source guards (one per file) because the '(-not $SkipConsumption.IsPresent)' conversion lives in a
    # script body no behavioural test can reach. They catch a polarity inversion (a false skip claim in a shipped log); omission fails safe via the $true default. Split per file so a failure names which call site drifted.
    It 'The wrapper derives both requested flags from the skip switches (source guard)' {
        # Pin the COLON bind form: Get-RunSummaryLogContent is a simple function, so if its params were
        # retyped to [switch] the space form would silently swallow the value into $args and bind the switch as present, forcing -ConsumptionRequested $true and reprinting a bare 0. Anchored to a non-comment line so a commented/quoted occurrence can't satisfy it.
        $WrapperSrc = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'Run-AllSubscriptions.ps1') -Raw
        $WrapperSrc | Should -Match '(?m)^[^#\r\n]*-ConsumptionRequested:?\s*\(-not \$SkipConsumption\.IsPresent\)'
        $WrapperSrc | Should -Match '(?m)^[^#\r\n]*-MetricsRequested:?\s*\(-not \$SkipMetrics\.IsPresent\)'
    }

    It 'The inner script derives the requested flag the same way (source guard)' {
        # Pin the same conversion feeding Write-RdaShareableDiagnosticsLog from ResourceInventory.ps1,
        # form-agnostically (polarity and presence, not the separator). Non-comment anchored so commented-out lines can't satisfy the >=2 count.
        $InnerSrc = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'ResourceInventory.ps1') -Raw
        @([regex]::Matches($InnerSrc, '(?m)^[^#\r\n]*-ConsumptionRequested:?\s*\(-not \$SkipConsumption\.IsPresent\)')).Count |
            Should -BeGreaterOrEqual 2 -Because 'both packaging branches pass the flag the same way'

        # Metrics half. It exists now because the diagnostics builder GAINED a
        # -MetricsRequested parameter when its 'Metric-query API calls issued' line was
        # added; before that there was genuinely no metrics flag here to pin.
        @([regex]::Matches($InnerSrc, '(?m)^[^#\r\n]*-MetricsRequested:?\s*\(-not \$SkipMetrics\.IsPresent\)')).Count |
            Should -BeGreaterOrEqual 2 -Because 'both packaging branches pass the metrics flag the same way'
    }

    It 'Renders the Parameters block for every dictionary shape a caller can pass' {
        # Runtime guard for $InvocationParameters shape sensitivity: no single membership method binds across
        # its accepted shapes (Dictionary lacks 1-arg Contains(), [ordered] lacks ContainsKey()), so a Hashtable-only fixture once stayed green while RunSummary.log silently failed to generate. The Parameters assertion is line-anchored, or the forced '-SkipConsumption' Health line satisfies it vacuously.
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

    # The builder now takes a plain [bool] -ConsumptionRequested; the switch->bool conversion moved to the
    # wrapper call site (unreachable by a behavioural test, pinned by the source guard + end-to-end run). The two Its below pin the builder's requested-vs-not contract.
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

    It 'Stays silent when every attempted subscription failed' {
        # The gate also requires ($Processed - $Failed) > 0: a zero count on a run where nothing got through
        # is explained by the failures, not the billing causes this warning names. (Close to but not identical to the console gate; a residual K>1 parallel-stream gap is recorded at the gate, not tested here.)
        $AllFailed = @(
            [pscustomobject]@{ Name = 's1'; Id = 'i1'; Message = 'boom' }
            [pscustomobject]@{ Name = 's2'; Id = 'i2'; Message = 'boom' }
        )
        $Lines = Get-RunSummaryLogContent -Version '0.0.0-test' -Processed 2 `
            -ConsumptionRecordCount 0 -ConsumptionRequested $true -FailedSubscriptions $AllFailed
        $Text = $Lines -join [Environment]::NewLine

        $Text | Should -Not -Match $script:WarnMarker
        # Arms the negative above: proving the count line rendered shows the absence is a real gate decision,
        # not a failed-to-generate document. Right-anchored with \b so a non-zero count whose first digit is 0 can't satisfy it.
        $Text | Should -Match 'Consumption records collected\s*:\s*0\b'
    }

    It 'Still warns when only SOME attempted subscriptions failed' {
        # Complement: one sub got through, so the warning must still fire. This is the ONLY test ruling out
        # ($Failed.Count -eq 0) as a substitute for the arithmetic gate (which would suppress the warning for any run with one failed sub out of fifty). Do not remove it though it can't fail for that term.
        $SomeFailed = @([pscustomobject]@{ Name = 's1'; Id = 'i1'; Message = 'boom' })
        $Lines = Get-RunSummaryLogContent -Version '0.0.0-test' -Processed 2 `
            -ConsumptionRecordCount 0 -ConsumptionRequested $true -FailedSubscriptions $SomeFailed
        $Text = $Lines -join [Environment]::NewLine

        $Text | Should -Match $script:WarnMarker
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

    It 'Reports n/a for the metric-query line when -SkipMetrics was passed' {
        # The gap this closes: a -SkipMetrics run left NO trace of the metrics phase in
        # the shareable log at all. The auth-skipped count read 0 (nothing failed, the
        # phase never ran) and the call count was absent, so the log read as healthy
        # while the metric data the operator asked for was simply missing - the same
        # class of silence the consumption line above was added for.
        $Text = script:GetDiagText -RecordCount 3 -Requested $true -MetricsRequested $false -RunTag 'd10'
        $Text | Should -Match $script:DiagMetricNaPattern
        # The consumption line must be unaffected by the metrics flag.
        $Text | Should -Match 'Consumption records collected:\s*3\b'
    }

    It 'Reports the metric-query count when metrics were requested' {
        $Text = script:GetDiagText -RecordCount 0 -Requested $true -MetricsRequested $true -MetricsApiCallCount 34 -RunTag 'd11'
        $Text | Should -Match '(?m)^\s*Metric-query API calls issued:\s*34\s*$'
        $Text | Should -Not -Match $script:DiagAnyMetricNaPattern
    }

    It 'Still prints the metric count when metrics were skipped but calls were nonetheless issued' {
        # Same anomaly rule as the consumption line: 'n/a' must never mask a non-zero
        # figure, because calls issued by a phase that was supposed to be skipped are
        # exactly what an operator needs to see.
        $Text = script:GetDiagText -RecordCount 0 -Requested $true -MetricsRequested $false -MetricsApiCallCount 12 -RunTag 'd12'
        $Text | Should -Match '(?m)^\s*Metric-query API calls issued:\s*12\s*$'
        $Text | Should -Not -Match $script:DiagAnyMetricNaPattern
    }

    It 'Never invents the metrics skip cause when -MetricsRequested was not supplied' {
        # Mirrors the consumption safe-default test below. The builder declares
        # [bool]$MetricsRequested = $true, so a caller that omits it must get the
        # numeric form rather than a false '-SkipMetrics was passed' claim about the
        # operator's own flags. Bypasses the helper so the BUILDER's default is what
        # gets exercised, not the helper's.
        $File = Write-RdaShareableDiagnosticsLog -DefaultPath $script:DiagPathPrefix `
            -ReportName 'R' -RunDateTime 'd13' -Version '0.0.0-test' -PhaseTimings $null `
            -ConsumptionRecordCount 0 -ConsumptionRequested $true
        $Text = Get-Content -LiteralPath $File -Raw

        $Text | Should -Match '(?m)^\s*Metric-query API calls issued:\s*0\s*$'
        $Text | Should -Not -Match $script:DiagAnyMetricNaPattern
    }

    It 'Groups large metric counts with N0 and InvariantCulture' {
        # Guards the same formatting contract the consumption count has. Without a
        # four-digit-plus fixture a revert to a bare -f would leave the suite green,
        # and this figure SHIPS next to the RunSummary one - the same number grouped in
        # one artifact and ungrouped in the other reads as a bug in whichever the
        # reader saw second.
        $Text = script:GetDiagText -RecordCount 0 -Requested $true -MetricsApiCallCount 89012 -RunTag 'd14'
        $Text | Should -Match '(?m)^\s*Metric-query API calls issued:\s*89,012\s*$'
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
        # These two lines ship in the same bundle and once disagreed (diagnostics said the skip phrase, the
        # summary said a bare "0"). Pin the shared cause phrase, not each full line - they differ by the Health block's column padding.
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

    It 'Uses the same n/a phrase on both surfaces when -SkipMetrics was passed' {
        # Previously UNTESTABLE, and the reason is the point: the diagnostics log had no
        # metric-query line at all, so a -SkipMetrics run produced a RunSummary saying
        # 'n/a (-SkipMetrics was passed)' beside a diagnostics log that said nothing
        # about metrics whatsoever. Now both carry the line, this pins the shared cause
        # phrase exactly as its consumption counterpart above does.
        $Summary = script:GetSummaryText -RecordCount 0 -Processed 1 -MetricsRequested $false
        $Diag = script:GetDiagText -RecordCount 0 -Requested $true -MetricsRequested $false -RunTag 'a5'
        $Summary | Should -Match $script:SummaryMetricNaPattern
        $Diag | Should -Match $script:DiagMetricNaPattern
    }

    It 'Reports the same metric count on both surfaces, identically formatted' {
        # The two figures ship together, so they must agree in VALUE and in FORMAT. A
        # four-digit-plus fixture is required for the format half: below 1000 N0 emits no
        # separator, so a revert to a bare -f on either side would pass unnoticed.
        $Summary = script:GetSummaryText -RecordCount 0 -Processed 1 -MetricsApiCallCount 89012
        $Diag = script:GetDiagText -RecordCount 0 -Requested $true -MetricsApiCallCount 89012 -RunTag 'a6'
        $Summary | Should -Match '(?m)^\s*Metric-query API calls issued\s*:\s*89,012\s*$'
        $Diag | Should -Match '(?m)^\s*Metric-query API calls issued:\s*89,012\s*$'
    }

    It 'Both surfaces fall through to the metric count when metrics were skipped but calls arrived' {
        # The metrics twin of the consumption anomaly case above: neither surface may
        # hide a non-zero call count behind 'n/a'.
        $Summary = script:GetSummaryText -RecordCount 0 -Processed 1 -MetricsRequested $false -MetricsApiCallCount 7
        $Diag = script:GetDiagText -RecordCount 0 -Requested $true -MetricsRequested $false -MetricsApiCallCount 7 -RunTag 'a7'
        $Summary | Should -Match '(?m)^\s*Metric-query API calls issued\s*:\s*7\s*$'
        $Diag | Should -Match '(?m)^\s*Metric-query API calls issued:\s*7\s*$'
        $Summary | Should -Not -Match $script:SummaryAnyMetricNaPattern
        $Diag | Should -Not -Match $script:DiagAnyMetricNaPattern
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
