# Requires -Modules Pester
# =============================================================================
# UnknownParameter.Tests.ps1
#
# ResourceInventory.ps1 must stop on a parameter name it does not declare.
# Without [CmdletBinding()], a misspelled switch such as -Obfuscte is collected
# into $args and ignored, so the run goes ahead with that option off (for
# -Obfuscate: a report with real names) and exits 0.
#
# The script is run the way a user runs it (pwsh -File) from a copy in
# TestDrive whose two helper files are stand-ins. The stand-ins define
# Write-Debug, which the script calls right after it applies -Debug: the
# stand-in records the error and debug preferences the script set, then exits.
# So a run that records nothing never got past parameter binding.
#
# No live Azure. Run with:
#   Invoke-Pester ./Tests/UnknownParameter.Tests.ps1 -Output Detailed
# =============================================================================

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $script:RiSource = Join-Path $script:RepoRoot 'ResourceInventory.ps1'
    if (-not (Test-Path -LiteralPath $script:RiSource)) { throw "ResourceInventory.ps1 not found at $script:RiSource" }

    $script:Tree = Join-Path $TestDrive 'tree'
    New-Item -ItemType Directory -Path (Join-Path $script:Tree 'Functions') -Force | Out-Null
    Copy-Item -LiteralPath $script:RiSource -Destination $script:Tree
    $script:Record = Join-Path $TestDrive 'record.txt'
    $Stub = @'
function Write-Debug
{
    param($Message)
    Set-Content -LiteralPath '{0}' -Value ('ErrorActionPreference=' + $ErrorActionPreference + ';DebugPreference=' + $DebugPreference)
    exit 0
}
'@.Replace('{0}', $script:Record.Replace("'", "''"))
    Set-Content -LiteralPath (Join-Path $script:Tree 'Functions/ResourceInventory.Functions.ps1') -Value $Stub
    Set-Content -LiteralPath (Join-Path $script:Tree 'Functions/Common.Functions.ps1') -Value '# stand-in'

    function script:Invoke-Inventory
    {
        param([string[]]$Arguments)
        Remove-Item -LiteralPath $script:Record -ErrorAction SilentlyContinue
        $Output = & pwsh -NoProfile -NonInteractive -File (Join-Path $script:Tree 'ResourceInventory.ps1') -RunAllSubs -OutputDirectory $TestDrive @Arguments 2>&1 | Out-String
        [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output   = $Output
            Record   = if (Test-Path -LiteralPath $script:Record) { (Get-Content -LiteralPath $script:Record -Raw).Trim() } else { $null }
        }
    }
}

Describe 'ResourceInventory.ps1 parameter binding' {

    It 'stops on a misspelled switch before any work, naming it, with exit 1' {
        $Run = Invoke-Inventory -Arguments @('-Obfuscte')
        $Run.Record | Should -BeNullOrEmpty -Because 'the script body must not start'
        $Run.Output | Should -Match "parameter name 'Obfuscte'"
        $Run.ExitCode | Should -Be 1
    }

    It 'stops on an unknown parameter that carries a value' {
        $Run = Invoke-Inventory -Arguments @('-ReportDir', 'somewhere')
        $Run.Record | Should -BeNullOrEmpty
        $Run.Output | Should -Match "parameter name 'ReportDir'"
        $Run.ExitCode | Should -Be 1
    }

    It 'runs quietly without -Debug' {
        (Invoke-Inventory -Arguments @()).Record | Should -Be 'ErrorActionPreference=SilentlyContinue;DebugPreference=SilentlyContinue'
    }

    It 'turns on debug mode with -Debug' {
        (Invoke-Inventory -Arguments @('-Debug')).Record | Should -Be 'ErrorActionPreference=Continue;DebugPreference=Continue'
    }

    It 'keeps debug mode off with -Debug:$false' {
        (Invoke-Inventory -Arguments @('-Debug:$false')).Record | Should -Be 'ErrorActionPreference=SilentlyContinue;DebugPreference=SilentlyContinue'
    }
}

Describe 'Wrapper forwarding' {

    # Run-AllSubscriptions.ps1 and Run-AllSubscriptions.Stream.ps1 call
    # ResourceInventory.ps1 for every subscription. A name they pass that the
    # script does not declare would now fail every subscription.
    It '<Wrapper> passes only parameters that ResourceInventory.ps1 declares' -ForEach @(
        @{ Wrapper = 'Run-AllSubscriptions.ps1' }
        @{ Wrapper = 'Run-AllSubscriptions.Stream.ps1' }
    ) {
        $Declared = @((Get-Command -Name $script:RiSource).Parameters.Keys)
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepoRoot $Wrapper), [ref]$null, [ref]$null)

        $Calls = @($Ast.FindAll({
                    param($Node)
                    $Node -is [System.Management.Automation.Language.CommandAst] -and $Node.CommandElements[0].Extent.Text -match 'ResourceInventory\.ps1'
                }, $true))
        $Calls.Count | Should -BeGreaterThan 0
        $Named = @($Calls | ForEach-Object { $_.CommandElements } | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } | ForEach-Object { $_.ParameterName })

        $Splatted = @($Ast.FindAll({
                    param($Node)
                    $Node -is [System.Management.Automation.Language.IndexExpressionAst] -and
                    $Node.Target -is [System.Management.Automation.Language.VariableExpressionAst] -and
                    $Node.Target.VariablePath.UserPath -eq 'InventoryPassthrough' -and
                    $Node.Index -is [System.Management.Automation.Language.StringConstantExpressionAst]
                }, $true) | ForEach-Object { $_.Index.Value })
        $Splatted.Count | Should -BeGreaterThan 0

        foreach ($Name in @($Named + $Splatted | Sort-Object -Unique))
        {
            $Declared | Should -Contain $Name
        }
    }
}
