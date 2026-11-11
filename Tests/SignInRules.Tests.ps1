# =============================================================================
# SignInRules.Tests.ps1
#
# End-to-end offline tests of the sign-in rules of a direct run of
# ResourceInventory.ps1, in every entry path (local PowerShell and Azure
# Cloud Shell):
#  1. -Appid/-Secret/-TenantID: always the service principal. If its sign-in
#     fails, or the context is then not that service principal, the run stops
#     with exit 1 and never goes on as a cached user. Same for
#     -UseManagedIdentity.
#  2. Otherwise a cached sign-in that can acquire a token for the target
#     tenant silently is reused with no prompt (switched to that tenant for
#     this process when it is on another one).
#  3. Otherwise sign in once, probe, and stop with exit 1 if it is unusable.
#     Never a second prompt in a run, and no browser in a session with no
#     console.
# The run also stops when the context is not on the target tenant, when no
# tenant is chosen, and when the tenant lists no subscriptions, instead of
# writing an empty or wrong-tenant report with exit 0.
#
# HOW
# ---
# Each case runs in a child pwsh under the production
# $ErrorActionPreference = 'SilentlyContinue', because the stops are real
# `exit 1` calls. LoginSession (and, for Cloud Shell, CheckPowerShell) is
# lifted out of ResourceInventory.ps1 with the parser. Every Az cmdlet the
# path uses is a file-logging fake driven by a scenario file; nothing reaches
# Azure. Tenant ids are generated at runtime.
#
# Run with: Invoke-Pester ./Tests/SignInRules.Tests.ps1 -Output Detailed
# =============================================================================

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $script:TenantA = [guid]::NewGuid().ToString()
    $script:TenantB = [guid]::NewGuid().ToString()
    $script:TenantC = [guid]::NewGuid().ToString()
    $script:Sorted = @($script:TenantA, $script:TenantB | Sort-Object)
    $script:AppId = [guid]::NewGuid().ToString()

    $script:Harness = Join-Path $TestDrive 'signin-harness.ps1'
    @'
param([string]$Root, [string]$ScenarioFile, [string]$CallLog)
$ErrorActionPreference = 'SilentlyContinue'
$S = Get-Content -LiteralPath $ScenarioFile -Raw | ConvertFrom-Json -AsHashtable
$Global:Sim = $S.Sim
$Global:CallLog = $CallLog
$Global:Answers = [System.Collections.Generic.Queue[string]]::new()
foreach ($A in @($S.Answers)) { if ($null -ne $A) { $Global:Answers.Enqueue([string]$A) } }
$Global:Interactive = [bool]$S.Interactive

. (Join-Path $Root 'Functions/Common.Functions.ps1')
$Ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Root 'ResourceInventory.ps1'), [ref]$null, [ref]$null)
foreach ($Name in 'LoginSession', 'CheckPowerShell')
{
    $Fn = $Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq $Name }, $true) | Select-Object -First 1
    . ([scriptblock]::Create($Fn.Extent.Text))
}

