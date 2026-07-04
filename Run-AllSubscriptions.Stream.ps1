#Requires -Version 7.0

# Run-AllSubscriptions.Stream.ps1
#
# Worker script invoked by Run-AllSubscriptions.ps1 when -ParallelStreams > 1.
# Each instance of this worker:
#   - Runs as a separate `pwsh` background job (fresh process, fresh AppDomain).
#   - Owns its own slice of the subscription list.
#   - Owns its own resume-state file (.resume-state-<TenantID>-stream-<N>.json),
#     so the streams cannot race on a shared file.
#   - Imports an Az PowerShell context from a shared snapshot file written by
#     the parent wrapper, so authentication is not re-prompted per stream.
#   - Calls ResourceInventory.ps1 once per subscription in its slice.
#   - Emits structured progress lines to stdout (prefixed [stream-N]) so the
#     parent wrapper can collate output across streams.
#   - Writes a per-stream JSON summary at the end so the parent can aggregate
#     resource counts, consumption results, and failures into the final
#     wrapper-level summary.
#
# This script is intentionally self-contained (no dot-source from the parent)
# because Start-Job runs the script block in a fresh runspace where parent
# functions and variables are not in scope. The wrapper passes everything via
# explicit parameters.

param (
    [Parameter(Mandatory=$true)] [string]   $TenantID,
    [Parameter(Mandatory=$true)] [string]   $StreamId,
    [Parameter(Mandatory=$true)] [string]   $InventoryRoot,
    [Parameter(Mandatory=$true)] [string]   $ScriptRoot,
    [Parameter(Mandatory=$true)] [string]   $AzContextPath,
    [Parameter(Mandatory=$true)] [string]   $StreamSummaryPath,
    [Parameter(Mandatory=$true)] [string]   $StreamFailuresPath,
    # SubscriptionIds / SubscriptionNames are intentionally NOT Mandatory.
    # PowerShell rejects empty arrays passed to Mandatory [string[]] params,
    # which would hard-fail the worker before any logging runs. The parent
    # currently guarantees non-empty slices via [Math]::Min(StreamCount, subs)
    # but a future change to the slicing logic should not silently break the
    # worker's binding. Default to @() and guard the body explicitly.
    [string[]] $SubscriptionIds   = @(),
    [string[]] $SubscriptionNames = @(),

    [switch] $Resume,
    # The parent already narrowed $SubscriptionIds to just the failed subs
    # before starting this worker, so the worker does no filtering of its own.
    # This flag is passed in only so the worker can note "failed-only mode" in
    # its summary, and so it's already wired up if the parent ever needs it.
    [switch] $ResumeFailedOnly,
    [switch] $DeviceLogin,
    [switch] $Obfuscate,
    [switch] $SkipMetrics,
    [switch] $SkipConsumption,
    [int]    $ConcurrencyLimit = 6
)

# Tag used to prefix all stdout lines so the parent wrapper can demultiplex
# interleaved output across streams.
$Tag = "[stream-$StreamId]"

function Write-Stream {
    param([string]$Message, [string]$Color = 'Gray')
    Write-Host ("{0} {1}" -f $Tag, $Message) -ForegroundColor $Color
}

# Empty slice = nothing to do. Write a minimal "ok with zero subs" summary so
# the parent's aggregation step (which expects a summary file from every
# stream) does not flag this as a missing-summary failure, and exit cleanly.
if ($SubscriptionIds.Count -eq 0) {
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
    } | ConvertTo-Json -Depth 5 | Set-Content -Path $StreamSummaryPath -Encoding utf8
    exit 0
}

Write-Stream ("starting; subs in slice: {0}" -f $SubscriptionIds.Count) 'Cyan'

