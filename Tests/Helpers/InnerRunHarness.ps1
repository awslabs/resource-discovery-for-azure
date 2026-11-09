# One direct run of the REAL ResourceInventory.ps1 against offline stand-ins
# for the Az cmdlets. A test runs this file in a child pwsh:
#
#   pwsh -NoProfile -NonInteractive -File InnerRunHarness.ps1 -Tree <copy of the scripts> [options]
#
#   -Culture         the culture the run uses (CurrentCulture and CurrentUICulture), e.g. tr-TR.
#   -Out             -OutputDirectory for the run; left out when empty.
#
# -Tree and -Out default to $env:RDA_INNER_HARNESS_TREE and
# $env:RDA_INNER_HARNESS_OUT. On Unix pwsh expands wildcards in the arguments
# it passes to a program (out[1] becomes out1 when out1 exists), so a test
# with [ or ] in a path hands it over in the environment instead.
#   -SubIds          the subscriptions the sign-in lists (comma-separated).
#   -AllSubs         a direct run without -SubscriptionID (every listed subscription).
#   -ResourceGroup   -ResourceGroup for the run.
#   -SignInFirst     no cached sign-in and no -TenantID: the run signs in itself
#                    (-DeviceLogin, so no browser is needed).
#   -Obfuscate       pass -Obfuscate.
#   -NoResources     the subscriptions hold no resources and have no usage.
#   -DebugOutput     pass -Debug.
#   -Runs            how many runs, one after another, in this one session
#                    (default 1). With more than one, run <n> writes to
#                    <Out>/run<n>/ and the exit code is the last run's.
#   -FailFirstRunConsumption  the usage query fails in run 1 only, so run 1
#                    records a consumption failure.
#   -RunAllSubs      pass -RunAllSubs, as the wrapper does, with one wrapper
#                    entry already in each health list before the first run.
#   -ListsOut        after run <n>, write the health lists ($Global:
#                    CollectorFailures, MetricsFailedSubs, ConsumptionFailedSubs
#                    and ConsumptionRecordCount) as JSON to <ListsOut>-<n>.json.
#
# Every subscription holds one disk in resource group RG-INFRA, and its usage
# page has one row for that disk with a consumption meter in additionalInfo.
# The stand-in for Get-AzSubscription writes one debug line ('stand-in debug
# line') so a test can see whether debug output is on. The run's exit code is
# this script's exit code. Placeholder ids and generic names only; no live Azure.
param(
    [string]$Tree = $env:RDA_INNER_HARNESS_TREE,
    [string]$Culture = 'en-US',
    [string]$Out = $env:RDA_INNER_HARNESS_OUT,
    [string]$SubIds = '12345678-1234-1234-1234-123456789012',
    [switch]$AllSubs,
    [string]$ResourceGroup = '',
    [switch]$SignInFirst,
    [switch]$Obfuscate,
    [switch]$NoResources,
    [switch]$DebugOutput,
    [int]$Runs = 1,
    [switch]$FailFirstRunConsumption,
    [switch]$RunAllSubs,
    [string]$ListsOut = ''
)
$PSStyle.OutputRendering = 'PlainText'
[System.Globalization.CultureInfo]::CurrentCulture = $Culture
[System.Globalization.CultureInfo]::CurrentUICulture = $Culture
$Global:RdaSessionInitialized = $true
$Global:AzPowerShellLoaded = $true
$Global:PlatformOS = 'PowerShell Unix'
$Global:StandInTenant = '12345678-1234-1234-1234-123456789012'
$Ids = @($SubIds -split ',' | Where-Object { $_ })
$Global:StandInSubs = @(for ($i = 0; $i -lt $Ids.Count; $i++) { [pscustomobject]@{ id = $Ids[$i]; name = ('Demo Subscription {0}' -f ($i + 1)); tenantId = $Global:StandInTenant; state = 'Enabled' } })
$Global:StandInSignedIn = -not $SignInFirst
$Global:StandInContextSub = $Ids[0]
$Global:StandInNoResources = [bool]$NoResources
$Global:StandInRun = 0
$Global:StandInFailConsumptionRun = if ($FailFirstRunConsumption) { 1 } else { 0 }

# The disk each subscription holds, with ids as Azure spells them.
function global:Get-StandInDiskId([string]$Sub) { '/subscriptions/{0}/resourceGroups/RG-INFRA/providers/Microsoft.Compute/disks/DISK-INFRA' -f $Sub }

