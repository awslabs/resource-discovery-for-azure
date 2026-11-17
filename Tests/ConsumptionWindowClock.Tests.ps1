# =============================================================================
# ConsumptionWindowClock.Tests.ps1
#
# The consumption window (Get-ConsumptionWindow in Functions/Common.Functions.ps1)
# must not depend on the host's time zone: usage days are UTC days, so the
# window is taken from the UTC date of the run's clock. The up-front
# consumption data check and the billing phase share the one window the run
# computes, so both follow.
#
# The host-zone case runs Get-ConsumptionWindow in two child pwsh processes,
# one with TZ=Pacific/Kiritimati (UTC+14) and one with TZ=Pacific/Pago_Pago
# (UTC-11). Their local dates are always one or two days apart, so a window
# taken from the local date always differs between them.
#
# Run with: Invoke-Pester ./Tests/ConsumptionWindowClock.Tests.ps1 -Output Detailed
# =============================================================================

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $script:CommonFunctions = Join-Path $script:RepoRoot 'Functions/Common.Functions.ps1'
    . $script:CommonFunctions

    # The window Get-ConsumptionWindow should give at a UTC moment.
    function Get-ExpectedText
    {
        param([datetime]$UtcNow)
        $Invariant = [System.Globalization.CultureInfo]::InvariantCulture
        '{0} to {1}' -f $UtcNow.AddDays(-31).Date.ToString('yyyy-MM-dd', $Invariant), $UtcNow.AddDays(-1).Date.ToString('yyyy-MM-dd', $Invariant)
    }

    $script:ChildScript = Join-Path $TestDrive 'window.ps1'
    Set-Content -LiteralPath $script:ChildScript -Encoding utf8 -Value @"
. '$($script:CommonFunctions.Replace("'", "''"))'
`$W = Get-ConsumptionWindow
'{0}|{1}|{2}' -f (Format-ConsumptionWindow -Window `$W), `$W.Start.Kind, [System.TimeZoneInfo]::Local.BaseUtcOffset.TotalHours
"@
    $script:Pwsh = (Get-Process -Id $PID).Path

    function Invoke-WindowInZone
    {
        param([string]$Zone)
        $Saved = $env:TZ
        try
        {
            $env:TZ = $Zone
            return [string](& $script:Pwsh -NoProfile -NonInteractive -File $script:ChildScript)
        }
        finally
        {
            if ($null -eq $Saved) { Remove-Item -Path 'Env:TZ' -ErrorAction SilentlyContinue } else { $env:TZ = $Saved }
        }
    }
}

Describe 'Get-ConsumptionWindow clock' {
    It 'takes the window from the UTC date when no clock is passed' {
        $Before = [datetime]::UtcNow
        $Text = Format-ConsumptionWindow -Window (Get-ConsumptionWindow)
        $After = [datetime]::UtcNow
        $Text | Should -BeIn @((Get-ExpectedText $Before), (Get-ExpectedText $After))
    }

    # TZ sets the time zone of a .NET process on Linux and macOS only.
    It 'gives the same window on hosts at UTC+14 and UTC-11 at the same moment' -Skip:$IsWindows {
        # Retried once if the UTC date changes while the two children run.
        foreach ($Try in 1..2)
        {
            $Before = [datetime]::UtcNow
            $East = Invoke-WindowInZone 'Pacific/Kiritimati'
            $West = Invoke-WindowInZone 'Pacific/Pago_Pago'
            $After = [datetime]::UtcNow
            if ($Before.Date -eq $After.Date) { break }
        }
        $EastParts = $East -split '\|'
        $WestParts = $West -split '\|'
        $EastParts[2] | Should -Be '14' -Because 'the child must really run at UTC+14'
        $WestParts[2] | Should -Be '-11' -Because 'the child must really run at UTC-11'
        $EastParts[0] | Should -BeExactly $WestParts[0]
        $EastParts[0] | Should -BeExactly (Get-ExpectedText $Before)
        $EastParts[1] | Should -Be 'Unspecified'
        $WestParts[1] | Should -Be 'Unspecified'
    }

    It 'still takes the window from a clock that is passed' {
        $W = Get-ConsumptionWindow -Now ([datetime]::SpecifyKind([datetime]'2026-10-28T00:55:00', 'Utc'))
        Format-ConsumptionWindow -Window $W | Should -BeExactly '2026-09-27 to 2026-10-27'
    }

    It 'is what the up-front check uses when it is given no window' {
        $Check = (Get-Command Invoke-ConsumptionDataCheck).ScriptBlock.Ast
        $Default = @($Check.FindAll({ param($N) $N -is [System.Management.Automation.Language.ParameterAst] -and $N.Name.VariablePath.UserPath -eq 'Window' }, $true))
        $Default.Count | Should -Be 1
        $Default[0].DefaultValue.Extent.Text | Should -BeExactly '(Get-ConsumptionWindow)'
    }
}