function global:Log([string]$Line) { Add-Content -LiteralPath $Global:CallLog -Value $Line }
function global:Resolve-SimTenant([string]$T) { if ($Global:Sim.Domains -and $Global:Sim.Domains.ContainsKey($T)) { return $Global:Sim.Domains[$T] } return $T }
function global:Test-RdaInteractiveSession { $Global:Interactive }
function global:Write-Log { param($Message, $Severity) Write-Output ('{0}: {1}' -f $Severity, $Message) }
function global:Read-Host { param($Prompt) Log 'Read-Host'; if ($Global:Answers.Count -gt 0) { $Global:Answers.Dequeue() } else { '' } }
function global:az { Log ('az ' + ($args -join ' ')) }
function global:Get-CloudDrive { if ($Global:Sim.CloudShell) { [pscustomobject]@{ Name = 'clouddrive' } } else { throw 'not Cloud Shell' } }
function global:Get-AzContext
{
    [CmdletBinding()] param()
    if (-not $Global:Sim.PsTenant) { return $null }
    [pscustomobject]@{
        Account     = [pscustomobject]@{ Id = $Global:Sim.AccountId; Type = $Global:Sim.AccountType }
        Tenant      = [pscustomobject]@{ Id = $Global:Sim.PsTenant }
        Environment = [pscustomobject]@{ Name = 'AzureCloud' }
    }
}
function global:Get-AzAccessToken
{
    [CmdletBinding()] param([string]$TenantId, [string]$ResourceUrl)
    $T = Resolve-SimTenant $TenantId
    Log ('probe ' + $T)
    if ($Global:Sim.PsTenant -and $Global:Sim.PsTokenOk -and $T -in @($Global:Sim.PsReach)) { return [pscustomobject]@{ Token = 'token'; TenantId = $T } }
    throw 'Unable to acquire token for tenant. User interaction is required.'
}
function global:Connect-AzAccount
{
    [CmdletBinding()] param([string]$Tenant, [switch]$Identity, [switch]$UseDeviceAuthentication, [switch]$ServicePrincipal, [pscredential]$Credential, [string]$Scope)
    Log ('Connect-AzAccount' + $(if ($ServicePrincipal) { ' -ServicePrincipal' }) + $(if ($Identity) { ' -Identity' }) + $(if ($UseDeviceAuthentication) { ' -UseDeviceAuthentication' }) + $(if ($Tenant) { ' -Tenant ' + $Tenant }) + $(if ($Scope) { ' -Scope ' + $Scope }))
    if ($Global:Sim.ConnectThrows) { throw 'AADSTS7000215: Invalid client secret provided.' }
    if ($Global:Sim.ConnectLeavesContext) { return }
    $T = Resolve-SimTenant $Tenant
    if ($T) { $Global:Sim.PsTenant = $T; $Global:Sim.PsReach = @($T) }
    else { $Global:Sim.PsTenant = $Global:Sim.HomeTenant; $Global:Sim.PsReach = @($Global:Sim.Tenants) }
    $Global:Sim.AccountType = if ($ServicePrincipal) { 'ServicePrincipal' } elseif ($Identity) { 'ManagedService' } else { 'User' }
    $Global:Sim.AccountId = if ($ServicePrincipal) { $Credential.UserName } elseif ($Identity) { 'managed-identity' } else { 'signed-in' }
    $Global:Sim.PsTokenOk = -not $Global:Sim.ConnectNoToken
}
function global:Disconnect-AzAccount { Log 'Disconnect-AzAccount' }
function global:Set-AzContext
{
    [CmdletBinding()] param([string]$Tenant, [string]$Subscription, [string]$Scope)
    $T = Resolve-SimTenant $Tenant
    Log ('Set-AzContext ' + $T + ' ' + $Scope)
    if (-not $Global:Sim.SetContextIgnored -and $T -in @($Global:Sim.PsReach)) { $Global:Sim.PsTenant = $T }
}
function global:New-SimSubscription([string]$T, [int]$N)
{
    $HomeTenant = if ($Global:Sim.HomeOf -and $Global:Sim.HomeOf.ContainsKey($T)) { $Global:Sim.HomeOf[$T] } else { $T }
    [pscustomobject]@{ Id = ('sub-{0}-{1}' -f $T, $N); Name = ('Subscription {0}' -f $N); TenantId = $T; HomeTenantId = $HomeTenant; State = 'Enabled' }
}
function global:Get-AzSubscription
{
    [CmdletBinding()] param([string]$TenantId)
    Log ('Get-AzSubscription ' + $TenantId)
    $Reach = @($Global:Sim.PsReach)
    $Wanted = if ($TenantId) { @((Resolve-SimTenant $TenantId)) | Where-Object { $_ -in $Reach } } else { $Reach }
    foreach ($T in $Wanted)
    {
        $Count = if ($Global:Sim.SubsOf -and $Global:Sim.SubsOf.ContainsKey($T)) { [int]$Global:Sim.SubsOf[$T] } else { 1 }
        for ($N = 1; $N -le $Count; $N++) { New-SimSubscription -T $T -N $N }
    }
}