# ---- Az context import -------------------------------------------------------
#
# The parent wrapper called Save-AzContext on its already-authenticated session
# and passed us the path. Importing it gives this child process a working Az
# context without prompting for sign-in. Import-AzContext is idempotent.
try {
    Import-Module Az.Accounts -ErrorAction Stop -Force | Out-Null
    # Prevent the imported context from being persisted to the user's on-disk
    # AzureRmContext.json. Without this, every parallel worker writes its
    # token cache to the same shared profile and the streams race on disk
    # state. Process-scope auto-save is per-process, so calling it here
    # confines this worker's context to in-memory.
    try { Disable-AzContextAutosave -Scope Process -ErrorAction Stop | Out-Null }
    catch { Write-Stream ("WARNING: could not disable AzContext autosave: {0}" -f $_.Exception.Message) 'Yellow' }
    Import-AzContext -Path $AzContextPath -ErrorAction Stop | Out-Null
    Write-Stream "Az context imported from shared snapshot" 'Green'
} catch {
    Write-Stream ("FATAL: could not import Az context from {0}: {1}" -f $AzContextPath, $_.Exception.Message) 'Red'
    # Write a minimum stream summary so the parent doesn't think the stream
    # disappeared silently.
    @{
        StreamId      = $StreamId
        Tenant        = $TenantID
        Status        = 'failed-to-start'
        Reason        = $_.Exception.Message
        Completed     = @()
        Failed        = @(0..([Math]::Max($SubscriptionIds.Count, $SubscriptionNames.Count) - 1) | ForEach-Object {
            $name = if ($_ -lt $SubscriptionNames.Count) { $SubscriptionNames[$_] } else { '<unknown>' }
            $id   = if ($_ -lt $SubscriptionIds.Count)   { $SubscriptionIds[$_] }   else { '<unknown>' }
            [pscustomobject]@{ Id = $id; Name = $name; Reason = 'stream did not start: Az context import failed' }
        })
        ResourceCounts = @()
    } | ConvertTo-Json -Depth 5 | Set-Content -Path $StreamSummaryPath -Encoding utf8
    exit 1
}

# ---- Per-stream resume state -------------------------------------------------
#
# Each stream owns a separate file. No races, no locking, simple semantics.
$StreamStateFile = Join-Path $InventoryRoot (".resume-state-{0}-stream-{1}.json" -f $TenantID, $StreamId)

function Read-StreamState {
    param([string]$Path)
    if (-not (Test-Path -Path $Path -PathType Leaf)) { return @{ Completed = @(); Failed = @() } }
    try {
        $obj = Get-Content -Path $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        return @{
            Completed = if ($null -eq $obj.Completed) { @() } else { @($obj.Completed) }
            # Backward-compatible: state files written by an older worker had
            # no FailedAttempts key, so default to @().
            Failed    = if ($null -eq $obj.FailedAttempts) { @() } else { @($obj.FailedAttempts) }
        }
    } catch {
        Write-Stream ("WARNING: could not read stream state at {0}: {1}" -f $Path, $_.Exception.Message) 'Yellow'
        return @{ Completed = @(); Failed = @() }
    }
}

function Write-StreamState {
    param([string]$Path, [string[]]$Completed, $FailedAttempts = @())
    try {
        @{
            Tenant         = $TenantID
            StreamId       = $StreamId
            Completed      = $Completed
            FailedAttempts = @($FailedAttempts)
        } | ConvertTo-Json -Depth 4 | Set-Content -Path $Path -Encoding utf8
    } catch {
        Write-Stream ("WARNING: failed to persist stream state to {0}: {1}" -f $Path, $_.Exception.Message) 'Yellow'
    }
}

# Per-sub helpers, matching the parent wrapper's Add-FailedAttempt /
# Remove-FailedAttempt semantics (same shape, same Attempts increment, same
# id-based dedup). Inlined rather than dot-sourced because workers cannot
# reach the parent's function table.
function Add-StreamFailedAttempt {
    param([System.Collections.IEnumerable]$Existing, [string]$Id, [string]$Name, [string]$Reason)
    $list = @($Existing | Where-Object { $_ })
    $existingEntry = $list | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if ($null -ne $existingEntry) {
        $list = @($list | Where-Object { $_.Id -ne $Id })
        $attempts = if ($existingEntry.Attempts) { [int]$existingEntry.Attempts + 1 } else { 2 }
    } else {
        $attempts = 1
    }
    $list += [pscustomobject]@{
        Id           = $Id
        Name         = $Name
        LastFailedAt = (Get-Date).ToString('o')
        Reason       = $Reason
        Attempts     = $attempts
    }
    return $list
}

function Remove-StreamFailedAttempt {
    param([System.Collections.IEnumerable]$Existing, [string]$Id)
    return @($Existing | Where-Object { $_ -and $_.Id -ne $Id })
}

$CompletedIds   = @()
$FailedAttempts = @()
if ($Resume -or $ResumeFailedOnly) {
    $state          = Read-StreamState -Path $StreamStateFile
    $CompletedIds   = $state.Completed
    $FailedAttempts = $state.Failed
    if ($CompletedIds.Count -gt 0) {
        Write-Stream ("resume: skipping {0} previously-completed subs in this slice" -f $CompletedIds.Count) 'DarkGray'
    }
    if ($ResumeFailedOnly -and $FailedAttempts.Count -gt 0) {
        Write-Stream ("resume-failed-only: prior FailedAttempts list has {0} entry(ies) for this stream" -f $FailedAttempts.Count) 'DarkGray'
    }
}

