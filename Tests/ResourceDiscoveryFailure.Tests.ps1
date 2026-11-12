# Resource discovery failure tests
# Run with: Invoke-Pester ./Tests/ResourceDiscoveryFailure.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# ResourceInventory.ps1 sets $ErrorActionPreference to 'SilentlyContinue' unless
# -Debug is passed. Under that preference a throw that nothing catches does not
# stop the script; it carries on with the next statement. Invoke-AzGraphQuerySafe
# reports a failed Resource Graph call by throwing, so in a direct run a page
# that could not be read was left out of the inventory with no error and exit
# code 0, and a failure that did not go away was retried without end instead of
# the 4 attempts the helper allows. Run-AllSubscriptions.ps1 calls the script
# inside try, so under the wrapper the same throw reached its catch and the
# subscription was recorded as failed.
#
# A direct run now stops with exit 1 before any report is written. Under
# -RunAllSubs the error is passed on unchanged, so the wrapper still records the
# subscription as failed with the Resource Graph error as the reason.
#
# Pester catches every throw, so this cannot be shown in-process. The tests copy
# the script and its folders to a temp dir and run the REAL ResourceInventory.ps1
# in a child pwsh, with -SkipMetrics -SkipConsumption -Service PublicIP and
# offline stand-ins for the Azure CLI and Az calls the run makes. Discovery
# returns 1,001 resources: a full first page of 1,000 and a second page of 1.
# No live Azure. Generic names and the documentation placeholder subscription id
# only.

