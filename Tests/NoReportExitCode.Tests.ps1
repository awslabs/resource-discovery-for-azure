# No-report exit code tests
# Run with: Invoke-Pester ./Tests/NoReportExitCode.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# A direct ResourceInventory.ps1 run (no -RunAllSubs) can reach its last line
# without having written the report zip: when 5 collectors fail in a row the
# collection phase stops before the inventory is written, and when the HTML
# report cannot be built Compress-Archive writes no zip. Such a run used to
# print the missing zip on its 'Reporting Data File:' line and exit 0. It now
# ends with a red 'No report was written' line and exits 2. A run that writes
# its zip, including one over a subscription with no resources, still exits 0.
# Under -RunAllSubs the exit code is unchanged; the wrapper checks each
# subscription's zip itself.
#
# A run that stops during setup (output folder not writable, Azure CLI not
# installed, service principal sign-in without a secret, -ResourceGroup without
# -SubscriptionID, Version.json missing) exits 1, also under -RunAllSubs, where
# the wrapper then records a failed subscription. Version.json is read from the
# script's own folder, so a run started from another folder writes its report.
#
# This test is SELF-CONTAINED: it copies the script and its folders to a temp
# dir, adds small collectors there (one returns a record, the others throw),
# and runs the REAL ResourceInventory.ps1 in a child pwsh with -SkipMetrics
# -SkipConsumption and offline stand-ins for the Azure CLI and Az calls the
# run makes. No live Azure. Generic names and the documentation placeholder
# subscription id only.

