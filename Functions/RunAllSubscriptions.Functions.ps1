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
function Exit-Wrapper
{
    param([int]$Code = 0)
    if ($WrapperTranscriptStarted)
    {
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
    $VCpu = [int][Environment]::ProcessorCount
    if ($VCpu -lt 1) { $VCpu = 1 }

    # Total physical RAM in GB, best-effort and cross-platform. 0 = undetectable.
    $RamGB = 0.0
    try
    {
        if ($IsWindows)
        {
            $Bytes = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory
            if ($Bytes) { $RamGB = [math]::Round([double]$Bytes / 1GB, 1) }
        }
        elseif ($IsLinux)
        {
            $MemLine = Select-String -Path '/proc/meminfo' -Pattern '^MemTotal:\s+(\d+)\s+kB' -ErrorAction Stop | Select-Object -First 1
            if ($MemLine) { $RamGB = [math]::Round([double]$MemLine.Matches[0].Groups[1].Value / 1MB, 1) }
        }
        elseif ($IsMacOS)
        {
            $Bytes = [double](& sysctl -n hw.memsize 2>$null)
            if ($Bytes) { $RamGB = [math]::Round($Bytes / 1GB, 1) }
        }
    }
    catch
    {
        $RamGB = 0.0
    }

    # One stream per ~2 vCPUs, capped at 6 (tenant Resource Graph ceiling).
    $Streams = [int][math]::Floor($VCpu / 2)
    if ($Streams -lt 1) { $Streams = 1 }
    if ($Streams -gt 6) { $Streams = 6 }

    # RAM cap when known: reserve ~2 GB for the OS, budget ~1.5 GB per stream.
    if ($RamGB -gt 0)
    {
        $StreamsByRam = [int][math]::Floor(($RamGB - 2) / 1.5)
        if ($StreamsByRam -lt 1) { $StreamsByRam = 1 }
        if ($StreamsByRam -lt $Streams) { $Streams = $StreamsByRam }
    }

    # Metrics throttle: I/O bound, so 2x vCPU, bounded to [6,16].
    $Concurrency = $VCpu * 2
    if ($Concurrency -lt 6) { $Concurrency = 6 }
    if ($Concurrency -gt 16) { $Concurrency = 16 }

    [pscustomobject]@{
        VCpu        = $VCpu
        RamGB       = $RamGB
        Streams     = [int]$Streams
        Concurrency = [int]$Concurrency
    }
}

# Disable the Windows console "QuickEdit Mode" for this session (best-effort).
#
# QuickEdit is on by default in conhost. If the user clicks in the window - or it
# otherwise enters mark/select mode - Windows SUSPENDS the process the instant it
# next writes to the console, until a key is pressed (Enter/Esc). During a long
# run (especially -ParallelStreams, where the wrapper continuously writes collated
# child output) this looks like a random hang that only clears when you press
# Enter. Clearing ENABLE_QUICK_EDIT_INPUT stops that.
#
# Windows-only and interactive-only: on Linux/macOS, or when input/output is
# redirected (CI, SSM run-command, piped to a file), there is no interactive
# console mode to change, so this no-ops. Best-effort: any failure is swallowed -
# tweaking the console must never break a run. The mode is not restored
# afterwards (it resets when the console window closes); selecting text to copy
# still works via the terminal's own selection, just not the legacy click-drag
# mark that caused the freeze.
function Disable-ConsoleQuickEdit
{
    if (-not $IsWindows) { return }
    if (-not [Environment]::UserInteractive) { return }
    try { if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) { return } } catch { return }

    try
    {
        if (-not ('Rda.ConsoleMode' -as [type]))
        {
            Add-Type -Namespace 'Rda' -Name 'ConsoleMode' -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError=true)]
public static extern IntPtr GetStdHandle(int nStdHandle);
[DllImport("kernel32.dll")]
public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
[DllImport("kernel32.dll")]
public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
'@ -ErrorAction Stop
        }

        $STD_INPUT_HANDLE = -10
        $ENABLE_QUICK_EDIT = [uint32]0x0040
        $ENABLE_EXTENDED_FLAGS = [uint32]0x0080

        $Handle = [Rda.ConsoleMode]::GetStdHandle($STD_INPUT_HANDLE)
        $Mode = [uint32]0
        if ([Rda.ConsoleMode]::GetConsoleMode($Handle, [ref]$Mode))
        {
            $NewMode = ($Mode -band (-bnot $ENABLE_QUICK_EDIT)) -bor $ENABLE_EXTENDED_FLAGS
            [void][Rda.ConsoleMode]::SetConsoleMode($Handle, $NewMode)
        }
    }
    catch
    {
        # Never let console-mode tweaking break a run.
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
function Get-SubscriptionAccessState
{
    param([Parameter(Mandatory = $true)][string]$SubscriptionId)

    # One cheap, access-scoped control-plane call. Capture stdout+stderr
    # together and the exit code. Listing resource groups requires a role on
    # the subscription, so a no-access identity gets AuthorizationFailed.
    $Output = (az group list --subscription $SubscriptionId --query "length(@)" -o tsv 2>&1) -join ' '
    $Exit = $LASTEXITCODE

    if ($Exit -eq 0)
    {
        # Call succeeded: identity can read the subscription, so 0 resources
        # means it is genuinely empty.
        return 'Empty'
    }
    if ($Output -match 'AuthorizationFailed|does not have authorization|not authorized|Forbidden|403')
    {
        return 'NoAccess'
    }
    # An identity that can ENUMERATE a subscription (it came from
    # Get-AzSubscription) but gets "not found / not recognized" on a
    # control-plane read into it has no usable role there - ARM hides the
    # subscription rather than returning a 403. Treat that as NoAccess too,
    # since the sub IDs we probe are always real and tenant-visible.
    if ($Output -match "not found|not recognized|could not be found|was not found")
    {
        return 'NoAccess'
    }
    # Some other failure (transient ARM error, throttling, network). Don't
    # mislabel it - report Unknown so the summary can hedge.
    return 'Unknown'
}

# Probe control-plane READ access for a set of subscriptions up front, before any
# per-subscription work. Reuses Get-SubscriptionAccessState (one cheap
# `az group list` per sub): 'Empty' == the identity CAN read the subscription
# (accessible, whether or not it has resources), 'NoAccess' == no role on it,
# 'Unknown' == an inconclusive/transient failure. A transient 'Unknown' is retried
# a few times with a short backoff before it is accepted, so a throttle/network
# blip is not mistaken for a permission gap. Returns one record per sub -
# { Id, Name, State } with State in Empty/NoAccess/Unknown. This is side-effecting
# (makes az calls); the proceed/skip DECISION is factored into the pure
# Resolve-AccessPreflight below so it can be unit-tested without a live session.
function Test-SubscriptionAccessAll
{
    param(
        [Parameter(Mandatory = $true)]$Subscriptions,
        [int]$UnknownRetries = 2,
        [int]$RetryDelaySeconds = 2
    )
    $Probed = @()
    foreach ($Sub in @($Subscriptions))
    {
        $State = Get-SubscriptionAccessState -SubscriptionId $Sub.Id
        $Attempt = 0
        while ($State -eq 'Unknown' -and $Attempt -lt $UnknownRetries)
        {
            Start-Sleep -Seconds $RetryDelaySeconds
            $State = Get-SubscriptionAccessState -SubscriptionId $Sub.Id
            $Attempt++
        }
        $Probed += [pscustomobject]@{ Id = $Sub.Id; Name = $Sub.Name; State = $State }
    }
    return $Probed
}

# Decide, from the up-front access probe results, whether the run may proceed.
# Pure (no Azure/az calls) so the gate policy is unit-testable in isolation. A
# subscription is "inaccessible" when the identity has no role ('NoAccess') or the
# probe stayed inconclusive after retries ('Unknown' - treated as blocking so a
# genuine access/throttling problem is never silently skipped). Returns:
#   Inaccessible    - the probe records the identity cannot (or may not) read
#   InaccessibleIds - the ids to drop from scope when -AllowPartialAccess is set
#   ShouldBlock     - $true when there is >=1 inaccessible sub AND
#                     -AllowPartialAccess was NOT set: the caller must STOP.
function Resolve-AccessPreflight
{
    param(
        [object]$Probed,
        [switch]$AllowPartialAccess
    )
    $Inaccessible = @(@($Probed) | Where-Object { $_ -and ($_.State -eq 'NoAccess' -or $_.State -eq 'Unknown') })
    return [pscustomobject]@{
        Inaccessible    = $Inaccessible
        InaccessibleIds = @($Inaccessible | ForEach-Object { $_.Id })
        ShouldBlock     = ($Inaccessible.Count -gt 0 -and -not $AllowPartialAccess)
    }
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
function Invoke-PreFlightChecks
{
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
    if (Get-Command Get-CloudDrive -ErrorAction SilentlyContinue)
    {
        $CheckCloudDrive = Get-CloudDrive 3>$null 2>$null
        if ($null -eq $CheckCloudDrive)
        {
            Write-Host ""
            Write-Host "WARNING: Cloud Shell detected, but no storage account is mounted." -ForegroundColor Yellow
            Write-Host "  Outputs in $InventoryRoot will be lost when this Cloud Shell session ends." -ForegroundColor Yellow
            Write-Host "  This includes the resume-state file, so -Resume on a future session won't help recover." -ForegroundColor Yellow
            Write-Host "  To persist outputs across sessions, attach a storage account via the Cloud Shell" -ForegroundColor Yellow
            Write-Host "  settings menu (gear icon) > Reset User Settings > Mount storage account." -ForegroundColor Yellow
            Write-Host "  Continuing in ephemeral mode - download the report ZIP from $InventoryRoot before closing the shell." -ForegroundColor Yellow
            Write-Host ""
        }
        else
        {
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
    try
    {
        $RootItem = Get-Item -Path $InventoryRoot -ErrorAction Stop
        $Drive = $RootItem.PSDrive
        if ($null -ne $Drive -and $null -ne $Drive.Free)
        {
            $FreeMB = [math]::Round($Drive.Free / 1MB, 0)
            if ($FreeMB -lt 100)
            {
                Write-Host ("ERROR: Free disk space at {0} is {1} MB. The script needs at least 100 MB to start. Free space and re-run." -f $InventoryRoot, $FreeMB) -ForegroundColor Red
                Exit-Wrapper -Code 1
            }
            elseif ($FreeMB -lt 500)
            {
                Write-Host ("WARNING: Free disk space at {0} is {1} MB. A large multi-subscription run can exceed this. Consider freeing space before running." -f $InventoryRoot, $FreeMB) -ForegroundColor Yellow
            }
            else
            {
                Write-Host ("Free disk space: {0:N0} MB at {1}" -f $FreeMB, $InventoryRoot) -ForegroundColor Green
            }
        }
    }
    catch
    {
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
    $ProbePath = Join-Path $InventoryRoot (".write-probe-{0}.tmp" -f ([guid]::NewGuid()))
    try
    {
        Set-Content -Path $ProbePath -Value 'preflight write probe' -Encoding utf8 -ErrorAction Stop
        $ProbeRead = Get-Content -Path $ProbePath -Raw -ErrorAction Stop
        if ($ProbeRead -notmatch 'preflight write probe')
        {
            throw "Write probe content mismatch (read back '$ProbeRead')"
        }
        Remove-Item -Path $ProbePath -Force -ErrorAction Stop
        Write-Host ("Write probe: OK ({0})" -f $InventoryRoot) -ForegroundColor Green
    }
    catch
    {
        Write-Host ("ERROR: Cannot write to {0}: {1}" -f $InventoryRoot, $_.Exception.Message) -ForegroundColor Red
        Write-Host "  This usually means: readonly directory, denied permissions, antivirus or DLP product blocking writes, or a stale handle." -ForegroundColor Red
        Write-Host "  Verify the directory is writable and re-run." -ForegroundColor Red
        # Best-effort cleanup in case Set-Content partially succeeded.
        try { if (Test-Path $ProbePath) { Remove-Item -Path $ProbePath -Force -ErrorAction SilentlyContinue } }
        catch { Write-Verbose ("Probe cleanup failed at {0}: {1}" -f $ProbePath, $_.Exception.Message) }
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
function Resolve-TenantId
{
    param([Parameter(Mandatory = $true)][string]$Value)

    $GuidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    if ($Value -match $GuidPattern) { return $Value }

    $Url = "https://login.microsoftonline.com/$Value/v2.0/.well-known/openid-configuration"
    Write-Host ("Resolving tenant '{0}' via OIDC discovery..." -f $Value) -ForegroundColor Cyan
    try
    {
        $Config = Invoke-RestMethod -Uri $Url -Method Get -ErrorAction Stop
    }
    catch
    {
        throw "Could not resolve tenant '$Value' to a GUID. Check that it is a valid Azure AD domain or pass the tenant GUID directly. Underlying error: $($_.Exception.Message)"
    }

    if ($null -eq $Config -or [string]::IsNullOrWhiteSpace($Config.issuer))
    {
        throw "OIDC discovery for tenant '$Value' returned an unexpected response (no issuer)."
    }

    # issuer looks like https://login.microsoftonline.com/<guid>/v2.0
    $Segments = $Config.issuer -split '/'
    $Resolved = $Segments | Where-Object { $_ -match $GuidPattern } | Select-Object -First 1
    if (-not $Resolved)
    {
        throw "OIDC discovery for tenant '$Value' did not contain a recognizable tenant GUID. issuer='$($Config.issuer)'"
    }

    Write-Host ("Resolved tenant '{0}' -> {1}" -f $Value, $Resolved) -ForegroundColor Green
    return $Resolved
}

function Get-CompletedSubscriptionIds
{
    param([string]$Path, [string]$Tenant)

    if (-not (Test-Path -Path $Path -PathType Leaf)) { return @() }
    try
    {
        $State = Get-Content -Path $Path -Raw | ConvertFrom-Json
        if ($State.TenantID -ne $Tenant)
        {
            Write-Host ("Resume state file is for a different tenant ({0}); ignoring." -f $State.TenantID) -ForegroundColor Yellow
            return @()
        }
        if ($null -eq $State.CompletedSubscriptionIds) { return @() }
        return @($State.CompletedSubscriptionIds)
    }
    catch
    {
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
function Get-FailedAttempts
{
    param([string]$Path, [string]$Tenant)

    if (-not (Test-Path -Path $Path -PathType Leaf)) { return @() }
    try
    {
        $State = Get-Content -Path $Path -Raw | ConvertFrom-Json
        if ($State.TenantID -ne $Tenant) { return @() }
        if ($null -eq $State.FailedAttempts) { return @() }
        return @($State.FailedAttempts)
    }
    catch
    {
        return @()
    }
}

function Save-CompletedSubscriptionIds
{
    param([string]$Path, [string]$Tenant, [string[]]$Ids, $FailedAttempts = @())

    $State = [pscustomobject]@{
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
    try
    {
        # Atomic write: serialize to a sibling temp file, then swap it into place
        # with File.Move(overwrite). A move within the same volume is a rename,
        # which is atomic - so a crash / SIGKILL / disk-full DURING the write can
        # never leave a truncated or half-written resume-state file. That matters
        # because Get-CompletedSubscriptionIds treats an unparseable file as
        # "start fresh", which would silently discard all recorded progress and
        # reprocess every subscription from scratch (potentially hours of work in
        # a large tenant / Cloud Shell run that gets killed). The temp file shares
        # the target directory so the move stays on the same volume.
        $TmpPath = "$Path.tmp"
        $State | ConvertTo-Json -Depth 4 | Set-Content -Path $TmpPath -Encoding utf8
        [System.IO.File]::Move($TmpPath, $Path, $true)
    }
    catch
    {
        Write-Host ("WARNING: Failed to persist resume state to {0}: $_" -f $Path) -ForegroundColor Yellow
        Remove-Item -LiteralPath "$Path.tmp" -Force -ErrorAction SilentlyContinue
    }
}

# Update an in-memory FailedAttempts list to record (or refresh) one sub's
# failure. Increments Attempts when the sub is already in the list. Caller
# is responsible for persisting via Save-CompletedSubscriptionIds afterwards.
function Add-FailedAttempt
{
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
    $List = @($Existing | Where-Object { $_ })
    $ExistingEntry = $List | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if ($null -ne $ExistingEntry)
    {
        $List = @($List | Where-Object { $_.Id -ne $Id })
        $Attempts = if ($ExistingEntry.Attempts) { [int]$ExistingEntry.Attempts + 1 } else { 2 }
    }
    else
    {
        $Attempts = 1
    }
    $List += [pscustomobject]@{
        Id           = $Id
        Name         = $Name
        LastFailedAt = (Get-Date).ToString('o')
        Reason       = $Reason
        Attempts     = $Attempts
    }
    return $List
}

# Remove a sub's FailedAttempts entry once it has succeeded on a retry, so
# the resume-state file does not grow into a graveyard of historical
# failures. Caller persists.
function Remove-FailedAttempt
{
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
function Get-StreamResumeStateFiles
{
    param(
        [Parameter(Mandatory = $true)][string]$InventoryRoot,
        [Parameter(Mandatory = $true)][string]$Tenant
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
function Merge-FailedAttempts
{
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
    if (@($StreamFailedAttempts).Count -eq 0)
    {
        # No new stream failures: still prune any existing entry whose sub
        # now appears in CompletedIds (a different stream succeeded for it).
        return @($ExistingFailedAttempts | Where-Object { $_ -and -not ($CompletedIds -contains $_.Id) })
    }
    $Merged = @($ExistingFailedAttempts) + @($StreamFailedAttempts)
    $ById = $Merged | Where-Object { $_ } | Group-Object -Property Id
    $Reconciled = @()
    foreach ($g in $ById)
    {
        if ($CompletedIds -contains $g.Name) { continue }
        $Best = $g.Group | Sort-Object -Property @{Expression = { [datetime]($_.LastFailedAt) } } -Descending | Select-Object -First 1
        $Reconciled += $Best
    }
    return $Reconciled
}

function Get-AzCliSignedInTenant
{
    $Raw = az account show --output json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $Raw) { return $null }
    try { return ($Raw | ConvertFrom-Json).tenantId } catch { return $null }
}

function Get-AzPsSignedInTenant
{
    try
    {
        $Ctx = Get-AzContext -ErrorAction Stop
        if ($null -eq $Ctx -or $null -eq $Ctx.Account) { return $null }
        return $Ctx.Tenant.Id
    }
    catch
    {
        return $null
    }
}

# Probe whether az CLI can silently acquire a token for $TenantID.
# Returns $true on success, $false on any failure.
function Test-AzCliTokenSilent
{
    param([Parameter(Mandatory = $true)][string]$Tenant)
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
function Test-AzPsTokenSilent
{
    param([Parameter(Mandatory = $true)][string]$Tenant)
    $Warnings = @()
    try
    {
        $Token = Get-AzAccessToken -TenantId $Tenant -ErrorAction Stop -WarningVariable warnings -WarningAction SilentlyContinue
        if ($null -eq $Token -or [string]::IsNullOrWhiteSpace($Token.Token)) { return $false }
        # Filter out known-benign warnings before deciding the call failed.
        # Az.Accounts >= 4.x emits a deprecation banner about the plain-string
        # output every time the cmdlet returns successfully; treating that as
        # failure forces users to re-authenticate every run.
        $RealWarnings = @($Warnings | Where-Object {
                $Msg = $_.Message
                -not (
                    $Msg -match 'Get-AzAccessToken\s*:?\s*Upcoming breaking changes' -or
                    $Msg -match 'AsSecureString' -or
                    $Msg -match 'plain string token output is deprecated'
                )
            })
        if ($RealWarnings.Count -gt 0) { return $false }
        return $true
    }
    catch
    {
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
function Get-WrapperExitCode
{
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

function Write-Stream
{
    param([string]$Message, [string]$Color = 'Gray')
    Write-Host ("{0} {1}" -f $Tag, $Message) -ForegroundColor $Color
}

function Read-StreamState
{
    param([string]$Path)
    if (-not (Test-Path -Path $Path -PathType Leaf)) { return @{ Completed = @(); Failed = @() } }
    try
    {
        $Obj = Get-Content -Path $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        return @{
            Completed = if ($null -eq $Obj.Completed) { @() } else { @($Obj.Completed) }
            # Backward-compatible: state files written by an older worker had
            # no FailedAttempts key, so default to @().
            Failed    = if ($null -eq $Obj.FailedAttempts) { @() } else { @($Obj.FailedAttempts) }
        }
    }
    catch
    {
        Write-Stream ("WARNING: could not read stream state at {0}: {1}" -f $Path, $_.Exception.Message) 'Yellow'
        return @{ Completed = @(); Failed = @() }
    }
}

function Write-StreamState
{
    param([string]$Path, [string[]]$Completed, $FailedAttempts = @())
    try
    {
        @{
            Tenant         = $TenantID
            StreamId       = $StreamId
            Completed      = $Completed
            FailedAttempts = @($FailedAttempts)
        } | ConvertTo-Json -Depth 4 | Set-Content -Path $Path -Encoding utf8
    }
    catch
    {
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
function Get-ConsumptionAccessOutcome
{
    param([string]$ErrorMessage)
    if ([string]::IsNullOrWhiteSpace($ErrorMessage)) { return 'Ok' }
    # Authorization / permission denial signatures across ARM + the billing APIs.
    if ($ErrorMessage -match '(?i)authoriz|forbidden|\b403\b|does not have|AuthorizationFailed|not authorized|insufficient privileg|access is denied|RBAC')
    {
        return 'Denied'
    }
    return 'Unavailable'
}

# Probe whether the signed-in identity can actually READ consumption/billing
# data for a subscription, by issuing the same Get-UsageAggregates call the
# consumption phase uses (a tiny 1-day window). A subscription with access but
# zero usage returns an empty result (not an error) -> 'Ok'. A failure to switch
# context is treated as 'Unavailable' (a session/token problem, not a
# consumption-authorization denial).
#
# Returns a [pscustomobject] with:
#   Outcome - 'Ok' / 'Denied' / 'Unavailable' (verdict via Get-ConsumptionAccessOutcome).
#   Detail  - $null on success, otherwise the underlying exception message so the
#             caller can tell the operator WHY the probe failed (e.g. the legacy
#             Get-UsageAggregates API is unsupported on this subscription type, a
#             token needs refreshing, or a 429 throttle). The verdict logic is
#             unchanged - Detail is purely for diagnosability.
function Test-ConsumptionAccess
{
    param([Parameter(Mandatory = $true)][string]$SubscriptionId)

    try
    {
        $null = Set-AzContext -Subscription $SubscriptionId -ErrorAction Stop
    }
    catch
    {
        return [pscustomobject]@{
            Outcome = 'Unavailable'
            Detail  = ('could not switch Az context to the probe subscription: {0}' -f $_.Exception.Message)
        }
    }

    # Get-UsageAggregates with Daily granularity requires the reported times to
    # be at UTC midnight (00:00:00Z). A local-midnight value ((Get-Date).Date)
    # serialises with the host's UTC offset, so for any operator NOT in UTC the
    # API rejects it with "InvalidInput: The reportedstarttime ... must have the
    # time set to midnight (0:00:00Z)" - which the probe then misclassified as a
    # transient/token 'Unavailable' on every run. Use explicit UTC midnight so
    # the probe actually tests billing access instead of tripping on a malformed
    # time. ([DateTime]::UtcNow.Date is 00:00:00 with Kind=Utc -> serialises as Z.)
    $ProbeEnd = [DateTime]::UtcNow.Date
    $ProbeStart = $ProbeEnd.AddDays(-1)
    try
    {
        $null = Get-UsageAggregates -ReportedStartTime $ProbeStart -ReportedEndTime $ProbeEnd -AggregationGranularity 'Daily' -ErrorAction Stop
        return [pscustomobject]@{ Outcome = 'Ok'; Detail = $null }
    }
    catch
    {
        return [pscustomobject]@{
            Outcome = (Get-ConsumptionAccessOutcome -ErrorMessage $_.Exception.Message)
            Detail  = $_.Exception.Message
        }
    }
}

# Build the run-level "RunSummary.log" content for the consolidated
# AllSubscriptions zip. Pure and deterministic apart from the generation
# timestamp (no file I/O, no Azure calls) so it is unit-testable offline: the
# caller writes the returned lines to RunSummary.log and adds that file to the
# outer zip.
#
# Safety posture: the wrapper does NOT hold the per-subscription obfuscation
# dictionaries (those live in the child ResourceInventory.ps1 scope - in a
# separate process for parallel runs), so it CANNOT tokenize a real identifier.
# Therefore an obfuscated run emits COUNTS ONLY - never subscription names, ids,
# or raw failure messages - so the shipped log is safe to share. A
# non-obfuscated run emits the per-subscription detail (names / ids / messages),
# consistent with the rest of that (non-obfuscated) bundle. The TenantID and
# SubscriptionID parameters are always dropped from the recorded parameter list
# regardless of mode (the operator asked for the invocation flags, not the
# targeted identifiers).
function Get-RunSummaryLogContent
{
    param(
        # PSBoundParameters (or any name -> value map) of the wrapper invocation.
        [System.Collections.IDictionary]$InvocationParameters = @{},
        [string]$Version,
        [datetime]$StartTime,
        [datetime]$EndTime,
        [int]$Visible,
        [int]$Excluded,
        [int]$Eligible,
        [int]$Processed,
        [int]$Skipped,
        # Per-subscription health collections ({ Name; Id } / { Name; Id; Message }).
        $EmptyNoAccess = @(),
        $EmptyGenuinelyEmpty = @(),
        $EmptyUndetermined = @(),
        $FailedSubscriptions = @(),
        $CollectorFailures = @(),
        $MetricsFailedSubs = @(),
        $ConsumptionFailedSubs = @(),
        [int]$ConsumptionRecordCount = 0,
        # Host size and resolved parallelism (run-environment metadata, not
        # identifiers). Emitted in both modes. Defaults mean "not supplied" and
        # the whole section is omitted (keeps standalone/offline callers clean).
        [int]$HostVCpu = 0,
        [double]$HostRamGB = 0,
        [int]$Streams = 0,
        [string]$StreamsSource,
        [int]$Concurrency = 0,
        [string]$ConcurrencySource,
        # When set, emit counts only (no names / ids / raw messages).
        [switch]$Obfuscated
    )

    # Parameters that identify the TARGET rather than describe the run - never
    # recorded, in either mode. Matched case-insensitively.
    $ExcludedParamNames = @('TenantID', 'SubscriptionID', 'InventoryRoot')

    # Valued (non-switch) parameters whose VALUE is safe to print verbatim even in
    # an obfuscated bundle (tuning knobs, never identifiers). Any other valued
    # parameter has its value omitted under -Obfuscated so a future value-carrying
    # parameter cannot leak into a shared log.
    $SafeValueParamNames = @('ParallelStreams', 'ConcurrencyLimit')

    # Normalise possibly-$null collections to real arrays so .Count is stable.
    $NoAccess = @(@($EmptyNoAccess) | Where-Object { $null -ne $_ })
    $Empty = @(@($EmptyGenuinelyEmpty) | Where-Object { $null -ne $_ })
    $Undetermined = @(@($EmptyUndetermined) | Where-Object { $null -ne $_ })
    $Failed = @(@($FailedSubscriptions) | Where-Object { $null -ne $_ })
    $Collector = @(@($CollectorFailures) | Where-Object { $null -ne $_ })
    $Metrics = @(@($MetricsFailedSubs) | Where-Object { $null -ne $_ })
    $Consumption = @(@($ConsumptionFailedSubs) | Where-Object { $null -ne $_ })

    $Lines = [System.Collections.Generic.List[string]]::new()
    $Lines.Add('Resource Discovery for Azure - run summary')
    if ($Obfuscated)
    {
        $Lines.Add('Obfuscated run: subscription names/ids and raw error text are omitted')
        $Lines.Add('(counts only) so this log is safe to share.')
    }
    else
    {
        $Lines.Add('Non-obfuscated run: contains real subscription names/ids.')
    }
    $Lines.Add(('Generated (UTC) : {0}' -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')))
    $Lines.Add(('Tool version    : {0}' -f [string]$Version))
    if ($StartTime -is [datetime] -and $StartTime -ne [datetime]::MinValue)
    {
        $Lines.Add(('Run started     : {0}' -f $StartTime.ToString('yyyy-MM-dd HH:mm:ss')))
    }
    if ($EndTime -is [datetime] -and $EndTime -ne [datetime]::MinValue)
    {
        $Lines.Add(('Run finished    : {0}' -f $EndTime.ToString('yyyy-MM-dd HH:mm:ss')))
    }
    if (($StartTime -is [datetime]) -and ($EndTime -is [datetime]) -and ($EndTime -ge $StartTime) -and ($StartTime -ne [datetime]::MinValue))
    {
        $TotalSec = [int][math]::Round((($EndTime - $StartTime).TotalSeconds))
        $DurText = if ($TotalSec -ge 3600)
        {
            '{0}h {1:D2}m {2:D2}s' -f [int][math]::Floor($TotalSec / 3600), [int][math]::Floor(($TotalSec % 3600) / 60), ($TotalSec % 60)
        }
        else
        {
            '{0}m {1:D2}s' -f [int][math]::Floor($TotalSec / 60), ($TotalSec % 60)
        }
        $Lines.Add(('Total duration  : {0}' -f $DurText))
    }

    # --- Invocation parameters (target identifiers dropped) ------------------
    $Lines.Add('')
    $Lines.Add('Parameters:')
    $ParamNames = @()
    if ($null -ne $InvocationParameters) { $ParamNames = @($InvocationParameters.Keys | Sort-Object) }
    $Emitted = 0
    foreach ($Name in $ParamNames)
    {
        if ($ExcludedParamNames -contains $Name) { continue }
        $Value = $InvocationParameters[$Name]
        # Switch / boolean parameters: list the flag only when it was enabled.
        if ($Value -is [switch])
        {
            if ($Value.IsPresent) { $Lines.Add(('  -{0}' -f $Name)); $Emitted++ }
            continue
        }
        if ($Value -is [bool])
        {
            if ($Value) { $Lines.Add(('  -{0}' -f $Name)); $Emitted++ }
            continue
        }
        # Valued parameter. Print the value verbatim only for known-safe tuning
        # knobs OR any non-obfuscated run; otherwise omit the value so an
        # obfuscated bundle never carries a raw parameter value.
        if (($SafeValueParamNames -contains $Name) -or (-not $Obfuscated))
        {
            $Lines.Add(('  -{0} {1}' -f $Name, [string]$Value))
        }
        else
        {
            $Lines.Add(('  -{0} <value omitted>' -f $Name))
        }
        $Emitted++
    }
    if ($Emitted -eq 0) { $Lines.Add('  (defaults - no switches or values passed)') }

    # --- Host / parallelism --------------------------------------------------
    # vCPU/RAM counts and the resolved streams/concurrency (auto vs explicit) are
    # run-environment metadata, not identifiers, so they are emitted in BOTH
    # modes. Each line is guarded on a supplied value; when nothing is passed
    # (standalone/offline callers) the whole section is omitted.
    $HostLines = [System.Collections.Generic.List[string]]::new()
    if ($HostVCpu -gt 0) { $HostLines.Add(('  Host vCPU         : {0}' -f $HostVCpu)) }
    if ($HostRamGB -gt 0) { $HostLines.Add(('  Host RAM (GB)     : {0}' -f $HostRamGB)) }
    if ($Streams -gt 0)
    {
        $StreamsSrcText = if (-not [string]::IsNullOrEmpty($StreamsSource)) { ' ({0})' -f $StreamsSource } else { '' }
        $HostLines.Add(('  Parallel streams  : {0}{1}' -f $Streams, $StreamsSrcText))
    }
    if ($Concurrency -gt 0)
    {
        $ConcurrencySrcText = if (-not [string]::IsNullOrEmpty($ConcurrencySource)) { ' ({0})' -f $ConcurrencySource } else { '' }
        $HostLines.Add(('  Concurrency limit : {0}{1}' -f $Concurrency, $ConcurrencySrcText))
    }
    if ($HostLines.Count -gt 0)
    {
        $Lines.Add('')
        $Lines.Add('Host / parallelism:')
        foreach ($HostLine in $HostLines) { $Lines.Add($HostLine) }
    }

    # --- Subscription tally --------------------------------------------------
    $Lines.Add('')
    $Lines.Add('Subscriptions:')
    $Lines.Add(('  Visible   : {0}' -f $Visible))
    $Lines.Add(('  Excluded  : {0} (non-Enabled)' -f $Excluded))
    $Lines.Add(('  Eligible  : {0}' -f $Eligible))
    $Lines.Add(('  Skipped   : {0} (already completed / resume)' -f $Skipped))
    $Lines.Add(('  Processed : {0}' -f $Processed))
    $Lines.Add(('  Failed    : {0}' -f $Failed.Count))
    $Lines.Add(('  0 resources - no access   : {0}' -f $NoAccess.Count))
    $Lines.Add(('  0 resources - empty       : {0}' -f $Empty.Count))
    $Lines.Add(('  0 resources - undetermined: {0}' -f $Undetermined.Count))

    # --- Health --------------------------------------------------------------
    $Lines.Add('')
    $Lines.Add('Health:')
    $Lines.Add(('  Consumption records collected : {0}' -f $ConsumptionRecordCount))
    $Lines.Add(('  Failed subscriptions          : {0}' -f $Failed.Count))
    $Lines.Add(('  Collector failures            : {0}' -f $Collector.Count))
    $Lines.Add(('  Metrics auth-skipped subs     : {0}' -f $Metrics.Count))
    $Lines.Add(('  Consumption failed subs       : {0}' -f $Consumption.Count))

    # Per-subscription detail is emitted ONLY for a non-obfuscated bundle, where
    # real names already appear throughout the report. An obfuscated bundle stops
    # at the counts above.
    if (-not $Obfuscated)
    {
        if ($Failed.Count -gt 0)
        {
            $Lines.Add('')
            $Lines.Add('Failed subscriptions (detail):')
            foreach ($FailedSub in $Failed) { $Lines.Add(('  - {0} ({1})' -f [string]$FailedSub.Name, [string]$FailedSub.Id)) }
        }
        if ($NoAccess.Count -gt 0)
        {
            $Lines.Add('')
            $Lines.Add('0-resource subscriptions with NO ACCESS (grant Reader, re-run -Resume):')
            foreach ($NoAccessSub in $NoAccess) { $Lines.Add(('  - {0} ({1})' -f [string]$NoAccessSub.Name, [string]$NoAccessSub.Id)) }
        }
        if ($Collector.Count -gt 0)
        {
            $Lines.Add('')
            $Lines.Add('Collector failures (detail):')
            foreach ($CollectorFail in $Collector) { $Lines.Add(('  - [sub {0}] {1}: {2}' -f [string]$CollectorFail.Id, [string]$CollectorFail.Module, [string]$CollectorFail.Message)) }
        }
        if ($Metrics.Count -gt 0)
        {
            $Lines.Add('')
            $Lines.Add('Metrics auth-skipped subscriptions (detail):')
            foreach ($MetricSub in $Metrics) { $Lines.Add(('  - {0} ({1}): {2}' -f [string]$MetricSub.Name, [string]$MetricSub.Id, [string]$MetricSub.Message)) }
        }
        if ($Consumption.Count -gt 0)
        {
            $Lines.Add('')
            $Lines.Add('Consumption failed subscriptions (detail):')
            foreach ($ConsumpSub in $Consumption) { $Lines.Add(('  - {0} ({1}): {2}' -f [string]$ConsumpSub.Name, [string]$ConsumpSub.Id, [string]$ConsumpSub.Message)) }
        }
    }

    return $Lines.ToArray()
}
