# =============================================================================
# LoginSessionReuse.Tests.ps1
#
# Offline tests for the sign-in step of a direct run of ResourceInventory.ps1
# (LoginSession, nested inside RunInventorySetup).
#
# WHY THIS TEST EXISTS
# --------------------
# The tool signs in with Az PowerShell only. A direct run follows three rules:
#  1. -Appid + -Secret + -TenantID: always sign in as that service principal,
#     even when a user is already signed in.
#  2. Otherwise an Az PowerShell sign-in that is on the target tenant and can
#     still acquire a token silently is reused, with no prompt.
#  3. Otherwise sign in once (device code with -DeviceLogin, the machine's
#     managed identity with -UseManagedIdentity), check the token, and stop
#     with exit 1 if it still fails. Never a second prompt in one run.
# A cached context whose token can no longer be acquired (expired, or gated
# by Conditional Access / MFA) must not count as signed in, or the run
# collects nothing. A usable context is never disconnected; a tenant switch
# uses Set-AzContext -Scope Process so the saved sign-in is left alone.
#
# HOW
# ---
# LoginSession is lifted out of ResourceInventory.ps1 with the PowerShell
# parser (the script runs setup when invoked). Get-AzContext,
# Get-AzAccessToken, Connect-AzAccount, Set-AzContext and Get-AzSubscription
# are shims driven by one simulated sign-in state, with Pester mocks on
# Connect-AzAccount so its parameters can be asserted. An `az` stand-in
# records any call so a test fails if the Azure CLI is used. No live Azure.
#
# Tenant ids are generated at runtime.
#
# Run with: Invoke-Pester ./Tests/LoginSessionReuse.Tests.ps1 -Output Detailed
# =============================================================================

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $script:CommonFunctions = Join-Path $script:RepoRoot 'Functions/Common.Functions.ps1'
    $script:InventoryScript = Join-Path $script:RepoRoot 'ResourceInventory.ps1'
    foreach ($Required in @($script:CommonFunctions, $script:InventoryScript))
    {
        if (-not (Test-Path -LiteralPath $Required -PathType Leaf)) { throw "Required file not found: $Required" }
    }

    # Something for Mock to replace if Common.Functions.ps1 does not define it.
    function Test-RdaInteractiveSession { $false }

    # ResourceInventory.ps1 dot-sources Common.Functions.ps1 at the top, so the
    # sign-in helpers it uses must come from there.
    . $script:CommonFunctions

    $Tokens = $null
    $ParseErrors = $null
    $Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:InventoryScript, [ref]$Tokens, [ref]$ParseErrors)
    if (@($ParseErrors).Count -gt 0) { throw ("ResourceInventory.ps1 does not parse: {0}" -f $ParseErrors[0].Message) }
    $LoginFn = $Ast.FindAll({
            param($Node)
            $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq 'LoginSession'
        }, $true) | Select-Object -First 1
    if ($null -eq $LoginFn) { throw 'LoginSession was not found in ResourceInventory.ps1. Has it been renamed or removed?' }
    $script:LoginFunctionText = $LoginFn.Extent.Text

    $script:TenantA = [guid]::NewGuid().ToString()
    $script:TenantB = [guid]::NewGuid().ToString()

    $script:HadSubscriptions = $null -ne (Get-Variable -Scope Global -Name Subscriptions -ErrorAction SilentlyContinue)
    $script:SavedSubscriptions = $Global:Subscriptions
    $script:HadInitialized = $null -ne (Get-Variable -Scope Global -Name RdaSessionInitialized -ErrorAction SilentlyContinue)
    $script:SavedInitialized = $Global:RdaSessionInitialized
}

AfterAll {
    if ($script:HadSubscriptions) { $Global:Subscriptions = $script:SavedSubscriptions }
    else { Remove-Variable -Scope Global -Name Subscriptions -ErrorAction SilentlyContinue }
    if ($script:HadInitialized) { $Global:RdaSessionInitialized = $script:SavedInitialized }
    else { Remove-Variable -Scope Global -Name RdaSessionInitialized -ErrorAction SilentlyContinue }
    Remove-Variable -Scope Global -Name RdaTenantSubscriptionCache -ErrorAction SilentlyContinue
}

