@{
    # PSScriptAnalyzer settings for Resource Discovery for Azure.
    # Keep in sync with .kiro/steering/powershell-style.md.
    #
    # Run locally:
    #   Invoke-ScriptAnalyzer -Path <file-or-folder> -Settings ./PSScriptAnalyzerSettings.psd1 -Recurse

    IncludeDefaultRules = $true

    # Custom rules live alongside this file.
    CustomRulePath   = @('./.scriptanalyzer/CustomRules.psm1')
    IncludeRules     = @('*')

    # Most of the repo predates these rules; excluding here keeps the signal
    # on new code. Remove entries as older files are cleaned up.
    ExcludeRules = @(
        # Pre-existing in ResourceInventory.ps1 for Service Principal auth.
        # TODO: replace with an encrypted credential store and re-enable.
        'PSAvoidUsingConvertToSecureStringWithPlainText',

        # Upstream PSScriptAnalyzer bug: this formatting rule throws a
        # NullReferenceException ("Object reference not set to an instance of an
        # object") while analyzing ResourceInventory.ps1 and Functions/*, which
        # aborts the entire -Recurse run (not just that file). The repo never
        # opted into this rule via the Rules block below — it only ran because
        # IncludeRules = @('*'). Our hashtable/assignment layouts are valid
        # PowerShell; the null-ref is inside the rule's own alignment logic, so
        # excluding the broken rule is the correct fix rather than reshaping
        # valid code to work around it.
        'PSAlignAssignmentStatement',

        # Upstream PSScriptAnalyzer bug: this cosmetic cmdlet-casing rule throws
        # a NullReferenceException inside its own AnalyzeScript ->
        # CommandInfo.get_Parameters() path when it tries to resolve the
        # parameter metadata of a command it cannot fully load (ResourceInventory.ps1
        # is dense with Az cmdlets; CI runs with no Az modules installed, which
        # makes the null-ref more likely). The exception is thrown on a worker
        # thread and aborts the whole analyzer process — it is NOT catchable via
        # -ErrorAction. Captured stack trace:
        #   System.NullReferenceException
        #     at CommandInfo.get_Parameters()
        #     at BuiltinRules.UseCorrectCasing.AnalyzeScript(...)
        # It only enforces cosmetic casing of cmdlet/keyword names, so excluding
        # it costs no correctness/security coverage. (The Rules block below no
        # longer enables it — see the note there.)
        'PSUseCorrectCasing'
    )

    Severity = @('Error', 'Warning', 'Information')

    Rules = @{

        # ---- Brace style --------------------------------------------------
        # Allman (BSD) style: opening brace on its own line so function /
        # block signatures stay visible when the body is folded.
        PSPlaceOpenBrace = @{
            Enable             = $true
            OnSameLine         = $false   # => brace on its own line
            NewLineAfter       = $true
            IgnoreOneLineBlock = $true    # leave `Where-Object { ... }` alone
        }

        PSPlaceCloseBrace = @{
            Enable             = $true
            NewLineAfter       = $true
            IgnoreOneLineBlock = $true
            NoEmptyLineBefore  = $false
        }

        # ---- Indentation --------------------------------------------------
        PSUseConsistentIndentation = @{
            Enable              = $true
            Kind                = 'space'
            IndentationSize     = 4
            PipelineIndentation = 'IncreaseIndentationForFirstPipeline'
        }

        PSUseConsistentWhitespace = @{
            Enable                                  = $true
            CheckInnerBrace                         = $true
            CheckOpenBrace                          = $true
            CheckOpenParen                          = $true
            CheckOperator                           = $true
            CheckPipe                               = $true
            CheckPipeForRedundantWhitespace         = $false
            CheckSeparator                          = $true
            CheckParameter                          = $false
            IgnoreAssignmentOperatorInsideHashTable = $true
        }

        # ---- Naming -------------------------------------------------------
        # Variable PascalCase is enforced by the custom rule below.
        #
        # NOTE: PSUseCorrectCasing (cmdlet/keyword casing) is intentionally
        # NOT enabled here — it is listed in ExcludeRules above because it
        # throws a process-aborting NullReferenceException on this repo's
        # Az-cmdlet-heavy files (see the ExcludeRules comment for the captured
        # stack trace). It only enforced cosmetic cmdlet casing, so nothing of
        # substance is lost. Re-enable if/when the upstream PSSA bug is fixed.

        # Custom rule — see .scriptanalyzer/CustomRules.psm1
        # Flags local variable assignments that don't start with an uppercase
        # letter. Keeps a short allow-list for common iterators and automatic
        # variables. Warning severity so it surfaces without blocking CI.
        'Measure-VariablePascalCase' = @{
            Enable = $true
        }
    }
}
