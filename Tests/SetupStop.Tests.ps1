# =============================================================================
# SetupStop.Tests.ps1
#
# Offline tests that a direct run of ResourceInventory.ps1 stops with exit 1,
# before any Azure call, when its setup finds a problem the run cannot get
# past.
#
# WHY THIS TEST EXISTS
# --------------------
# The script runs with $ErrorActionPreference = 'SilentlyContinue' (unless
# -Debug). Under that preference a bare `throw` that no try/catch handles is
# suppressed: the script just carries on with the next statement. The setup
# checks used `throw` to stop the run, so:
#  - with Az.Compute or Az.Monitor not installed, the run went on to sign in
#    and collect, and the VirtualMachines / VMSS collectors failed later;
#  - with an Az module present on disk that does not load, the same;
#  - with under 100 MB free, or an output folder that cannot be written to,
#    the pre-flight check printed nothing and the run went on.
# Each of these now writes the reason and stops with exit 1, the same way a
# sign-in that gives no usable token stops the run.
#
# HOW
# ---
# The script and its folders are copied to a temp dir and the REAL
# ResourceInventory.ps1 runs in a child pwsh. Get-Module and Import-Module
# are stand-ins for the Az modules only; Get-Item and Set-Content are
# stand-ins for the pre-flight paths only (everything else goes to the real
# cmdlet). Every Azure cmdlet the run could reach first is a stand-in that
# records the call and ends the run with exit 7, so "reached Azure" is
# visible both in the exit code and in the call log. No live Azure.
#
# Run with: Invoke-Pester ./Tests/SetupStop.Tests.ps1 -Output Detailed
# =============================================================================

BeforeAll {
    $script:RepoRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' | Resolve-Path | Select-Object -ExpandProperty Path
    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ('SetupStop_' + [guid]::NewGuid().ToString('N'))
    $script:Tree = Join-Path $script:WorkDir 'tree'
    New-Item -ItemType Directory -Path $script:Tree -Force | Out-Null
    foreach ($Item in @('ResourceInventory.ps1', 'Version.json', 'Functions', 'Extension', 'Services'))
    {
        Copy-Item -Path (Join-Path $script:RepoRoot $Item) -Destination $script:Tree -Recurse -Force
    }

    $script:Harness = Join-Path $script:WorkDir 'run.ps1'
    @'
param([string]$Tree, [string]$Out, [string]$CallLog, [string]$Scenario)
$PSStyle.OutputRendering = 'PlainText'
# Skips the online version check; the sign-in step still runs.
$Global:RdaSessionInitialized = $true
$Global:PlatformOS = 'PowerShell Unix'
$Global:SetupStopScenario = $Scenario
$Global:SetupStopCallLog = $CallLog
$Global:SetupStopOut = (Resolve-Path -LiteralPath $Out).Path

# The Az modules: Az.Compute and Az.Monitor are not installed in 'missing';
# Az.Monitor is on disk but does not load in 'broken'.
function global:Get-Module
{
    [CmdletBinding()] param([Parameter(Position = 0)][string[]]$Name, [switch]$ListAvailable)
    if ($ListAvailable -and @($Name).Count -eq 1 -and $Name[0] -like 'Az.*')
    {
        if ($Global:SetupStopScenario -eq 'missing' -and $Name[0] -in @('Az.Compute', 'Az.Monitor')) { return }
        return [pscustomobject]@{ Name = $Name[0]; Version = [version]'9.9.9' }
    }
    Microsoft.PowerShell.Core\Get-Module @PSBoundParameters
}
function global:Import-Module
{
    [CmdletBinding()] param([Parameter(Position = 0)][string[]]$Name, [switch]$DisableNameChecking, [version]$MinimumVersion)
    if (@($Name).Count -eq 1 -and $Name[0] -like 'Az.*')
    {
        Add-Content -LiteralPath $Global:SetupStopCallLog -Value ('import ' + $Name[0])
        if ($Global:SetupStopScenario -eq 'broken' -and $Name[0] -eq 'Az.Monitor') { throw 'Could not load file or assembly Azure.Core.' }
        return
    }
    Microsoft.PowerShell.Core\Import-Module @PSBoundParameters
}

# The pre-flight checks: 50 MB free in 'lowdisk'; the write probe fails in
# 'unwritable'.
function global:Get-Item
{
    [CmdletBinding()] param([Parameter(Position = 0)][string[]]$Path, [string[]]$LiteralPath)
    if ($Global:SetupStopScenario -eq 'lowdisk' -and @($Path).Count -eq 1 -and $Path[0] -eq $Global:SetupStopOut)
    {
        return [pscustomobject]@{ PSDrive = [pscustomobject]@{ Free = 50MB } }
    }
    Microsoft.PowerShell.Management\Get-Item @PSBoundParameters
}
function global:Set-Content
{
    [CmdletBinding()] param([string[]]$Path, [string[]]$LiteralPath, [Parameter(ValueFromPipeline = $true)][object[]]$Value, $Encoding, [switch]$Force)
    process
    {
        if ($Global:SetupStopScenario -eq 'unwritable' -and "$Path" -like '*.write-probe-*') { throw 'Access to the path is denied.' }
        Microsoft.PowerShell.Management\Set-Content @PSBoundParameters
    }
}

# Reaching any of these means the run went on to Azure.
foreach ($AzName in @('Get-AzContext', 'Connect-AzAccount', 'Get-AzAccessToken', 'Get-AzSubscription', 'Set-AzContext', 'Invoke-AzRestMethod'))
{
    $Body = "Add-Content -LiteralPath `$Global:SetupStopCallLog -Value 'azure $AzName'; exit 7"
    Set-Item -Path ("function:global:{0}" -f $AzName) -Value ([scriptblock]::Create($Body))
}

Set-Location $Tree
$global:LASTEXITCODE = 0
& (Join-Path $Tree 'ResourceInventory.ps1') -TenantID 'tenant-demo' -SubscriptionID '12345678-1234-1234-1234-123456789012' -SkipMetrics -SkipConsumption -OutputDirectory $Out
exit $LASTEXITCODE
'@ | Set-Content -Path $script:Harness -Encoding utf8

    function Invoke-SetupRun
    {
        param([string]$Scenario)
        $Name = [guid]::NewGuid().ToString('N')
        $Out = Join-Path $script:WorkDir ('out_' + $Name)
        New-Item -ItemType Directory -Path $Out -Force | Out-Null
        $CallLog = Join-Path $script:WorkDir ('calls_' + $Name + '.log')
        $Output = & (Join-Path $PSHOME 'pwsh') -NoProfile -NonInteractive -File $script:Harness -Tree $script:Tree -Out $Out -CallLog $CallLog -Scenario $Scenario *>&1 | Out-String
        $Code = $LASTEXITCODE
        $Calls = if (Test-Path -LiteralPath $CallLog) { @(Get-Content -LiteralPath $CallLog) } else { @() }
        [pscustomobject]@{
            ExitCode   = $Code
            Output     = $Output
            AzureCalls = @($Calls | Where-Object { $_ -like 'azure *' })
            Imports    = @($Calls | Where-Object { $_ -like 'import *' })
        }
    }
}