Describe 'LoginSession on a direct run' {

    BeforeAll {
        . ([scriptblock]::Create($script:LoginFunctionText))

        # The Azure CLI must not be used at all.
        function az { $script:AzCalls.Add(($args -join ' ')) }

        function Get-AzContext
        {
            [CmdletBinding()] param()
            if (-not $script:Sim.PsTenant) { return $null }
            [pscustomobject]@{
                Account     = [pscustomobject]@{ Id = $script:Sim.AccountId; Type = $script:Sim.AccountType }
                Tenant      = [pscustomobject]@{ Id = $script:Sim.PsTenant }
                Environment = [pscustomobject]@{ Name = 'AzureCloud' }
            }
        }

        function Set-AzContext
        {
            [CmdletBinding()]
            param([string]$Tenant, [string]$Subscription, [ValidateSet('Process', 'CurrentUser')][string]$Scope)
            $null = $Subscription
            $script:SetContextCalls.Add(('{0} {1}' -f $Tenant, $Scope))
            if ($Tenant -and $Tenant -in $script:Sim.PsReach) { $script:Sim.PsTenant = $Tenant }
        }

        function Get-AzAccessToken
        {
            [CmdletBinding()] param([string]$TenantId, [string]$ResourceUrl)
            if ($script:Sim.PsTenant -and $script:Sim.PsTokenOk -and $TenantId -in $script:Sim.PsReach) { return [pscustomobject]@{ Token = 'token'; TenantId = $TenantId } }
            throw 'Unable to acquire token for tenant. User interaction is required.'
        }

        function Connect-AzAccount
        {
            [CmdletBinding()]
            param([string]$Tenant, [switch]$UseDeviceAuthentication, [switch]$Identity, [switch]$ServicePrincipal, [pscredential]$Credential, [ValidateSet('Process', 'CurrentUser')][string]$Scope)
            $null = $UseDeviceAuthentication, $Identity, $ServicePrincipal, $Credential, $Scope
            Invoke-SimPsSignIn -Tenant $Tenant
        }

        function Disconnect-AzAccount { [CmdletBinding()] param() }

        # A sign-in; the context's account is that identity: a service
        # principal's id is its app id, as in Az PowerShell.
        function Invoke-SimPsSignIn
        {
            param([string]$Tenant, [string]$Account = 'signed-in', [string]$AppId)
            if ($Tenant) { $script:Sim.PsTenant = $Tenant; $script:Sim.PsReach = @($Tenant) }
            else { $script:Sim.PsTenant = $script:Sim.HomeTenant; $script:Sim.PsReach = @($script:Sim.Tenants) }
            $script:Sim.Account = $Account
            $script:Sim.AccountType = switch ($Account) { 'service-principal' { 'ServicePrincipal' } 'managed-identity' { 'ManagedService' } default { 'User' } }
            $script:Sim.AccountId = if ($Account -eq 'service-principal') { $AppId } else { $Account }
            $script:Sim.PsTokenOk = $true
        }

        # One subscription per tenant; with -TenantId, that tenant's
        # subscriptions, without it one entry per tenant the sign-in reaches.
        function Get-AzSubscription
        {
            [CmdletBinding()] param([string]$TenantId)
            $script:SubscriptionCalls.Add([string]$TenantId)
            if ($TenantId)
            {
                if ($TenantId -notin $script:Sim.PsReach) { return }
                return [pscustomobject]@{ Id = ('sub-' + $TenantId); Name = ('Subscription ' + $TenantId); TenantId = $TenantId; HomeTenantId = $TenantId; State = 'Enabled' }
            }
            foreach ($T in $script:Sim.PsReach) { [pscustomobject]@{ Id = ('sub-' + $T); TenantId = $T; HomeTenantId = $T; State = 'Enabled' } }
        }

        function Set-SignInState
        {
            param([string]$PsTenant, [bool]$PsTokenOk = $true, [string]$HomeTenant = $script:TenantA, [string[]]$Tenants)
            if (-not $Tenants) { $Tenants = @($HomeTenant) }
            $script:Sim = @{
                PsTenant = $PsTenant; PsTokenOk = $PsTokenOk; PsReach = @($PsTenant | Where-Object { $_ })
                HomeTenant = $HomeTenant; Tenants = $Tenants; Account = 'cached-user'; AccountType = 'User'; AccountId = 'cached-user'
            }
        }
    }

    BeforeEach {
        $script:AzCalls = [System.Collections.Generic.List[string]]::new()
        $script:SetContextCalls = [System.Collections.Generic.List[string]]::new()
        $script:SubscriptionCalls = [System.Collections.Generic.List[string]]::new()
        $script:LogLines = [System.Collections.Generic.List[string]]::new()
        $Global:RdaSessionInitialized = $true
        $Global:Subscriptions = @()
        Remove-Variable -Scope Global -Name RdaTenantSubscriptionCache -ErrorAction SilentlyContinue
        Mock -CommandName Write-Log -MockWith { $script:LogLines.Add(('{0}: {1}' -f $Severity, $Message)) }
        Mock -CommandName Connect-AzAccount -MockWith { Invoke-SimPsSignIn -Tenant $Tenant -Account $(if ($ServicePrincipal) { 'service-principal' } elseif ($Identity) { 'managed-identity' } else { 'signed-in' }) -AppId $Credential.UserName }
        Mock -CommandName Disconnect-AzAccount -MockWith { }
        # A console a person can answer; a browser sign-in in a session with
        # none stops the run (SignInRules.Tests.ps1 covers that in a child
        # process, since the stop is a real exit).
        Mock -CommandName Test-RdaInteractiveSession -MockWith { $true }
        Mock -CommandName Read-Host -MockWith { throw 'Read-Host was not expected in this test' }

        # Script parameters LoginSession reads from its caller's scope.
        $TenantID = $null
        $Appid = $null
        $Secret = $null
        $DeviceLogin = [switch]$false
        $RunAllSubs = [switch]$false
        $UseManagedIdentity = [switch]$false
        $null = $TenantID, $Appid, $Secret, $DeviceLogin, $RunAllSubs, $UseManagedIdentity
    }

    AfterEach {
        $script:AzCalls.Count | Should -Be 0 -Because 'the Azure CLI is not used'
        Should -Invoke -CommandName Disconnect-AzAccount -Times 0 -Exactly
    }

    It 'reuses a usable cached Az PowerShell sign-in with no prompt' {
        Set-SignInState -PsTenant $script:TenantA

        LoginSession 6>$null

        Should -Invoke -CommandName Connect-AzAccount -Times 0 -Exactly
        Should -Invoke -CommandName Read-Host -Times 0 -Exactly
        @($Global:Subscriptions).Count | Should -Be 1
        $Global:Subscriptions[0].id | Should -Be ('sub-' + $script:TenantA)
        $Global:Subscriptions[0].tenantId | Should -Be $script:TenantA
        @($script:SubscriptionCalls) | Should -Be @($script:TenantA) -Because 'subscriptions are listed for the tenant with -TenantId'
    }

    It 'reuses a usable cached sign-in on the tenant -TenantID names' {
        $TenantID = $script:TenantA
        $null = $TenantID
        Set-SignInState -PsTenant $script:TenantA

        LoginSession 6>$null

        Should -Invoke -CommandName Connect-AzAccount -Times 0 -Exactly
        @($Global:Subscriptions).Count | Should -Be 1
    }

    It 'signs in once more when the cached context cannot acquire a token' {
        Set-SignInState -PsTenant $script:TenantA -PsTokenOk $false

        LoginSession 6>$null

        Should -Invoke -CommandName Connect-AzAccount -Times 1 -Exactly
        Should -Invoke -CommandName Connect-AzAccount -Times 1 -Exactly -ParameterFilter { $Tenant -eq $script:TenantA -and -not $UseDeviceAuthentication }
        @($Global:Subscriptions).Count | Should -Be 1
    }

    It 'signs in to -TenantID once when the cached sign-in is on another tenant, without disconnecting it' {
        $TenantID = $script:TenantB
        $null = $TenantID
        Set-SignInState -PsTenant $script:TenantA

        LoginSession 6>$null

        Should -Invoke -CommandName Connect-AzAccount -Times 1 -Exactly -ParameterFilter { $Tenant -eq $script:TenantB }
        @($Global:Subscriptions | Where-Object { $_.tenantId -eq $script:TenantB }).Count | Should -Be 1
    }

    It 'uses device code sign-in with -DeviceLogin' {
        $DeviceLogin = [switch]$true
        $TenantID = $script:TenantA
        $null = $DeviceLogin, $TenantID
        Set-SignInState

        LoginSession 6>$null

        Should -Invoke -CommandName Connect-AzAccount -Times 1 -Exactly
        Should -Invoke -CommandName Connect-AzAccount -Times 1 -Exactly -ParameterFilter { $UseDeviceAuthentication.IsPresent -and $Tenant -eq $script:TenantA }
    }

    It 'uses device code sign-in with -DeviceLogin when nothing is signed in and no -TenantID is given' {
        $DeviceLogin = [switch]$true
        $null = $DeviceLogin
        Set-SignInState

        LoginSession 6>$null

        Should -Invoke -CommandName Connect-AzAccount -Times 1 -Exactly -ParameterFilter { $UseDeviceAuthentication.IsPresent -and -not $Tenant }
    }

    It 'signs in once and lists the only tenant''s subscriptions when nothing is signed in' {
        Set-SignInState

        LoginSession 6>$null

        Should -Invoke -CommandName Connect-AzAccount -Times 1 -Exactly
        Should -Invoke -CommandName Connect-AzAccount -Times 1 -Exactly -ParameterFilter { -not $Tenant }
        @($Global:Subscriptions).Count | Should -Be 1
        $Global:Subscriptions[0].tenantId | Should -Be $script:TenantA
    }

    # With no console only the device code can sign in (a browser sign-in
    # stops the run), and there is nobody to pick the tenant.
    It 'signs in once and uses the first tenant when nothing was signed in, several tenants, no console' {
        $Sorted = @($script:TenantA, $script:TenantB | Sort-Object)
        Set-SignInState -Tenants $script:TenantA, $script:TenantB
        $DeviceLogin = [switch]$true
        $null = $DeviceLogin
        Mock -CommandName Test-RdaInteractiveSession -MockWith { $false }

        LoginSession 6>$null

        Should -Invoke -CommandName Connect-AzAccount -Times 1 -Exactly -Because 'never a second prompt in one run'
        Should -Invoke -CommandName Read-Host -Times 0 -Exactly
        @($Global:Subscriptions).Count | Should -Be 1
        $Global:Subscriptions[0].tenantId | Should -Be $Sorted[0]
        Get-AzPsSignedInTenant | Should -Be $Sorted[0]
    }

    It 'signs in once and uses the picked tenant, switching only this process, when several tenants and interactive' {
        $Sorted = @($script:TenantA, $script:TenantB | Sort-Object)
        Set-SignInState -Tenants $script:TenantA, $script:TenantB
        Mock -CommandName Test-RdaInteractiveSession -MockWith { $true }
        Mock -CommandName Read-Host -MockWith { '2' }

        LoginSession 6>$null

        Should -Invoke -CommandName Read-Host -Times 1 -Exactly
        Should -Invoke -CommandName Connect-AzAccount -Times 1 -Exactly -Because 'never a second prompt in one run'
        @($Global:Subscriptions).Count | Should -Be 1
        $Global:Subscriptions[0].tenantId | Should -Be $Sorted[1]
        Get-AzPsSignedInTenant | Should -Be $Sorted[1]
        if ($Sorted[1] -ne $script:TenantA) { @($script:SetContextCalls) | Should -Contain ('{0} Process' -f $Sorted[1]) }
        @($script:SetContextCalls | Where-Object { $_ -notmatch ' Process$' }).Count | Should -Be 0
    }

    It 'signs in with the managed identity on -TenantID with -UseManagedIdentity' {
        $UseManagedIdentity = [switch]$true
        $TenantID = $script:TenantA
        $null = $UseManagedIdentity, $TenantID
        Set-SignInState

        LoginSession 6>$null

        Should -Invoke -CommandName Connect-AzAccount -Times 1 -Exactly
        Should -Invoke -CommandName Connect-AzAccount -Times 1 -Exactly -ParameterFilter { $Identity.IsPresent -and $Tenant -eq $script:TenantA }
        @($Global:Subscriptions).Count | Should -Be 1
    }

    It 'signs in with the managed identity without a tenant when -TenantID is not given' {
        $UseManagedIdentity = [switch]$true
        $null = $UseManagedIdentity
        Set-SignInState

        LoginSession 6>$null

        Should -Invoke -CommandName Connect-AzAccount -Times 1 -Exactly -ParameterFilter { $Identity.IsPresent -and -not $Tenant }
        @($Global:Subscriptions).Count | Should -Be 1
    }

    It 'signs in as the service principal with a SecureString credential when -Appid, -Secret and -TenantID are given' {
        $TenantID = $script:TenantA
        $Appid = [guid]::NewGuid().ToString()
        $Secret = ConvertTo-SecureString -String 'not-a-real-secret' -AsPlainText -Force
        $null = $TenantID, $Appid, $Secret
        Set-SignInState

        LoginSession 6>$null

        Should -Invoke -CommandName Connect-AzAccount -Times 1 -Exactly
        Should -Invoke -CommandName Connect-AzAccount -Times 1 -Exactly -ParameterFilter {
            $ServicePrincipal.IsPresent -and $Tenant -eq $script:TenantA -and $Credential.UserName -eq $Appid -and $Credential.Password -is [securestring]
        }
        @($Global:Subscriptions).Count | Should -Be 1
    }

    It 'signs in as the service principal even when a user is already signed in to the tenant' {
        $TenantID = $script:TenantA
        $Appid = [guid]::NewGuid().ToString()
        $Secret = ConvertTo-SecureString -String 'not-a-real-secret' -AsPlainText -Force
        $null = $TenantID, $Appid, $Secret
        Set-SignInState -PsTenant $script:TenantA

        LoginSession 6>$null

        Should -Invoke -CommandName Connect-AzAccount -Times 1 -Exactly -Because 'explicit service principal credentials replace a cached user'
        Should -Invoke -CommandName Connect-AzAccount -Times 1 -Exactly -ParameterFilter { $ServicePrincipal.IsPresent -and $Tenant -eq $script:TenantA }
        $script:Sim.Account | Should -Be 'service-principal'
    }

    It 'signs in as the service principal, not with the managed identity, when both are asked for' {
        $TenantID = $script:TenantA
        $Appid = [guid]::NewGuid().ToString()
        $Secret = ConvertTo-SecureString -String 'not-a-real-secret' -AsPlainText -Force
        $UseManagedIdentity = [switch]$true
        $null = $TenantID, $Appid, $Secret, $UseManagedIdentity
        Set-SignInState

        LoginSession 6>$null

        Should -Invoke -CommandName Connect-AzAccount -Times 1 -Exactly -ParameterFilter { $ServicePrincipal.IsPresent -and -not $Identity }
    }

    # Connect-AzAccount saves its sign-in as the user's default context unless
    # it is given -Scope Process, and the next run reuses a usable saved
    # sign-in (rule 2). A service principal or managed identity sign-in saved
    # that way would make a later run without -Appid / -UseManagedIdentity
    # quietly collect as that identity. The stand-in below saves a sign-in
    # made without -Scope Process; the second LoginSession is the next run,
    # starting from what was saved.
    It 'keeps the service principal sign-in to this process, so a later run without -Appid does not reuse it' {
        $TenantID = $script:TenantA
        $Appid = [guid]::NewGuid().ToString()
        $Secret = ConvertTo-SecureString -String 'not-a-real-secret' -AsPlainText -Force
        $null = $TenantID, $Appid, $Secret
        Set-SignInState
        $script:SavedAccount = $null
        Mock -CommandName Connect-AzAccount -MockWith {
            $SignedInAs = if ($ServicePrincipal) { 'service-principal' } elseif ($Identity) { 'managed-identity' } else { 'signed-in' }
            Invoke-SimPsSignIn -Tenant $Tenant -Account $SignedInAs -AppId $Credential.UserName
            if ($Scope -ne 'Process') { $script:SavedAccount = $SignedInAs }
        }

        LoginSession 6>$null

        Should -Invoke -CommandName Connect-AzAccount -Times 1 -Exactly -ParameterFilter { $ServicePrincipal.IsPresent -and $Scope -eq 'Process' }
        $script:SavedAccount | Should -BeNullOrEmpty -Because 'the service principal sign-in is not saved as the default context'

        # The next run, without -Appid, in a new process.
        if ($script:SavedAccount) { Set-SignInState -PsTenant $script:TenantA; $script:Sim.Account = $script:SavedAccount } else { Set-SignInState }
        $Appid = $null
        $Secret = $null
        $null = $Appid, $Secret

        LoginSession 6>$null

        Should -Invoke -CommandName Connect-AzAccount -Times 1 -Exactly -ParameterFilter { -not $ServicePrincipal.IsPresent -and -not $Identity.IsPresent } -Because 'a run without -Appid signs in itself instead of running as the service principal'
        $script:Sim.Account | Should -Be 'signed-in'
    }

    It 'keeps the managed identity sign-in to this process, so a later run without -UseManagedIdentity does not reuse it' {
        $TenantID = $script:TenantA
        $UseManagedIdentity = [switch]$true
        $null = $TenantID, $UseManagedIdentity
        Set-SignInState
        $script:SavedAccount = $null
        Mock -CommandName Connect-AzAccount -MockWith {
            $SignedInAs = if ($ServicePrincipal) { 'service-principal' } elseif ($Identity) { 'managed-identity' } else { 'signed-in' }
            Invoke-SimPsSignIn -Tenant $Tenant -Account $SignedInAs -AppId $Credential.UserName
            if ($Scope -ne 'Process') { $script:SavedAccount = $SignedInAs }
        }

        LoginSession 6>$null

        Should -Invoke -CommandName Connect-AzAccount -Times 1 -Exactly -ParameterFilter { $Identity.IsPresent -and $Scope -eq 'Process' }
        $script:SavedAccount | Should -BeNullOrEmpty -Because 'the managed identity sign-in is not saved as the default context'

        # The next run, without -UseManagedIdentity, in a new process.
        if ($script:SavedAccount) { Set-SignInState -PsTenant $script:TenantA; $script:Sim.Account = $script:SavedAccount } else { Set-SignInState }
        $UseManagedIdentity = [switch]$false
        $null = $UseManagedIdentity

        LoginSession 6>$null

        Should -Invoke -CommandName Connect-AzAccount -Times 1 -Exactly -ParameterFilter { -not $ServicePrincipal.IsPresent -and -not $Identity.IsPresent } -Because 'a run without -UseManagedIdentity signs in itself instead of running as the managed identity'
        $script:Sim.Account | Should -Be 'signed-in'
    }

    It 'saves a user sign-in as usual, so the next run reuses it' {
        $TenantID = $script:TenantA
        $null = $TenantID
        Set-SignInState

        LoginSession 6>$null

        Should -Invoke -CommandName Connect-AzAccount -Times 1 -Exactly -ParameterFilter { -not $Scope } -Because 'only service principal and managed identity sign-ins are kept to the process'
    }

    It 'signs in nothing under -RunAllSubs' {
        $RunAllSubs = [switch]$true
        $TenantID = $script:TenantA
        $null = $RunAllSubs, $TenantID
        Set-SignInState -PsTenant $script:TenantA

        LoginSession 6>$null

        Should -Invoke -CommandName Connect-AzAccount -Times 0 -Exactly
        @($Global:Subscriptions).Count | Should -Be 1
    }

    It 'lists the tenant''s subscriptions once per process under -RunAllSubs' {
        $RunAllSubs = [switch]$true
        $TenantID = $script:TenantA
        $null = $RunAllSubs, $TenantID
        Set-SignInState -PsTenant $script:TenantA

        LoginSession 6>$null
        LoginSession 6>$null

        @($script:SubscriptionCalls).Count | Should -Be 1 -Because 'the wrapper runs this once per subscription; the tenant list does not change in between'
        @($Global:Subscriptions).Count | Should -Be 1
    }

    It 'points this process at -TenantID, without a sign-in, under -RunAllSubs when the context is on another tenant' {
        $RunAllSubs = [switch]$true
        $TenantID = $script:TenantB
        $null = $RunAllSubs, $TenantID
        Set-SignInState -PsTenant $script:TenantA
        $script:Sim.PsReach = @($script:TenantA, $script:TenantB)

        LoginSession 6>$null

        Should -Invoke -CommandName Connect-AzAccount -Times 0 -Exactly
        @($script:SetContextCalls) | Should -Be @(('{0} Process' -f $script:TenantB))
        $Global:Subscriptions[0].tenantId | Should -Be $script:TenantB
    }
}

