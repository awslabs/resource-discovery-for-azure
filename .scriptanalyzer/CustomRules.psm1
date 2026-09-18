
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

    $DiagnosticType = [type]'Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord'
    if (-not $DiagnosticType)
    {
        return @()
    }

    $AllowList = @(
        '_', 'args', 'input', 'this', 'psitem', 'myinvocation',
        'psboundparameters', 'psscriptroot', 'pscommandpath', 'pscmdlet',
        'host', 'home', 'pwd', 'error', 'true', 'false', 'null',
        'i', 'j', 'k', 'x', 'y', 'z',
        '1', '2', '3'
    )

    $Results = @()

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

        if ($Name -match '^(\w+):' -and $Matches[1].ToLower() -notin @('global', 'local', 'script', 'private', 'using', 'workflow'))
        {
            continue
        }

        $ScopePrefixPattern = '^(global|local|script|private|using|workflow):'
        $NameForCasingCheck = $Name -replace $ScopePrefixPattern, ''
        $ScopePrefix        = if ($Name -match $ScopePrefixPattern) { $Matches[0] } else { '' }

        if ($AllowList -contains $NameForCasingCheck.ToLower()) { continue }
        if ($NameForCasingCheck -cmatch '^[A-Z]') { continue }

        $Suggested = $ScopePrefix + $NameForCasingCheck.Substring(0,1).ToUpper() + $NameForCasingCheck.Substring(1)
        $Message   = "Variable '`$$Name' should use PascalCase (e.g. '`$$Suggested')."

        $SeverityType = [type]'Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticSeverity'
        $Warning      = [Enum]::Parse($SeverityType, 'Warning')

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
            $null
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

