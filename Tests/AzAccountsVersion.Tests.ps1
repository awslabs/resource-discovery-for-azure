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
$Global:AzvInstalled = @($Installed -split ',' | Where-Object { $_ })
$Global:AzvLoaded = $Loaded

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
            param([string]$Entry, [string]$Installed, [string]$Loaded, [switch]$Interactive, [string]$Install = 'fails', [string]$ImportLoads = '', [string]$ImportMin = '')
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