# A sign-in whose token probe still fails after its one attempt must stop the
# run (exit 1) instead of prompting again. The stop is a real `exit`, so these
# cases run LoginSession in a child pwsh process with file-logged fakes, under
# the production $ErrorActionPreference.
Describe 'LoginSession when a sign-in does not give a usable token' {

    BeforeAll {
        $script:Harness = Join-Path $TestDrive 'login-harness.ps1'
        @'
param([string]$Root, [string]$CallLog, [string]$Scenario, [string]$Tenant)
$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path $Root 'Functions/Common.Functions.ps1')
$Ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Root 'ResourceInventory.ps1'), [ref]$null, [ref]$null)
$Fn = $Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq 'LoginSession' }, $true) | Select-Object -First 1
. ([scriptblock]::Create($Fn.Extent.Text))

# Simulated sign-in state. A sign-in "succeeds" but never yields a token,
# so the probe fails again afterwards.
$Global:Sim = switch ($Scenario)
{
    # Cached on the tenant, token gone; the sign-in gives no token either.
    'ps-token-fails' { @{ PsTenant = $Tenant; PsToken = $false } }
    'mi-token-fails' { @{ PsTenant = $null; PsToken = $false } }
    # Nothing signed in and no -TenantID: the sign-in itself fails.
    'fresh-login-fails' { @{ PsTenant = $null; PsToken = $false; LoginFails = $true } }
    # Nothing signed in and no -TenantID: the sign-in succeeds, no token follows.
    'fresh-token-fails' { @{ PsTenant = $null; PsToken = $false } }
    # Service principal sign-in succeeds, no token follows.
    'sp-token-fails' { @{ PsTenant = $null; PsToken = $false } }
    # -Appid without -Secret while a user is signed in to the tenant.
    'sp-missing-secret' { @{ PsTenant = $Tenant; PsToken = $true } }
}
# A console is there (a browser sign-in without one stops the run); one
# tenant only, so no tenant number is asked for.
function global:Test-RdaInteractiveSession { $true }
function global:Write-Log { param($Message, $Severity) Write-Output ('{0}: {1}' -f $Severity, $Message) }
function global:az { Add-Content -Path $CallLog -Value ('az ' + ($args -join ' ')) }
function global:Get-AzContext { [CmdletBinding()] param() if ($Global:Sim.PsTenant) { [pscustomobject]@{ Account = [pscustomobject]@{ Id = $Global:Sim.AccountId; Type = $Global:Sim.AccountType }; Tenant = [pscustomobject]@{ Id = $Global:Sim.PsTenant }; Environment = [pscustomobject]@{ Name = 'AzureCloud' } } } }
function global:Get-AzAccessToken { [CmdletBinding()] param($TenantId) Add-Content -Path $CallLog -Value 'probe'; if ($Global:Sim.PsToken) { [pscustomobject]@{ Token = 'token' } } else { throw 'User interaction is required.' } }
function global:Connect-AzAccount
{
    [CmdletBinding()] param([string]$Tenant, [switch]$Identity, [switch]$UseDeviceAuthentication, [switch]$ServicePrincipal, [pscredential]$Credential, [string]$Scope)
    Add-Content -Path $CallLog -Value ('Connect-AzAccount' + $(if ($Identity) { ' -Identity' }) + $(if ($ServicePrincipal) { ' -ServicePrincipal' }) + $(if ($Tenant) { ' -Tenant ' + $Tenant }) + $(if ($Scope) { ' -Scope ' + $Scope }))
    if ($Global:Sim.LoginFails) { throw 'sign-in was cancelled' }
    $Global:Sim.PsTenant = if ($Tenant) { $Tenant } else { $Global:HarnessTenant }
    $Global:Sim.AccountType = if ($ServicePrincipal) { 'ServicePrincipal' } elseif ($Identity) { 'ManagedService' } else { 'User' }
    $Global:Sim.AccountId = if ($ServicePrincipal) { $Credential.UserName } else { 'signed-in' }
}
function global:Disconnect-AzAccount { Add-Content -Path $CallLog -Value 'Disconnect-AzAccount' }
function global:Get-AzSubscription { [CmdletBinding()] param([string]$TenantId) Add-Content -Path $CallLog -Value ('Get-AzSubscription ' + $TenantId); [pscustomobject]@{ Id = 'sub-1'; TenantId = $Global:HarnessTenant; HomeTenantId = $Global:HarnessTenant; State = 'Enabled' } }
function global:Set-AzContext { [CmdletBinding()] param([string]$Tenant, [string]$Scope) if ($Tenant) { $Global:Sim.PsTenant = $Tenant } }

