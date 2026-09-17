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

    # Shard identity + state-blob container, forwarded by the parent ONLY when
    # blob-backed resume state is enabled. Used to mirror THIS stream's per-stream
    # resume state to a shard+stream-namespaced blob for AKS pod-reschedule
    # durability. StateBlobContainerUri empty (default) -> per-stream state stays
    # local-only, exactly as before.
    [int]    $ShardIndex = 0,
    [int]    $ShardCount = 1,
    [string] $StateBlobContainerUri = '',

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
    # EXPERIMENTAL (default OFF). Forwarded by the parent wrapper and passed on to
    # ResourceInventory.ps1's -UseMetricsBatch so this stream's subscriptions use
    # the Azure Monitor metrics:getBatch data-plane fast-path (falls back to the
    # per-call path on any failure). See the -UseMetricsBatch notes in
    # Extension/Metrics.ps1.
    [switch] $UseMetricsBatch,
    # Metric-volume controls forwarded by the parent wrapper on to
    # ResourceInventory.ps1. -IncludeStorageMetrics OPTS IN to the Storage Account
    # UsedCapacity metric, which is NOT collected by default. -SkipDiskMetrics drops
    # the Managed Disk I/O metrics; -MetricsIntervalMinutes overrides the VM / SQL /
    # OSS-DB utilization grain (0 = native); -MetricsLookbackDays sets how many days
    # of history the lookback-bound trend series cover. See the notes in
    # Extension/Metrics.ps1.
    [switch] $IncludeStorageMetrics,
    [switch] $SkipDiskMetrics,
    [ValidateSet(0, 5, 15, 30, 60)][int] $MetricsIntervalMinutes = 0,
    # No default, matching the parent: the parent sends this key ONLY when the
    # operator passed it, so an absent key must leave ResourceInventory.ps1's 31-day
    # default in force rather than a copy of it held here. Same [ValidateRange] as
    # the parent so a bad value cannot reach the metrics phase by this path either.
    # Consequence of having no default: when unbound this variable reads 0, NOT 31,
    # so anything needing the EFFECTIVE lookback must go through the same
    # ContainsKey gate used below rather than reading the variable directly.
    [ValidateRange(1, 93)][int] $MetricsLookbackDays,
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


# SubscriptionIds and SubscriptionNames are paired positionally by the parent,
# which is expected to pass equal-length arrays. The param comment above states
# the worker must NOT silently depend on that guarantee: if the arrays arrive
# mismatched, the empty-slice guard (which keys only on Ids.Count) and the
# per-sub loop (which bounds on [Math]::Min of the two counts) would silently
# drop the unpaired subs and still report Status 'ok'. Fail loud here, before
# the empty-slice guard and the Az import, writing a 'failed-to-start' summary
# so the parent sees the stream could not begin rather than a missing summary.
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
    } | ConvertTo-Json -Depth 5 | Set-Content -Path $StreamSummaryPath -Encoding utf8
    exit 1
}

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

