# Direct-run exit code tests
# Run with: Invoke-Pester ./Tests/DirectRunExitCode.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# When a Services/*/*.ps1 collector throws, ResourceInventory.ps1 logs it,
# names the missing type in the report and carries on. A direct run (no
# -RunAllSubs) then exits 4 once the report and zip are written, so
# automation can tell the report is incomplete; with no collector failure it
# exits 0. A run whose collector failures left it without a zip does not exit
# 4, because 4 promises a written report. Under -RunAllSubs the script does
# not exit 4: every wrapper call site treats a non-zero exit as a failed
# subscription, and the wrapper reports collector failures through its own
# exit code.
#
# This test is SELF-CONTAINED: it copies the script and its folders to a temp
# dir, adds small collectors there (one returns a record, the others throw),
# and runs the REAL ResourceInventory.ps1 in a child pwsh with -SkipMetrics
# -SkipConsumption and offline stand-ins for the Azure CLI and Az calls the
# run makes. No live Azure. Generic names and the documentation placeholder
# subscription id only.

BeforeAll {
    $script:RepoRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' | Resolve-Path | Select-Object -ExpandProperty Path
    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ("DirectRunExitCode_" + [guid]::NewGuid().ToString('N'))
    $script:Tree = Join-Path $script:WorkDir 'tree'
    New-Item -ItemType Directory -Path $script:Tree -Force | Out-Null

    foreach ($Item in @('ResourceInventory.ps1', 'Version.json', 'Functions', 'Extension', 'Services'))
    {
        Copy-Item -Path (Join-Path $script:RepoRoot $Item) -Destination $script:Tree -Recurse -Force
    }

    $StandInServices = Join-Path $script:Tree 'Services/StandIn'
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
    @'
param($Sub, $Resources, $Task, $ResourceIdDictionary)
if ($Task -eq 'Processing') { throw 'stand-in collector error' }
'@ | Set-Content -Path (Join-Path $StandInServices 'StandInFailing.ps1') -Encoding utf8
    # Five failing collectors in a row trip the collector circuit breaker, which
    # ends the collection phase before the inventory is written: no report.
    foreach ($i in 1..5)
    {
        "param(`$Sub, `$Resources, `$Task, `$ResourceIdDictionary)`nif (`$Task -eq 'Processing') { throw 'stand-in collector error $i' }" |
            Set-Content -Path (Join-Path $StandInServices ("StandInBreak{0}.ps1" -f $i)) -Encoding utf8
    }

    # Child-process harness: stand-ins for the az CLI and Az cmdlets, then the
    # real script. -Service arrives as one comma-separated string because
    # pwsh -File does not bind arrays.
    $script:Harness = Join-Path $script:WorkDir 'run.ps1'
    @'
param([string]$Tree, [string]$Out, [string]$Service, [switch]$RunAllSubs, [string]$StateFile)
$PSStyle.OutputRendering = 'PlainText'
$Global:RdaSessionInitialized = $true
$Global:AzPowerShellLoaded = $true
$Global:PlatformOS = 'PowerShell Unix'
$SubId = '12345678-1234-1234-1234-123456789012'
$Global:StandInSubs = @([pscustomobject]@{ id = $SubId; name = 'Demo Subscription'; tenantId = 'tenant-demo'; state = 'Enabled' })
function global:az
{
    $Joined = $args -join ' '
    $global:LASTEXITCODE = 0
    if ($Joined -like 'account show*') { return '{"user":{"name":"tester"},"tenantId":"tenant-demo"}' }
    if ($Joined -like 'account list*') { return (ConvertTo-Json -InputObject @($Global:StandInSubs) -Compress) }
    if ($Joined -like 'graph*')
    {
        if ($Joined -match 'desktopvirtualizationresources') { return '{"data":[{"count_":0}],"count":1}' }
        if ($Joined -match 'summarize count\(\)') { return '{"data":[{"count_":1}],"count":1}' }
        $Row = @{ id = ('/subscriptions/{0}/resourceGroups/rg-demo/providers/Microsoft.Network/networkSecurityGroups/nsg-demo' -f $SubId); name = 'nsg-demo'; type = 'microsoft.network/networksecuritygroups'; location = 'eastus'; subscriptionId = $SubId; resourceGroup = 'rg-demo'; properties = @{} }
        return (@{ data = @($Row); count = 1 } | ConvertTo-Json -Depth 5 -Compress)
    }
    return $null
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

$Params = @{ SubscriptionID = $SubId; SkipMetrics = $true; SkipConsumption = $true; OutputDirectory = $Out }
if ($Service) { $Params.Service = @($Service -split ',') }
if ($RunAllSubs) { $Params.RunAllSubs = $true }
Set-Location $Tree
$global:LASTEXITCODE = 0
& (Join-Path $Tree 'ResourceInventory.ps1') @Params
$Code = $LASTEXITCODE
@{ ExitCode = $Code; CollectorFailures = @($Global:CollectorFailures).Count } | ConvertTo-Json -Compress | Set-Content -LiteralPath $StateFile
exit $Code
'@ | Set-Content -Path $script:Harness -Encoding utf8

    # Runs one direct run in a child pwsh and returns its process exit code,
    # what the harness saw inside, the console text and the files written.
    function Invoke-DirectRun
    {
        param([string]$Service, [switch]$RunAllSubs)

        $Name = [guid]::NewGuid().ToString('N')
        $Out = Join-Path $script:WorkDir ('out_' + $Name)
        New-Item -ItemType Directory -Path $Out -Force | Out-Null
        $StateFile = Join-Path $script:WorkDir ('state_' + $Name + '.json')

        $ArgList = @('-NoProfile', '-NonInteractive', '-File', $script:Harness, '-Tree', $script:Tree, '-Out', $Out, '-StateFile', $StateFile)
        if ($Service) { $ArgList += @('-Service', $Service) }
        if ($RunAllSubs) { $ArgList += '-RunAllSubs' }

        $Console = @(& pwsh @ArgList 2>&1 | ForEach-Object { [string]$_ })
        $ProcessExit = $LASTEXITCODE

        return [pscustomobject]@{
            ProcessExit = $ProcessExit
            State       = $(if (Test-Path -LiteralPath $StateFile) { Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json } else { $null })
            Console     = ($Console -join "`n")
            Html        = @(Get-ChildItem -Path $Out -Filter 'ResourcesReport_*.html' -File)
            Zip         = @(Get-ChildItem -Path $Out -Filter 'ResourcesReport_*.zip' -File)
        }
    }
}

AfterAll {
    if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir))
    {
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Direct run with a failing collector' {
    BeforeAll {
        $script:Failed = Invoke-DirectRun -Service 'StandInWorking,StandInFailing'
    }

    It 'still writes the HTML report and the zip' {
        $script:Failed.Html.Count | Should -Be 1
        $script:Failed.Zip.Count | Should -Be 1
        $script:Failed.Console | Should -Match 'Reporting Data File: '
    }

    It 'names the failed collector in the report' {
        Get-Content -LiteralPath $script:Failed.Html[0].FullName -Raw | Should -Match '<b>Incomplete collection:</b> 1 resource type\(s\).*StandInFailing'
    }

    It 'exits 4' {
        $script:Failed.ProcessExit | Should -Be 4
        $script:Failed.State.ExitCode | Should -Be 4
    }
}

