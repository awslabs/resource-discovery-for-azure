# =============================================================================
# WrapperSignIn.Tests.ps1
#
# Offline tests for the sign-in gate of Run-AllSubscriptions.ps1
# (Connect-RdaWrapperSession in Functions/Common.Functions.ps1).
#
# WHY THIS TEST EXISTS
# --------------------
# The wrapper signs in with Az PowerShell only, once, before it starts
# ResourceInventory.ps1 for each subscription. An existing sign-in that is on
# -TenantID and can still acquire a token silently is reused with no prompt
# (Cloud Shell, a second run). Otherwise it signs in once (device code with
# -DeviceLogin) and checks the token again; when the token still fails it
# throws, and the wrapper stops with exit 1 instead of prompting a second
# time or collecting an empty inventory. A usable context is never
# disconnected.
#
# No live Azure: Az cmdlets are shims and Pester mocks, and the gate test runs
# the real wrapper as its own process with stand-in Az modules.
# Run with: Invoke-Pester ./Tests/WrapperSignIn.Tests.ps1 -Output Detailed
# =============================================================================

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:RepoRoot 'Functions/Common.Functions.ps1')

    function Get-AzContext { [CmdletBinding()] param() }
    function Get-AzAccessToken { [CmdletBinding()] param([string]$TenantId, [string]$ResourceUrl) }
    function Connect-AzAccount { [CmdletBinding()] param([string]$Tenant, [switch]$UseDeviceAuthentication) }
    function Disconnect-AzAccount { [CmdletBinding()] param() }
    function az { $script:AzCalls++ }

    $script:Tenant = [guid]::NewGuid().ToString()
    $script:Other = [guid]::NewGuid().ToString()
}

Describe 'Connect-RdaWrapperSession' {

    BeforeEach {
        $script:AzCalls = 0
        $script:Sim = @{ Tenant = $null; TokenOk = $false; SignInGivesToken = $true; SignInFails = $false }
        Mock Get-AzContext { if ($script:Sim.Tenant) { [pscustomobject]@{ Account = [pscustomobject]@{ Id = 'user' }; Tenant = [pscustomobject]@{ Id = $script:Sim.Tenant } } } }
        Mock Get-AzAccessToken { if ($script:Sim.TokenOk -and $TenantId -eq $script:Sim.Tenant) { [pscustomobject]@{ Token = 'token' } } else { throw 'User interaction is required.' } }
        Mock Connect-AzAccount {
            if ($script:Sim.SignInFails) { throw 'sign-in was cancelled' }
            $script:Sim.Tenant = $Tenant
            $script:Sim.TokenOk = $script:Sim.SignInGivesToken
        }
        Mock Disconnect-AzAccount { }
        Mock Write-Host { }
        # A console to sign in from, unless a case says otherwise.
        Mock Test-RdaInteractiveSession { $true }
    }

    AfterEach {
        $script:AzCalls | Should -Be 0 -Because 'the Azure CLI is not used'
        Should -Invoke Disconnect-AzAccount -Times 0 -Exactly
    }

    It 'reuses a usable sign-in on the tenant with no prompt' {
        $script:Sim.Tenant = $script:Tenant
        $script:Sim.TokenOk = $true

        Connect-RdaWrapperSession -TenantID $script:Tenant

        Should -Invoke Connect-AzAccount -Times 0 -Exactly
    }

    It 'signs in once to the tenant when nothing is signed in' {
        Connect-RdaWrapperSession -TenantID $script:Tenant

        Should -Invoke Connect-AzAccount -Times 1 -Exactly
        Should -Invoke Connect-AzAccount -Times 1 -Exactly -ParameterFilter { $Tenant -eq $script:Tenant -and -not $UseDeviceAuthentication }
    }

    It 'signs in once to the tenant when the sign-in is on another tenant' {
        $script:Sim.Tenant = $script:Other
        $script:Sim.TokenOk = $true

        Connect-RdaWrapperSession -TenantID $script:Tenant

        Should -Invoke Connect-AzAccount -Times 1 -Exactly -ParameterFilter { $Tenant -eq $script:Tenant }
    }

    It 'signs in once when the cached sign-in cannot acquire a token' {
        $script:Sim.Tenant = $script:Tenant
        $script:Sim.TokenOk = $false

        Connect-RdaWrapperSession -TenantID $script:Tenant

        Should -Invoke Connect-AzAccount -Times 1 -Exactly
    }

    It 'uses device code sign-in with -DeviceLogin' {
        Connect-RdaWrapperSession -TenantID $script:Tenant -DeviceLogin

        Should -Invoke Connect-AzAccount -Times 1 -Exactly -ParameterFilter { $UseDeviceAuthentication.IsPresent -and $Tenant -eq $script:Tenant }
    }

    It 'throws after one sign-in when the token still fails' {
        $script:Sim.SignInGivesToken = $false

        { Connect-RdaWrapperSession -TenantID $script:Tenant } | Should -Throw -ExpectedMessage '*did not give a usable token*'
        Should -Invoke Connect-AzAccount -Times 1 -Exactly -Because 'never a second prompt in one run'
    }

    It 'stops without opening a browser when there is no console and no -DeviceLogin' {
        Mock Test-RdaInteractiveSession { $false }

        { Connect-RdaWrapperSession -TenantID $script:Tenant } | Should -Throw -ExpectedMessage '*no console to sign in from*'
        Should -Invoke Connect-AzAccount -Times 0 -Exactly
    }

    It 'still reuses a usable sign-in when there is no console' {
        Mock Test-RdaInteractiveSession { $false }
        $script:Sim.Tenant = $script:Tenant
        $script:Sim.TokenOk = $true

        Connect-RdaWrapperSession -TenantID $script:Tenant

        Should -Invoke Connect-AzAccount -Times 0 -Exactly
    }

    It 'uses device code sign-in with -DeviceLogin when there is no console' {
        Mock Test-RdaInteractiveSession { $false }

        Connect-RdaWrapperSession -TenantID $script:Tenant -DeviceLogin

        Should -Invoke Connect-AzAccount -Times 1 -Exactly -ParameterFilter { $UseDeviceAuthentication.IsPresent }
    }

    It 'throws after one attempt when the sign-in itself fails' {
        $script:Sim.SignInFails = $true

        { Connect-RdaWrapperSession -TenantID $script:Tenant } | Should -Throw
        Should -Invoke Connect-AzAccount -Times 1 -Exactly
    }
}