$Global:Sim.AccountType = 'User'; $Global:Sim.AccountId = 'cached-user'
$Global:RdaSessionInitialized = $true
$Global:HarnessTenant = $Tenant
$TenantID = if ($Scenario -in 'ps-token-fails', 'mi-token-fails', 'sp-token-fails', 'sp-missing-secret') { $Tenant } else { $null }
$UseManagedIdentity = [switch]($Scenario -eq 'mi-token-fails')
$Appid = if ($Scenario -like 'sp-*') { [guid]::NewGuid().ToString() } else { $null }
$Secret = if ($Scenario -eq 'sp-token-fails') { ConvertTo-SecureString -String 'not-a-real-secret' -AsPlainText -Force } else { $null }
$DeviceLogin = [switch]$false; $RunAllSubs = [switch]$false
LoginSession
Add-Content -Path $CallLog -Value 'returned'
exit 0
'@ | Set-Content -Path $script:Harness -Encoding utf8

        function Invoke-LoginHarness
        {
            param([string]$Scenario)
            $CallLog = Join-Path $TestDrive ('calls-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.log')
            $Output = & (Join-Path $PSHOME 'pwsh') -NoProfile -NonInteractive -File $script:Harness -Root $script:RepoRoot -CallLog $CallLog -Scenario $Scenario -Tenant $script:TenantA 2>&1 | Out-String
            $Code = $LASTEXITCODE
            $Calls = if (Test-Path -LiteralPath $CallLog) { @(Get-Content -LiteralPath $CallLog) } else { @() }
            [pscustomobject]@{
                ExitCode = $Code
                Output   = $Output
                Calls    = $Calls
                AzCalls  = @($Calls | Where-Object { $_ -like 'az *' })
                Connects = @($Calls | Where-Object { $_ -like 'Connect-AzAccount*' })
                Probes   = @($Calls | Where-Object { $_ -eq 'probe' })
                Listed   = @($Calls | Where-Object { $_ -like 'Get-AzSubscription*' })
            }
        }
    }

    It 'signs in once and stops with exit 1 when the token probe still fails' {
        $Run = Invoke-LoginHarness -Scenario 'ps-token-fails'

        $Run.ExitCode | Should -Be 1
        $Run.Connects.Count | Should -Be 1 -Because 'one sign-in attempt, never a second prompt'
        $Run.Probes.Count | Should -BeGreaterThan 1 -Because 'the token is probed before and after the sign-in'
        $Run.Calls | Should -Not -Contain 'returned'
        $Run.Listed.Count | Should -Be 0 -Because 'no subscriptions are listed for an unusable sign-in'
        $Run.Calls | Should -Not -Contain 'Disconnect-AzAccount'
        $Run.AzCalls.Count | Should -Be 0
        $Run.Output | Should -Match 'Az PowerShell: sign-in to tenant .* did not give a usable token'
    }

    It 'signs in with the managed identity once and stops with exit 1 when no token can be acquired' {
        $Run = Invoke-LoginHarness -Scenario 'mi-token-fails'

        $Run.ExitCode | Should -Be 1
        $Run.Connects.Count | Should -Be 1
        $Run.Connects[0] | Should -Match '-Identity'
        $Run.Calls | Should -Not -Contain 'returned'
        $Run.AzCalls.Count | Should -Be 0
    }

    It 'stops with exit 1 after one attempt when the sign-in itself fails and nothing was signed in' {
        $Run = Invoke-LoginHarness -Scenario 'fresh-login-fails'

        $Run.ExitCode | Should -Be 1
        $Run.Connects.Count | Should -Be 1 -Because 'one sign-in attempt, never a second prompt'
        $Run.Calls | Should -Not -Contain 'returned'
        $Run.AzCalls.Count | Should -Be 0
    }

    It 'signs in once and stops with exit 1 when no token follows, nothing was signed in and no -TenantID' {
        $Run = Invoke-LoginHarness -Scenario 'fresh-token-fails'

        $Run.ExitCode | Should -Be 1 -Because 'an unusable sign-in must not continue into an empty inventory'
        $Run.Connects.Count | Should -Be 1
        $Run.Probes.Count | Should -BeGreaterThan 0
        $Run.Calls | Should -Not -Contain 'returned'
        $Run.Output | Should -Match 'did not give a usable token'
    }

    It 'signs in as the service principal once and stops with exit 1 when no token follows' {
        $Run = Invoke-LoginHarness -Scenario 'sp-token-fails'

        $Run.ExitCode | Should -Be 1
        $Run.Connects.Count | Should -Be 1
        $Run.Connects[0] | Should -Match '-ServicePrincipal'
        $Run.Calls | Should -Not -Contain 'returned'
        $Run.AzCalls.Count | Should -Be 0
    }

    It 'stops with exit 1 for -Appid without -Secret instead of using the signed-in user' {
        $Run = Invoke-LoginHarness -Scenario 'sp-missing-secret'

        $Run.ExitCode | Should -Be 1
        $Run.Connects.Count | Should -Be 0
        $Run.Calls | Should -Not -Contain 'returned'
    }
}

