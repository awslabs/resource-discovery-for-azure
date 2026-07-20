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
# Start-Job runs this script block in a fresh runspace (separate process) where
# the parent's functions and variables are NOT in scope, so the wrapper passes
# everything via explicit parameters. Shared helper functions are dot-sourced
# below from this worker's OWN $PSScriptRoot (Functions/RunAllSubscriptions.Functions.ps1)
# - the same file the parent loads - rather than inherited from the parent.

param (
    [Parameter(Mandatory = $true)] [string]   $TenantID,
    [Parameter(Mandatory = $true)] [string]   $StreamId,
    [Parameter(Mandatory = $true)] [string]   $InventoryRoot,
    [Parameter(Mandatory = $true)] [string]   $ScriptRoot,
    [Parameter(Mandatory = $true)] [string]   $AzContextPath,
    [Parameter(Mandatory = $true)] [string]   $StreamSummaryPath,
    [Parameter(Mandatory = $true)] [string]   $StreamFailuresPath,
    # SubscriptionIds / SubscriptionNames are intentionally NOT Mandatory.
    # PowerShell rejects empty arrays passed to Mandatory [string[]] params,
    # which would hard-fail the worker before any logging runs. The parent
    # currently guarantees non-empty slices via [Math]::Min(StreamCount, subs)
    # but a future change to the slicing logic should not silently break the
    # worker's binding. Default to @() and guard the body explicitly.
    [string[]] $SubscriptionIds = @(),
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
    # Collector scope forwarded to ResourceInventory.ps1's -Service filter. The
    # parent (Run-AllSubscriptions.ps1) already normalized + validated it and
    # passes a clean array via the Start-Job argument hashtable, so the worker
    # forwards it as-is.
    [string[]] $Service = @(),
    [int]    $ConcurrencyLimit = 6
)

# ---------------------------------------------------------------------------
# Load shared helper functions. Dot-sourced (NOT invoked via &) so they load
# into this script's scope. Fail loud if the file is missing rather than
# breaking later with a confusing "command not found".
# ---------------------------------------------------------------------------
$FunctionsFile = Join-Path $PSScriptRoot 'Functions/RunAllSubscriptions.Functions.ps1'
if (-not (Test-Path -Path $FunctionsFile -PathType Leaf))
{
    Write-Host "ERROR: Required functions file not found: $FunctionsFile" -ForegroundColor Red
    Write-Host "Ensure the 'Functions' folder ships alongside this script." -ForegroundColor Yellow
    exit 1
}
. $FunctionsFile

# Tag used to prefix all stdout lines so the parent wrapper can demultiplex
# interleaved output across streams.
$Tag = "[stream-$StreamId]"


# Empty slice = nothing to do. Write a minimal "ok with zero subs" summary so
# the parent's aggregation step (which expects a summary file from every
# stream) does not flag this as a missing-summary failure, and exit cleanly.
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
    } | ConvertTo-Json -Depth 5 | Set-Content -Path $StreamSummaryPath -Encoding utf8
    exit 0
}

Write-Stream ("starting; subs in slice: {0}" -f $SubscriptionIds.Count) 'Cyan'

# ---- Az context import -------------------------------------------------------
#
# The parent wrapper called Save-AzContext on its already-authenticated session
# and passed us the path. Importing it gives this child process a working Az
# context without prompting for sign-in. Import-AzContext is idempotent.
try
{
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
}
catch
{
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
                $Name = if ($_ -lt $SubscriptionNames.Count) { $SubscriptionNames[$_] } else { '<unknown>' }
                $Id = if ($_ -lt $SubscriptionIds.Count) { $SubscriptionIds[$_] }   else { '<unknown>' }
                [pscustomobject]@{ Id = $Id; Name = $Name; Reason = 'stream did not start: Az context import failed' }
            })
        ResourceCounts = @()
    } | ConvertTo-Json -Depth 5 | Set-Content -Path $StreamSummaryPath -Encoding utf8
    exit 1
}

# ---- Per-stream resume state -------------------------------------------------
#
# Each stream owns a separate file. No races, no locking, simple semantics.
$StreamStateFile = Join-Path $InventoryRoot (".resume-state-{0}-stream-{1}.json" -f $TenantID, $StreamId)





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

# ---- Build the inner-script passthrough --------------------------------------
$InventoryPassthrough = @{}
if ($DeviceLogin) { $InventoryPassthrough['DeviceLogin'] = $true }
if ($Obfuscate) { $InventoryPassthrough['Obfuscate'] = $true }
if ($SkipMetrics) { $InventoryPassthrough['SkipMetrics'] = $true }
if ($SkipConsumption) { $InventoryPassthrough['SkipConsumption'] = $true }
if ($Service -and $Service.Count -gt 0) { $InventoryPassthrough['Service'] = $Service }
$InventoryPassthrough['ConcurrencyLimit'] = $ConcurrencyLimit