Describe 'Run-AllSubscriptions.ps1 sign-in gate' -Skip:$IsWindows {

    # The REAL wrapper as its own pwsh process (stdin closed), from a copy of
    # the tool, with stand-in Az modules first on PSModulePath and a scratch
    # home (the wrapper writes under $HOME/InventoryReports, so not on
    # Windows). Nothing is signed in and the one sign-in Connect-RdaWrapperSession
    # makes throws, so Connect-RdaWrapperSession throws. Every Azure call
    # after the gate, and the start of an inventory run (the stand-in
    # Az.Compute loads only there), is written to a call log.
    BeforeAll {
        $script:GateDir = Join-Path ([System.IO.Path]::GetTempPath()) ('WrapperSignIn_' + [guid]::NewGuid().ToString('N'))
        $script:GateTool = Join-Path $script:GateDir 'tool'
        New-Item -ItemType Directory -Path $script:GateTool -Force | Out-Null
        foreach ($Item in @('Run-AllSubscriptions.ps1', 'Run-AllSubscriptions.Stream.ps1', 'ResourceInventory.ps1', 'Version.json', 'Functions', 'Extension', 'Services'))
        {
            Copy-Item -LiteralPath (Join-Path $script:RepoRoot $Item) -Destination $script:GateTool -Recurse -Force
        }
        $Accounts = @'
# Skips the online version check and the environment check, as the other
# wrapper harnesses do.
$Global:RdaSessionInitialized = $true
$Global:PlatformOS = 'PowerShell Unix'
function Write-RdaGateCall { param([string]$Name) Add-Content -LiteralPath $env:RDA_GATE_CALLS -Value $Name }
function Get-AzContext { [CmdletBinding()] param([switch]$ListAvailable) }
function Get-AzAccessToken { [CmdletBinding()] param($TenantId, $ResourceUrl, [switch]$AsSecureString) throw 'stand-in: no token' }
function Connect-AzAccount { [CmdletBinding()] param($Tenant, [switch]$UseDeviceAuthentication) Write-RdaGateCall 'Connect-AzAccount'; throw 'stand-in: sign-in was cancelled' }
function Disable-AzContextAutosave { [CmdletBinding()] param($Scope) }
function Get-AzContextAutosaveSetting { [CmdletBinding()] param($Scope) [pscustomobject]@{ Mode = 'Process'; ContextFile = 'None'; CacheFile = 'None' } }
function Get-AzSubscription { [CmdletBinding()] param($TenantId, $SubscriptionId, $SubscriptionName) Write-RdaGateCall 'Get-AzSubscription' }
function Set-AzContext { [CmdletBinding()] param($Subscription, $Tenant, $Context, $Scope) Write-RdaGateCall 'Set-AzContext' }
function Invoke-AzRestMethod { [CmdletBinding()] param($Method, $Path, $Payload, $Uri) Write-RdaGateCall 'Invoke-AzRestMethod' }
'@
        $script:GateModules = Join-Path $script:GateDir 'modules'
        foreach ($Module in @(@{ Name = 'Az.Accounts'; Body = $Accounts }, @{ Name = 'Az.Compute'; Body = 'Add-Content -LiteralPath $env:RDA_GATE_CALLS -Value ''inventory''' }, @{ Name = 'Az.Monitor'; Body = '' }, @{ Name = 'Az.Billing'; Body = '' }))
        {
            $Dir = Join-Path $script:GateModules (Join-Path $Module.Name '99.0.0')
            New-Item -ItemType Directory -Path $Dir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $Dir ($Module.Name + '.psm1')) -Value $Module.Body -Encoding utf8
            Set-Content -LiteralPath (Join-Path $Dir ($Module.Name + '.psd1')) -Value ("@{{ ModuleVersion = '99.0.0'; RootModule = '{0}.psm1'; FunctionsToExport = '*' }}" -f $Module.Name) -Encoding utf8
        }
    }

    AfterAll {
        if ($script:GateDir -and (Test-Path -LiteralPath $script:GateDir)) { Remove-Item -LiteralPath $script:GateDir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'stops with exit 1 when Connect-RdaWrapperSession throws, before any subscription query or inventory run' {
        $CaseHome = Join-Path $script:GateDir 'home'
        New-Item -ItemType Directory -Path $CaseHome -Force | Out-Null
        $Calls = Join-Path $script:GateDir 'calls.log'
        $Info = [System.Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh'))
        foreach ($Arg in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', (Join-Path $script:GateTool 'Run-AllSubscriptions.ps1'), '-TenantID', $script:Tenant, '-DeviceLogin', '-SkipMetrics', '-SkipConsumption', '-ParallelStreams', '1')) { $Info.ArgumentList.Add($Arg) }
        $Info.UseShellExecute = $false
        $Info.RedirectStandardInput = $true
        $Info.RedirectStandardOutput = $true
        $Info.RedirectStandardError = $true
        $Info.WorkingDirectory = $script:GateTool
        $Info.Environment['HOME'] = $CaseHome
        $Info.Environment['PSModulePath'] = $script:GateModules
        $Info.Environment['RDA_GATE_CALLS'] = $Calls
        $Info.Environment['NO_COLOR'] = '1'
        $Info.Environment['POWERSHELL_TELEMETRY_OPTOUT'] = '1'
        $Proc = [System.Diagnostics.Process]::Start($Info)
        $Proc.StandardInput.Close()
        $Out = $Proc.StandardOutput.ReadToEndAsync()
        $Err = $Proc.StandardError.ReadToEndAsync()
        if (-not $Proc.WaitForExit(120000)) { $Proc.Kill($true); throw 'The wrapper run did not end within 120 seconds.' }
        $Proc.WaitForExit()
        $Console = $Out.Result + $Err.Result
        $Logged = @(if (Test-Path -LiteralPath $Calls) { Get-Content -LiteralPath $Calls })

        $Logged | Should -Contain 'Connect-AzAccount' -Because 'the gate made its one sign-in'
        $Console | Should -Match 'ERROR: Authentication failed\. .*stand-in: sign-in was cancelled' -Because $Console
        $Logged | Should -Not -Contain 'Get-AzSubscription' -Because 'no subscription is listed after the gate stops'
        $Logged | Should -Not -Contain 'Invoke-AzRestMethod' -Because $Console
        $Logged | Should -Not -Contain 'Set-AzContext' -Because $Console
        $Logged | Should -Not -Contain 'inventory' -Because 'no inventory run starts'
        @($Logged | Where-Object { $_ -eq 'Connect-AzAccount' }).Count | Should -Be 1 -Because 'one sign-in, no second prompt'
        $Proc.ExitCode | Should -Be 1 -Because $Console
    }
}