# The reconnect before metrics and consumption (Test-DataPlaneAuthReady, nested
# in ExecuteInventoryProcessing). With -UseManagedIdentity it reconnects with
# the machine's identity at most once per run and never with a user sign-in.
Describe 'Data-plane reconnect with -UseManagedIdentity' {

    BeforeAll {
        $ReadyFn = $Ast.FindAll({
                param($Node)
                $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq 'Test-DataPlaneAuthReady'
            }, $true) | Select-Object -First 1
        if ($null -eq $ReadyFn) { throw 'Test-DataPlaneAuthReady was not found in ResourceInventory.ps1. Has it been renamed or removed?' }
        . ([scriptblock]::Create($ReadyFn.Extent.Text))

        function Get-AzContext { [CmdletBinding()] param() }
        function Get-AzAccessToken { [CmdletBinding()] param([string]$TenantId, [string]$ResourceUrl) $null = $TenantId, $ResourceUrl }
        function Connect-AzAccount
        {
            [CmdletBinding()]
            param([string]$Tenant, [switch]$UseDeviceAuthentication, [switch]$Identity, [switch]$ServicePrincipal, [pscredential]$Credential, [ValidateSet('Process', 'CurrentUser')][string]$Scope)
            $null = $Tenant, $UseDeviceAuthentication, $Identity, $ServicePrincipal, $Credential, $Scope
        }
    }

    BeforeEach {
        $script:LogLines = [System.Collections.Generic.List[string]]::new()
        $script:Connected = $false
        $script:IdentityGivesToken = $true
        $script:RdaReconnectTried = $null
        $script:RdaUserSignInMade = $null
        $script:RdaRunTenant = $null
        Mock -CommandName Write-Log -MockWith { $script:LogLines.Add(('{0}: {1}' -f $Severity, $Message)) }
        Mock -CommandName Get-AzContext -MockWith { if ($script:Connected) { [pscustomobject]@{ Account = [pscustomobject]@{ Id = 'identity' } } } }
        Mock -CommandName Get-AzAccessToken -MockWith { [pscustomobject]@{ Token = 'token' } }
        Mock -CommandName Connect-AzAccount -MockWith { if ($Identity.IsPresent -and $script:IdentityGivesToken) { $script:Connected = $true } }

        $UseManagedIdentity = [switch]$true
        $TenantID = $script:TenantA
        $Appid = $null
        $Secret = $null
        $DeviceLogin = [switch]$false
        $RunAllSubs = [switch]$false
        $null = $UseManagedIdentity, $TenantID, $Appid, $Secret, $DeviceLogin, $RunAllSubs
    }

    It 'reconnects once with the managed identity on the tenant when the token was dropped' {
        Test-DataPlaneAuthReady -Phase 'Metrics' | Should -BeTrue

        Should -Invoke -CommandName Connect-AzAccount -Times 1 -Exactly
        Should -Invoke -CommandName Connect-AzAccount -Times 1 -Exactly -ParameterFilter { $Identity.IsPresent -and $Tenant -eq $script:TenantA }
    }

    It 'reconnects with the managed identity without a tenant when -TenantID is not given' {
        $TenantID = $null
        $null = $TenantID

        Test-DataPlaneAuthReady -Phase 'Metrics' | Should -BeTrue

        Should -Invoke -CommandName Connect-AzAccount -Times 1 -Exactly -ParameterFilter { $Identity.IsPresent -and -not $Tenant }
    }

    It 'keeps the managed identity reconnect to this process' {
        Test-DataPlaneAuthReady -Phase 'Metrics' | Should -BeTrue

        Should -Invoke -CommandName Connect-AzAccount -Times 1 -Exactly -ParameterFilter { $Identity.IsPresent -and $Scope -eq 'Process' }
    }

    It 'reconnects as the service principal, for this process only, when -Appid, -Secret and -TenantID are given' {
        $UseManagedIdentity = [switch]$false
        $Appid = [guid]::NewGuid().ToString()
        $Secret = ConvertTo-SecureString -String 'not-a-real-secret' -AsPlainText -Force
        $null = $UseManagedIdentity, $Appid, $Secret
        Mock -CommandName Connect-AzAccount -MockWith { if ($ServicePrincipal.IsPresent) { $script:Connected = $true } }

        Test-DataPlaneAuthReady -Phase 'Metrics' | Should -BeTrue

        Should -Invoke -CommandName Connect-AzAccount -Times 1 -Exactly
        Should -Invoke -CommandName Connect-AzAccount -Times 1 -Exactly -ParameterFilter {
            $ServicePrincipal.IsPresent -and $Tenant -eq $script:TenantA -and $Credential.UserName -eq $Appid -and $Scope -eq 'Process'
        }
    }

    It 'skips the phase with an error, and does not try again for the next phase, when the identity gives no token' {
        $script:IdentityGivesToken = $false

        Test-DataPlaneAuthReady -Phase 'Metrics' | Should -BeFalse
        Test-DataPlaneAuthReady -Phase 'Consumption' | Should -BeFalse

        Should -Invoke -CommandName Connect-AzAccount -Times 1 -Exactly -Because 'one managed identity reconnect per run, then stop trying'
        Should -Invoke -CommandName Connect-AzAccount -Times 0 -Exactly -ParameterFilter { -not $Identity.IsPresent }
        @($script:LogLines | Where-Object { $_ -match '^Error:' -and $_ -match 'managed identity' }).Count | Should -BeGreaterThan 0
    }
}

