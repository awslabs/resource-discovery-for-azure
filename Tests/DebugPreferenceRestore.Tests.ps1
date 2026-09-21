#Requires -Version 7.0
<#
    DebugPreferenceRestore.Tests.ps1

    Guards the suppress/restore of $DebugPreference around the interactive sign-in in
    ResourceInventory.ps1's LoginSession.

    WHY. Az emits its own debug chatter during Connect-AzAccount, so LoginSession
    suppresses $DebugPreference across the sign-in and puts it back afterwards. The
    restore assigned the LITERAL "Continue", which meant that after the sign-in the
    remaining ~100 lines of that function ran with debug output ON even when the caller
    had passed -Debug:$false, or had not passed -Debug at all (where the preference is
    'SilentlyContinue').

    That is the same defect class as the $DebugMode assignment at the top of the script:
    an explicit opt-OUT read as an opt-IN. It was easy to miss because a preference
    assignment inside a function is FUNCTION-SCOPED and never leaked to script scope, so
    the damage was bounded to the rest of LoginSession and nothing downstream misbehaved.

    These tests are OFFLINE. They assert the source shape (a saved value exists and is
    what gets restored) and then evaluate the save/restore round-trip as pure logic
    against the three states the binder can produce. No Azure, no sign-in.
#>

BeforeAll {
    $script:InvPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'ResourceInventory.ps1'
    $script:InvSrc = Get-Content -LiteralPath $script:InvPath -Raw
    $script:InvLines = Get-Content -LiteralPath $script:InvPath

    $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:InvPath, [ref]$null, [ref]$null)
    $script:LoginFn = $script:Ast.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'LoginSession'
        }, $true) | Select-Object -First 1

    if ($null -eq $script:LoginFn)
    {
        throw 'Could not locate LoginSession in ResourceInventory.ps1; this test cannot verify what it cannot find.'
    }
    $script:LoginText = $script:LoginFn.Extent.Text
}

Describe 'LoginSession restores the caller''s $DebugPreference, not a literal' {

    It 'saves the incoming preference before suppressing it' {
        $script:LoginText | Should -Match '\$SavedDebugPref\s*=\s*\$DebugPreference' -Because 'you cannot restore what you did not capture'
    }

    It 'suppresses during the sign-in' {
        $script:LoginText | Should -Match '\$DebugPreference\s*=\s*"SilentlyContinue"'
    }

    It 'restores the SAVED value and never a hardcoded Continue' {
        # THE regression. A literal here forces debug on for a caller who opted out.
        $script:LoginText | Should -Match '\$DebugPreference\s*=\s*\$SavedDebugPref'
        $script:LoginText | Should -Not -Match '\$DebugPreference\s*=\s*[''"]Continue[''"]' -Because 'restoring to a literal (single OR double quoted) overrides -Debug:$false'
    }

    It 'saves BEFORE it suppresses, so the captured value is the caller''s' {
        # Use regex matches (not literal IndexOf) to locate each statement, so a
        # harmless reformatting of spacing/quotes in the source cannot make an
        # IndexOf return -1 and fail this ordering check while the shape checks
        # above (which use \s* regexes) still pass - the two must agree.
        $SaveMatch = [regex]::Match($script:LoginText, '\$SavedDebugPref\s*=\s*\$DebugPreference')
        $SuppressMatch = [regex]::Match($script:LoginText, '\$DebugPreference\s*=\s*"SilentlyContinue"')
        $RestoreMatch = [regex]::Match($script:LoginText, '\$DebugPreference\s*=\s*\$SavedDebugPref')

        $SaveMatch.Success | Should -BeTrue
        $SuppressMatch.Success | Should -BeTrue
        $RestoreMatch.Success | Should -BeTrue

        $SuppressMatch.Index | Should -BeGreaterThan $SaveMatch.Index -Because 'saving after suppressing would capture SilentlyContinue and restore that instead'
        $RestoreMatch.Index | Should -BeGreaterThan $SuppressMatch.Index
    }
}

Describe 'No hardcoded Continue restore survives anywhere in the script' {

    It 'has no hardcoded $DebugPreference = Continue assignment left (single or double quoted)' {
        # The other occurrence was the LAST statement of GetResourceConsumption, so it
        # could never affect anything - dead code that read like a safeguard. Both are
        # gone; only the comment describing why remains.
        $CodeLines = @($script:InvLines | Where-Object { $_ -notmatch '^\s*#' })
        @($CodeLines | Where-Object { $_ -match '\$DebugPreference\s*=\s*[''"]Continue[''"]' }).Count |
            Should -Be 0 -Because 'a literal Continue anywhere (single or double quoted) re-introduces the opt-out override'
    }
}

