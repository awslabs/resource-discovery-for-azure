#Requires -Version 7.0

param (
    [Parameter(Mandatory=$true)]
    [string]$TenantID,

    [switch]$DeviceLogin,
    [switch]$Obfuscate,
    [switch]$SkipMetrics,
    [switch]$SkipConsumption,
    [switch]$Resume,
    # Retry only the subscriptions that failed on a previous run: the script
    # processes exactly the failures recorded in the resume-state file and
    # nothing else. Handy for troubleshooting - when a large run finishes with
    # a few failures (e.g. transient throttling or an auth blip on specific
    # subs), use this to re-run just those without walking the whole tenant
    # again. (Use -Resume instead to continue an interrupted run - that covers
    # both failures and subscriptions not yet reached.) If there are no recorded
    # failures, prints "Nothing to retry" and exits 0. Works with
    # -ParallelStreams; the failed-only filter is applied before the
    # subscriptions are split across streams.
    [switch]$ResumeFailedOnly,
    [switch]$IncludeDisabled,

    # Forwarded to ResourceInventory.ps1's -ConcurrencyLimit. Default of 6 matches
    # the inner script's own default. The inner script uses this as the throttle
    # for its metrics-collection runspace pool (Get-AzMetric calls in
    # Extension/Metrics.ps1). Tenants with metric-heavy subscriptions (many VMs,
    # SQL DBs, Storage Accounts, Scale Sets, Container Registries) bottleneck on
    # this phase; raising the limit to 12-24 typically cuts that phase 30-50%
    # without hitting Azure Monitor's 12,000 reads/hour/subscription ceiling.
    # Don't go above ~24 in a single tenant - tenant-scoped Resource Graph
    # rate limits start to bite.
    [int]$ConcurrencyLimit = 6,

    # Number of parallel "streams" that process subscriptions concurrently.
    # Default 1 = current sequential behavior, no change. Each stream is a
    # separate `pwsh` background process with its own Az PowerShell context
    # and its own resume-state file (.resume-state-<TenantID>-stream-<N>.json),
    # so they cannot race on the shared Az static state or the resume file.
    # The wrapper splits the eligible subscription list into N approximately
    # equal chunks at the start and assigns one chunk per stream.
    #
    # Practical guidance:
    #   1   = sequential (default, lowest memory, easiest to debug)
    #   2   = Cloud Shell (3.5 GB RAM / 2 vCPU). Saturates both vCPUs without
    #         OOM-killing workers.
    #   3-4 = local laptop / VM with 16+ GB RAM and 4+ vCPUs.
    #   5+  = only if you have validated memory headroom (each stream loads
    #         its own Az module set, roughly 400 MB resident).
    #
    # Tenant-scoped Azure Resource Graph rate limits (~15 req/sec/tenant) are
    # the hard ceiling - more than ~6 parallel streams in one tenant will
    # start to throttle and provide no further wall-time benefit.
    [int]$ParallelStreams = 1
)

$RunStartTime = Get-Date
$FailedSubscriptions = @()

# Per-subscription metrics-phase auth health, aggregated across the whole run.
# This is the metrics counterpart to $Global:ConsumptionFailedSubs and works the
# same way: a list of { Name, Id, Message } objects, one per subscription whose
# metrics phase was skipped because Azure auth was unavailable (no valid
# context/token) even though the user did NOT pass -SkipMetrics.
#   - Sequential run: ResourceInventory.ps1 appends entries directly (it runs in
#     this wrapper's scope).
#   - Parallel run: each stream worker collects its own list and reports it in
#     its summary JSON; the aggregation loop below concatenates them, so the
#     run-level list names every affected subscription regardless of which
#     stream processed it.
# The final summary reads this list to print which subscriptions had metrics
# skipped, and to set the non-zero wrapper exit code. Empty list = no problem.
$Global:MetricsFailedSubs = @()

# Per-subscription collector failures (#22), aggregated across the whole run.
# Same pattern and lifecycle as $Global:MetricsFailedSubs above: a list of
# { Id, Module, Message } objects, one per (subscription, collector) pair
# where a Services/*/*.ps1 collector threw and was caught by
# ResourceInventory.ps1's circuit breaker.
#   - Sequential run: ResourceInventory.ps1 appends entries directly (it runs
#     in this wrapper's scope).
#   - Parallel run: each stream worker collects its own list and reports it
#     in its summary JSON; the aggregation loop below concatenates them.
$Global:CollectorFailures = @()

# Inventory root (used for resume state, consolidated output, and the wrapper
# transcript). Computed up front so the transcript can be started before
# anything else writes to the host.
$InventoryRoot = if ($PSVersionTable.Platform -eq 'Unix') { "$HOME/InventoryReports" } else { "C:\InventoryReports" }
if (-not (Test-Path -Path $InventoryRoot -PathType Container)) {
    try { New-Item -Path $InventoryRoot -ItemType Directory -Force | Out-Null }
    catch { Write-Verbose ("InventoryRoot create failed at {0}: {1}" -f $InventoryRoot, $_.Exception.Message) }
}

