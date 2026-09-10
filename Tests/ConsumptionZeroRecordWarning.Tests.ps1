# Offline tests pinning the "consumption requested but ZERO records collected" warning: a header-only
# Consumption CSV once shipped unflagged (the console gate excluded the exact 0/0 case). The warning must fire only when all five guards hold: requested, 0 records, 0 consumption failures, >=1 sub ran, and >=1 ran without recording a failure.
# The last two Describes pin the warning's inputs: the run-wide totals start from zero on every run (a stale record count would disarm the warning) and every stream's consumption failures reach the parent (a dropped row would mis-gate it).

BeforeAll {
    $script:RepoRoot = Split-Path -Path $PSScriptRoot -Parent

    # Read as TEXT by the source-guard Describes at the end of this file. Those two
    # counting/gating sites have no callable seam - see the coverage note there.
    $script:InventoryScript = Join-Path $script:RepoRoot 'ResourceInventory.ps1'
    $script:WrapperScript = Join-Path $script:RepoRoot 'Run-AllSubscriptions.ps1'

    . (Join-Path $script:RepoRoot 'Functions/Common.Functions.ps1')
    . (Join-Path $script:RepoRoot 'Functions/RunAllSubscriptions.Functions.ps1')
    . (Join-Path $script:RepoRoot 'Functions/ResourceInventory.Functions.ps1')

    # Write-RdaShareableDiagnosticsLog reads the run-wide failure lists from the session, so a
    # pwsh that already ran the wrapper would feed that run's failures into every case below.
    # Clear them for this file and put the caller's values back in AfterAll.
    $script:SessionFailureLists = @{}
    foreach ($Name in 'ConsumptionFailedSubs', 'MetricsFailedSubs', 'MarketplaceFailedSubs', 'CollectorFailures')
    {
        $Existing = Get-Variable -Name $Name -Scope Global -ErrorAction SilentlyContinue
        $script:SessionFailureLists[$Name] = if ($Existing) { @{ Value = $Existing.Value } } else { $null }
        Remove-Variable -Name $Name -Scope Global -ErrorAction SilentlyContinue
    }

    # Fail loudly here rather than with a confusing "command not found" mid-test if
    # a future change renames either builder, or the single owner of the
    # excluded-by-scope text that both of them call.
    foreach ($Fn in @('Get-RunSummaryLogContent', 'Write-RdaShareableDiagnosticsLog', 'Get-RdaConsumptionExcludedByScopeText'))
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

    # The marker for the SIBLING condition: the billing API returned rows and the
    # tool wrote none of them. Taken from the shared preamble in
    # Get-RdaConsumptionExcludedByScopeText, so both surfaces carry it verbatim and
    # neither can be reworded without the other failing.
    #
    # CONSTRAINT: this phrase must stay free of regex metacharacters. It is used BOTH
    # as a regex (Should -Match) and as a literal (.Contains in
    # script:GetExcludedNoteText), and those two only agree while it has none. That
    # is why it stops short of the preamble's 'usage row(s)' parenthetical.
    $script:ExcludedMarker = 'but none were written'

    # The two mutually exclusive cause forms the helper emits. Narrow is the
    # default (no -ResourceGroup in play, so only the data-shape guard is
    # reachable); scoped names all three exclusions and closes with a remedy.
    $script:NarrowCauseMarker = 'The exclusion that does this is:'
    $script:ScopedCauseMarker = 'The exclusions that do this are:'
    $script:ScopedRemedyMarker = 'Re-run without -ResourceGroup'

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
            [string]$RunTag,
            # Rows FETCHED from the billing API, and whether the run was
            # -ResourceGroup scoped. Both are added to the splat ONLY when the
            # caller actually supplies them, so every pre-existing It block calls
            # the builder exactly as it does today and keeps the -1 / $false
            # defaults under test. Do NOT give these defaults that get splatted
            # unconditionally - that would silently retire the sentinel coverage.
            [int]$RowsFetched,
            [bool]$ResourceGroupScoped,
            # Per-subscription consumption failures for THIS call. NOT splatted like
            # the two above, because it is not a builder parameter:
            # Write-RdaShareableDiagnosticsLog reads $Global:ConsumptionFailedSubs
            # directly, so setting that global is the only way to drive its
            # $ConsumpSkips guard. Assigned on EVERY call - to the empty default when
            # the caller omits it - and restored in the finally, so the gate never
            # reads ambient state another suite left behind, and an omitting caller
            # gets the same "no failures reported" verdict it gets today.
            $ConsumptionFailedSubs = @()
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
        if ($PSBoundParameters.ContainsKey('RowsFetched')) { $Params.ConsumptionRowsFetchedCount = $RowsFetched }
        if ($PSBoundParameters.ContainsKey('ResourceGroupScoped')) { $Params.ConsumptionResourceGroupScoped = $ResourceGroupScoped }

        $PriorFailedSubs = $Global:ConsumptionFailedSubs
        $Global:ConsumptionFailedSubs = $ConsumptionFailedSubs
        try
        {
            $File = Write-RdaShareableDiagnosticsLog @Params
            if ([string]::IsNullOrEmpty($File) -or -not (Test-Path -LiteralPath $File))
            {
                throw 'Write-RdaShareableDiagnosticsLog did not return a written file.'
            }
            return (Get-Content -LiteralPath $File -Raw)
        }
        finally
        {
            $Global:ConsumptionFailedSubs = $PriorFailedSubs
        }
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
            [switch]$Obfuscated,
            # Splatted ONLY when supplied - see the note on script:GetDiagText.
            # There is deliberately no scoped counterpart here: Get-RunSummaryLogContent
            # has no such parameter, because Run-AllSubscriptions.ps1 (whose
            # RunSummary.log it builds) has no -ResourceGroup to be scoped by.
            [int]$RowsFetched
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
        if ($PSBoundParameters.ContainsKey('RowsFetched')) { $Params.ConsumptionRowsFetchedCount = $RowsFetched }
        return ((Get-RunSummaryLogContent @Params) -join [Environment]::NewLine)
    }

    # Slice ONLY the excluded-by-scope note out of a surface's full text: the run of
    # lines starting at the marker, as many lines as the single owner returns.
    #
    # Asserting a negative against the NOTE rather than the whole artifact is what
    # keeps it honest. A whole-artifact negative is coupled to every other line the
    # builder might ever emit, so it can be tripped by unrelated wording (a false
    # failure) or - worse - be satisfied because the note was never emitted at all
    # (a vacuous pass). Returns '' when the note is absent, so a caller that forgot
    # to assert presence gets an obviously empty subject rather than a silent pass.
    # Plain param() with an explicit throw, matching the two helpers above rather
    # than using [Parameter(Mandatory)]: a Mandatory parameter turns this into an
    # advanced function that PROMPTS for a missing argument, and a prompt is
    # invisible when output is captured, so an omission would hang a run instead of
    # failing it.
    function script:GetExcludedNoteText
    {
        param(
            [string]$SurfaceText,
            [int]$RowsFetched,
            [bool]$ResourceGroupScoped = $false
        )
        if ([string]::IsNullOrEmpty($SurfaceText)) { throw 'script:GetExcludedNoteText requires -SurfaceText.' }

        $Owner = @(Get-RdaConsumptionExcludedByScopeText -RowsFetched $RowsFetched -Indent '  ' -ResourceGroupScoped:$ResourceGroupScoped)
        $Lines = @($SurfaceText -split "`r?`n")
        for ($Index = 0; $Index -lt $Lines.Count; $Index++)
        {
            if (-not $Lines[$Index].Contains($script:ExcludedMarker)) { continue }

            # The slice LENGTH comes from the owner, but which form the owner returns
            # is chosen by the CALLER's -ResourceGroupScoped. If the caller disagrees
            # with the form the surface actually emitted, the slice runs short (and a
            # negative asserted against the dropped tail passes vacuously - the exact
            # failure this helper exists to prevent) or long (dragging in following
            # lines, restoring the whole-artifact coupling it removed). Verifying the
            # last line pins the BOUNDARY and throws on a mismatch, while leaving the
            # note's BODY for the tests to assert.
            $Last = $Index + $Owner.Count - 1
            if ($Last -gt ($Lines.Count - 1))
            {
                throw ("Note starts at line {0} but the surface has only {1} line(s), so a {2}-line note cannot fit: -ResourceGroupScoped disagrees with what was emitted." -f ($Index + 1), $Lines.Count, $Owner.Count)
            }
            if ($Lines[$Last] -cne $Owner[-1])
            {
                throw ("Sliced {0} line(s) ending '{1}' but the owner's note ends '{2}': -ResourceGroupScoped disagrees with the form the surface emitted." -f $Owner.Count, $Lines[$Last], $Owner[-1])
            }
            return (($Lines[$Index..$Last]) -join "`n")
        }
        return ''
    }
}