$P = $S.Params
$TenantID = $P.TenantID
$Appid = $P.Appid
$Secret = if ($P.Secret) { ConvertTo-SecureString -String 'not-a-real-secret' -AsPlainText -Force } else { $null }
$UseManagedIdentity = [switch][bool]$P.UseManagedIdentity
$DeviceLogin = [switch][bool]$P.DeviceLogin
$RunAllSubs = [switch]$false
$OutputDirectory = $null
$Global:ReportName = 'ResourcesReport'

if ($S.Entry -eq 'CloudShell')
{
    $Global:RdaSessionInitialized = $false
    CheckPowerShell
    Log ('platform ' + $Global:PlatformOS)
}
else
{
    $Global:RdaSessionInitialized = $true
    LoginSession
}
Log ('context ' + $Global:Sim.PsTenant + ' ' + $Global:Sim.AccountType)
Log ('subscriptions ' + (@($Global:Subscriptions | ForEach-Object { $_.tenantId }) -join ','))
Log 'returned'
exit 0
'@ | Set-Content -Path $script:Harness -Encoding utf8

    # A scenario: Entry (LoginSession / CloudShell), Params, Interactive,
    # Answers (for Read-Host) and the simulated sign-in state.
    function Invoke-SignIn
    {
        param([string]$Entry = 'LoginSession', [hashtable]$Params = @{}, [bool]$Interactive = $true, [string[]]$Answers = @(), [hashtable]$Sim)
        $Base = @{
            PsTenant = $null; PsTokenOk = $true; PsReach = @(); AccountType = 'User'; AccountId = 'cached-user'
            HomeTenant = $script:TenantA; Tenants = @($script:TenantA); CloudShell = ($Entry -eq 'CloudShell')
        }
        foreach ($Key in $Sim.Keys) { $Base[$Key] = $Sim[$Key] }
        if ($Base.PsTenant -and @($Base.PsReach).Count -eq 0) { $Base.PsReach = @($Base.PsTenant) }
        $Id = [guid]::NewGuid().ToString('N').Substring(0, 8)
        $ScenarioFile = Join-Path $TestDrive ('scenario-' + $Id + '.json')
        $CallLog = Join-Path $TestDrive ('calls-' + $Id + '.log')
        @{ Entry = $Entry; Params = $Params; Interactive = $Interactive; Answers = @($Answers); Sim = $Base } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ScenarioFile -Encoding utf8
        $Output = & (Join-Path $PSHOME 'pwsh') -NoProfile -NonInteractive -File $script:Harness -Root $script:RepoRoot -ScenarioFile $ScenarioFile -CallLog $CallLog *>&1 | Out-String
        $Code = $LASTEXITCODE
        $Calls = if (Test-Path -LiteralPath $CallLog) { @(Get-Content -LiteralPath $CallLog) } else { @() }
        [pscustomobject]@{
            ExitCode      = $Code
            Output        = $Output
            Calls         = $Calls
            Returned      = ($Calls -contains 'returned')
            AzCalls       = @($Calls | Where-Object { $_ -like 'az *' })
            Connects      = @($Calls | Where-Object { $_ -like 'Connect-AzAccount*' })
            Listed        = @($Calls | Where-Object { $_ -like 'Get-AzSubscription *' -and $_ -ne 'Get-AzSubscription ' })
            SetContexts   = @($Calls | Where-Object { $_ -like 'Set-AzContext*' })
            ReadHosts     = @($Calls | Where-Object { $_ -eq 'Read-Host' })
            Context       = ($Calls | Where-Object { $_ -like 'context *' } | Select-Object -Last 1)
            Subscriptions = ($Calls | Where-Object { $_ -like 'subscriptions *' } | Select-Object -Last 1)
        }
    }

    $script:Sp = @{ TenantID = $script:TenantA; Appid = $script:AppId; Secret = $true }
    $script:Mi = @{ TenantID = $script:TenantA; UseManagedIdentity = $true }
}