# ---- Per-sub iteration -------------------------------------------------------
#
# This is the same shape as the wrapper's existing loop: invoke the inner
# script via `&`, capture $Global:Resources / $Global:Consumption* afterward,
# and record a per-sub status row for the wrapper to aggregate.

$ResourceCounts = @()
# Plain string array. We never call .Add() on this — only `+=`, which creates a
# new array each time. Cheaper than fighting [List[T]]::new() constructor
# overload resolution against an empty PowerShell array argument.
$Completed = @($CompletedIds)
$FailedSubs = @()

# The inner script's $Global:ConsumptionRecordCount / $Global:ConsumptionFailedSubs
# are *running totals*: ResourceInventory.ps1 only nil-initializes them once and
# then accumulates with += across every subscription it processes in this
# worker's scope. Reset them to known-zero state up-front so the worker reads
# the entire-slice running total once after the loop, instead of summing
# per-iteration snapshots (which would double-count: 100, 300, 600 for three
# 100-record subs).
$Global:ConsumptionRecordCount = 0
$Global:ConsumptionFailedSubs = @()

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
        & (Join-Path $ScriptRoot 'ResourceInventory.ps1') -TenantID $TenantID -SubscriptionID $SubId @InventoryPassthrough -RunAllSubs
        # Only treat as failure if the inner script set a non-zero exit code.
        # Some completion paths in ResourceInventory.ps1 leave $LASTEXITCODE
        # unset ($null), and PowerShell's `-ne 0` returns $true against $null,
        # which would spuriously fail every successful sub.
        if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "Script exited with code $LASTEXITCODE" }

        # Capture inner-script globals while we are still in the same scope.
        # ResourceInventory.ps1 is invoked via `&` so its $Global:Resources lives
        # in this stream worker's scope. The inner script resets $Global:Resources
        # to @() at the start of every invocation.
        $ResCount = if ($null -ne $Global:Resources) { @($Global:Resources).Count } else { 0 }
        $ResourceCounts += [pscustomobject]@{ Name = $SubName; Id = $SubId; Count = $ResCount }

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
            # If this is a retry that finally succeeded, drop the sub from
            # FailedAttempts so the unified resume-state file reflects truth.
            $FailedAttempts = Remove-FailedAttempt -Existing $FailedAttempts -Id $SubId
            Write-StreamState -Path $StreamStateFile -Completed @($Completed) -FailedAttempts $FailedAttempts
        }
    }
    catch
    {
        $ErrRecord = $_
        Write-Stream ("ERROR processing {0}: {1}" -f $SubName, $ErrRecord.Exception.Message) 'Red'

        # Build a structured failure record. Append to a per-stream failures log
        # so per-sub diagnostic detail survives even when many subs fail in one
        # stream. Mirrors the parent wrapper's diag-log shape.
        $DiagLines = @()
        $DiagLines += "==== Failure for subscription: $SubName ($SubId) [$Tag] ===="
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

        try { $DiagLines | Out-File -FilePath $StreamFailuresPath -Append -Encoding utf8 }
        catch { Write-Stream ("could not write to stream failures log {0}: {1}" -f $StreamFailuresPath, $_.Exception.Message) 'Yellow' }

        $FailedSubs += [pscustomobject]@{ Id = $SubId; Name = $SubName; Reason = $ErrRecord.Exception.Message }
        # Persist the failure to the per-stream state file. The parent
        # wrapper will fold these entries into the unified FailedAttempts
        # list when it merges per-stream state at run end. Persisting on
        # every failure (rather than only at end-of-stream) means a worker
        # that is killed mid-slice still surfaces its partial failure
        # history to the next -ResumeFailedOnly invocation.
        $FailedAttempts = Add-FailedAttempt -Existing $FailedAttempts `
            -Id $SubId -Name $SubName -Reason $ErrRecord.Exception.Message
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
$ConsumptionTotal = if ($null -ne $Global:ConsumptionRecordCount) { [int]$Global:ConsumptionRecordCount } else { 0 }
$ConsumptionFailedSubs = if ($null -ne $Global:ConsumptionFailedSubs) { @($Global:ConsumptionFailedSubs) } else { @() }
$MetricsFailedSubs = if ($null -ne $Global:MetricsFailedSubs) { @($Global:MetricsFailedSubs) } else { @() }
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
    ConsumptionFailedSubs  = @($ConsumptionFailedSubs | Select-Object -Unique)
    MetricsFailedSubs      = @($MetricsFailedSubs)
    CollectorFailures      = @($CollectorFailures)
}
try
{
    $Summary | ConvertTo-Json -Depth 6 | Set-Content -Path $StreamSummaryPath -Encoding utf8
}
catch
{
    Write-Stream ("FATAL: could not write stream summary to {0}: {1}" -f $StreamSummaryPath, $_.Exception.Message) 'Red'
    exit 1
}

Write-Stream ("complete: {0}/{1} succeeded, {2} failed" -f $Completed.Count, $PairCount, $FailedSubs.Count) 'Green'
exit 0