# Every meaningful relation between rows FETCHED and rows WRITTEN. The domain is
# two integers, so it is ENUMERATED rather than sampled: the builders are pure
# functions of these inputs, so covering the grid exhaustively is stronger than
# generating points in it. The last row (written greater than fetched) is
# impossible in a real run - it is the stale mixed-version stream-summary path -
# and is included so the gates are proven not to emit BOTH texts even on nonsense.
#
# BeforeDiscovery, not BeforeAll: -ForEach is expanded during Pester's DISCOVERY
# pass, so a grid built in BeforeAll would still be $null when the It blocks are
# generated and every case would silently vanish.
BeforeDiscovery {
    $script:FetchedWrittenGrid = @(
        @{ Fetched = 0; Written = 0; Case = 'API returned nothing' }
        @{ Fetched = 1; Written = 0; Case = 'one row arrived, excluded' }
        @{ Fetched = 481; Written = 0; Case = 'every row excluded' }
        @{ Fetched = 481; Written = 180; Case = 'partially excluded' }
        @{ Fetched = 481; Written = 481; Case = 'nothing excluded' }
        @{ Fetched = 1; Written = 1; Case = 'single row, nothing excluded' }
        @{ Fetched = 180; Written = 481; Case = 'written exceeds fetched, stale input' }
    )
}