Describe 'Service principal and managed identity never fall back to a cached user' {

    AfterEach { $script:Run.AzCalls.Count | Should -Be 0 }

    It 'stops with exit 1 when the service principal sign-in throws while a user is cached on the tenant' {
        $script:Run = Invoke-SignIn -Params $script:Sp -Sim @{ PsTenant = $script:TenantA; ConnectThrows = $true }

        $script:Run.ExitCode | Should -Be 1
        $script:Run.Connects.Count | Should -Be 1
        $script:Run.Connects[0] | Should -Match '-ServicePrincipal'
        $script:Run.Returned | Should -BeFalse
        $script:Run.Listed.Count | Should -Be 0 -Because 'nothing is collected as the cached user'
        $script:Run.Output | Should -Match 'service principal sign-in failed'
    }

    It 'stops with exit 1 when the managed identity sign-in throws while a user is cached on the tenant' {
        $script:Run = Invoke-SignIn -Params $script:Mi -Sim @{ PsTenant = $script:TenantA; ConnectThrows = $true }

        $script:Run.ExitCode | Should -Be 1
        $script:Run.Connects.Count | Should -Be 1
        $script:Run.Connects[0] | Should -Match '-Identity'
        $script:Run.Returned | Should -BeFalse
        $script:Run.Listed.Count | Should -Be 0
    }

    It 'stops with exit 1 when the context is still the cached user after the service principal sign-in' {
        $script:Run = Invoke-SignIn -Params $script:Sp -Sim @{ PsTenant = $script:TenantA; ConnectLeavesContext = $true }

        $script:Run.ExitCode | Should -Be 1
        $script:Run.Returned | Should -BeFalse
        $script:Run.Listed.Count | Should -Be 0
        $script:Run.Output | Should -Match 'not that identity'
    }

    It 'stops with exit 1 when the context is still the cached user after the managed identity sign-in' {
        $script:Run = Invoke-SignIn -Params $script:Mi -Sim @{ PsTenant = $script:TenantA; ConnectLeavesContext = $true }

        $script:Run.ExitCode | Should -Be 1
        $script:Run.Returned | Should -BeFalse
        $script:Run.Listed.Count | Should -Be 0
    }

    It 'collects as the service principal when its sign-in works, even with a user cached' {
        $script:Run = Invoke-SignIn -Params $script:Sp -Sim @{ PsTenant = $script:TenantA }

        $script:Run.ExitCode | Should -Be 0
        $script:Run.Context | Should -Be ('context {0} ServicePrincipal' -f $script:TenantA)
        $script:Run.Subscriptions | Should -Be ('subscriptions {0}' -f $script:TenantA)
    }
}

