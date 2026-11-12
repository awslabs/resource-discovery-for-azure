# Resource discovery page order tests
# Run with: Invoke-Pester ./Tests/DiscoveryPageOrder.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# Resource discovery reads Resource Graph 1,000 rows at a time, one request per
# page, so the pages are read seconds apart. Resource Graph sorts text by its
# exact characters, upper case before lower case. It also returns some ids with
# the resource group in upper case and others in lower case, and for one
# resource the case can change from one read to the next: a virtual machine
# that is starting or stopping switches between the two several times. With the
# rows sorted by the id as returned, such a row moves between the start and the
# end of the list while the pages are read, so the inventory listed it twice or
# not at all, and the row at the edge of a page was dropped or listed twice with
# it. Sorting by the id in lower case keeps every row in one place whatever the
# case of its id.
#
# The tests copy the script and its folders to a temp dir and run the REAL
# ResourceInventory.ps1 in a child pwsh, with -SkipMetrics -SkipConsumption
# -Service PublicIP and offline stand-ins for the Az calls the run makes. The
# Resource Graph stand-in holds 1,501 public IPs in one resource group. It sorts
# them the way Resource Graph does (by exact characters; an order it does not
# know fails the request), and one of them, pip-move, has its resource group in
# one case for the first page and in the other case for every later page.
# Each discovery path (-SubscriptionID, -ResourceGroup, and every subscription)
# is run. The AVD discovery query (desktopvirtualizationresources) pages the
# same way: in its tests the resources table holds one host pool and the AVD
# table 1,501 session hosts of it, one of which, sh-move, changes case the same
# way. No live Azure. Generic names and the documentation placeholder
# subscription id only.

BeforeDiscovery {
    $script:Paths = @('Subscription', 'ResourceGroup', 'AllSubscriptions')
}