AfterAll {
    if ($script:DiagDir -and (Test-Path -LiteralPath $script:DiagDir))
    {
        Remove-Item -LiteralPath $script:DiagDir -Recurse -Force
    }
    foreach ($Name in @($script:SessionFailureLists.Keys))
    {
        if ($null -ne $script:SessionFailureLists[$Name]) { Set-Variable -Name $Name -Scope Global -Value $script:SessionFailureLists[$Name].Value }
        else { Remove-Variable -Name $Name -Scope Global -ErrorAction SilentlyContinue }
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
        # Two conditions, and both are load-bearing. The first is the original polarity guard: requested
        # means NOT skipped. The second was added so a subscription whose collection was ABORTED - billing
        # deliberately never pulled - does not report "requested but zero rows collected", a false
        # negative. An inverted polarity (-ConsumptionRequested:($SkipConsumption.IsPresent)) still fails
        # this, and so does dropping either condition.
        @([regex]::Matches($InnerSrc, '(?m)^[^#\r\n]*-ConsumptionRequested:?\s*\(\(-not \$SkipConsumption\.IsPresent\) -and -not \$script:BillingSkippedForAbort\)')).Count |
            Should -BeGreaterOrEqual 2 -Because 'both packaging branches pass the flag the same way'
        # And no call site is left on the old single-condition form, which would re-open the false negative.
        @([regex]::Matches($InnerSrc, '(?m)^[^#\r\n]*-ConsumptionRequested:?\s*\(-not \$SkipConsumption\.IsPresent\)\s')).Count |
            Should -Be 0 -Because 'a call site without the abort condition would report a false zero for an aborted subscription'

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

    It 'Stays silent, and says why, when a parallel stream did not report back' {
        # Its record counts were only in the summary it never wrote, so a zero total proves nothing.
        $Lines = Get-RunSummaryLogContent -Version '0.0.0-test' -Processed 2 `
            -ConsumptionRecordCount 0 -ConsumptionRequested $true -UnreportedStreamCount 1
        $Text = $Lines -join [Environment]::NewLine
        $Text | Should -Not -Match $script:WarnMarker
        $Text | Should -Match 'Streams that did not report\s*:\s*1 \(their record counts and health are not in the figures above\)'
        $Text | Should -Match 'Consumption records collected\s*:\s*0\b' -Because 'the absence above is a gate decision, not a document that failed to render'
        $Clean = (Get-RunSummaryLogContent -Version '0.0.0-test' -Processed 2 -ConsumptionRecordCount 0 -ConsumptionRequested $true) -join [Environment]::NewLine
        $Clean | Should -Match $script:WarnMarker -Because 'with every stream reported, the warning still fires'
        $Clean | Should -Not -Match 'Streams that did not report'
    }
    It 'The wrapper hands it the number of streams that did not report, and gates its own console claims on it (source guard)' {
        $WrapSrc = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'Run-AllSubscriptions.ps1') -Raw
        $WrapSrc | Should -Match '-UnreportedStreamCount \$UnreportedStreamCount `'
        $WrapSrc | Should -Match '(?m)^if \(-not \$SkipConsumption -and \$ConsumptionRowsFetched -eq 0 [^\r\n]*-and \$UnreportedStreamCount -eq 0\)\s*$'
        $WrapSrc | Should -Match '(?m)^elseif \(\$MarketplaceRequested -and \$MarketplaceRecords -eq 0 [^\r\n]*-and \$UnreportedStreamCount -eq 0\)\s*$'
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

Describe 'Run-AllSubscriptions.ps1 starts every run from zero run-wide totals' {

    # Two writers only ever add to these globals: ResourceInventory.ps1, which runs in the
    # wrapper's own process on the sequential path, and the wrapper's per-stream summary
    # aggregation on the parallel path. A PowerShell prompt (Azure Cloud Shell included) keeps
    # one process across runs, so without a reset at the top of the wrapper a second run in the
    # same session reported the first run's records and failures as its own. A stale record
    # total also disarms the zero-record warning pinned above: a run that collected nothing
    # still reads as non-zero.

    BeforeDiscovery {
        # Every run-wide total the wrapper summarises, with a value an earlier run can leave behind.
        $script:RunTotals = @(
            @{ Name = 'ConsumptionRecordCount'; IsList = $false; Stale = 612 }
            @{ Name = 'ConsumptionRowsFetchedCount'; IsList = $false; Stale = 640 }
            @{ Name = 'ConsumptionFailedSubs'; IsList = $true; Stale = @([pscustomobject]@{ Name = 'earlier run'; Id = '12345678-1234-1234-1234-123456789012'; Message = 'stale' }) }
            @{ Name = 'MetricsApiCallCount'; IsList = $false; Stale = 34 }
            @{ Name = 'MetricsFailedSubs'; IsList = $true; Stale = @([pscustomobject]@{ Name = 'earlier run'; Id = '12345678-1234-1234-1234-123456789012'; Message = 'stale' }) }
            @{ Name = 'MarketplaceRecordCount'; IsList = $false; Stale = 7 }
            @{ Name = 'MarketplaceFailedSubs'; IsList = $true; Stale = @([pscustomobject]@{ Name = 'earlier run'; Id = '12345678-1234-1234-1234-123456789012'; Message = 'stale' }) }
            @{ Name = 'CollectorFailures'; IsList = $true; Stale = @([pscustomobject]@{ Id = '12345678-1234-1234-1234-123456789012'; Module = 'VirtualMachines'; Message = 'stale' }) }
            @{ Name = 'MemoryReadings'; IsList = $true; Stale = @([pscustomobject]@{ Id = '12345678-1234-1234-1234-123456789012'; Stamp = '20260101000000'; Phase = 'end'; Resources = 1; HeapMB = 1.0; WorkingSetMB = 1.0; LimitMB = 1.0 }) }
        )
    }

    BeforeAll {
        $ParseErrors = $null
        $WrapperAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepoRoot 'Run-AllSubscriptions.ps1'), [ref]$null, [ref]$ParseErrors)
        if ($ParseErrors) { throw ('Run-AllSubscriptions.ps1 does not parse: ' + (($ParseErrors | ForEach-Object { $_.Message }) -join '; ')) }
        # Top-level statements only: a reset nested in a function or a branch does not run on every start.
        $script:WrapperTopLevel = @($WrapperAst.EndBlock.Statements)
        # The statement that dispatches the subscription loop; the sequential and parallel paths both live under it.
        $script:DispatchStatement = $script:WrapperTopLevel | Where-Object {
            $_ -is [System.Management.Automation.Language.IfStatementAst] -and
            $_.Clauses[0].Item1.Extent.Text -eq '$ParallelStreams -le 1'
        } | Select-Object -First 1
        if (-not $script:DispatchStatement) { throw 'The subscription dispatch (if ($ParallelStreams -le 1)) was not found at the top level of Run-AllSubscriptions.ps1.' }
        # The value in force when subscriptions start: the LAST plain assignment ahead of the dispatch.
        $script:GetReset = {
            param([string]$Name)
            $script:WrapperTopLevel | Where-Object {
                $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $_.Operator -eq 'Equals' -and
                $_.Left.Extent.Text -eq ('$Global:' + $Name) -and
                $_.Extent.EndOffset -le $script:DispatchStatement.Extent.StartOffset
            } | Select-Object -Last 1
        }
    }

    # A single case even when the table is empty, so this Describe can never silently vanish.
    It 'pins every run-wide total the parallel stream worker resets' -ForEach @(@{ Pinned = @($script:RunTotals | ForEach-Object { $_.Name }) }) {
        $StreamErrors = $null
        $StreamAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepoRoot 'Run-AllSubscriptions.Stream.ps1'), [ref]$null, [ref]$StreamErrors)
        $StreamErrors | Should -BeNullOrEmpty
        $StreamResets = @($StreamAst.EndBlock.Statements | Where-Object {
                $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $_.Operator -eq 'Equals' -and
                $_.Left.Extent.Text -match '^\$Global:\w+$'
            } | ForEach-Object { $_.Left.Extent.Text.Substring('$Global:'.Length) } | Sort-Object -Unique)
        $StreamResets.Count | Should -BeGreaterThan 0 -Because 'the stream worker resets its own run-wide totals'
        (@($Pinned | Sort-Object -Unique) -join ',') | Should -Be ($StreamResets -join ',') -Because 'every total the stream worker resets must also be reset for the sequential path, and pinned here'
    }

    It 'pins every run-wide total the wrapper itself resets before the dispatch' -ForEach @(@{ Pinned = @($script:RunTotals | ForEach-Object { $_.Name }) }) {
        $WrapperResets = @($script:WrapperTopLevel | Where-Object {
                $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $_.Operator -eq 'Equals' -and
                $_.Left.Extent.Text -match '^\$Global:\w+$' -and
                $_.Extent.EndOffset -le $script:DispatchStatement.Extent.StartOffset
            } | ForEach-Object { $_.Left.Extent.Text.Substring('$Global:'.Length) } | Sort-Object -Unique)
        (@($Pinned | Sort-Object -Unique) -join ',') | Should -Be ($WrapperResets -join ',') -Because 'a total reset only in the wrapper would never be mirrored in the stream worker'
    }

    It 'resets $Global:<Name> at the top level, before any subscription is processed' -ForEach $script:RunTotals {
        & $script:GetReset $Name | Should -Not -BeNullOrEmpty -Because "without it a second run in one session inherits the previous run's $Name"
    }

    It 'clears a $Global:<Name> that an earlier run in the same session left behind' -ForEach $script:RunTotals {
        $Reset = & $script:GetReset $Name
        $Reset | Should -Not -BeNullOrEmpty
        $Existing = Get-Variable -Name $Name -Scope Global -ErrorAction SilentlyContinue
        # Snapshot the VALUE: the variable object itself changes when the reset runs.
        $Snapshot = if ($Existing) { @{ Value = $Existing.Value } } else { $null }
        try
        {
            Set-Variable -Name $Name -Scope Global -Value $Stale
            . ([scriptblock]::Create($Reset.Extent.Text))
            $After = (Get-Variable -Name $Name -Scope Global).Value
            if ($IsList)
            {
                @($After | Where-Object { $null -ne $_ }).Count | Should -Be 0 -Because 'no earlier entry may survive into this run'
            }
            else
            {
                $After | Should -Be 0
            }
        }
        finally
        {
            if ($null -ne $Snapshot) { Set-Variable -Name $Name -Scope Global -Value $Snapshot.Value }
            else { Remove-Variable -Name $Name -Scope Global -ErrorAction SilentlyContinue }
        }
    }
}

