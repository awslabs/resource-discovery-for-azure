# =============================================================================
# DirectRunEnabledSubscriptions.Tests.ps1
#
# WHY THIS TEST EXISTS
# --------------------
# A direct run of ResourceInventory.ps1 without -SubscriptionID collects every
# subscription the sign-in lists. It used to list them with `az account list`,
# which by default lists only Enabled subscriptions. Get-AzSubscription lists
# every state, so a Disabled or Warned subscription was collected too. The run
# keeps only Enabled ones, as before; -SubscriptionID still collects the one it
# names, whatever its state (the wrapper's -IncludeDisabled relies on that).
#
# Set-RdaRunSubscriptions is lifted from ResourceInventory.ps1; the listing
# and the stop are stand-ins. No live Azure.
# =============================================================================

BeforeAll {
    $Root = Split-Path $PSScriptRoot -Parent
    $Ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Root 'ResourceInventory.ps1'), [ref]$null, [ref]$null)
    $Fn = @($Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq 'Set-RdaRunSubscriptions' }, $true))
    if ($Fn.Count -ne 1) { throw 'Set-RdaRunSubscriptions was not found in ResourceInventory.ps1.' }
    $script:FnText = $Fn[0].Extent.Text

    function Get-RdaTenantSubscriptions
    {
        param([string]$Tenant)
        [pscustomobject]@{ id = 'sub-on'; name = 'On'; tenantId = $Tenant; homeTenantId = $Tenant; state = 'Enabled' }
        [pscustomobject]@{ id = 'sub-off'; name = 'Off'; tenantId = $Tenant; homeTenantId = $Tenant; state = 'Disabled' }
        [pscustomobject]@{ id = 'sub-warn'; name = 'Warn'; tenantId = $Tenant; homeTenantId = $Tenant; state = 'Warned' }
    }
    function Stop-SignIn { param([string]$Message, [string]$Advice) throw ('STOP: ' + $Message + ' ADVICE: ' + $Advice) }

    function script:Invoke-Set
    {
        param([string]$SubscriptionID, [object[]]$Listed)
        if ($null -ne $Listed) { $script:Listed = $Listed; function Get-RdaTenantSubscriptions { param([string]$Tenant) $script:Listed } }
        . ([scriptblock]::Create($script:FnText))
        Set-RdaRunSubscriptions -Tenant 'tenant-1'
        return @($Global:Subscriptions)
    }
}

AfterAll {
    Remove-Variable -Name Subscriptions -Scope Global -ErrorAction SilentlyContinue
}

Describe 'A direct run lists the subscriptions it collects' {
    It 'keeps only the Enabled subscriptions without -SubscriptionID, as az account list did' {
        $SubscriptionID = $null
        $Subs = Invoke-Set -SubscriptionID $SubscriptionID
        @($Subs | ForEach-Object { $_.id }) | Should -Be @('sub-on')
    }

    It 'keeps every listed subscription with -SubscriptionID, so a named one that is not Enabled is still found' {
        $SubscriptionID = 'sub-off'
        $Subs = Invoke-Set -SubscriptionID $SubscriptionID
        @($Subs | ForEach-Object { $_.id }) | Should -Be @('sub-on', 'sub-off', 'sub-warn')
    }

    It 'stops without -SubscriptionID when no listed subscription is Enabled, and says how to collect one' {
        $SubscriptionID = $null
        $Off = [pscustomobject]@{ id = 'sub-off'; name = 'Off'; tenantId = 'tenant-1'; homeTenantId = 'tenant-1'; state = 'Disabled' }
        $Err = $null
        try { Invoke-Set -SubscriptionID $SubscriptionID -Listed @($Off) | Out-Null } catch { $Err = $_.Exception.Message }
        $Err | Should -BeLike '*no Enabled subscription*ADVICE:*To collect a subscription that is not Enabled, pass -SubscriptionID.*'
        $Err | Should -Not -BeLike '*ADVICE:*Reader*' -Because 'the tenant listed a subscription, so access is not the problem'
    }

    It 'stops without -SubscriptionID when nothing is listed, without the hint to pass -SubscriptionID' {
        $SubscriptionID = $null
        $Err = $null
        try { Invoke-Set -SubscriptionID $SubscriptionID -Listed @() | Out-Null } catch { $Err = $_.Exception.Message }
        $Err | Should -BeLike '*lists no subscriptions*'
        $Err | Should -Not -BeLike '*pass -SubscriptionID*'
    }

    It 'stops with -SubscriptionID when the sign-in does not list that subscription' {
        $SubscriptionID = 'sub-missing'
        { Invoke-Set -SubscriptionID $SubscriptionID } | Should -Throw '*does not list subscription sub-missing*'
    }

    It 'finds the -SubscriptionID subscription whatever the case of its id' {
        $SubscriptionID = 'SUB-WARN'
        $Subs = Invoke-Set -SubscriptionID $SubscriptionID
        @($Subs).Count | Should -Be 3
    }

    It 'stops with -SubscriptionID when nothing is listed, without the hint to pass -SubscriptionID' {
        $SubscriptionID = 'sub-off'
        $Err = $null
        try { Invoke-Set -SubscriptionID $SubscriptionID -Listed @() | Out-Null } catch { $Err = $_.Exception.Message }
        $Err | Should -BeLike '*lists no subscriptions*'
        $Err | Should -Not -BeLike '*pass -SubscriptionID*'
    }
}

