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
# Best-effort collection of this run's LOCAL support/diagnostic logs into a
# single zip (see New-RdaSupportLogBundle), with the operator-facing "here is
# what to send" message. Fully ISOLATED: a collection failure is swallowed to a
# verbose line so it can never disrupt the caller (an exit path, or the normal
# end-of-run). Shared by BOTH Exit-Wrapper (any failure exit, where no report
# bundle may have been produced) and the normal-completion path (a run that DID
# produce a report but had per-phase failures). The caller passes $InventoryRoot
# and the run start time (scopes collection to THIS run); a Get-Command guard
# avoids a hard dependency if the collector is somehow absent.
function Invoke-RdaSupportLogCollection
{
    param(
        [string]$InventoryRoot,
        [datetime]$SinceTime,
        # When set, ALSO upload the produced support-log bundle to this blob
        # container (passwordless, -UseConnectedAccount - the same identity/path
        # the report upload uses). This is what lets an operator who cannot easily
        # reach the node filesystem (e.g. an AKS pod) retrieve the troubleshooting
        # logs. Best-effort and isolated: an upload failure warns but never throws.
        # ShardIndex/ShardCount make the blob name unique so concurrent shards do
        # not overwrite each other's logs.
        [string]$ContainerUri,
        [int]$ShardIndex = 0,
        [int]$ShardCount = 1
    )
    if (-not (Get-Command New-RdaSupportLogBundle -ErrorAction SilentlyContinue)) { return }
    try
    {
        $CollectParams = @{}
        if (-not [string]::IsNullOrWhiteSpace($InventoryRoot)) { $CollectParams['InventoryRoot'] = $InventoryRoot }
        if ($SinceTime -ne [datetime]::MinValue) { $CollectParams['SinceTime'] = $SinceTime }
        $SupportBundle = New-RdaSupportLogBundle @CollectParams
        if ($SupportBundle)
        {
            Write-Host ("Support logs collected: {0}" -f $SupportBundle) -ForegroundColor Cyan
            Write-Host "  Send this file to support over a secure/private channel (it contains real identifiers)." -ForegroundColor Cyan

            # Optional blob upload so the logs are retrievable without node/pod
            # filesystem access. Own try/catch so an upload failure can NEVER
            # disrupt collection or the exit path - the bundle always remains on
            # local disk as the fallback. The bundle carries REAL identifiers, so
            # this must only ever target the operator's own (private) container.
            if (-not [string]::IsNullOrWhiteSpace($ContainerUri))
            {
                try
                {
                    $LogBlobUri = [System.Uri]$ContainerUri
                    $LogAccount = $LogBlobUri.Host.Split('.')[0]
                    $LogPathParts = $LogBlobUri.AbsolutePath.Trim('/').Split('/', 2)
                    $LogContainer = $LogPathParts[0]
                    $LogPrefix = if ($LogPathParts.Count -gt 1 -and $LogPathParts[1]) { $LogPathParts[1].Trim('/') + '/' } else { '' }
                    $LogShardTag = if ($ShardCount -gt 1) { 'shard-{0}of{1}-' -f $ShardIndex, $ShardCount } else { '' }
                    $LogBlobName = '{0}{1}{2}' -f $LogPrefix, $LogShardTag, (Split-Path -Path $SupportBundle -Leaf)
                    Write-Host ("Uploading support logs to blob: {0} / {1} / {2}" -f $LogAccount, $LogContainer, $LogBlobName) -ForegroundColor Cyan
                    $LogCtx = New-AzStorageContext -StorageAccountName $LogAccount -UseConnectedAccount -ErrorAction Stop
                    $null = Set-AzStorageBlobContent -File $SupportBundle -Container $LogContainer -Blob $LogBlobName -Context $LogCtx -Force -ErrorAction Stop
                    Write-Host ("Support-log upload complete: {0}" -f $LogBlobName) -ForegroundColor Green
                }
                catch
                {
                    Write-Host ("WARNING: Support-log upload to blob failed ({0}). The bundle remains on local disk at: {1}" -f $_.Exception.Message, $SupportBundle) -ForegroundColor Yellow
                }
            }
        }
    }
    catch { Write-Verbose ("Support-log collection failed: {0}" -f $_.Exception.Message) }
}

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

    # Collect this run's LOCAL support/diagnostic logs into one zip so an operator
    # whose run hard-stopped BEFORE producing a report bundle (auth / access-gate /
    # consumption denial / output-verification) still has a single artefact for
    # support. The transcript is finalized just above, so it is captured. When an
    # upload target was configured, ALSO upload that bundle to blob so an operator
    # who cannot reach the pod filesystem still gets the logs even on a hard-stop -
    # hence the guard fires on any failure exit OR whenever upload is enabled.
    # $InventoryRoot / $RunStartTime / $UploadToBlobContainerUri / $ShardIndex /
    # $ShardCount are read from the caller (parent-wrapper) scope, the same way
    # $WrapperTranscriptStarted is above; the helper is isolated so it can NEVER
    # change the exit code.
    if ($Code -ne 0 -or -not [string]::IsNullOrWhiteSpace($UploadToBlobContainerUri))
    {
        Invoke-RdaSupportLogCollection -InventoryRoot $InventoryRoot -SinceTime $RunStartTime -ContainerUri $UploadToBlobContainerUri -ShardIndex $ShardIndex -ShardCount $ShardCount
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

# Reduce a chosen metrics-collection concurrency by the requested API-headroom
# percentage, so a run deliberately leaves part of the shared Azure API throttle
# budget for other/production workloads. PURE (no Azure/host calls) - unit-tested
# in Tests/Headroom.Tests.ps1.
#
# WHY concurrency (and not stream count): the metrics phase (the run's heaviest
# ARM / Azure Monitor consumer) is throttled by this value - it is the size of
# the Get-AzMetric runspace pool. Scaling ONLY concurrency keeps the aggregate
# request-rate reduction predictable (streams x 0.8*concurrency ~= 80% of
# baseline); scaling both streams and concurrency would compound (0.8*0.8 ~= 64%)
# and over-shoot the requested headroom.
#
# HeadRoomPercent is clamped to [0,90]; the result is floored and never drops
# below 1 (a 0 would stall the runspace pool). HeadRoomPercent 0 returns the
# concurrency unchanged (the default no-op path).
function Get-HeadroomAdjustedConcurrency
{
    param(
        [Parameter(Mandatory = $true)][int]$Concurrency,
        [Parameter(Mandatory = $true)][int]$HeadRoomPercent
    )

    if ($HeadRoomPercent -lt 0) { $HeadRoomPercent = 0 }
    if ($HeadRoomPercent -gt 90) { $HeadRoomPercent = 90 }
    if ($Concurrency -lt 1) { $Concurrency = 1 }

    $Adjusted = [int][math]::Floor($Concurrency * (100 - $HeadRoomPercent) / 100.0)
    if ($Adjusted -lt 1) { $Adjusted = 1 }
    return $Adjusted
}

# Probe whether PowerShell background jobs (Start-Job) can actually be launched
# in this session. Returns $true when jobs are usable, $false otherwise.
#
# WHY: the parallel-streams path launches each stream with Start-Job (a child
# pwsh process). On a Windows host under a system-wide application-control
# policy (WDAC / AppLocker / __PSLockdownPolicy) the interactive session can be
# FullLanguage while the machine enforces ConstrainedLanguage system-wide;
# Start-Job then throws synchronously ("Cannot start job. The language mode for
# this session is incompatible with the system-wide language mode.") and NO job
# process is ever created. Left unguarded, the whole parallel run produces an
# empty report ("No per-subscription zip files found ... to consolidate").
#
# Rather than replicate PowerShell's internal language-mode comparison (brittle,
# and the trigger set can shift between releases), this probes the exact
# capability the caller needs: it launches a trivial job and confirms it starts.
# Any failure to START the job is treated as "not supported" so the caller can
# fall back to the sequential path (which never calls Start-Job). The probe job
# is always removed. On Linux/macOS and unrestricted Windows this simply returns
# $true.
function Test-BackgroundJobSupport
{
    # The language-mode lockdown this guards against is Windows-only, so on
    # Linux/macOS skip the probe entirely rather than spawn a needless child
    # pwsh (mirrors Disable-ConsoleQuickEdit's early return in this file).
    if (-not $IsWindows) { return $true }

    $Probe = $null
    try
    {
        $Probe = Start-Job -ScriptBlock { $true } -ErrorAction Stop
        return $true
    }
    catch
    {
        return $false
    }
    finally
    {
        if ($Probe)
        {
            try { Remove-Job -Job $Probe -Force -ErrorAction SilentlyContinue } catch { Write-Verbose ("Probe job cleanup failed: {0}" -f $_.Exception.Message) }
        }
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
# To tell them apart we make ONE cheap, access-scoped control-plane call via the
# native Az module (Invoke-AzRestMethod) - an authenticated ARM GET of the
# subscription's resource groups. Listing resource groups requires a role on the
# subscription (Reader is enough): HTTP 200 means the identity DOES have access
# (so 0 resources == genuinely empty), 403/401 means no role, and 404 means ARM
# is hiding a subscription the identity cannot see. Using the module cmdlet (not
# the `az` CLI) keeps this portable across Windows/Linux/macOS with no per-OS
# shell quoting - see .kiro/steering/cross-platform-powershell.md.
#
# Returns one of: 'NoAccess', 'Empty', 'Unknown'. Only called for subs that
# returned 0 resources, so it adds no cost to the normal (non-empty) path.
function Get-SubscriptionAccessState
{
    param([Parameter(Mandatory = $true)][string]$SubscriptionId)

    # One cheap, access-scoped control-plane read via the native Az module - an
    # authenticated ARM GET of the subscription's resource groups. Portable by
    # construction (no `az` CLI, no per-OS shell quoting). Invoke-AzRestMethod
    # returns a PSHttpResponse with an integer .StatusCode for HTTP responses
    # (including 4xx) and only throws for CLIENT-side failures (no usable
    # context/token, network/DNS) - verified against a live session: 200 for an
    # accessible subscription, 404 for an unknown one, neither thrown.
    try
    {
        $Response = Invoke-AzRestMethod -Method GET `
            -Path ('/subscriptions/{0}/resourcegroups?api-version=2021-04-01' -f $SubscriptionId) `
            -ErrorAction Stop
    }
    catch
    {
        # Client-side failure (no usable Azure context/token, network/DNS). This
        # is not a permission verdict - hedge as Unknown so the caller retries.
        return 'Unknown'
    }

    $Status = [int]$Response.StatusCode
    if ($Status -ge 200 -and $Status -lt 300)
    {
        # Identity can read the subscription, so 0 resources means it is
        # genuinely empty.
        return 'Empty'
    }
    if ($Status -eq 403 -or $Status -eq 401)
    {
        return 'NoAccess'
    }
    if ($Status -eq 404)
    {
        # An identity that can ENUMERATE a subscription (it came from
        # Get-AzSubscription) but gets 404 on a control-plane read into it has
        # no usable role there - ARM hides the subscription rather than
        # returning a 403. Treat that as NoAccess too, since the sub IDs we
        # probe are always real and tenant-visible.
        return 'NoAccess'
    }
    # Any other status (429 throttling, 5xx, gateway) is transient/inconclusive.
    # Don't mislabel it - report Unknown so the caller can retry and the summary
    # can hedge.
    return 'Unknown'
}

# Probe control-plane READ access for a set of subscriptions up front, before any
# per-subscription work. Reuses Get-SubscriptionAccessState (one cheap
# native ARM GET per sub): 'Empty' == the identity CAN read the subscription
# (accessible, whether or not it has resources), 'NoAccess' == no role on it,
# 'Unknown' == an inconclusive/transient failure. A transient 'Unknown' is retried
# a few times with a short backoff before it is accepted, so a throttle/network
# blip is not mistaken for a permission gap. Returns one record per sub -
# { Id, Name, State } with State in Empty/NoAccess/Unknown. This is side-effecting
# (makes Azure control-plane calls); the proceed/skip DECISION is factored into
# the pure Resolve-AccessPreflight below so it can be unit-tested without a live
# session.
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

# ---- Subscription-coverage gate ---------------------------------------------
# The access gate above proves the identity can READ the subscriptions it
# enumerated; the coverage gate proves it enumerated them ALL. Get-AzSubscription
# returns ONLY subscriptions the identity holds a role on, so an identity granted
# access per-subscription (rather than at the tenant-root management group)
# silently misses the rest. The only reliable way to know the TRUE total is to
# read it from the tenant-root management group.
#
# Recursively collect the subscription IDs (each subscription child's .Name is
# its subscription GUID) under a management-group tree returned by
# Get-AzManagementGroup -Expand -Recurse. Subscription children carry a Type like
# '/subscriptions'; nested management-group children carry a 'managementGroups'
# Type and their own .Children, so we recurse into those. Returning the actual ID
# SET (not just a count) lets the caller compare it against the ids the identity
# can enumerate - which is more robust than a raw count (immune to a transient
# count mismatch, e.g. a sub mid-deletion still listed in the MG tree) and lets it
# NAME exactly which subscriptions would be missed. Pure (no Azure calls) so it is
# unit-testable against a synthetic tree - the side-effecting fetch is factored
# into Get-TenantSubscriptionId below (mirrors the Test-SubscriptionAccessAll /
# Resolve-AccessPreflight split). Uses the established $arr = @() + '+=' idiom;
# subscription counts are small so the concatenation cost is irrelevant.
function Get-RdaMgSubscriptionId
{
    param($Node)

    $Ids = @()
    if ($null -eq $Node -or $null -eq $Node.Children) { return $Ids }
    foreach ($Child in @($Node.Children))
    {
        if ("$($Child.Type)" -like '*subscriptions*')
        {
            if (-not [string]::IsNullOrWhiteSpace($Child.Name)) { $Ids += [string]$Child.Name }
        }
        else
        {
            $Ids += Get-RdaMgSubscriptionId -Node $Child
        }
    }
    return $Ids
}

# Establish the TRUE set of subscription IDs under the tenant-root management
# group (its GroupName/GroupId equals the tenant id), independent of what the
# running identity can enumerate via Get-AzSubscription. Side-effecting (one
# control-plane call); the traversal lives in the pure Get-RdaMgSubscriptionId
# above. Returns a [pscustomobject] with:
#   Ids    - the DISTINCT subscription-id string[] under the tenant-root MG, or
#            $null when the set cannot be established (the identity lacks
#            management-group read, Get-AzManagementGroup is unavailable, or the
#            tree came back empty). $null is the caller's signal for
#            "unverifiable", handled distinctly from a real (possibly-empty-of-
#            missing) set.
#   Detail - $null on success, otherwise the reason the set is unverifiable, so
#            the caller can tell the operator WHY (mirrors Test-ConsumptionAccess).
function Get-TenantSubscriptionId
{
    param([Parameter(Mandatory = $true)][string]$TenantId)

    try
    {
        $RootMg = Get-AzManagementGroup -GroupName $TenantId -Expand -Recurse -ErrorAction Stop
        $Ids = @(Get-RdaMgSubscriptionId -Node $RootMg | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
        if ($Ids.Count -eq 0)
        {
            return [pscustomobject]@{ Ids = $null; Detail = 'The tenant-root management group returned zero subscriptions.' }
        }
        return [pscustomobject]@{ Ids = $Ids; Detail = $null }
    }
    catch
    {
        return [pscustomobject]@{ Ids = $null; Detail = $_.Exception.Message }
    }
}

# ---- Horizontal sharding ----------------------------------------------------
# Deterministically assign a subscription to one of $ShardCount shards, purely as
# a function of its OWN subscription id - independent of what other subscriptions
# are present in the caller's list. That independence is the whole point of
# sharding for horizontal scale: N machines each run the same command with a
# different -ShardIndex, each calls Get-AzSubscription for the full tenant, and
# each keeps only the subs whose shard == its own index. Because the shard is a
# pure function of the sub id, the N slices are guaranteed DISJOINT and
# collectively EXHAUSTIVE with no coordination between machines - and a sub
# created/deleted (or an access difference) on one machine only ever affects its
# OWN slice, never reshuffling the others. A positional/round-robin split would
# misalign the moment two machines saw even slightly different sub lists.
#
# Hash: SHA-256 of the lowercased id, first 4 bytes assembled BIG-ENDIAN into a
# uint32, mod ShardCount. SHA-256 is stable across processes, OSes and CPU
# architectures (unlike [string]::GetHashCode(), which is randomized per process
# in modern .NET); the explicit big-endian assembly avoids any BitConverter
# endianness dependence, so an x64 and an ARM host agree on the same shard for the
# same id. Returns an int in [0, ShardCount-1]; ShardCount <= 1 is the
# no-sharding case and always returns 0.
function Get-ShardKeyForSubscription
{
    param(
        [Parameter(Mandatory = $true)][string]$SubscriptionId,
        [Parameter(Mandatory = $true)][int]$ShardCount
    )
    if ($ShardCount -le 1) { return 0 }
    $Bytes = [System.Text.Encoding]::UTF8.GetBytes($SubscriptionId.ToLowerInvariant())
    # SHA256.Create().ComputeHash (NOT the static [SHA256]::HashData, which is a
    # .NET 5+ / PowerShell 7.1+ API) so this stays portable to a genuine
    # '#Requires -Version 7.0' (.NET Core 3.1) host. Disposed to avoid leaking the
    # provider across the per-subscription calls.
    $Sha = [System.Security.Cryptography.SHA256]::Create()
    try { $Hash = $Sha.ComputeHash($Bytes) } finally { $Sha.Dispose() }
    $Value = ([uint32]$Hash[0] -shl 24) -bor ([uint32]$Hash[1] -shl 16) -bor ([uint32]$Hash[2] -shl 8) -bor [uint32]$Hash[3]
    return [int]($Value % [uint32]$ShardCount)
}

# Filter a subscription list to only those owned by shard $ShardIndex of
# $ShardCount, via Get-ShardKeyForSubscription. $ShardCount <= 1 is the
# no-sharding case and returns the list unchanged. Pure (no Azure calls) so the
# partition is unit-testable in isolation (see Tests/Sharding.Tests.ps1).
function Select-ShardSubscriptions
{
    param(
        $Subscriptions,
        [Parameter(Mandatory = $true)][int]$ShardIndex,
        [Parameter(Mandatory = $true)][int]$ShardCount
    )
    if ($ShardCount -le 1) { return @($Subscriptions) }
    return @(@($Subscriptions) | Where-Object { (Get-ShardKeyForSubscription -SubscriptionId $_.Id -ShardCount $ShardCount) -eq $ShardIndex })
}

# Assess-only capacity planner behind the -Plan switch. PURE (no Azure/az calls)
# so it is unit-testable in isolation (see Tests/InventoryPlan.Tests.ps1). Given
# the eligible subscription COUNT, this host's recommended parallel-stream count,
# and a per-subscription time estimate, it decides whether ONE machine can finish
# within the single-machine wall-time ceiling ($MaxSingleMachineHours), or - if
# not - the fewest machines (shards) to split across so each machine's slice fits
# under that ceiling.
#
# Model: on one machine up to $Streams subscriptions run concurrently (one per
# stream), each taking ~$PerSubSeconds, so wall-time is approximately
#   ceil(SubscriptionCount / Streams) * PerSubSeconds.
# Sharding assumes each additional machine is like this host (same $Streams); the
# caller states that assumption in the printed guidance. All times are rough
# estimates the operator can treat as a starting point, not a guarantee.
#
# Returns a PSCustomObject the caller formats for display:
#   Mode ('Single'|'Sharded'), ShardCount, Streams, PerSubSeconds,
#   EstimatedSeconds (single-machine estimate), PerMachineSubscriptions,
#   EstimatedPerMachineSeconds, MaxSingleMachineHours.
function Get-InventoryPlan
{
    param(
        [Parameter(Mandatory = $true)][int]$SubscriptionCount,
        [Parameter(Mandatory = $true)][int]$Streams,
        [Parameter(Mandatory = $true)][double]$PerSubSeconds,
        [double]$MaxSingleMachineHours = 2
    )

    if ($Streams -lt 1) { $Streams = 1 }
    if ($PerSubSeconds -le 0) { $PerSubSeconds = 1 }
    # Defensive: a non-positive ceiling has no sane meaning (and would make every
    # tenant "over the ceiling"); fall back to the 2-hour default the wrapper uses.
    if ($MaxSingleMachineHours -le 0) { $MaxSingleMachineHours = 2 }
    $CeilingSeconds = $MaxSingleMachineHours * 3600

    # Single-machine wall-time: ceil(SubCount / Streams) batches * PerSubSeconds.
    $SingleBatches = if ($SubscriptionCount -le 0) { 0 } else { [math]::Ceiling($SubscriptionCount / $Streams) }
    $SingleSeconds = $SingleBatches * $PerSubSeconds

    if ($SubscriptionCount -le 0 -or $SingleSeconds -le $CeilingSeconds)
    {
        return [pscustomobject]@{
            SubscriptionCount          = $SubscriptionCount
            Mode                       = 'Single'
            ShardCount                 = 1
            Streams                    = $Streams
            PerSubSeconds              = $PerSubSeconds
            EstimatedSeconds           = [int]$SingleSeconds
            PerMachineSubscriptions    = $SubscriptionCount
            EstimatedPerMachineSeconds = [int]$SingleSeconds
            MaxSingleMachineHours      = $MaxSingleMachineHours
        }
    }

    # Over the ceiling: most subscriptions one machine can finish in time, then
    # the fewest machines needed to cover them all.
    $MaxBatchesPerMachine = [math]::Floor($CeilingSeconds / $PerSubSeconds)
    if ($MaxBatchesPerMachine -lt 1) { $MaxBatchesPerMachine = 1 }
    $MaxSubsPerMachine = [int]($Streams * $MaxBatchesPerMachine)
    if ($MaxSubsPerMachine -lt 1) { $MaxSubsPerMachine = 1 }

    $ShardCount = [int][math]::Ceiling($SubscriptionCount / $MaxSubsPerMachine)
    if ($ShardCount -lt 2) { $ShardCount = 2 }

    $PerMachineSubs = [int][math]::Ceiling($SubscriptionCount / $ShardCount)
    $PerMachineBatches = [math]::Ceiling($PerMachineSubs / $Streams)
    $PerMachineSeconds = $PerMachineBatches * $PerSubSeconds

    return [pscustomobject]@{
        SubscriptionCount          = $SubscriptionCount
        Mode                       = 'Sharded'
        ShardCount                 = $ShardCount
        Streams                    = $Streams
        PerSubSeconds              = $PerSubSeconds
        EstimatedSeconds           = [int]$SingleSeconds
        PerMachineSubscriptions    = $PerMachineSubs
        EstimatedPerMachineSeconds = [int]$PerMachineSeconds
        MaxSingleMachineHours      = $MaxSingleMachineHours
    }
}

# Render the operator/machine-facing shard directive for the -Plan output. PURE
# (no Azure, no host writes) so it is unit-testable in isolation. Given the
# recommended shard count it returns the lines the -Plan block prints:
#   1. A single MACHINE-READABLE token, 'PLAN_SHARDCOUNT=<n>', that an automating
#      wrapper can grep for a stable integer instead of scraping the human prose
#      (the prose caps the printed command list at 10, which a naive parser can
#      misread). Emitted in BOTH single (n=1) and sharded (n>1) cases.
#   2. When sharding (n>1), one unmissable directive making the FULL required
#      index range explicit - you must run every -ShardIndex 0..n-1, one per
#      machine; any index not run is silently omitted from the combined result
#      (the shards are disjoint and there is no cross-machine coordinator).
# Returns [string[]]; the caller decides how to colour/emit them.
function Get-PlanShardDirective
{
    param(
        [Parameter(Mandatory = $true)][int]$ShardCount
    )
    $Count = if ($ShardCount -lt 1) { 1 } else { $ShardCount }
    $Lines = @()
    $Lines += ('PLAN_SHARDCOUNT={0}' -f $Count)
    if ($Count -gt 1)
    {
        $Lines += ('IMPORTANT: this is {0} shards. Run ALL of them - one per machine - with -ShardIndex 0 through {1} (i.e. 0..{1}). Each -ShardIndex is a distinct ~1/{0} slice of the tenant; any index you do NOT run is SILENTLY omitted from the combined result (the shards are disjoint and do not coordinate).' -f $Count, ($Count - 1))
    }
    return $Lines
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
# downstream call (Get-AzSubscription, the resume state filename, the
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

# Return the parsed resume-state object for this tenant, BLOB-FIRST (a
# rescheduled AKS pod has no local file, so the blob mirror is the source of
# truth across pod lifetimes) with a local-file fallback, or $null if neither
# exists / is readable / matches the tenant. Centralises the blob-first-then-
# local read + tenant guard for every Get-* reader below so the logic (and its
# one tenant-mismatch message) lives in exactly one place. The blob branch is
# skipped entirely when no blob is configured, so the local path is byte-for-
# byte the historical behaviour.
function Get-ResumeStateObject
{
    param([string]$Path, [string]$Tenant, $BlobContext = $null, [string]$BlobContainer = $null, [string]$BlobName = $null)

    if ($BlobContext -and $BlobContainer -and $BlobName)
    {
        $BlobState = Read-StateBlob -Context $BlobContext -Container $BlobContainer -BlobName $BlobName
        if ($null -ne $BlobState)
        {
            if ($BlobState.TenantID -ne $Tenant)
            {
                Write-Host ("Resume state blob is for a different tenant ({0}); ignoring." -f $BlobState.TenantID) -ForegroundColor Yellow
                return $null
            }
            return $BlobState
        }
        # Blob absent/unreadable -> fall through to the local file, if any.
    }
    if (-not (Test-Path -Path $Path -PathType Leaf)) { return $null }
    try
    {
        $State = Get-Content -Path $Path -Raw | ConvertFrom-Json
        if ($State.TenantID -ne $Tenant)
        {
            Write-Host ("Resume state file is for a different tenant ({0}); ignoring." -f $State.TenantID) -ForegroundColor Yellow
            return $null
        }
        return $State
    }
    catch
    {
        Write-Host ("Could not read resume state file ({0}); starting fresh. $_" -f $Path) -ForegroundColor Yellow
        return $null
    }
}

function Get-CompletedSubscriptionIds
{
    param([string]$Path, [string]$Tenant, $BlobContext = $null, [string]$BlobContainer = $null, [string]$BlobName = $null)

    $State = Get-ResumeStateObject -Path $Path -Tenant $Tenant -BlobContext $BlobContext -BlobContainer $BlobContainer -BlobName $BlobName
    if ($null -eq $State -or $null -eq $State.CompletedSubscriptionIds) { return @() }
    return @($State.CompletedSubscriptionIds)
}

# Read the FailedAttempts list out of the same resume-state (blob-first, then
# local). Returns an array of objects shaped { Id, Name, LastFailedAt, Reason,
# Attempts }, or an empty array if the state is absent, malformed, or for a
# different tenant. Backward-compatible: state written by an older version of
# this script (which has CompletedSubscriptionIds but no FailedAttempts key)
# reads back as empty here, so existing on-disk/blob state never blocks an upgrade.
function Get-FailedAttempts
{
    param([string]$Path, [string]$Tenant, $BlobContext = $null, [string]$BlobContainer = $null, [string]$BlobName = $null)

    $State = Get-ResumeStateObject -Path $Path -Tenant $Tenant -BlobContext $BlobContext -BlobContainer $BlobContainer -BlobName $BlobName
    if ($null -eq $State -or $null -eq $State.FailedAttempts) { return @() }
    return @($State.FailedAttempts)
}

# Read the EnumeratedAtStart object ({ CapturedUtc; SubscriptionIds }) recorded
# at the start of the run, blob-first then local, or $null if none. Lets a
# resumed / rescheduled run keep the ORIGINAL start-of-run universe for the
# end-of-run reconciliation instead of re-capturing an already-moved mid-run
# snapshot. Returns $null for state written before this key existed.
function Get-StartSnapshot
{
    param([string]$Path, [string]$Tenant, $BlobContext = $null, [string]$BlobContainer = $null, [string]$BlobName = $null)

    $State = Get-ResumeStateObject -Path $Path -Tenant $Tenant -BlobContext $BlobContext -BlobContainer $BlobContainer -BlobName $BlobName
    if ($null -eq $State) { return $null }
    return $State.EnumeratedAtStart
}

function Save-CompletedSubscriptionIds
{
    param([string]$Path, [string]$Tenant, [string[]]$Ids, $FailedAttempts = @(),
        # EnumeratedAtStart object { CapturedUtc; SubscriptionIds } captured once
        # at run start and passed on EVERY write, so the start-of-run universe
        # survives a crash/resume for the end-of-run reconciliation. $null omits
        # the key entirely (identical to the historical file shape).
        $StartSnapshot = $null,
        # Optional blob mirror for AKS pod-reschedule durability. When all three
        # are supplied the freshly-written local file is also PUT to blob,
        # best-effort (the local atomic write is authoritative; a blob blip must
        # not abort the run).
        $BlobContext = $null, [string]$BlobContainer = $null, [string]$BlobName = $null)

    # [ordered] so the optional EnumeratedAtStart key appends AFTER the historical
    # keys (TenantID, CompletedSubscriptionIds, FailedAttempts, LastUpdated),
    # keeping the existing shape unchanged for readers that ignore the new key.
    $StateMap = [ordered]@{
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
    if ($null -ne $StartSnapshot) { $StateMap['EnumeratedAtStart'] = $StartSnapshot }
    $State = [pscustomobject]$StateMap
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
        # Depth 5 (was 4) so the nested EnumeratedAtStart.SubscriptionIds array
        # serialises fully.
        $TmpPath = "$Path.tmp"
        $State | ConvertTo-Json -Depth 5 | Set-Content -Path $TmpPath -Encoding utf8
        [System.IO.File]::Move($TmpPath, $Path, $true)
    }
    catch
    {
        Write-Host ("WARNING: Failed to persist resume state to {0}: $_" -f $Path) -ForegroundColor Yellow
        Remove-Item -LiteralPath "$Path.tmp" -Force -ErrorAction SilentlyContinue
        return
    }
    # Mirror to blob AFTER the authoritative local write succeeded. Best-effort:
    # Save-StateBlob warns and returns $false on a transient blob failure rather
    # than throwing, so a blob blip never loses the local progress or aborts the run.
    if ($BlobContext -and $BlobContainer -and $BlobName)
    {
        $null = Save-StateBlob -Context $BlobContext -Container $BlobContainer -BlobName $BlobName -File $Path -BestEffort
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
    param([string]$Path, [string[]]$Completed, $FailedAttempts = @(),
        # Optional per-stream blob mirror (AKS pod-reschedule durability). When
        # supplied, the freshly-written local per-stream file is also PUT to blob,
        # best-effort - so a pod that dies mid-parallel-run leaves its in-flight
        # stream progress in blob for the rescheduled shard's parent to fold in.
        $BlobContext = $null, [string]$BlobContainer = $null, [string]$BlobName = $null)
    $Tmp = "$Path.tmp"
    try
    {
        $Json = @{
            Tenant         = $TenantID
            StreamId       = $StreamId
            Completed      = $Completed
            FailedAttempts = @($FailedAttempts)
        } | ConvertTo-Json -Depth 4
        # Atomic write: serialise to a sibling temp file, then replace the target
        # in a single filesystem operation. A crash mid-write can only ever
        # damage the temp file, so a -Resume never reads a half-written (and thus
        # truncated / progress-losing) state file. [IO.File]::Move overwrite is
        # cross-platform (PowerShell 7 / .NET) and atomic on the same volume.
        Set-Content -LiteralPath $Tmp -Value $Json -Encoding utf8 -ErrorAction Stop
        [System.IO.File]::Move($Tmp, $Path, $true)
    }
    catch
    {
        Remove-Item -LiteralPath $Tmp -Force -ErrorAction SilentlyContinue
        Write-Stream ("WARNING: failed to persist stream state to {0}: {1}" -f $Path, $_.Exception.Message) 'Yellow'
        return
    }
    if ($BlobContext -and $BlobContainer -and $BlobName)
    {
        $null = Save-StateBlob -Context $BlobContext -Container $BlobContainer -BlobName $BlobName -File $Path -BestEffort
    }
}

# Normalize the -Service collector filter so it behaves identically however it
# was supplied. In-shell PowerShell splits `-Service a,b` into @('a','b'), but
# `pwsh -File Run-AllSubscriptions.ps1 -Service a,b` (how the PS 5.1 -> 7 relaunch
# and some callers invoke it) binds the whole thing as the single element 'a,b'
# - verified empirically. Splitting on comma here makes both forms yield the same
# list; also trims whitespace, drops empties, and de-duplicates. Returns @() for
# no input. Pure (no Azure/state), so it is unit-testable offline.
function Expand-ServiceFilter
{
    param([string[]]$Service)
    if (-not $Service) { return @() }
    return @(
        $Service |
            ForEach-Object { $_ -split ',' } |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ } |
            Select-Object -Unique
    )
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
        [int]$MetricsApiCallCount = 0,
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
    $Lines.Add(('  Metric-query API calls issued : {0:N0}' -f $MetricsApiCallCount))
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

# Return $true if the consolidated zip contains an entry with the given name
# (matched case-insensitively against both the entry's root-level name and its
# full path). Used to VERIFY that the run summary actually persisted into the
# shared bundle after a Compress-Archive -Update fold, so a silent fold failure
# can be surfaced instead of shipping a bundle with no run summary.
#
# Uses the cross-platform .NET System.IO.Compression API rather than shelling
# out to any archive tool, so it behaves identically on Windows, Linux and
# macOS (see the cross-platform-powershell steering rule). Any error (archive
# locked, unreadable, missing) returns $false - the caller treats $false as
# "could not confirm the entry is present" and keeps the on-disk fallback copy.
function Test-ZipArchiveEntry
{
    param(
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][string]$EntryName
    )

    if ([string]::IsNullOrWhiteSpace($ZipPath) -or -not (Test-Path -LiteralPath $ZipPath))
    {
        return $false
    }

    $Archive = $null
    try
    {
        # System.IO.Compression.FileSystem carries ZipFile::OpenRead. It is loaded
        # by default under PowerShell 7 but Add-Type is a cheap no-op guard for
        # any host where it is not, and never throws when already present.
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $Archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
        foreach ($Entry in $Archive.Entries)
        {
            if ($Entry.Name -ieq $EntryName -or $Entry.FullName -ieq $EntryName)
            {
                return $true
            }
        }
        return $false
    }
    catch
    {
        return $false
    }
    finally
    {
        if ($null -ne $Archive) { $Archive.Dispose() }
    }
}

# Collect the LOCAL support/diagnostic logs a run leaves behind into a single
# zip the operator can hand to support - especially for a FAILED run that never
# produced a consolidated report bundle (auth / access-gate / consumption hard-
# fail), where the only evidence lives in loose, timestamped files scattered
# under $InventoryRoot. Gathers the wrapper transcript + failure / access-verdict
# diagnostics logs and every per-subscription log (the scrubbed Diagnostics_*
# plus the LOCAL DebugLog_* / ErrorLog_* / Transcript_Log_*), preserves each
# per-subscription folder so the grouping is obvious, and writes a MANIFEST.txt
# describing each file.
#
# IMPORTANT - this bundle is NOT safe for a public surface. The wrapper
# transcript and the per-sub DebugLog / ErrorLog / Transcript carry real
# identifiers (signed-in UPN, tenant / subscription IDs, resource names) and raw
# exception text. It is a PRIVATE support artefact to send over a secure channel,
# never posted publicly. The obfuscation dictionary (ObfuscationDictionary_* /
# Full_*) - the de-obfuscation reveal key - is EXPLICITLY excluded so collecting
# logs can never leak the mapping.
#
# Cross-platform by construction (Get-ChildItem / Copy-Item / Compress-Archive +
# .NET path APIs; no external CLI). Best-effort: an unreadable individual file is
# skipped rather than aborting the whole collection. Returns the destination zip
# path, or $null when nothing matched (with a warning) so the caller can tell the
# operator there was nothing to collect.
function New-RdaSupportLogBundle
{
    param(
        # Root the run wrote to. Defaults to the same platform path the wrapper
        # uses so a bare New-RdaSupportLogBundle "just works" after a run.
        [string]$InventoryRoot,
        # Where to write the bundle. Defaults to a timestamped zip in InventoryRoot.
        [string]$DestinationPath,
        # When supplied, include only files last written at/after this time (scope
        # to a single run). Omit to collect everything currently present.
        [datetime]$SinceTime,
        # Also include the aggregate MainSummary_*.html for context.
        [switch]$IncludeMainSummary
    )

    if ([string]::IsNullOrWhiteSpace($InventoryRoot))
    {
        $InventoryRoot = if ($PSVersionTable.Platform -eq 'Unix') { "$HOME/InventoryReports" } else { "C:\InventoryReports" }
    }
    if (-not (Test-Path -LiteralPath $InventoryRoot -PathType Container))
    {
        Write-Warning ("Support-log collection: inventory root not found at '{0}'; nothing to collect." -f $InventoryRoot)
        return $null
    }
    if ([string]::IsNullOrWhiteSpace($DestinationPath))
    {
        $DestinationPath = Join-Path $InventoryRoot ('RdaSupportLogs_{0}.zip' -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'))
    }

    # Names that must NEVER be collected: the reveal dictionary would expose the
    # de-obfuscation mapping. Matched case-insensitively against the file name.
    $ExcludedNamePatterns = @('ObfuscationDictionary_*', 'Full_*')
    $IsExcluded = {
        param($Name)
        foreach ($Pat in $ExcludedNamePatterns) { if ($Name -like $Pat) { return $true } }
        return $false
    }
    # $SinceTime is a value-type param: when the caller omits it, it defaults to
    # [datetime]::MinValue, so that sentinel (closed over from the function scope)
    # is the reliable "was it supplied?" test inside this scriptblock.
    $PassesSince = {
        param($File)
        if ($SinceTime -ne [datetime]::MinValue)
        {
            return ($File.LastWriteTime -ge $SinceTime)
        }
        return $true
    }

    # Wrapper-level logs live directly in InventoryRoot (non-recursive).
    $WrapperPatterns = @(
        'RunAllSubscriptions_transcript_*.txt',
        'RunAllSubscriptions_failures_*.log',
        'RunAllSubscriptions_diagnostics_*.log',
        'RunSummary_*.log'
    )
    if ($IncludeMainSummary) { $WrapperPatterns += 'MainSummary_*.html' }

    # Per-subscription logs live in ResourcesReport<stamp>/ subfolders.
    $PerSubPatterns = @(
        'Diagnostics_*.log',
        'DebugLog_*.log',
        'ErrorLog_*.log',
        'Transcript_Log_*.txt'
    )

    # Build a staging tree: wrapper logs at the root, per-sub logs grouped under
    # their originating ResourcesReport<stamp>/ folder name.
    $Stage = Join-Path $InventoryRoot ('.rda-supportlogs-{0}' -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
    $Collected = 0
    try
    {
        New-Item -ItemType Directory -Path $Stage -Force | Out-Null

        foreach ($Pattern in $WrapperPatterns)
        {
            foreach ($File in @(Get-ChildItem -Path $InventoryRoot -File -Filter $Pattern -ErrorAction SilentlyContinue))
            {
                if ((& $IsExcluded $File.Name) -or -not (& $PassesSince $File)) { continue }
                try { Copy-Item -LiteralPath $File.FullName -Destination (Join-Path $Stage $File.Name) -Force; $Collected++ }
                catch { Write-Verbose ("Support-log collection: skipped '{0}': {1}" -f $File.FullName, $_.Exception.Message) }
            }
        }

        foreach ($SubDir in @(Get-ChildItem -Path $InventoryRoot -Directory -Filter 'ResourcesReport*' -ErrorAction SilentlyContinue))
        {
            $DestSubDir = Join-Path $Stage $SubDir.Name
            foreach ($Pattern in $PerSubPatterns)
            {
                foreach ($File in @(Get-ChildItem -Path $SubDir.FullName -File -Filter $Pattern -ErrorAction SilentlyContinue))
                {
                    if ((& $IsExcluded $File.Name) -or -not (& $PassesSince $File)) { continue }
                    if (-not (Test-Path -LiteralPath $DestSubDir -PathType Container)) { New-Item -ItemType Directory -Path $DestSubDir -Force | Out-Null }
                    try { Copy-Item -LiteralPath $File.FullName -Destination (Join-Path $DestSubDir $File.Name) -Force; $Collected++ }
                    catch { Write-Verbose ("Support-log collection: skipped '{0}': {1}" -f $File.FullName, $_.Exception.Message) }
                }
            }
        }

        if ($Collected -eq 0)
        {
            Write-Warning ("Support-log collection: no matching log files found under '{0}'{1}." -f $InventoryRoot, $(if ($PSBoundParameters.ContainsKey('SinceTime')) { ' for the requested time window' } else { '' }))
            return $null
        }

        # Manifest: what each file is + the mandatory do-not-post-publicly warning.
        $Manifest = [System.Collections.Generic.List[string]]::new()
        $Manifest.Add('Resource Discovery for Azure - support log bundle')
        $Manifest.Add(('Generated (UTC) : {0}' -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')))
        $Manifest.Add(('Inventory root  : {0}' -f $InventoryRoot))
        if ($PSBoundParameters.ContainsKey('SinceTime')) { $Manifest.Add(('Scoped to files at/after : {0}' -f $SinceTime.ToString('yyyy-MM-dd HH:mm:ss'))) }
        $Manifest.Add(('Files collected : {0}' -f $Collected))
        $Manifest.Add('')
        $Manifest.Add('*** PRIVATE - contains real identifiers ***')
        $Manifest.Add('This bundle includes the wrapper transcript and per-subscription debug/error')
        $Manifest.Add('logs, which carry the signed-in account (UPN), tenant/subscription IDs,')
        $Manifest.Add('resource names, and raw error text. Send it to support over a SECURE/PRIVATE')
        $Manifest.Add('channel only. Do NOT attach it to a public issue, PR, or forum post.')
        $Manifest.Add('The obfuscation dictionary (the de-obfuscation reveal key) is deliberately')
        $Manifest.Add('NOT included in this bundle.')
        $Manifest.Add('')
        $Manifest.Add('Contents:')
        $Manifest.Add('  RunAllSubscriptions_transcript_*.txt  - full wrapper console transcript (start-to-exit; present even when the run hard-failed before producing a report).')
        $Manifest.Add('  RunAllSubscriptions_failures_*.log    - wrapper failure diagnostics (per subscription / per stream).')
        $Manifest.Add('  RunAllSubscriptions_diagnostics_*.log - 0-resource access verdict (no-access / empty / undetermined).')
        $Manifest.Add('  RunSummary_*.log                      - run parameters, subscription tally, per-phase failure counts (per-sub detail only for non-obfuscated runs).')
        if ($IncludeMainSummary) { $Manifest.Add('  MainSummary_*.html                    - aggregate run summary (context).') }
        $Manifest.Add('  <ResourcesReport*>/Diagnostics_*.log  - per-subscription SHAREABLE (identifier-scrubbed) phase/health diagnostics.')
        $Manifest.Add('  <ResourcesReport*>/DebugLog_*.log     - per-subscription collector heartbeat (START/DONE/FAIL) + metrics diagnostics (LOCAL; real names).')
        $Manifest.Add('  <ResourcesReport*>/ErrorLog_*.log     - per-subscription error log (LOCAL; real names).')
        $Manifest.Add('  <ResourcesReport*>/Transcript_Log_*.txt - per-subscription PowerShell transcript (LOCAL; real names).')
        $Manifest.ToArray() | Out-File -FilePath (Join-Path $Stage 'MANIFEST.txt') -Encoding utf8

        $StageItems = @(Get-ChildItem -Path $Stage -Force -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
        Compress-Archive -Path $StageItems -DestinationPath $DestinationPath -Force
        return $DestinationPath
    }
    catch
    {
        Write-Warning ("Support-log collection failed: {0}" -f $_.Exception.Message)
        return $null
    }
    finally
    {
        if (Test-Path -LiteralPath $Stage) { Remove-Item -LiteralPath $Stage -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# =============================================================================
# Blob-backed resume state (AKS / ephemeral-pod durability)
#
# On AKS the wrapper runs in a pod whose local disk (emptyDir) is destroyed when
# the pod is evicted, rescheduled, or the node is reclaimed - exactly when
# -Resume matters. To survive that, the resume-state file is MIRRORED to Azure
# Blob storage: the local atomic write stays the fast, authoritative path within
# a pod's life, and the blob copy is the durable layer a rescheduled pod reads
# from (it has no local file). Writes are write-through (local first, then blob);
# reads are blob-first with a local fallback.
#
# Why the SDK (Az.Storage) and not a blobfuse CSI mount: the local write relies
# on [IO.File]::Move being an ATOMIC rename for crash-safety, and blobfuse does
# not honour that. A whole-object block-blob PUT (Set-AzStorageBlobContent)
# commits atomically on its own - a reader never sees a partial blob - so it is
# actually safer than a mounted rename, and it is passwordless via the pod's
# workload identity (-UseConnectedAccount), matching the existing upload path.
#
# Concurrency: the existing state model is disjoint-by-writer (each shard = its
# own pod = its own unified file; each stream = its own process = its own
# per-stream file), so no two writers target the same blob and no lease/ETag
# arbitration is needed. The ONE catch is that the local per-stream filename is
# keyed by tenant + stream index only (NOT shard) - safe on local disk because
# each shard pod has its own disk, but in a SHARED blob container two shard pods
# would collide on it. So EVERY state blob name is additionally namespaced by
# shard (see Get-StateBlobName / Get-StateBlobNames).
#
# These identifiers (subscription GUIDs) live only in the LOCAL/blob resume
# state, which is never part of the zipped report, so - like the existing
# CompletedSubscriptionIds - they do NOT route through the obfuscation layer.
# =============================================================================

# Parse a blob container URL into its parts. Pure (no Azure calls) so it is
# unit-testable offline. Accepts:
#   https://<account>.blob.core.windows.net/<container>[/<prefix...>]
# and returns { Account; Container; Prefix } where Prefix is '' or ends in '/'.
function Split-BlobContainerUri
{
    param([Parameter(Mandatory = $true)][string]$Uri)

    $Parsed = [System.Uri]$Uri
    $Account = $Parsed.Host.Split('.')[0]
    $PathParts = $Parsed.AbsolutePath.Trim('/').Split('/', 2)
    $Container = $PathParts[0]
    $Prefix = if ($PathParts.Count -gt 1 -and $PathParts[1]) { $PathParts[1].Trim('/') + '/' } else { '' }
    return [pscustomobject]@{
        Account   = $Account
        Container = $Container
        Prefix    = $Prefix
    }
}

# Build the shard-namespaced blob NAME for a state file, under the container's
# optional path prefix plus a dedicated _state/ area (kept separate from the
# report zips so the *.zip consolidation glob never trips over it). Pure.
#   - StreamId < 0  -> the shard's unified file (.resume-state-<tenant>.json)
#   - StreamId >= 0 -> a per-stream file (.resume-state-<tenant>-stream-<n>.json)
# Shard namespacing (shard-<i>of<n>/) is applied whenever ShardCount > 1 because
# the blob container is shared across shard pods (see region header).
function Get-StateBlobName
{
    param(
        # Empty string is a valid prefix (the container root, when the container
        # URL carries no path segment), so it must be allowed past the mandatory
        # non-empty default that [string] parameters enforce.
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Prefix,
        [Parameter(Mandatory = $true)][string]$Tenant,
        [int]$ShardIndex = 0,
        [int]$ShardCount = 1,
        [int]$StreamId = -1
    )
    $ShardSeg = if ($ShardCount -gt 1) { 'shard-{0}of{1}/' -f $ShardIndex, $ShardCount } else { '' }
    $Leaf = if ($StreamId -ge 0)
    {
        '.resume-state-{0}-stream-{1}.json' -f $Tenant, $StreamId
    }
    else
    {
        '.resume-state-{0}.json' -f $Tenant
    }
    return ('{0}_state/{1}{2}' -f $Prefix, $ShardSeg, $Leaf)
}

# Classify how the subscription universe moved between the START-of-run snapshot
# and an END re-enumeration, given which subs actually completed. This is the
# "moving target" reconciliation: another team can create/delete subscriptions
# mid-run, so the single start-time Get-AzSubscription is a stale picture by the
# end. Pure (no Azure calls) so it is unit-testable offline. Case-insensitive on
# ids (they are GUIDs, but normalise to be safe). Returns:
#   Vanished   - present at start, GONE at end   -> deleted mid-run; a failure
#                against one of these is expected, not a real fault.
#   New        - absent at start, present at end -> created mid-run; never
#                enumerated, so SILENTLY MISSING from the report unless handled.
#   Incomplete - existed at start AND still exists at end, but not in the
#                completed set -> genuine resume gaps. Deliberately EXCLUDES the
#                New set (a mid-run-created sub is reported under New, not double-
#                counted here), so New and Incomplete are disjoint.
function Get-SubscriptionDelta
{
    param(
        [string[]]$StartIds = @(),
        [string[]]$EndIds = @(),
        [string[]]$CompletedIds = @()
    )
    $Start = @{}
    foreach ($x in $StartIds) { if ($x) { $Start[([string]$x).ToLowerInvariant()] = $x } }
    $End = @{}
    foreach ($x in $EndIds) { if ($x) { $End[([string]$x).ToLowerInvariant()] = $x } }
    $Done = @{}
    foreach ($x in $CompletedIds) { if ($x) { $Done[([string]$x).ToLowerInvariant()] = $true } }

    $Vanished = @()
    foreach ($k in $Start.Keys) { if (-not $End.ContainsKey($k)) { $Vanished += $Start[$k] } }
    $New = @()
    foreach ($k in $End.Keys) { if (-not $Start.ContainsKey($k)) { $New += $End[$k] } }
    $Incomplete = @()
    foreach ($k in $End.Keys) { if ($Start.ContainsKey($k) -and -not $Done.ContainsKey($k)) { $Incomplete += $End[$k] } }

    return [pscustomobject]@{
        Vanished   = @($Vanished)
        New        = @($New)
        Incomplete = @($Incomplete)
    }
}

# Passwordless storage context for the current signed-in identity (the AKS
# workload identity in a pod), matching the existing blob-upload path. Kept as a
# one-line wrapper so every state-blob call constructs the context identically
# and so tests have a single seam to stub.
function New-StateBlobContext
{
    param([Parameter(Mandatory = $true)][string]$Account)
    return New-AzStorageContext -StorageAccountName $Account -UseConnectedAccount -ErrorAction Stop
}

# Whole-blob PUT of a local file. A block-blob upload commits atomically, so a
# concurrent/rescheduled reader never observes a truncated state doc - no
# temp+rename needed on the blob side. -BestEffort (used on the hot per-sub write
# path) downgrades a transient blob failure to a WARNING and returns $false
# instead of throwing, because the local atomic write already succeeded and a
# blob blip must never abort a multi-hour run. Returns $true on success.
function Save-StateBlob
{
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Container,
        [Parameter(Mandatory = $true)][string]$BlobName,
        [Parameter(Mandatory = $true)][string]$File,
        [switch]$BestEffort
    )
    try
    {
        $null = Set-AzStorageBlobContent -File $File -Container $Container -Blob $BlobName -Context $Context -Force -ErrorAction Stop
        return $true
    }
    catch
    {
        if ($BestEffort)
        {
            Write-Host ("WARNING: could not mirror resume state to blob {0}/{1}: {2}" -f $Container, $BlobName, $_.Exception.Message) -ForegroundColor Yellow
            return $false
        }
        throw
    }
}

# Download a state blob and return its parsed object, or $null if the blob is
# absent/unreadable. Used for blob-first resume reads (a rescheduled pod has no
# local state file). Never throws - an absent blob is a normal "start fresh"
# signal, identical to a missing local file.
function Read-StateBlob
{
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Container,
        [Parameter(Mandatory = $true)][string]$BlobName
    )
    $Tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('rda-state-dl-{0}.json' -f ([guid]::NewGuid().ToString('N')))
    try
    {
        $null = Get-AzStorageBlobContent -Container $Container -Blob $BlobName -Destination $Tmp -Context $Context -Force -ErrorAction Stop
        return (Get-Content -LiteralPath $Tmp -Raw | ConvertFrom-Json)
    }
    catch
    {
        return $null
    }
    finally
    {
        Remove-Item -LiteralPath $Tmp -Force -ErrorAction SilentlyContinue
    }
}

# List the per-stream state blob names under the shard's _state area, so a
# rescheduled pod (or the end-of-run merge) can fold in per-stream progress that
# was mirrored to blob. This is the blob-backend analogue of the local
# Get-StreamResumeStateFiles disk scan. Returns @() if none / on any error.
function Get-StateBlobNames
{
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Container,
        # Empty string is the valid container-root prefix (see Get-StateBlobName).
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Prefix,
        [Parameter(Mandatory = $true)][string]$Tenant,
        [int]$ShardIndex = 0,
        [int]$ShardCount = 1
    )
    $ShardSeg = if ($ShardCount -gt 1) { 'shard-{0}of{1}/' -f $ShardIndex, $ShardCount } else { '' }
    $ListPrefix = '{0}_state/{1}.resume-state-{2}-stream-' -f $Prefix, $ShardSeg, $Tenant
    try
    {
        $Blobs = Get-AzStorageBlob -Container $Container -Prefix $ListPrefix -Context $Context -ErrorAction Stop
        return @($Blobs | Select-Object -ExpandProperty Name)
    }
    catch
    {
        return @()
    }
}
