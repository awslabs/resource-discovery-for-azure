# Main summary row of a subscription whose consumption collection failed
# Run with: Invoke-Pester ./Tests/ConsumptionIncompleteRow.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# When a subscription's usage pages could not be read, the main summary of a
# Run-AllSubscriptions.ps1 run still marked its row "ok". The consumption banner
# only gives a count under -Obfuscate, so the shareable summary could not say
# which subscription was missing its cost data. In a -ParallelStreams run the
# stream worker also kept one consumption failure per stream (Select-Object
# -Unique treats any two of these entries as equal), so the banner undercounted.
# A consumption phase skipped because the Azure sign-in could no longer be
# refreshed was recorded without its report folder, so that row said "ok" too.
#
# The test copies the scripts to a temp folder and runs, in a child pwsh with
# HOME pointed at a temp folder and offline stand-ins for the Azure CLI and the
# Az cmdlets:
#   - the REAL ResourceInventory.ps1 once per subscription, the way the
#     wrapper's sequential loop calls it, then the main summary the way the
#     wrapper builds it;
#   - the REAL Run-AllSubscriptions.Stream.ps1 for one stream, which calls the
#     real ResourceInventory.ps1 per subscription, then the main summary from
#     that stream's summary file.
# One subscription's usage page fails on every attempt in the first case, two
# in the second; in the third, one subscription's Az token cannot be refreshed
# in the consumption phase. The metrics phase is skipped (-SkipMetrics): it is
# not part of this behaviour and its thread jobs would not see the stand-ins.
# Retry waits are skipped by a Start-Sleep stand-in. Placeholder ids only; no
# live Azure.
#
# Not run on Windows: without -OutputDirectory the inner script writes to
# C:\InventoryReports there, which a test cannot isolate.

BeforeDiscovery {
    $script:SkipReason = if ($IsWindows) { 'the inner script writes to C:\InventoryReports on Windows, which a test cannot isolate' } else { $null }
}