Describe 'Run-AllSubscriptions.Stream.ps1 passes every consumption failure to the wrapper' {

    # Select-Object -Unique treats any two [pscustomobject] rows as equal, so deduplicating the
    # stream summary with it kept one consumption failure per stream: with -ParallelStreams the
    # RunSummary under-counted failed subscriptions and MainSummary read ok for the dropped ones.

    BeforeAll {
        $ParseErrors = $null
        $StreamAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepoRoot 'Run-AllSubscriptions.Stream.ps1'), [ref]$null, [ref]$ParseErrors)
        if ($ParseErrors) { throw ('Run-AllSubscriptions.Stream.ps1 does not parse: ' + (($ParseErrors | ForEach-Object { $_.Message }) -join '; ')) }
        $SummaryAssignment = $StreamAst.EndBlock.Statements | Where-Object {
            $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -eq '$Summary'
        } | Select-Object -First 1
        if (-not $SummaryAssignment) { throw 'The stream summary ($Summary = [pscustomobject]@{ ... }) was not found in Run-AllSubscriptions.Stream.ps1.' }
        $Table = $SummaryAssignment.Right.Find({ param($N) $N -is [System.Management.Automation.Language.HashtableAst] }, $true)
        $Entry = @($Table.KeyValuePairs | Where-Object { $_.Item1.Extent.Text -eq 'ConsumptionFailedSubs' }) | Select-Object -First 1
        if (-not $Entry) { throw 'The stream summary has no ConsumptionFailedSubs entry.' }
        # The entry's own expression, run against a list the stream built.
        $script:StreamFailuresEntry = [scriptblock]::Create('param($ConsumptionFailedSubs) ' + $Entry.Item2.Extent.Text)
    }

    It 'keeps the failures of two different subscriptions from the same stream' {
        $Failures = @(
            [pscustomobject]@{ Name = 'first'; Id = '12345678-1234-1234-1234-123456789012'; Message = 'stopped'; Complete = $false }
            [pscustomobject]@{ Name = 'second'; Id = 'second-subscription'; Message = 'stopped'; Complete = $false }
        )

        $Reported = @(& $script:StreamFailuresEntry $Failures)

        $Reported.Count | Should -Be 2 -Because 'each failed subscription must reach RunSummary and its MainSummary row'
        (@($Reported | ForEach-Object { $_.Id }) -join ',') | Should -Be '12345678-1234-1234-1234-123456789012,second-subscription'
    }
}

# =============================================================================
# Rows FETCHED from the billing API vs rows WRITTEN to Consumption_*.csv
# =============================================================================
# One consumption counter was split into two at the point their meanings diverge.
# Both builders are driven FOR REAL below, across the whole fetched/written grid -
# nothing here reimplements them.
#
# WHAT THIS SUITE DOES NOT COVER - stated plainly rather than implied away:
#
#   1. The per-stream summary field (ConsumptionRowsFetched, written by
#      Run-AllSubscriptions.Stream.ps1) and the parent's aggregation arithmetic in
#      Run-AllSubscriptions.ps1. Neither is reachable without launching a real
#      stream worker, so cross-stream aggregation (spec clause 2.8) is proven ONLY
#      by a live -ParallelStreams 2 run. Do NOT read this file as covering it.
#
#   2. GetResourceConsumption()'s counting change itself. It is a nested function
#      inside ExecuteInventoryProcessing() in ResourceInventory.ps1, so it cannot
#      be dot-sourced or invoked without executing the whole script including
#      authentication, and the wrapper's console gate sits in the top-level script
#      body. Neither has a seam. The two source-guard Describes at the end of this
#      file read those files as TEXT and assert presence and ORDER only, never
#      behaviour. The end-to-end run against a real subscription is what proves
#      those paths. Tests/ConsumptionResourceGroupFilter.Tests.ps1 carries the
#      same limitation and the same pattern.

Describe 'Both consumption numbers are reported, distinctly labelled' {

    It 'Diagnostics_*.log reports collected and fetched separately when they differ' {
        $Text = script:GetDiagText -RecordCount 180 -Requested $true -RowsFetched 481 -RunTag 'fw1'
        $Text | Should -Match 'Consumption records collected:\s*180(?!\d)'
        $Text | Should -Match 'Consumption rows fetched from the billing API:\s*481(?!\d)'
    }

    It 'RunSummary.log reports collected and fetched separately when they differ' {
        $Text = script:GetSummaryText -RecordCount 180 -Processed 1 -RowsFetched 481
        $Text | Should -Match 'Consumption records collected\s*:\s*180(?!\d)'
        $Text | Should -Match 'Consumption rows fetched\s*:\s*481(?!\d)'
    }

    It 'Reports the same figure twice on both surfaces when nothing was excluded' {
        $Diag = script:GetDiagText -RecordCount 481 -Requested $true -RowsFetched 481 -RunTag 'fw2'
        $Summary = script:GetSummaryText -RecordCount 481 -Processed 1 -RowsFetched 481
        $Diag | Should -Match 'Consumption records collected:\s*481(?!\d)'
        $Diag | Should -Match 'Consumption rows fetched from the billing API:\s*481(?!\d)'
        $Summary | Should -Match 'Consumption records collected\s*:\s*481(?!\d)'
        $Summary | Should -Match 'Consumption rows fetched\s*:\s*481(?!\d)'
    }

    It 'Diagnostics_*.log omits the fetched line entirely when -SkipConsumption was passed' {
        # A skipped phase reports as SKIPPED, not as numbers. The fetched figure is
        # supplied here and must still be suppressed.
        $Text = script:GetDiagText -RecordCount 0 -Requested $false -RowsFetched 481 -RunTag 'fw3'
        $Text | Should -Match 'n/a'
        $Text | Should -Not -Match 'Consumption rows fetched'
    }
}

