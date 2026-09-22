#!/usr/bin/env pwsh
#Requires -Version 7.0

param (
    [Parameter(Mandatory = $true)] [string]   $TenantID,
    [Parameter(Mandatory = $true)] [string]   $StreamId,
    [Parameter(Mandatory = $true)] [string]   $InventoryRoot,
    [Parameter(Mandatory = $true)] [string]   $ScriptRoot,
    [Parameter(Mandatory = $true)] [string]   $AzContextPath,
    [Parameter(Mandatory = $true)] [string]   $StreamSummaryPath,
    [Parameter(Mandatory = $true)] [string]   $StreamFailuresPath,
    [string[]] $SubscriptionIds = @(),
    [string[]] $SubscriptionNames = @(),

    [int]    $ShardIndex = 0,
    [int]    $ShardCount = 1,
    [string] $StateBlobContainerUri = '',

    [switch] $Resume,
    [switch] $ResumeFailedOnly,
    [switch] $DeviceLogin,
    [switch] $Obfuscate,
    [switch] $SkipMetrics,
    [switch] $SkipConsumption,
    [switch] $SkipMarketplace,
    [switch] $UseMetricsBatch,
    [switch] $IncludeStorageMetrics,
    [switch] $SkipDiskMetrics,
    [switch] $MetricsDetailed,
    [switch] $CapacityPlan,
    [ValidateSet(0, 5, 15, 30, 60)][int] $MetricsIntervalMinutes = 0,
    [ValidateRange(1, 93)][int] $MetricsLookbackDays,
    [string[]] $Service = @(),
    [int]    $ConcurrencyLimit = 6
)

$FunctionsFile = Join-Path $PSScriptRoot 'Functions/RunAllSubscriptions.Functions.ps1'
if (-not (Test-Path -LiteralPath $FunctionsFile -PathType Leaf))
{
    Write-Host "ERROR: Required functions file not found: $FunctionsFile" -ForegroundColor Red
    Write-Host "Ensure the 'Functions' folder ships alongside this script." -ForegroundColor Yellow
    exit 1
}
. $FunctionsFile

$Tag = "[stream-$StreamId]"