# The reconnect for a user (no -Appid, no -UseManagedIdentity): only on the
# run's tenant, at most once per run, and never a second prompt in a run (a
# run that already signed a person in skips the phase instead).
Describe 'Data-plane reconnect for a user' {

    BeforeAll {
        $ReadyFn = $Ast.FindAll({
                param($Node)
                $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq 'Test-DataPlaneAuthReady'
            }, $true) | Select-Object -First 1
        . ([scriptblock]::Create($ReadyFn.Extent.Text))

        function Get-AzContext { [CmdletBinding()] param() }
        function Get-AzAccessToken { [CmdletBinding()] param([string]$TenantId, [string]$ResourceUrl) $null = $TenantId, $ResourceUrl }
        function Set-AzContext { [CmdletBinding()] param([string]$Tenant, [string]$Scope) $null = $Tenant, $Scope }
        function Connect-AzAccount
        {
            [CmdletBinding()]
            param([string]$Tenant, [switch]$UseDeviceAuthentication, [switch]$Identity, [switch]$ServicePrincipal, [pscredential]$Credential, [ValidateSet('Process', 'CurrentUser')][string]$Scope)
            $null = $Tenant, $UseDeviceAuthentication, $Identity, $ServicePrincipal, $Credential, $Scope
        }
    }

    BeforeEach {
        $script:LogLines = [System.Collections.Generic.List[string]]::new()
        $script:Connected = $false
        $script:SignInGivesToken = $true
        $script:SilentTenant = $null
        $script:RdaReconnectTried = $null
        $script:RdaUserSignInMade = $null
        $script:RdaRunTenant = $null
        Mock -CommandName Write-Log -MockWith { $script:LogLines.Add(('{0}: {1}' -f $Severity, $Message)) }
        Mock -CommandName Get-AzContext -MockWith { if ($script:Connected) { [pscustomobject]@{ Account = [pscustomobject]@{ Id = 'user'; Type = 'User' } } } }
        # A token for the current context once connected; with -TenantId,
        # only for the tenant the cached account still reaches silently.
        Mock -CommandName Get-AzAccessToken -MockWith {
            if ($TenantId) { if ($TenantId -eq $script:SilentTenant) { return [pscustomobject]@{ Token = 'token' } } throw 'User interaction is required.' }
            [pscustomobject]@{ Token = 'token' }
        }
        Mock -CommandName Set-AzContext -MockWith { if ($Tenant -eq $script:SilentTenant) { $script:Connected = $true } }
        Mock -CommandName Connect-AzAccount -MockWith { if ($script:SignInGivesToken) { $script:Connected = $true } }
        Mock -CommandName Test-RdaInteractiveSession -MockWith { $true }

        $UseManagedIdentity = [switch]$false
        $TenantID = $script:TenantB
        $Appid = $null
        $Secret = $null
        $DeviceLogin = [switch]$false
        $RunAllSubs = [switch]$false
        $null = $UseManagedIdentity, $TenantID, $Appid, $Secret, $DeviceLogin, $RunAllSubs
    }

    It 'signs in once on -TenantID, not on the home tenant, when the token was dropped' {
        Test-DataPlaneAuthReady -Phase 'Metrics' | Should -BeTrue

        Should -Invoke -CommandName Connect-AzAccount -Times 1 -Exactly
        Should -Invoke -CommandName Connect-AzAccount -Times 1 -Exactly -ParameterFilter { $Tenant -eq $script:TenantB -and -not $Identity -and -not $ServicePrincipal }
    }

    It 'signs in on the tenant the run chose when -TenantID is not given' {
        $TenantID = $null
        $null = $TenantID
        $script:RdaRunTenant = $script:TenantA

        Test-DataPlaneAuthReady -Phase 'Metrics' | Should -BeTrue

        Should -Invoke -CommandName Connect-AzAccount -Times 1 -Exactly -ParameterFilter { $Tenant -eq $script:TenantA }
    }

    It 'signs in with the device code on the tenant with -DeviceLogin' {
        $DeviceLogin = [switch]$true
        $null = $DeviceLogin

        Test-DataPlaneAuthReady -Phase 'Metrics' | Should -BeTrue

        Should -Invoke -CommandName Connect-AzAccount -Times 1 -Exactly -ParameterFilter { $UseDeviceAuthentication.IsPresent -and $Tenant -eq $script:TenantB }
    }

    It 'switches this process back to the tenant, with no prompt, when the sign-in still reaches it silently' {
        $script:SilentTenant = $script:TenantB

        Test-DataPlaneAuthReady -Phase 'Metrics' | Should -BeTrue

        Should -Invoke -CommandName Connect-AzAccount -Times 0 -Exactly
        Should -Invoke -CommandName Set-AzContext -Times 1 -Exactly -ParameterFilter { $Tenant -eq $script:TenantB -and $Scope -eq 'Process' }
    }

    It 'skips the phase instead of prompting a second time when the run already signed a person in' {
        $script:RdaUserSignInMade = $true

        Test-DataPlaneAuthReady -Phase 'Metrics' | Should -BeFalse

        Should -Invoke -CommandName Connect-AzAccount -Times 0 -Exactly
        @($script:LogLines | Where-Object { $_ -match '^Error:' -and $_ -match 'second time' }).Count | Should -Be 1
    }

    It 'reconnects at most once per run: the next phase does not prompt again' {
        $script:SignInGivesToken = $false

        Test-DataPlaneAuthReady -Phase 'Metrics' | Should -BeFalse
        Test-DataPlaneAuthReady -Phase 'Consumption' | Should -BeFalse

        Should -Invoke -CommandName Connect-AzAccount -Times 1 -Exactly
    }

    It 'skips the phase without a sign-in in a session with no console' {
        Mock -CommandName Test-RdaInteractiveSession -MockWith { $false }

        Test-DataPlaneAuthReady -Phase 'Metrics' | Should -BeFalse

        Should -Invoke -CommandName Connect-AzAccount -Times 0 -Exactly
        @($script:LogLines | Where-Object { $_ -match '^Error:' -and $_ -match 'non-interactive' }).Count | Should -Be 1
    }

    It 'reconnects the service principal at most once per run' {
        $Appid = [guid]::NewGuid().ToString()
        $Secret = ConvertTo-SecureString -String 'not-a-real-secret' -AsPlainText -Force
        $null = $Appid, $Secret
        $script:SignInGivesToken = $false

        Test-DataPlaneAuthReady -Phase 'Metrics' | Should -BeFalse
        Test-DataPlaneAuthReady -Phase 'Consumption' | Should -BeFalse

        Should -Invoke -CommandName Connect-AzAccount -Times 1 -Exactly -ParameterFilter { $ServicePrincipal.IsPresent }
    }
}
