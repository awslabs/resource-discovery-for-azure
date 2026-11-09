# Report header of a direct run over several subscriptions
# Run with: Invoke-Pester ./Tests/MultiSubscriptionHeader.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# A direct run without -SubscriptionID inventories every subscription the
# sign-in lists into one report. Its header still read 'Subscription: <name>'
# with one subscription's name: Summary.ps1 took the name from the first
# record it found. The header now says how many subscriptions the report
# covers. A count says nothing that -Obfuscate would mask.
#
# The test copies the scripts to a temp folder and runs the REAL
# ResourceInventory.ps1 in a child pwsh against offline stand-ins for the
# Azure CLI and the Az cmdlets: two subscriptions without -SubscriptionID
# (with and without -Obfuscate), two subscriptions with -SubscriptionID, and
# one subscription without -SubscriptionID, under en-US and tr-TR. Each
# subscription holds one disk. Placeholder ids and generic names only; no
# live Azure.
#
# Not run on Windows: the stand-ins are written for the Unix paths.

BeforeDiscovery {
    $Two = '12345678-1234-1234-1234-123456789012,12345678-1234-1234-1234-123456789013'
    $One = '12345678-1234-1234-1234-123456789012'
    $script:Cases = @(
        foreach ($Culture in @('en-US', 'tr-TR'))
        {
            @{ Culture = $Culture; SubIds = $Two; AllSubs = $true; Obfuscate = $false; Header = '2 subscriptions (consolidated)'; Disks = 2; Name = 'two subscriptions, no -SubscriptionID' }
            @{ Culture = $Culture; SubIds = $Two; AllSubs = $true; Obfuscate = $true; Header = '2 subscriptions (consolidated)'; Disks = 2; Name = 'two subscriptions, no -SubscriptionID, -Obfuscate' }
            @{ Culture = $Culture; SubIds = $Two; AllSubs = $false; Obfuscate = $false; Header = 'Demo Subscription 1'; Disks = 1; Name = 'two subscriptions, -SubscriptionID' }
            # This header comes from the first record's Subscription field. On this
            # branch's base a tr-TR run lower-cases the Resource Graph text with
            # tr-TR rules, so 'subscriptionId' loses its dotted i and the record's
            # Subscription is empty; that is older than this change and is fixed
            # where Resource Graph is read with Az PowerShell. So that one case
            # runs under en-US only.
            if ($Culture -eq 'en-US')
            {
                @{ Culture = $Culture; SubIds = $One; AllSubs = $true; Obfuscate = $false; Header = 'Demo Subscription 1'; Disks = 1; Name = 'one subscription, no -SubscriptionID' }
            }
        }
    )
}

BeforeAll {
    $script:RepoRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' | Resolve-Path | Select-Object -ExpandProperty Path
    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ('MultiSubscriptionHeader_' + [guid]::NewGuid().ToString('N'))
    $script:Tree = Join-Path $script:WorkDir 'tree'
    $null = New-Item -ItemType Directory -Path $script:Tree -Force
    foreach ($Item in @('ResourceInventory.ps1', 'Version.json', 'Functions', 'Extension', 'Services'))
    {
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot $Item) -Destination $script:Tree -Recurse -Force
    }

    # The child run: stand-ins first, then the real script. Each subscription the
    # sign-in lists holds one disk; Resource Graph returns the disks of the
    # subscriptions named after --subscriptions only.
    $script:Harness = Join-Path $script:WorkDir 'run.ps1'
    @'
