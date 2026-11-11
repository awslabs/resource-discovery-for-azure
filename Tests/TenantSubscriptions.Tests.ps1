# =============================================================================
# TenantSubscriptions.Tests.ps1
#
# Offline tests for Get-RdaTenantSubscriptions (Functions/Common.Functions.ps1),
# the one place a run lists the subscriptions of the tenant it collects from.
#
# WHY THIS TEST EXISTS
# --------------------
# Subscriptions used to come from `az account list`, filtered on tenantId. The
# Az PowerShell replacement must:
#  - ask Get-AzSubscription with -TenantId, so a subscription delegated to the
#    tenant (Azure Lighthouse), whose HomeTenantId is another tenant, is kept.
#    Filtering on HomeTenantId would drop it.
#  - list a subscription once even when Az returns it twice.
#  - keep every state (a Disabled or Warned subscription is still listed).
#    The callers choose: a direct run without -SubscriptionID keeps the
#    Enabled ones, as `az account list` did by default
#    (DirectRunEnabledSubscriptions.Tests.ps1); under -RunAllSubs every
#    state is kept and the wrapper chooses the subscriptions.
#  - give callers the properties they read from the az objects: id, name,
#    tenantId, homeTenantId, state.
#
# No live Azure: Get-AzSubscription is mocked.
# Run with: Invoke-Pester ./Tests/TenantSubscriptions.Tests.ps1 -Output Detailed
# =============================================================================

BeforeAll {
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'Functions/Common.Functions.ps1')
    function Get-AzSubscription { [CmdletBinding()] param([string]$TenantId) }

    $script:Tenant = [guid]::NewGuid().ToString()
    $script:Customer = [guid]::NewGuid().ToString()
    $script:Own = [guid]::NewGuid().ToString()
    $script:Delegated = [guid]::NewGuid().ToString()
    $script:Disabled = [guid]::NewGuid().ToString()
}

Describe 'Get-RdaTenantSubscriptions' {

    BeforeEach {
        Mock Get-AzSubscription {
            [pscustomobject]@{ Id = $script:Own; Name = 'Own'; TenantId = $script:Tenant; HomeTenantId = $script:Tenant; State = 'Enabled' }
            [pscustomobject]@{ Id = $script:Delegated; Name = 'Delegated'; TenantId = $script:Tenant; HomeTenantId = $script:Customer; State = 'Enabled' }
            [pscustomobject]@{ Id = $script:Own.ToUpperInvariant(); Name = 'Own again'; TenantId = $script:Tenant; HomeTenantId = $script:Tenant; State = 'Enabled' }
            [pscustomobject]@{ Id = $script:Disabled; Name = 'Old'; TenantId = $null; HomeTenantId = $script:Tenant; State = 'Disabled' }
        }
    }

    It 'asks Az PowerShell for the tenant''s subscriptions with -TenantId' {
        Get-RdaTenantSubscriptions -Tenant $script:Tenant | Out-Null
        Should -Invoke Get-AzSubscription -Times 1 -Exactly
        Should -Invoke Get-AzSubscription -Times 1 -Exactly -ParameterFilter { $TenantId -eq $script:Tenant }
    }

    It 'keeps a subscription delegated to the tenant' {
        $Subs = @(Get-RdaTenantSubscriptions -Tenant $script:Tenant)
        @($Subs | Where-Object { $_.id -eq $script:Delegated }).Count | Should -Be 1
        ($Subs | Where-Object { $_.id -eq $script:Delegated }).homeTenantId | Should -Be $script:Customer
        ($Subs | Where-Object { $_.id -eq $script:Delegated }).tenantId | Should -Be $script:Tenant
    }

    It 'lists a subscription Az returns twice only once (first one kept)' {
        $Subs = @(Get-RdaTenantSubscriptions -Tenant $script:Tenant)
        @($Subs | Where-Object { $_.id -eq $script:Own }).Count | Should -Be 1
        ($Subs | Where-Object { $_.id -eq $script:Own }).name | Should -Be 'Own'
        $Subs.Count | Should -Be 3
    }

    It 'keeps every state, and gives the properties callers read' {
        $Subs = @(Get-RdaTenantSubscriptions -Tenant $script:Tenant)
        $Old = $Subs | Where-Object { $_.id -eq $script:Disabled }
        $Old.state | Should -Be 'Disabled'
        $Old.name | Should -Be 'Old'
        $Old.tenantId | Should -Be $script:Tenant -Because 'a missing TenantId is the tenant that was asked'
        @($Subs[0].PSObject.Properties.Name) | Should -Be @('id', 'name', 'tenantId', 'homeTenantId', 'state')
    }

    It 'returns an empty list when the tenant has no subscription' {
        Mock Get-AzSubscription { }
        $Subs = @(Get-RdaTenantSubscriptions -Tenant $script:Tenant)
        $Subs.Count | Should -Be 0
    }
}