Describe 'Direct run with no collector failure' {
    BeforeAll {
        $script:Clean = Invoke-DirectRun -Service 'StandInWorking'
    }

    It 'writes the HTML report and the zip with no banner' {
        $script:Clean.Html.Count | Should -Be 1
        $script:Clean.Zip.Count | Should -Be 1
        Get-Content -LiteralPath $script:Clean.Html[0].FullName -Raw | Should -Not -Match 'Incomplete collection:'
    }

    It 'exits 0' {
        $script:Clean.ProcessExit | Should -Be 0
        $script:Clean.State.ExitCode | Should -Be 0
    }
}

Describe 'Direct run that stops in pre-flight' {
    It 'still exits 1 when -Service matches no collector' {
        $Run = Invoke-DirectRun -Service 'NoSuchCollector'
        $Run.ProcessExit | Should -Be 1
        $Run.Html.Count | Should -Be 0
    }
}

Describe 'Direct run with collector failures that wrote no report' {
    It 'does not exit 4 when the circuit breaker ended collection before the report' {
        $Run = Invoke-DirectRun -Service 'StandInBreak1,StandInBreak2,StandInBreak3,StandInBreak4,StandInBreak5'
        $Run.Console | Should -Match 'Collector FAILED: StandInBreak5'
        $Run.Zip.Count | Should -Be 0
        $Run.ProcessExit | Should -Not -Be 4
    }
}

Describe 'Run under -RunAllSubs with a failing collector' {
    BeforeAll {
        $script:Wrapped = Invoke-DirectRun -Service 'StandInWorking,StandInFailing' -RunAllSubs

        # The statement each wrapper call site runs right after
        # '& ResourceInventory.ps1 ... -RunAllSubs'.
        $script:CallSiteGuards = @()
        foreach ($File in @('Run-AllSubscriptions.ps1', 'Run-AllSubscriptions.Stream.ps1'))
        {
            $Lines = Get-Content -LiteralPath (Join-Path $script:RepoRoot $File)
            for ($i = 0; $i -lt $Lines.Count; $i++)
            {
                if ($Lines[$i] -match "ResourceInventory\.ps1.*-RunAllSubs\s*$")
                {
                    $Next = @($Lines[($i + 1)..([math]::Min($i + 8, $Lines.Count - 1))] | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') }) | Select-Object -First 1
                    $script:CallSiteGuards += [pscustomobject]@{ File = $File; Line = $i + 1; Guard = $Next.Trim() }
                }
            }
        }
    }

    It 'writes the report and records the failure for the wrapper' {
        $script:Wrapped.Html.Count | Should -Be 1
        $script:Wrapped.State.CollectorFailures | Should -Be 1
    }

    It 'exits 0, which every wrapper call site treats as a completed subscription' {
        $script:Wrapped.State.ExitCode | Should -Be 0
        $script:CallSiteGuards.Count | Should -Be 3
        foreach ($Site in $script:CallSiteGuards)
        {
            $Site.Guard | Should -Be 'if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "Script exited with code $LASTEXITCODE" }'
            $Check = [scriptblock]::Create($Site.Guard)
            $global:LASTEXITCODE = $script:Wrapped.State.ExitCode
            { & $Check } | Should -Not -Throw
        }
    }
}
