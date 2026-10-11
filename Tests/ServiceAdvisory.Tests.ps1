# SOURCE GUARDS for the -Service advisory. -Service scopes the INVENTORY phase only; metrics/consumption still run whole-subscription, so ResourceInventory.ps1 warns (advisory only, NOT enforced - Merge-RecoveryData runs -Service without the skips).
# These are source guards because the advisory is a console Warning (no artifact field, unreachable by dot-sourcing) and this bug class has already shipped once. OFFLINE - no Azure, zip, or env.

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $script:InvSrc = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'ResourceInventory.ps1') -Raw
    $script:WrapSrc = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'Run-AllSubscriptions.ps1') -Raw
}

Describe '-Service advisory: per-phase accuracy (source guard)' {

    # The core of the a748452 fix. Both lists must stay state-derived: a run that
    # already passed a skip must not be told that phase still runs, nor be told to
    # add a switch it supplied.
    It 'derives the unscoped-phase list from the skip switches, not a static string' {
        # Single-quoted: in a double-quoted PowerShell string '\$' does NOT escape
        # the sigil (backtick does), so '$SkipMetrics' would interpolate to empty and
        # the assertion would silently test the wrong pattern.
        $script:InvSrc | Should -Match '\$UnscopedPhases\s*=\s*@\(\)'
        $script:InvSrc | Should -Match '(?s)-not\s+\$SkipMetrics\.IsPresent[\s\S]{0,80}?\$UnscopedPhases\s*\+=\s*''metrics'''
        $script:InvSrc | Should -Match '(?s)-not\s+\$SkipConsumption\.IsPresent[\s\S]{0,80}?\$UnscopedPhases\s*\+=\s*''consumption'''
    }

    It 'suggests only the skip switches not already supplied' {
        $script:InvSrc | Should -Match '\$SuggestedSkips\s*=\s*@\(\)'
        $script:InvSrc | Should -Match '\$SuggestedSkips\s*\+=\s*''-SkipMetrics'''
        $script:InvSrc | Should -Match '\$SuggestedSkips\s*\+=\s*''-SkipConsumption'''
    }

    It 'stays silent when both phases were already skipped' {
        $script:InvSrc | Should -Match '@\(\$UnscopedPhases\)\.Count\s*-gt\s*0'
    }

    # REGRESSION GUARD, corrected. This used to require the tip be gated on
    # -not $SkipMetrics.IsPresent, on the belief that scoping metrics was its only
    # benefit. Measured otherwise: -ResourceGroup also narrows consumption
    # (480 rows across 29 resource groups unscoped, 180 rows in 1 group scoped), so
    # a -SkipMetrics run still benefits and must still be offered it.
    #
    # The gate is now the single honest condition - withhold only when the operator
    # already supplied it. Withholding on -SkipMetrics would hide a switch that
    # genuinely helps the consumption phase such a run is still executing. The
    # advisory as a whole is already silent when BOTH phases are skipped
    # ($UnscopedPhases non-empty, asserted above), so nothing reaching this point
    # lacks a phase the tip narrows.
    It 'gates the -ResourceGroup tip only on -ResourceGroup not already being supplied' {
        $script:InvSrc | Should -Match '(?s)\$RgTip\s*=\s*''''.*?if\s*\(\s*\[string\]::IsNullOrEmpty\(\$ResourceGroup\)\s*\)'
    }

    It 'no longer withholds the -ResourceGroup tip from a -SkipMetrics run' {
        $script:InvSrc | Should -Not -Match '(?s)\$RgTip\s*=\s*''''.*?if\s*\(\s*-not\s+\$SkipMetrics\.IsPresent'
    }

    # ...and not when the operator already passed it. -Service and -ResourceGroup
    # are independent parameters with no mutual exclusion, so this combination is
    # legal and must not be told to add what it already has.
    It 'does not offer -ResourceGroup when -ResourceGroup was already supplied' {
        $script:InvSrc | Should -Match '\$RgTip[\s\S]{0,400}?\[string\]::IsNullOrEmpty\(\$ResourceGroup\)'
    }

    # HONESTY GUARD, corrected. This previously asserted that -ResourceGroup does
    # NOT scope consumption, reasoning that Get-UsageAggregates is whole-subscription
    # billing with no resource-group filter. That premise is true but the conclusion
    # was not: GetResourceConsumption() applies the narrowing CLIENT-side, per usage
    # record, so consumption IS scoped.
    #
    # Measured on a live subscription, same subscription and window, only
    # -ResourceGroup differing:
    #   without -ResourceGroup : 480 consumption rows across 29 resource groups
    #   with    -ResourceGroup : 180 rows, 1 resource group - exactly that group's
    #                            180 rows from the unscoped run
    #
    # So the advisory must say consumption IS scoped. The honesty obligation does not
    # disappear, it moves: because the narrowing is per-record, a meter with no
    # resource id (marketplace purchases, reservations, tenant-level charges) cannot
    # be attributed to a resource group and is excluded. Both halves are asserted.
    It 'states that -ResourceGroup DOES scope consumption' {
        $script:InvSrc | Should -Match '(?i)\$RgTip[\s\S]{0,400}?scopes inventory, metrics AND consumption'
    }

    It 'warns that unattributed meters are excluded from a resource-group-scoped run' {
        $script:InvSrc | Should -Match '(?i)\$RgTip[\s\S]{0,700}?no resource id[\s\S]{0,200}?excluded'
    }

    It 'no longer claims consumption stays whole-subscription' {
        $script:InvSrc | Should -Not -Match '(?i)NOT consumption'
    }

    It 'no longer claims -ResourceGroup "also scopes metrics" without qualification' {
        $script:InvSrc | Should -Not -Match 'which also scopes metrics'
    }

    # BINDING GUARD: the other tests prove the lists are state-derived and the gate
    # exists but none touches the emitted string, so a hardcoded message body would pass them all yet re-ship the wrong-for-state claim. Bind the Warning to the -f interpolation of BOTH derived lists.
    It 'interpolates the derived phase and skip lists into the emitted advisory (not a hardcoded body)' {
        $script:InvSrc | Should -Match '(?s)-Service scopes the INVENTORY phase only[\s\S]*?\{0\}[\s\S]*?\{1\}[\s\S]*?-f\s*\(\$UnscopedPhases\s*-join[\s\S]{0,40}?\),\s*\(\$SuggestedSkips\s*-join'
    }
}

