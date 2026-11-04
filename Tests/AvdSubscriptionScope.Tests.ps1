# AVD discovery subscription scope tests
# Run with: Invoke-Pester ./Tests/AvdSubscriptionScope.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# Host pools come from the resources table, which a -SubscriptionID run reads
# for that subscription only. Session hosts come from a second Resource Graph
# table (desktopvirtualizationresources), and that query named every
# subscription the identity can see, also under -SubscriptionID. The wrapper
# runs one -SubscriptionID run per subscription, so every one of them read the
# other subscriptions' session hosts too. Their real ids went into each run's
# obfuscation dictionary, each run gave them its own tokens (one resource with
# a different token in every dictionary), and an empty subscription counted
# them as its own resources.
#
# The tests copy the script and its folders to a temp dir and run the REAL
# ResourceInventory.ps1 -Obfuscate -Service AVD in a child pwsh with offline
# stand-ins: two subscriptions, a host pool with one session host in each. The
# Resource Graph stand-in filters rows by the subscriptions a request names, as
# Resource Graph does. No live Azure. Generic names and placeholder ids only.

BeforeAll {
    $env:RDA_AZPS_STANDINS = Join-Path $PSScriptRoot 'Helpers/AzPsStandIns.ps1'
    $script:RepoRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' | Resolve-Path | Select-Object -ExpandProperty Path
    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ("AvdSubscriptionScope_" + [guid]::NewGuid().ToString('N'))
    $script:Tree = Join-Path $script:WorkDir 'tree'
    New-Item -ItemType Directory -Path $script:Tree -Force | Out-Null
    foreach ($Item in @('ResourceInventory.ps1', 'Version.json', 'Functions', 'Extension', 'Services'))
    {
        Copy-Item -Path (Join-Path $script:RepoRoot $Item) -Destination $script:Tree -Recurse -Force
    }

    $script:SubA = '11111111-1111-1111-1111-111111111111'
    $script:SubB = '22222222-2222-2222-2222-222222222222'

    $script:Harness = Join-Path $script:WorkDir 'run.ps1'
    @'
param([string]$Tree, [string]$Out, [string]$StateDir, [string]$Scope)
$PSStyle.OutputRendering = 'PlainText'
$Global:RdaSessionInitialized = $true
$Global:AzPowerShellLoaded = $true
$Global:PlatformOS = 'PowerShell Unix'
$Global:HCallLog = Join-Path $StateDir 'graph-calls.log'
$SubA = '11111111-1111-1111-1111-111111111111'
$SubB = '22222222-2222-2222-2222-222222222222'
$Global:StandInSubs = @(
    [pscustomobject]@{ id = $SubA; name = 'Demo Subscription A'; tenantId = 'tenant-demo'; state = 'Enabled' },
    [pscustomobject]@{ id = $SubB; name = 'Demo Subscription B'; tenantId = 'tenant-demo'; state = 'Enabled' }
)
function global:Get-StandInPoolId([string]$Sub, [string]$Pool) { '/subscriptions/{0}/resourcegroups/rg-avd/providers/microsoft.desktopvirtualization/hostpools/{1}' -f $Sub, $Pool }
function global:Get-StandInPools
{
    foreach ($P in @(@{ Sub = $SubA; Pool = 'hp-a' }, @{ Sub = $SubB; Pool = 'hp-b' }))
    {
        @{ id = (Get-StandInPoolId $P.Sub $P.Pool); name = $P.Pool; type = 'microsoft.desktopvirtualization/hostpools'; location = 'eastus'; subscriptionId = $P.Sub; resourceGroup = 'rg-avd'; properties = @{ hostPoolType = 'Pooled'; loadBalancerType = 'BreadthFirst'; maxSessionLimit = 10; preferredAppGroupType = 'Desktop' } }
    }
}
function global:Get-StandInHosts
{
    foreach ($P in @(@{ Sub = $SubA; Pool = 'hp-a'; Host = 'sh-a.demo.local' }, @{ Sub = $SubB; Pool = 'hp-b'; Host = 'sh-b.demo.local' }))
    {
        @{ id = ('{0}/sessionhosts/{1}' -f (Get-StandInPoolId $P.Sub $P.Pool), $P.Host); name = ('{0}/{1}' -f $P.Pool, $P.Host); type = 'microsoft.desktopvirtualization/hostpools/sessionhosts'; location = 'eastus'; subscriptionId = $P.Sub; resourceGroup = 'rg-avd'; properties = @{ agentVersion = '1.0.0'; allowNewSession = $true; status = 'Available'; updateState = 'Succeeded' } }
    }
}
function global:Invoke-StandInGraph
{
    $global:LASTEXITCODE = 0
    $Joined = $args -join ' '
    if ($Joined -like 'account*') { return '{}' }
    # The subscriptions the request names, as Resource Graph filters by them.
    $Named = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $args.Count; $i++)
    {
        if ($args[$i] -ne '--subscriptions') { continue }
        for ($j = $i + 1; $j -lt $args.Count -and -not ([string]$args[$j]).StartsWith('--'); $j++) { $Named.Add([string]$args[$j]) }
    }
    $Table = if ($Joined -match 'desktopvirtualizationresources') { 'avd' } else { 'resources' }
    Add-Content -LiteralPath $Global:HCallLog -Value ('{0} subs={1}' -f $Table, (($Named | Sort-Object) -join ','))
    $Rows = @(if ($Table -eq 'avd') { Get-StandInHosts } else { Get-StandInPools })
    $Rows = @($Rows | Where-Object { $Named -contains $_.subscriptionId })
    if ($Joined -match 'summarize count\(\)') { return ('{{"data":[{{"count_":{0}}}],"count":1}}' -f $Rows.Count) }
    return (@{ data = $Rows; count = $Rows.Count } | ConvertTo-Json -Depth 8 -Compress)
}
function global:Start-Sleep { param([Parameter(Position = 0)][double]$Seconds, [int]$Milliseconds) }
function global:Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = 'tenant-demo' }; Subscription = [pscustomobject]@{ Id = $SubA; Name = 'Demo Subscription A' }; Account = [pscustomobject]@{ Id = 'tester' } } }
function global:Connect-AzAccount { throw 'no sign-in in this harness' }
function global:Get-AzAccessToken { param($ResourceUrl) [pscustomobject]@{ Token = ('e30.' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"oid":"test-oid"}')).TrimEnd('=') + '.sig') } }
# Reader on whichever subscription a role check asks about.
function global:Invoke-AzRestMethod
{
    param($Method, $Path, $Payload, $Uri)
    $Target = if ($Path) { $Path } else { $Uri }
    $Sub = if ($Target -match '/subscriptions/([^/?]+)') { $Matches[1] } else { $SubA }
    $Json = { param($Obj) [pscustomobject]@{ StatusCode = 200; Content = ($Obj | ConvertTo-Json -Depth 10) } }
    if ($Target -match '/roleAssignments\?')
    {
        return (& $Json @{ value = @(@{ properties = @{ roleDefinitionId = "/subscriptions/$Sub/providers/Microsoft.Authorization/roleDefinitions/reader"; scope = "/subscriptions/$Sub"; principalId = 'test-oid'; principalType = 'ServicePrincipal' } }) })
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
. $env:RDA_AZPS_STANDINS
$Params = @{ SkipMetrics = $true; SkipConsumption = $true; OutputDirectory = $Out; Service = @('AVD'); Obfuscate = $true }
if ($Scope -eq 'SubscriptionA') { $Params.SubscriptionID = $SubA }
if ($Scope -eq 'ResourceGroupA') { $Params.SubscriptionID = $SubA; $Params.ResourceGroup = 'rg-avd' }
# A run over every subscription checks their roles side by side in other
# runspaces, where these stand-ins do not exist; -RunAllSubs leaves that check
# to the wrapper, so the control runs with it.
if ($Scope -eq 'All') { $Params.RunAllSubs = $true }
Set-Location $Tree
$global:LASTEXITCODE = 0
& (Join-Path $Tree 'ResourceInventory.ps1') @Params
exit $LASTEXITCODE
'@ | Set-Content -Path $script:Harness -Encoding utf8

    # One direct run in a child pwsh: exit code, console, the Resource Graph
    # requests it made and the real ids its obfuscation dictionary holds.
    function Invoke-AvdScopeRun
    {
        param([string]$Scope)
        $Name = [guid]::NewGuid().ToString('N')
        $Out = Join-Path $script:WorkDir ('out_' + $Name)
        $StateDir = Join-Path $script:WorkDir ('state_' + $Name)
        New-Item -ItemType Directory -Path $Out, $StateDir -Force | Out-Null
        $Console = @(& pwsh -NoProfile -NonInteractive -File $script:Harness -Tree $script:Tree -Out $Out -StateDir $StateDir -Scope $Scope 2>&1 | ForEach-Object { [string]$_ })
        $ProcessExit = $LASTEXITCODE
        $CallLog = Join-Path $StateDir 'graph-calls.log'
        $DictFile = @(Get-ChildItem -Path $Out -Filter 'ObfuscationDictionary_*.json' -File -Recurse)
        $RealIds = @()
        if ($DictFile.Count -eq 1)
        {
            $Dict = Get-Content -LiteralPath $DictFile[0].FullName -Raw | ConvertFrom-Json
            $RealIds = @($Dict.ResourceIdMap.PSObject.Properties | ForEach-Object { [string]$_.Value })
        }
        return [pscustomobject]@{
            ProcessExit = $ProcessExit
            Console     = ($Console -join "`n")
            Calls       = @(if (Test-Path -LiteralPath $CallLog) { Get-Content -LiteralPath $CallLog })
            DictCount   = $DictFile.Count
            RealIds     = $RealIds
        }
    }
}

AfterAll {
    if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir))
    {
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'AVD session hosts follow the run''s subscription scope' {

    It 'a -SubscriptionID run asks the AVD table for that subscription only' {
        $Run = Invoke-AvdScopeRun -Scope 'SubscriptionA'
        $Run.ProcessExit | Should -Be 0 -Because $Run.Console
        @($Run.Calls | Where-Object { $_ -like 'avd *' }) | Should -Not -BeNullOrEmpty
        @($Run.Calls | Where-Object { $_ -like 'avd *' -and $_ -ne ('avd subs={0}' -f $script:SubA) }) | Should -BeNullOrEmpty -Because ($Run.Calls -join '; ')
        $Run.Console | Should -Match 'AVD Resources Output: 1 AVD Resources Identified'
    }

    It 'a -SubscriptionID run keeps no other subscription''s session host in its dictionary' {
        $Run = Invoke-AvdScopeRun -Scope 'SubscriptionA'
        $Run.ProcessExit | Should -Be 0 -Because $Run.Console
        $Run.DictCount | Should -Be 1
        @($Run.RealIds | Where-Object { $_ -match $script:SubB }) | Should -BeNullOrEmpty
        @($Run.RealIds | Where-Object { $_ -match '/sessionhosts/sh-a\.demo\.local$' }).Count | Should -Be 1
    }

    It 'a -ResourceGroup run asks the AVD table for its subscription only' {
        $Run = Invoke-AvdScopeRun -Scope 'ResourceGroupA'
        $Run.ProcessExit | Should -Be 0 -Because $Run.Console
        @($Run.Calls | Where-Object { $_ -like 'avd *' -and $_ -ne ('avd subs={0}' -f $script:SubA) }) | Should -BeNullOrEmpty -Because ($Run.Calls -join '; ')
    }

    It 'a run over every subscription still asks the AVD table for all of them (control)' {
        $Run = Invoke-AvdScopeRun -Scope 'All'
        $Run.ProcessExit | Should -Be 0 -Because $Run.Console
        $Expected = 'avd subs={0}' -f ((@($script:SubA, $script:SubB) | Sort-Object) -join ',')
        @($Run.Calls | Where-Object { $_ -like 'avd *' }) | Should -Not -BeNullOrEmpty
        @($Run.Calls | Where-Object { $_ -like 'avd *' -and $_ -ne $Expected }) | Should -BeNullOrEmpty -Because ($Run.Calls -join '; ')
        @($Run.RealIds | Where-Object { $_ -match '/sessionhosts/' }).Count | Should -Be 2
    }
}
