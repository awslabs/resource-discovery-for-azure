# Custom PSScriptAnalyzer rules for Resource Discovery for Azure (referenced from ../PSScriptAnalyzerSettings.psd1); exported Measure-* functions are discovered as rules, run per ScriptBlockAst.
# ScriptAnalyzer types are resolved by fully-qualified name at RUNTIME, not `using namespace`, because the assembly is not resolvable when this module is parsed.

<#
.SYNOPSIS
    Flags variable assignments that do not start with an uppercase letter.

.DESCRIPTION
    The repo standard is PascalCase for variable names. This rule walks every
    assignment statement and emits a diagnostic when the variable on the left
    starts with a lowercase letter, skipping PowerShell automatic variables
    and an allow-list of short loop iterators.

    Hashtable keys, parameter defaults, and pipeline variables ($_) are not
    reported here — only explicit `$foo = ...` assignments.
#>
function Measure-VariablePascalCase
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [System.Management.Automation.Language.ScriptBlockAst]$ScriptBlockAst
    )

    # Resolve the DiagnosticRecord type at call time — it's owned by
    # PSScriptAnalyzer.dll, which is loaded before the rule runs.
    $DiagnosticType = [type]'Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord'
    if (-not $DiagnosticType)
    {
        # If PSScriptAnalyzer isn't loaded, silently skip.
        return @()
    }

    # Automatic variables and common iterators we never want to flag.
    $AllowList = @(
        '_', 'args', 'input', 'this', 'psitem', 'myinvocation',
        'psboundparameters', 'psscriptroot', 'pscommandpath', 'pscmdlet',
        'host', 'home', 'pwd', 'error', 'true', 'false', 'null',
        'i', 'j', 'k', 'x', 'y', 'z',
        # The repo uses $1 pervasively as the foreach iterator; allow it so
        # this rule doesn't explode on legacy collectors. New code should
        # prefer a descriptive name.
        '1', '2', '3'
    )

    $Results = @()

    # Do not recurse into nested script blocks: PSScriptAnalyzer invokes the
    # rule once per ScriptBlockAst, so recursing here double-counts anything
    # inside if/foreach bodies.
    $Assignments = $ScriptBlockAst.FindAll(
        {
            param($Ast)
            $Ast -is [System.Management.Automation.Language.AssignmentStatementAst]
        },
        $false
    )

    foreach ($Assignment in $Assignments)
    {
        $Left = $Assignment.Left

        # Unwrap `[type]$Var = ...` convert expressions.
        if ($Left -is [System.Management.Automation.Language.ConvertExpressionAst])
        {
            $Left = $Left.Child
        }

        if ($Left -isnot [System.Management.Automation.Language.VariableExpressionAst])
        {
            continue
        }

        $Name = $Left.VariablePath.UserPath

        if ([string]::IsNullOrEmpty($Name)) { continue }

        # Skip provider/drive-qualified variables ($env:, $variable:, $function:, ...):
        # their casing is provider-defined so PascalCase does not apply. Real scope modifiers (global:/script:/etc.) are handled by the scope-prefix strip below.
        if ($Name -match '^(\w+):' -and $Matches[1].ToLower() -notin @('global', 'local', 'script', 'private', 'using', 'workflow'))
        {
            continue
        }

        # UserPath carries a lowercase scope prefix (e.g. "script:Foo") that would always
        # fail the uppercase-start check, so strip it for the casing check/allow-list/suggestion but keep the original $Name (with prefix) for the diagnostic message.
        $ScopePrefixPattern = '^(global|local|script|private|using|workflow):'
        $NameForCasingCheck = $Name -replace $ScopePrefixPattern, ''
        $ScopePrefix        = if ($Name -match $ScopePrefixPattern) { $Matches[0] } else { '' }

        if ($AllowList -contains $NameForCasingCheck.ToLower()) { continue }
        # Case-sensitive regex: `-match` is case-insensitive by default in
        # PowerShell, which would accept lowercase names. `-cmatch` forces
        # case-sensitive matching so only real PascalCase passes through.
        if ($NameForCasingCheck -cmatch '^[A-Z]') { continue }

        $Suggested = $ScopePrefix + $NameForCasingCheck.Substring(0,1).ToUpper() + $NameForCasingCheck.Substring(1)
        $Message   = "Variable '`$$Name' should use PascalCase (e.g. '`$$Suggested')."

        # Construct via reflection-friendly form so we don't depend on the
        # type literal being resolvable at parse time.
        $SeverityType = [type]'Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticSeverity'
        $Warning      = [Enum]::Parse($SeverityType, 'Warning')

        # Attach a SuggestedCorrection for -Fix. Safe because PowerShell variable resolution
        # is case-insensitive: re-casing only the assignment-site token does not change references. Attach it only for the plain `$foo` form; a brace-quoted `${foo bar}` would yield invalid syntax under -Fix, so it gets the diagnostic but no correction.
        $Corrections = $null
        if (-not $Left.Extent.Text.StartsWith('${'))
        {
            $CorrectionType = [type]'Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.CorrectionExtent'
            $Correction     = $CorrectionType::new(
                $Left.Extent,
                ('$' + $Suggested),
                $Left.Extent.File,
                $Message
            )
            $CorrectionListType = [System.Collections.Generic.List`1].MakeGenericType($CorrectionType)
            $Corrections        = $CorrectionListType::new()
            $Corrections.Add($Correction)
        }

        $Record = $DiagnosticType::new(
            $Message,
            $Left.Extent,
            'Measure-VariablePascalCase',
            $Warning,
            $null  # scriptName filled in by PSScriptAnalyzer
        )
        if ($null -ne $Corrections)
        {
            $Record.SuggestedCorrections = $Corrections
        }
        $Results += $Record
    }

    return $Results
}

Export-ModuleMember -Function 'Measure-*'