# Optional per-stream blob mirror (AKS pod-reschedule durability). $StreamBlobArgs
# is EMPTY when no state-blob container was forwarded, so Write-StreamState below
# takes the local-only path unchanged. The blob name is shard+stream-namespaced so
# it (a) never collides with another shard pod's stream in the SHARED container and
# (b) matches the prefix the parent's Get-StateBlobNames lists on when it folds
# per-stream blobs back into the unified state. The worker has already imported the
# Az context snapshot above, so -UseConnectedAccount resolves; a context-build blip
# falls back to local-only rather than killing the stream.
$StreamBlobArgs = @{}
if (-not [string]::IsNullOrWhiteSpace($StateBlobContainerUri))
{
    try
    {
        # Explicit import: this worker is a fresh Start-Job process that only
        # imports Az.Accounts above, so New-AzStorageContext would otherwise rely
        # on module autoloading. Importing here makes a blob-enabled run fail LOUD
        # into the catch (local-only fallback) if Az.Storage is unavailable,
        # rather than silently losing durability when autoload is off.
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

# ---- Build the inner-script passthrough --------------------------------------
$InventoryPassthrough = @{}
if ($DeviceLogin) { $InventoryPassthrough['DeviceLogin'] = $true }
if ($Obfuscate) { $InventoryPassthrough['Obfuscate'] = $true }
if ($SkipMetrics) { $InventoryPassthrough['SkipMetrics'] = $true }
if ($SkipConsumption) { $InventoryPassthrough['SkipConsumption'] = $true }
if ($UseMetricsBatch) { $InventoryPassthrough['UseMetricsBatch'] = $true }
if ($IncludeStorageMetrics) { $InventoryPassthrough['IncludeStorageMetrics'] = $true }
if ($SkipDiskMetrics) { $InventoryPassthrough['SkipDiskMetrics'] = $true }
if ($MetricsIntervalMinutes -gt 0) { $InventoryPassthrough['MetricsIntervalMinutes'] = $MetricsIntervalMinutes }
# ContainsKey, not a value sentinel - 0 is a real, harmful lookback rather than
# "unset". Populated from the parent's splat, exactly as the -Debug forward below.
if ($PSBoundParameters.ContainsKey('MetricsLookbackDays')) { $InventoryPassthrough['MetricsLookbackDays'] = $MetricsLookbackDays }
if ($Service -and $Service.Count -gt 0) { $InventoryPassthrough['Service'] = $Service }
$InventoryPassthrough['ConcurrencyLimit'] = $ConcurrencyLimit
# Forward -Debug on to the inner script, mirroring the sequential path in
# Run-AllSubscriptions.ps1. This stream is a background job, which does NOT
# inherit the parent's $DebugPreference, so the wrapper forwards -Debug to this
# script explicitly and this line carries it the last hop. Without both hops
# -Debug is accepted and silently ignored for every parallel run.
# [bool] so an explicit -Debug:$false is honoured rather than inverted.
if ($PSBoundParameters.ContainsKey('Debug')) { $InventoryPassthrough['Debug'] = [bool]$PSBoundParameters['Debug'] }

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
# Subs in this slice whose report archive could not be written (inner exit 2).
# Relayed in the summary so the parent wrapper's exit code can reflect a MISSING
# report, not just a failed subscription.
$ArchiveWriteFailures = @()

# The inner script's $Global:ConsumptionRecordCount / $Global:ConsumptionFailedSubs
# are *running totals*: ResourceInventory.ps1 only nil-initializes them once and
# then accumulates with += across every subscription it processes in this
# worker's scope. Reset them to known-zero state up-front so the worker reads
# the entire-slice running total once after the loop, instead of summing
# per-iteration snapshots (which would double-count: 100, 300, 600 for three
# 100-record subs).
$Global:ConsumptionRecordCount = 0
$Global:ConsumptionFailedSubs = @()

# Metric-query API-call running total. Same running-total semantics as
# $Global:ConsumptionRecordCount above: Extension/Metrics.ps1 nil-inits it once
# then accumulates with += across every sub in this worker's scope. Reset to
# known-zero up-front so the worker reads the whole-slice total once after the
# loop instead of a stale/per-iteration value.
$Global:MetricsApiCallCount = 0

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
        # Clear $LASTEXITCODE first. It is a SHARED, STICKY variable and the inner
        # script runs with `&` in this worker's runspace, so a completion path that
        # does not call `exit` leaves the PREVIOUS subscription's value in place.
        # Without this reset, one subscription in this stream's slice exiting
        # non-zero would make every later subscription in the slice look like it
        # failed too, even though their reports were written correctly.
        #
        # $Global:ZipOutputFile is sticky the same way: the inner script has early
        # gates that leave with a BARE `Exit` (code 0) before an archive path
        # exists, and without this reset that subscription would be recorded as
        # successful carrying the PREVIOUS subscription's archive path, then pass
        # the parent's output verification "by exact path" against another
        # subscription's file.
        $global:LASTEXITCODE = 0
        $Global:ZipOutputFile = $null
        & (Join-Path $ScriptRoot 'ResourceInventory.ps1') -TenantID $TenantID -SubscriptionID $SubId @InventoryPassthrough -RunAllSubs
        # Only treat as failure if the inner script set a non-zero exit code.
        # Some completion paths in ResourceInventory.ps1 leave $LASTEXITCODE
        # unset ($null), and PowerShell's `-ne 0` returns $true against $null,
        # which would spuriously fail every successful sub.
        if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0)
        {
            # Inner code 2 == the report archive could not be written, so a report
            # is MISSING rather than merely uncollected. Relayed to the parent
            # wrapper in this stream's summary so the run's exit code can reflect
            # it. Recorded before the throw because the catch cannot read
            # $LASTEXITCODE reliably once other commands have run.
            if ($LASTEXITCODE -eq 2) { $ArchiveWriteFailures += ("{0} ({1})" -f $SubName, $SubId) }
            throw "Script exited with code $LASTEXITCODE"
        }

        # Capture inner-script globals while we are still in the same scope.
        # ResourceInventory.ps1 is invoked via `&` so its $Global:Resources lives
        # in this stream worker's scope. The inner script resets $Global:Resources
        # to @() at the start of every invocation.
        $ResCount = if ($null -ne $Global:Resources) { @($Global:Resources).Count } else { 0 }
        # Zip is the exact archive the inner script wrote, relayed to the parent
        # wrapper through this stream's summary JSON so its per-subscription output
        # verification can name a subscription whose report went missing rather
        # than only reporting a count gap.
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
            # If this is a retry that finally succeeded, drop the sub from
            # FailedAttempts so the unified resume-state file reflects truth.
            $FailedAttempts = Remove-FailedAttempt -Existing $FailedAttempts -Id $SubId
            Write-StreamState -Path $StreamStateFile -Completed @($Completed) -FailedAttempts $FailedAttempts @StreamBlobArgs
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
        Write-StreamState -Path $StreamStateFile -Completed @($Completed) -FailedAttempts $FailedAttempts @StreamBlobArgs
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
$MetricsApiCallTotal = if ($null -ne $Global:MetricsApiCallCount) { [int]$Global:MetricsApiCallCount } else { 0 }
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
    MetricsApiCalls        = $MetricsApiCallTotal
    ConsumptionFailedSubs  = @($ConsumptionFailedSubs | Select-Object -Unique)
    MetricsFailedSubs      = @($MetricsFailedSubs)
    CollectorFailures      = @($CollectorFailures)
    ArchiveWriteFailures   = @($ArchiveWriteFailures)
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