Describe '-Service advisory: emitted once per run, not once per subscription' {

    # Under the wrapper, ResourceInventory.ps1 is invoked via & once PER
    # SUBSCRIPTION in the same process, with -Service forwarded every time. An
    # ungated advisory therefore repeats N times on a large tenant. It is also
    # actively wrong there: it recommends -ResourceGroup, which
    # Run-AllSubscriptions.ps1 does not accept as a parameter at all.
    It 'suppresses the inner advisory under -RunAllSubs' {
        $script:InvSrc | Should -Match '@\(\$UnscopedPhases\)\.Count\s*-gt\s*0\s*-and\s*-not\s+\$RunAllSubs\.IsPresent'
    }

    # Suppressing it inner-side would LOSE the advice under the wrapper, so the
    # wrapper must carry its own once-up-front equivalent.
    It 'the wrapper emits its own once-up-front equivalent' {
        $script:WrapSrc | Should -Match '-Service scopes the INVENTORY phase only'
    }

    It 'the wrapper advisory is also per-phase accurate' {
        $script:WrapSrc | Should -Match '\$UnscopedPhases\s*=\s*@\(\)'
        $script:WrapSrc | Should -Match '@\(\$UnscopedPhases\)\.Count\s*-gt\s*0'
    }

    # BINDING GUARD (wrapper copy). Same class of regression as the inner one: the
    # wrapper derives both lists and gates on the count, but a hardcoded Write-Warning
    # body would pass the two assertions above while re-shipping the wrong-for-state
    # string. Bind the emitted text to the -f interpolation of both derived lists.
    It 'interpolates the derived phase and skip lists into the wrapper advisory (not a hardcoded body)' {
        $script:WrapSrc | Should -Match '(?s)-Service scopes the INVENTORY phase only[\s\S]*?\{0\}[\s\S]*?\{1\}[\s\S]*?-f\s*\(\$UnscopedPhases\s*-join[\s\S]{0,40}?\),\s*\(\$SuggestedSkips\s*-join'
    }

    # The wrapper has no -ResourceGroup parameter, so its copy must not suggest one.
    It 'the wrapper does not suggest -ResourceGroup' {
        $WrapperHasRgParam = $script:WrapSrc -match '(?m)^\s*\[string\]\s*\$ResourceGroup'
        $WrapperHasRgParam | Should -BeFalse -Because 'the premise of the next assertion is that the wrapper has no such parameter'
        $script:WrapSrc | Should -Not -Match 'use -ResourceGroup'
    }
}