Describe 'The billing-API zero-record warning is keyed on rows FETCHED' {

    Context 'It fires when the API itself returned nothing' {

        It 'Diagnostics_*.log warns when fetched is 0' {
            $Text = script:GetDiagText -RecordCount 0 -Requested $true -RowsFetched 0 -RunTag 'zk1'
            $Text | Should -Match $script:WarnMarker
        }

        It 'RunSummary.log warns when fetched is 0' {
            $Text = script:GetSummaryText -RecordCount 0 -Processed 1 -RowsFetched 0
            $Text | Should -Match $script:WarnMarker
        }

        It 'Keeps the existing named causes unchanged on both surfaces' {
            # Those three causes are true ONLY when the API returned nothing, which
            # is exactly why the gate moved onto the fetched count rather than away
            # from this text.
            $Diag = script:GetDiagText -RecordCount 0 -Requested $true -RowsFetched 0 -RunTag 'zk2'
            $Summary = script:GetSummaryText -RecordCount 0 -Processed 1 -RowsFetched 0
            foreach ($Text in @($Diag, $Summary))
            {
                $Text | Should -Match 'CSP'
                $Text | Should -Match 'Partner Center'
                $Text | Should -Match 'not transitioned to the Azure plan'
                $Text | Should -Match 'legacy usage API does not serve'
            }
        }
    }

    Context 'It is withheld when rows arrived and none were written' {

        It 'Diagnostics_*.log does not warn when fetched is greater than 0 and written is 0' {
            $Text = script:GetDiagText -RecordCount 0 -Requested $true -RowsFetched 481 -RunTag 'zk3'
            $Text | Should -Not -Match $script:WarnMarker -Because 'the billing API answered WITH data, so every cause that warning names is false'
        }

        It 'RunSummary.log does not warn when fetched is greater than 0 and written is 0' {
            $Text = script:GetSummaryText -RecordCount 0 -Processed 1 -RowsFetched 481
            $Text | Should -Not -Match $script:WarnMarker -Because 'the billing API answered WITH data, so every cause that warning names is false'
        }
    }
}

Describe 'The excluded-by-scope note reports the previously unreported case' {

    Context 'It appears when fetched is greater than 0 and written is 0' {

        It 'Diagnostics_*.log emits the note' {
            $Text = script:GetDiagText -RecordCount 0 -Requested $true -RowsFetched 481 -RunTag 'ex1'
            $Text | Should -Match $script:ExcludedMarker
            $Text | Should -Match 'the billing API returned 481 usage row'
        }

        It 'RunSummary.log emits the note' {
            $Text = script:GetSummaryText -RecordCount 0 -Processed 1 -RowsFetched 481
            $Text | Should -Match $script:ExcludedMarker
            $Text | Should -Match 'the billing API returned 481 usage row'
        }
    }

    Context 'It stays silent on every other input' {

        It 'Diagnostics_*.log is silent when records were written' {
            $Text = script:GetDiagText -RecordCount 180 -Requested $true -RowsFetched 481 -RunTag 'ex2'
            $Text | Should -Not -Match $script:ExcludedMarker
        }

        It 'RunSummary.log is silent when records were written' {
            $Text = script:GetSummaryText -RecordCount 180 -Processed 1 -RowsFetched 481
            $Text | Should -Not -Match $script:ExcludedMarker
        }

        It 'Diagnostics_*.log is silent when the API returned nothing' {
            $Text = script:GetDiagText -RecordCount 0 -Requested $true -RowsFetched 0 -RunTag 'ex3'
            $Text | Should -Not -Match $script:ExcludedMarker
        }

        It 'RunSummary.log is silent when the API returned nothing' {
            $Text = script:GetSummaryText -RecordCount 0 -Processed 1 -RowsFetched 0
            $Text | Should -Not -Match $script:ExcludedMarker
        }

        It 'Diagnostics_*.log is silent when -SkipConsumption was passed' {
            $Text = script:GetDiagText -RecordCount 0 -Requested $false -RowsFetched 481 -RunTag 'ex4'
            $Text | Should -Not -Match $script:ExcludedMarker
        }

        It 'RunSummary.log is silent when -SkipConsumption was passed' {
            $Text = script:GetSummaryText -RecordCount 0 -Processed 1 -RowsFetched 481 -Requested $false -InvocationParameters @{ SkipConsumption = [switch]$true }
            $Text | Should -Not -Match $script:ExcludedMarker
        }

        It 'RunSummary.log is silent when a consumption failure was already reported' {
            # A reported failure is surfaced by its own block, exactly as for the
            # zero-record warning; both branches repeat that guard, on both surfaces.
            $Failed = @([pscustomobject]@{ Name = 'x'; Id = 'y'; Message = 'boom' })
            $Text = script:GetSummaryText -RecordCount 0 -Processed 1 -RowsFetched 481 -ConsumptionFailedSubs $Failed
            $Text | Should -Not -Match $script:ExcludedMarker
        }

        It 'Diagnostics_*.log is silent when a consumption failure was already reported' {
            # The guard this branch was previously missing. A reported billing failure
            # already has its own block in the log, and it - not scope - is then the
            # reason nothing was written, so emitting the note here would assert a
            # cause the run has no evidence for.
            #
            # The presence assertion comes FIRST and is load-bearing: the builder reads
            # $Global:ConsumptionFailedSubs rather than taking a parameter, so if the
            # failure never reached it the negative below would pass vacuously.
            $Failed = @([pscustomobject]@{ Name = 'x'; Id = 'y'; Message = 'boom' })
            $Text = script:GetDiagText -RecordCount 0 -Requested $true -RowsFetched 481 -ConsumptionFailedSubs $Failed -RunTag 'ex5'
            $Text | Should -Match 'Consumption failed/incomplete subscriptions:\s*1(?!\d)' -Because 'the failure must actually reach the builder, or the negative below is vacuous'
            $Text | Should -Not -Match $script:ExcludedMarker
            $Text | Should -Not -Match $script:WarnMarker -Because 'a reported failure withholds BOTH texts, not just this one - otherwise dropping the sibling''s fetched test would hand this input to a branch claiming the API returned nothing'
        }

        It 'RunSummary.log is silent when no subscription actually ran' {
            $Text = script:GetSummaryText -RecordCount 0 -Processed 0 -RowsFetched 481
            $Text | Should -Not -Match $script:ExcludedMarker
        }
    }
}

