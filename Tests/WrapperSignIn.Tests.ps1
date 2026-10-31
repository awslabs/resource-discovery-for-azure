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
# No live Azure: Az cmdlets are shims and Pester mocks.
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

Describe 'Run-AllSubscriptions.ps1 sign-in gate' {

    It 'signs in through Connect-RdaWrapperSession and stops with exit 1 when it throws' {
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepoRoot 'Run-AllSubscriptions.ps1'), [ref]$null, [ref]$null)
        $Gate = $Ast.FindAll({
                param($Node)
                $Node -is [System.Management.Automation.Language.TryStatementAst] -and
                @($Node.Body.FindAll({ param($C) $C -is [System.Management.Automation.Language.CommandAst] -and $C.GetCommandName() -eq 'Connect-RdaWrapperSession' }, $true)).Count -gt 0
            }, $false) | Select-Object -First 1
        $Gate | Should -Not -BeNullOrEmpty
        $Gate.CatchClauses[0].Body.Extent.Text | Should -Match 'Exit-Wrapper -Code 1'
    }
}