Describe 'Azure Cloud Shell uses the same sign-in rules' {

    AfterEach {
        $script:Run.AzCalls.Count | Should -Be 0
        $script:Run.Calls | Should -Not -Contain 'Disconnect-AzAccount'
    }

    It 'reuses Cloud Shell''s usable sign-in with no prompt' {
        $script:Run = Invoke-SignIn -Entry CloudShell -Sim @{ PsTenant = $script:TenantA }

        $script:Run.ExitCode | Should -Be 0
        $script:Run.Calls | Should -Contain 'platform Azure CloudShell'
        $script:Run.Connects.Count | Should -Be 0
        $script:Run.Calls | Should -Contain ('probe {0}' -f $script:TenantA) -Because 'the cached token is probed in Cloud Shell too'
        $script:Run.Subscriptions | Should -Be ('subscriptions {0}' -f $script:TenantA)
    }

    It 'signs in once when Cloud Shell''s sign-in cannot acquire a token' {
        $script:Run = Invoke-SignIn -Entry CloudShell -Sim @{ PsTenant = $script:TenantA; PsTokenOk = $false }

        $script:Run.ExitCode | Should -Be 0
        $script:Run.Connects | Should -Be @(('Connect-AzAccount -Tenant {0}' -f $script:TenantA))
        $script:Run.Subscriptions | Should -Be ('subscriptions {0}' -f $script:TenantA)
    }

    It 'signs in once with the device code when Cloud Shell''s sign-in is stale and -DeviceLogin is given' {
        $script:Run = Invoke-SignIn -Entry CloudShell -Params @{ DeviceLogin = $true } -Sim @{ PsTenant = $script:TenantA; PsTokenOk = $false }

        $script:Run.ExitCode | Should -Be 0
        $script:Run.Connects | Should -Be @(('Connect-AzAccount -UseDeviceAuthentication -Tenant {0}' -f $script:TenantA))
    }

    It 'stops with exit 1 when Cloud Shell''s sign-in is stale and the one sign-in gives no token either' {
        $script:Run = Invoke-SignIn -Entry CloudShell -Sim @{ PsTenant = $script:TenantA; PsTokenOk = $false; ConnectNoToken = $true }

        $script:Run.ExitCode | Should -Be 1
        $script:Run.Connects.Count | Should -Be 1
        $script:Run.Returned | Should -BeFalse
    }

    It 'signs in to -TenantID once when Cloud Shell is on another tenant it cannot reach silently' {
        $script:Run = Invoke-SignIn -Entry CloudShell -Params @{ TenantID = $script:TenantB } -Sim @{ PsTenant = $script:TenantA }

        $script:Run.ExitCode | Should -Be 0
        $script:Run.Connects | Should -Be @(('Connect-AzAccount -Tenant {0}' -f $script:TenantB))
        $script:Run.Context | Should -Be ('context {0} User' -f $script:TenantB)
        $script:Run.Subscriptions | Should -Be ('subscriptions {0}' -f $script:TenantB)
    }

    It 'signs in as the service principal in Cloud Shell, not as Cloud Shell''s user' {
        $script:Run = Invoke-SignIn -Entry CloudShell -Params $script:Sp -Sim @{ PsTenant = $script:TenantA }

        $script:Run.ExitCode | Should -Be 0
        $script:Run.Connects.Count | Should -Be 1
        $script:Run.Connects[0] | Should -Match '-ServicePrincipal.*-Scope Process'
        $script:Run.Context | Should -Be ('context {0} ServicePrincipal' -f $script:TenantA)
    }

    It 'stops with exit 1 in Cloud Shell when the service principal sign-in throws' {
        $script:Run = Invoke-SignIn -Entry CloudShell -Params $script:Sp -Sim @{ PsTenant = $script:TenantA; ConnectThrows = $true }

        $script:Run.ExitCode | Should -Be 1
        $script:Run.Returned | Should -BeFalse
        $script:Run.Listed.Count | Should -Be 0
    }

    It 'signs in with the managed identity in Cloud Shell when -UseManagedIdentity is given' {
        $script:Run = Invoke-SignIn -Entry CloudShell -Params $script:Mi -Sim @{ PsTenant = $script:TenantA }

        $script:Run.ExitCode | Should -Be 0
        $script:Run.Connects.Count | Should -Be 1
        $script:Run.Connects[0] | Should -Match '-Identity'
        $script:Run.Context | Should -Be ('context {0} ManagedService' -f $script:TenantA)
    }
}

