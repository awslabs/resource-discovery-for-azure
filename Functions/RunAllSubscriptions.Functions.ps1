#Requires -Version 7.0
# =============================================================================
# RunAllSubscriptions.Functions.ps1
#
# Shared helper functions for the multi-subscription wrappers. Dot-sourced by
# BOTH Run-AllSubscriptions.ps1 (parent) and Run-AllSubscriptions.Stream.ps1
# (per-stream worker), which is safe because each dot-sources this file from
# its OWN $PSScriptRoot - the stream worker runs in a fresh Start-Job process
# and cannot inherit the parent's function table, so it loads its own copy.
#
# Definitions only - no top-level code. Functions that reference caller-scope
# variables ($WrapperTranscriptStarted, $Tag, $TenantID, $StreamId) resolve
# them at CALL time from whichever script dot-sourced this file; a script only
# ever calls the functions relevant to it.
#
# The single Add-FailedAttempt / Remove-FailedAttempt pair replaces what used
# to be duplicated as Add-StreamFailedAttempt / Remove-StreamFailedAttempt in
# the worker - identical logic, now defined once.
# =============================================================================

# ---- Wrapper / shared -------------------------------------------------------
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

# Auto-tune parallelism to the current host. Detects logical CPU count and total
# physical RAM, then recommends a ParallelStreams / ConcurrencyLimit pair using
# the same guidance documented on Run-AllSubscriptions.ps1's parameters:
#   - Each stream is a separate pwsh process (~1-1.5 GB resident once Az is
#     loaded and its metrics runspaces are active), so RAM caps the stream
#     count; ~2 GB is reserved for the OS.
#   - One stream per ~2 vCPUs, so each stream still has a core for its own
#     metrics threads. On a 2-vCPU box this yields 1 (sequential), which is
#     faster there than two streams fighting over the cores.
#   - Tenant-scoped Resource Graph limits make more than ~6 streams pointless.
#   - Metric calls are network-I/O bound, so the per-stream metrics throttle can
#     oversubscribe the CPU a little: 2x vCPU, bounded to [6,16] (Azure Monitor's
#     ~12k reads/hour/subscription makes higher concurrency pointless).
# Returns a PSCustomObject { VCpu, RamGB (0 when undetectable), Streams,
# Concurrency }. The caller applies these ONLY for parameters the operator did
# not pass explicitly; the existing clamp to the eligible subscription count
# still applies on top.
function Get-RecommendedParallelism
{
    $vCpu = [int][Environment]::ProcessorCount
    if ($vCpu -lt 1) { $vCpu = 1 }

    # Total physical RAM in GB, best-effort and cross-platform. 0 = undetectable.
    $ramGB = 0.0
    try
    {
        if ($IsWindows)
        {
            $bytes = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory
            if ($bytes) { $ramGB = [math]::Round([double]$bytes / 1GB, 1) }
        }
        elseif ($IsLinux)
        {
            $memLine = Select-String -Path '/proc/meminfo' -Pattern '^MemTotal:\s+(\d+)\s+kB' -ErrorAction Stop | Select-Object -First 1
            if ($memLine) { $ramGB = [math]::Round([double]$memLine.Matches[0].Groups[1].Value / 1MB, 1) }
        }
        elseif ($IsMacOS)
        {
            $bytes = [double](& sysctl -n hw.memsize 2>$null)
            if ($bytes) { $ramGB = [math]::Round($bytes / 1GB, 1) }
        }
    }
    catch
    {
        $ramGB = 0.0
    }

    # One stream per ~2 vCPUs, capped at 6 (tenant Resource Graph ceiling).
    $streams = [int][math]::Floor($vCpu / 2)
    if ($streams -lt 1) { $streams = 1 }
    if ($streams -gt 6) { $streams = 6 }

    # RAM cap when known: reserve ~2 GB for the OS, budget ~1.5 GB per stream.
    if ($ramGB -gt 0)
    {
        $streamsByRam = [int][math]::Floor(($ramGB - 2) / 1.5)
        if ($streamsByRam -lt 1) { $streamsByRam = 1 }
        if ($streamsByRam -lt $streams) { $streams = $streamsByRam }
    }

    # Metrics throttle: I/O bound, so 2x vCPU, bounded to [6,16].
    $concurrency = $vCpu * 2
    if ($concurrency -lt 6)  { $concurrency = 6 }
    if ($concurrency -gt 16) { $concurrency = 16 }

    [pscustomobject]@{
        VCpu        = $vCpu
        RamGB       = $ramGB
        Streams     = [int]$streams
        Concurrency = [int]$concurrency
    }
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
# NOTE: Run-AllSubscriptions.ps1 dot-sources this function from the shared
# Functions folder. ResourceInventory.ps1 keeps its OWN inline variant of the
# same checks (it deliberately differs: it honors -OutputDirectory, throws
# instead of calling Exit-Wrapper, and is gated on -not $RunAllSubs). Keep the
# two behaviorally in sync - if you change a check here, mirror it there.
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
        # [object] rather than [System.Collections.IEnumerable]: when the list
        # holds exactly one prior failure, PowerShell collapses it to a single
        # PSCustomObject on assignment at the call site, and a PSCustomObject is
        # NOT IEnumerable - the stricter type threw a parameter-transformation
        # error on the second failure. The @(...) normalization below already
        # handles scalar, $null, and array uniformly.
        [object]$Existing,
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
        # [object] not [System.Collections.IEnumerable]: same single-element
        # collapse as Add-FailedAttempt - a lone prior failure arrives as a
        # scalar PSCustomObject. @(...) below normalizes scalar/$null/array.
        [object]$Existing,
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
        # [object], not [System.Collections.IEnumerable], for all three: same
        # single-element-collapse hazard as Add-/Remove-FailedAttempt. When any
        # of these lists holds exactly one item it arrives as a scalar
        # PSCustomObject/string, which is not IEnumerable and would throw a
        # parameter-transformation error. Every use below is already @()-wrapped,
        # so scalar/$null/array all normalize correctly.
        [object]$ExistingFailedAttempts,
        [object]$StreamFailedAttempts,
        [object]$CompletedIds
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

# ---- Stream worker output + per-stream state --------------------------------

function Write-Stream {
    param([string]$Message, [string]$Color = 'Gray')
    Write-Host ("{0} {1}" -f $Tag, $Message) -ForegroundColor $Color
}

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


# Classify a consumption-probe error message into an access outcome. Pure (no
# Azure calls) so the classification rules are unit-testable without a live
# session. Returns:
#   'Ok'          - no error ($null/empty message): the probe query succeeded.
#   'Denied'      - the message indicates an authorization/RBAC denial: the
#                   identity lacks Cost Management / Billing Reader. Because
#                   consumption was REQUESTED (no -SkipConsumption), the caller
#                   treats this as a HARD failure - producing a report silently
#                   missing requested billing data is worse than stopping.
#   'Unavailable' - any other failure (expired token, Conditional Access, MFA,
#                   throttling, transient network). NOT a hard failure: this is
#                   the recoverable class the per-subscription consumption phase
#                   already detects, retries once, and reports on.
function Get-ConsumptionAccessOutcome {
    param([string]$ErrorMessage)
    if ([string]::IsNullOrWhiteSpace($ErrorMessage)) { return 'Ok' }
    # Authorization / permission denial signatures across ARM + the billing APIs.
    if ($ErrorMessage -match '(?i)authoriz|forbidden|\b403\b|does not have|AuthorizationFailed|not authorized|insufficient privileg|access is denied|RBAC') {
        return 'Denied'
    }
    return 'Unavailable'
}

# Probe whether the signed-in identity can actually READ consumption/billing
# data for a subscription, by issuing the same Get-UsageAggregates call the
# consumption phase uses (a tiny 1-day window). Returns 'Ok' / 'Denied' /
# 'Unavailable' via Get-ConsumptionAccessOutcome. A subscription with access but
# zero usage returns an empty result (not an error) -> 'Ok'. A failure to switch
# context is treated as 'Unavailable' (a session/token problem, not a
# consumption-authorization denial).
function Test-ConsumptionAccess {
    param([Parameter(Mandatory=$true)][string]$SubscriptionId)

    try {
        $null = Set-AzContext -Subscription $SubscriptionId -ErrorAction Stop
    } catch {
        return 'Unavailable'
    }

    $probeEnd   = (Get-Date).Date
    $probeStart = $probeEnd.AddDays(-1)
    try {
        $null = Get-UsageAggregates -ReportedStartTime $probeStart -ReportedEndTime $probeEnd -AggregationGranularity 'Daily' -ErrorAction Stop
        return 'Ok'
    } catch {
        return (Get-ConsumptionAccessOutcome -ErrorMessage $_.Exception.Message)
    }
}
