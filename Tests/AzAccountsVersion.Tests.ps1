# =============================================================================
# AzAccountsVersion.Tests.ps1
#
# Offline tests that both entry points ask for Az.Accounts 5.5.4 or newer
# before any Azure call.
#
# WHY THIS TEST EXISTS
# --------------------
# Az.Accounts 5.5.4 is the version this tool was tested with live. An older
# Az.Accounts on disk, or an older one already loaded in the session (an
# older loaded Az.Accounts wins in-process, its assemblies cannot be
# swapped), must stop the run with the found version, the needed version and
# the exact command that fixes it. That command is the way out: once it has
# run, the next run passes the check, so the stop can never repeat on its own.
#
# HOW
# ---
# 1. Test-RdaAzAccountsVersion (Functions/AzModules.Functions.ps1) with
#    Get-Module mocked: older, equal, newer, missing, several installed,
#    older already loaded.
# 2. Install-RdaAzSubModule with Install-Module mocked: the wrapper's
#    auto-install asks for Az.Accounts 5.5.4 or newer.
# 3. The REAL ResourceInventory.ps1 and Run-AllSubscriptions.ps1 in a child
#    pwsh with stand-ins for Get-Module, Import-Module and Install-Module
#    (Az modules only). Every Azure cmdlet the run could reach first records
#    the call and ends the run with exit 7. No live Azure.
# 4. A submodule whose manifest asks for an older Az.Accounts, with real
#    empty modules on a scratch PSModulePath and one pwsh per session: the
#    stop names it and its update command, and the sessions after the update
#    (or after an old copy found first is removed) pass.
#
# Run with: Invoke-Pester ./Tests/AzAccountsVersion.Tests.ps1 -Output Detailed
# =============================================================================

BeforeAll {
    $script:RepoRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' | Resolve-Path | Select-Object -ExpandProperty Path
    $script:AzModulesFile = Join-Path $script:RepoRoot 'Functions/AzModules.Functions.ps1'
    if (Test-Path -LiteralPath $script:AzModulesFile) { . $script:AzModulesFile }

    function New-FakeModule
    {
        param([string]$Version)
        [pscustomobject]@{ Name = 'Az.Accounts'; Version = [version]$Version }
    }
}

Describe 'Test-RdaAzAccountsVersion' {

    It 'holds the one minimum version, 5.5.4' {
        Get-RdaAzAccountsMinimumVersion | Should -Be ([version]'5.5.4')
    }

    It 'stops on an older installed version and prints found, needed and the install command' {
        Mock Get-Module -ParameterFilter { $ListAvailable } -MockWith { New-FakeModule '5.5.3' }
        Mock Get-Module -ParameterFilter { -not $ListAvailable } -MockWith { }

        $Result = Test-RdaAzAccountsVersion

        $Result.Status | Should -Be 'TooOld'
        $Result.Installed | Should -Be ([version]'5.5.3')
        $Text = $Result.Messages -join "`n"
        $Text | Should -Match 'Az\.Accounts 5\.5\.3 is installed'
        $Text | Should -Match 'needs Az\.Accounts 5\.5\.4 or newer'
        $Text | Should -Match ([regex]::Escape('Install-Module -Name Az.Accounts -MinimumVersion 5.5.4'))
        $Text | Should -Match '-Scope CurrentUser'
    }

    It 'passes on exactly 5.5.4' {
        Mock Get-Module -ParameterFilter { $ListAvailable } -MockWith { New-FakeModule '5.5.4' }
        Mock Get-Module -ParameterFilter { -not $ListAvailable } -MockWith { }

        $Result = Test-RdaAzAccountsVersion

        $Result.Status | Should -Be 'Ok'
        $Result.Messages | Should -BeNullOrEmpty
    }

    It 'passes on a newer version' {
        Mock Get-Module -ParameterFilter { $ListAvailable } -MockWith { New-FakeModule '6.1.0' }
        Mock Get-Module -ParameterFilter { -not $ListAvailable } -MockWith { }

        (Test-RdaAzAccountsVersion).Status | Should -Be 'Ok'
    }

    It 'stops when Az.Accounts is not installed and prints the install command' {
        Mock Get-Module -ParameterFilter { $ListAvailable } -MockWith { }
        Mock Get-Module -ParameterFilter { -not $ListAvailable } -MockWith { }

        $Result = Test-RdaAzAccountsVersion

        $Result.Status | Should -Be 'Missing'
        $Result.Installed | Should -BeNullOrEmpty
        $Text = $Result.Messages -join "`n"
        $Text | Should -Match 'Az\.Accounts is not installed'
        $Text | Should -Match ([regex]::Escape('Install-Module -Name Az.Accounts -MinimumVersion 5.5.4'))
    }

    It 'picks the highest version when several are installed, in any order' {
        Mock Get-Module -ParameterFilter { $ListAvailable } -MockWith { New-FakeModule '5.5.3'; New-FakeModule '5.10.0'; New-FakeModule '5.2.0' }
        Mock Get-Module -ParameterFilter { -not $ListAvailable } -MockWith { }

        $Result = Test-RdaAzAccountsVersion

        $Result.Status | Should -Be 'Ok'
        $Result.Installed | Should -Be ([version]'5.10.0') -Because '5.10.0 is newer than 5.5.3 as a version, not as text'
    }

    It 'stops when every installed version is older' {
        Mock Get-Module -ParameterFilter { $ListAvailable } -MockWith { New-FakeModule '5.5.3'; New-FakeModule '4.0.2' }
        Mock Get-Module -ParameterFilter { -not $ListAvailable } -MockWith { }

        $Result = Test-RdaAzAccountsVersion

        $Result.Status | Should -Be 'TooOld'
        $Result.Installed | Should -Be ([version]'5.5.3')
    }

    It 'stops when an older Az.Accounts is already loaded, even with a good one installed, and says to start a new session' {
        Mock Get-Module -ParameterFilter { $ListAvailable } -MockWith { New-FakeModule '5.5.4' }
        Mock Get-Module -ParameterFilter { -not $ListAvailable } -MockWith { New-FakeModule '5.5.3' }

        $Result = Test-RdaAzAccountsVersion

        $Result.Status | Should -Be 'LoadedTooOld'
        $Result.Loaded | Should -Be ([version]'5.5.3')
        $Text = $Result.Messages -join "`n"
        $Text | Should -Match 'Az\.Accounts 5\.5\.3 is already loaded'
        $Text | Should -Match 'new PowerShell session'
        $Text | Should -Not -Match 'Install-Module' -Because 'a good version is already installed; only a new session is needed'
    }

    It 'says to sign in again in the new session, since pwsh -NoProfile drops a profile''s sign-in' {
        Mock Get-Module -ParameterFilter { $ListAvailable } -MockWith { New-FakeModule '5.5.4' }
        Mock Get-Module -ParameterFilter { -not $ListAvailable } -MockWith { New-FakeModule '5.5.3' }

        $Messages = @((Test-RdaAzAccountsVersion).Messages)

        $NoProfile = [array]::FindIndex([string[]]$Messages, [Predicate[string]] { param($m) $m -match 'pwsh -NoProfile' })
        $SignIn = [array]::FindIndex([string[]]$Messages, [Predicate[string]] { param($m) $m -match 'sign in first' })
        $NoProfile | Should -BeGreaterOrEqual 0
        $SignIn | Should -BeGreaterThan $NoProfile -Because 'the sign-in step follows the new-session advice'
        $Messages[$SignIn] | Should -Match ([regex]::Escape('Connect-AzAccount'))
        $Messages[$SignIn] | Should -Match ([regex]::Escape('Connect-AzAccount -Identity'))
        $Messages[$SignIn] | Should -Match 'then run again'
        (Get-RdaAzAccountsMinimumVersion) | Should -Be ([version]'5.5.4') -Because 'the supported version stays 5.5.4'
    }

    It 'gives the install command and the new-session advice when the loaded and installed versions are both older' {
        Mock Get-Module -ParameterFilter { $ListAvailable } -MockWith { New-FakeModule '5.5.3' }
        Mock Get-Module -ParameterFilter { -not $ListAvailable } -MockWith { New-FakeModule '5.5.3' }

        $Result = Test-RdaAzAccountsVersion

        $Result.Status | Should -Be 'LoadedTooOld'
        $Text = $Result.Messages -join "`n"
        $Text | Should -Match ([regex]::Escape('Install-Module -Name Az.Accounts -MinimumVersion 5.5.4'))
        $Text | Should -Match 'new PowerShell session'
    }

    It 'passes when a good version is already loaded' {
        Mock Get-Module -ParameterFilter { $ListAvailable } -MockWith { New-FakeModule '5.5.4' }
        Mock Get-Module -ParameterFilter { -not $ListAvailable } -MockWith { New-FakeModule '5.5.4' }

        (Test-RdaAzAccountsVersion).Status | Should -Be 'Ok'
    }
}