Describe 'The context must be on the target tenant' {

    AfterEach { $script:Run.AzCalls.Count | Should -Be 0 }

    It 'switches this process to -TenantID with no prompt when the cached account reaches it silently' {
        $script:Run = Invoke-SignIn -Params @{ TenantID = $script:TenantB } -Sim @{ PsTenant = $script:TenantA; PsReach = @($script:TenantA, $script:TenantB) }

        $script:Run.ExitCode | Should -Be 0
        $script:Run.Connects.Count | Should -Be 0 -Because 'the cached account already gets a token for the tenant'
        $script:Run.SetContexts | Should -Be @(('Set-AzContext {0} Process' -f $script:TenantB))
        $script:Run.Context | Should -Be ('context {0} User' -f $script:TenantB)
        $script:Run.Subscriptions | Should -Be ('subscriptions {0}' -f $script:TenantB)
    }

    It 'signs in once when the silent switch does not move the context' {
        $script:Run = Invoke-SignIn -Params @{ TenantID = $script:TenantB } -Sim @{ PsTenant = $script:TenantA; PsReach = @($script:TenantA, $script:TenantB); SetContextIgnored = $true }

        $script:Run.ExitCode | Should -Be 0
        $script:Run.Connects | Should -Be @(('Connect-AzAccount -Tenant {0}' -f $script:TenantB))
        $script:Run.Context | Should -Be ('context {0} User' -f $script:TenantB)
    }

    It 'stops with exit 1 when the context stays on another tenant after the sign-in, although a token for the target can be acquired' {
        $script:Run = Invoke-SignIn -Params @{ TenantID = $script:TenantB } -Sim @{ PsTenant = $script:TenantA; PsReach = @($script:TenantA, $script:TenantB); SetContextIgnored = $true; ConnectLeavesContext = $true }

        $script:Run.ExitCode | Should -Be 1
        $script:Run.Connects.Count | Should -Be 1 -Because 'one sign-in, never a second prompt'
        $script:Run.Returned | Should -BeFalse
        $script:Run.Listed.Count | Should -Be 0 -Because 'the other tenant is not collected'
        $script:Run.Output | Should -Match 'not on tenant'
    }

    It 'stops with exit 1 when the context does not move to the tenant picked after a fresh sign-in' {
        $script:Run = Invoke-SignIn -Answers @('2') -Sim @{ Tenants = @($script:TenantA, $script:TenantB); HomeTenant = $script:Sorted[0]; SetContextIgnored = $true }

        $script:Run.ExitCode | Should -Be 1
        $script:Run.Connects.Count | Should -Be 1
        $script:Run.Returned | Should -BeFalse
    }

    It 'reuses a cached sign-in on a tenant given by domain, with no prompt' {
        $script:Run = Invoke-SignIn -Params @{ TenantID = 'contoso.example' } -Sim @{ PsTenant = $script:TenantA; Domains = @{ 'contoso.example' = $script:TenantA } }

        $script:Run.ExitCode | Should -Be 0
        $script:Run.Connects.Count | Should -Be 0
        $script:Run.Subscriptions | Should -Be ('subscriptions {0}' -f $script:TenantA)
    }
}