# ---- Build the inner-script passthrough --------------------------------------
$InventoryPassthrough = @{}
if ($DeviceLogin)     { $InventoryPassthrough['DeviceLogin']     = $true }
if ($Obfuscate)       { $InventoryPassthrough['Obfuscate']       = $true }
if ($SkipMetrics)     { $InventoryPassthrough['SkipMetrics']     = $true }
if ($SkipConsumption) { $InventoryPassthrough['SkipConsumption'] = $true }
$InventoryPassthrough['ConcurrencyLimit'] = $ConcurrencyLimit

# ---- Per-sub iteration -------------------------------------------------------
#
# This is the same shape as the wrapper's existing loop: invoke the inner
# script via `&`, capture $Global:Resources / $Global:Consumption* afterward,
# and record a per-sub status row for the wrapper to aggregate.

$ResourceCounts        = @()
# Plain string array. We never call .Add() on this — only `+=`, which creates a
# new array each time. Cheaper than fighting [List[T]]::new() constructor
# overload resolution against an empty PowerShell array argument.
$Completed             = @($CompletedIds)
$FailedSubs            = @()

# The inner script's $Global:ConsumptionRecordCount / $Global:ConsumptionFailedSubs
# are *running totals*: ResourceInventory.ps1 only nil-initializes them once and
# then accumulates with += across every subscription it processes in this
# worker's scope. Reset them to known-zero state up-front so the worker reads
# the entire-slice running total once after the loop, instead of summing
# per-iteration snapshots (which would double-count: 100, 300, 600 for three
# 100-record subs).
$Global:ConsumptionRecordCount = 0
$Global:ConsumptionFailedSubs  = @()

# Per-subscription metrics-phase auth health. ResourceInventory.ps1 appends to
# $Global:MetricsFailedSubs (in this worker's scope, since it is invoked via `&`)
# for each sub whose metrics phase was skipped because no usable Azure
# context/token could be established. Reset up-front so a stale value cannot leak
# in; read once after the slice loop and reported in the summary JSON.
$Global:MetricsFailedSubs = @()

# Per-subscription collector failures (#22). ResourceInventory.ps1 appends to
# $Global:CollectorFailures (in this worker's scope, since it is invoked via `&`)
# each time one of the Services/*/*.ps1 collectors throws for a subscription.
# Same reset/aggregate/report lifecycle as $Global:MetricsFailedSubs above.
$Global:CollectorFailures = @()