Describe 'The save/restore round-trip honours every preference value the binder can produce' {

    # Illustrates, over the same three-line idiom the function uses, WHY the source shape
    # asserted in the first two Describes is the correct one. On its own the round-trip is
    # pure logic that would pass regardless of ResourceInventory.ps1, so each case FIRST
    # couples to the code under test: it asserts the LIVE source restores the saved value and
    # never a literal, so a regression in LoginSession fails here too, not only in Describe 1.
    #
    # NOTE: the -Debug binder produces only TWO distinct $DebugPreference VALUES -
    # 'Continue' (-Debug) and 'SilentlyContinue' (no -Debug and -Debug:$false both). The
    # three cases below enumerate the three binder INPUTS on purpose (the -Debug:$false
    # opt-out is the one that regressed), even though two of them share the same value.
    It 'round-trips <Label> unchanged' -ForEach @(
        @{ Label = 'SilentlyContinue (no -Debug, the production default)'; Incoming = 'SilentlyContinue' }
        @{ Label = 'Continue (-Debug passed)'; Incoming = 'Continue' }
        @{ Label = 'SilentlyContinue (-Debug:$false, an explicit opt-out)'; Incoming = 'SilentlyContinue' }
    ) {
        # Couple to the code under test - without this the round-trip below is pure logic.
        $script:LoginText | Should -Match '\$DebugPreference\s*=\s*\$SavedDebugPref' -Because 'the round-trip only reflects LoginSession if the source restores the saved value'
        $script:LoginText | Should -Not -Match '\$DebugPreference\s*=\s*[''"]Continue[''"]' -Because 'a literal restore (single or double quoted) would break the opt-out'

        $DebugPreference = $Incoming

        $SavedDebugPref = $DebugPreference
        $DebugPreference = 'SilentlyContinue'
        # ... sign-in would happen here ...
        $DebugPreference | Should -Be 'SilentlyContinue' -Because 'the sign-in must be quiet regardless'
        $DebugPreference = $SavedDebugPref

        $DebugPreference | Should -Be $Incoming -Because 'the caller''s choice must survive the sign-in'
    }

    It 'the OLD idiom demonstrably broke the opt-out (regression witness)' {
        # Illustrates what the literal restore did, so the reason for the change is executable
        # rather than only described in a comment. Coupled to the code under test: the live
        # source must NOT contain that literal restore any more.
        $script:LoginText | Should -Not -Match '\$DebugPreference\s*=\s*[''"]Continue[''"]' -Because 'the literal restore is the bug and must be gone from LoginSession'

        $DebugPreference = 'SilentlyContinue'   # caller passed -Debug:$false
        $DebugPreference = 'SilentlyContinue'   # suppress
        $DebugPreference = 'Continue'           # the OLD restore: a literal
        $DebugPreference | Should -Be 'Continue' -Because 'this is the bug: an opt-out ends up with debug ON'
        $DebugPreference | Should -Not -Be 'SilentlyContinue'
    }
}

Describe 'A preference assignment inside a function does not leak to script scope' {

    It 'confirms the blast radius that made this easy to miss' {
        # The local-function demonstration below documents the LANGUAGE invariant - a
        # function-scoped preference assignment does not leak to script scope. To couple the
        # blast-radius claim to THIS repo, first assert LoginSession's suppress and restore
        # actually live inside the function's extent ($script:LoginText is that extent only);
        # were they moved to script scope the blast radius would widen and these Matches fail.
        $script:LoginText | Should -Match '\$DebugPreference\s*=\s*"SilentlyContinue"' -Because 'the suppression is scoped inside LoginSession'
        $script:LoginText | Should -Match '\$DebugPreference\s*=\s*\$SavedDebugPref' -Because 'the restore is scoped inside LoginSession'

        $DebugPreference = 'SilentlyContinue'
        function script:Set-PrefLocally { $DebugPreference = 'Continue'; return $DebugPreference }

        script:Set-PrefLocally | Should -Be 'Continue' -Because 'the assignment takes effect inside the function'
        $DebugPreference | Should -Be 'SilentlyContinue' -Because 'and does NOT propagate back out'
    }
}