Describe 'The two consumption branches are mutually exclusive' {

    It 'Diagnostics_*.log never emits both texts - <Case> (fetched <Fetched>, written <Written>)' -ForEach $script:FetchedWrittenGrid {
        $Text = script:GetDiagText -RecordCount $Written -Requested $true -RowsFetched $Fetched -RunTag ('mx{0}x{1}' -f $Fetched, $Written)
        $BothPresent = ($Text -match $script:WarnMarker) -and ($Text -match $script:ExcludedMarker)
        $BothPresent | Should -BeFalse -Because 'the two texts contradict each other - one says the API returned nothing, the other says it returned rows'
    }

    It 'RunSummary.log never emits both texts - <Case> (fetched <Fetched>, written <Written>)' -ForEach $script:FetchedWrittenGrid {
        $Text = script:GetSummaryText -RecordCount $Written -Processed 1 -RowsFetched $Fetched
        $BothPresent = ($Text -match $script:WarnMarker) -and ($Text -match $script:ExcludedMarker)
        $BothPresent | Should -BeFalse -Because 'the two texts contradict each other - one says the API returned nothing, the other says it returned rows'
    }

    It 'Diagnostics_*.log emits the RIGHT one of the pair - <Case> (fetched <Fetched>, written <Written>)' -ForEach $script:FetchedWrittenGrid {
        # The positive companion to the two above. Mutual exclusivity alone is
        # satisfied by emitting NEITHER, so this pins which branch owns which case.
        $Text = script:GetDiagText -RecordCount $Written -Requested $true -RowsFetched $Fetched -RunTag ('one{0}x{1}' -f $Fetched, $Written)
        if ($Fetched -eq 0)
        {
            $Text | Should -Match $script:WarnMarker -Because 'the API returned nothing'
            $Text | Should -Not -Match $script:ExcludedMarker
        }
        elseif ($Written -eq 0)
        {
            $Text | Should -Match $script:ExcludedMarker -Because 'rows arrived and none were written'
            $Text | Should -Not -Match $script:WarnMarker
        }
        else
        {
            $Text | Should -Not -Match $script:WarnMarker -Because 'rows were written, so neither signal applies'
            $Text | Should -Not -Match $script:ExcludedMarker -Because 'rows were written, so neither signal applies'
        }
    }
}

Describe 'The excluded-by-scope note is safe in an obfuscated bundle' {

    It 'Appears in the OBFUSCATED Diagnostics_*.log and carries no GUID' {
        # Obfuscated bundles are the ones normally shared, so this is the build that
        # actually reaches a report consumer.
        $Text = script:GetDiagText -RecordCount 0 -Requested $true -RowsFetched 481 -Obfuscated -RunTag 'ob1'
        $Text | Should -Match $script:ExcludedMarker
        $Text | Should -Not -Match '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
    }

    It 'Appears in the OBFUSCATED RunSummary.log and carries no GUID' {
        $Text = script:GetSummaryText -RecordCount 0 -Processed 1 -RowsFetched 481 -Obfuscated
        $Text | Should -Match $script:ExcludedMarker
        $Text | Should -Not -Match '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
    }

    It 'Carries no GUID in its SCOPED form either' {
        # The scoped form names more causes, so it is the longer text and the one
        # more likely to acquire an identifier by accident later.
        $Text = script:GetDiagText -RecordCount 0 -Requested $true -RowsFetched 481 -ResourceGroupScoped $true -Obfuscated -RunTag 'ob2'
        $Text | Should -Match $script:ScopedCauseMarker
        $Text | Should -Not -Match '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
    }
}

Describe 'The two surfaces agree on the excluded-by-scope note BODY' {

    # Scope of the claim, stated exactly: the two surfaces render the same note
    # TEXT. Their gates agree on requested / fetched / written / no-reported-failure,
    # but they are not identical - only Get-RunSummaryLogContent carries
    # ($Processed -gt 0), which has no per-subscription analogue in the diagnostics
    # builder - and nothing here asserts that they are.

    It 'Uses the same marker phrase in RunSummary.log and Diagnostics_*.log' {
        # Mirrors the existing "The two surfaces agree" Describe above. The note has
        # ONE owner (Get-RdaConsumptionExcludedByScopeText); this is what stops a
        # reword of one surface leaving the other behind.
        $Summary = script:GetSummaryText -RecordCount 0 -Processed 1 -RowsFetched 481
        $Diag = script:GetDiagText -RecordCount 0 -Requested $true -RowsFetched 481 -RunTag 'ag1'
        $Summary | Should -Match $script:ExcludedMarker
        $Diag | Should -Match $script:ExcludedMarker
    }

    It 'Renders the identical note body on both surfaces for the same input' {
        # Stronger than a shared marker: the whole note, line for line, EQUAL to what
        # the owner returns rather than merely contained in the surface. Both
        # surfaces pass the same two-space indent, so a divergence here means one of
        # them stopped calling the shared owner. -BeExactly, not -Be: Should -Be is
        # case-insensitive, which is the wrong bar for a text-identity check, and it
        # prints both texts on failure.
        $Summary = script:GetSummaryText -RecordCount 0 -Processed 1 -RowsFetched 481
        $Diag = script:GetDiagText -RecordCount 0 -Requested $true -RowsFetched 481 -RunTag 'ag2'
        $Expected = ((Get-RdaConsumptionExcludedByScopeText -RowsFetched 481 -Indent '  ') -join "`n")
        script:GetExcludedNoteText -SurfaceText $Summary -RowsFetched 481 | Should -BeExactly $Expected -Because 'the RunSummary note must come from the shared owner verbatim'
        script:GetExcludedNoteText -SurfaceText $Diag -RowsFetched 481 | Should -BeExactly $Expected -Because 'the Diagnostics note must come from the shared owner verbatim'
    }
}