AfterAll {
    if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir)) { Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'Direct run setup under the production error preference' {

    It 'goes on to the sign-in when every Az module is present and loads (control)' {
        $Run = Invoke-SetupRun -Scenario 'ok'

        $Run.ExitCode | Should -Be 7 -Because 'the stand-in Azure cmdlet ends the run once it is reached'
        $Run.AzureCalls.Count | Should -BeGreaterThan 0
        $Run.Imports | Should -Be @('import Az.Accounts', 'import Az.Compute', 'import Az.Monitor', 'import Az.Billing')
    }

    It 'stops with exit 1 before any Azure call when Az.Compute and Az.Monitor are not installed' {
        $Run = Invoke-SetupRun -Scenario 'missing'

        $Run.ExitCode | Should -Be 1
        $Run.AzureCalls | Should -BeNullOrEmpty -Because 'the run must not sign in or collect without the modules its collectors need'
        $Run.Imports | Should -BeNullOrEmpty
        $Run.Output | Should -Match 'Required Azure PowerShell module\(s\) not found: Az\.Compute, Az\.Monitor'
    }

    It 'stops with exit 1 before any Azure call when an Az module is on disk but does not load' {
        $Run = Invoke-SetupRun -Scenario 'broken'

        $Run.ExitCode | Should -Be 1
        $Run.AzureCalls | Should -BeNullOrEmpty
        $Run.Imports | Should -Contain 'import Az.Monitor'
        $Run.Imports | Should -Not -Contain 'import Az.Billing' -Because 'loading stops at the first module that fails'
        $Run.Output | Should -Match 'present on disk but failed to load'
    }

    It 'stops with exit 1 before any Azure call when the output folder has under 100 MB free' {
        $Run = Invoke-SetupRun -Scenario 'lowdisk'

        $Run.ExitCode | Should -Be 1
        $Run.AzureCalls | Should -BeNullOrEmpty
        $Run.Imports | Should -BeNullOrEmpty -Because 'the pre-flight checks run before setup'
        $Run.Output | Should -Match 'free disk space at .* is 50 MB'
    }

    It 'stops with exit 1 before any Azure call when the output folder cannot be written to' {
        $Run = Invoke-SetupRun -Scenario 'unwritable'

        $Run.ExitCode | Should -Be 1
        $Run.AzureCalls | Should -BeNullOrEmpty
        $Run.Imports | Should -BeNullOrEmpty
        $Run.Output | Should -Match 'cannot write to .*Access to the path is denied'
    }
}