Describe 'A submodule that asks for an older Az.Accounts' -Skip:$IsWindows {

    # Real modules on a scratch PSModulePath, no mocks: Az.Accounts 5.5.3 and
    # 5.5.4, and an Az.Compute 1.0.0 whose manifest asks for exactly 5.5.3.
    # Each session is its own pwsh, as a user opening a new one. Not on
    # Windows, where the user's module folder is not under HOME.
    BeforeAll {
        $script:PinDir = Join-Path ([System.IO.Path]::GetTempPath()) ('AzAccountsPin_' + [guid]::NewGuid().ToString('N'))
        function script:New-PinModule
        {
            param([string]$Root, [string]$Name, [string]$Version, [string]$Requires = '')
            $Dir = Join-Path $Root (Join-Path $Name $Version)
            New-Item -ItemType Directory -Path $Dir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $Dir ($Name + '.psm1')) -Value '' -Encoding utf8
            $Req = if ($Requires) { "; RequiredModules = @($Requires)" } else { '' }
            Set-Content -LiteralPath (Join-Path $Dir ($Name + '.psd1')) -Value ("@{{ ModuleVersion = '{0}'; RootModule = '{1}.psm1'; FunctionsToExport = @(){2} }}" -f $Version, $Name, $Req) -Encoding utf8
        }
        $script:First = Join-Path $script:PinDir 'first'
        $script:Second = Join-Path $script:PinDir 'second'
        New-PinModule -Root $script:Second -Name 'Az.Accounts' -Version '5.5.3'
        New-PinModule -Root $script:Second -Name 'Az.Accounts' -Version '5.5.4'
        New-PinModule -Root $script:Second -Name 'Az.Compute' -Version '1.0.0' -Requires "@{ ModuleName = 'Az.Accounts'; RequiredVersion = '5.5.3' }"

        # One new session: loads the modules as ResourceInventory.ps1 does,
        # then runs the check after the import. -Preload first loads that
        # Az.Accounts version, as a profile or an older tool does.
        $script:PinSession = Join-Path $script:PinDir 'session.ps1'
        @'
param([string]$Functions, [string]$Preload = '', [string]$PreloadCompute = '')
. $Functions
if ($Preload) { Import-Module Az.Accounts -RequiredVersion $Preload -ErrorAction Stop | Out-Null }
if ($PreloadCompute) { Import-Module Az.Compute -RequiredVersion $PreloadCompute -ErrorAction Stop | Out-Null }
Import-Module Az.Accounts -MinimumVersion (Get-RdaAzAccountsMinimumVersion) -ErrorAction Stop | Out-Null
Import-Module Az.Compute -ErrorAction Stop | Out-Null
Test-RdaAzAccountsVersion -SubModule @('Az.Accounts', 'Az.Compute', 'Az.Monitor') | ConvertTo-Json -Depth 4
'@ | Set-Content -LiteralPath $script:PinSession -Encoding utf8
        # The check alone, before any Az module is loaded, as the wrapper and
        # ResourceInventory.ps1 run it first. A -PreloadCompute that is a full
        # path loads the Az.Compute copy in that folder, as a profile that
        # imports it by path does.
        $script:CheckSession = Join-Path $script:PinDir 'check.ps1'
        @'
param([string]$Functions, [string]$Preload = '', [string]$PreloadCompute = '')
. $Functions
if ($Preload) { Import-Module Az.Accounts -RequiredVersion $Preload -ErrorAction Stop | Out-Null }
if ($PreloadCompute -and [System.IO.Path]::IsPathRooted($PreloadCompute)) { Import-Module $PreloadCompute -ErrorAction Stop | Out-Null }
elseif ($PreloadCompute) { Import-Module Az.Compute -RequiredVersion $PreloadCompute -ErrorAction Stop | Out-Null }
Test-RdaAzAccountsVersion -SubModule @('Az.Accounts', 'Az.Compute', 'Az.Monitor') | ConvertTo-Json -Depth 4
'@ | Set-Content -LiteralPath $script:CheckSession -Encoding utf8
        function script:Invoke-PinSession
        {
            param([string[]]$ModulePath, [string]$Preload = '', [string]$PreloadCompute = '', [switch]$CheckOnly)
            $Old = $env:PSModulePath
            $OldHome = $env:HOME
            $OldData = $env:XDG_DATA_HOME
            try
            {
                $env:PSModulePath = $ModulePath -join [System.IO.Path]::PathSeparator
                # pwsh puts the user's own module folder (under HOME, or
                # Documents on Windows) in front of PSModulePath; a scratch
                # home keeps the host's real Az modules out.
                $env:HOME = Join-Path $script:PinDir 'home'
                $env:XDG_DATA_HOME = Join-Path $env:HOME '.local/share'
                $Json = & (Join-Path $PSHOME 'pwsh') -NoProfile -NonInteractive -File $(if ($CheckOnly) { $script:CheckSession } else { $script:PinSession }) -Functions $script:AzModulesFile -Preload $Preload -PreloadCompute $PreloadCompute | Out-String
            }
            finally
            {
                $env:PSModulePath = $Old
                $env:HOME = $OldHome
                $env:XDG_DATA_HOME = $OldData
            }
            $Result = $Json | ConvertFrom-Json
            [pscustomobject]@{ Status = [string]$Result.Status; Text = (@($Result.Messages) -join "`n") }
        }
    }

    AfterAll {
        if ($script:PinDir -and (Test-Path -LiteralPath $script:PinDir)) { Remove-Item -LiteralPath $script:PinDir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'names the submodule and the command that updates it, and the next sessions end once it is updated' {
        # Session 1: the pair loads and the check stops.
        $One = Invoke-PinSession -ModulePath @($script:Second)
        $One.Status | Should -Be 'LoadedTooOld' -Because $One.Text
        $One.Text | Should -Match 'Az\.Accounts 5\.5\.3 is already loaded'
        $One.Text | Should -Match ([regex]::Escape('Az.Compute 1.0.0 asks for Az.Accounts 5.5.3'))
        $One.Text | Should -Match ([regex]::Escape('Install-Module -Name Az.Compute -Repository PSGallery -Scope CurrentUser -Force'))
        $One.Text | Should -Not -Match 'Install-Module -Name Az\.Accounts' -Because 'a supported Az.Accounts is installed'
        $One.Text | Should -Match 'new PowerShell session'

        # Session 2, a new session alone: the same stop, so the advice must
        # name the update.
        (Invoke-PinSession -ModulePath @($script:Second)).Text | Should -Be $One.Text

        # Session 3, after the printed command installed a newer Az.Compute
        # (CurrentUser scope, first on the module path): the check passes.
        New-PinModule -Root $script:First -Name 'Az.Compute' -Version '2.0.0' -Requires "@{ ModuleName = 'Az.Accounts'; ModuleVersion = '5.5.4' }"
        $Three = Invoke-PinSession -ModulePath @($script:First, $script:Second)
        $Three.Status | Should -Be 'Ok' -Because $Three.Text
    }

    It 'does not name a submodule that asks only for a minimum Az.Accounts, when an older one was loaded first' {
        # Az.Compute 3.0.0 asks for Az.Accounts 5.0.0 or newer (ModuleVersion).
        # The session loads Az.Accounts 5.5.3 first, so Az.Compute binds to it,
        # but its manifest pins nothing: a new session without that first
        # load passes.
        $Root = Join-Path $script:PinDir 'minimum'
        New-PinModule -Root $Root -Name 'Az.Accounts' -Version '5.5.3'
        New-PinModule -Root $Root -Name 'Az.Accounts' -Version '5.5.4'
        New-PinModule -Root $Root -Name 'Az.Compute' -Version '3.0.0' -Requires "@{ ModuleName = 'Az.Accounts'; ModuleVersion = '5.0.0' }"

        $Stop = Invoke-PinSession -ModulePath @($Root) -Preload '5.5.3'
        $Stop.Status | Should -Be 'LoadedTooOld' -Because $Stop.Text
        $Stop.Text | Should -Match 'Az\.Accounts 5\.5\.3 is already loaded'
        $Stop.Text | Should -Not -Match 'Az\.Compute 3\.0\.0 asks for' -Because 'its manifest asks only for a minimum'
        $Stop.Text | Should -Not -Match 'Install-Module -Name Az\.Compute' -Because $Stop.Text
        $Stop.Text | Should -Not -Match 'Uninstall-Module' -Because 'removing the only Az.Compute would stop the next run on a missing module'
        $Stop.Text | Should -Match 'new PowerShell session'
        $Stop.Text | Should -Match 'pwsh -NoProfile'

        # The advice followed: a new session that does not load the old copy.
        (Invoke-PinSession -ModulePath @($Root)).Status | Should -Be 'Ok'
    }

    It 'before anything is loaded: stops on the submodule copy that would load when it pins an older Az.Accounts, and passes once it is updated' {
        $Root = Join-Path $script:PinDir 'unloaded'
        $UserFolder = Join-Path $Root 'user'
        $SystemFolder = Join-Path $Root 'system'
        New-PinModule -Root $SystemFolder -Name 'Az.Accounts' -Version '5.5.4'
        New-PinModule -Root $SystemFolder -Name 'Az.Compute' -Version '1.0.0' -Requires "@{ ModuleName = 'Az.Accounts'; RequiredVersion = '5.5.3' }"

        $Stop = Invoke-PinSession -ModulePath @($UserFolder, $SystemFolder) -CheckOnly
        $Stop.Status | Should -Be 'SubModulePinned' -Because $Stop.Text
        $Stop.Text | Should -Match ([regex]::Escape('Az.Compute 1.0.0 asks for Az.Accounts 5.5.3'))
        $Stop.Text | Should -Match ([regex]::Escape('Install-Module -Name Az.Compute -Repository PSGallery -Scope CurrentUser -Force'))
        $Stop.Text | Should -Not -Match 'Install-Module -Name Az\.Accounts' -Because 'a supported Az.Accounts is installed'

        # The printed command installs a newer Az.Compute into the user's
        # folder, first on the module path: the next run passes.
        New-PinModule -Root $UserFolder -Name 'Az.Compute' -Version '2.0.0' -Requires "@{ ModuleName = 'Az.Accounts'; ModuleVersion = '5.5.4' }"
        $Next = Invoke-PinSession -ModulePath @($UserFolder, $SystemFolder) -CheckOnly
        $Next.Status | Should -Be 'Ok' -Because $Next.Text
    }

    It 'before anything is loaded: an old pinning copy found first stops again with how to remove it, and the run after its removal passes' {
        $Root = Join-Path $script:PinDir 'unloaded-order'
        $OldFirst = Join-Path $Root 'old'
        $NewLater = Join-Path $Root 'new'
        New-PinModule -Root $NewLater -Name 'Az.Accounts' -Version '5.5.4'
        New-PinModule -Root $NewLater -Name 'Az.Compute' -Version '2.0.0' -Requires "@{ ModuleName = 'Az.Accounts'; ModuleVersion = '5.5.4' }"
        New-PinModule -Root $OldFirst -Name 'Az.Compute' -Version '1.0.0' -Requires "@{ ModuleName = 'Az.Accounts'; RequiredVersion = '5.5.3' }"

        $Stop = Invoke-PinSession -ModulePath @($OldFirst, $NewLater) -CheckOnly
        $Stop.Status | Should -Be 'SubModulePinned' -Because $Stop.Text
        $Stop.Text | Should -Match ([regex]::Escape('Uninstall-Module -Name Az.Compute -RequiredVersion 1.0.0'))

        Remove-Item -LiteralPath (Join-Path $OldFirst 'Az.Compute') -Recurse -Force
        (Invoke-PinSession -ModulePath @($OldFirst, $NewLater) -CheckOnly).Status | Should -Be 'Ok'
    }

    It 'before anything is loaded: passes for a submodule that asks only for a minimum Az.Accounts, or one older than the copy that loads' {
        $Root = Join-Path $script:PinDir 'unloaded-minimum'
        $First = Join-Path $Root 'first'
        $Later = Join-Path $Root 'later'
        New-PinModule -Root $First -Name 'Az.Accounts' -Version '5.5.4'
        New-PinModule -Root $First -Name 'Az.Compute' -Version '3.0.0' -Requires "@{ ModuleName = 'Az.Accounts'; ModuleVersion = '5.0.0' }"
        # A pinning copy in a later folder is never loaded while the first
        # folder holds one.
        New-PinModule -Root $Later -Name 'Az.Compute' -Version '9.0.0' -Requires "@{ ModuleName = 'Az.Accounts'; RequiredVersion = '5.5.3' }"
        $Check = Invoke-PinSession -ModulePath @($First, $Later) -CheckOnly
        $Check.Status | Should -Be 'Ok' -Because $Check.Text
    }

    It 'before anything is loaded: a relative first module folder (with .. and a trailing separator) is matched as PowerShell finds it' {
        # PowerShell finds 'first' from the current location and loads its
        # pinning Az.Compute 1.0.0, not the newer copy in the later folder.
        $Root = Join-Path $script:PinDir 'unloaded-relative'
        $First = Join-Path $Root 'first'
        $Later = Join-Path $Root 'later'
        New-Item -ItemType Directory -Path (Join-Path $Root 'other') -Force | Out-Null
        New-PinModule -Root $First -Name 'Az.Accounts' -Version '5.5.4'
        New-PinModule -Root $First -Name 'Az.Compute' -Version '1.0.0' -Requires "@{ ModuleName = 'Az.Accounts'; RequiredVersion = '5.5.3' }"
        New-PinModule -Root $Later -Name 'Az.Compute' -Version '2.0.0' -Requires "@{ ModuleName = 'Az.Accounts'; ModuleVersion = '5.5.4' }"
        $Relative = 'other' + [System.IO.Path]::DirectorySeparatorChar + '..' + [System.IO.Path]::DirectorySeparatorChar + 'first' + [System.IO.Path]::DirectorySeparatorChar
        Push-Location -LiteralPath $Root
        try { $Stop = Invoke-PinSession -ModulePath @($Relative, $Later) -CheckOnly }
        finally { Pop-Location }
        $Stop.Status | Should -Be 'SubModulePinned' -Because $Stop.Text
        $Stop.Text | Should -Match ([regex]::Escape('Az.Compute 1.0.0 asks for Az.Accounts 5.5.3'))
    }

    It 'an older Az.Accounts loaded first: also names an unloaded submodule copy that would load and pins it, so one stop gives all the advice' {
        # Az.Accounts 5.5.3 is loaded (a profile or an older tool), 5.5.4 is
        # installed, and the Az.Compute that would load (not loaded yet) asks
        # for exactly 5.5.3. A new session alone would stop again on that pin.
        $Root = Join-Path $script:PinDir 'loaded-unloaded-pin'
        $UserFolder = Join-Path $Root 'user'
        $SystemFolder = Join-Path $Root 'system'
        New-PinModule -Root $SystemFolder -Name 'Az.Accounts' -Version '5.5.3'
        New-PinModule -Root $SystemFolder -Name 'Az.Accounts' -Version '5.5.4'
        New-PinModule -Root $SystemFolder -Name 'Az.Compute' -Version '1.0.0' -Requires "@{ ModuleName = 'Az.Accounts'; RequiredVersion = '5.5.3' }"

        $Stop = Invoke-PinSession -ModulePath @($UserFolder, $SystemFolder) -Preload '5.5.3' -CheckOnly
        $Stop.Status | Should -Be 'LoadedTooOld' -Because $Stop.Text
        $Stop.Text | Should -Match 'Az\.Accounts 5\.5\.3 is already loaded'
        $Stop.Text | Should -Match ([regex]::Escape('Az.Compute 1.0.0 asks for Az.Accounts 5.5.3')) -Because $Stop.Text
        $Stop.Text | Should -Match ([regex]::Escape('Install-Module -Name Az.Compute -Repository PSGallery -Scope CurrentUser -Force'))
        $Stop.Text | Should -Not -Match 'Install-Module -Name Az\.Accounts' -Because 'a supported Az.Accounts is installed'
        $Stop.Text | Should -Match 'new PowerShell session'

        # The advice followed: the printed command installs a newer Az.Compute
        # into the user's folder, then a new session without the old load.
        New-PinModule -Root $UserFolder -Name 'Az.Compute' -Version '2.0.0' -Requires "@{ ModuleName = 'Az.Accounts'; ModuleVersion = '5.5.4' }"
        $Next = Invoke-PinSession -ModulePath @($UserFolder, $SystemFolder) -CheckOnly
        $Next.Status | Should -Be 'Ok' -Because $Next.Text
        $Run = Invoke-PinSession -ModulePath @($UserFolder, $SystemFolder)
        $Run.Status | Should -Be 'Ok' -Because $Run.Text
    }

    It 'an older Az.Accounts and a newer submodule loaded first: names the pinning submodule copy a new session would load, so one stop gives all the advice' {
        # The session loads Az.Accounts 5.5.3 and Az.Compute 2.0.0 (a minimum
        # only) by version, as a profile or the Az meta-module does. A new
        # session loads neither: a plain Import-Module takes Az.Compute 1.0.0
        # from the first folder, which asks for exactly 5.5.3.
        $Root = Join-Path $script:PinDir 'loaded-hides-disk-pin'
        $UserFolder = Join-Path $Root 'user'
        $SystemFolder = Join-Path $Root 'system'
        New-PinModule -Root $UserFolder -Name 'Az.Compute' -Version '1.0.0' -Requires "@{ ModuleName = 'Az.Accounts'; RequiredVersion = '5.5.3' }"
        New-PinModule -Root $SystemFolder -Name 'Az.Accounts' -Version '5.5.3'
        New-PinModule -Root $SystemFolder -Name 'Az.Accounts' -Version '5.5.4'
        New-PinModule -Root $SystemFolder -Name 'Az.Compute' -Version '2.0.0' -Requires "@{ ModuleName = 'Az.Accounts'; ModuleVersion = '5.5.3' }"

        $Stop = Invoke-PinSession -ModulePath @($UserFolder, $SystemFolder) -Preload '5.5.3' -PreloadCompute '2.0.0' -CheckOnly
        $Stop.Status | Should -Be 'LoadedTooOld' -Because $Stop.Text
        $Stop.Text | Should -Match 'Az\.Accounts 5\.5\.3 is already loaded'
        $Stop.Text | Should -Match ([regex]::Escape('Az.Compute 1.0.0 asks for Az.Accounts 5.5.3')) -Because $Stop.Text
        $Stop.Text | Should -Not -Match 'Az\.Compute 2\.0\.0 asks for' -Because 'the loaded copy asks only for a minimum'
        $Stop.Text | Should -Match ([regex]::Escape('Install-Module -Name Az.Compute -Repository PSGallery -Scope CurrentUser -Force'))
        $Stop.Text | Should -Not -Match 'Install-Module -Name Az\.Accounts' -Because 'a supported Az.Accounts is installed'
        $Stop.Text | Should -Match 'new PowerShell session'

        # The advice followed: the printed command installs a newer Az.Compute
        # into the user's folder, then a new session without the old loads.
        New-PinModule -Root $UserFolder -Name 'Az.Compute' -Version '3.0.0' -Requires "@{ ModuleName = 'Az.Accounts'; ModuleVersion = '5.5.4' }"
        $Next = Invoke-PinSession -ModulePath @($UserFolder, $SystemFolder) -CheckOnly
        $Next.Status | Should -Be 'Ok' -Because $Next.Text
        $Run = Invoke-PinSession -ModulePath @($UserFolder, $SystemFolder)
        $Run.Status | Should -Be 'Ok' -Because $Run.Text
    }

    It 'a supported Az.Accounts and a newer submodule loaded first: stops on the pinning submodule copy a new session (a stream worker) would load, as that new session does, and both pass once it is updated' {
        # The wrapper's session has Az.Accounts 5.5.4 and Az.Compute 2.0.0 (a
        # minimum only) loaded, as a profile does. A stream worker is its own
        # process and loads neither: after it imports Az.Accounts 5.5.4, a
        # plain Import-Module takes Az.Compute 1.0.0 from the first folder,
        # which asks for exactly 5.5.3.
        $Root = Join-Path $script:PinDir 'ok-loaded-hides-disk-pin'
        $UserFolder = Join-Path $Root 'user'
        $SystemFolder = Join-Path $Root 'system'
        New-PinModule -Root $UserFolder -Name 'Az.Compute' -Version '1.0.0' -Requires "@{ ModuleName = 'Az.Accounts'; RequiredVersion = '5.5.3' }"
        New-PinModule -Root $SystemFolder -Name 'Az.Accounts' -Version '5.5.3'
        New-PinModule -Root $SystemFolder -Name 'Az.Accounts' -Version '5.5.4'
        New-PinModule -Root $SystemFolder -Name 'Az.Compute' -Version '2.0.0' -Requires "@{ ModuleName = 'Az.Accounts'; ModuleVersion = '5.5.3' }"

        $Wrapper = Invoke-PinSession -ModulePath @($UserFolder, $SystemFolder) -Preload '5.5.4' -PreloadCompute '2.0.0' -CheckOnly
        $Stream = Invoke-PinSession -ModulePath @($UserFolder, $SystemFolder) -Preload '5.5.4' -CheckOnly
        $Stream.Status | Should -Be 'SubModulePinned' -Because $Stream.Text
        $Wrapper.Status | Should -Be 'SubModulePinned' -Because 'the wrapper stops once, before any subscription, where every stream would stop'
        $Wrapper.Text | Should -Be $Stream.Text
        $Wrapper.Text | Should -Match ([regex]::Escape('Az.Compute 1.0.0 asks for Az.Accounts 5.5.3')) -Because $Wrapper.Text
        $Wrapper.Text | Should -Not -Match 'Az\.Compute 2\.0\.0 asks for' -Because 'the loaded copy asks only for a minimum'
        $Wrapper.Text | Should -Match ([regex]::Escape('Install-Module -Name Az.Compute -Repository PSGallery -Scope CurrentUser -Force'))

        # The advice followed: the printed command installs a newer Az.Compute
        # into the user's folder. The same wrapper session and a new stream
        # both pass, and so does the run after.
        New-PinModule -Root $UserFolder -Name 'Az.Compute' -Version '3.0.0' -Requires "@{ ModuleName = 'Az.Accounts'; ModuleVersion = '5.5.4' }"
        foreach ($Next in 1..2)
        {
            $Again = Invoke-PinSession -ModulePath @($UserFolder, $SystemFolder) -Preload '5.5.4' -PreloadCompute '2.0.0' -CheckOnly
            $Again.Status | Should -Be 'Ok' -Because $Again.Text
            $Again = Invoke-PinSession -ModulePath @($UserFolder, $SystemFolder) -Preload '5.5.4' -CheckOnly
            $Again.Status | Should -Be 'Ok' -Because $Again.Text
        }
        (Invoke-PinSession -ModulePath @($UserFolder, $SystemFolder)).Status | Should -Be 'Ok'
    }

    It 'the same pinning submodule version in two folders is named once in each line of the advice' {
        # Az.Compute 1.0.0, which asks for exactly 5.5.3, is in the user's
        # folder and in a later one. The session loaded Az.Accounts 5.5.3 and
        # the later folder's Az.Compute by path; a new session takes the
        # user's copy, so the check finds two copies of the same version.
        $Root = Join-Path $script:PinDir 'same-pin-two-folders'
        $UserFolder = Join-Path $Root 'user'
        $SystemFolder = Join-Path $Root 'system'
        New-PinModule -Root $UserFolder -Name 'Az.Compute' -Version '1.0.0' -Requires "@{ ModuleName = 'Az.Accounts'; RequiredVersion = '5.5.3' }"
        New-PinModule -Root $SystemFolder -Name 'Az.Accounts' -Version '5.5.3'
        New-PinModule -Root $SystemFolder -Name 'Az.Accounts' -Version '5.5.4'
        New-PinModule -Root $SystemFolder -Name 'Az.Compute' -Version '1.0.0' -Requires "@{ ModuleName = 'Az.Accounts'; RequiredVersion = '5.5.3' }"

        $Stop = Invoke-PinSession -ModulePath @($UserFolder, $SystemFolder) -Preload '5.5.3' -PreloadCompute (Join-Path $SystemFolder 'Az.Compute/1.0.0/Az.Compute.psd1') -CheckOnly
        $Stop.Status | Should -Be 'LoadedTooOld' -Because $Stop.Text
        @([regex]::Matches($Stop.Text, [regex]::Escape('Az.Compute 1.0.0 asks for Az.Accounts 5.5.3'))).Count | Should -Be 1 -Because $Stop.Text
        @([regex]::Matches($Stop.Text, [regex]::Escape('If this stops again with the same Az.Compute 1.0.0'))).Count | Should -Be 1 -Because $Stop.Text
        @([regex]::Matches($Stop.Text, [regex]::Escape('Install-Module -Name Az.Compute -Repository'))).Count | Should -Be 1 -Because $Stop.Text
    }

    It 'names a submodule whose manifest caps Az.Accounts below the minimum (MaximumVersion)' {
        $Root = Join-Path $script:PinDir 'maximum'
        New-PinModule -Root $Root -Name 'Az.Accounts' -Version '5.5.3'
        New-PinModule -Root $Root -Name 'Az.Accounts' -Version '5.5.4'
        New-PinModule -Root $Root -Name 'Az.Compute' -Version '1.5.0' -Requires "@{ ModuleName = 'Az.Accounts'; ModuleVersion = '5.0.0'; MaximumVersion = '5.5.3' }"

        $Stop = Invoke-PinSession -ModulePath @($Root)
        $Stop.Status | Should -Be 'LoadedTooOld' -Because $Stop.Text
        $Stop.Text | Should -Match ([regex]::Escape('Az.Compute 1.5.0 asks for Az.Accounts 5.5.3'))
        $Stop.Text | Should -Match ([regex]::Escape('Install-Module -Name Az.Compute -Repository PSGallery -Scope CurrentUser -Force'))
    }

    It 'when the old copy is still found first, says how to remove it, and the next session passes once it is gone' {
        $Root = Join-Path $script:PinDir 'order'
        $OldFirst = Join-Path $Root 'old'
        $NewLater = Join-Path $Root 'new'
        New-PinModule -Root $NewLater -Name 'Az.Accounts' -Version '5.5.3'
        New-PinModule -Root $NewLater -Name 'Az.Accounts' -Version '5.5.4'
        New-PinModule -Root $NewLater -Name 'Az.Compute' -Version '2.0.0' -Requires "@{ ModuleName = 'Az.Accounts'; ModuleVersion = '5.5.4' }"
        New-PinModule -Root $OldFirst -Name 'Az.Compute' -Version '1.0.0' -Requires "@{ ModuleName = 'Az.Accounts'; RequiredVersion = '5.5.3' }"

        $Stop = Invoke-PinSession -ModulePath @($OldFirst, $NewLater)
        $Stop.Status | Should -Be 'LoadedTooOld' -Because $Stop.Text
        $Stop.Text | Should -Match ([regex]::Escape('Get-Module -Name Az.Compute -ListAvailable'))
        $Stop.Text | Should -Match ([regex]::Escape('Uninstall-Module -Name Az.Compute -RequiredVersion 1.0.0'))

        # The old copy removed as the message says: the next session passes.
        Remove-Item -LiteralPath (Join-Path $OldFirst 'Az.Compute') -Recurse -Force
        (Invoke-PinSession -ModulePath @($OldFirst, $NewLater)).Status | Should -Be 'Ok'
    }

    It '<Status>: also names a submodule copy on disk that pins an older Az.Accounts, so one stop gives both fixes, and the next runs pass once both are done' -ForEach @(
        @{ Status = 'Missing'; Accounts = @() }
        @{ Status = 'TooOld'; Accounts = @('5.5.3') }
    ) {
        # Az.Accounts is not installed, or only 5.5.3 is, and the Az.Compute
        # a new session would load asks for exactly 5.5.3. Installing a
        # supported Az.Accounts alone would stop the next run on that pin.
        $Root = Join-Path $script:PinDir ('accounts-' + $Status)
        $UserFolder = Join-Path $Root 'user'
        $SystemFolder = Join-Path $Root 'system'
        foreach ($Version in $Accounts) { New-PinModule -Root $SystemFolder -Name 'Az.Accounts' -Version $Version }
        New-PinModule -Root $SystemFolder -Name 'Az.Compute' -Version '1.0.0' -Requires "@{ ModuleName = 'Az.Accounts'; RequiredVersion = '5.5.3' }"

        $Stop = Invoke-PinSession -ModulePath @($UserFolder, $SystemFolder) -CheckOnly
        $Stop.Status | Should -Be $Status -Because $Stop.Text
        $Stop.Text | Should -Match ([regex]::Escape('Install-Module -Name Az.Accounts -MinimumVersion 5.5.4')) -Because $Stop.Text
        $Stop.Text | Should -Match ([regex]::Escape('Az.Compute 1.0.0 asks for Az.Accounts 5.5.3')) -Because $Stop.Text
        $Stop.Text | Should -Match ([regex]::Escape('Install-Module -Name Az.Compute -Repository PSGallery -Scope CurrentUser -Force')) -Because $Stop.Text
        @([regex]::Matches($Stop.Text, [regex]::Escape('Az.Compute 1.0.0 asks for Az.Accounts 5.5.3'))).Count | Should -Be 1 -Because $Stop.Text

        # Both printed commands run: a supported Az.Accounts and a newer
        # Az.Compute in the user's folder, first on the module path. The
        # next two runs pass, the check alone and the full load.
        New-PinModule -Root $UserFolder -Name 'Az.Accounts' -Version '5.5.4'
        New-PinModule -Root $UserFolder -Name 'Az.Compute' -Version '2.0.0' -Requires "@{ ModuleName = 'Az.Accounts'; ModuleVersion = '5.5.4' }"
        foreach ($Next in 1..2)
        {
            $Again = Invoke-PinSession -ModulePath @($UserFolder, $SystemFolder) -CheckOnly
            $Again.Status | Should -Be 'Ok' -Because $Again.Text
            $Run = Invoke-PinSession -ModulePath @($UserFolder, $SystemFolder)
            $Run.Status | Should -Be 'Ok' -Because $Run.Text
        }
    }
}

Describe 'Install-RdaAzSubModule' {

    It 'installs Az.Accounts with -MinimumVersion 5.5.4 and the other modules by name' {
        Mock Install-Module -MockWith { }

        Install-RdaAzSubModule -Name @('Az.Accounts', 'Az.Compute', 'Az.Monitor')

        Should -Invoke Install-Module -Times 1 -Exactly -ParameterFilter {
            @($Name).Count -eq 1 -and $Name[0] -eq 'Az.Accounts' -and [version]$MinimumVersion -eq [version]'5.5.4' -and $Scope -eq 'CurrentUser'
        }
        Should -Invoke Install-Module -Times 1 -Exactly -ParameterFilter {
            (@($Name) -join ',') -eq 'Az.Compute,Az.Monitor' -and -not $MinimumVersion -and $Scope -eq 'CurrentUser'
        }
    }

    It 'makes no Az.Accounts call when only other modules are missing' {
        Mock Install-Module -MockWith { }

        Install-RdaAzSubModule -Name @('Az.Billing')

        Should -Invoke Install-Module -Times 1 -Exactly
        Should -Invoke Install-Module -Times 0 -Exactly -ParameterFilter { 'Az.Accounts' -in @($Name) }
    }
}

Describe 'Entry points stop before any Azure call on an old Az.Accounts' {

    BeforeAll {
        $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ('AzAccountsVersion_' + [guid]::NewGuid().ToString('N'))
        $script:Tree = Join-Path $script:WorkDir 'tree'
        New-Item -ItemType Directory -Path $script:Tree -Force | Out-Null
        foreach ($Item in @('ResourceInventory.ps1', 'Run-AllSubscriptions.ps1', 'Run-AllSubscriptions.Stream.ps1', 'Version.json', 'Functions', 'Extension', 'Services'))
        {
            Copy-Item -Path (Join-Path $script:RepoRoot $Item) -Destination $script:Tree -Recurse -Force
        }

        # Scenarios: <installed versions>/<loaded version>, e.g. '5.5.3/' or '5.5.4/5.5.3'.
        $script:Harness = Join-Path $script:WorkDir 'run.ps1'
        @'
param([string]$Tree, [string]$Out, [string]$CallLog, [string]$Installed, [string]$Loaded, [string]$Entry)
$PSStyle.OutputRendering = 'PlainText'
$Global:RdaSessionInitialized = $true
$Global:PlatformOS = 'PowerShell Unix'
$Global:AzvCallLog = $CallLog
$Global:AzvOut = $Out
$Global:AzvInstalled = @($Installed -split ',' | Where-Object { $_ })
$Global:AzvLoaded = $Loaded
# AZV_PRELOADED: an earlier run in this session already loaded the Az modules.
if ($env:AZV_PRELOADED) { $Global:AzPowerShellLoaded = $true }

function global:Get-Module
{
    [CmdletBinding()] param([Parameter(Position = 0)][string[]]$Name, [switch]$ListAvailable)
    if (@($Name).Count -eq 1 -and $Name[0] -like 'Az.*')
    {
        if ($Name[0] -eq 'Az.Accounts')
        {
            if ($ListAvailable) { foreach ($V in $Global:AzvInstalled) { [pscustomobject]@{ Name = 'Az.Accounts'; Version = [version]$V } }; return }
            if ($Global:AzvLoaded) { return [pscustomobject]@{ Name = 'Az.Accounts'; Version = [version]$Global:AzvLoaded } }
            return
        }
        if ($ListAvailable) { return [pscustomobject]@{ Name = $Name[0]; Version = [version]'9.9.9' } }
        # A loaded Az.Compute whose manifest asks for exactly the older
        # Az.Accounts (AZV_SUB_LOADS), which is the copy bound to it.
        if ($Name[0] -eq 'Az.Compute' -and $Global:AzvSubLoaded)
        {
            $SubBase = Join-Path $Global:AzvOut 'modules/Az.Compute/9.9.9'
            $null = New-Item -ItemType Directory -Path $SubBase -Force
            Set-Content -LiteralPath (Join-Path $SubBase 'Az.Compute.psd1') -Value ("@{{ ModuleVersion = '9.9.9'; RequiredModules = @(@{{ ModuleName = 'Az.Accounts'; RequiredVersion = '{0}' }}) }}" -f $env:AZV_SUB_LOADS)
            return [pscustomobject]@{ Name = 'Az.Compute'; Version = [version]'9.9.9'; ModuleBase = $SubBase; RequiredModules = @([pscustomobject]@{ Name = 'Az.Accounts'; Version = [version]$env:AZV_SUB_LOADS }) }
        }
        # AZV_PRELOADED: the earlier run loaded the other Az modules too,
        # except one removed since with Remove-Module (AZV_REMOVED); an
        # import in this run loads that one again.
        if ($env:AZV_PRELOADED -and ($Name[0] -ne $env:AZV_REMOVED -or $Global:AzvReloaded -contains $Name[0])) { return [pscustomobject]@{ Name = $Name[0]; Version = [version]'9.9.9' } }
        return
    }
    Microsoft.PowerShell.Core\Get-Module @PSBoundParameters
}
function global:Import-Module
{
    [CmdletBinding()] param([Parameter(Position = 0)][string[]]$Name, [switch]$DisableNameChecking, [switch]$Force, [version]$MinimumVersion)
    if (@($Name).Count -eq 1 -and $Name[0] -like 'Az.*')
    {
        Add-Content -LiteralPath $Global:AzvCallLog -Value ('import ' + $Name[0])
        Add-Content -LiteralPath $Global:AzvCallLog -Value ('importmin ' + $Name[0] + ' ' + $MinimumVersion)
        # AZV_IMPORT_LOADS: the version a plain import takes (an older copy
        # earlier in PSModulePath). With -MinimumVersion, PowerShell takes a
        # copy at or above it; 'ignore-min' takes the older copy anyway.
        # AZV_SUB_LOADS: a submodule whose manifest asks for that exact older
        # Az.Accounts (RequiredVersion), which PowerShell then loads next to
        # the new one; the lowest loaded copy is that older one.
        if ($Name[0] -eq 'Az.Compute' -and $env:AZV_SUB_LOADS) { $Global:AzvLoaded = $env:AZV_SUB_LOADS; $Global:AzvSubLoaded = $true }
        $Global:AzvReloaded = @($Global:AzvReloaded) + $Name[0]
        if ($Name[0] -eq 'Az.Accounts' -and $env:AZV_IMPORT_LOADS)
        {
            if ($MinimumVersion -and $env:AZV_IMPORT_MIN -ne 'ignore-min' -and [version]$env:AZV_IMPORT_LOADS -lt $MinimumVersion)
            {
                $Global:AzvLoaded = ($Global:AzvInstalled | ForEach-Object { [version]$_ } | Sort-Object -Descending | Select-Object -First 1).ToString()
            }
            else
            {
                $Global:AzvLoaded = $env:AZV_IMPORT_LOADS
            }
        }
        return
    }
    Microsoft.PowerShell.Core\Import-Module @PSBoundParameters
}
function global:Install-Module
{
    param([string[]]$Name, $MinimumVersion, $Repository, [switch]$Force, [switch]$AllowClobber, [switch]$SkipPublisherCheck, $Scope)
    Add-Content -LiteralPath $Global:AzvCallLog -Value ('install ' + ($Name -join ',') + ' min=' + $MinimumVersion)
    # 'works': the install puts a supported Az.Accounts on disk.
    if ($env:AZV_INSTALL -eq 'works' -and 'Az.Accounts' -in $Name) { $Global:AzvInstalled += [string]$MinimumVersion }
}
function global:Install-PackageProvider { }
# Interactive runs answer yes to the install prompt.
function global:Read-Host { param($Prompt) Add-Content -LiteralPath $Global:AzvCallLog -Value 'prompt'; 'y' }

foreach ($AzName in @('Get-AzContext', 'Connect-AzAccount', 'Get-AzAccessToken', 'Get-AzSubscription', 'Set-AzContext', 'Invoke-AzRestMethod'))
{
    $Body = "Add-Content -LiteralPath `$Global:AzvCallLog -Value 'azure $AzName'; exit 7"
    Set-Item -Path ("function:global:{0}" -f $AzName) -Value ([scriptblock]::Create($Body))
}

Set-Location $Tree
$global:LASTEXITCODE = 0
if ($Entry -eq 'wrapper')
{
    & (Join-Path $Tree 'Run-AllSubscriptions.ps1') -TenantID '00000000-0000-0000-0000-000000000001' -SkipMetrics -SkipConsumption -ParallelStreams 1
}
else
{
    & (Join-Path $Tree 'ResourceInventory.ps1') -TenantID 'tenant-demo' -SubscriptionID '12345678-1234-1234-1234-123456789012' -SkipMetrics -SkipConsumption -OutputDirectory $Out
}
exit $LASTEXITCODE
'@ | Set-Content -Path $script:Harness -Encoding utf8

        function Invoke-AzvRun
        {
            param([string]$Entry, [string]$Installed, [string]$Loaded, [switch]$Interactive, [string]$Install = 'fails', [string]$ImportLoads = '', [string]$ImportMin = '', [switch]$Preloaded, [string]$SubLoads = '', [string]$Removed = '')
            $Name = [guid]::NewGuid().ToString('N')
            $Out = Join-Path $script:WorkDir ('out_' + $Name)
            New-Item -ItemType Directory -Path $Out -Force | Out-Null
            $CallLog = Join-Path $script:WorkDir ('calls_' + $Name + '.log')
            $OldHome = $env:HOME
            # The wrapper writes under $HOME/InventoryReports; keep that in the temp dir.
            $env:HOME = $Out
            $env:AZV_INSTALL = $Install
            $env:AZV_IMPORT_LOADS = $ImportLoads
            $env:AZV_IMPORT_MIN = $ImportMin
            $env:AZV_PRELOADED = if ($Preloaded) { '1' } else { '' }
            $env:AZV_SUB_LOADS = $SubLoads
            $env:AZV_REMOVED = $Removed
            $Pwsh = Join-Path $PSHOME 'pwsh'
            try
            {
                if ($Interactive)
                {
                    # A pseudo-terminal from util-linux 'script' makes the wrapper see an
                    # interactive session, so it takes the install path.
                    $Cmd = "'{0}' -NoProfile -File '{1}' -Tree '{2}' -Out '{3}' -CallLog '{4}' -Installed '{5}' -Loaded '{6}' -Entry '{7}'" -f $Pwsh, $script:Harness, $script:Tree, $Out, $CallLog, $Installed, $Loaded, $Entry
                    $Output = & script -qec $Cmd /dev/null 2>&1 | Out-String
                }
                else
                {
                    # Piped input makes the wrapper see a non-interactive session: it must not prompt.
                    $Output = '' | & $Pwsh -NoProfile -NonInteractive -File $script:Harness -Tree $script:Tree -Out $Out -CallLog $CallLog -Installed $Installed -Loaded $Loaded -Entry $Entry *>&1 | Out-String
                }
                $Code = $LASTEXITCODE
            }
            finally
            {
                $env:HOME = $OldHome
                Remove-Item Env:AZV_INSTALL -ErrorAction SilentlyContinue
                Remove-Item Env:AZV_IMPORT_LOADS -ErrorAction SilentlyContinue
                Remove-Item Env:AZV_IMPORT_MIN -ErrorAction SilentlyContinue
                Remove-Item Env:AZV_PRELOADED -ErrorAction SilentlyContinue
                Remove-Item Env:AZV_SUB_LOADS -ErrorAction SilentlyContinue
                Remove-Item Env:AZV_REMOVED -ErrorAction SilentlyContinue
            }
            $Calls = if (Test-Path -LiteralPath $CallLog) { @(Get-Content -LiteralPath $CallLog) } else { @() }
            [pscustomobject]@{
                ExitCode   = $Code
                Output     = $Output
                AzureCalls = @($Calls | Where-Object { $_ -like 'azure *' })
                Imports    = @($Calls | Where-Object { $_ -like 'import *' })
                ImportMins = @($Calls | Where-Object { $_ -like 'importmin *' })
                Installs   = @($Calls | Where-Object { $_ -like 'install *' })
                Prompts    = @($Calls | Where-Object { $_ -eq 'prompt' })
            }
        }
    }

    AfterAll {
        if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir)) { Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'direct run: goes on to the sign-in with Az.Accounts 5.5.4 (control)' {
        $Run = Invoke-AzvRun -Entry 'direct' -Installed '5.5.4'

        $Run.ExitCode | Should -Be 7 -Because 'the stand-in Azure cmdlet ends the run once it is reached'
        $Run.Imports | Should -Contain 'import Az.Accounts'
    }

    It 'direct run: stops with exit 1 before any Azure call on Az.Accounts 5.5.3' {
        $Run = Invoke-AzvRun -Entry 'direct' -Installed '5.5.3'

        $Run.ExitCode | Should -Be 1
        $Run.AzureCalls | Should -BeNullOrEmpty
        $Run.Imports | Should -BeNullOrEmpty -Because 'the version check runs before any module is loaded'
        $Run.Output | Should -Match 'Az\.Accounts 5\.5\.3 is installed'
        $Run.Output | Should -Match 'needs Az\.Accounts 5\.5\.4 or newer'
        $Run.Output | Should -Match ([regex]::Escape('Install-Module -Name Az.Accounts -MinimumVersion 5.5.4'))
    }

    It 'direct run: goes on with several installed when the highest is new enough' {
        $Run = Invoke-AzvRun -Entry 'direct' -Installed '5.5.3,5.5.4,5.2.0'

        $Run.ExitCode | Should -Be 7
    }

    It 'direct run: stops with exit 1 when an older Az.Accounts is already loaded' {
        $Run = Invoke-AzvRun -Entry 'direct' -Installed '5.5.4' -Loaded '5.5.3'

        $Run.ExitCode | Should -Be 1
        $Run.AzureCalls | Should -BeNullOrEmpty
        $Run.Output | Should -Match 'Az\.Accounts 5\.5\.3 is already loaded'
        $Run.Output | Should -Match 'new PowerShell session'
    }

    It 'direct run, Az modules already loaded by an earlier run in the session: goes on without loading them again when the loaded Az.Accounts is 5.5.4' {
        $Run = Invoke-AzvRun -Entry 'direct' -Installed '5.5.4' -Loaded '5.5.4' -Preloaded

        $Run.ExitCode | Should -Be 7 -Because 'the run goes on to the sign-in'
        $Run.Imports | Should -BeNullOrEmpty -Because 'the modules are already loaded'
    }

    It 'direct run, Az modules loaded by an earlier run in the session but Az.Compute removed since: loads them again and goes on' {
        $Run = Invoke-AzvRun -Entry 'direct' -Installed '5.5.4' -Loaded '5.5.4' -Preloaded -Removed 'Az.Compute'

        $Run.Imports | Should -Contain 'import Az.Compute' -Because 'a required module that is not loaded is loaded again'
        $Run.ExitCode | Should -Be 7 -Because 'the run goes on to the sign-in'
    }

    It 'direct run, Az modules already loaded by an earlier run in the session: stops with exit 1 when the loaded Az.Accounts is older' {
        # An older build of the tool loaded Az.Accounts 5.5.3 earlier in the
        # same session, then the checkout was updated and run again.
        $Run = Invoke-AzvRun -Entry 'direct' -Installed '5.5.4' -Loaded '5.5.3' -Preloaded

        $Run.ExitCode | Should -Be 1 -Because $Run.Output
        $Run.AzureCalls | Should -BeNullOrEmpty
        $Run.Output | Should -Match 'Az\.Accounts 5\.5\.3 is already loaded'
        $Run.Output | Should -Match 'new PowerShell session'
    }

    It 'wrapper: goes past the module check with Az.Accounts 5.5.4 (control)' {
        $Run = Invoke-AzvRun -Entry 'wrapper' -Installed '5.5.4'

        $Run.Imports | Should -Contain 'import Az.Accounts'
        $Run.Installs | Should -BeNullOrEmpty
        $Run.Output | Should -Not -Match 'needs Az\.Accounts 5\.5\.4 or newer'
    }

    It 'wrapper: stops with exit 1 and the command, without prompting or installing, on Az.Accounts 5.5.3 in a non-interactive session' {
        $Run = Invoke-AzvRun -Entry 'wrapper' -Installed '5.5.3'

        $Run.ExitCode | Should -Be 1
        $Run.AzureCalls | Should -BeNullOrEmpty
        $Run.Installs | Should -BeNullOrEmpty
        $Run.Imports | Should -BeNullOrEmpty
        $Run.Output | Should -Match 'Az\.Accounts 5\.5\.3 is installed'
        $Run.Output | Should -Match ([regex]::Escape('Install-Module -Name Az.Accounts -MinimumVersion 5.5.4'))
    }

    It 'wrapper, interactive: installs Az.Accounts with -MinimumVersion 5.5.4 once, then goes on' -Skip:(-not $IsLinux -or -not (Get-Command script -ErrorAction SilentlyContinue)) {
        $Run = Invoke-AzvRun -Entry 'wrapper' -Installed '5.5.3' -Interactive -Install 'works'

        $Run.Prompts.Count | Should -Be 1
        $Run.Installs | Should -Be @('install Az.Accounts min=5.5.4')
        $Run.Imports | Should -Contain 'import Az.Accounts'
        $Run.ExitCode | Should -Not -Be 1 -Because 'the second check sees the new version and the run goes on'
    }

    It 'wrapper, interactive: stops with exit 1 after one install that still leaves an old Az.Accounts (no retry loop)' -Skip:(-not $IsLinux -or -not (Get-Command script -ErrorAction SilentlyContinue)) {
        $Run = Invoke-AzvRun -Entry 'wrapper' -Installed '5.5.3' -Interactive -Install 'fails'

        $Run.ExitCode | Should -Be 1
        $Run.Prompts.Count | Should -Be 1
        $Run.Installs.Count | Should -Be 1 -Because 'the wrapper installs once and checks once more; it never tries again'
        $Run.Imports | Should -BeNullOrEmpty
        $Run.AzureCalls | Should -BeNullOrEmpty
        $Run.Output | Should -Match ([regex]::Escape('Install-Module -Name Az.Accounts -MinimumVersion 5.5.4'))
    }

    It 'wrapper: stops with exit 1 when an older Az.Accounts is already loaded' {
        $Run = Invoke-AzvRun -Entry 'wrapper' -Installed '5.5.4' -Loaded '5.5.3'

        $Run.ExitCode | Should -Be 1
        $Run.AzureCalls | Should -BeNullOrEmpty
        $Run.Installs | Should -BeNullOrEmpty
        $Run.Output | Should -Match 'Az\.Accounts 5\.5\.3 is already loaded'
        $Run.Output | Should -Match 'new PowerShell session'
    }

    It 'direct run: imports Az.Accounts with -MinimumVersion 5.5.4, so an older copy earlier in PSModulePath is not taken' {
        $Run = Invoke-AzvRun -Entry 'direct' -Installed '5.5.3,5.5.4' -ImportLoads '5.5.3'

        $Run.ImportMins | Should -Contain 'importmin Az.Accounts 5.5.4'
        $Run.ExitCode | Should -Be 7 -Because 'the supported copy loads and the run goes on to the sign-in'
    }

    It 'direct run: stops with exit 1 before any Azure call when the copy that loaded is older anyway' {
        $Run = Invoke-AzvRun -Entry 'direct' -Installed '5.5.3,5.5.4' -ImportLoads '5.5.3' -ImportMin 'ignore-min'

        $Run.ExitCode | Should -Be 1
        $Run.AzureCalls | Should -BeNullOrEmpty
        $Run.Output | Should -Match 'Az\.Accounts 5\.5\.3 is already loaded'
    }

    It 'direct run: stops with exit 1 before any Azure call when a submodule loads an older Az.Accounts next to the supported one' {
        $Run = Invoke-AzvRun -Entry 'direct' -Installed '5.5.3,5.5.4' -SubLoads '5.5.3'

        $Run.Imports | Should -Contain 'import Az.Compute'
        $Run.ExitCode | Should -Be 1 -Because $Run.Output
        $Run.AzureCalls | Should -BeNullOrEmpty
        $Run.Output | Should -Match 'Az\.Accounts 5\.5\.3 is already loaded'
    }

    It 'direct run: the stop for a submodule that loads an older Az.Accounts names it and the command that updates it' {
        $Run = Invoke-AzvRun -Entry 'direct' -Installed '5.5.3,5.5.4' -SubLoads '5.5.3'

        $Run.ExitCode | Should -Be 1 -Because $Run.Output
        $Run.AzureCalls | Should -BeNullOrEmpty
        $Run.Installs | Should -BeNullOrEmpty -Because 'the check prints the command; it installs nothing'
        $Run.Output | Should -Match ([regex]::Escape('Az.Compute 9.9.9 asks for Az.Accounts 5.5.3'))
        $Run.Output | Should -Match ([regex]::Escape('Install-Module -Name Az.Compute -Repository PSGallery -Scope CurrentUser -Force'))
    }

    It 'wrapper: imports Az.Accounts with -MinimumVersion 5.5.4, so an older copy earlier in PSModulePath is not taken' {
        $Run = Invoke-AzvRun -Entry 'wrapper' -Installed '5.5.3,5.5.4' -ImportLoads '5.5.3'

        $Run.ImportMins | Should -Contain 'importmin Az.Accounts 5.5.4'
        $Run.Output | Should -Not -Match 'is already loaded'
    }

    It 'wrapper: stops with exit 1 before any Azure call when the copy that loaded is older anyway' {
        $Run = Invoke-AzvRun -Entry 'wrapper' -Installed '5.5.3,5.5.4' -ImportLoads '5.5.3' -ImportMin 'ignore-min'

        $Run.ExitCode | Should -Be 1
        $Run.AzureCalls | Should -BeNullOrEmpty
        $Run.Installs | Should -BeNullOrEmpty
        $Run.Output | Should -Match 'Az\.Accounts 5\.5\.3 is already loaded'
    }
}

Describe 'Every Az.Accounts import asks for the supported version' {

    # A plain Import-Module takes the first copy in PSModulePath order, which
    # can be older than the copy the version check saw. Every import of
    # Az.Accounts in the entry scripts must name -MinimumVersion, and an
    # import by variable must loop over a list that leaves Az.Accounts out.
    It '<_> imports Az.Accounts only with -MinimumVersion' -ForEach @('ResourceInventory.ps1', 'Run-AllSubscriptions.ps1', 'Run-AllSubscriptions.Stream.ps1') {
        $Path = Join-Path $script:RepoRoot $_
        $Tokens = $null
        $Errors = $null
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$Tokens, [ref]$Errors)
        $Imports = @($Ast.FindAll({
                    param($Node)
                    $Node -is [System.Management.Automation.Language.CommandAst] -and $Node.GetCommandName() -eq 'Import-Module'
                }, $true))
        $Bad = [System.Collections.Generic.List[string]]::new()
        $Literal = 0
        foreach ($Import in $Imports)
        {
            $Target = $Import.CommandElements[1]
            $Text = $Import.Extent.Text
            if ($Target -is [System.Management.Automation.Language.StringConstantExpressionAst])
            {
                if ($Target.Value -ne 'Az.Accounts') { continue }
                $Literal++
                if ($Text -notmatch '-MinimumVersion\b') { $Bad.Add("line $($Import.Extent.StartLineNumber): $Text") }
            }
            elseif ($Target -is [System.Management.Automation.Language.VariableExpressionAst])
            {
                $Loop = $Import.Parent
                while ($Loop -and $Loop -isnot [System.Management.Automation.Language.ForEachStatementAst]) { $Loop = $Loop.Parent }
                if ($Text -notmatch '-MinimumVersion\b' -and -not ($Loop -and $Loop.Condition.Extent.Text -match "-ne 'Az\.Accounts'"))
                {
                    $Bad.Add("line $($Import.Extent.StartLineNumber): $Text")
                }
            }
        }
        $Literal | Should -BeGreaterThan 0 -Because "$_ loads Az.Accounts by name"
        @($Bad) | Should -BeNullOrEmpty
    }
}