Describe 'Each surface names only the exclusions it could actually have hit' {

    It 'The RunSummary note never mentions -ResourceGroup, because the wrapper has no such parameter' {
        # Run-AllSubscriptions.ps1 cannot be resource-group scoped, so naming a
        # -ResourceGroup filter - or telling the operator to remove one - would be a
        # factual error about the run they just performed.
        #
        # The negatives are asserted against the NOTE, sliced out of the log, not
        # against the whole log: a whole-log negative would be coupled to every
        # other line Get-RunSummaryLogContent can emit, and would read as a pass if
        # the note were missing entirely. The presence assertion comes first for the
        # same reason - an empty subject must not look like success.
        $Text = script:GetSummaryText -RecordCount 0 -Processed 1 -RowsFetched 481
        $Note = script:GetExcludedNoteText -SurfaceText $Text -RowsFetched 481
        $Note | Should -Not -BeNullOrEmpty -Because 'the note must be PRESENT for the negatives below to mean anything'
        $Note | Should -Not -Match '-ResourceGroup' -Because 'Get-RunSummaryLogContent must not pass -ResourceGroupScoped'
        $Note | Should -Not -Match 'Re-run' -Because 'there is no -ResourceGroup on this entry point to re-run without'
        $Note | Should -Match $script:NarrowCauseMarker
        $Note | Should -Not -Match $script:ScopedCauseMarker
    }

    It 'Diagnostics_*.log names all three exclusions and the remedy when the run WAS scoped' {
        $Text = script:GetDiagText -RecordCount 0 -Requested $true -RowsFetched 481 -ResourceGroupScoped $true -RunTag 'sc1'
        $Text | Should -Match $script:ScopedCauseMarker
        $Text | Should -Match 'the -ResourceGroup filter, when no billed resource lives in that group'
        $Text | Should -Match 'a meter with no resource id'
        $Text | Should -Match 'a meter carrying no instance data at all'
        $Text | Should -Match $script:ScopedRemedyMarker
    }

    It 'Diagnostics_*.log names only the reachable exclusion when the run was NOT scoped' {
        $Text = script:GetDiagText -RecordCount 0 -Requested $true -RowsFetched 481 -ResourceGroupScoped $false -RunTag 'sc2'
        $Note = script:GetExcludedNoteText -SurfaceText $Text -RowsFetched 481
        $Note | Should -Not -BeNullOrEmpty -Because 'the note must be PRESENT for the negatives below to mean anything'
        $Note | Should -Match $script:NarrowCauseMarker
        $Note | Should -Match 'a meter carrying no instance data at all'
        $Note | Should -Not -Match '-ResourceGroup' -Because 'the operator passed no -ResourceGroup, so that exclusion was unreachable'
        $Note | Should -Not -Match 'Re-run' -Because 'there is no parameter to remove'
    }

    It 'Defaults to the narrow form when the caller omits the scoped flag entirely' {
        $Text = script:GetDiagText -RecordCount 0 -Requested $true -RowsFetched 481 -RunTag 'sc3'
        $Text | Should -Match $script:NarrowCauseMarker
        $Text | Should -Not -Match $script:ScopedCauseMarker
    }
}

Describe 'Sentinel collapse - omitting the fetched count preserves today''s verdict' {

    # This Describe is what protects the pre-existing It blocks above: every one of
    # them calls the builders WITHOUT the new parameter, so the -1 default must make
    # fetched collapse onto collected. A default of 0 would instead read as "N
    # written out of 0 fetched" and fire the zero-record warning on all of them.

    It 'Diagnostics_*.log reports fetched equal to collected when the parameter is omitted' {
        foreach ($Count in @(0, 1, 42, 481))
        {
            $Text = script:GetDiagText -RecordCount $Count -Requested $true -RunTag ('sn{0}' -f $Count)
            $Text | Should -Match ('Consumption records collected:\s*{0}(?!\d)' -f $Count)
            $Text | Should -Match ('Consumption rows fetched from the billing API:\s*{0}(?!\d)' -f $Count)
        }
    }

    It 'RunSummary.log reports fetched equal to collected when the parameter is omitted' {
        foreach ($Count in @(0, 1, 42, 481))
        {
            $Text = script:GetSummaryText -RecordCount $Count -Processed 1
            $Text | Should -Match ('Consumption records collected\s*:\s*{0}(?!\d)' -f $Count)
            $Text | Should -Match ('Consumption rows fetched\s*:\s*{0}(?!\d)' -f $Count)
        }
    }

    It 'Gives the same warning verdict as explicitly passing fetched equal to collected' {
        foreach ($Count in @(0, 1, 42, 481))
        {
            $Omitted = script:GetDiagText -RecordCount $Count -Requested $true -RunTag ('so{0}' -f $Count)
            $Explicit = script:GetDiagText -RecordCount $Count -Requested $true -RowsFetched $Count -RunTag ('se{0}' -f $Count)
            ($Omitted -match $script:WarnMarker) | Should -Be ($Explicit -match $script:WarnMarker) -Because ('the -1 sentinel must behave exactly like fetched equal to written for {0} record(s)' -f $Count)

            $OmittedSummary = script:GetSummaryText -RecordCount $Count -Processed 1
            $ExplicitSummary = script:GetSummaryText -RecordCount $Count -Processed 1 -RowsFetched $Count
            ($OmittedSummary -match $script:WarnMarker) | Should -Be ($ExplicitSummary -match $script:WarnMarker) -Because ('the -1 sentinel must behave exactly like fetched equal to written for {0} record(s)' -f $Count)
        }
    }

    It 'Can never fire the excluded-by-scope note when the parameter is omitted' {
        # With the sentinel, "fetched greater than 0" and "written is 0" cannot both
        # hold, so an omitting caller stays silent rather than guessing that
        # something was excluded. That silence is correct: nothing is KNOWN.
        foreach ($Count in @(0, 1, 42, 481))
        {
            $Text = script:GetDiagText -RecordCount $Count -Requested $true -RunTag ('sx{0}' -f $Count)
            $Text | Should -Not -Match $script:ExcludedMarker
            $Summary = script:GetSummaryText -RecordCount $Count -Processed 1
            $Summary | Should -Not -Match $script:ExcludedMarker
        }
    }

    It 'Still warns on the 0-record case exactly as the pre-existing blocks expect' {
        $Diag = script:GetDiagText -RecordCount 0 -Requested $true -RunTag 'sw1'
        $Summary = script:GetSummaryText -RecordCount 0 -Processed 1
        $Diag | Should -Match $script:WarnMarker
        $Summary | Should -Match $script:WarnMarker
    }
}