$pairCount = [Math]::Min($SubscriptionIds.Count, $SubscriptionNames.Count)
for ($i = 0; $i -lt $pairCount; $i++) {
    $subId   = $SubscriptionIds[$i]
    $subName = $SubscriptionNames[$i]

    if ($Resume -and ($Completed -contains $subId)) {
        Write-Stream ("skipping (already completed): {0} ({1})" -f $subName, $subId) 'DarkGray'
        continue
    }

    Write-Stream ("processing: {0} ({1})" -f $subName, $subId) 'Cyan'

    try {
        & (Join-Path $ScriptRoot 'ResourceInventory.ps1') -TenantID $TenantID -SubscriptionID $subId @InventoryPassthrough -RunAllSubs
        # Only treat as failure if the inner script set a non-zero exit code.
        # Some completion paths in ResourceInventory.ps1 leave $LASTEXITCODE
        # unset ($null), and PowerShell's `-ne 0` returns $true against $null,
        # which would spuriously fail every successful sub.
        if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "Script exited with code $LASTEXITCODE" }

        # Capture inner-script globals while we are still in the same scope.
        # ResourceInventory.ps1 is invoked via `&` so its $Global:Resources lives
        # in this stream worker's scope. The inner script resets $Global:Resources
        # to @() at the start of every invocation.
        $resCount = if ($null -ne $Global:Resources) { @($Global:Resources).Count } else { 0 }
        $ResourceCounts += [pscustomobject]@{ Name = $subName; Id = $subId; Count = $resCount }

        if ($resCount -eq 0) {
            Write-Stream ("WARNING: '{0}' returned 0 resources (likely permission gap or empty sub)" -f $subName) 'Yellow'
        } else {
            Write-Stream ("done: {0} - {1:N0} resources" -f $subName, $resCount) 'Green'
        }

        if (-not ($Completed -contains $subId)) {
            $Completed += $subId
            # If this is a retry that finally succeeded, drop the sub from
            # FailedAttempts so the unified resume-state file reflects truth.
            $FailedAttempts = Remove-StreamFailedAttempt -Existing $FailedAttempts -Id $subId
            Write-StreamState -Path $StreamStateFile -Completed @($Completed) -FailedAttempts $FailedAttempts
        }
    } catch {
        $errRecord = $_
        Write-Stream ("ERROR processing {0}: {1}" -f $subName, $errRecord.Exception.Message) 'Red'

        # Build a structured failure record. Append to a per-stream failures log
        # so per-sub diagnostic detail survives even when many subs fail in one
        # stream. Mirrors the parent wrapper's diag-log shape.
        $diagLines = @()
        $diagLines += "==== Failure for subscription: $subName ($subId) [$Tag] ===="
        $diagLines += "Timestamp: $(Get-Date -Format 'o')"
        $diagLines += "Message:   $($errRecord.Exception.Message)"
        $diagLines += "Type:      $($errRecord.Exception.GetType().FullName)"
        $inner = $errRecord.Exception.InnerException
        $depth = 0
        while ($null -ne $inner -and $depth -lt 5) {
            $diagLines += "Inner[$depth] Type:    $($inner.GetType().FullName)"
            $diagLines += "Inner[$depth] Message: $($inner.Message)"
            $inner = $inner.InnerException
            $depth++
        }
        if ($null -ne $errRecord.InvocationInfo) {
            $diagLines += "ScriptName:    $($errRecord.InvocationInfo.ScriptName)"
            $diagLines += "Line:          $($errRecord.InvocationInfo.ScriptLineNumber)"
            $diagLines += "PositionMsg:   $($errRecord.InvocationInfo.PositionMessage)"
        }
        $diagLines += "StackTrace:"
        $diagLines += $errRecord.ScriptStackTrace
        if ($null -ne $errRecord.Exception.StackTrace) {
            $diagLines += "ExceptionStackTrace:"
            $diagLines += $errRecord.Exception.StackTrace
        }
        $diagLines += ""

        try { $diagLines | Out-File -FilePath $StreamFailuresPath -Append -Encoding utf8 }
        catch { Write-Stream ("could not write to stream failures log {0}: {1}" -f $StreamFailuresPath, $_.Exception.Message) 'Yellow' }

        $FailedSubs += [pscustomobject]@{ Id = $subId; Name = $subName; Reason = $errRecord.Exception.Message }
        # Persist the failure to the per-stream state file. The parent
        # wrapper will fold these entries into the unified FailedAttempts
        # list when it merges per-stream state at run end. Persisting on
        # every failure (rather than only at end-of-stream) means a worker
        # that is killed mid-slice still surfaces its partial failure
        # history to the next -ResumeFailedOnly invocation.
        $FailedAttempts = Add-StreamFailedAttempt -Existing $FailedAttempts `
            -Id $subId -Name $subName -Reason $errRecord.Exception.Message
        Write-StreamState -Path $StreamStateFile -Completed @($Completed) -FailedAttempts $FailedAttempts
    }
}

# ---- Per-stream summary ------------------------------------------------------
#
# Single JSON file the parent wrapper aggregates across all streams.
#
# Read the consumption totals from the inner-script globals once, here, after
# the entire slice has been processed. The inner script accumulates these
# across all subs in this worker's scope (see the reset at the top of the
# loop), so a single read at the end gives the correct slice total without
# the per-iteration double-counting trap.
$ConsumptionTotal      = if ($null -ne $Global:ConsumptionRecordCount) { [int]$Global:ConsumptionRecordCount } else { 0 }
$ConsumptionFailedSubs = if ($null -ne $Global:ConsumptionFailedSubs)  { @($Global:ConsumptionFailedSubs) } else { @() }
$MetricsFailedSubs     = if ($null -ne $Global:MetricsFailedSubs)      { @($Global:MetricsFailedSubs) } else { @() }
$CollectorFailures     = if ($null -ne $Global:CollectorFailures)      { @($Global:CollectorFailures) } else { @() }

$summary = [pscustomobject]@{
    StreamId               = $StreamId
    Tenant                 = $TenantID
    Status                 = if ($FailedSubs.Count -eq 0) { 'ok' } else { 'partial-failure' }
    SubsProcessed          = $pairCount
    Completed              = @($Completed)
    Failed                 = $FailedSubs
    ResourceCounts         = $ResourceCounts
    ConsumptionRecords     = $ConsumptionTotal
    ConsumptionFailedSubs  = @($ConsumptionFailedSubs | Select-Object -Unique)
    MetricsFailedSubs      = @($MetricsFailedSubs)
    CollectorFailures      = @($CollectorFailures)
}
try {
    $summary | ConvertTo-Json -Depth 6 | Set-Content -Path $StreamSummaryPath -Encoding utf8
} catch {
    Write-Stream ("FATAL: could not write stream summary to {0}: {1}" -f $StreamSummaryPath, $_.Exception.Message) 'Red'
    exit 1
}

Write-Stream ("complete: {0}/{1} succeeded, {2} failed" -f $Completed.Count, $pairCount, $FailedSubs.Count) 'Green'
exit 0