Describe 'The stream worker stops without the Az.Accounts version file' {

    # Without Functions/AzModules.Functions.ps1 the worker does not know the
    # supported version. It must stop as for its other required file, not
    # load any Az.Accounts and import the sign-in.
    BeforeAll {
        $script:StreamDir = Join-Path ([System.IO.Path]::GetTempPath()) ('AzAccountsVersionStream_' + [guid]::NewGuid().ToString('N'))
        $script:StreamTree = Join-Path $script:StreamDir 'tree'
        New-Item -ItemType Directory -Path $script:StreamTree -Force | Out-Null
        foreach ($Item in @('Run-AllSubscriptions.Stream.ps1', 'ResourceInventory.ps1', 'Version.json', 'Functions', 'Extension', 'Services'))
        {
            Copy-Item -Path (Join-Path $script:RepoRoot $Item) -Destination $script:StreamTree -Recurse -Force
        }
        Remove-Item -LiteralPath (Join-Path $script:StreamTree 'Functions/AzModules.Functions.ps1') -Force

        $script:StreamHarness = Join-Path $script:StreamDir 'stream.ps1'
        @'
param([string]$Tree, [string]$CallLog)
$PSStyle.OutputRendering = 'PlainText'
$Global:AzvCallLog = $CallLog
function global:Import-Module
{
    [CmdletBinding()] param([Parameter(Position = 0)][string[]]$Name, [switch]$DisableNameChecking, [switch]$Force, [version]$MinimumVersion)
    if (@($Name).Count -eq 1 -and $Name[0] -like 'Az.*') { Add-Content -LiteralPath $Global:AzvCallLog -Value ('import ' + $Name[0]); return }
    Microsoft.PowerShell.Core\Import-Module @PSBoundParameters
}
function global:Disable-AzContextAutosave { param($Scope) Add-Content -LiteralPath $Global:AzvCallLog -Value 'azure Disable-AzContextAutosave' }
function global:Import-AzContext { param($Path) Add-Content -LiteralPath $Global:AzvCallLog -Value 'azure Import-AzContext'; exit 7 }
$Root = Join-Path $Tree 'out'
New-Item -ItemType Directory -Path $Root -Force | Out-Null
$global:LASTEXITCODE = 0
& (Join-Path $Tree 'Run-AllSubscriptions.Stream.ps1') -TenantID '00000000-0000-0000-0000-000000000001' -RunId '11111111-2222-3333-4444-555555555555' -StreamId '0' -InventoryRoot $Root -ScriptRoot $Tree -AzContextPath (Join-Path $Root 'ctx.json') -StreamSummaryPath (Join-Path $Root 'summary.json') -StreamFailuresPath (Join-Path $Root 'failures.json') -SubscriptionIds @('12345678-1234-1234-1234-123456789012') -SubscriptionNames @('Sub demo') -SkipMetrics -SkipConsumption
exit $LASTEXITCODE
'@ | Set-Content -Path $script:StreamHarness -Encoding utf8
    }

    AfterAll {
        if ($script:StreamDir -and (Test-Path -LiteralPath $script:StreamDir)) { Remove-Item -LiteralPath $script:StreamDir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'stops with exit 1 and the missing file named, before loading Az.Accounts or the sign-in' {
        $CallLog = Join-Path $script:StreamDir 'calls.log'
        $Output = '' | & (Join-Path $PSHOME 'pwsh') -NoProfile -NonInteractive -File $script:StreamHarness -Tree $script:StreamTree -CallLog $CallLog *>&1 | Out-String
        $Code = $LASTEXITCODE
        $Calls = if (Test-Path -LiteralPath $CallLog) { @(Get-Content -LiteralPath $CallLog) } else { @() }

        $Code | Should -Be 1 -Because $Output
        $Output | Should -Match ([regex]::Escape('Required functions file not found:'))
        $Output | Should -Match 'AzModules\.Functions\.ps1'
        $Calls | Should -BeNullOrEmpty -Because 'no Az module is loaded and no Azure call is made'
    }
}