BeforeAll {
    $env:RDA_AZPS_STANDINS = Join-Path $PSScriptRoot 'Helpers/AzPsStandIns.ps1'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $script:RepoRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' | Resolve-Path | Select-Object -ExpandProperty Path
    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ("DiscoveryPageOrder_" + [guid]::NewGuid().ToString('N'))
    $script:Tree = Join-Path $script:WorkDir 'tree'
    New-Item -ItemType Directory -Path $script:Tree -Force | Out-Null

    foreach ($Item in @('ResourceInventory.ps1', 'Version.json', 'Functions', 'Extension', 'Services'))
    {
        Copy-Item -Path (Join-Path $script:RepoRoot $Item) -Destination $script:Tree -Recurse -Force
    }

    # Child-process harness. -Flip: 'none' keeps pip-move's id as 'rg-demo'
    # for every page; 'upper-first' returns 'RG-DEMO' for the first page and
    # 'rg-demo' after it (as a starting VM did live); 'lower-first' the other way
    # round. -Path picks the discovery path. -Avd 'on' moves the 1,501 rows,
    # and the flip, to the AVD table (sh-move), and leaves one host pool in the
    # resources table. The pause between pages and the retry backoff do not wait.
    $script:Harness = Join-Path $script:WorkDir 'run.ps1'
    @'
param([string]$Tree, [string]$Out, [string]$Flip, [string]$Path, [string]$StateDir, [string]$Avd = 'off')
$PSStyle.OutputRendering = 'PlainText'
$Global:RdaSessionInitialized = $true
$Global:AzPowerShellLoaded = $true
$Global:PlatformOS = 'PowerShell Unix'
$Global:HFlip = $Flip
$Global:HAvd = $Avd
$Global:HCallLog = Join-Path $StateDir 'graph-pages.log'
$SubId = '12345678-1234-1234-1234-123456789012'
$Global:StandInSubs = @([pscustomobject]@{ id = $SubId; name = 'Demo Subscription'; tenantId = 'tenant-demo'; state = 'Enabled' })
function global:New-StandInPublicIp([string]$Name, [string]$Group)
{
    $Props = @{ publicIPAllocationMethod = 'Static'; publicIPAddressVersion = 'IPv4'; provisioningState = 'Succeeded' }
    @{ id = ('/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.Network/publicIPAddresses/{2}' -f $Global:StandInSubs[0].id, $Group, $Name); name = $Name; type = 'microsoft.network/publicipaddresses'; location = 'eastus'; subscriptionId = $Global:StandInSubs[0].id; resourceGroup = 'rg-demo'; sku = @{ name = 'Standard' }; properties = $Props }
}
# The rows as Resource Graph holds them when a page is read: 1,500 public IPs
# whose ids carry 'rg-demo', and pip-move, whose id carries 'RG-DEMO' or
# 'rg-demo' depending on -Flip and on which page is read.
function global:Get-StandInRows([int]$Skip)
{
    $Rows = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt 1500; $i++) { $Rows.Add((New-StandInPublicIp -Name ('pip-demo-{0:D4}' -f $i) -Group 'rg-demo')) }
    $Upper = switch ($Global:HFlip) { 'upper-first' { $Skip -eq 0 } 'lower-first' { $Skip -gt 0 } default { $false } }
    $Rows.Add((New-StandInPublicIp -Name 'pip-move' -Group $(if ($Upper) { 'RG-DEMO' } else { 'rg-demo' })))
    return $Rows
}
function global:Get-StandInHostPoolId([string]$Group)
{
    '/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.DesktopVirtualization/hostpools/hp-demo' -f $Global:StandInSubs[0].id, $Group
}
# The AVD table as Resource Graph holds it when a page is read: 1,500 session
# hosts of hp-demo whose ids carry 'rg-demo', and sh-move, whose id carries
# 'RG-DEMO' or 'rg-demo' as pip-move's does. The AVD sheet has one row per
# session host but no session-host name, so each host has its own agent version
# (sh-move 2.0.0) to tell the rows apart.
function global:Get-StandInAvdRows([int]$Skip)
{
    $Upper = switch ($Global:HFlip) { 'upper-first' { $Skip -eq 0 } 'lower-first' { $Skip -gt 0 } default { $false } }
    $Hosts = @(for ($i = 0; $i -lt 1500; $i++) { @{ Name = ('sh-{0:D4}.demo.local' -f $i); Group = 'rg-demo'; Version = ('1.0.{0}' -f $i) } })
    $Hosts += @{ Name = 'sh-move.demo.local'; Group = $(if ($Upper) { 'RG-DEMO' } else { 'rg-demo' }); Version = '2.0.0' }
    $Rows = [System.Collections.Generic.List[object]]::new()
    foreach ($H in $Hosts)
    {
        $Props = @{ agentVersion = $H.Version; allowNewSession = $true; status = 'Available'; updateState = 'Succeeded' }
        $Rows.Add(@{ id = ('{0}/sessionhosts/{1}' -f (Get-StandInHostPoolId -Group $H.Group), $H.Name); name = ('hp-demo/{0}' -f $H.Name); type = 'microsoft.desktopvirtualization/hostpools/sessionhosts'; location = 'eastus'; subscriptionId = $Global:StandInSubs[0].id; resourceGroup = 'rg-demo'; properties = $Props })
    }
    return $Rows
}
# One page of $Rows in the order the query asks for. Resource Graph compares
# text by its exact characters (ordinal), so an upper-case group sorts before
# every lower-case one.
function global:Get-StandInPage([string]$Joined, [object]$Rows, [int]$Skip, [int]$First)
{
    $Key = if ($Joined -match '\| order by id asc\b') { { param($Row) [string]$Row.id } }
    elseif ($Joined -match '\| order by tolower\(id\) asc\b') { { param($Row) ([string]$Row.id).ToLowerInvariant() } }
    else { $global:LASTEXITCODE = 1; return ('stand-in Resource Graph: no known order clause in: {0}' -f $Joined) }
    $Sorted = [System.Collections.Generic.List[object]]::new($Rows)
    $Sorted.Sort([System.Comparison[object]] { param($A, $B) [string]::CompareOrdinal((& $Key $A), (& $Key $B)) })
    $Page = @(for ($i = $Skip; $i -lt [math]::Min($Skip + $First, $Sorted.Count); $i++) { $Sorted[$i] })
    return (@{ data = $Page; count = $Page.Count } | ConvertTo-Json -Depth 8 -Compress)
}
function global:Invoke-StandInGraph
{
    $Joined = $args -join ' '
    $global:LASTEXITCODE = 0
    if ($Joined -like 'account show*') { return '{"user":{"name":"tester"},"tenantId":"tenant-demo"}' }
    if ($Joined -like 'account list*') { return (ConvertTo-Json -InputObject @($Global:StandInSubs) -Compress) }
    if ($Joined -like 'graph*')
    {
        $Skip = 0
        $First = 1000
        if ($Joined -match '--skip (\d+)') { $Skip = [int]$Matches[1] }
        if ($Joined -match '--first (\d+)') { $First = [int]$Matches[1] }
        if ($Joined -match 'desktopvirtualizationresources')
        {
            if ($Global:HAvd -ne 'on') { return '{"data":[{"count_":0}],"count":1}' }
            if ($Joined -match 'summarize count\(\)') { return '{"data":[{"count_":1501}],"count":1}' }
            Add-Content -LiteralPath $Global:HCallLog -Value ('avd skip={0}' -f $Skip)
            return (Get-StandInPage -Joined $Joined -Rows (Get-StandInAvdRows -Skip $Skip) -Skip $Skip -First $First)
        }
        if ($Global:HAvd -eq 'on')
        {
            if ($Joined -match 'summarize count\(\)') { return '{"data":[{"count_":1}],"count":1}' }
            Add-Content -LiteralPath $Global:HCallLog -Value ('skip={0}' -f $Skip)
            $Pool = @{ id = (Get-StandInHostPoolId -Group 'rg-demo'); name = 'hp-demo'; type = 'microsoft.desktopvirtualization/hostpools'; location = 'eastus'; subscriptionId = $Global:StandInSubs[0].id; resourceGroup = 'rg-demo'; properties = @{ hostPoolType = 'Pooled'; loadBalancerType = 'BreadthFirst'; maxSessionLimit = 10; preferredAppGroupType = 'Desktop' } }
            return (Get-StandInPage -Joined $Joined -Rows @($Pool) -Skip $Skip -First $First)
        }
        if ($Joined -match 'summarize count\(\)') { return '{"data":[{"count_":1501}],"count":1}' }
        Add-Content -LiteralPath $Global:HCallLog -Value ('skip={0}' -f $Skip)
        return (Get-StandInPage -Joined $Joined -Rows (Get-StandInRows -Skip $Skip) -Skip $Skip -First $First)
    }
    return $null
}
function global:Start-Sleep
{
    param([Parameter(Position = 0)][double]$Seconds, [int]$Milliseconds)
    $Caller = (Get-PSCallStack)[1].Command
    if ($Caller -in @('Invoke-AzGraphQuerySafe', 'Invoke-AzGraphPage', 'ResourceInventoryLoop', 'ResourceInventoryAvd')) { return }
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

# Az PowerShell sign-in, subscription list and Resource Graph paging on top of the stand-ins above.
. $env:RDA_AZPS_STANDINS
$Params = @{ SkipMetrics = $true; SkipConsumption = $true; OutputDirectory = $Out; Service = @($(if ($Avd -eq 'on') { 'AVD' } else { 'PublicIP' })) }
if ($Path -ne 'AllSubscriptions') { $Params.SubscriptionID = $SubId }
if ($Path -eq 'ResourceGroup') { $Params.ResourceGroup = 'rg-demo' }
Set-Location $Tree
$global:LASTEXITCODE = 0
& (Join-Path $Tree 'ResourceInventory.ps1') @Params
exit $LASTEXITCODE
'@ | Set-Content -Path $script:Harness -Encoding utf8

    # Runs one direct run in a child pwsh and returns its process exit code, the
    # console text, the page requests, the PublicIP records of the report and,
    # with -Avd 'on', the agent versions of its AVD records.
    function Invoke-PageOrderRun
    {
        param([string]$Flip, [string]$Path, [string]$Avd = 'off')

        $Name = [guid]::NewGuid().ToString('N')
        $Out = Join-Path $script:WorkDir ('out_' + $Name)
        $StateDir = Join-Path $script:WorkDir ('state_' + $Name)
        New-Item -ItemType Directory -Path $Out, $StateDir -Force | Out-Null

        $ArgList = @('-NoProfile', '-NonInteractive', '-File', $script:Harness, '-Tree', $script:Tree, '-Out', $Out, '-Flip', $Flip, '-Path', $Path, '-StateDir', $StateDir, '-Avd', $Avd)
        $Console = @(& pwsh @ArgList 2>&1 | ForEach-Object { [string]$_ })
        $ProcessExit = $LASTEXITCODE
        $PageLog = Join-Path $StateDir 'graph-pages.log'

        $Records = @()
        $AvdRecords = @()
        $ZipFile = @(Get-ChildItem -Path $Out -Filter 'ResourcesReport_*.zip' -File)
        if ($ZipFile.Count -eq 1)
        {
            $Zip = [System.IO.Compression.ZipFile]::OpenRead($ZipFile[0].FullName)
            try
            {
                $Entry = @($Zip.Entries | Where-Object { $_.Name -like 'Inventory_*.json' })[0]
                $Reader = [System.IO.StreamReader]::new($Entry.Open())
                try { $Inventory = $Reader.ReadToEnd() | ConvertFrom-Json } finally { $Reader.Dispose() }
                $Records = @($Inventory.PublicIP)
                $AvdRecords = @($Inventory.AVD)
            }
            finally { $Zip.Dispose() }
        }

        return [pscustomobject]@{
            ProcessExit = $ProcessExit
            Console     = ($Console -join "`n")
            Pages       = @(if (Test-Path -LiteralPath $PageLog) { Get-Content -LiteralPath $PageLog })
            Names       = @($Records | ForEach-Object { [string]$_.Name })
            Ids         = @($Records | ForEach-Object { ([string]$_.ID).ToLowerInvariant() })
            AvdVersions = @($AvdRecords | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_.AVDAgentVersion })
        }
    }
}