Describe 'A direct run with wrong arguments' {
    BeforeAll {
        $Root = Split-Path $PSScriptRoot -Parent
        $script:RiAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Root 'ResourceInventory.ps1'), [ref]$null, [ref]$null)

        # Runs the one if statement whose body holds $Text in a child pwsh,
        # after $Setup, with $Swap's text swapped in; Write-Log prints its message.
        function script:Invoke-Check
        {
            param([string]$Text, [string]$Setup, [hashtable]$Swap = @{})
            $Check = @($script:RiAst.FindAll({ param($N) $N -is [System.Management.Automation.Language.IfStatementAst] -and $N.Clauses.Count -eq 1 -and $N.Clauses[0].Item2.Extent.Text -like "*$Text*" -and $N.Clauses[0].Item2.Extent.Text -notlike '*if (*' }, $true))
            $Check.Count | Should -Be 1
            $Body = $Check[0].Extent.Text
            foreach ($Key in $Swap.Keys) { $Body.Contains($Key) | Should -BeTrue; $Body = $Body.Replace($Key, $Swap[$Key]) }
            $Script = Join-Path $TestDrive 'check.ps1'
            Set-Content -LiteralPath $Script -Value ("function Write-Log { param([string]`$Message, [string]`$Severity) Write-Output `$Message }`n" + $Setup + "`n" + $Body + "`n'NOT STOPPED'")
            $Pwsh = (Get-Process -Id $PID).Path
            $Out = @(& $Pwsh -NoProfile -NonInteractive -File $Script)
            return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $Out }
        }
    }

    It 'stops with exit 1 for -ResourceGroup without -SubscriptionID, before sign-in' {
        $Run = Invoke-Check -Text 'must also put SubscriptionId' -Setup "`$ResourceGroup = 'rg-1'`n`$SubscriptionID = `$null"
        $Run.ExitCode | Should -Be 1
        $Run.Output | Should -Contain 'Resource Group Name present, but missing Subscription ID.'
        $Run.Output | Should -Not -Contain 'NOT STOPPED'

        $Setup = @($script:RiAst.FindAll({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq 'RunInventorySetup' }, $true))[0].Extent.Text
        $Setup.IndexOf('must also put SubscriptionId') | Should -BeGreaterThan -1
        $Setup.IndexOf('must also put SubscriptionId') | Should -BeLessThan $Setup.IndexOf("`n            LoginSession")
    }

    It 'goes on for -ResourceGroup with -SubscriptionID' {
        $Run = Invoke-Check -Text 'must also put SubscriptionId' -Setup "`$ResourceGroup = 'rg-1'`n`$SubscriptionID = 'sub-1'"
        $Run.ExitCode | Should -Be 0
        $Run.Output | Should -Contain 'NOT STOPPED'
    }

    It 'stops with exit 1 for an -OutputDirectory that cannot be made' {
        # A direct run makes a missing output folder before this check, so
        # there the check fails only for a folder that cannot be made: here
        # one under a file.
        $File = Join-Path $TestDrive 'a-file'
        Set-Content -LiteralPath $File -Value 'x'
        $Run = Invoke-Check -Text 'Wrong OutputDirectory Path' -Setup ("`$OutputDirectory = '{0}'" -f (Join-Path $File 'out'))
        $Run.ExitCode | Should -Be 1
        $Run.Output | Should -Contain 'Wrong OutputDirectory Path! OutputDirectory Parameter must contain the full path.'
        $Run.Output | Should -Not -Contain 'NOT STOPPED'
    }

    It 'requires PowerShell 7, and stops with exit 1 before it (<Platform> <Version>)' -ForEach @(
        @{ Platform = 'Unix'; Version = '6.2'; Stops = $true }
        @{ Platform = 'Win32NT'; Version = '5.1'; Stops = $true }
        @{ Platform = 'Unix'; Version = '7.4'; Stops = $false }
    ) {
        # The whole CheckPowerShell runs; $PSVersionTable cannot be set, so it
        # reads stand-ins, and no Cloud Shell drive is found.
        $Fn = @($script:RiAst.FindAll({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq 'CheckPowerShell' }, $true))
        $Fn.Count | Should -Be 1
        $Body = $Fn[0].Extent.Text.Replace('$PSVersionTable.PSVersion.Major', '$FakeVersion.Major').Replace('$PSVersionTable.Platform', '$FakePlatform')
        $Body | Should -Not -Match '\$PSVersionTable'
        $Script = Join-Path $TestDrive 'ps.ps1'
        Set-Content -LiteralPath $Script -Value ("function Write-Log { param([string]`$Message, [string]`$Severity) Write-Output `$Message }`nfunction Get-CloudDrive { throw 'no drive' }`n`$Global:RdaSessionInitialized = `$false`n`$FakeVersion = [version]'$Version'`n`$FakePlatform = '$Platform'`n" + $Body + "`ntry { CheckPowerShell } catch { }`n'NOT STOPPED'")
        $Pwsh = (Get-Process -Id $PID).Path
        $Out = @(& $Pwsh -NoProfile -NonInteractive -File $Script)
        if ($Stops)
        {
            $LASTEXITCODE | Should -Be 1
            $Out | Should -Contain 'You must use Powershell 7 to run the inventory script.'
            $Out | Should -Not -Contain 'NOT STOPPED'
        }
        else
        {
            $Out | Should -Not -Contain 'You must use Powershell 7 to run the inventory script.'
            $Out | Should -Contain 'NOT STOPPED'
        }
    }
}