BeforeAll {
    $script:RepoRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' | Resolve-Path | Select-Object -ExpandProperty Path
    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ("NoReportExitCode_" + [guid]::NewGuid().ToString('N'))

    # Copies the script and its folders into a new tree with the stand-in
    # collectors; -BrokenSummary replaces Extension/Summary.ps1 with one that throws,
    # -NoVersionJson leaves Version.json out.
    function New-StandInTree
    {
        param([string]$Name, [switch]$BrokenSummary, [switch]$NoVersionJson)

        $Tree = Join-Path $script:WorkDir $Name
        New-Item -ItemType Directory -Path $Tree -Force | Out-Null
        $Items = @('ResourceInventory.ps1', 'Version.json', 'Functions', 'Extension', 'Services')
        if ($NoVersionJson) { $Items = @($Items | Where-Object { $_ -ne 'Version.json' }) }
        foreach ($Item in $Items)
        {
            Copy-Item -Path (Join-Path $script:RepoRoot $Item) -Destination $Tree -Recurse -Force
        }

        $StandInServices = Join-Path $Tree 'Services/StandIn'
        New-Item -ItemType Directory -Path $StandInServices -Force | Out-Null
        @'
param($Sub, $Resources, $Task, $ResourceIdDictionary)
if ($Task -eq 'Processing')
{
    foreach ($1 in $Resources)
    {
        @{ 'ID' = $1.id; 'Subscription' = 'Demo Subscription'; 'ResourceGroup' = $1.resourcegroup; 'Name' = $1.name; 'Location' = $1.location }
    }
}
'@ | Set-Content -Path (Join-Path $StandInServices 'StandInWorking.ps1') -Encoding utf8
        # Five failing collectors in a row trip the collector circuit breaker,
        # which ends the collection phase before the inventory is written.
        foreach ($i in 1..5)
        {
            "param(`$Sub, `$Resources, `$Task, `$ResourceIdDictionary)`nif (`$Task -eq 'Processing') { throw 'stand-in collector error $i' }" |
                Set-Content -Path (Join-Path $StandInServices ("StandInBreak{0}.ps1" -f $i)) -Encoding utf8
        }

        if ($BrokenSummary)
        {
            "param(`$JsonFile, `$HtmlFile, `$Title, `$TenantId, `$Version, `$ExtractionRunTime, `$ReportingRunTime, `$PhaseTimings, `$PlatOS, `$ConsumptionFile)`nthrow 'stand-in report failure'" |
                Set-Content -Path (Join-Path $Tree 'Extension/Summary.ps1') -Encoding utf8
        }

        return $Tree
    }

    $script:Tree = New-StandInTree -Name 'tree'
    $script:BrokenSummaryTree = New-StandInTree -Name 'tree-broken-summary' -BrokenSummary
    $script:NoVersionJsonTree = New-StandInTree -Name 'tree-no-version-json' -NoVersionJson

    # Child-process harness: stand-ins for the az CLI and Az cmdlets, then the
    # real script. -Service arrives as one comma-separated string because
    # pwsh -File does not bind arrays. -NoResources makes Resource Graph report
    # an empty subscription. -Cwd starts the script from another folder,
    # -SignedOut means no saved sign-in, and -NoAzCli removes the Azure CLI from
    # PATH (and its stand-in) so the script's own CLI check runs.
    $script:Harness = Join-Path $script:WorkDir 'run.ps1'
    @'
param([string]$Tree, [string]$Out, [string]$Service, [switch]$RunAllSubs, [switch]$NoResources, [string]$StateFile,
    [string]$Cwd, [string]$ResourceGroup, [switch]$NoSubscriptionID, [string]$TenantID, [string]$Appid, [switch]$SignedOut, [switch]$NoAzCli)
$PSStyle.OutputRendering = 'PlainText'
$Global:RdaSessionInitialized = $true
$Global:AzPowerShellLoaded = -not $NoAzCli.IsPresent
$Global:PlatformOS = 'PowerShell Unix'
$Global:StandInNoResources = $NoResources.IsPresent
$Global:StandInSignedOut = $SignedOut.IsPresent
$SubId = '12345678-1234-1234-1234-123456789012'
$Global:StandInSubs = @([pscustomobject]@{ id = $SubId; name = 'Demo Subscription'; tenantId = 'tenant-demo'; state = 'Enabled' })
if ($NoAzCli)
{
    $Sep = [IO.Path]::PathSeparator
    foreach ($Cmd in @(Get-Command az -CommandType Application -All -ErrorAction SilentlyContinue))
    {
        $Dir = (Split-Path -Parent $Cmd.Source).TrimEnd('/', '\')
        $env:PATH = (@($env:PATH -split [regex]::Escape($Sep)) | Where-Object { $_ -and $_.TrimEnd('/', '\') -ne $Dir }) -join $Sep
    }
}
else
{
function global:az
{
    $Joined = $args -join ' '
    $global:LASTEXITCODE = 0
    if ($Joined -like 'account show*') { if ($Global:StandInSignedOut) { return $null }; return '{"user":{"name":"tester"},"tenantId":"tenant-demo"}' }
    if ($Joined -like 'account list*') { return (ConvertTo-Json -InputObject @($Global:StandInSubs) -Compress) }
    if ($Joined -like 'graph*')
    {
        if ($Joined -match 'desktopvirtualizationresources') { return '{"data":[{"count_":0}],"count":1}' }
        if ($Joined -match 'summarize count\(\)')
        {
            if ($Global:StandInNoResources) { return '{"data":[{"count_":0}],"count":1}' }
            return '{"data":[{"count_":1}],"count":1}'
        }
        if ($Global:StandInNoResources) { return '{"data":[],"count":0}' }
        $Row = @{ id = ('/subscriptions/{0}/resourceGroups/rg-demo/providers/Microsoft.Network/networkSecurityGroups/nsg-demo' -f $SubId); name = 'nsg-demo'; type = 'microsoft.network/networksecuritygroups'; location = 'eastus'; subscriptionId = $SubId; resourceGroup = 'rg-demo'; properties = @{} }
        return (@{ data = @($Row); count = 1 } | ConvertTo-Json -Depth 5 -Compress)
    }
    return $null
}
}
function global:Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = 'tenant-demo' }; Subscription = [pscustomobject]@{ Id = '12345678-1234-1234-1234-123456789012'; Name = 'Demo Subscription' }; Account = [pscustomobject]@{ Id = 'tester' } } }
function global:Connect-AzAccount { throw 'no sign-in in this harness' }
# A direct run checks read access up front: the object id in the Resource
# Manager token, the caller's role assignments and their role definition, and
# Azure's permissions answer. These answer as for a Reader assignment on the
# subscription, so the subscription is readable. Any other Resource Manager
# call fails, so a new one shows up here.
function global:Get-AzAccessToken { param($ResourceUrl) [pscustomobject]@{ Token = ('e30.' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"oid":"test-oid"}')).TrimEnd('=') + '.sig') } }
function global:Invoke-AzRestMethod
{
    param($Method, $Path, $Payload, $Uri)
    $Target = if ($Path) { $Path } else { $Uri }
    $Json = { param($Obj) [pscustomobject]@{ StatusCode = 200; Content = ($Obj | ConvertTo-Json -Depth 10) } }
    if ($Target -match '/roleAssignments\?')
    {
        return (& $Json @{ value = @(@{ properties = @{ roleDefinitionId = "/subscriptions/$SubId/providers/Microsoft.Authorization/roleDefinitions/reader"; scope = "/subscriptions/$SubId"; principalId = 'test-oid'; principalType = 'ServicePrincipal' } }) })
    }
    if ($Target -match '/roleDefinitions/')
    {
        return (& $Json @{ properties = @{ roleName = 'Reader'; type = 'BuiltInRole'; permissions = @(@{ actions = @('*/read'); notActions = @() }) } })
    }
    if ($Target -match '/providers/Microsoft\.Authorization/permissions\?')
    {
        return (& $Json @{ value = @(@{ actions = @('*/read'); notActions = @() }) })
    }
    throw ('no stand-in for {0} {1}' -f $Method, $Target)
}

$Params = @{ SkipMetrics = $true; SkipConsumption = $true; OutputDirectory = $Out }
if (-not $NoSubscriptionID) { $Params.SubscriptionID = $SubId }
if ($Service) { $Params.Service = @($Service -split ',') }
if ($RunAllSubs) { $Params.RunAllSubs = $true }
if ($ResourceGroup) { $Params.ResourceGroup = $ResourceGroup }
if ($TenantID) { $Params.TenantID = $TenantID }
if ($Appid) { $Params.Appid = $Appid }
Set-Location $(if ($Cwd) { $Cwd } else { $Tree })
$global:LASTEXITCODE = 0
& (Join-Path $Tree 'ResourceInventory.ps1') @Params
$Code = $LASTEXITCODE
@{ ExitCode = $Code } | ConvertTo-Json -Compress | Set-Content -LiteralPath $StateFile
exit $Code
'@ | Set-Content -Path $script:Harness -Encoding utf8

    # Runs one run in a child pwsh and returns its process exit code, what the
    # harness saw inside, the console lines and the files written.
    # -UnwritableOut points -OutputDirectory below a file, so the folder cannot
    # be created or written on any OS.
    function Invoke-StandInRun
    {
        param([string]$Tree = $script:Tree, [string]$Service, [switch]$RunAllSubs, [switch]$NoResources,
            [switch]$FromOtherFolder, [string]$ResourceGroup, [switch]$NoSubscriptionID, [string]$TenantID, [string]$Appid,
            [switch]$SignedOut, [switch]$NoAzCli, [switch]$UnwritableOut)

        $Name = [guid]::NewGuid().ToString('N')
        $Out = Join-Path $script:WorkDir ('out_' + $Name)
        if ($UnwritableOut)
        {
            $Blocker = Join-Path $script:WorkDir ('file_' + $Name)
            Set-Content -LiteralPath $Blocker -Value 'not a folder'
            $Out = Join-Path $Blocker 'out'
        }
        else
        {
            New-Item -ItemType Directory -Path $Out -Force | Out-Null
        }
        $StateFile = Join-Path $script:WorkDir ('state_' + $Name + '.json')

        $ArgList = @('-NoProfile', '-NonInteractive', '-File', $script:Harness, '-Tree', $Tree, '-Out', $Out, '-StateFile', $StateFile)
        if ($Service) { $ArgList += @('-Service', $Service) }
        if ($RunAllSubs) { $ArgList += '-RunAllSubs' }
        if ($NoResources) { $ArgList += '-NoResources' }
        if ($FromOtherFolder)
        {
            $Cwd = Join-Path $script:WorkDir ('cwd_' + $Name)
            New-Item -ItemType Directory -Path $Cwd -Force | Out-Null
            $ArgList += @('-Cwd', $Cwd)
        }
        if ($ResourceGroup) { $ArgList += @('-ResourceGroup', $ResourceGroup) }
        if ($NoSubscriptionID) { $ArgList += '-NoSubscriptionID' }
        if ($TenantID) { $ArgList += @('-TenantID', $TenantID) }
        if ($Appid) { $ArgList += @('-Appid', $Appid) }
        if ($SignedOut) { $ArgList += '-SignedOut' }
        if ($NoAzCli) { $ArgList += '-NoAzCli' }

        $Console = @(& pwsh @ArgList 2>&1 | ForEach-Object { [string]$_ })
        $ProcessExit = $LASTEXITCODE
        $Lines = @($Console | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

        return [pscustomobject]@{
            ProcessExit = $ProcessExit
            State       = $(if (Test-Path -LiteralPath $StateFile) { Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json } else { $null })
            Console     = ($Console -join "`n")
            Lines       = $Lines
            LastLine    = $(if ($Lines.Count -gt 0) { $Lines[-1] } else { '' })
            Zip         = @(Get-ChildItem -Path $Out -Filter 'ResourcesReport_*.zip' -File -ErrorAction SilentlyContinue)
        }
    }

    $script:BreakerServices = 'StandInBreak1,StandInBreak2,StandInBreak3,StandInBreak4,StandInBreak5,StandInWorking'
}

AfterAll {
    if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir))
    {
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Direct run stopped by the collector circuit breaker' {
    BeforeAll {
        $script:Breaker = Invoke-StandInRun -Service $script:BreakerServices
    }

    It 'writes no zip' {
        $script:Breaker.Console | Should -Match 'Collector FAILED: StandInBreak5'
        $script:Breaker.Zip.Count | Should -Be 0
    }

    It 'ends with a red line saying no report was written, not with the missing zip' {
        $script:Breaker.LastLine | Should -Match 'No report was written: .*ResourcesReport_.*\.zip was not created'
        $script:Breaker.Console | Should -Not -Match 'Reporting Data File: '
        $LastFailure = [array]::FindLastIndex([string[]]$script:Breaker.Lines, [Predicate[string]] { param($l) $l -match 'Collector FAILED: ' })
        $NoReport = [array]::FindIndex([string[]]$script:Breaker.Lines, [Predicate[string]] { param($l) $l -match 'No report was written: ' })
        $NoReport | Should -BeGreaterThan $LastFailure
    }

    It 'exits 2' {
        $script:Breaker.ProcessExit | Should -Be 2
        $script:Breaker.State.ExitCode | Should -Be 2
    }
}

Describe 'Direct run whose HTML report fails' {
    It 'writes no zip and exits 2' {
        $Run = Invoke-StandInRun -Tree $script:BrokenSummaryTree -Service 'StandInWorking'
        $Run.Console | Should -Match 'HTML report generation FAILED: stand-in report failure'
        $Run.Zip.Count | Should -Be 0
        $Run.LastLine | Should -Match 'No report was written: '
        $Run.ProcessExit | Should -Be 2
    }
}

Describe 'Direct run that writes its report' {
    It 'exits 0 and names the zip, as before' {
        $Run = Invoke-StandInRun -Service 'StandInWorking'
        $Run.Zip.Count | Should -Be 1
        $Run.LastLine | Should -Match 'Reporting Data File: .*ResourcesReport_.*\.zip'
        $Run.Console | Should -Not -Match 'No report was written'
        $Run.ProcessExit | Should -Be 0
    }

    It 'exits 0 for a subscription with no resources' {
        $Run = Invoke-StandInRun -Service 'StandInWorking' -NoResources
        $Run.Zip.Count | Should -Be 1
        $Run.Console | Should -Not -Match 'No report was written'
        $Run.ProcessExit | Should -Be 0
    }
}

Describe 'Run under -RunAllSubs stopped by the collector circuit breaker' {
    It 'keeps its exit code 0 and its last line; the wrapper checks the zip' {
        $Run = Invoke-StandInRun -Service $script:BreakerServices -RunAllSubs
        $Run.Zip.Count | Should -Be 0
        $Run.Console | Should -Not -Match 'No report was written'
        $Run.LastLine | Should -Match 'Reporting Data File: '
        $Run.State.ExitCode | Should -Be 0
        $Run.ProcessExit | Should -Be 0
    }
}

Describe 'Direct run that stops during setup' {
    It 'exits 1 before signing in when the output folder cannot be written' {
        $Run = Invoke-StandInRun -Service 'StandInWorking' -UnwritableOut
        $Run.Console | Should -Match 'ERROR: Pre-flight: cannot write to '
        $Run.Console | Should -Not -Match 'Pre-flight checks passed'
        $Run.Console | Should -Not -Match 'Extracting Resources'
        $Run.ProcessExit | Should -Be 1
    }

    It 'exits 1 when the Azure CLI is not installed' {
        $Run = Invoke-StandInRun -Service 'StandInWorking' -NoAzCli
        $Run.Console | Should -Match 'Azure CLI Not Found'
        $Run.Zip.Count | Should -Be 0
        $Run.ProcessExit | Should -Be 1
    }

    It 'exits 1 when the service principal sign-in has no secret' {
        $Run = Invoke-StandInRun -Service 'StandInWorking' -SignedOut -TenantID 'tenant-other' -Appid 'app-demo'
        $Run.Console | Should -Match 'Service Principal Authentication Method in a wrong way'
        $Run.Zip.Count | Should -Be 0
        $Run.ProcessExit | Should -Be 1
    }

    It 'exits 1 when -ResourceGroup is given without -SubscriptionID' {
        $Run = Invoke-StandInRun -Service 'StandInWorking' -ResourceGroup 'rg-demo' -NoSubscriptionID
        $Run.Console | Should -Match 'Resource Group Name present, but missing Subscription ID'
        $Run.Zip.Count | Should -Be 0
        $Run.ProcessExit | Should -Be 1
    }

    It 'exits 1 when Version.json is missing' {
        $Run = Invoke-StandInRun -Tree $script:NoVersionJsonTree -Service 'StandInWorking'
        $Run.Console | Should -Match 'Local Version.json not found'
        $Run.Zip.Count | Should -Be 0
        $Run.ProcessExit | Should -Be 1
    }
}

Describe 'Run started from another folder' {
    It 'finds Version.json next to the script and writes its report' {
        $Run = Invoke-StandInRun -Service 'StandInWorking' -FromOtherFolder
        $Run.Console | Should -Not -Match 'Version.json not found'
        $Run.Zip.Count | Should -Be 1
        $Run.LastLine | Should -Match 'Reporting Data File: '
        $Run.ProcessExit | Should -Be 0
    }

    It 'writes its report under -RunAllSubs too' {
        $Run = Invoke-StandInRun -Service 'StandInWorking' -FromOtherFolder -RunAllSubs
        $Run.Console | Should -Not -Match 'Version.json not found'
        $Run.Zip.Count | Should -Be 1
        $Run.State.ExitCode | Should -Be 0
    }
}

Describe 'Setup failure under -RunAllSubs' {
    It 'returns 1 to the caller, so the wrapper records a failed subscription' {
        $Run = Invoke-StandInRun -Tree $script:NoVersionJsonTree -Service 'StandInWorking' -RunAllSubs
        $Run.Console | Should -Match 'Local Version.json not found'
        $Run.State.ExitCode | Should -Be 1
    }
}