BeforeAll {
    $script:RepoRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' | Resolve-Path | Select-Object -ExpandProperty Path
    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ('ConsumptionIncompleteRow_' + [guid]::NewGuid().ToString('N'))
    $script:Tree = Join-Path $script:WorkDir 'tree'
    New-Item -ItemType Directory -Path $script:Tree -Force | Out-Null
    foreach ($Item in @('ResourceInventory.ps1', 'Run-AllSubscriptions.Stream.ps1', 'Version.json', 'Functions', 'Extension', 'Services'))
    {
        Copy-Item -Path (Join-Path $script:RepoRoot $Item) -Destination $script:Tree -Recurse -Force
    }

    $script:Harness = Join-Path $script:WorkDir 'run.ps1'
    @'
param([string]$Tree, [ValidateSet('Sequential', 'Stream')][string]$Mode, [string]$FailIds = '', [string]$LapseIds = '', [switch]$Obfuscate)
$PSStyle.OutputRendering = 'PlainText'
$ErrorActionPreference = 'Continue'
$Global:RdaSessionInitialized = $true
$Global:AzPowerShellLoaded = $true
$Global:PlatformOS = 'PowerShell Unix'
$Tenant = '12345678-1234-1234-1234-123456789012'
$Global:StandInSubs = @(
    [pscustomobject]@{ Id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'; Name = 'Sub A' },
    [pscustomobject]@{ Id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'; Name = 'Sub B' },
    [pscustomobject]@{ Id = 'cccccccc-cccc-cccc-cccc-cccccccccccc'; Name = 'Sub C' })
$Global:StandInFailIds = @($FailIds -split ',' | Where-Object { $_ })
$Global:StandInLapseIds = @($LapseIds -split ',' | Where-Object { $_ })
$Global:StandInCurrentSub = $null
$Global:StandInContextSub = $Global:StandInSubs[0].Id

function global:az
{
    $Joined = $args -join ' '
    $global:LASTEXITCODE = 0
    if ($Joined -like 'account show*') { return ('{{"user":{{"name":"tester"}},"tenantId":"{0}"}}' -f '12345678-1234-1234-1234-123456789012') }
    if ($Joined -like 'account list*') { return (ConvertTo-Json -Compress -InputObject @($Global:StandInSubs | ForEach-Object { @{ id = $_.Id; name = $_.Name; tenantId = '12345678-1234-1234-1234-123456789012'; state = 'Enabled' } })) }
    if ($Joined -like 'graph*')
    {
        $Sub = ''
        for ($i = 0; $i -lt $args.Count - 1; $i++) { if ([string]$args[$i] -eq '--subscriptions') { $Sub = [string]$args[$i + 1] } }
        if ($Joined -match 'desktopvirtualizationresources') { return '{"data":[{"count_":0}],"count":1}' }
        if ($Joined -match 'summarize count\(\)') { return '{"data":[{"count_":1}],"count":1}' }
        $Row = @{ id = "/subscriptions/$Sub/resourceGroups/rg-demo/providers/Microsoft.Network/publicIPAddresses/pip-demo"; name = 'pip-demo'; type = 'microsoft.network/publicipaddresses'; location = 'eastus'; subscriptionId = $Sub; resourceGroup = 'rg-demo'
            sku = @{ name = 'Standard' }; properties = @{ publicIPAllocationMethod = 'Static'; publicIPAddressVersion = 'IPv4'; provisioningState = 'Succeeded' } }
        return (@{ data = @($Row); count = 1 } | ConvertTo-Json -Depth 8 -Compress)
    }
    return $null
}
function global:Get-AzContext { [CmdletBinding()] param() [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = '12345678-1234-1234-1234-123456789012' }; Subscription = [pscustomobject]@{ Id = $Global:StandInContextSub; Name = 'stand-in' }; Account = [pscustomobject]@{ Id = 'tester' } } }
function global:Set-AzContext { [CmdletBinding()] param($Subscription, $Scope, $Context, $Tenant) $Global:StandInContextSub = [string]$Subscription; $null }
# For the subscriptions in -LapseIds the token cannot be refreshed once the
# consumption phase starts: a sign-in that stopped working part-way through.
function global:Get-AzAccessToken
{
    [CmdletBinding()] param($ResourceUrl, $TenantId)
    if ($Global:StandInLapseIds -contains $Global:StandInCurrentSub -and @(Get-PSCallStack | ForEach-Object FunctionName) -contains 'GetResorceConsumption') { throw 'stand-in: the sign-in can no longer be refreshed' }
    [pscustomobject]@{ Token = ('e30.' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"oid":"test-oid"}')).TrimEnd('=') + '.sig') }
}
function global:Connect-AzAccount { throw 'no sign-in in this harness' }
function global:Import-AzContext { [CmdletBinding()] param($Path) }
function global:Disable-AzContextAutosave { [CmdletBinding()] param($Scope) }
function global:Invoke-AzRestMethod { [CmdletBinding()] param($Method, $Path, $Payload, $Uri) throw ('no stand-in for {0} {1}' -f $Method, $(if ($Path) { $Path } else { $Uri })) }
function global:Get-AzMetric { throw 'no metric calls expected: the harness runs with -SkipMetrics' }
# The consumption loop has just switched the context to the subscription; its
# usage page fails on every attempt for the subscriptions in -FailIds.
function global:Get-AzUsageAggregate
{
    [CmdletBinding()] param($ReportedStartTime, $ReportedEndTime, $AggregationGranularity, $ShowDetails, $ContinuationToken)
    if ($Global:StandInFailIds -contains $Global:StandInContextSub) { throw 'stand-in: the usage service returned an error for this page' }
    $Uri = '/subscriptions/{0}/resourceGroups/rg-demo/providers/Microsoft.Network/publicIPAddresses/pip-demo' -f $Global:StandInContextSub
    $Instance = @{ 'Microsoft.Resources' = @{ resourceUri = $Uri; location = 'eastus'; additionalInfo = @{} } } | ConvertTo-Json -Depth 5 -Compress
    $Row = [pscustomobject]@{ InstanceData = $Instance; MeterCategory = 'Virtual Network'; MeterId = 'meter-1'; MeterName = 'Static Public IP'; MeterRegion = 'US East'; MeterSubCategory = 'IP Addresses'; Quantity = 24; Unit = '1 Hour'; UsageStartTime = (Get-Date).AddDays(-2).Date; UsageEndTime = (Get-Date).AddDays(-1).Date }
    [pscustomobject]@{ UsageAggregations = @([pscustomobject]@{ Properties = $Row }); ContinuationToken = $null }
}
# Get-UsageAggregates is an alias of Get-AzUsageAggregate once Az.Billing is loaded.
function global:Get-UsageAggregates { Get-AzUsageAggregate @args }
function global:Start-Sleep { param($Seconds, $Milliseconds) }
# The stream worker imports Az.Accounts before it imports the saved context.
function global:Import-Module
{
    if ($args -contains 'Az.Accounts') { return }
    Microsoft.PowerShell.Core\Import-Module @args
}

$Root = Join-Path $HOME 'InventoryReports'
New-Item -ItemType Directory -Path $Root -Force | Out-Null
$Start = (Get-Date).AddSeconds(-1)
$Passthrough = @{ SkipMetrics = $true; ConcurrencyLimit = 2 }
if ($Obfuscate) { $Passthrough.Obfuscate = $true }
Set-Location $Tree

if ($Mode -eq 'Sequential')
{
    # As the wrapper's sequential loop calls it, for Sub A and Sub B.
    foreach ($Sub in @($Global:StandInSubs | Select-Object -First 2))
    {
        $Global:StandInCurrentSub = $Sub.Id
        & (Join-Path $Tree 'ResourceInventory.ps1') -TenantID $Tenant -SubscriptionID $Sub.Id @Passthrough -RunAllSubs *> (Join-Path $HOME ('inner-' + $Sub.Name + '.log'))
    }
    $Entries = @($Global:ConsumptionFailedSubs | Where-Object { $null -ne $_ })
}
else
{
    $WorkerArgs = @{
        TenantID           = $Tenant
        StreamId           = '0'
        InventoryRoot      = $Root
        ScriptRoot         = $Tree
        AzContextPath      = (Join-Path $Root '.ctx.json')
        StreamSummaryPath  = (Join-Path $Root '.rda-stream-0-summary.json')
        StreamFailuresPath = (Join-Path $Root 'failures-stream-0.log')
        SubscriptionIds    = @($Global:StandInSubs | ForEach-Object Id)
        SubscriptionNames  = @($Global:StandInSubs | ForEach-Object Name)
        SkipMetrics        = $true
        ConcurrencyLimit   = 2
    }
    if ($Obfuscate) { $WorkerArgs.Obfuscate = $true }
    & (Join-Path $Tree 'Run-AllSubscriptions.Stream.ps1') @WorkerArgs *> (Join-Path $HOME 'worker.log')
    # What the parent wrapper appends to its run-wide list from this stream.
    $Entries = @((Get-Content -LiteralPath $WorkerArgs.StreamSummaryPath -Raw | ConvertFrom-Json).ConsumptionFailedSubs | Where-Object { $null -ne $_ })
}

# The main summary, built the way the wrapper builds it.
. (Join-Path $Tree 'Functions/AllSubHtmlSummary.Functions.ps1')
$Html = Join-Path $Root 'MainSummary_test.html'
New-RdaAllSubHtmlSummary -RunOutputDirectory $Root -HtmlFile $Html -SinceTime $Start -ConsumptionFailedSubs $Entries -Obfuscated:$Obfuscate *> $null
$Text = Get-Content -LiteralPath $Html -Raw

$Folders = foreach ($F in @(Get-ChildItem -LiteralPath $Root -Directory -Filter 'ResourcesReport*' | Sort-Object Name))
{
    $Csv = Get-ChildItem -LiteralPath $F.FullName -Filter 'Consumption_*.csv' -File | Select-Object -First 1
    $Health = [regex]::Match($Text, ('<td><span class="tag [a-z]+">([^<]*)</span></td><td><a href="' + [regex]::Escape($F.Name) + '[/\\]')).Groups[1].Value
    [pscustomobject]@{ Name = $F.Name; ConsumptionRows = $(if ($Csv) { @(Import-Csv -LiteralPath $Csv.FullName).Count } else { -1 }); Health = $Health }
}
[pscustomobject]@{
    Entries = @($Entries | ForEach-Object { [pscustomobject]@{ Id = [string]$_.Id; ReportFolder = [string]$_.ReportFolder } })
    Folders = @($Folders)
    Banner  = [regex]::Match($Text, '<b>(\d+) subscription\(s\) had consumption \(billing\) issues\.</b>').Groups[1].Value
    Html    = $Text
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $HOME 'result.json') -Encoding utf8
'@ | Set-Content -Path $script:Harness -Encoding utf8

    # One harness run in a child pwsh with its own HOME; returns the result it wrote.
    function Invoke-Harness
    {
        param([string]$Mode, [string]$FailIds, [string]$LapseIds = '', [switch]$Obfuscate)
        $CaseHome = Join-Path $script:WorkDir ('home_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $CaseHome -Force | Out-Null
        $ArgList = @('-NoProfile', '-NonInteractive', '-File', $script:Harness, '-Tree', $script:Tree, '-Mode', $Mode, '-FailIds', $FailIds, '-LapseIds', $LapseIds)
        if ($Obfuscate) { $ArgList += '-Obfuscate' }
        $SavedHome = $env:HOME
        try
        {
            $env:HOME = $CaseHome
            $Console = @(& pwsh @ArgList 2>&1 | ForEach-Object { [string]$_ })
        }
        finally
        {
            $env:HOME = $SavedHome
        }
        $ResultFile = Join-Path $CaseHome 'result.json'
        if (-not (Test-Path -LiteralPath $ResultFile)) { throw ("the harness wrote no result:`n" + ($Console -join "`n")) }
        return (Get-Content -LiteralPath $ResultFile -Raw | ConvertFrom-Json)
    }

    if (-not $IsWindows)
    {
        $script:Seq = Invoke-Harness -Mode Sequential -FailIds 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb' -Obfuscate
        $script:Par = Invoke-Harness -Mode Stream -FailIds 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb,cccccccc-cccc-cccc-cccc-cccccccccccc' -Obfuscate
        $script:Lapse = Invoke-Harness -Mode Sequential -LapseIds 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb' -Obfuscate
    }
}

AfterAll {
    if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir))
    {
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Obfuscated run, one subscription at a time: Sub B''s usage page cannot be read' -Skip:([bool]$script:SkipReason) {
    It 'both subscriptions wrote a report, Sub A with its consumption row and Sub B with none' {
        @($script:Seq.Folders).Count | Should -Be 2
        @($script:Seq.Folders | ForEach-Object ConsumptionRows) | Should -Be @(1, 0)
    }

    It 'the consumption failure entry names Sub B''s report folder' {
        @($script:Seq.Entries).Count | Should -Be 1
        $script:Seq.Entries[0].Id | Should -Be 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
        $script:Seq.Entries[0].ReportFolder | Should -Be $script:Seq.Folders[1].Name
    }

    It 'the main summary marks Sub B''s row consumption incomplete and Sub A''s row ok' {
        @($script:Seq.Folders | ForEach-Object Health) | Should -Be @('ok', 'consumption incomplete')
        $script:Seq.Banner | Should -Be '1'
    }

    It 'no subscription name or id reaches the obfuscated summary' {
        $script:Seq.Html | Should -Not -Match 'Sub [AB]\b'
        $script:Seq.Html | Should -Not -Match 'aaaaaaaa-aaaa|bbbbbbbb-bbbb'
    }
}

Describe 'Obfuscated stream of three subscriptions: Sub B''s and Sub C''s usage pages cannot be read' -Skip:([bool]$script:SkipReason) {
    It 'the stream summary keeps both consumption failure entries, each with its own report folder' {
        @($script:Par.Entries | ForEach-Object Id) | Should -Be @('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'cccccccc-cccc-cccc-cccc-cccccccccccc')
        @($script:Par.Entries | ForEach-Object ReportFolder) | Should -Be @($script:Par.Folders[1].Name, $script:Par.Folders[2].Name)
    }

    It 'the main summary marks the rows of Sub B and Sub C, and the banner counts both' {
        @($script:Par.Folders | ForEach-Object ConsumptionRows) | Should -Be @(1, 0, 0)
        @($script:Par.Folders | ForEach-Object Health) | Should -Be @('ok', 'consumption incomplete', 'consumption incomplete')
        $script:Par.Banner | Should -Be '2'
    }
}

Describe 'Obfuscated run, one subscription at a time: Sub B''s sign-in cannot be refreshed in the consumption phase' -Skip:([bool]$script:SkipReason) {
    It 'Sub B''s report has no consumption rows and Sub A''s has its row' {
        @($script:Lapse.Folders).Count | Should -Be 2
        @($script:Lapse.Folders | ForEach-Object ConsumptionRows) | Should -Be @(1, 0)
    }

    It 'the sign-in skip entry names Sub B''s report folder' {
        @($script:Lapse.Entries).Count | Should -Be 1
        $script:Lapse.Entries[0].Id | Should -Be '(auth)'
        $script:Lapse.Entries[0].ReportFolder | Should -Be $script:Lapse.Folders[1].Name
    }

    It 'the main summary marks Sub B''s row consumption incomplete and Sub A''s row ok; the banner does not count a sign-in skip (unchanged)' {
        @($script:Lapse.Folders | ForEach-Object Health) | Should -Be @('ok', 'consumption incomplete')
        $script:Lapse.Banner | Should -BeNullOrEmpty
    }
}