if ($SubscriptionIds.Count -ne $SubscriptionNames.Count)
{
    $MismatchReason = "SubscriptionIds count ({0}) does not match SubscriptionNames count ({1}); parent must pass equal-length, positionally-paired arrays" -f $SubscriptionIds.Count, $SubscriptionNames.Count
    Write-Stream ("FATAL: {0}" -f $MismatchReason) 'Red'
    @{
        StreamId      = $StreamId
        Tenant        = $TenantID
        Status        = 'failed-to-start'
        Reason        = $MismatchReason
        Completed     = @()
        Failed        = @(0..([Math]::Max($SubscriptionIds.Count, $SubscriptionNames.Count) - 1) | ForEach-Object {
                $Name = if ($_ -lt $SubscriptionNames.Count) { $SubscriptionNames[$_] } else { '<unknown>' }
                $Id = if ($_ -lt $SubscriptionIds.Count) { $SubscriptionIds[$_] }   else { '<unknown>' }
                [pscustomobject]@{ Id = $Id; Name = $Name; Reason = 'stream did not start: SubscriptionIds/SubscriptionNames length mismatch' }
            })
        ResourceCounts = @()
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $StreamSummaryPath -Encoding utf8
    exit 1
}

if ($SubscriptionIds.Count -eq 0)
{
    Write-Stream "no subscriptions in slice; exiting cleanly" 'Yellow'
    @{
        StreamId              = $StreamId
        Tenant                = $TenantID
        Status                = 'ok'
        SubsProcessed         = 0
        Completed             = @()
        Failed                = @()
        ResourceCounts        = @()
        ConsumptionRecords    = 0
        ConsumptionFailedSubs = @()
        MetricsFailedSubs     = @()
        MarketplaceRecords    = 0
        MarketplaceFailedSubs = @()
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $StreamSummaryPath -Encoding utf8
    exit 0
}

Write-Stream ("starting; subs in slice: {0}" -f $SubscriptionIds.Count) 'Cyan'

try
{
    Import-Module Az.Accounts -ErrorAction Stop -Force | Out-Null
    try { Disable-AzContextAutosave -Scope Process -ErrorAction Stop | Out-Null }
    catch { Write-Stream ("WARNING: could not disable AzContext autosave: {0}" -f $_.Exception.Message) 'Yellow' }
    Import-AzContext -Path $AzContextPath -ErrorAction Stop | Out-Null
    Write-Stream "Az context imported from shared snapshot" 'Green'
}
catch
{
    Write-Stream ("FATAL: could not import Az context from {0}: {1}" -f $AzContextPath, $_.Exception.Message) 'Red'
    @{
        StreamId      = $StreamId
        Tenant        = $TenantID
        Status        = 'failed-to-start'
        Reason        = $_.Exception.Message
        Completed     = @()
        Failed        = @(0..([Math]::Max($SubscriptionIds.Count, $SubscriptionNames.Count) - 1) | ForEach-Object {
                $Name = if ($_ -lt $SubscriptionNames.Count) { $SubscriptionNames[$_] } else { '<unknown>' }
                $Id = if ($_ -lt $SubscriptionIds.Count) { $SubscriptionIds[$_] }   else { '<unknown>' }
                [pscustomobject]@{ Id = $Id; Name = $Name; Reason = 'stream did not start: Az context import failed' }
            })
        ResourceCounts = @()
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $StreamSummaryPath -Encoding utf8
    exit 1
}

$StreamStateFile = Join-Path $InventoryRoot (".resume-state-{0}-stream-{1}.json" -f $TenantID, $StreamId)

$StreamBlobArgs = @{}
if (-not [string]::IsNullOrWhiteSpace($StateBlobContainerUri))
{
    try
    {
        Import-Module Az.Storage -ErrorAction Stop
        $StreamBlobParts = Split-BlobContainerUri -Uri $StateBlobContainerUri
        $StreamBlobArgs = @{
            BlobContext   = New-StateBlobContext -Account $StreamBlobParts.Account
            BlobContainer = $StreamBlobParts.Container
            BlobName      = Get-StateBlobName -Prefix $StreamBlobParts.Prefix -Tenant $TenantID -ShardIndex $ShardIndex -ShardCount $ShardCount -StreamId ([int]$StreamId)
        }
    }
    catch
    {
        Write-Stream ("WARNING: could not initialise state-blob context; per-stream state stays local-only: {0}" -f $_.Exception.Message) 'Yellow'
        $StreamBlobArgs = @{}
    }
}

$CompletedIds = @()
$FailedAttempts = @()
if ($Resume -or $ResumeFailedOnly)
{
    $State = Read-StreamState -Path $StreamStateFile
    $CompletedIds = $State.Completed
    $FailedAttempts = $State.Failed
    if ($CompletedIds.Count -gt 0)
    {
        Write-Stream ("resume: skipping {0} previously-completed subs in this slice" -f $CompletedIds.Count) 'DarkGray'
    }
    if ($ResumeFailedOnly -and $FailedAttempts.Count -gt 0)
    {
        Write-Stream ("resume-failed-only: prior FailedAttempts list has {0} entry(ies) for this stream" -f $FailedAttempts.Count) 'DarkGray'
    }
}

$InventoryPassthrough = @{}
if ($DeviceLogin) { $InventoryPassthrough['DeviceLogin'] = $true }
if ($Obfuscate) { $InventoryPassthrough['Obfuscate'] = $true }
if ($SkipMetrics) { $InventoryPassthrough['SkipMetrics'] = $true }
if ($SkipConsumption) { $InventoryPassthrough['SkipConsumption'] = $true }
if ($SkipMarketplace) { $InventoryPassthrough['SkipMarketplace'] = $true }
if ($UseMetricsBatch) { $InventoryPassthrough['UseMetricsBatch'] = $true }
if ($IncludeStorageMetrics) { $InventoryPassthrough['IncludeStorageMetrics'] = $true }
if ($SkipDiskMetrics) { $InventoryPassthrough['SkipDiskMetrics'] = $true }
if ($MetricsDetailed) { $InventoryPassthrough['MetricsDetailed'] = $true }
if ($CapacityPlan) { $InventoryPassthrough['CapacityPlan'] = $true }
if ($MetricsIntervalMinutes -gt 0) { $InventoryPassthrough['MetricsIntervalMinutes'] = $MetricsIntervalMinutes }
if ($PSBoundParameters.ContainsKey('MetricsLookbackDays')) { $InventoryPassthrough['MetricsLookbackDays'] = $MetricsLookbackDays }
if ($Service -and $Service.Count -gt 0) { $InventoryPassthrough['Service'] = $Service }
$InventoryPassthrough['ConcurrencyLimit'] = $ConcurrencyLimit
if ($PSBoundParameters.ContainsKey('Debug')) { $InventoryPassthrough['Debug'] = [bool]$PSBoundParameters['Debug'] }

$ResourceCounts = @()
$Completed = @($CompletedIds)
$FailedSubs = @()
$ArchiveWriteFailures = @()

$Global:ConsumptionRecordCount = 0
$Global:ConsumptionFailedSubs = @()

$Global:MetricsApiCallCount = 0

$Global:MetricsFailedSubs = @()

$Global:MarketplaceRecordCount = 0
$Global:MarketplaceFailedSubs = @()

$Global:CollectorFailures = @()

$PairCount = [Math]::Min($SubscriptionIds.Count, $SubscriptionNames.Count)
for ($i = 0; $i -lt $PairCount; $i++)
{
    $SubId = $SubscriptionIds[$i]
    $SubName = $SubscriptionNames[$i]

    if ($Resume -and ($Completed -contains $SubId))
    {
        Write-Stream ("skipping (already completed): {0} ({1})" -f $SubName, $SubId) 'DarkGray'
        continue
    }

    Write-Stream ("processing ({0} of {1}): {2} ({3})" -f ($i + 1), $PairCount, $SubName, $SubId) 'Cyan'

    try
    {
        $global:LASTEXITCODE = 0
        $Global:ZipOutputFile = $null
        & (Join-Path $ScriptRoot 'ResourceInventory.ps1') -TenantID $TenantID -SubscriptionID $SubId @InventoryPassthrough -RunAllSubs
        if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0)
        {
            if ($LASTEXITCODE -eq 2) { $ArchiveWriteFailures += ("{0} ({1})" -f $SubName, $SubId) }
            throw "Script exited with code $LASTEXITCODE"
        }

        $ResCount = if ($null -ne $Global:Resources) { @($Global:Resources).Count } else { 0 }
        $ResourceCounts += [pscustomobject]@{ Name = $SubName; Id = $SubId; Count = $ResCount; Zip = $Global:ZipOutputFile }

        if ($ResCount -eq 0)
        {
            Write-Stream ("WARNING: '{0}' returned 0 resources (likely permission gap or empty sub)" -f $SubName) 'Yellow'
        }
        else
        {
            Write-Stream ("done: {0} - {1:N0} resources" -f $SubName, $ResCount) 'Green'
        }

        if (-not ($Completed -contains $SubId))
        {
            $Completed += $SubId
            $FailedAttempts = Remove-FailedAttempt -Existing $FailedAttempts -Id $SubId
            Write-StreamState -Path $StreamStateFile -Completed @($Completed) -FailedAttempts $FailedAttempts @StreamBlobArgs
        }
    }
    catch
    {
        $ErrRecord = $_
        Write-Stream ("ERROR processing {0}: {1}" -f $SubName, $ErrRecord.Exception.Message) 'Red'

        $DiagLines = @()
        $DiagLines += "==== Failure for subscription: $SubName ($SubId) $Tag ===="
        $DiagLines += "Timestamp: $(Get-Date -Format 'o')"
        $DiagLines += "Message:   $($ErrRecord.Exception.Message)"
        $DiagLines += "Type:      $($ErrRecord.Exception.GetType().FullName)"
        $Inner = $ErrRecord.Exception.InnerException
        $Depth = 0
        while ($null -ne $Inner -and $Depth -lt 5)
        {
            $DiagLines += "Inner[$Depth] Type:    $($Inner.GetType().FullName)"
            $DiagLines += "Inner[$Depth] Message: $($Inner.Message)"
            $Inner = $Inner.InnerException
            $Depth++
        }
        if ($null -ne $ErrRecord.InvocationInfo)
        {
            $DiagLines += "ScriptName:    $($ErrRecord.InvocationInfo.ScriptName)"
            $DiagLines += "Line:          $($ErrRecord.InvocationInfo.ScriptLineNumber)"
            $DiagLines += "PositionMsg:   $($ErrRecord.InvocationInfo.PositionMessage)"
        }
        $DiagLines += "StackTrace:"
        $DiagLines += $ErrRecord.ScriptStackTrace
        if ($null -ne $ErrRecord.Exception.StackTrace)
        {
            $DiagLines += "ExceptionStackTrace:"
            $DiagLines += $ErrRecord.Exception.StackTrace
        }
        $DiagLines += ""

        try { $DiagLines | Out-File -LiteralPath $StreamFailuresPath -Append -Encoding utf8 }
        catch { Write-Stream ("could not write to stream failures log {0}: {1}" -f $StreamFailuresPath, $_.Exception.Message) 'Yellow' }

        $FailedSubs += [pscustomobject]@{ Id = $SubId; Name = $SubName; Reason = $ErrRecord.Exception.Message }
        $FailedAttempts = Add-FailedAttempt -Existing $FailedAttempts `
            -Id $SubId -Name $SubName -Reason $ErrRecord.Exception.Message
        Write-StreamState -Path $StreamStateFile -Completed @($Completed) -FailedAttempts $FailedAttempts @StreamBlobArgs
    }
}

$ConsumptionTotal = if ($null -ne $Global:ConsumptionRecordCount) { [int]$Global:ConsumptionRecordCount } else { 0 }
$MetricsApiCallTotal = if ($null -ne $Global:MetricsApiCallCount) { [int]$Global:MetricsApiCallCount } else { 0 }
$MarketplaceTotal = if ($null -ne $Global:MarketplaceRecordCount) { [int]$Global:MarketplaceRecordCount } else { 0 }
$ConsumptionFailedSubs = if ($null -ne $Global:ConsumptionFailedSubs) { @($Global:ConsumptionFailedSubs) } else { @() }
$MetricsFailedSubs = if ($null -ne $Global:MetricsFailedSubs) { @($Global:MetricsFailedSubs) } else { @() }
$MarketplaceFailedSubs = if ($null -ne $Global:MarketplaceFailedSubs) { @($Global:MarketplaceFailedSubs) } else { @() }
$CollectorFailures = if ($null -ne $Global:CollectorFailures) { @($Global:CollectorFailures) } else { @() }

$Summary = [pscustomobject]@{
    StreamId               = $StreamId
    Tenant                 = $TenantID
    Status                 = if ($FailedSubs.Count -eq 0) { 'ok' } else { 'partial-failure' }
    SubsProcessed          = $PairCount
    Completed              = @($Completed)
    Failed                 = $FailedSubs
    ResourceCounts         = $ResourceCounts
    ConsumptionRecords     = $ConsumptionTotal
    MetricsApiCalls        = $MetricsApiCallTotal
    MarketplaceRecords     = $MarketplaceTotal
    ConsumptionFailedSubs  = @($ConsumptionFailedSubs | Select-Object -Unique)
    MetricsFailedSubs      = @($MetricsFailedSubs)
    MarketplaceFailedSubs  = @($MarketplaceFailedSubs)
    CollectorFailures      = @($CollectorFailures)
    ArchiveWriteFailures   = @($ArchiveWriteFailures)
}
try
{
    $Summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $StreamSummaryPath -Encoding utf8
}
catch
{
    Write-Stream ("FATAL: could not write stream summary to {0}: {1}" -f $StreamSummaryPath, $_.Exception.Message) 'Red'
    exit 1
}

Write-Stream ("complete: {0}/{1} succeeded, {2} failed" -f $Completed.Count, $PairCount, $FailedSubs.Count) 'Green'
exit 0