BeforeAll {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $script:RepoRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' | Resolve-Path | Select-Object -ExpandProperty Path
    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ("ResourceDiscoveryFailure_" + [guid]::NewGuid().ToString('N'))
    $script:Tree = Join-Path $script:WorkDir 'tree'
    New-Item -ItemType Directory -Path $script:Tree -Force | Out-Null

    foreach ($Item in @('ResourceInventory.ps1', 'Version.json', 'Functions', 'Extension', 'Services'))
    {
        Copy-Item -Path (Join-Path $script:RepoRoot $Item) -Destination $script:Tree -Recurse -Force
    }

    # Child-process harness. Scenario 'ok' reads every page. 'emptykey' gives the
    # last resource a property whose name is empty, which ConvertFrom-Json cannot
    # read, so the second page cannot be parsed. 'toolarge' fails the second page
    # with ResponsePayloadTooLarge six times and then answers, so the run also ends
    # when every failed call is retried. The retry backoff and the pause between
    # pages do not wait, so the suite runs in seconds.
    $script:Harness = Join-Path $script:WorkDir 'run.ps1'
    @'
param([string]$Tree, [string]$Out, [string]$Scenario, [string]$StateDir, [switch]$RunAllSubs)
$PSStyle.OutputRendering = 'PlainText'
$Global:RdaSessionInitialized = $true
$Global:AzPowerShellLoaded = $true
$Global:PlatformOS = 'PowerShell Unix'
$Global:HScenario = $Scenario
$Global:HCallLog = Join-Path $StateDir 'graph-pages.log'
$SubId = '12345678-1234-1234-1234-123456789012'
$Global:StandInSubs = @([pscustomobject]@{ id = $SubId; name = 'Demo Subscription'; tenantId = 'tenant-demo'; state = 'Enabled' })
function global:New-StandInPublicIp([int]$Index, [switch]$EmptyKey)
{
    $Props = @{ publicIPAllocationMethod = 'Static'; publicIPAddressVersion = 'IPv4'; provisioningState = 'Succeeded' }
    if ($EmptyKey) { $Props['definition'] = @{ '' = 'unnamed' } }
    @{ id = ('/subscriptions/{0}/resourceGroups/rg-demo/providers/Microsoft.Network/publicIPAddresses/pip-demo-{1}' -f $Global:StandInSubs[0].id, $Index); name = ('pip-demo-{0}' -f $Index); type = 'microsoft.network/publicipaddresses'; location = 'eastus'; subscriptionId = $Global:StandInSubs[0].id; resourceGroup = 'rg-demo'; sku = @{ name = 'Standard' }; properties = $Props }
}
function global:az
{
    $Joined = $args -join ' '
    $global:LASTEXITCODE = 0
    if ($Joined -like 'account show*') { return '{"user":{"name":"tester"},"tenantId":"tenant-demo"}' }
    if ($Joined -like 'account list*') { return (ConvertTo-Json -InputObject @($Global:StandInSubs) -Compress) }
    if ($Joined -like 'graph*')
    {
        if ($Joined -match 'desktopvirtualizationresources') { return '{"data":[{"count_":0}],"count":1}' }
        if ($Joined -match 'summarize count\(\)') { return '{"data":[{"count_":1001}],"count":1}' }
        $Skip = 0
        if ($Joined -match '--skip (\d+)') { $Skip = [int]$Matches[1] }
        Add-Content -LiteralPath $Global:HCallLog -Value ('skip={0}' -f $Skip)
        if ($Global:HScenario -eq 'toolarge' -and $Skip -ge 1000 -and @(Get-Content -LiteralPath $Global:HCallLog | Where-Object { $_ -eq 'skip=1000' }).Count -le 6)
        {
            $global:LASTEXITCODE = 1
            # The real az CLI writes this to its stderr whatever the error
            # preference; -ErrorAction Continue does the same for the stand-in.
            Write-Error 'ERROR: (ResponsePayloadTooLarge) Response payload size is 17000000, and has exceeded the limit of 16777216.' -ErrorAction Continue
            return
        }
        $Rows = [System.Collections.Generic.List[object]]::new()
        for ($i = $Skip; $i -lt [math]::Min($Skip + 1000, 1001); $i++) { $Rows.Add((New-StandInPublicIp -Index $i -EmptyKey:($Global:HScenario -eq 'emptykey' -and $i -eq 1000))) }
        return (@{ data = @($Rows); count = $Rows.Count } | ConvertTo-Json -Depth 8 -Compress)
    }
    return $null
}
function global:Start-Sleep
{
    param([Parameter(Position = 0)][double]$Seconds, [int]$Milliseconds)
    $Caller = (Get-PSCallStack)[1].Command
    if ($Caller -in @('Invoke-AzGraphQuerySafe', 'ResourceInventoryLoop', 'ResourceInventoryAvd')) { return }
    if ($PSBoundParameters.ContainsKey('Milliseconds')) { Microsoft.PowerShell.Utility\Start-Sleep -Milliseconds $Milliseconds }
    else { Microsoft.PowerShell.Utility\Start-Sleep -Seconds $Seconds }
}
function global:Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = 'tenant-demo' }; Subscription = [pscustomobject]@{ Id = '12345678-1234-1234-1234-123456789012'; Name = 'Demo Subscription' }; Account = [pscustomobject]@{ Id = 'tester' } } }
function global:Connect-AzAccount { throw 'no sign-in in this harness' }
# Where the script checks the identity's roles up front, the calls answer as
# for a Reader assignment on the subscription. Any other Resource Manager call
# fails, so a new one shows up here.
function global:Get-AzAccessToken { param($ResourceUrl) [pscustomobject]@{ Token = ('e30.' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"oid":"test-oid"}')).TrimEnd('=') + '.sig') } }
function global:Invoke-AzRestMethod
{
    param($Method, $Path, $Payload, $Uri)
    $Target = if ($Path) { $Path } else { $Uri }
    $Sub = $Global:StandInSubs[0].id
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

$Params = @{ SubscriptionID = $SubId; SkipMetrics = $true; SkipConsumption = $true; OutputDirectory = $Out; Service = @('PublicIP') }
Set-Location $Tree
$global:LASTEXITCODE = 0
$Caught = $null
if ($RunAllSubs)
{
    # The shape of every Run-AllSubscriptions.ps1 call site: the script runs
    # inside try, and a non-zero exit code is turned into a failure.
    try
    {
        & (Join-Path $Tree 'ResourceInventory.ps1') @Params -RunAllSubs
        if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "Script exited with code $LASTEXITCODE" }
    }
    catch { $Caught = $_.Exception.Message }
}
else
{
    & (Join-Path $Tree 'ResourceInventory.ps1') @Params
}
$Code = $LASTEXITCODE
@{ ExitCode = $Code; Caught = $Caught } | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $StateDir 'state.json')
exit $Code
'@ | Set-Content -Path $script:Harness -Encoding utf8

    # Runs one direct run in a child pwsh and returns its process exit code, what
    # the harness saw inside, the console text, the Resource Graph page requests
    # and the report files written.
    function Invoke-DiscoveryRun
    {
        param([string]$Scenario, [switch]$RunAllSubs)

        $Name = [guid]::NewGuid().ToString('N')
        $Out = Join-Path $script:WorkDir ('out_' + $Name)
        $StateDir = Join-Path $script:WorkDir ('state_' + $Name)
        New-Item -ItemType Directory -Path $Out, $StateDir -Force | Out-Null

        $ArgList = @('-NoProfile', '-NonInteractive', '-File', $script:Harness, '-Tree', $script:Tree, '-Out', $Out, '-Scenario', $Scenario, '-StateDir', $StateDir)
        if ($RunAllSubs) { $ArgList += '-RunAllSubs' }

        $Console = @(& pwsh @ArgList 2>&1 | ForEach-Object { [string]$_ })
        $ProcessExit = $LASTEXITCODE
        $StateFile = Join-Path $StateDir 'state.json'
        $PageLog = Join-Path $StateDir 'graph-pages.log'

        return [pscustomobject]@{
            ProcessExit = $ProcessExit
            State       = $(if (Test-Path -LiteralPath $StateFile) { Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json } else { $null })
            Console     = ($Console -join "`n")
            Pages       = @(if (Test-Path -LiteralPath $PageLog) { Get-Content -LiteralPath $PageLog })
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

Describe 'Direct run: a Resource Graph page that cannot be read' {

    It 'writes the report with every resource and exits 0 when every page reads' {
        $Run = Invoke-DiscoveryRun -Scenario 'ok'
        $Run.ProcessExit | Should -Be 0 -Because $Run.Console
        $Run.Zip.Count | Should -Be 1
        $Zip = [System.IO.Compression.ZipFile]::OpenRead($Run.Zip[0].FullName)
        try
        {
            $Entry = @($Zip.Entries | Where-Object { $_.Name -like 'Inventory_*.json' })[0]
            $Reader = [System.IO.StreamReader]::new($Entry.Open())
            try { $Inventory = $Reader.ReadToEnd() | ConvertFrom-Json } finally { $Reader.Dispose() }
        }
        finally { $Zip.Dispose() }
        @($Inventory.PublicIP).Count | Should -Be 1001
    }

    It 'stops with exit 1 and writes no report when a page cannot be parsed' {
        $Run = Invoke-DiscoveryRun -Scenario 'emptykey'
        $Run.ProcessExit | Should -Be 1 -Because $Run.Console
        $Run.Console | Should -Match 'could not be parsed as JSON'
        $Run.Console | Should -Match 'Resource discovery failed'
        $Run.Html.Count | Should -Be 0
        $Run.Zip.Count | Should -Be 0
        @($Run.Pages | Where-Object { $_ -eq 'skip=1000' }).Count | Should -Be 1
    }

    It 'stops with exit 1 after 4 attempts when a page keeps failing' {
        $Run = Invoke-DiscoveryRun -Scenario 'toolarge'
        $Run.ProcessExit | Should -Be 1 -Because $Run.Console
        @($Run.Pages | Where-Object { $_ -eq 'skip=1000' }).Count | Should -Be 4
        $Run.Console | Should -Match 'after 4 attempt\(s\)'
        $Run.Console | Should -Match 'ResponsePayloadTooLarge'
        $Run.Html.Count | Should -Be 0
        $Run.Zip.Count | Should -Be 0
    }
}

Describe 'Under -RunAllSubs: the failure reaches the wrapper with its reason' {

    It 'passes on the parse failure to the caller and writes no report' {
        $Run = Invoke-DiscoveryRun -Scenario 'emptykey' -RunAllSubs
        $Run.State.Caught | Should -Match 'could not be parsed as JSON' -Because $Run.Console
        $Run.Html.Count | Should -Be 0
        $Run.Zip.Count | Should -Be 0
    }

    It 'passes on a lasting failure after 4 attempts and writes no report' {
        $Run = Invoke-DiscoveryRun -Scenario 'toolarge' -RunAllSubs
        $Run.State.Caught | Should -Match 'after 4 attempt\(s\)' -Because $Run.Console
        @($Run.Pages | Where-Object { $_ -eq 'skip=1000' }).Count | Should -Be 4
        $Run.Html.Count | Should -Be 0
        $Run.Zip.Count | Should -Be 0
    }
}