AfterAll {
    if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir))
    {
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Discovery path <_>: a resource whose id changes case between page reads' -ForEach $script:Paths {

    BeforeAll { $script:Path = $_ }

    It 'lists every resource once when no id changes case (control)' {
        $Run = Invoke-PageOrderRun -Flip 'none' -Path $script:Path
        $Run.ProcessExit | Should -Be 0 -Because $Run.Console
        $Run.Pages | Should -Be @('skip=0', 'skip=1000')
        $Run.Names.Count | Should -Be 1501
        @($Run.Ids | Sort-Object -Unique).Count | Should -Be 1501
    }

    It 'lists it once, and keeps the row at the page edge, when its group turns lower case after the first page' {
        $Run = Invoke-PageOrderRun -Flip 'upper-first' -Path $script:Path
        $Run.ProcessExit | Should -Be 0 -Because $Run.Console
        $Run.Pages | Should -Be @('skip=0', 'skip=1000')
        @($Run.Names | Where-Object { $_ -eq 'pip-move' }).Count | Should -Be 1
        @($Run.Names | Where-Object { $_ -eq 'pip-demo-0999' }).Count | Should -Be 1
        $Run.Names.Count | Should -Be 1501
        @($Run.Ids | Sort-Object -Unique).Count | Should -Be 1501
    }

    It 'lists it once, and keeps the row at the page edge once, when its group turns upper case after the first page' {
        $Run = Invoke-PageOrderRun -Flip 'lower-first' -Path $script:Path
        $Run.ProcessExit | Should -Be 0 -Because $Run.Console
        $Run.Pages | Should -Be @('skip=0', 'skip=1000')
        @($Run.Names | Where-Object { $_ -eq 'pip-move' }).Count | Should -Be 1
        @($Run.Names | Where-Object { $_ -eq 'pip-demo-0999' }).Count | Should -Be 1
        $Run.Names.Count | Should -Be 1501
        @($Run.Ids | Sort-Object -Unique).Count | Should -Be 1501
    }
}