Describe 'Source guard - ResourceInventory.ps1 counts fetched at arrival, written after the write' {

    # NO behavioural coverage here, and none is available: GetResourceConsumption()
    # is nested inside ExecuteInventoryProcessing(), so it cannot be dot-sourced or
    # invoked without running the entire script including authentication. These
    # blocks verify PRESENCE and ORDER in the source text, nothing more - a refactor
    # that relocated the counters into another function earlier in the same file
    # would keep them green. Only the live run closes that gap.
    #
    # IndexOf is called with [StringComparison]::Ordinal throughout: the default
    # overload is culture-sensitive, and a source guard's verdict must not depend on
    # the host's collation when the tool has to behave identically on every OS.

    It 'ResourceInventory.ps1 exists at the expected path' {
        Test-Path -LiteralPath $script:InventoryScript | Should -BeTrue
    }

    It 'counts rows FETCHED with the Records found: log line, before anything is written' {
        $Text = Get-Content -LiteralPath $script:InventoryScript -Raw

        $LogIdx = $Text.IndexOf('Write-Log -Message ("Records found:', [StringComparison]::Ordinal)
        $FetchIdx = $Text.IndexOf('$ConsumptionRowsFetchedThisSub += $UsageDataExport.Count', [StringComparison]::Ordinal)
        $ExportIdx = $Text.IndexOf('Export-Csv -LiteralPath $Global:ConsumptionFileCsv', [StringComparison]::Ordinal)

        $LogIdx | Should -BeGreaterThan -1 -Because 'the per-page operator log line reporting the fetched page size must survive unchanged'
        $FetchIdx | Should -BeGreaterThan -1 -Because 'the fetched counter must exist'
        $ExportIdx | Should -BeGreaterThan -1 -Because 'the single per-page Export-Csv must still exist'

        $LogIdx | Should -BeLessThan $FetchIdx -Because 'fetched is counted where the page ARRIVES, next to the line that reports the page size'
        $FetchIdx | Should -BeLessThan $ExportIdx -Because 'fetched is counted before the filter loop and the write, which is what makes it the API-volume signal'
    }

    It 'counts rows WRITTEN only AFTER Export-Csv has returned' {
        $Text = Get-Content -LiteralPath $script:InventoryScript -Raw

        $ExportIdx = $Text.IndexOf('Export-Csv -LiteralPath $Global:ConsumptionFileCsv', [StringComparison]::Ordinal)
        $WrittenIdx = $Text.IndexOf('$ConsumptionRecordsThisSub += $NewUsageDataExport.Count', [StringComparison]::Ordinal)

        # Both presence checks first. IndexOf returns -1 when absent, so without the
        # $ExportIdx one a vanished Export-Csv would leave the ordering assertion
        # comparing against -1 and passing - green while the thing it orders against
        # no longer exists.
        $ExportIdx | Should -BeGreaterThan -1 -Because 'the single per-page Export-Csv must still exist for the ordering below to mean anything'
        $WrittenIdx | Should -BeGreaterThan -1 -Because 'the written counter must read the filtered ArrayList, which already IS the rows-written figure'
        $WrittenIdx | Should -BeGreaterThan $ExportIdx -Because 'counting BEFORE the call would overstate by up to a whole page when Export-Csv throws, and overstating on a healthy-looking run is the defect this split removes'
    }

    It 'no longer counts the fetched page size as records collected' {
        $Text = Get-Content -LiteralPath $script:InventoryScript -Raw
        $Text.Contains('$ConsumptionRecordsThisSub += $UsageDataExport.Count') | Should -BeFalse -Because 'that form IS the original overstatement'
    }

    It 'introduced exactly one new consumption global' {
        # (?i) is load-bearing: PowerShell treats $global: and $Global: identically
        # and this repo already writes the lowercase form elsewhere, so a
        # case-sensitive pattern would let $global:ConsumptionSomething straight past
        # the one guard whose whole job is to fail loud on an unapproved global.
        # Scope limit worth knowing: this only covers names beginning "Consumption".
        $Text = Get-Content -LiteralPath $script:InventoryScript -Raw
        $Names = @([regex]::Matches($Text, '(?i)\$Global:(Consumption[A-Za-z0-9_]*)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        ($Names -join ',') | Should -Be 'ConsumptionFailedSubs,ConsumptionFileCsv,ConsumptionRecordCount,ConsumptionRowsFetchedCount' -Because 'ConsumptionRowsFetchedCount is the ONE approved addition - anything else is an unapproved global'
    }
}

Describe 'Source guard - Run-AllSubscriptions.ps1 console gate reads the FETCHED count' {

    # Source guard only for the same reason: the console block sits in the top-level
    # script body, not a function, so there is no seam to call. .Contains is used
    # rather than -BeLike so a bracket or '?' in a future needle cannot turn the
    # check into a wildcard match.

    It 'Run-AllSubscriptions.ps1 exists at the expected path' {
        Test-Path -LiteralPath $script:WrapperScript | Should -BeTrue
    }

    It 'gates the zero-record console warning on the fetched count' {
        $Text = Get-Content -LiteralPath $script:WrapperScript -Raw
        $Text.Contains('-not $SkipConsumption -and $ConsumptionRowsFetched -eq 0') | Should -BeTrue -Because 'that warning''s named causes are true only when the API itself returned nothing'
    }

    It 'no longer gates that warning on the collected count' {
        $Text = Get-Content -LiteralPath $script:WrapperScript -Raw
        $Text.Contains('-not $SkipConsumption -and $ConsumptionRecords -eq 0') | Should -BeFalse -Because 'that form fires on a run where rows arrived and were all excluded, which is a DIFFERENT condition with different causes'
    }

    It 'emits the excluded-by-scope text from its single owner' {
        $Text = Get-Content -LiteralPath $script:WrapperScript -Raw
        $Text.Contains('Get-RdaConsumptionExcludedByScopeText') | Should -BeTrue -Because 'the console is the third surface and must not hand-copy the text'
    }

    It 'reads the fetched total from the one approved global' {
        $Text = Get-Content -LiteralPath $script:WrapperScript -Raw
        $Text.Contains('$Global:ConsumptionRowsFetchedCount') | Should -BeTrue
    }
}
