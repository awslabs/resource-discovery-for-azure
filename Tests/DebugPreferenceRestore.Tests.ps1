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
        $script:LoginText | Should -Not -Match '\$DebugPreference\s*=\s*"Continue"' -Because 'restoring to a literal overrides -Debug:$false'
    }

    It 'saves BEFORE it suppresses, so the captured value is the caller''s' {
        $SaveIdx = $script:LoginText.IndexOf('$SavedDebugPref = $DebugPreference')
        $SuppressIdx = $script:LoginText.IndexOf('$DebugPreference = "SilentlyContinue"')
        $RestoreIdx = $script:LoginText.IndexOf('$DebugPreference = $SavedDebugPref')

        $SaveIdx | Should -BeGreaterThan -1
        $SuppressIdx | Should -BeGreaterThan $SaveIdx -Because 'saving after suppressing would capture SilentlyContinue and restore that instead'
        $RestoreIdx | Should -BeGreaterThan $SuppressIdx
    }
}

Describe 'No hardcoded Continue restore survives anywhere in the script' {

    It 'has no $DebugPreference = "Continue" assignment left' {
        # The other occurrence was the LAST statement of GetResourceConsumption, so it
        # could never affect anything - dead code that read like a safeguard. Both are
        # gone; only the comment describing why remains.
        $CodeLines = @($script:InvLines | Where-Object { $_ -notmatch '^\s*#' })
        @($CodeLines | Where-Object { $_ -match '\$DebugPreference\s*=\s*"Continue"' }).Count |
            Should -Be 0 -Because 'a literal Continue anywhere re-introduces the opt-out override'
    }
}

Describe 'The save/restore round-trip honours every state the binder can produce' {

    # Pure logic over the same three-line idiom the function uses, so the invariant is
    # checked behaviourally rather than only as text.
    It 'round-trips <Label> unchanged' -ForEach @(
        @{ Label = 'SilentlyContinue (no -Debug, the production default)'; Incoming = 'SilentlyContinue' }
        @{ Label = 'Continue (-Debug passed)'; Incoming = 'Continue' }
        @{ Label = 'SilentlyContinue (-Debug:$false, an explicit opt-out)'; Incoming = 'SilentlyContinue' }
    ) {
        $DebugPreference = $Incoming

        $SavedDebugPref = $DebugPreference
        $DebugPreference = 'SilentlyContinue'
        # ... sign-in would happen here ...
        $DebugPreference | Should -Be 'SilentlyContinue' -Because 'the sign-in must be quiet regardless'
        $DebugPreference = $SavedDebugPref

        $DebugPreference | Should -Be $Incoming -Because 'the caller''s choice must survive the sign-in'
    }

    It 'the OLD idiom demonstrably broke the opt-out (regression witness)' {
        # Shows what the literal restore did, so the reason for the change is executable
        # rather than only described in a comment.
        $DebugPreference = 'SilentlyContinue'   # caller passed -Debug:$false
        $DebugPreference = 'SilentlyContinue'   # suppress
        $DebugPreference = 'Continue'           # the OLD restore: a literal
        $DebugPreference | Should -Be 'Continue' -Because 'this is the bug: an opt-out ends up with debug ON'
        $DebugPreference | Should -Not -Be 'SilentlyContinue'
    }
}

Describe 'A preference assignment inside a function does not leak to script scope' {

    It 'confirms the blast radius that made this easy to miss' {
        # Measured, not assumed. This is why the defect was bounded to the remainder of
        # LoginSession instead of corrupting the whole run - and therefore why nothing
        # downstream ever surfaced it.
        $DebugPreference = 'SilentlyContinue'
        function script:Set-PrefLocally { $DebugPreference = 'Continue'; return $DebugPreference }

        script:Set-PrefLocally | Should -Be 'Continue' -Because 'the assignment takes effect inside the function'
        $DebugPreference | Should -Be 'SilentlyContinue' -Because 'and does NOT propagate back out'
    }
}
