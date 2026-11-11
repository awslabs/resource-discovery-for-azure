# =============================================================================
# DirectRunEnabledSubscriptions.Tests.ps1
#
# WHY THIS TEST EXISTS
# --------------------
# A direct run of ResourceInventory.ps1 without -SubscriptionID collects the
# subscriptions the sign-in lists. It used to list them with `az account list`,
# which by default lists only Enabled subscriptions. Get-AzSubscription lists
# every state, so a Disabled or Warned subscription was collected too. The run
# now keeps only the Enabled ones of that list, as before. A direct run with
# -SubscriptionID still collects the one it names, whatever its state;
# -IncludeDisabled runs go through the -RunAllSubs path, which keeps every
# state.
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
        $Err | Should -BeLike '*no Enabled subscription*ADVICE:*To collect a subscription that is not Enabled, pass -SubscriptionID; or pass -TenantID for a tenant with Enabled subscriptions.*'
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
        $Run = Invoke-Check -Text 'Pass -SubscriptionID when you use -ResourceGroup.' -Setup "`$ResourceGroup = 'rg-1'`n`$SubscriptionID = `$null"
        $Run.ExitCode | Should -Be 1
        $Run.Output | Should -Contain '-ResourceGroup was given without -SubscriptionID.'
        $Run.Output | Should -Not -Contain 'NOT STOPPED'

        $Setup = @($script:RiAst.FindAll({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq 'RunInventorySetup' }, $true))[0].Extent.Text
        $Setup.IndexOf('Pass -SubscriptionID when you use -ResourceGroup.') | Should -BeGreaterThan -1
        $Setup.IndexOf('Pass -SubscriptionID when you use -ResourceGroup.') | Should -BeLessThan $Setup.IndexOf("`n            LoginSession")
    }

    It 'goes on for -ResourceGroup with -SubscriptionID' {
        $Run = Invoke-Check -Text 'Pass -SubscriptionID when you use -ResourceGroup.' -Setup "`$ResourceGroup = 'rg-1'`n`$SubscriptionID = 'sub-1'"
        $Run.ExitCode | Should -Be 0
        $Run.Output | Should -Contain 'NOT STOPPED'
    }

    It 'stops with exit 1 for an -OutputDirectory that cannot be made' {
        # The check alone, as a fallback: a direct run's pre-flight makes the
        # output folder first and stops if it cannot write there, so this
        # check is reached with a bad folder only if that changes or races.
        # The folder here is under a file, so it cannot be found or made.
        $File = Join-Path $TestDrive 'a-file'
        Set-Content -LiteralPath $File -Value 'x'
        $Run = Invoke-Check -Text 'could not be found or made' -Setup ("`$OutputDirectory = '{0}'" -f (Join-Path $File 'out'))
        $Run.ExitCode | Should -Be 1
        $Run.Output | Should -Contain ('The output directory {0} could not be found or made. Pass -OutputDirectory as the full path of a folder you can write to.' -f (Join-Path $File 'out'))
        $Run.Output | Should -Not -Contain 'NOT STOPPED'
    }

    It 'checks PowerShell 7 first, before any other statement of the script' {
        $First = $script:RiAst.EndBlock.Statements[0]
        $First | Should -BeOfType ([System.Management.Automation.Language.IfStatementAst])
        $First.Extent.Text | Should -BeLike '*$PSVersionTable.PSVersion.Major -lt 7*You must use PowerShell 7*exit 1*'
    }

    It 'requires PowerShell 7, and stops with exit 1 before it (<Version>)' -ForEach @(
        @{ Version = '6.2'; Stops = $true }
        @{ Version = '5.1'; Stops = $true }
        @{ Version = '7.4'; Stops = $false }
    ) {
        # $PSVersionTable cannot be set, so the check reads a stand-in.
        $Body = $script:RiAst.EndBlock.Statements[0].Extent.Text
        $Body.Contains('$PSVersionTable.PSVersion.Major') | Should -BeTrue
        $Body = $Body.Replace('$PSVersionTable.PSVersion.Major', '$FakeVersion.Major')
        $Script = Join-Path $TestDrive 'ps.ps1'
        Set-Content -LiteralPath $Script -Value ("`$FakeVersion = [version]'$Version'`n" + $Body + "`n'NOT STOPPED'")
        $Pwsh = (Get-Process -Id $PID).Path
        $Out = @(& $Pwsh -NoProfile -NonInteractive -File $Script 6>&1 | ForEach-Object { [string]$_ })
        if ($Stops)
        {
            $LASTEXITCODE | Should -Be 1
            $Out | Should -Contain 'You must use PowerShell 7 to run the inventory script.'
            $Out | Should -Not -Contain 'NOT STOPPED'
        }
        else
        {
            $Out | Should -Not -Contain 'You must use PowerShell 7 to run the inventory script.'
            $Out | Should -Contain 'NOT STOPPED'
        }
    }
}

Describe 'A -ResourceGroup run on a Turkish host' {
    It 'queries the group by its invariant lower-case name (<Culture>)' -ForEach @(
        @{ Culture = 'en-US' }
        @{ Culture = 'tr-TR' }
    ) {
        $Root = Split-Path $PSScriptRoot -Parent
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Root 'ResourceInventory.ps1'), [ref]$null, [ref]$null)
        $Fn = @($Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq 'ResourceInventoryLoop' }, $true))
        $Fn.Count | Should -Be 1
        # The loop runs with stand-ins that print each query; the group has no
        # resource, so only the count query runs. Any other command the loop
        # calls (a helper another change adds) is a no-op, so the loop runs on.
        # (CommandNotFoundAction is read by the child's own engine, so it is
        # set there.)
        $Script = Join-Path $TestDrive 'rg-culture.ps1'
        Set-Content -LiteralPath $Script -Value ((@'
[System.Globalization.CultureInfo]::CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('{0}')
$ExecutionContext.InvokeCommand.CommandNotFoundAction = {{ param($Name, $EventArgs) $EventArgs.CommandScriptBlock = {{ }}; $EventArgs.StopSearch = $true }}
function Write-Log {{ param([string]$Message, [string]$Severity) }}
function Invoke-AzGraphQuerySafe {{ param([string]$Query, [string[]]$SubscriptionId, [switch]$Lowercase, [switch]$HideRawOutput) [Console]::WriteLine('QUERY: ' + $Query); return $null }}
function Get-AzGraphCount {{ param($Result) 0 }}
$ResourceGroup = 'RG-INFRA'
$SubscriptionID = '00000000-0000-0000-0000-000000000001'
$Global:Resources = @()
'@ -f $Culture) + "`n" + $Fn[0].Extent.Text + "`nResourceInventoryLoop")
        $Pwsh = (Get-Process -Id $PID).Path
        $Out = @(& $Pwsh -NoProfile -NonInteractive -File $Script)
        $Queries = @($Out | Where-Object { $_ -like 'QUERY: *' })
        $Queries.Count | Should -BeGreaterThan 0
        $Queries | ForEach-Object { $_ | Should -BeLike "*resourceGroup == 'rg-infra'*" }
    }
}
