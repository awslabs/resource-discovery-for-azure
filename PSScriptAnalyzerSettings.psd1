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
        'PSAvoidUsingConvertToSecureStringWithPlainText'
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
        # Parameter names must be PascalCase (built-in rule).
        # Variable PascalCase is enforced by the custom rule below.
        PSUseCorrectCasing = @{
            Enable = $true
        }

        # Custom rule — see .scriptanalyzer/CustomRules.psm1
        # Flags local variable assignments that don't start with an uppercase
        # letter. Keeps a short allow-list for common iterators and automatic
        # variables. Warning severity so it surfaces without blocking CI.
        'Measure-VariablePascalCase' = @{
            Enable = $true
        }
    }
}