# The AVD query names every subscription of the run whatever the discovery
# path, so one path is enough.
Describe 'AVD discovery: a session host whose id changes case between page reads' {

    It 'lists every session host once when no id changes case (control)' {
        $Run = Invoke-PageOrderRun -Flip 'none' -Path 'Subscription' -Avd 'on'
        $Run.ProcessExit | Should -Be 0 -Because $Run.Console
        $Run.Pages | Should -Be @('skip=0', 'avd skip=0', 'avd skip=1000')
        $Run.AvdVersions.Count | Should -Be 1501
        @($Run.AvdVersions | Sort-Object -Unique).Count | Should -Be 1501
    }

    It 'lists it once, and keeps the row at the page edge, when its group turns lower case after the first page' {
        $Run = Invoke-PageOrderRun -Flip 'upper-first' -Path 'Subscription' -Avd 'on'
        $Run.ProcessExit | Should -Be 0 -Because $Run.Console
        $Run.Pages | Should -Be @('skip=0', 'avd skip=0', 'avd skip=1000')
        @($Run.AvdVersions | Where-Object { $_ -eq '2.0.0' }).Count | Should -Be 1
        @($Run.AvdVersions | Where-Object { $_ -eq '1.0.999' }).Count | Should -Be 1
        $Run.AvdVersions.Count | Should -Be 1501
        @($Run.AvdVersions | Sort-Object -Unique).Count | Should -Be 1501
    }

    It 'lists it once, and keeps the row at the page edge once, when its group turns upper case after the first page' {
        $Run = Invoke-PageOrderRun -Flip 'lower-first' -Path 'Subscription' -Avd 'on'
        $Run.ProcessExit | Should -Be 0 -Because $Run.Console
        $Run.Pages | Should -Be @('skip=0', 'avd skip=0', 'avd skip=1000')
        @($Run.AvdVersions | Where-Object { $_ -eq '2.0.0' }).Count | Should -Be 1
        @($Run.AvdVersions | Where-Object { $_ -eq '1.0.999' }).Count | Should -Be 1
        $Run.AvdVersions.Count | Should -Be 1501
        @($Run.AvdVersions | Sort-Object -Unique).Count | Should -Be 1501
    }
}