function global:Invoke-StandInGraph
{
    $Joined = $args -join ' '
    $global:LASTEXITCODE = 0
    if ($Joined -like 'graph*')
    {
        $Subs = @()
        for ($i = 0; $i -lt $args.Count; $i++)
        {
            if ([string]$args[$i] -eq '--subscriptions')
            {
                for ($j = $i + 1; $j -lt $args.Count -and -not ([string]$args[$j]).StartsWith('--'); $j++) { $Subs += [string]$args[$j] }
            }
        }
        if ($Subs.Count -eq 0) { $Subs = @($Global:StandInSubs | ForEach-Object { [string]$_.id }) }
        if ($Global:StandInNoResources) { $Subs = @() }
        # Resource Graph keeps the resource group in small letters; == is case-sensitive.
        $Rows = @(foreach ($Sub in $Subs)
            {
                @{ id = (Get-StandInDiskId $Sub); name = 'DISK-INFRA'; type = 'microsoft.compute/disks'; location = 'eastus'; subscriptionId = $Sub; resourceGroup = 'rg-infra'
                    sku = @{ name = 'Premium_LRS' }; properties = @{ diskSizeGB = 32; diskState = 'Unattached'; timeCreated = '2024-03-15T09:41:27Z' } }
            })
        if ($Joined -match "resourceGroup == '([^']*)'") { $Want = $Matches[1]; $Rows = @($Rows | Where-Object { $_.resourceGroup -ceq $Want }) }
        if ($Joined -match 'desktopvirtualizationresources') { return '{"data":[{"count_":0}],"count":1}' }
        if ($Joined -match 'summarize count\(\)') { return ('{{"data":[{{"count_":{0}}}],"count":1}}' -f $Rows.Count) }
        return (@{ data = @($Rows); count = $Rows.Count } | ConvertTo-Json -Depth 8 -Compress)
    }
    return $null
}
function global:Get-AzContext
{
    [CmdletBinding()] param()
    if (-not $Global:StandInSignedIn) { return $null }
    [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = $Global:StandInTenant }; Subscription = [pscustomobject]@{ Id = $Global:StandInContextSub; Name = 'stand-in' }; Account = [pscustomobject]@{ Id = 'tester'; Type = 'User' } }
}
function global:Set-AzContext { [CmdletBinding()] param($Subscription, $Scope, $Context, $Tenant) $Global:StandInContextSub = [string]$Subscription; $null }
function global:Connect-AzAccount { [CmdletBinding()] param($Tenant, [switch]$UseDeviceAuthentication, $Scope) $Global:StandInSignedIn = $true; $null }
function global:Disable-AzContextAutosave { [CmdletBinding()] param($Scope) }
function global:Get-AzAccessToken
{
    [CmdletBinding()] param($ResourceUrl, $TenantId)
    if (-not $Global:StandInSignedIn) { throw 'stand-in: not signed in' }
    [pscustomobject]@{ Token = ('e30.' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"oid":"test-oid"}')).TrimEnd('=') + '.sig'); TenantId = $Global:StandInTenant }
}
function global:Get-AzSubscription
{
    [CmdletBinding()] param($TenantId, $SubscriptionId, $SubscriptionName)
    Write-Debug 'stand-in debug line'
    foreach ($Sub in @($Global:StandInSubs))
    {
        if ($SubscriptionId -and [string]$Sub.id -ne [string]$SubscriptionId) { continue }
        [pscustomobject]@{ Id = [string]$Sub.id; Name = [string]$Sub.name; TenantId = $Global:StandInTenant; HomeTenantId = $Global:StandInTenant; State = 'Enabled' }
    }
}
function global:Get-AzMetric { [CmdletBinding()] param($ResourceId, $MetricName, $StartTime, $EndTime, $TimeGrain, $AggregationType, $DefaultProfile) }
function global:Get-AzUsageAggregate
{
    [CmdletBinding()] param($ReportedStartTime, $ReportedEndTime, $AggregationGranularity, $ShowDetails, $ContinuationToken)
    if ($Global:StandInFailConsumptionRun -gt 0 -and $Global:StandInRun -eq $Global:StandInFailConsumptionRun) { throw 'stand-in: the usage query failed' }
    if ($Global:StandInNoResources) { return [pscustomobject]@{ UsageAggregations = @(); ContinuationToken = $null } }
    $Instance = @{ 'Microsoft.Resources' = @{ resourceUri = (Get-StandInDiskId $Global:StandInContextSub); location = 'eastus'; additionalInfo = @{ ConsumptionMeter = 'meter-1'; ImageType = 'Standard' } } } | ConvertTo-Json -Depth 5 -Compress
    $Row = [pscustomobject]@{ InstanceData = $Instance; MeterCategory = 'Storage'; MeterId = 'meter-1'; MeterName = 'P4 Disks'; MeterRegion = 'US East'; MeterSubCategory = 'Premium SSD Managed Disks'; Quantity = 1; Unit = '1/Month'; UsageStartTime = (Get-Date).AddDays(-2).Date; UsageEndTime = (Get-Date).AddDays(-1).Date }
    [pscustomobject]@{ UsageAggregations = @([pscustomobject]@{ Properties = $Row }); ContinuationToken = $null }
}
function global:Get-UsageAggregates { Get-AzUsageAggregate @args }
function global:Invoke-AzRestMethod
{
    param($Method, $Path, $Payload, $Uri)
    $Target = if ($Path) { $Path } else { $Uri }
    $Json = { param($Obj) [pscustomobject]@{ StatusCode = 200; Content = ($Obj | ConvertTo-Json -Depth 10) } }
    $Sub = if ($Target -match '/subscriptions/([^/?]+)') { $Matches[1] } else { $Global:StandInContextSub }
    if ($Target -match '/roleAssignments\?') { return (& $Json @{ value = @(@{ properties = @{ roleDefinitionId = "/subscriptions/$Sub/providers/Microsoft.Authorization/roleDefinitions/reader"; scope = "/subscriptions/$Sub"; principalId = 'test-oid'; principalType = 'User' } }) }) }
    if ($Target -match '/roleDefinitions/') { return (& $Json @{ properties = @{ roleName = 'Reader'; type = 'BuiltInRole'; permissions = @(@{ actions = @('*/read'); notActions = @() }) } }) }
    if ($Target -match '/providers/Microsoft\.Authorization/permissions\?') { return (& $Json @{ value = @(@{ actions = @('*/read'); notActions = @() }) }) }
    if ($Target -match '/UsageAggregates\?') { return (& $Json @{ value = @() }) }
    if ($Target -match 'Microsoft\.ResourceGraph/resources') { return (& $Json @{ data = @($Global:StandInSubs | Where-Object { -not $Global:StandInNoResources } | ForEach-Object { @{ subscriptionId = [string]$_.id; ResourceCount = 1 } }) }) }
    throw ('no stand-in for {0} {1}' -f $Method, $Target)
}
function global:Start-Sleep { param($Seconds, $Milliseconds) }

# The stand-ins exist only in this runspace, so the up-front checks of a run
# over several subscriptions check one subscription at a time.
$Global:PSDefaultParameterValues = @{
    'Test-SubscriptionRoleAccessAll:ThrottleLimit' = 1
    'Invoke-ConsumptionDataCheck:ThrottleLimit'    = 1
}

# Az PowerShell sign-in, subscription list and Resource Graph paging on top of the stand-ins above.
. (Join-Path $PSScriptRoot 'AzPsStandIns.ps1')

$Params = @{ Service = @('VMDisk') }
if (-not $SignInFirst) { $Params.TenantID = $Global:StandInTenant } else { $Params.DeviceLogin = $true }
if (-not $AllSubs) { $Params.SubscriptionID = $Ids[0] }
if ($Out) { $Params.OutputDirectory = $Out }
if ($ResourceGroup) { $Params.ResourceGroup = $ResourceGroup }
if ($Obfuscate) { $Params.Obfuscate = $true }
if ($DebugOutput) { $Params.Debug = $true }
if ($RunAllSubs)
{
    $Params.RunAllSubs = $true
    # What the wrapper has gathered from earlier subscriptions before it
    # starts this one.
    $Global:CollectorFailures = @([pscustomobject]@{ Id = 'wrapper-entry'; Module = 'WrapperEntry'; Message = 'kept by the wrapper' })
    $Global:MetricsFailedSubs = @([pscustomobject]@{ Name = 'wrapper-entry'; Id = 'wrapper-entry'; Message = 'kept by the wrapper' })
    $Global:ConsumptionFailedSubs = @([pscustomobject]@{ Name = 'wrapper-entry'; Id = 'wrapper-entry'; Message = 'kept by the wrapper' })
    $Global:ConsumptionRecordCount = 7
}
Set-Location -LiteralPath $Tree
$RunExit = 0
for ($Run = 1; $Run -le [math]::Max(1, $Runs); $Run++)
{
    $Global:StandInRun = $Run
    if ($Runs -gt 1 -and $Out)
    {
        $Params.OutputDirectory = Join-Path $Out ('run{0}/' -f $Run)
        $null = New-Item -ItemType Directory -Path $Params.OutputDirectory -Force
    }
    $global:LASTEXITCODE = 0
    & (Join-Path $Tree 'ResourceInventory.ps1') @Params
    $RunExit = $LASTEXITCODE
    Set-Location -LiteralPath $Tree
    if ($ListsOut)
    {
        [pscustomobject]@{
            CollectorFailures      = @(@($Global:CollectorFailures) | Where-Object { $null -ne $_ })
            MetricsFailedSubs      = @(@($Global:MetricsFailedSubs) | Where-Object { $null -ne $_ })
            ConsumptionFailedSubs  = @(@($Global:ConsumptionFailedSubs) | Where-Object { $null -ne $_ })
            ConsumptionRecordCount = $Global:ConsumptionRecordCount
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath ('{0}-{1}.json' -f $ListsOut, $Run) -Encoding utf8
    }
}
exit $RunExit
