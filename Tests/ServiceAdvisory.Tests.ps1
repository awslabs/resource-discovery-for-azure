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

    # REGRESSION GUARD for the residual clause. The -ResourceGroup tip must not be
    # emitted unconditionally: its only benefit is scoping metrics, so offering it
    # to a -SkipMetrics run advertises a benefit that run cannot receive.
    It 'offers the -ResourceGroup tip only when metrics are actually still running' {
        $script:InvSrc | Should -Match '(?s)\$RgTip\s*=\s*''''.*?if\s*\(\s*-not\s+\$SkipMetrics\.IsPresent'
    }

    # ...and not when the operator already passed it. -Service and -ResourceGroup
    # are independent parameters with no mutual exclusion, so this combination is
    # legal and must not be told to add what it already has.
    It 'does not offer -ResourceGroup when -ResourceGroup was already supplied' {
        $script:InvSrc | Should -Match '\$RgTip[\s\S]{0,400}?\[string\]::IsNullOrEmpty\(\$ResourceGroup\)'
    }

    # HONESTY GUARD. -ResourceGroup narrows the Resource Graph query, so it scopes
    # inventory and metrics - but Get-UsageAggregates is whole-subscription billing
    # with no resource-group filter, so consumption is NOT scoped. The advisory
    # names consumption as part of the problem, so it must not imply -ResourceGroup
    # solves it. See docs/recovery-and-diagnostics.md.
    It 'states that -ResourceGroup does NOT scope consumption' {
        $script:InvSrc | Should -Match '(?i)\$RgTip[\s\S]{0,400}?NOT\s+consumption'
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