Describe 'Choosing the tenant after a fresh sign-in' {

    AfterEach { $script:Run.AzCalls.Count | Should -Be 0 }

    It 'offers the tenant a subscription is accessed through, not its home tenant (Azure Lighthouse)' {
        # The sign-in is on tenant A; tenant B manages a subscription whose
        # home tenant is C.
        $Pick = [array]::IndexOf($script:Sorted, $script:TenantB) + 1
        $script:Run = Invoke-SignIn -Answers @([string]$Pick) -Sim @{ Tenants = @($script:TenantA, $script:TenantB); HomeTenant = $script:TenantA; HomeOf = @{ $script:TenantB = $script:TenantC } }

        $script:Run.ExitCode | Should -Be 0
        $script:Run.Output | Should -Match ([regex]::Escape($script:TenantB))
        $script:Run.Output | Should -Not -Match ([regex]::Escape($script:TenantC)) -Because 'the home tenant of a delegated subscription is not a tenant the sign-in can collect'
        $script:Run.Subscriptions | Should -Be ('subscriptions {0}' -f $script:TenantB)
        $script:Run.Connects.Count | Should -Be 1
    }

    It 'stops with exit 1 when the tenant number is out of range twice' {
        $script:Run = Invoke-SignIn -Answers @('5', '7') -Sim @{ Tenants = @($script:TenantA, $script:TenantB) }

        $script:Run.ExitCode | Should -Be 1
        $script:Run.ReadHosts.Count | Should -Be 2 -Because 'asked again once, never in a loop'
        $script:Run.Connects.Count | Should -Be 1
        $script:Run.Returned | Should -BeFalse
        $script:Run.Listed.Count | Should -Be 0
    }

    It 'stops with exit 1 when the answer is not a number twice' {
        $script:Run = Invoke-SignIn -Answers @('abc', 'x') -Sim @{ Tenants = @($script:TenantA, $script:TenantB) }

        $script:Run.ExitCode | Should -Be 1
        $script:Run.ReadHosts.Count | Should -Be 2
        $script:Run.Returned | Should -BeFalse
    }

    It 'uses the second answer when the first is out of range' {
        $script:Run = Invoke-SignIn -Answers @('5', '2') -Sim @{ Tenants = @($script:TenantA, $script:TenantB) }

        $script:Run.ExitCode | Should -Be 0
        $script:Run.ReadHosts.Count | Should -Be 2
        $script:Run.Subscriptions | Should -Be ('subscriptions {0}' -f $script:Sorted[1])
    }

    It 'uses the first tenant for an empty answer' {
        $script:Run = Invoke-SignIn -Answers @('') -Sim @{ Tenants = @($script:TenantA, $script:TenantB) }

        $script:Run.ExitCode | Should -Be 0
        $script:Run.Output | Should -Match 'the browser will open' -Because 'a session with a console signs in in the browser'
        $script:Run.ReadHosts.Count | Should -Be 1
        $script:Run.Subscriptions | Should -Be ('subscriptions {0}' -f $script:Sorted[0])
    }
}

Describe 'A direct run with nothing to collect, or nobody to sign in, stops' {

    AfterEach { $script:Run.AzCalls.Count | Should -Be 0 }

    It 'stops with exit 1 when the tenant lists no subscriptions' {
        $script:Run = Invoke-SignIn -Sim @{ PsTenant = $script:TenantA; SubsOf = @{ $script:TenantA = 0 } }

        $script:Run.ExitCode | Should -Be 1
        $script:Run.Returned | Should -BeFalse
        $script:Run.Output | Should -Match 'lists no subscriptions'
    }

    It 'stops with exit 1, without opening a browser, in a session with no console and nothing signed in' {
        $script:Run = Invoke-SignIn -Interactive $false -Sim @{}

        $script:Run.ExitCode | Should -Be 1
        $script:Run.Connects.Count | Should -Be 0
        $script:Run.Returned | Should -BeFalse
        $script:Run.Output | Should -Match 'non-interactive'
        $script:Run.Output | Should -Not -Match 'the browser will open' -Because 'no browser is opened'
    }

    It 'stops with exit 1, without opening a browser, in a session with no console when the cached sign-in is stale' {
        $script:Run = Invoke-SignIn -Interactive $false -Sim @{ PsTenant = $script:TenantA; PsTokenOk = $false }

        $script:Run.ExitCode | Should -Be 1
        $script:Run.Connects.Count | Should -Be 0
    }

    It 'signs in with the device code in a session with no console when -DeviceLogin is given' {
        $script:Run = Invoke-SignIn -Interactive $false -Params @{ DeviceLogin = $true } -Sim @{}

        $script:Run.ExitCode | Should -Be 0
        $script:Run.Connects | Should -Be @('Connect-AzAccount -UseDeviceAuthentication')
    }
}