# Wrapper-level transcript.
#
# ResourceInventory.ps1 already records a per-subscription transcript inside
# each subscription's output folder. That captures everything inside a single
# sub's run, but it does not capture the wrapper's own output: tenant
# resolution, the auth gate's decisions, resume-state messages, the
# Processing/Completed/ERROR cross-iteration narration, the consolidation
# step, or the final summary. For multi-subscription runs that bookkeeping is
# the most useful diagnostic signal of all - which sub failed, why, what came
# before, and how the wrapper proceeded.
#
# This transcript runs at the wrapper level for every invocation (single sub
# or many) and lands at:
#   <InventoryRoot>/RunAllSubscriptions_transcript_<timestamp>.txt
# It also catches everything Write-Host'd by the inner script into the same
# console session, so the file is a complete record of one wrapper invocation.
# Start-Transcript is idempotent in the sense that we Stop it on every exit
# path via Exit-Wrapper.
$WrapperTranscriptStarted = $false
$WrapperTranscriptFile = Join-Path $InventoryRoot ("RunAllSubscriptions_transcript_{0}.txt" -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'))
try {
    Start-Transcript -Path $WrapperTranscriptFile -UseMinimalHeader -Force | Out-Null
    $WrapperTranscriptStarted = $true
    Write-Host ("Wrapper transcript: {0}" -f $WrapperTranscriptFile) -ForegroundColor DarkGray
} catch {
    # Non-fatal. If transcript fails to start (rare - usually permissions or
    # an already-running transcript on this host), the run continues without
    # one rather than aborting.
    Write-Host ("WARNING: Could not start wrapper transcript at {0}: {1}" -f $WrapperTranscriptFile, $_.Exception.Message) -ForegroundColor Yellow
}

# Single exit path that ensures the wrapper transcript is stopped before
# returning to the host. Used by every error path that previously called
# `exit <code>` directly.
function Exit-Wrapper {
    param([int]$Code = 0)
    if ($WrapperTranscriptStarted) {
        try { Stop-Transcript | Out-Null }
        catch { Write-Verbose ("Stop-Transcript on Exit-Wrapper failed: {0}" -f $_.Exception.Message) }
    }
    exit $Code
}

# Classify a subscription that returned 0 resources as either a genuine
# permission gap (the signed-in identity has NO role on the subscription) or a
# genuinely empty subscription. This distinction is impossible to make from the
# resource-discovery phase alone: Azure Resource Graph queries at the tenant
# level and returns reduced/empty results rather than a 403 when the identity
# lacks a role, so "no access" and "empty" look identical there.
#
# To tell them apart we make ONE cheap, access-scoped control-plane call:
# `az group list` on the subscription. Listing resource groups requires a role
# on the subscription (Reader is enough). If the identity has none, ARM returns
# AuthorizationFailed (403), which we detect. If it succeeds (even with zero
# RGs) the identity DOES have access, so the subscription is genuinely empty.
#
# Returns one of: 'NoAccess', 'Empty', 'Unknown'. Only called for subs that
# returned 0 resources, so it adds no cost to the normal (non-empty) path.
function Get-SubscriptionAccessState {
    param([Parameter(Mandatory=$true)][string]$SubscriptionId)

    # One cheap, access-scoped control-plane call. Capture stdout+stderr
    # together and the exit code. Listing resource groups requires a role on
    # the subscription, so a no-access identity gets AuthorizationFailed.
    $output = (az group list --subscription $SubscriptionId --query "length(@)" -o tsv 2>&1) -join ' '
    $exit = $LASTEXITCODE

    if ($exit -eq 0) {
        # Call succeeded: identity can read the subscription, so 0 resources
        # means it is genuinely empty.
        return 'Empty'
    }
    if ($output -match 'AuthorizationFailed|does not have authorization|not authorized|Forbidden|403') {
        return 'NoAccess'
    }
    # An identity that can ENUMERATE a subscription (it came from
    # Get-AzSubscription) but gets "not found / not recognized" on a
    # control-plane read into it has no usable role there - ARM hides the
    # subscription rather than returning a 403. Treat that as NoAccess too,
    # since the sub IDs we probe are always real and tenant-visible.
    if ($output -match "not found|not recognized|could not be found|was not found") {
        return 'NoAccess'
    }
    # Some other failure (transient ARM error, throttling, network). Don't
    # mislabel it - report Unknown so the summary can hedge.
    return 'Unknown'
}

# === Pre-flight checks ===
#
# Detect the most common environment problems that make a long run pointless,
# before authentication, tenant resolution, or any per-subscription work.
# Each check is one of:
#   - Hard fail: print a clear message + remediation, call Exit-Wrapper.
#   - Warn:      print a clear message and continue (the run will still
#                produce useful output, just with a known caveat).
#
# NOTE: Keep this block in sync with the same block at the top of
# ResourceInventory.ps1 (just before its Start-Transcript call). They are
# inlined in both files rather than dot-sourced from a shared file because
# the dot-source itself is a failure surface (path resolution, missing file)
# we do not want to add to a script whose entire job is to fail loudly when
# the environment is wrong.
function Invoke-PreFlightChecks {
    param(
        [Parameter(Mandatory = $true)] [string] $InventoryRoot
    )

    Write-Host "Running pre-flight checks..." -ForegroundColor Cyan

    # 1. Cloud Shell mount detection.
    #
    # Get-CloudDrive ships with the Az.CloudShell module which is preloaded
    # in Cloud Shell and not present in regular PowerShell installs. So the
    # cmdlet's existence is our "are we in Cloud Shell" probe; its return
    # value is our "is the drive mounted" probe.
    #   - Cmdlet absent       -> not in Cloud Shell, skip the check entirely.
    #   - Cmdlet present, $null returned -> Cloud Shell, ephemeral mode
    #                            (verified live: emits "Clouddrive is not
    #                            mounted" warning on stream 3 and returns null).
    #   - Cmdlet present, object returned -> Cloud Shell, drive mounted.
    # The 3>$null suppresses the noisy WARNING so our message is the first
    # thing the user sees.
    if (Get-Command Get-CloudDrive -ErrorAction SilentlyContinue) {
        $CheckCloudDrive = Get-CloudDrive 3>$null 2>$null
        if ($null -eq $CheckCloudDrive) {
            Write-Host ""
            Write-Host "WARNING: Cloud Shell detected, but no storage account is mounted." -ForegroundColor Yellow
            Write-Host "  Outputs in $InventoryRoot will be lost when this Cloud Shell session ends." -ForegroundColor Yellow
            Write-Host "  This includes the resume-state file, so -Resume on a future session won't help recover." -ForegroundColor Yellow
            Write-Host "  To persist outputs across sessions, attach a storage account via the Cloud Shell" -ForegroundColor Yellow
            Write-Host "  settings menu (gear icon) > Reset User Settings > Mount storage account." -ForegroundColor Yellow
            Write-Host "  Continuing in ephemeral mode - download the report ZIP from $InventoryRoot before closing the shell." -ForegroundColor Yellow
            Write-Host ""
        } else {
            Write-Host ("Cloud Shell drive mounted: {0}" -f $CheckCloudDrive.Name) -ForegroundColor Green
        }
    }

    # 2. Disk space probe at the inventory root.
    #
    # Cloud Shell's overlay filesystem provides ~50 GB (verified with `df -h`
    # in 2026); the legacy 5 GB number some older docs cite is outdated.
    # A 100+ subscription run can produce 200-500 MB of zips and intermediate
    # files; if free space is already low (typically because something else
    # is filling the home directory) the run will fail late with a confusing
    # "There is not enough space" during report generation or zip packaging.
    # Catch it now.
    try {
        $rootItem = Get-Item -Path $InventoryRoot -ErrorAction Stop
        $drive = $rootItem.PSDrive
        if ($null -ne $drive -and $null -ne $drive.Free) {
            $freeMB = [math]::Round($drive.Free / 1MB, 0)
            if ($freeMB -lt 100) {
                Write-Host ("ERROR: Free disk space at {0} is {1} MB. The script needs at least 100 MB to start. Free space and re-run." -f $InventoryRoot, $freeMB) -ForegroundColor Red
                Exit-Wrapper -Code 1
            } elseif ($freeMB -lt 500) {
                Write-Host ("WARNING: Free disk space at {0} is {1} MB. A large multi-subscription run can exceed this. Consider freeing space before running." -f $InventoryRoot, $freeMB) -ForegroundColor Yellow
            } else {
                Write-Host ("Free disk space: {0:N0} MB at {1}" -f $freeMB, $InventoryRoot) -ForegroundColor Green
            }
        }
    } catch {
        # If we cannot read free space (uncommon - usually means the inventory
        # root is on an exotic filesystem), warn but do not fail. The write
        # probe below is the real correctness gate.
        Write-Host ("WARNING: Could not determine free disk space at {0}: {1}" -f $InventoryRoot, $_.Exception.Message) -ForegroundColor Yellow
    }

    # 3. Write probe.
    #
    # Catches any reason the script cannot create files in $InventoryRoot:
    # readonly mount, permissions, antivirus quarantine, DLP product, etc.
    # Cheap (~1 ms) and definitive.
    $probePath = Join-Path $InventoryRoot (".write-probe-{0}.tmp" -f ([guid]::NewGuid()))
    try {
        Set-Content -Path $probePath -Value 'preflight write probe' -Encoding utf8 -ErrorAction Stop
        $probeRead = Get-Content -Path $probePath -Raw -ErrorAction Stop
        if ($probeRead -notmatch 'preflight write probe') {
            throw "Write probe content mismatch (read back '$probeRead')"
        }
        Remove-Item -Path $probePath -Force -ErrorAction Stop
        Write-Host ("Write probe: OK ({0})" -f $InventoryRoot) -ForegroundColor Green
    } catch {
        Write-Host ("ERROR: Cannot write to {0}: {1}" -f $InventoryRoot, $_.Exception.Message) -ForegroundColor Red
        Write-Host "  This usually means: readonly directory, denied permissions, antivirus or DLP product blocking writes, or a stale handle." -ForegroundColor Red
        Write-Host "  Verify the directory is writable and re-run." -ForegroundColor Red
        # Best-effort cleanup in case Set-Content partially succeeded.
        try { if (Test-Path $probePath) { Remove-Item -Path $probePath -Force -ErrorAction SilentlyContinue } }
        catch { Write-Verbose ("Probe cleanup failed at {0}: {1}" -f $probePath, $_.Exception.Message) }
        Exit-Wrapper -Code 1
    }

    # 4. (removed) ImportExcel / EPPlus health probe.
    #
    # The report format changed from Excel (.xlsx) to a self-contained HTML
    # report (Extension/Summary.ps1), which has no external module dependency.
    # There is nothing to preflight here any more. This is the dependency that
    # previously failed in Cloud Shell when ImportExcel was partially installed.

    Write-Host "Pre-flight checks passed." -ForegroundColor Green
    Write-Host ""
}

Invoke-PreFlightChecks -InventoryRoot $InventoryRoot

# Resolve a tenant identifier to a tenant GUID.
#
# -TenantID may be passed as either a GUID (the canonical form) or as a verified
# domain (e.g. "contoso.onmicrosoft.com" or "contoso.com"). When given a domain,
# resolve it to the GUID via Microsoft's public OIDC discovery endpoint:
#
#   https://login.microsoftonline.com/<domain>/v2.0/.well-known/openid-configuration
#
# That endpoint is anonymous (no sign-in required) and returns a JSON document
# whose "issuer" field embeds the tenant GUID. Resolving up front means every
# downstream call (az login, Get-AzSubscription, the resume state filename, the
# auth gate) operates on a stable identifier even if Azure later renames the
# domain.
function Resolve-TenantId {
    param([Parameter(Mandatory=$true)][string]$Value)

    $guidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    if ($Value -match $guidPattern) { return $Value }

    $url = "https://login.microsoftonline.com/$Value/v2.0/.well-known/openid-configuration"
    Write-Host ("Resolving tenant '{0}' via OIDC discovery..." -f $Value) -ForegroundColor Cyan
    try {
        $config = Invoke-RestMethod -Uri $url -Method Get -ErrorAction Stop
    } catch {
        throw "Could not resolve tenant '$Value' to a GUID. Check that it is a valid Azure AD domain or pass the tenant GUID directly. Underlying error: $($_.Exception.Message)"
    }

    if ($null -eq $config -or [string]::IsNullOrWhiteSpace($config.issuer)) {
        throw "OIDC discovery for tenant '$Value' returned an unexpected response (no issuer)."
    }

    # issuer looks like https://login.microsoftonline.com/<guid>/v2.0
    $segments = $config.issuer -split '/'
    $resolved = $segments | Where-Object { $_ -match $guidPattern } | Select-Object -First 1
    if (-not $resolved) {
        throw "OIDC discovery for tenant '$Value' did not contain a recognizable tenant GUID. issuer='$($config.issuer)'"
    }

    Write-Host ("Resolved tenant '{0}' -> {1}" -f $Value, $resolved) -ForegroundColor Green
    return $resolved
}

try {
    $TenantID = Resolve-TenantId -Value $TenantID
} catch {
    Write-Host ("ERROR: {0}" -f $_.Exception.Message) -ForegroundColor Red
    Exit-Wrapper -Code 1
}

# Resume state helpers
$ResumeStateFile = Join-Path $InventoryRoot (".resume-state-{0}.json" -f $TenantID)

function Get-CompletedSubscriptionIds {
    param([string]$Path, [string]$Tenant)

    if (-not (Test-Path -Path $Path -PathType Leaf)) { return @() }
    try {
        $state = Get-Content -Path $Path -Raw | ConvertFrom-Json
        if ($state.TenantID -ne $Tenant) {
            Write-Host ("Resume state file is for a different tenant ({0}); ignoring." -f $state.TenantID) -ForegroundColor Yellow
            return @()
        }
        if ($null -eq $state.CompletedSubscriptionIds) { return @() }
        return @($state.CompletedSubscriptionIds)
    } catch {
        Write-Host ("Could not read resume state file ({0}); starting fresh. $_" -f $Path) -ForegroundColor Yellow
        return @()
    }
}

# Read the FailedAttempts list out of the same resume-state file. Returns an
# array of objects shaped { Id, Name, LastFailedAt, Reason, Attempts }, or an
# empty array if the file is absent, malformed, or for a different tenant.
# Backward-compatible: a state file written by an older version of this
# script (which has CompletedSubscriptionIds but no FailedAttempts key) reads
# back as empty here, so existing on-disk state never blocks an upgrade.
function Get-FailedAttempts {
    param([string]$Path, [string]$Tenant)

    if (-not (Test-Path -Path $Path -PathType Leaf)) { return @() }
    try {
        $state = Get-Content -Path $Path -Raw | ConvertFrom-Json
        if ($state.TenantID -ne $Tenant) { return @() }
        if ($null -eq $state.FailedAttempts) { return @() }
        return @($state.FailedAttempts)
    } catch {
        return @()
    }
}

function Save-CompletedSubscriptionIds {
    param([string]$Path, [string]$Tenant, [string[]]$Ids, $FailedAttempts = @())

    $state = [pscustomobject]@{
        TenantID                  = $Tenant
        CompletedSubscriptionIds  = @($Ids)
        # FailedAttempts is the canonical "what to retry" list. The wrapper
        # appends/refreshes entries on every catch and removes them on the
        # next successful attempt for the same sub, so the file is always
        # an accurate snapshot of "subs that failed at least once and have
        # not yet succeeded since".
        FailedAttempts            = @($FailedAttempts)
        LastUpdated               = (Get-Date).ToString('o')
    }
    try {
        $state | ConvertTo-Json -Depth 4 | Set-Content -Path $Path -Encoding utf8
    } catch {
        Write-Host ("WARNING: Failed to persist resume state to {0}: $_" -f $Path) -ForegroundColor Yellow
    }
}

# Update an in-memory FailedAttempts list to record (or refresh) one sub's
# failure. Increments Attempts when the sub is already in the list. Caller
# is responsible for persisting via Save-CompletedSubscriptionIds afterwards.
function Add-FailedAttempt {
    param(
        [System.Collections.IEnumerable]$Existing,
        [string]$Id,
        [string]$Name,
        [string]$Reason
    )
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

# Remove a sub's FailedAttempts entry once it has succeeded on a retry, so
# the resume-state file does not grow into a graveyard of historical
# failures. Caller persists.
function Remove-FailedAttempt {
    param(
        [System.Collections.IEnumerable]$Existing,
        [string]$Id
    )
    return @($Existing | Where-Object { $_ -and $_.Id -ne $Id })
}

# Discover every per-stream resume-state file on disk for a tenant, rather
# than iterating 0..($StreamCount-1). $StreamCount reflects THIS run's
# -ParallelStreams value; if an earlier interrupted run used a LARGER value,
# its higher-numbered per-stream files would otherwise never be read (losing
# their Completed/FailedAttempts data) nor cleaned up (leaving them as
# orphans). -Force is required because these filenames are dot-prefixed and
# Get-ChildItem hides dot-files by default on Unix. Pulled out to its own
# function purely so it can be exercised by a Pester test against a temp
# directory without spinning up any streams.
function Get-StreamResumeStateFiles {
    param(
        [Parameter(Mandatory=$true)][string]$InventoryRoot,
        [Parameter(Mandatory=$true)][string]$Tenant
    )
    return @(Get-ChildItem -Path $InventoryRoot -Filter (".resume-state-{0}-stream-*.json" -f $Tenant) -File -Force -ErrorAction SilentlyContinue)
}

# Reconcile FailedAttempts entries gathered from multiple streams (plus any
# pre-existing entries) against the unified CompletedIds list.
#   - A sub that now appears in CompletedIds (any stream, or a prior run,
#     succeeded for it) is dropped entirely.
#   - Otherwise, when the same sub failed in more than one place, the entry
#     with the most recent LastFailedAt wins - so a stale failure recorded
#     before a later, more informative failure never shadows it.
# Pulled out to its own function (previously inlined) so this decision can
# be unit-tested directly instead of only via full multi-stream runs.
function Merge-FailedAttempts {
    param(
        [System.Collections.IEnumerable]$ExistingFailedAttempts,
        [System.Collections.IEnumerable]$StreamFailedAttempts,
        [System.Collections.IEnumerable]$CompletedIds
    )
    $CompletedIds = @($CompletedIds)
    if (@($StreamFailedAttempts).Count -eq 0) {
        # No new stream failures: still prune any existing entry whose sub
        # now appears in CompletedIds (a different stream succeeded for it).
        return @($ExistingFailedAttempts | Where-Object { $_ -and -not ($CompletedIds -contains $_.Id) })
    }
    $merged = @($ExistingFailedAttempts) + @($StreamFailedAttempts)
    $byId = $merged | Where-Object { $_ } | Group-Object -Property Id
    $reconciled = @()
    foreach ($g in $byId) {
        if ($CompletedIds -contains $g.Name) { continue }
        $best = $g.Group | Sort-Object -Property @{Expression={[datetime]($_.LastFailedAt)}} -Descending | Select-Object -First 1
        $reconciled += $best
    }
    return $reconciled
}

# Authenticate, but only if needed.
#
# In environments like Azure Cloud Shell the shell already has a valid az CLI
# and Az PowerShell session for the signed-in user. Unconditionally calling
# `az login` and `Connect-AzAccount` from the wrapper produces a redundant
# browser/device-code prompt every run.
#
# Two things have to be true to skip the interactive login:
#   1. The cached context for each side must be on the requested tenant.
#   2. That cached context must still be able to *acquire a token* silently.
# Condition 1 alone is not enough: a context can persist on disk (e.g. in
# ~/.Azure/AzureRmContext.json) with the right tenant ID but an expired or
# revoked refresh token. In that state Azure AD requires user interaction
# (typically driven by Conditional Access or MFA), so any data-plane call
# from inside the script will emit a warning like "Unable to acquire token
# for tenant ... User interaction is required" and silently return nothing -
# producing an empty inventory rather than failing loudly.
#
# Therefore the gate probes token acquisition for the requested tenant on both
# sides. Only if both probes succeed do we skip the login.

function Get-AzCliSignedInTenant {
    $raw = az account show --output json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) { return $null }
    try { return ($raw | ConvertFrom-Json).tenantId } catch { return $null }
}

function Get-AzPsSignedInTenant {
    try {
        $ctx = Get-AzContext -ErrorAction Stop
        if ($null -eq $ctx -or $null -eq $ctx.Account) { return $null }
        return $ctx.Tenant.Id
    } catch {
        return $null
    }
}

# Probe whether az CLI can silently acquire a token for $TenantID.
# Returns $true on success, $false on any failure.
function Test-AzCliTokenSilent {
    param([Parameter(Mandatory=$true)][string]$Tenant)
    az account get-access-token --tenant $Tenant --output none 2>$null
    return ($LASTEXITCODE -eq 0)
}

# Probe whether Az PowerShell can silently acquire a token for $TenantID.
# Get-AzAccessToken in this configuration emits a non-terminating warning
# instead of throwing on token-acquisition failure, so we capture warnings
# explicitly and treat any warning as a failure signal in addition to
# catching outright exceptions. We DO NOT treat the Az.Accounts 4.x
# deprecation banner as a failure - that warning fires on every successful
# call now that the SecureString-output cmdlet is the recommended path,
# and ignoring it lets users on the new module version skip re-auth.
function Test-AzPsTokenSilent {
    param([Parameter(Mandatory=$true)][string]$Tenant)
    $warnings = @()
    try {
        $token = Get-AzAccessToken -TenantId $Tenant -ErrorAction Stop -WarningVariable warnings -WarningAction SilentlyContinue
        if ($null -eq $token -or [string]::IsNullOrWhiteSpace($token.Token)) { return $false }
        # Filter out known-benign warnings before deciding the call failed.
        # Az.Accounts >= 4.x emits a deprecation banner about the plain-string
        # output every time the cmdlet returns successfully; treating that as
        # failure forces users to re-authenticate every run.
        $realWarnings = @($warnings | Where-Object {
            $msg = $_.Message
            -not (
                $msg -match 'Get-AzAccessToken\s*:?\s*Upcoming breaking changes' -or
                $msg -match 'AsSecureString' -or
                $msg -match 'plain string token output is deprecated'
            )
        })
        if ($realWarnings.Count -gt 0) { return $false }
        return $true
    } catch {
        return $false
    }
}

try {
    $cliTenant = Get-AzCliSignedInTenant
    $psTenant  = Get-AzPsSignedInTenant

    $cliTenantOk = ($cliTenant -eq $TenantID)
    $psTenantOk  = ($psTenant  -eq $TenantID)

    $cliTokenOk = $false
    $psTokenOk  = $false
    if ($cliTenantOk) { $cliTokenOk = Test-AzCliTokenSilent -Tenant $TenantID }
    if ($psTenantOk)  { $psTokenOk  = Test-AzPsTokenSilent  -Tenant $TenantID }

    $cliOk = $cliTenantOk -and $cliTokenOk
    $psOk  = $psTenantOk  -and $psTokenOk

    if ($cliOk -and $psOk) {
        Write-Host ("Existing session detected for tenant {0} (token probe ok); skipping interactive login." -f $TenantID) -ForegroundColor Green
    } else {
        if (-not $cliOk) {
            if ($null -eq $cliTenant) {
                Write-Host "az CLI is not signed in; authenticating..." -ForegroundColor Cyan
            } elseif (-not $cliTenantOk) {
                Write-Host ("az CLI is signed in to tenant {0}; switching to {1}..." -f $cliTenant, $TenantID) -ForegroundColor Cyan
            } else {
                Write-Host ("az CLI session for tenant {0} cannot acquire a token silently (likely expired or CA/MFA-gated); re-authenticating..." -f $TenantID) -ForegroundColor Cyan
            }
            if ($DeviceLogin) {
                az login -t $TenantID --use-device-code --only-show-errors | Out-Null
            } else {
                az login -t $TenantID --only-show-errors | Out-Null
            }
            if ($LASTEXITCODE -ne 0) { throw "az login failed with exit code $LASTEXITCODE" }
        }

        if (-not $psOk) {
            if ($null -eq $psTenant) {
                Write-Host "Az PowerShell is not signed in; authenticating..." -ForegroundColor Cyan
            } elseif (-not $psTenantOk) {
                Write-Host ("Az PowerShell is signed in to tenant {0}; switching to {1}..." -f $psTenant, $TenantID) -ForegroundColor Cyan
            } else {
                Write-Host ("Az PowerShell session for tenant {0} cannot acquire a token silently (likely expired or CA/MFA-gated); re-authenticating..." -f $TenantID) -ForegroundColor Cyan
            }
            if ($DeviceLogin) {
                Connect-AzAccount -Tenant $TenantID -UseDeviceAuthentication | Out-Null
            } else {
                Connect-AzAccount -Tenant $TenantID | Out-Null
            }
        }
    }
} catch {
    Write-Host "ERROR: Authentication failed. $_" -ForegroundColor Red
    Exit-Wrapper -Code 1
}

# Get all Azure subscriptions.
#
# Get-AzSubscription emits warnings (rather than throwing) when token
# acquisition for a tenant fails - typically due to CA/MFA gating. In that
# state the cmdlet returns no subscriptions, which would otherwise cause
# this wrapper to report "All subscriptions processed!" with an empty
# inventory. Capture warnings and treat zero-results-with-warnings as a
# loud failure instead of a silent one.
$subWarnings = @()
$allSubscriptions = Get-AzSubscription -TenantId $TenantID -WarningVariable subWarnings -WarningAction SilentlyContinue
if ($null -eq $allSubscriptions) { $allSubscriptions = @() }
$allSubscriptions = @($allSubscriptions)

if ($allSubscriptions.Count -eq 0) {
    Write-Host ("ERROR: Get-AzSubscription returned no subscriptions for tenant {0}." -f $TenantID) -ForegroundColor Red
    if ($subWarnings.Count -gt 0) {
        Write-Host "Underlying warnings:" -ForegroundColor Red
        foreach ($w in $subWarnings) { Write-Host ("  - {0}" -f $w) -ForegroundColor Red }
        Write-Host "This typically indicates the cached session cannot acquire a token (Conditional Access / MFA), or the signed-in identity has no access to any subscription in this tenant." -ForegroundColor Yellow
        Write-Host "Try re-running with -DeviceLogin, or sign out and sign back in to the requested tenant." -ForegroundColor Yellow
    } else {
        Write-Host "The signed-in identity may have no subscriptions in this tenant. Verify with 'Get-AzSubscription -TenantId <id>' interactively." -ForegroundColor Yellow
    }
    Exit-Wrapper -Code 1
}

# Filter out non-Enabled subscriptions by default. Disabled / Warned / Deleted
# subscriptions return little-to-no data from Resource Graph and most ARM
# data-plane calls, so processing them produces near-empty per-subscription
# reports while still costing wall-clock time (which matters for environments
# like Azure Cloud Shell where the session has a hard maximum lifetime).
# Pass -IncludeDisabled to inventory every subscription regardless of state.
if ($IncludeDisabled) {
    $subscriptions = $allSubscriptions
    $excluded = @()
} else {
    $subscriptions = @($allSubscriptions | Where-Object { $_.State -eq 'Enabled' })
    $excluded     = @($allSubscriptions | Where-Object { $_.State -ne 'Enabled' })
}

Write-Host ("Subscriptions visible: {0}" -f $allSubscriptions.Count) -ForegroundColor Cyan
if ($excluded.Count -gt 0) {
    $byState = $excluded | Group-Object -Property State | ForEach-Object { ('{0}: {1}' -f $_.Name, $_.Count) }
    Write-Host ("Excluded {0} non-Enabled subscription(s) [{1}]. Use -IncludeDisabled to inventory them anyway." -f $excluded.Count, ($byState -join ', ')) -ForegroundColor Yellow
}
Write-Host ("Subscriptions to process: {0}" -f $subscriptions.Count) -ForegroundColor Cyan

# Always seed $CompletedIds from the existing state file. -Resume only
# controls whether we *use* that list to skip subscriptions; reading it
# either way ensures the per-iteration writes below append to existing
# state instead of overwriting it.
$CompletedIds = Get-CompletedSubscriptionIds -Path $ResumeStateFile -Tenant $TenantID
# Always seed $FailedAttempts the same way. Read on every run so the writes
# below preserve any existing failure history; -ResumeFailedOnly is what
# uses it to filter the subscription list.
$FailedAttempts = Get-FailedAttempts -Path $ResumeStateFile -Tenant $TenantID
if ($Resume) {
    if ($CompletedIds.Count -gt 0) {
        Write-Host ("Resume mode: {0} previously completed subscription(s) will be skipped." -f $CompletedIds.Count) -ForegroundColor Cyan
    } else {
        Write-Host "Resume mode: no previous state found; processing all subscriptions." -ForegroundColor Cyan
    }
} else {
    if ($CompletedIds.Count -gt 0) {
        Write-Host ("Note: resume state file exists at {0} ({1} previously completed). Pass -Resume to skip them." -f $ResumeStateFile, $CompletedIds.Count) -ForegroundColor Yellow
    }
}

# -ResumeFailedOnly narrows the eligible-subscription list to only those that
# have a FailedAttempts entry from a prior run. This is the targeted-retry
# workflow: a 100-sub run had 7 failures, the operator wants to re-run JUST
# those 7 instead of walking the whole tenant again with -Resume.
#
# Filter happens here, BEFORE the -Resume "skip completed" check below, because
# in failed-only mode the resume list is the authority on what to do; the
# completed list is only checked to defend against a sub that succeeded on a
# previous retry but whose FailedAttempts entry was not yet pruned (shouldn't
# happen if the catch/success paths are correct, but cheap to defend).
if ($ResumeFailedOnly) {
    if ($FailedAttempts.Count -eq 0) {
        Write-Host "ResumeFailedOnly: no failed subscriptions in resume state. Nothing to retry." -ForegroundColor Green
        Write-Host ("If you expected failures here, verify {0} has a non-empty FailedAttempts array." -f $ResumeStateFile) -ForegroundColor DarkGray
        Exit-Wrapper -Code 0
    }
    $failedIds = @($FailedAttempts | ForEach-Object { $_.Id })
    $beforeCount = $subscriptions.Count
    $subscriptions = @($subscriptions | Where-Object { $failedIds -contains $_.Id })
    Write-Host ("ResumeFailedOnly: filtered to {0} previously-failed subscription(s) (was {1})." -f $subscriptions.Count, $beforeCount) -ForegroundColor Cyan
    if ($subscriptions.Count -eq 0) {
        # Could happen if the visible-subs list no longer contains the failed
        # IDs (sub was deleted, identity lost access, IncludeDisabled toggled
        # off relative to the prior run). Tell the user instead of silently
        # processing nothing.
        Write-Host "WARNING: FailedAttempts list contained IDs but none are visible in the current subscription set. Verify access and -IncludeDisabled flag matches the prior run." -ForegroundColor Yellow
        Exit-Wrapper -Code 0
    }
}

# Build passthrough hashtable for optional switches
$InventoryPassthrough = @{}
if ($DeviceLogin)      { $InventoryPassthrough['DeviceLogin'] = $true }
if ($Obfuscate)        { $InventoryPassthrough['Obfuscate'] = $true }
if ($SkipMetrics)      { $InventoryPassthrough['SkipMetrics'] = $true }
if ($SkipConsumption)  { $InventoryPassthrough['SkipConsumption'] = $true }
# Always forward ConcurrencyLimit so the operator can tune metrics-phase
# throttling end-to-end from a single param instead of editing the inner
# script's default. Defaults to 6 (the inner script's existing default), so
# behavior is unchanged for runs that don't pass it.
$InventoryPassthrough['ConcurrencyLimit'] = $ConcurrencyLimit
if ($PSBoundParameters.ContainsKey('Debug')) { $InventoryPassthrough['Debug'] = $true }

# Loop through each subscription and run ResourceInventory
$SkippedCount = 0
$DiagFile = $null
# Per-subscription resource counts collected for the final summary so the user
# can see at a glance which subscriptions came back empty (the most common
# explanation is that the signed-in identity does not have Reader on the
# subscription, but it can also legitimately mean the subscription is empty).
$SubResourceCounts = @()

if ($ParallelStreams -le 1) {
    # === SEQUENTIAL PATH (default) ============================================
    # Original behavior, unchanged. Selected when -ParallelStreams 1 or unset.
foreach ($sub in $subscriptions) {
    if ($Resume -and ($CompletedIds -contains $sub.Id)) {
        Write-Host ("Skipping (already completed): {0} ({1})" -f $sub.Name, $sub.Id) -ForegroundColor DarkGray
        $SkippedCount++
        continue
    }

    Write-Host "Processing subscription: $($sub.Name) ($($sub.Id))" -ForegroundColor Cyan

    try {
        & (Join-Path $PSScriptRoot "ResourceInventory.ps1") -TenantID $TenantID -SubscriptionID $sub.Id @InventoryPassthrough -RunAllSubs
        # Only treat as failure if the inner script set a non-zero exit code.
        # Some completion paths leave $LASTEXITCODE unset ($null), and
        # PowerShell's `-ne 0` returns $true against $null - which would
        # spuriously fail every successful sub.
        if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "Script exited with code $LASTEXITCODE" }

        # Capture the per-subscription resource count from the inner script.
        # ResourceInventory.ps1 invokes via `& <path>` so its $Global:Resources
        # lives in this wrapper's scope. The inner script resets that variable
        # to @() at the start of every invocation, so the count after return
        # accurately reflects the subscription that just finished.
        $resCount = if ($null -ne $Global:Resources) { @($Global:Resources).Count } else { 0 }
        $SubResourceCounts += [pscustomobject]@{
            Name  = $sub.Name
            Id    = $sub.Id
            Count = $resCount
        }

        if ($resCount -eq 0) {
            # Loud yellow signal so this stands out in the per-iteration narration
            # and in the wrapper transcript. The most common cause is the signed-in
            # identity not having Reader on the subscription; second is a sub that
            # genuinely has no resources. Either way the user almost always wants
            # to know immediately rather than discover it days later when the
            # consolidated report turns out to be empty for some subs.
            Write-Host ("WARNING: Subscription '{0}' returned 0 resources. Likely permission gap (no Reader on the subscription) or a genuinely empty subscription. Verify with: az graph query -q ""resources | summarize count()"" --subscriptions {1}" -f $sub.Name, $sub.Id) -ForegroundColor Yellow
        } else {
            Write-Host ("Resources collected: {0:N0}" -f $resCount) -ForegroundColor DarkGreen
        }

        Write-Host "Completed subscription: $($sub.Name)" -ForegroundColor Green

        # Mark complete and persist immediately so a mid-run sign-out is recoverable.
        # If the sub was previously in FailedAttempts (i.e. this is a retry that
        # finally succeeded), remove its entry so the resume-state file reflects
        # current truth.
        $stateChanged = $false
        if (-not ($CompletedIds -contains $sub.Id)) {
            $CompletedIds += $sub.Id
            $stateChanged = $true
        }
        $beforeFailedCount = @($FailedAttempts).Count
        $FailedAttempts = Remove-FailedAttempt -Existing $FailedAttempts -Id $sub.Id
        if (@($FailedAttempts).Count -ne $beforeFailedCount) { $stateChanged = $true }
        if ($stateChanged) {
            Save-CompletedSubscriptionIds -Path $ResumeStateFile -Tenant $TenantID -Ids $CompletedIds -FailedAttempts $FailedAttempts
        }
    } catch {
        # Surface the full exception chain so failures (e.g. report/JSON write
        # errors, OOM in long CloudShell runs, file-handle leaks) are
        # diagnosable instead of being summarised to a single line. See #16.
        $errRecord = $_
        Write-Host "ERROR processing subscription $($sub.Name): $errRecord" -ForegroundColor Red

        $diagLines = @()
        $diagLines += "==== Failure for subscription: $($sub.Name) ($($sub.Id)) ===="
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

        # Environment snapshot — useful when CloudShell runs out of memory or disk
        try {
            $proc = Get-Process -Id $PID
            $diagLines += "Process WorkingSet (MB):  $([math]::Round($proc.WorkingSet64 / 1MB, 1))"
            $diagLines += "Process PrivateMemory (MB): $([math]::Round($proc.PrivateMemorySize64 / 1MB, 1))"
        } catch { Write-Verbose ("Process snapshot failed: {0}" -f $_.Exception.Message) }

        try {
            $InventoryRoot = if ($PSVersionTable.Platform -eq 'Unix') { "$HOME/InventoryReports" } else { "C:\InventoryReports" }
            if (Test-Path $InventoryRoot) {
                $rootDrive = (Get-Item $InventoryRoot).PSDrive
                if ($rootDrive) {
                    $diagLines += "Free disk on $($rootDrive.Name): (MB): $([math]::Round($rootDrive.Free / 1MB, 1))"
                }
            }
        } catch { Write-Verbose ("Disk snapshot failed: {0}" -f $_.Exception.Message) }

        $diagLines += ""

        # Write to a per-run failures file so we don't lose the detail when many subs fail.
        if ($null -eq $DiagFile) {
            $InventoryRoot = if ($PSVersionTable.Platform -eq 'Unix') { "$HOME/InventoryReports" } else { "C:\InventoryReports" }
            if (-not (Test-Path $InventoryRoot)) {
                try { New-Item -ItemType Directory -Path $InventoryRoot -Force | Out-Null }
                catch { Write-Verbose ("InventoryRoot create failed at {0}: {1}" -f $InventoryRoot, $_.Exception.Message) }
            }
            $DiagFile = Join-Path $InventoryRoot ("RunAllSubscriptions_failures_{0}_{1}.log" -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss-fff'), [guid]::NewGuid().ToString().Substring(0,4))
        }
        try { $diagLines | Out-File -FilePath $DiagFile -Append -Encoding utf8 }
        catch { Write-Verbose ("DiagFile write failed at {0}: {1}" -f $DiagFile, $_.Exception.Message) }

        $FailedSubscriptions += $sub.Name
        # Persist the failure to the resume-state file so a future run with
        # -ResumeFailedOnly can target it. Use the exception message as the
        # Reason so the operator can see at a glance why each sub failed
        # without opening the diag log.
        $FailedAttempts = Add-FailedAttempt -Existing $FailedAttempts `
            -Id $sub.Id -Name $sub.Name `
            -Reason $errRecord.Exception.Message
        Save-CompletedSubscriptionIds -Path $ResumeStateFile -Tenant $TenantID -Ids $CompletedIds -FailedAttempts $FailedAttempts
    }

    Write-Host "-----------------------------------" -ForegroundColor Gray
}

} else {
    # === PARALLEL-STREAMS PATH ================================================
    #
    # Each "stream" is a separate `pwsh` background job (Start-Job runs the
    # provided ScriptBlock in a fresh process). Process-level isolation is
    # what makes this safe: the inner script's `Set-AzContext -Subscription`
    # call (in the consumption phase) mutates *process-global* Az PowerShell
    # state, so two streams running in the same process would race each
    # other's contexts and silently cross-contaminate consumption data.
    # A separate process per stream sidesteps that entirely.
    #
    # Each stream owns:
    #   - Its own slice of the eligible subscription list (round-robin split).
    #   - Its own resume-state file at
    #     $InventoryRoot/.resume-state-<TenantID>-stream-<N>.json
    #     so concurrent state writes cannot race.
    #   - Its own per-stream summary JSON (Stream_<N>_Summary.json) which the
    #     parent aggregates at the end.
    #   - Its own per-stream failures log (RunAllSubscriptions_failures_*_stream-<N>.log).
    #
    # All streams share:
    #   - One Az context snapshot, written by the parent via Save-AzContext
    #     and imported by every stream via Import-AzContext. This is the only
    #     way to avoid an interactive sign-in prompt in each child process.
    #     The snapshot is removed after all streams finish.
    #
    # Output is interleaved (each stream prints its own lines, prefixed
    # `[stream-N]`). The final summary is consolidated from the per-stream
    # summary JSON files.

    $StreamCount = [Math]::Min($ParallelStreams, $subscriptions.Count)
    Write-Host ""
    Write-Host ("Parallel-streams mode: {0} streams across {1} eligible subscription(s)" -f $StreamCount, $subscriptions.Count) -ForegroundColor Cyan
    if ($ParallelStreams -gt $subscriptions.Count) {
        Write-Host ("Note: -ParallelStreams {0} clamped to {1} (one stream per subscription is the practical limit)." -f $ParallelStreams, $StreamCount) -ForegroundColor DarkGray
    }
    Write-Host "Each stream is a separate pwsh background job with its own Az context and resume-state file." -ForegroundColor DarkGray
    Write-Host ""

    if ($StreamCount -le 1) {
        # User asked for parallel but only one (or zero) sub is eligible.
        # Process it inline using the same per-sub logic the sequential
        # branch uses, instead of bailing and asking the user to re-run.
        Write-Host "Only one eligible subscription; running sequentially." -ForegroundColor Yellow
        if ($subscriptions.Count -gt 0) {
            $sub = $subscriptions[0]
            Write-Host "Processing subscription: $($sub.Name) ($($sub.Id))" -ForegroundColor Cyan
            try {
                & (Join-Path $PSScriptRoot "ResourceInventory.ps1") -TenantID $TenantID -SubscriptionID $sub.Id @InventoryPassthrough -RunAllSubs
                # Same null-guard as the sequential branch above.
                if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "Script exited with code $LASTEXITCODE" }
                $resCount = if ($null -ne $Global:Resources) { @($Global:Resources).Count } else { 0 }
                $SubResourceCounts += [pscustomobject]@{ Name = $sub.Name; Id = $sub.Id; Count = $resCount }
                if ($resCount -eq 0) {
                    Write-Host ("WARNING: '{0}' returned 0 resources." -f $sub.Name) -ForegroundColor Yellow
                } else {
                    Write-Host ("Resources collected: {0:N0}" -f $resCount) -ForegroundColor DarkGreen
                }
                if (-not ($CompletedIds -contains $sub.Id)) {
                    $CompletedIds += $sub.Id
                    $FailedAttempts = Remove-FailedAttempt -Existing $FailedAttempts -Id $sub.Id
                    Save-CompletedSubscriptionIds -Path $ResumeStateFile -Tenant $TenantID -Ids $CompletedIds -FailedAttempts $FailedAttempts
                }
            } catch {
                # Match the sequential branch's diagnostic detail so users do not
                # get a degraded error report when -ParallelStreams collapses to a
                # single subscription. Mirrors the catch handler around line 615.
                $errRecord = $_
                Write-Host ("ERROR processing subscription {0}: {1}" -f $sub.Name, $errRecord) -ForegroundColor Red
                $diagLines = @()
                $diagLines += "==== Failure for subscription: $($sub.Name) ($($sub.Id)) ===="
                $diagLines += "Timestamp: $(Get-Date -Format 'o')"
                $diagLines += "Message:   $($errRecord.Exception.Message)"
                $diagLines += "Type:      $($errRecord.Exception.GetType().FullName)"
                $diagLines += "StackTrace:"
                $diagLines += $errRecord.ScriptStackTrace
                $diagLines += ""
                if ($null -eq $DiagFile) {
                    $DiagFile = Join-Path $InventoryRoot ("RunAllSubscriptions_failures_{0}_{1}.log" -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss-fff'), [guid]::NewGuid().ToString().Substring(0,4))
                }
                try { $diagLines | Out-File -FilePath $DiagFile -Append -Encoding utf8 }
                catch { Write-Verbose ("DiagFile write failed at {0}: {1}" -f $DiagFile, $_.Exception.Message) }
                $FailedSubscriptions += $sub.Name
                # Mirror the sequential branch: persist failure to the
                # resume-state file so -ResumeFailedOnly works even for the
                # single-sub-collapses-to-inline corner case.
                $FailedAttempts = Add-FailedAttempt -Existing $FailedAttempts `
                    -Id $sub.Id -Name $sub.Name `
                    -Reason $errRecord.Exception.Message
                Save-CompletedSubscriptionIds -Path $ResumeStateFile -Tenant $TenantID -Ids $CompletedIds -FailedAttempts $FailedAttempts
            }
        }
        # Skip the parallel orchestration entirely; fall through to the
        # post-processing (consolidation, summary) below.
        $StreamCount = 0
    }
    if ($StreamCount -ge 2) {

    # Snapshot the parent's Az context to a shared file so each stream can
    # Import-AzContext without prompting. Save-AzContext writes a JSON file
    # containing a token cache, so it MUST NOT be left on disk after the
    # run completes - that's the responsibility of the `finally` block
    # below, which guarantees cleanup even on stream-launch crash, on
    # Receive-Job failure, or on Ctrl+C.
    $AzContextSnapshot = Join-Path $InventoryRoot (".rda-stream-azcontext-{0}.json" -f ([guid]::NewGuid().ToString()))
    try {
        Save-AzContext -Path $AzContextSnapshot -Force -ErrorAction Stop | Out-Null
    } catch {
        Write-Host ("ERROR: could not snapshot Az context for stream workers: {0}" -f $_.Exception.Message) -ForegroundColor Red
        Write-Host "Re-run without -ParallelStreams to use the sequential code path." -ForegroundColor Yellow
        # No snapshot was successfully written, so no security cleanup needed -
        # but Save-AzContext can write a partial file before throwing on some
        # error paths, so still try to remove it.
        if (Test-Path -Path $AzContextSnapshot) {
            try { Remove-Item -Path $AzContextSnapshot -Force }
            catch { Write-Verbose ("Could not remove partial Az context snapshot: {0}" -f $_.Exception.Message) }
        }
        Exit-Wrapper -Code 1
    }

    # Everything from here until the matching `finally` is the orchestration
    # body. The `finally` guarantees the Az context snapshot is always wiped
    # AND that any background jobs are cleaned up, which is the primary
    # reason for this try/finally structure.
    # Declared outside the try so the finally can always see them.
    $jobs = @()
    $StreamSummaries = @()
    try {
        $WorkerScript = Join-Path $PSScriptRoot 'Run-AllSubscriptions.Stream.ps1'
        if (-not (Test-Path -Path $WorkerScript -PathType Leaf)) {
            Write-Host ("ERROR: parallel worker script not found at {0}." -f $WorkerScript) -ForegroundColor Red
            Write-Host "Make sure Run-AllSubscriptions.Stream.ps1 is present alongside Run-AllSubscriptions.ps1, or re-run without -ParallelStreams." -ForegroundColor Yellow
            Exit-Wrapper -Code 1
        }

        # Round-robin split: sub 0 -> stream 0, sub 1 -> stream 1, ..., sub N -> stream (N % StreamCount).
        # This balances the slices regardless of how subscription sizes vary,
        # and keeps slices roughly the same length even when the total
        # subscription count is not evenly divisible by StreamCount.
        $slices = @()
        for ($i = 0; $i -lt $StreamCount; $i++) {
            $slices += ,(New-Object 'System.Collections.Generic.List[object]')
        }
        for ($i = 0; $i -lt $subscriptions.Count; $i++) {
            $slices[$i % $StreamCount].Add($subscriptions[$i])
        }

        # Build per-stream output paths up front so we know where to look later.
        for ($s = 0; $s -lt $StreamCount; $s++) {
            $sliceList     = $slices[$s]
            $sliceIds      = @($sliceList | ForEach-Object { $_.Id })
            $sliceNames    = @($sliceList | ForEach-Object { $_.Name })

            $summaryPath   = Join-Path $InventoryRoot (".rda-stream-{0}-summary.json"   -f $s)
            $failuresPath  = Join-Path $InventoryRoot ("RunAllSubscriptions_failures_{0}_stream-{1}.log" -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'), $s)

            $StreamSummaries += [pscustomobject]@{
                StreamId     = $s
                SummaryPath  = $summaryPath
                FailuresPath = $failuresPath
                SubCount     = $sliceList.Count
            }

            Write-Host ("[stream-{0}] queued: {1} subscription(s)" -f $s, $sliceList.Count) -ForegroundColor DarkCyan

            # Pass arguments to the worker via a single hashtable so the worker
            # script's named parameters bind correctly. Start-Job's -FilePath
            # mode passes ArgumentList positionally which collides with our
            # named-parameter contract. Switches are only included when they
            # are set, since switch parameters bind correctly from a splatted
            # hashtable when present with value $true.
            $workerArgs = @{
                TenantID           = $TenantID
                StreamId           = [string]$s
                InventoryRoot      = $InventoryRoot
                ScriptRoot         = $PSScriptRoot
                AzContextPath      = $AzContextSnapshot
                StreamSummaryPath  = $summaryPath
                StreamFailuresPath = $failuresPath
                SubscriptionIds    = $sliceIds
                SubscriptionNames  = $sliceNames
                ConcurrencyLimit   = $ConcurrencyLimit
            }
            if ($Resume)          { $workerArgs.Resume          = $true }
            if ($ResumeFailedOnly) { $workerArgs.ResumeFailedOnly = $true }
            if ($DeviceLogin)     { $workerArgs.DeviceLogin     = $true }
            if ($Obfuscate)       { $workerArgs.Obfuscate       = $true }
            if ($SkipMetrics)     { $workerArgs.SkipMetrics     = $true }
            if ($SkipConsumption) { $workerArgs.SkipConsumption = $true }

            $jobs += Start-Job -ScriptBlock {
                param($WorkerScript, $WorkerArgs)
                & $WorkerScript @WorkerArgs
            } -ArgumentList @($WorkerScript, $workerArgs)
        }

        # Stream output back to the user as it arrives. Receive-Job is
        # non-blocking when called against a still-running job; without this
        # loop the wrapper would appear frozen until every stream completed.
        Write-Host ""
        Write-Host "All streams launched. Streaming output (lines prefixed [stream-N]):" -ForegroundColor Green
        Write-Host ""
        Write-Host ("Note: per-stream tags only prefix the wrapper's narration. The inner script's") -ForegroundColor DarkGray
        Write-Host ("Write-Host/Write-Log output is unprefixed and will interleave across streams.") -ForegroundColor DarkGray
        Write-Host ""
        # Initial drain handles the case where every stream crashes immediately
        # (jobs reach Completed state in <1500 ms, so the loop predicate would
        # otherwise be false on first check and we'd skip output streaming).
        # Drain output once before the polling loop, in case all streams
        # finished synchronously between Start-Job and our first poll
        # (jobs reach Completed state in <1500 ms, so the loop predicate would
        # otherwise be false on first check and we'd skip output streaming).
        $jobs | Receive-Job
        # Explicit count check is safer than truthiness on the Where-Object
        # result: when zero jobs match, Where-Object returns $null which is
        # falsy, but when one matches it returns a single non-array object
        # whose truthiness varies by PowerShell edition. @(...).Count is
        # always an integer.
        while (@($jobs | Where-Object { $_.State -eq 'Running' }).Count -gt 0) {
            $jobs | Receive-Job
            Start-Sleep -Milliseconds 1500
        }
        # Drain anything still buffered after all jobs reached terminal state.
        $jobs | Receive-Job

        # Capture exit codes and any errors from the jobs themselves before removing.
        foreach ($j in $jobs) {
            if ($j.State -ne 'Completed') {
                Write-Host ("[stream-{0}] job ended in state {1}" -f $j.Id, $j.State) -ForegroundColor Yellow
            }
        }
        # Job cleanup is in the `finally` block below so it runs even if any
        # exception was raised during Receive-Job polling or aggregation.

        # Aggregate per-stream summaries into the wrapper's existing
        # accumulators so the consolidated summary at end-of-run looks the
        # same shape as a sequential run.
        foreach ($s in $StreamSummaries) {
            if (-not (Test-Path -Path $s.SummaryPath -PathType Leaf)) {
                Write-Host ("[stream-{0}] WARNING: no summary file at {1} - the stream did not finish cleanly" -f $s.StreamId, $s.SummaryPath) -ForegroundColor Yellow
                $FailedSubscriptions += ("stream-{0} (no summary)" -f $s.StreamId)
                continue
            }
            try {
                $streamSummary = Get-Content -Path $s.SummaryPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            } catch {
                Write-Host ("[stream-{0}] ERROR: could not parse summary file {1}: {2}" -f $s.StreamId, $s.SummaryPath, $_.Exception.Message) -ForegroundColor Red
                $FailedSubscriptions += ("stream-{0} (corrupt summary)" -f $s.StreamId)
                continue
            }

            # Surface stream-level failures (failed-to-start, etc.) so the
            # wrapper transcript distinguishes "the whole stream broke" from
            # "the stream ran fine but some subs in it failed". Per-sub
            # failures are still folded into $FailedSubscriptions via the
            # streamSummary.Failed enumeration below.
            if ($streamSummary.Status -and $streamSummary.Status -ne 'ok' -and $streamSummary.Status -ne 'partial-failure') {
                $reasonText = if ($streamSummary.Reason) { $streamSummary.Reason } else { '(no reason given)' }
                Write-Host ("[stream-{0}] stream status: {1} - {2}" -f $s.StreamId, $streamSummary.Status, $reasonText) -ForegroundColor Red
            }

            if ($streamSummary.ResourceCounts) {
                foreach ($rc in $streamSummary.ResourceCounts) {
                    if ($null -eq $rc) { continue }
                    $SubResourceCounts += [pscustomobject]@{
                        Name  = $rc.Name
                        Id    = $rc.Id
                        Count = [int]$rc.Count
                    }
                }
            }

            if ($streamSummary.Failed) {
                foreach ($f in $streamSummary.Failed) {
                    $FailedSubscriptions += ("{0} (stream-{1}: {2})" -f $f.Name, $s.StreamId, $f.Reason)
                }
            }

            if ($null -ne $streamSummary.ConsumptionRecords) {
                if ($null -eq $Global:ConsumptionRecordCount) { $Global:ConsumptionRecordCount = 0 }
                $Global:ConsumptionRecordCount = [int]$Global:ConsumptionRecordCount + [int]$streamSummary.ConsumptionRecords
            }
            if ($streamSummary.ConsumptionFailedSubs -and $streamSummary.ConsumptionFailedSubs.Count -gt 0) {
                if ($null -eq $Global:ConsumptionFailedSubs) { $Global:ConsumptionFailedSubs = @() }
                $Global:ConsumptionFailedSubs += @($streamSummary.ConsumptionFailedSubs)
            }

            if ($streamSummary.MetricsFailedSubs -and $streamSummary.MetricsFailedSubs.Count -gt 0) {
                if ($null -eq $Global:MetricsFailedSubs) { $Global:MetricsFailedSubs = @() }
                $Global:MetricsFailedSubs += @($streamSummary.MetricsFailedSubs)
            }

            if ($streamSummary.CollectorFailures -and $streamSummary.CollectorFailures.Count -gt 0) {
                if ($null -eq $Global:CollectorFailures) { $Global:CollectorFailures = @() }
                $Global:CollectorFailures += @($streamSummary.CollectorFailures)
            }

            # If a stream wrote a failures log, add it to the wrapper's diag-file
            # accumulator so the final summary surfaces the path. The wrapper's
            # existing $DiagFile was nullable; using a single concatenated log
            # avoids breaking that contract.
            if ((Test-Path -Path $s.FailuresPath -PathType Leaf) -and ((Get-Item $s.FailuresPath).Length -gt 0)) {
                if ($null -eq $DiagFile) {
                    $DiagFile = Join-Path $InventoryRoot ("RunAllSubscriptions_failures_{0}_{1}.log" -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss-fff'), [guid]::NewGuid().ToString().Substring(0,4))
                }
                try {
                    Get-Content -Path $s.FailuresPath -Raw | Out-File -FilePath $DiagFile -Append -Encoding utf8
                } catch {
                    Write-Verbose ("Failed to merge stream failures log {0}: {1}" -f $s.FailuresPath, $_.Exception.Message)
                }
            }
        }

        # Clean up per-stream summary JSON files (the data is now folded into
        # the wrapper's accumulators). Per-stream failures logs are NOT deleted -
        # they are referenced from the merged $DiagFile via Append above. The
        # Az context snapshot cleanup lives in the `finally` block below so it
        # runs even on failure paths.
        foreach ($s in $StreamSummaries) {
            if (Test-Path -Path $s.SummaryPath) {
                try { Remove-Item -Path $s.SummaryPath -Force } catch { Write-Verbose ("Could not remove stream summary {0}: {1}" -f $s.SummaryPath, $_.Exception.Message) }
            }
        }

        # When parallel streams have completed (clean or otherwise), merge each
        # stream's resume-state file into the unified resume-state file so a
        # subsequent -Resume run picks up correctly. The unified file is also
        # what the existing "clean run -> remove resume state" logic below
        # will look at.
        # Discover every per-stream resume file on disk for this tenant. See
        # Get-StreamResumeStateFiles for why this is a full-disk scan rather
        # than an iteration over 0..($StreamCount-1).
        $AllStreamFiles = @(Get-StreamResumeStateFiles -InventoryRoot $InventoryRoot -Tenant $TenantID)
        $allCompletedFromStreams = @()
        $allFailedFromStreams    = @()
        foreach ($StreamFile in $AllStreamFiles) {
            $perStreamFile = $StreamFile.FullName
            try {
                $obj = Get-Content -Path $perStreamFile -Raw | ConvertFrom-Json
                if ($null -ne $obj.Completed) {
                    $allCompletedFromStreams += @($obj.Completed)
                }
                # Per-stream files written by workers also carry their
                # FailedAttempts entries. Merge by Id so the unified
                # state file reflects every stream's failures, with the
                # most-recent attempt's Reason/LastFailedAt winning when
                # the same sub appears in multiple streams (which would
                # only happen across re-runs with different slicing).
                if ($null -ne $obj.FailedAttempts) {
                    $allFailedFromStreams += @($obj.FailedAttempts)
                }
            } catch {
                Write-Verbose ("Could not read stream resume file {0}: {1}" -f $perStreamFile, $_.Exception.Message)
            }
        }
        if ($allCompletedFromStreams.Count -gt 0) {
            $CompletedIds = @($CompletedIds + $allCompletedFromStreams | Sort-Object -Unique)
        }
        # Reconcile failed attempts from all streams against the unified list.
        # See Merge-FailedAttempts for the recency/completion rules.
        $FailedAttempts = Merge-FailedAttempts -ExistingFailedAttempts $FailedAttempts -StreamFailedAttempts $allFailedFromStreams -CompletedIds $CompletedIds
        if ($allCompletedFromStreams.Count -gt 0 -or $allFailedFromStreams.Count -gt 0) {
            Save-CompletedSubscriptionIds -Path $ResumeStateFile -Tenant $TenantID -Ids $CompletedIds -FailedAttempts $FailedAttempts
        }
        # Also delete per-stream resume files now that the unified file holds
        # the truth - this prevents drift if a future run uses a different
        # stream count. Reuses the same on-disk discovery ($AllStreamFiles)
        # as the merge loop above, so every file that was just merged is also
        # the one that gets cleaned up here - regardless of this run's
        # -ParallelStreams value.
        foreach ($StreamFile in $AllStreamFiles) {
            $perStreamFile = $StreamFile.FullName
            try { Remove-Item -Path $perStreamFile -Force } catch { Write-Verbose ("Could not remove stream resume file {0}: {1}" -f $perStreamFile, $_.Exception.Message) }
        }
    } finally {
        # Unconditional cleanup of background jobs and the Az context snapshot.
        # Runs whether the orchestration succeeded, threw mid-aggregation, or
        # was interrupted via Ctrl+C while a child stream was still running.

        # 1. Background jobs. If we threw before $jobs was declared, the
        # variable is null/empty and Remove-Job is a no-op. Each job is a
        # separate `pwsh` process holding an Az context snapshot reference;
        # leaving them running after the parent exits would leak both
        # processes and authentication state.
        if ($null -ne $jobs -and @($jobs).Count -gt 0) {
            try {
                # Stop any still-running jobs first so Remove-Job doesn't
                # block waiting for them.
                @($jobs | Where-Object { $_.State -eq 'Running' }) | ForEach-Object {
                    try { Stop-Job -Job $_ -ErrorAction SilentlyContinue } catch {}
                }
                $jobs | Remove-Job -Force -ErrorAction SilentlyContinue
            } catch {
                Write-Host ("WARNING: could not fully clean up background jobs: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
            }
        }

        # 2. Az context snapshot. The snapshot file contains a token cache;
        # leaving it on disk is a security exposure (bounded by the ~1h
        # token lifetime, but real). Best-effort: log if the delete fails
        # but do not propagate the error - that would mask the real exit
        # reason.
        if (Test-Path -Path $AzContextSnapshot) {
            try {
                Remove-Item -Path $AzContextSnapshot -Force -ErrorAction Stop
            } catch {
                Write-Host ("WARNING: could not remove Az context snapshot at {0}: {1}" -f $AzContextSnapshot, $_.Exception.Message) -ForegroundColor Yellow
                Write-Host "  This file contains an Azure token cache and should be deleted manually." -ForegroundColor Yellow
            }
        }
    }
    }
}

Write-Host "All subscriptions processed!" -ForegroundColor Green

# === Per-subscription output verification (hard-stop) ========================
#
# Hard-fail with exit code 2 (distinct from auth/runtime exit code 1) if the
# number of per-subscription zip files written by this invocation is lower
# than the number of subscriptions that ran to completion this invocation.
#
# Why this matters. The consolidation step below globs `*.zip` under
# $InventoryRoot. If a per-sub zip is missing for any reason - antivirus
# quarantine, Cloud Shell ephemeral-storage eviction between worker exit and
# wrapper consolidation, a worker that crashed after the inner script logged
# completion but before its zip flushed, an out-of-disk-space write that the
# inner script silently swallowed - the wrapper would silently consolidate
# the smaller set and tell the operator everything succeeded. The downstream
# consumer then discovers an incomplete archive days later.
#
# Invariant. ResourceInventory.ps1 always writes a per-sub zip on a
# successful return, even when the sub holds zero resources (it still emits
# the empty-shape report). So:
#   expected zip count = number of subs in $SubResourceCounts
# (which is appended to ONLY on the inner script's successful return path,
# both in the sequential branch and after streaming aggregation).
# Failed subs (in $FailedSubscriptions) are intentionally NOT counted -
# their zip-or-no-zip state is unreliable and the wrapper already surfaces
# them via the failure summary.
$expectedZipCount = @($SubResourceCounts).Count
if ($expectedZipCount -gt 0 -and (Test-Path -Path $InventoryRoot -PathType Container)) {
    $actualSubZips = @(Get-ChildItem -Path $InventoryRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        Get-ChildItem -Path $_.FullName -Filter "*.zip" -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -ge $RunStartTime }
    })
    $actualZipCount = $actualSubZips.Count
    if ($actualZipCount -lt $expectedZipCount) {
        $missingCount = $expectedZipCount - $actualZipCount
        Write-Host ""
        Write-Host "ERROR: Per-subscription output verification failed." -ForegroundColor Red
        Write-Host ("  Expected zips: {0} (one per subscription that ran to completion this run)" -f $expectedZipCount) -ForegroundColor Red
        Write-Host ("  Found zips:    {0} (filter: under {1}, LastWriteTime >= {2:o})" -f $actualZipCount, $InventoryRoot, $RunStartTime) -ForegroundColor Red
        Write-Host ("  Gap:           {0} missing per-subscription zip(s)." -f $missingCount) -ForegroundColor Red
        Write-Host ""
        Write-Host "Subscriptions whose inner script reported success this run:" -ForegroundColor Yellow
        foreach ($s in $SubResourceCounts) {
            Write-Host ("  - {0} ({1}) [{2:N0} resources]" -f $s.Name, $s.Id, $s.Count) -ForegroundColor Yellow
        }
        Write-Host ""
        Write-Host "Likely causes:" -ForegroundColor Yellow
        Write-Host "  - Antivirus or DLP product quarantined the per-sub zip after the inner script wrote it." -ForegroundColor Yellow
        Write-Host "  - Cloud Shell ephemeral storage was evicted between worker exit and wrapper consolidation." -ForegroundColor Yellow
        Write-Host "  - A parallel worker crashed after the inner script logged completion but before flushing the zip to disk." -ForegroundColor Yellow
        Write-Host "  - Out-of-disk-space write that the inner script swallowed silently." -ForegroundColor Yellow
        Write-Host ""
        Write-Host ("Resume State:            {0}" -f $ResumeStateFile) -ForegroundColor Yellow
        Write-Host "Recover by either:" -ForegroundColor Yellow
        Write-Host "  - Locating the missing per-sub directory under the inventory root and inspecting why its zip is absent, OR" -ForegroundColor Yellow
        Write-Host "  - Re-running with -Resume to re-collect any unprocessed/missing subscription." -ForegroundColor Yellow
        if ($WrapperTranscriptStarted) {
            Write-Host ("Wrapper Transcript:      {0}" -f $WrapperTranscriptFile) -ForegroundColor Yellow
        }
        Exit-Wrapper -Code 2
    }
    Write-Host ("Per-subscription output verification: OK ({0} zip(s) match {0} successful sub(s))" -f $actualZipCount) -ForegroundColor Green
}

# Consolidate per-subscription ZIPs into a single outer ZIP
$OuterZipFile = $null

if (Test-Path -Path $InventoryRoot -PathType Container) {
    # Filter ZIPs by current run timestamp only
    $subZips = @(Get-ChildItem -Path $InventoryRoot -Directory | ForEach-Object {
        Get-ChildItem -Path $_.FullName -Filter "*.zip" -File |
            Where-Object { $_.LastWriteTime -ge $RunStartTime }
    })

    if ($subZips.Count -gt 0) {
        $Timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
        $OuterZipFile = Join-Path $InventoryRoot "AllSubscriptions_ResourcesReport_$Timestamp.zip"

        Write-Host ("Compressing {0} per-subscription report(s) into: {1}" -f $subZips.Count, $OuterZipFile) -ForegroundColor Cyan
        Compress-Archive -Path $subZips.FullName -DestinationPath $OuterZipFile -Force

        Write-Host ("Reporting Data File: {0}" -f $OuterZipFile) -ForegroundColor Green
    } else {
        Write-Host ("No per-subscription zip files found under {0} to consolidate." -f $InventoryRoot) -ForegroundColor Yellow
    }
} else {
    Write-Host ("Inventory root not found at {0}. Nothing to consolidate." -f $InventoryRoot) -ForegroundColor Yellow
}

# Clean up resume state on a fully successful run (all subs processed, no failures
# this run AND no pending retries from a prior run). Otherwise leave it so a
# future -Resume / -ResumeFailedOnly invocation can pick up where this stopped.
if ($FailedSubscriptions.Count -eq 0 -and $FailedAttempts.Count -eq 0 -and (Test-Path -Path $ResumeStateFile -PathType Leaf)) {
    try {
        Remove-Item -Path $ResumeStateFile -Force
        Write-Host "Resume state cleared (clean run)." -ForegroundColor Green
    } catch {
        Write-Host ("WARNING: Could not remove resume state file {0}: $_" -f $ResumeStateFile) -ForegroundColor Yellow
    }
}

# Final summary
$Elapsed = (Get-Date) - $RunStartTime
Write-Host ""
Write-Host "================ Summary ================" -ForegroundColor Green
Write-Host ("Subscriptions Visible:   {0}" -f $allSubscriptions.Count) -ForegroundColor Green
if ($excluded.Count -gt 0) {
    Write-Host ("Subscriptions Excluded:  {0} (non-Enabled; use -IncludeDisabled to inventory them)" -f $excluded.Count) -ForegroundColor Green
}
Write-Host ("Subscriptions Eligible:  {0}" -f $subscriptions.Count) -ForegroundColor Green
# In parallel mode, $SkippedCount is not populated by the foreach loop above
# (each worker skips independently). Derive it from the difference between
# the number of eligible subs and the number of subs that actually ran in
# this invocation (the union of $SubResourceCounts entries plus failures).
if ($ParallelStreams -gt 1 -and $Resume -and $SkippedCount -eq 0) {
    $actuallyProcessed = ($SubResourceCounts | Measure-Object).Count + $FailedSubscriptions.Count
    $derivedSkip = $subscriptions.Count - $actuallyProcessed
    if ($derivedSkip -gt 0) { $SkippedCount = $derivedSkip }
}
if ($Resume) {
    Write-Host ("Subscriptions Skipped:   {0} (already completed)" -f $SkippedCount) -ForegroundColor Green
}
Write-Host ("Subscriptions Processed: {0}" -f ($subscriptions.Count - $SkippedCount)) -ForegroundColor Green

# Surface the per-subscription resource-count result so the user does not have
# to scan individual transcripts to find subs that came back empty. Empty subs
# are shown distinctly because they almost always indicate a permission gap;
# treating them as "successful" in the summary is misleading.
$EmptySubs = @($SubResourceCounts | Where-Object { $_.Count -eq 0 })
$NonEmptySubs = @($SubResourceCounts | Where-Object { $_.Count -gt 0 })
if ($SubResourceCounts.Count -gt 0) {
    $totalRes = ($SubResourceCounts | Measure-Object -Property Count -Sum).Sum
    Write-Host ("Total Resources:         {0:N0} across {1} subscription(s)" -f $totalRes, $NonEmptySubs.Count) -ForegroundColor Green
}
if ($EmptySubs.Count -gt 0) {
    # A sub that returned 0 resources is either a permission gap (no role on the
    # sub) or genuinely empty. Probe each one to label it precisely so the user
    # knows whether to fix access or ignore it. The probe is one cheap ARM call
    # per empty sub (only empties, so no cost on normal runs).
    $noAccessSubs = @()
    $genuinelyEmptySubs = @()
    $unknownSubs = @()
    foreach ($e in $EmptySubs) {
        switch (Get-SubscriptionAccessState -SubscriptionId $e.Id) {
            'NoAccess' { $noAccessSubs += $e }
            'Empty'    { $genuinelyEmptySubs += $e }
            default    { $unknownSubs += $e }
        }
    }

    Write-Host ""
    Write-Host ("Subscriptions with 0 resources: {0}" -f $EmptySubs.Count) -ForegroundColor Yellow

    if ($noAccessSubs.Count -gt 0) {
        Write-Host ("  NO ACCESS ({0}) - the signed-in identity has no role on these subscriptions:" -f $noAccessSubs.Count) -ForegroundColor Red
        foreach ($e in $noAccessSubs) { Write-Host ("    - {0} ({1})" -f $e.Name, $e.Id) -ForegroundColor Red }
        Write-Host "    Fix: grant the identity Reader on these subscriptions, then re-run." -ForegroundColor Red
    }
    if ($genuinelyEmptySubs.Count -gt 0) {
        Write-Host ("  GENUINELY EMPTY ({0}) - access confirmed, the subscription has no resources:" -f $genuinelyEmptySubs.Count) -ForegroundColor Yellow
        foreach ($e in $genuinelyEmptySubs) { Write-Host ("    - {0} ({1})" -f $e.Name, $e.Id) -ForegroundColor Yellow }
        Write-Host "    No action needed - these are expected to be empty in the report." -ForegroundColor DarkGray
    }
    if ($unknownSubs.Count -gt 0) {
        Write-Host ("  UNDETERMINED ({0}) - access probe was inconclusive (transient error / throttling):" -f $unknownSubs.Count) -ForegroundColor Yellow
        foreach ($e in $unknownSubs) { Write-Host ("    - {0} ({1})" -f $e.Name, $e.Id) -ForegroundColor Yellow }
        Write-Host "    Verify manually: az group list --subscription <id>" -ForegroundColor Yellow
    }
    Write-Host ""
}

# Surface consumption (billing) data health. The inner script's consumption
# loop populates these globals; if every Get-UsageAggregates call failed
# (typically because the Az PowerShell module is broken on disk and cannot
# load its bundled MSAL/Azure.Core assemblies) the customer ends up with an
# empty consumption sheet and no signal that anything went wrong. Make it
# loud here so it's caught before the report is shared.
$consumptionRecords = if ($null -ne $Global:ConsumptionRecordCount) { [int]$Global:ConsumptionRecordCount } else { 0 }
$consumptionFailures = if ($null -ne $Global:ConsumptionFailedSubs) { @($Global:ConsumptionFailedSubs) } else { @() }
if ($consumptionRecords -gt 0 -or $consumptionFailures.Count -gt 0) {
    Write-Host ("Consumption Records:     {0:N0} record(s) collected" -f $consumptionRecords) -ForegroundColor Green
}
if ($consumptionFailures.Count -gt 0) {
    Write-Host ""
    Write-Host ("Consumption Failures:    {0} subscription(s)" -f $consumptionFailures.Count) -ForegroundColor Yellow
    # The consumption failure message is repeated verbatim across every sub
    # when the cause is a broken Az module - dedupe to avoid screen wall.
    $uniqueMessages = @($consumptionFailures | Select-Object -ExpandProperty Message -Unique)
    foreach ($m in $uniqueMessages) {
        Write-Host ("  - {0}" -f $m) -ForegroundColor Yellow
    }
    if ($uniqueMessages | Where-Object { $_ -match 'context has not been properly initialized|Could not load file or assembly|MSAL|Azure\.Core' }) {
        Write-Host "  This message strongly suggests the Az PowerShell module is broken on disk." -ForegroundColor Yellow
        Write-Host "  Reinstall with:" -ForegroundColor Yellow
        Write-Host "    Get-Module Az* -ListAvailable | Uninstall-Module -Force" -ForegroundColor Yellow
        Write-Host "    Install-Module -Name Az -Repository PSGallery -Force -AllowClobber -SkipPublisherCheck" -ForegroundColor Yellow
    }
    Write-Host "  Note: the consumption sheet in the output report may be empty or incomplete for these subscriptions." -ForegroundColor Yellow
    Write-Host ""
}

# Surface metrics-phase auth health. Mirrors the consumption block above:
# metrics were requested (no -SkipMetrics) but skipped because no usable Azure
# context/token could be established even after a reconnect attempt. Without
# this the metrics sheet is silently empty and looks like "no metric-eligible
# resources" rather than an auth failure. Listed per-subscription so the
# operator knows exactly which subs are missing metrics.
$metricsFailures = if ($null -ne $Global:MetricsFailedSubs) { @($Global:MetricsFailedSubs) } else { @() }
if ($metricsFailures.Count -gt 0) {
    Write-Host ""
    Write-Host ("Metrics Auth Failures:   {0} subscription(s) - metrics SKIPPED" -f $metricsFailures.Count) -ForegroundColor Yellow
    foreach ($m in ($metricsFailures | Sort-Object Name -Unique)) {
        Write-Host ("  - {0} ({1})" -f $m.Name, $m.Id) -ForegroundColor Yellow
    }
    # The reason is the same across subs (auth), so show it once.
    $firstMsg = @($metricsFailures | Where-Object { -not [string]::IsNullOrEmpty($_.Message) } | Select-Object -First 1).Message
    if (-not [string]::IsNullOrEmpty($firstMsg)) {
        Write-Host ("  Reason: {0}" -f $firstMsg) -ForegroundColor Yellow
    }
    Write-Host "  Re-authenticate (Connect-AzAccount) or pass -appid/-secret/-tenant, then re-run." -ForegroundColor Yellow
    Write-Host "  Note: the metrics sheet in the output report will be empty for these subscriptions." -ForegroundColor Yellow
    Write-Host ""
}

# Surface collector failures (#22). A Services/*/*.ps1 collector threw for a
# specific subscription and was caught by ResourceInventory.ps1's circuit
# breaker (CreateResourceJobs); that resource type is missing from the
# affected subscription's report, not silently empty because none exist.
# Grouped by subscription so the operator can see exactly which sub(s) and
# which resource type(s) were affected without hunting through per-sub logs.
$CollectorFailuresList = if ($null -ne $Global:CollectorFailures) { @($Global:CollectorFailures) } else { @() }
if ($CollectorFailuresList.Count -gt 0) {
    Write-Host ""
    Write-Host ("Collector Failures:      {0} failure(s) across {1} subscription(s)" -f $CollectorFailuresList.Count, (@($CollectorFailuresList | Select-Object -ExpandProperty Id -Unique)).Count) -ForegroundColor Yellow
    foreach ($SubGroup in ($CollectorFailuresList | Group-Object -Property Id)) {
        Write-Host ("  - Subscription {0}:" -f $SubGroup.Name) -ForegroundColor Yellow
        foreach ($f in $SubGroup.Group) {
            Write-Host ("      {0}: {1}" -f $f.Module, $f.Message) -ForegroundColor Yellow
        }
    }
    Write-Host "  These resource types are missing (not empty) from the affected subscription's report." -ForegroundColor Yellow
    Write-Host "  Re-run to retry, or investigate the error(s) above if they repeat." -ForegroundColor Yellow
    Write-Host ""
}

if ($FailedSubscriptions.Count -gt 0) {
    Write-Host ("Subscriptions Failed:    {0} ({1})" -f $FailedSubscriptions.Count, ($FailedSubscriptions -join ', ')) -ForegroundColor Red
    Write-Host ("Resume State:            {0}" -f $ResumeStateFile) -ForegroundColor Yellow
    Write-Host "Re-run with -Resume to retry failed and any unprocessed subscriptions." -ForegroundColor Yellow
    Write-Host "Or re-run with -ResumeFailedOnly to retry ONLY the failed subscriptions." -ForegroundColor Yellow
    if ($DiagFile -and (Test-Path $DiagFile)) {
        Write-Host ("Failure Diagnostics:     {0}" -f $DiagFile) -ForegroundColor Red
    }
    if ($WrapperTranscriptStarted) {
        Write-Host ("Wrapper Transcript:      {0}" -f $WrapperTranscriptFile) -ForegroundColor Red
    }
} elseif ($FailedAttempts.Count -gt 0) {
    # No new failures this run, but the resume-state file still has lingering
    # FailedAttempts from a prior run that have not yet been retried. Surface
    # them so the operator does not lose track of historical failures simply
    # because the most recent run was clean.
    Write-Host ("Pending Retries:         {0} subscription(s) from a prior run still in FailedAttempts" -f $FailedAttempts.Count) -ForegroundColor Yellow
    Write-Host "Re-run with -ResumeFailedOnly to retry them." -ForegroundColor Yellow
}
Write-Host ("Execution Time:          {0}" -f $Elapsed.ToString('hh\:mm\:ss')) -ForegroundColor Green
if ($OuterZipFile) {
    Write-Host ("Consolidated Report:     {0}" -f $OuterZipFile) -ForegroundColor Green
}
if ($WrapperTranscriptStarted) {
    Write-Host ("Wrapper Transcript:      {0}" -f $WrapperTranscriptFile) -ForegroundColor Green
}
Write-Host "=========================================" -ForegroundColor Green

# Final, last-thing-the-user-sees banner when a requested data phase could not
# be collected due to authentication. Printed AFTER the summary block so it is
# the final output on screen. Covers metrics (no -SkipMetrics) and consumption
# (no -SkipConsumption) auth skips. The Excel sheets are intentionally NOT
# annotated (server-side ingestion expects fixed columns); this banner is the
# human-facing signal, and the non-zero exit below is the machine-facing one.
$authSkippedPhases = @()
if (@($Global:MetricsFailedSubs).Count -gt 0) { $authSkippedPhases += 'Metrics' }
$consumptionAuthSkipped = @(
    if ($null -ne $Global:ConsumptionFailedSubs) { $Global:ConsumptionFailedSubs } else { @() }
) | Where-Object { $_.Id -eq '(auth)' }
if ($consumptionAuthSkipped.Count -gt 0) { $authSkippedPhases += 'Consumption' }

if ($authSkippedPhases.Count -gt 0) {
    Write-Host ""
    Write-Host "===================== FAILED (auth) =====================" -ForegroundColor Red
    Write-Host ("Could not collect: {0}" -f ($authSkippedPhases -join ' and ')) -ForegroundColor Red
    Write-Host "Reason: no usable Azure context/token (even after one reconnect attempt)." -ForegroundColor Red
    Write-Host "These were requested (no matching -Skip switch) but returned no data." -ForegroundColor Red
    Write-Host "Fix: run Connect-AzAccount (or pass -appid/-secret/-tenant), then re-run." -ForegroundColor Red
    Write-Host "The rest of the inventory completed and the report was still produced." -ForegroundColor Yellow
    Write-Host "=========================================================" -ForegroundColor Red
}

# Machine-facing signal for collector failures (#22), distinct from the auth
# banner above. A collector failure is not an auth problem - it means one or
# more resource types are silently MISSING from one or more subscriptions'
# reports because a Services/*/*.ps1 collector threw. This must be
# machine-detectable (not just console-visible in the summary block above),
# per the same "do not sweep failures under the rug" requirement that drove
# the circuit breaker itself - a human-only signal that scrolls past in a
# large multi-subscription run is not good enough for CI/automation.
if (@($Global:CollectorFailures).Count -gt 0) {
    Write-Host ""
    Write-Host "=================== FAILED (collectors) ===================" -ForegroundColor Red
    Write-Host ("{0} collector failure(s) across {1} subscription(s) - see 'Collector Failures' above for detail." -f @($Global:CollectorFailures).Count, (@($Global:CollectorFailures | Select-Object -ExpandProperty Id -Unique)).Count) -ForegroundColor Red
    Write-Host "One or more resource types are MISSING (not empty) from the affected subscription(s)' reports." -ForegroundColor Red
    Write-Host "Re-run to retry, or investigate the error(s) above if they repeat." -ForegroundColor Red
    Write-Host "The rest of the inventory completed and the report was still produced." -ForegroundColor Yellow
    Write-Host "=========================================================" -ForegroundColor Red
}

# Stop the wrapper transcript on the normal-completion path. Error paths take
# Exit-Wrapper which does the same.
if ($WrapperTranscriptStarted) {
    try { Stop-Transcript | Out-Null }
    catch { Write-Verbose ("Stop-Transcript on normal completion failed: {0}" -f $_.Exception.Message) }
}

# Machine-facing signal. Exit code 3 == "completed, but a requested data phase
# was auth-skipped". Exit code 4 == "completed, but one or more collectors
# failed for one or more subscriptions" (#22). Exit code 5 == BOTH occurred in
# the same run. A plain if/elseif chain would let 3 mask 4 (or vice versa) when
# both problems occur together, silently hiding one from any automation that
# only checks the exit code (the console banners above always print both
# independently, but the exit code itself must not lose information either -
# same "do not sweep failures under the rug" requirement as everywhere else in
# this fix). Distinct from the existing codes (1 = hard pre-flight / auth /
# setup failure, 2 = per-subscription output verification gap, 0 = clean).
# Nothing inside this repo consumes the WRAPPER's exit code (it is the
# top-level entrypoint); the inner ResourceInventory.ps1 exit code is left
# UNCHANGED because the wrapper treats inner non-zero as "this whole
# subscription failed" (see the $LASTEXITCODE checks in the run loops).
#
# Priority logic pulled into its own function so it is independently
# unit-testable (see Tests/RunAllSubscriptionsReconciliation.Tests.ps1) without
# requiring a live wrapper run. Pure function: two booleans in, exit code out.
function Get-WrapperExitCode {
    param(
        [bool]$AuthSkipped,
        [bool]$CollectorsFailed
    )
    if ($AuthSkipped -and $CollectorsFailed) { return 5 }
    if ($AuthSkipped) { return 3 }
    if ($CollectorsFailed) { return 4 }
    return 0
}

$AuthSkipped      = $authSkippedPhases.Count -gt 0
$CollectorsFailed = @($Global:CollectorFailures).Count -gt 0
$WrapperExitCode  = Get-WrapperExitCode -AuthSkipped $AuthSkipped -CollectorsFailed $CollectorsFailed
if ($WrapperExitCode -ne 0) {
    exit $WrapperExitCode
}