param([string]$Tree, [string]$Out, [string]$Culture, [string]$SubIds, [switch]$AllSubs, [switch]$Obfuscate)
$PSStyle.OutputRendering = 'PlainText'
[System.Globalization.CultureInfo]::CurrentCulture = $Culture
[System.Globalization.CultureInfo]::CurrentUICulture = $Culture
$Global:RdaSessionInitialized = $true
$Global:AzPowerShellLoaded = $true
$Global:PlatformOS = 'PowerShell Unix'
$Ids = @($SubIds -split ',' | Where-Object { $_ })
$Global:StandInSubs = @(for ($i = 0; $i -lt $Ids.Count; $i++) { [pscustomobject]@{ id = $Ids[$i]; name = ('Demo Subscription {0}' -f ($i + 1)); tenantId = 'tenant-demo'; state = 'Enabled' } })
$Global:StandInContextSub = $Ids[0]
function global:Get-StandInRows([object[]]$Arguments)
{
    $Subs = @()
    for ($i = 0; $i -lt $Arguments.Count; $i++)
    {
        if ([string]$Arguments[$i] -eq '--subscriptions')
        {
            for ($j = $i + 1; $j -lt $Arguments.Count -and -not ([string]$Arguments[$j]).StartsWith('--'); $j++) { $Subs += [string]$Arguments[$j] }
        }
    }
    if ($Subs.Count -eq 0) { $Subs = @($Global:StandInSubs | ForEach-Object { [string]$_.id }) }
    @(foreach ($Sub in $Subs)
        {
            @{ id = "/subscriptions/$Sub/resourceGroups/rg-demo/providers/Microsoft.Compute/disks/disk-demo"; name = 'disk-demo'; type = 'microsoft.compute/disks'; location = 'eastus'; subscriptionId = $Sub; resourceGroup = 'rg-demo'
                sku = @{ name = 'Premium_LRS' }; properties = @{ diskSizeGB = 32; diskState = 'Unattached'; timeCreated = '2024-03-15T09:41:27Z' } }
        })
}
function global:az
{
    $Joined = $args -join ' '
    $global:LASTEXITCODE = 0
    if ($Joined -like 'account show*') { return '{"user":{"name":"tester"},"tenantId":"tenant-demo"}' }
    if ($Joined -like 'account list*') { return (ConvertTo-Json -InputObject @($Global:StandInSubs) -Compress) }
    if ($Joined -like 'graph*')
    {
        $Rows = @(Get-StandInRows -Arguments $args)
        if ($Joined -match 'desktopvirtualizationresources') { return '{"data":[{"count_":0}],"count":1}' }
        if ($Joined -match 'summarize count\(\)') { return ('{{"data":[{{"count_":{0}}}],"count":1}}' -f $Rows.Count) }
        return (@{ data = $Rows; count = $Rows.Count } | ConvertTo-Json -Depth 8 -Compress)
    }
    return $null
}
function global:Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = 'tenant-demo' }; Subscription = [pscustomobject]@{ Id = $Global:StandInContextSub; Name = 'stand-in' }; Account = [pscustomobject]@{ Id = 'tester' } } }
function global:Set-AzContext { [CmdletBinding()] param($Subscription, $Scope, $Context) $Global:StandInContextSub = [string]$Subscription; $null }
function global:Connect-AzAccount { throw 'no sign-in in this harness' }
function global:Get-AzAccessToken { param($ResourceUrl) [pscustomobject]@{ Token = ('e30.' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"oid":"test-oid"}')).TrimEnd('=') + '.sig') } }
function global:Get-AzMetric { [CmdletBinding()] param($ResourceId, $MetricName, $StartTime, $EndTime, $TimeGrain, $AggregationType, $DefaultProfile) }
function global:Get-UsageAggregates { [CmdletBinding()] param($ReportedStartTime, $ReportedEndTime, $AggregationGranularity, $ShowDetails, $ContinuationToken) [pscustomobject]@{ UsageAggregations = @(); ContinuationToken = $null } }
function global:Invoke-AzRestMethod
{
    param($Method, $Path, $Payload, $Uri)
    $Target = if ($Path) { $Path } else { $Uri }
    $Json = { param($Obj) [pscustomobject]@{ StatusCode = 200; Content = ($Obj | ConvertTo-Json -Depth 10) } }
    $Sub = if ($Target -match '/subscriptions/([^/?]+)') { $Matches[1] } else { $Global:StandInContextSub }
    if ($Target -match '/roleAssignments\?') { return (& $Json @{ value = @(@{ properties = @{ roleDefinitionId = "/subscriptions/$Sub/providers/Microsoft.Authorization/roleDefinitions/reader"; scope = "/subscriptions/$Sub"; principalId = 'test-oid'; principalType = 'ServicePrincipal' } }) }) }
    if ($Target -match '/roleDefinitions/') { return (& $Json @{ properties = @{ roleName = 'Reader'; type = 'BuiltInRole'; permissions = @(@{ actions = @('*/read'); notActions = @() }) } }) }
    if ($Target -match '/providers/Microsoft\.Authorization/permissions\?') { return (& $Json @{ value = @(@{ actions = @('*/read'); notActions = @() }) }) }
    if ($Target -match '/UsageAggregates\?') { return (& $Json @{ value = @() }) }
    if ($Target -match 'Microsoft\.ResourceGraph/resources') { return (& $Json @{ data = @($Global:StandInSubs | ForEach-Object { @{ subscriptionId = [string]$_.id; ResourceCount = 1 } }) }) }
    throw ('no stand-in for {0} {1}' -f $Method, $Target)
}

$Params = @{ OutputDirectory = $Out; Service = @('VMDisk') }
if (-not $AllSubs) { $Params.SubscriptionID = $Ids[0] }
if ($Obfuscate) { $Params.Obfuscate = $true }
Set-Location -LiteralPath $Tree
& (Join-Path $Tree 'ResourceInventory.ps1') @Params
exit $LASTEXITCODE
'@ | Set-Content -LiteralPath $script:Harness -Encoding utf8

    # The pwsh that runs these tests runs the child too.
    $script:Pwsh = (Get-Process -Id $PID).Path

    function Invoke-HeaderRun
    {
        param([string]$Culture, [string]$SubIds, [bool]$AllSubs, [bool]$Obfuscate)
        $Out = Join-Path $script:WorkDir ('out_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Path $Out -Force
        $ArgList = @('-NoProfile', '-NonInteractive', '-File', $script:Harness, '-Tree', $script:Tree, '-Out', $Out, '-Culture', $Culture, '-SubIds', $SubIds)
        if ($AllSubs) { $ArgList += '-AllSubs' }
        if ($Obfuscate) { $ArgList += '-Obfuscate' }
        $Console = @(& $script:Pwsh @ArgList 2>&1 | ForEach-Object { [string]$_ })
        $Exit = $LASTEXITCODE
        $Html = @(Get-ChildItem -LiteralPath $Out -Filter 'ResourcesReport_*.html' -File)[0]
        $Text = if ($null -ne $Html) { Get-Content -LiteralPath $Html.FullName -Raw } else { '' }
        $Json = @(Get-ChildItem -LiteralPath $Out -Filter 'Inventory_*.json' -File)[0]
        $Disks = if ($null -ne $Json) { @((Get-Content -LiteralPath $Json.FullName -Raw | ConvertFrom-Json).VMDisk) } else { @() }
        $Header = if ($Text -match '<div><b>Subscription:</b> ([^<]*)</div>') { $Matches[1] } else { '<no such line>' }
        return [pscustomobject]@{ Exit = $Exit; Console = ($Console -join "`n"); Header = $Header; Disks = $Disks; Html = $Text }
    }
}

AfterAll {
    if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir))
    {
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Direct run under <Culture>: <Name>' -ForEach $script:Cases -Skip:$IsWindows {
    BeforeAll {
        $script:Run = Invoke-HeaderRun -Culture $Culture -SubIds $SubIds -AllSubs $AllSubs -Obfuscate $Obfuscate
    }

    It 'finishes with exit 0' {
        $script:Run.Exit | Should -Be 0 -Because $script:Run.Console
    }

    It 'lists the disk of every subscription it covers' {
        @($script:Run.Disks).Count | Should -Be $Disks
    }

    It 'names the subscription, or the number of subscriptions, in the header' {
        $script:Run.Header | Should -BeExactly $Header
    }

    It 'shows no subscription name under -Obfuscate' {
        if (-not $Obfuscate) { Set-ItResult -Skipped -Because 'this run is not obfuscated' }
        $script:Run.Html | Should -Not -Match 'Demo Subscription'
    }
}
