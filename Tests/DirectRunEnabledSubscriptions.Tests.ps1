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
        { Invoke-Set -SubscriptionID $SubscriptionID -Listed @($Off) } | Should -Throw '*no Enabled subscription*ADVICE:*pass -SubscriptionID to collect one that is not Enabled*'
    }

    It 'stops with -SubscriptionID when nothing is listed, without the hint to pass -SubscriptionID' {
        $SubscriptionID = 'sub-off'
        $Err = $null
        try { Invoke-Set -SubscriptionID $SubscriptionID -Listed @() | Out-Null } catch { $Err = $_.Exception.Message }
        $Err | Should -BeLike '*lists no subscriptions*'
        $Err | Should -Not -BeLike '*pass -SubscriptionID*'
    }
}
