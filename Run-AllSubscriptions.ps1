#!/usr/bin/env pwsh
param (
    # -TenantID NOT Mandatory: Mandatory made PowerShell PROMPT for a missing value, which hangs any non-interactive caller silently; the -TenantID guard below fails loud with a non-zero exit instead.
    # The bare [Parameter()] MUST stay - it is the only attribute here and there is no [CmdletBinding()], so it is what makes this an ADVANCED script; dropping it turns unknown args into $args instead of an error.
    [Parameter()]
    [string]$TenantID,
    [switch]$DeviceLogin,
    [switch]$Obfuscate,
    [switch]$SkipMetrics,
    [switch]$SkipConsumption,

    # EXPERIMENTAL (default OFF), forwarded to ResourceInventory.ps1 -UseMetricsBatch for every sub: collect VM/disk/storage metrics via the Azure Monitor metrics:getBatch API (one request per <=50 resources) instead of one Get-AzMetric per (resource, metric).
    # Registers Microsoft.Insights if needed and falls back to the per-call path on any batch failure (no data lost).
    [switch]$UseMetricsBatch,

    # Metric-volume controls for very large tenants, forwarded to every sub: -IncludeStorageMetrics opts in to the 1-call-per-account UsedCapacity metric; -SkipDiskMetrics drops the 4-calls-per-attached-disk composite I/O metrics (the biggest call source).
    # -MetricsIntervalMinutes / -MetricsLookbackDays change data-point volume only, NOT the API-call COUNT (which is why -Plan cannot size from them); omit -MetricsLookbackDays to keep ResourceInventory.ps1's 31-day default as the single authority.
    [switch]$IncludeStorageMetrics,
    [switch]$SkipDiskMetrics,
    # -MetricsDetailed restores the native (finer) metric grain: VM/disk 15 min, SQL 30 min; default is hourly (upstream parity), 4x fewer VM data points.
    [switch]$MetricsDetailed,
    # OPT-IN (default OFF), forwarded to every sub as ResourceInventory.ps1 -CapacityPlan: produce the tenant-wide capacity-planning VM placement CSV. Without it no VMPlacement*.csv is produced, aggregated, or folded into the outer bundle.
    [switch]$CapacityPlan,
    [ValidateSet(0, 5, 15, 30, 60)][int]$MetricsIntervalMinutes = 0,
    # Deliberately NO default so an omitted value leaves ResourceInventory.ps1's own 31-day default as the single authority (a visible 31 here would pin a second copy and drift when the inner one changes).
    # ValidateRange is essential, not cosmetic: the inner param is untyped and run through [math]::Abs, so a negative would flip positive and a 0 would give a zero-width window that reports Success while shipping every trend metric as a measured 0.
    [ValidateRange(1, 93)][int]$MetricsLookbackDays,

    # Re-collect ONLY these inventory collectors (Services/*.ps1 BaseName) across every in-scope sub, forwarded to ResourceInventory.ps1 -Service. Scopes the INVENTORY phase only (metrics/consumption still run whole-sub), so it is for RECOVERING a failed collector - pair with -SkipMetrics -SkipConsumption.
    # Unknown names fail fast up front with the valid list.
    [string[]]$Service,

    [switch]$Resume,
    # Retry ONLY the subscriptions recorded as failed on a previous run (vs -Resume, which also continues subs not yet reached). No recorded failures -> prints "Nothing to retry" and exits 0.
    # Works with -ParallelStreams; the failed-only filter is applied before the subs are split across streams.
    [switch]$ResumeFailedOnly,
    [switch]$IncludeDisabled,

    # By DEFAULT the wrapper verifies control-plane read access to EVERY in-scope sub up front and HARD-STOPS on any gap, so a missing sub is caught before it silently drops from the report (and risks the consumption cross-attribution bug).
    # -AllowPartialAccess overrides that gate: inaccessible subs are SKIPPED (listed loudly) and the run proceeds - use only when you intentionally hold Reader on a subset of the tenant.
    [switch]$AllowPartialAccess,

    # Check permissions and stop, collecting nothing: probe EVERY in-scope sub for Cost Management Reader (consumption) and Monitoring Reader (metrics) and print a per-sub matrix with the exact role to grant - gaps that otherwise surface only mid-run.
    # Exit 0 when nothing requested is denied, 1 otherwise. Honours -SkipMetrics / -SkipConsumption (a skipped phase is not probed).
    [switch]$Preflight,

    # DEPRECATED / no-op: the aggregate MainSummary.html is now produced on EVERY run and folded into the consolidated zip. Retained only for backward compatibility with existing callers and has no effect.
    [switch]$MainSummary,

    # Also parse each per-subscription inventory to render a run-wide by-service
    # breakdown (donut + top-services bar chart) in the MainSummary. Slightly
    # slower on very large tenants (one JSON parse per subscription).
    [switch]$Detailed,

    # Forwarded to ResourceInventory.ps1 -ConcurrencyLimit: the throttle for its metrics-collection runspace pool. Raising to 12-24 typically cuts the metrics phase 30-50%; don't exceed ~24 in one tenant (tenant Resource Graph rate limits bite).
    # When OMITTED it is AUTO-TUNED from CPU/RAM (Get-RecommendedParallelism, ~2x vCPU clamped [6,16]); the 6 here is only the fallback, and an explicit value always overrides auto-tuning.
    [int]$ConcurrencyLimit = 6,

    # Number of parallel streams processing subscriptions concurrently, each a separate `pwsh` process with its own Az context and its own resume-state file (.resume-state-<TenantID>-stream-<N>.json), so they cannot race on shared Az state or the resume file.
    # When OMITTED it is AUTO-TUNED from CPU/RAM (Get-RecommendedParallelism: 1 on small boxes up to ~1 per 2 vCPUs, never above 6); explicit always overrides (pass 1 to force sequential). Tenant Resource Graph limits (~15 req/s) are the hard ceiling above ~6 streams.
    [int]$ParallelStreams = 1,

    # API headroom: leave this PERCENTAGE of the chosen metrics concurrency unused so the run consumes less of the shared Azure throttle budget (e.g. -HeadRoom 20 scales the effective -ConcurrencyLimit to 80%, floored, min 1). 0 (default) = full concurrency.
    # A proportional throttle, not a hard reservation; scaling concurrency only (not stream count) keeps the aggregate rate reduction predictable.
    [ValidateRange(0, 90)]
    [int]$HeadRoom = 0,

    # --- Horizontal scale-out (sharding): split subscriptions across N INDEPENDENT machines (same -ShardCount, distinct -ShardIndex 0..N-1). Assignment is a deterministic per-sub-id hash, so shards are disjoint and exhaustive with NO cross-machine coordination.
    # Orthogonal to -ParallelStreams (which scales within a machine). Each shard keeps its own resume-state file and produces its own consolidated zip covering only its slice; ShardCount=1 (default) is byte-identical to a non-sharded run. See docs/horizontal-sharding.md.
    [int]$ShardIndex = 0,
    [int]$ShardCount = 1,

    # After the run, upload THIS machine's consolidated zip to an Azure Blob container (URL https://<account>.blob.core.windows.net/<container>[/<prefix>]) so a multi-node/AKS operator need not SSH into each worker.
    # Uses the CURRENT signed-in identity via Azure AD (NO key/SAS), so it needs "Storage Blob Data Contributor"; shard runs prefix the blob with the shard index so disjoint shards never collide. Best-effort - a failure warns, the run still succeeds and the zip stays on local disk.
    [string]$UploadToBlobContainerUri,

    # Mirror the resume/state file to an Azure Blob container so a run survives loss of local disk - the AKS case, where a pod's emptyDir dies on eviction/reschedule (exactly when -Resume is needed); state lives under a shard-namespaced _state/ subfolder so it never collides with the report zips.
    # Same passwordless identity as the upload. Writes are write-through (local atomic first, then a best-effort blob PUT); start reads are blob-first with a local fallback. Omit to keep state local-only (byte-identical to before).
    [string]$StateBlobContainerUri,

    # Assess-only bootstrap: authenticate, enumerate eligible subs, size the run against THIS machine's CPU/RAM, then PRINT a recommendation and EXIT without inventorying - a single run (concrete parallelism flags) or, for a larger tenant, a shard count plus ready-to-paste per-node commands.
    # Per-sub time is a rough estimate (auto-picked from the -Skip* switches) - guidance, not a guarantee.
    [switch]$Plan,

    # -Plan only: override the estimated wall-time cost (seconds) of a single Azure Monitor metric query, which -Plan multiplies by each sub's projected query volume (counted live via Resource Graph). 0 (default) auto-picks: small under -UseMetricsBatch, larger throttled per-call otherwise.
    # Defaults are deliberately rough; for accuracy pass a value measured from a prior run's Diagnostics timings (metrics seconds / metric-query count).
    [double]$PlanPerQuerySeconds = 0
)

# -TenantID guard: fail loud (exit 1) instead of prompting - a prompt is invisible to a non-interactive caller (CI, scheduled task, AKS, redirected output) and would hang the run silently with no exit code.
# Placed BEFORE the PS7 bootstrap (no point relaunching/installing PS7 for a run that cannot succeed) and kept in the 5.1+7 common syntax subset (no ternary, ??/??=, &&/||, -Parallel) so Windows PowerShell 5.1 reaches it instead of failing at parse time.
if ([string]::IsNullOrWhiteSpace($TenantID))
{
    Write-Host "ERROR: -TenantID is required." -ForegroundColor Red
    Write-Host "Supply the tenant to inventory, either its GUID or its domain name:" -ForegroundColor Yellow
    Write-Host "    ./Run-AllSubscriptions.ps1 -TenantID contoso.onmicrosoft.com" -ForegroundColor Yellow
    Write-Host "To read it from an existing signed-in session: (Get-AzContext).Tenant.Id" -ForegroundColor Yellow
    exit 1
}

# PowerShell 7 bootstrap: MUST run before the dot-sources below - the helpers declare #requires -Version 7.0, which Windows PowerShell 5.1 cannot load. Re-launches the run under PS7, installing it first with consent if missing; a no-op on PS7+.
# KEEP FREE OF PS7-ONLY SYNTAX (no ternary ? :, no ??/??=, no &&/||, no ForEach-Object -Parallel) - any of those makes 5.1 fail to parse the whole script and this bootstrap never runs.
if ($PSVersionTable.PSVersion.Major -lt 7)
{
    Write-Host ("Detected Windows PowerShell {0}. This tool requires PowerShell 7." -f $PSVersionTable.PSVersion) -ForegroundColor Yellow

    $PwshPath = $null
    $PwshCommand = Get-Command pwsh -ErrorAction SilentlyContinue
    # Require major >= 7: a lingering PowerShell 6 'pwsh' on PATH would also fail
    # the version guard above and could re-exec into itself in a loop.
    if ($PwshCommand -and $PwshCommand.Version -and $PwshCommand.Version.Major -ge 7)
    {
        $PwshPath = $PwshCommand.Source
    }
    else
    {
        $PwshCandidates = @()
        if ($env:ProgramFiles)
        {
            $PwshCandidates += (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe')
        }
        $ProgramFilesX86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
        if ($ProgramFilesX86)
        {
            $PwshCandidates += (Join-Path $ProgramFilesX86 'PowerShell\7\pwsh.exe')
        }
        foreach ($PwshCandidate in $PwshCandidates)
        {
            if (Test-Path -LiteralPath $PwshCandidate)
            {
                $PwshPath = $PwshCandidate
                break
            }
        }
    }

    if (-not $PwshPath)
    {
        $ManualInstallHint = '  Invoke-Expression "& { $(Invoke-RestMethod https://aka.ms/install-powershell.ps1) } -UseMSI"'
        $IsInteractive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected

        if (-not $IsInteractive)
        {
            Write-Host "PowerShell 7 (pwsh) was not found, and this is a non-interactive session, so I will not prompt to install it." -ForegroundColor Red
            Write-Host "Install PowerShell 7 and re-run. For example:" -ForegroundColor Yellow
            Write-Host $ManualInstallHint -ForegroundColor Yellow
            exit 1
        }

        Write-Host ""
        $InstallAnswer = Read-Host "PowerShell 7 is not installed. Install it now? [y/N]"
        if ($InstallAnswer -notmatch '^(y|yes)$')
        {
            Write-Host "Not installing. Install PowerShell 7 manually and re-run:" -ForegroundColor Yellow
            Write-Host $ManualInstallHint -ForegroundColor Yellow
            exit 1
        }

        Write-Host "Installing PowerShell 7 via the official Microsoft installer (this may prompt for elevation)..." -ForegroundColor Cyan
        try
        {
            $InstallScript = Invoke-RestMethod -Uri 'https://aka.ms/install-powershell.ps1'
            $InstallBlock = [ScriptBlock]::Create($InstallScript)
            & $InstallBlock -UseMSI -Quiet
        }
        catch
        {
            Write-Host ("Automatic install failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
            Write-Host "Install PowerShell 7 manually from https://aka.ms/powershell-release then re-run." -ForegroundColor Yellow
            exit 1
        }

        $PwshCommand = Get-Command pwsh -ErrorAction SilentlyContinue
        if ($PwshCommand -and $PwshCommand.Version -and $PwshCommand.Version.Major -ge 7)
        {
            $PwshPath = $PwshCommand.Source
        }
        elseif ($env:ProgramFiles -and (Test-Path -LiteralPath (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe')))
        {
            $PwshPath = (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe')
        }

        if (-not $PwshPath)
        {
            Write-Host "PowerShell 7 was installed but is not visible in this session yet." -ForegroundColor Yellow
            Write-Host "Close this window, open a new PowerShell 7 (pwsh) prompt, then re-run the same command." -ForegroundColor Yellow
            exit 1
        }
    }

    # Rebuild the original invocation as CLI tokens so `pwsh -File` binds them to
    # this script's param() exactly as supplied: switches become a bare -Name,
    # valued params become -Name Value.
    $ForwardArgs = @()
    foreach ($BoundParam in $PSBoundParameters.GetEnumerator())
    {
        $BoundValue = $BoundParam.Value
        if ($BoundValue -is [System.Management.Automation.SwitchParameter])
        {
            if ($BoundValue.IsPresent)
            {
                $ForwardArgs += ('-' + $BoundParam.Key)
            }
        }
        else
        {
            $ForwardArgs += ('-' + $BoundParam.Key)
            # Array-valued params (e.g. -Service) must survive the `pwsh -File`
            # round-trip. `-File` does NOT split a space- or comma-separated token
            # back into array elements, so join with commas into ONE token; the
            # relaunched instance normalizes it via Expand-ServiceFilter.
            if ($BoundValue -is [System.Array])
            {
                $ForwardArgs += (($BoundValue | ForEach-Object { [string]$_ }) -join ',')
            }
            else
            {
                $ForwardArgs += [string]$BoundValue
            }
        }
    }

    Write-Host ("Re-launching under PowerShell 7: {0}" -f $PwshPath) -ForegroundColor Cyan
    & $PwshPath -NoLogo -NoProfile -File $PSCommandPath @ForwardArgs
    exit $LASTEXITCODE
}

# Az PowerShell module bootstrap: detect the Az module the wrapper and inner script need; if missing, offer to install when interactive or fail loud when non-interactive (same preflight as PS7). 5.1+7 common syntax subset - executes only under 7 but must parse under 5.1.
# Install BEFORE any Az call, then VERIFY by actually importing Az.Accounts and fail loud if it cannot load: a past mid-run install left a half-installed module (manifests present, MSAL/Azure.Core DLLs missing) that limped on ~an hour and silently produced zero consumption records. Install ONLY the five slim submodules (Accounts/Compute/Monitor/Billing/ResourceGraph), checked per-submodule since a slim install has no `Az` meta-module.
$RequiredAzSubModules = @('Az.Accounts', 'Az.Compute', 'Az.Monitor', 'Az.Billing', 'Az.ResourceGraph')
$MissingAzSubModules = @($RequiredAzSubModules | Where-Object { $null -eq (Get-Module -Name $_ -ListAvailable -ErrorAction SilentlyContinue | Select-Object -First 1) })
if ($MissingAzSubModules.Count -gt 0)
{
    $AzModuleManualHint = ('  Install-Module -Name {0} -Repository PSGallery -Force -AllowClobber -SkipPublisherCheck -Scope CurrentUser' -f ($RequiredAzSubModules -join ','))
    $AzModuleInteractive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected

    if (-not $AzModuleInteractive)
    {
        Write-Host ("Required Az submodule(s) not found ({0}), and this is a non-interactive session, so I will not prompt to install them." -f ($MissingAzSubModules -join ', ')) -ForegroundColor Red
        Write-Host "Install them and re-run:" -ForegroundColor Yellow
        Write-Host $AzModuleManualHint -ForegroundColor Yellow
        exit 1
    }

    Write-Host ""
    $AzModuleAnswer = Read-Host ("These Az submodules are required but not installed: {0}. Install them now (into your user scope)? [y/N]" -f ($MissingAzSubModules -join ', '))
    if ($AzModuleAnswer -notmatch '^(y|yes)$')
    {
        Write-Host "Not installing. Install them and re-run:" -ForegroundColor Yellow
        Write-Host $AzModuleManualHint -ForegroundColor Yellow
        exit 1
    }

    Write-Host ("Installing the required Az submodules into your user scope: {0} ..." -f ($MissingAzSubModules -join ', ')) -ForegroundColor Cyan
    try
    {
        # First-time PowerShellGet use on a fresh box would otherwise interrupt
        # with a "NuGet provider is required, install it now?" prompt. Bootstrap
        # the provider non-interactively so the install cannot hang on it.
        # (-Force on Install-Module below suppresses the untrusted-PSGallery prompt.)
        $null = Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser -ErrorAction SilentlyContinue
        # Install only the missing required submodules, not the full Az rollup.
        Install-Module -Name $MissingAzSubModules -Repository PSGallery -Force -AllowClobber -SkipPublisherCheck -Scope CurrentUser -ErrorAction Stop
    }
    catch
    {
        Write-Host ("Az submodule install failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
        Write-Host "Install them manually then re-run:" -ForegroundColor Yellow
        Write-Host $AzModuleManualHint -ForegroundColor Yellow
        exit 1
    }
}

# Verify the module actually LOADS, not just that its manifest is on disk. This
# catches the half-installed state (manifest present, bundled MSAL/Azure.Core
# assemblies missing) here - with a clear repair message - rather than an hour
# into the run as a silent empty-consumption result. Runs whether we just
# installed Az or found it preinstalled.
try
{
    Import-Module Az.Accounts -ErrorAction Stop
}
catch
{
    Write-Host ("The Az PowerShell module is present but failed to load: {0}" -f $_.Exception.Message) -ForegroundColor Red
    Write-Host "This usually indicates a broken/partial install (manifest present but bundled assemblies missing or unloadable)." -ForegroundColor Yellow
    Write-Host "Repair it, then re-run:" -ForegroundColor Yellow
    Write-Host "  Get-Module Az* -ListAvailable | Uninstall-Module -Force" -ForegroundColor Yellow
    Write-Host "  Install-Module -Name Az.Accounts,Az.Compute,Az.Monitor,Az.Billing,Az.ResourceGraph -Repository PSGallery -Force -AllowClobber -SkipPublisherCheck -Scope CurrentUser" -ForegroundColor Yellow
    exit 1
}

# ---------------------------------------------------------------------------
# Load shared helper functions. Dot-sourced (NOT invoked via &) so they load
# into this script's scope. Fail loud if the file is missing rather than
# breaking later with a confusing "command not found".
# ---------------------------------------------------------------------------
$FunctionsFile = Join-Path $PSScriptRoot 'Functions/RunAllSubscriptions.Functions.ps1'
if (-not (Test-Path -LiteralPath $FunctionsFile -PathType Leaf))
{
    Write-Host "ERROR: Required functions file not found: $FunctionsFile" -ForegroundColor Red
    Write-Host "Ensure the 'Functions' folder ships alongside this script." -ForegroundColor Yellow
    exit 1
}
. $FunctionsFile

# Shared cross-cutting helpers (Write-RdaProgress). Same dot-source pattern.
$CommonFunctionsFile = Join-Path $PSScriptRoot 'Functions/Common.Functions.ps1'
if (-not (Test-Path -LiteralPath $CommonFunctionsFile -PathType Leaf))
{
    Write-Host "ERROR: Required functions file not found: $CommonFunctionsFile" -ForegroundColor Red
    Write-Host "Ensure the 'Functions' folder ships alongside this script." -ForegroundColor Yellow
    exit 1
}
. $CommonFunctionsFile

# Turn off the Windows console QuickEdit mode as early as possible so a stray
# click in the window cannot suspend the run mid-output (the "stuck until I
# pressed Enter" freeze). No-ops on non-Windows / non-interactive / redirected
# sessions and never throws. See Disable-ConsoleQuickEdit for details.
Disable-ConsoleQuickEdit

$RunStartTime = Get-Date

# -MainSummary is a retained no-op: acknowledge it here when it is actually passed (not just at the param block) so an operator can tell "retained no-op" from "silently ignored a typo". Info, not a warning - they still get the summary they asked for.
if ($PSBoundParameters.ContainsKey('MainSummary'))
{
    Write-Host "Note: -MainSummary is a retained no-op. The aggregate MainSummary.html is produced on EVERY run and folded into the consolidated bundle, so you already get it without this flag." -ForegroundColor DarkGray
}

$FailedSubscriptions = @()

# Subscriptions whose inner script could not write its report archive (ResourceInventory.ps1 exit code 2). Tracked separately from $FailedSubscriptions because it is the one failure class meaning "a report is MISSING from the bundle", which is exactly what the wrapper's own exit code 2 signals.
# Without this the run would exit 0: the sub is correctly excluded from the expected archive count, so the output-verification gate has nothing to compare and stays silent, leaving a failure that exit-code-only automation reads as success.
$ArchiveWriteFailures = @()

# Per-sub metrics-phase auth health aggregated across the run: a list of {Name,Id,Message}, one per sub whose metrics phase was skipped for missing Azure auth despite no -SkipMetrics. Sequential runs append directly; parallel streams report their own summary JSON that the aggregation loop concatenates.
# The final summary reads this to list metrics-skipped subs and set the non-zero exit code. Empty = no problem.
$Global:MetricsFailedSubs = @()

# Per-sub collector failures aggregated across the run: a list of {Id,Module,Message}, one per (sub,collector) where a Services/*.ps1 collector threw and was caught by ResourceInventory.ps1's circuit breaker. Same lifecycle as $Global:MetricsFailedSubs above (sequential appends directly; parallel concatenates per-stream summary JSON).
$Global:CollectorFailures = @()

# Inventory root (resume state, consolidated output, wrapper transcript), computed up front so the transcript can start before anything else writes. Get-RdaInventoryRoot is the SINGLE resolver: it creates the dir, PROVES it writable with a real write, and degrades loudly to a fallback rather than continuing toward an unusable dir (the old inline path swallowed the failure and failed later elsewhere).
# -NoInherit because this process ESTABLISHES the root: a stale RDA_INVENTORY_ROOT left in the operator's shell must not be trusted. The resolved value is then pinned for children, so the inner script and every stream write under the SAME root the consolidation step reads.
$RootResult = Get-RdaInventoryRoot -NoInherit
if (-not $RootResult.Ok)
{
    Write-Host ("ERROR: {0}" -f $RootResult.Message) -ForegroundColor Red
    Exit-Wrapper -Code 1
}
$InventoryRoot = $RootResult.Path
if ($RootResult.IsFallback)
{
    Write-Host ("WARNING: {0}" -f $RootResult.Message) -ForegroundColor Yellow
}
Set-RdaInventoryRootForChildren -Path $InventoryRoot

# Wrapper-level transcript. ResourceInventory.ps1 records a per-sub transcript, but not the wrapper's own output (tenant resolution, auth-gate decisions, resume messages, the cross-iteration narration, consolidation, the final summary) - the most useful multi-sub diagnostic of which sub failed and why.
# Runs for every invocation, lands at <InventoryRoot>/RunAllSubscriptions_transcript_<timestamp>.txt, and is Stop'd on every exit path via Exit-Wrapper.
$WrapperTranscriptStarted = $false
$WrapperTranscriptFile = Join-Path $InventoryRoot ("RunAllSubscriptions_transcript_{0}.txt" -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'))
try
{
    Start-Transcript -LiteralPath $WrapperTranscriptFile -UseMinimalHeader -Force | Out-Null
    $WrapperTranscriptStarted = $true
    Write-Host ("Wrapper transcript: {0}" -f $WrapperTranscriptFile) -ForegroundColor DarkGray
}
catch
{
    # Non-fatal. If transcript fails to start (rare - usually permissions or
    # an already-running transcript on this host), the run continues without
    # one rather than aborting.
    Write-Host ("WARNING: Could not start wrapper transcript at {0}: {1}" -f $WrapperTranscriptFile, $_.Exception.Message) -ForegroundColor Yellow
}




Invoke-PreFlightChecks -InventoryRoot $InventoryRoot


try
{
    $TenantID = Resolve-TenantId -Value $TenantID
}
catch
{
    Write-Host ("ERROR: {0}" -f $_.Exception.Message) -ForegroundColor Red
    Exit-Wrapper -Code 1
}

# Validate the sharding parameters up front (before any work). ShardCount>=1 and
# a ShardIndex in [0, ShardCount-1] are the only valid combinations; anything
# else is an operator mistake that would silently process the wrong slice, so
# fail loud immediately. ShardCount=1 (default) is the no-sharding case.
if ($ShardCount -lt 1)
{
    Write-Host ("ERROR: -ShardCount must be >= 1 (got {0})." -f $ShardCount) -ForegroundColor Red
    Exit-Wrapper -Code 1
}
if ($ShardIndex -lt 0 -or $ShardIndex -ge $ShardCount)
{
    Write-Host ("ERROR: -ShardIndex must be in [0, {0}] for -ShardCount {1} (got {2})." -f ($ShardCount - 1), $ShardCount, $ShardIndex) -ForegroundColor Red
    Exit-Wrapper -Code 1
}

# Validate the blob-upload request up front (before the multi-hour run): the operator EXPLICITLY asked to upload, so a malformed URL or a missing Az.Storage module must fail LOUD here rather than stranding a whole run's output on an ephemeral node with only an end-of-run warning. (The upload itself later stays best-effort for transient/RBAC issues.)
if ($UploadToBlobContainerUri)
{
    $UploadUriValid = $false
    try
    {
        $PreflightUri = [System.Uri]$UploadToBlobContainerUri
        $UploadUriValid = $PreflightUri.Scheme -eq 'https' -and
        $PreflightUri.Host -match '\.blob\.' -and -not [string]::IsNullOrWhiteSpace($PreflightUri.AbsolutePath.Trim('/'))
    }
    catch
    {
        $UploadUriValid = $false
    }
    if (-not $UploadUriValid)
    {
        Write-Host ("ERROR: -UploadToBlobContainerUri '{0}' is not a valid blob container URL. Expected https://<account>.blob.core.windows.net/<container>[/<prefix>]." -f $UploadToBlobContainerUri) -ForegroundColor Red
        Exit-Wrapper -Code 1
    }
    if ($null -eq (Get-Module -Name Az.Storage -ListAvailable -ErrorAction SilentlyContinue | Select-Object -First 1))
    {
        Write-Host "ERROR: -UploadToBlobContainerUri was requested but the Az.Storage module is not installed. Install it (Install-Module Az.Storage -Scope CurrentUser) or bake it into the container image, then re-run." -ForegroundColor Red
        Exit-Wrapper -Code 1
    }
}

# Resume state helpers. When sharding (ShardCount>1) each shard keeps its OWN unified resume-state file so shards never clobber each other. NOTE the intended topology is ONE shard per machine: the per-stream artefacts are keyed by tenant+stream index only (NOT by shard), so two shards on the SAME host + InventoryRoot with -ParallelStreams>1 would collide - run each shard on its own machine (or give each a distinct InventoryRoot).
# The non-sharded filename is unchanged, so a normal run resumes exactly as before.
$ResumeStateFile = if ($ShardCount -gt 1)
{
    Join-Path $InventoryRoot (".resume-state-{0}-shard-{1}of{2}.json" -f $TenantID, $ShardIndex, $ShardCount)
}
else
{
    Join-Path $InventoryRoot (".resume-state-{0}.json" -f $TenantID)
}

# Blob-backed resume state (AKS pod-reschedule durability): validate the URL shape + Az.Storage up front (mirroring the -UploadToBlobContainerUri preflight) so a bad URL / missing module fails LOUD here, not after a multi-hour run. The passwordless context is built later, just before state is first read/written.
# $StateBlobParts is $null when the feature is off, keeping every downstream blob step a no-op and the run byte-identical to a local-only run.
$StateBlobParts = $null
if ($StateBlobContainerUri)
{
    $StateUriValid = $false
    try
    {
        $StatePreflightUri = [System.Uri]$StateBlobContainerUri
        $StateUriValid = $StatePreflightUri.Scheme -eq 'https' -and
        $StatePreflightUri.Host -match '\.blob\.' -and -not [string]::IsNullOrWhiteSpace($StatePreflightUri.AbsolutePath.Trim('/'))
    }
    catch
    {
        $StateUriValid = $false
    }
    if (-not $StateUriValid)
    {
        Write-Host ("ERROR: -StateBlobContainerUri '{0}' is not a valid blob container URL. Expected https://<account>.blob.core.windows.net/<container>[/<prefix>]." -f $StateBlobContainerUri) -ForegroundColor Red
        Exit-Wrapper -Code 1
    }
    if ($null -eq (Get-Module -Name Az.Storage -ListAvailable -ErrorAction SilentlyContinue | Select-Object -First 1))
    {
        Write-Host "ERROR: -StateBlobContainerUri was requested but the Az.Storage module is not installed. Install it (Install-Module Az.Storage -Scope CurrentUser) or bake it into the container image, then re-run." -ForegroundColor Red
        Exit-Wrapper -Code 1
    }
    $StateBlobParts = Split-BlobContainerUri -Uri $StateBlobContainerUri
    Write-Host ("Resume state will be mirrored to blob: {0}/{1}_state/ (shard-namespaced)" -f $StateBlobParts.Container, $StateBlobParts.Prefix) -ForegroundColor Cyan
}








# Authenticate, but only if needed: skip the interactive Connect-AzAccount (which reprompts every run in e.g. Cloud Shell) only when the cached context is BOTH on the requested tenant AND can still acquire a token silently.
# Tenant match alone is not enough - a persisted context can carry the right tenant with an expired/revoked refresh token, which then emits a warning and silently returns an empty inventory - so the gate actually probes token acquisition for the tenant and skips login only if that probe succeeds.





try
{
    $PsTenant = Get-AzPsSignedInTenant

    $PsTenantOk = ($PsTenant -eq $TenantID)

    $PsTokenOk = $false
    if ($PsTenantOk) { $PsTokenOk = Test-AzPsTokenSilent -Tenant $TenantID }

    $PsOk = $PsTenantOk -and $PsTokenOk

    if ($PsOk)
    {
        Write-Host ("Existing session detected for tenant {0} (token probe ok); skipping interactive login." -f $TenantID) -ForegroundColor Green
    }
    else
    {
        if ($null -eq $PsTenant)
        {
            Write-Host "Az PowerShell is not signed in; authenticating..." -ForegroundColor Cyan
        }
        elseif (-not $PsTenantOk)
        {
            Write-Host ("Az PowerShell is signed in to tenant {0}; switching to {1}..." -f $PsTenant, $TenantID) -ForegroundColor Cyan
        }
        else
        {
            Write-Host ("Az PowerShell session for tenant {0} cannot acquire a token silently (likely expired or CA/MFA-gated); re-authenticating..." -f $TenantID) -ForegroundColor Cyan
        }

        # Do not launch an interactive sign-in in a non-interactive/headless session (an ADO agent, cron, or any redirected-stdin run): Connect-AzAccount would block on a browser/device-code prompt no one can answer and hang the run. Fail loud with actionable guidance and a non-zero exit instead.
        # -DeviceLogin is an explicit opt-in to the device-code flow and is still honored. Uses the same interactivity test as the PS7 / Az module install prompts above.
        $SessionInteractive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
        if (-not $SessionInteractive -and -not $DeviceLogin)
        {
            Write-Host ("ERROR: No usable Az PowerShell session for tenant {0}, and this is a non-interactive session - refusing to launch an interactive sign-in (it would hang here)." -f $TenantID) -ForegroundColor Red
            Write-Host "Establish a session before running (choose one):" -ForegroundColor Yellow
            Write-Host "  - Use an AzurePowerShell@5 pipeline task (NOT AzureCLI@2) so the Az PowerShell context is set from the service connection." -ForegroundColor Yellow
            Write-Host ("  - Or run 'Connect-AzAccount -Tenant {0}' interactively first, then re-run." -f $TenantID) -ForegroundColor Yellow
            Write-Host "  - Or pass -DeviceLogin to use the device-code flow (still requires a human to complete it)." -ForegroundColor Yellow
            Exit-Wrapper -Code 1
        }

        if ($DeviceLogin)
        {
            Connect-AzAccount -Tenant $TenantID -UseDeviceAuthentication | Out-Null
        }
        else
        {
            Connect-AzAccount -Tenant $TenantID | Out-Null
        }
    }
}
catch
{
    Write-Host "ERROR: Authentication failed. $_" -ForegroundColor Red
    Exit-Wrapper -Code 1
}

# Identity banner: print WHO this run is authenticated as, before any work. On AKS / workload identity the pod signs in as a service principal / managed identity, whereas a VM operator signs in as themselves - a run returning 0 resources is almost always a DIFFERENT principal, which the Account.Type line surfaces at a glance.
# Native Az only: identity is read from Get-AzContext (the tool never invokes the az CLI at runtime), so there is no az.cmd/cmd.exe quoting boundary.
Write-Host ""
Write-Host "Running identity:" -ForegroundColor Cyan
$BannerCtx = Get-AzContext -ErrorAction SilentlyContinue
if ($BannerCtx -and $BannerCtx.Account)
{
    Write-Host ("  Az PowerShell : {0} (type: {1})" -f $BannerCtx.Account.Id, $BannerCtx.Account.Type) -ForegroundColor Green
    Write-Host ("  Tenant        : {0}" -f $BannerCtx.Tenant.Id) -ForegroundColor Green
    if ($BannerCtx.Subscription -and $BannerCtx.Subscription.Id)
    {
        Write-Host ("  Active sub    : {0}" -f $BannerCtx.Subscription.Id) -ForegroundColor Green
    }
    # For a service-principal / workload identity (type != 'User'), Account.Id is the app (client) id, which Azure DevOps' log scrubber masks as '***' because the service connection registered it as a secret - that is ADO masking the LOG, not the tool hiding it (Tenant / Active sub are not secrets and print normally).
    # Explain it inline because this masked principal is exactly the identity that must hold Reader (+ Cost Management / Monitoring Reader) for the run to see resources, and it differs from an interactive VM login.
    if ($BannerCtx.Account.Type -and $BannerCtx.Account.Type -ne 'User')
    {
        Write-Host "  Note          : running as a service principal / workload identity. If the id above shows as '***', that" -ForegroundColor DarkYellow
        Write-Host "                  is Azure DevOps masking the service connection's client id in the log - not the tool." -ForegroundColor DarkYellow
        Write-Host "                  Identify this principal in Project Settings > Service connections, or resolve its object id" -ForegroundColor DarkYellow
        Write-Host "                  with  Get-AzADServicePrincipal -ApplicationId <app-id>  from a workstation, then grant THAT" -ForegroundColor DarkYellow
        Write-Host "                  object id Reader at the tenant-root management group (it differs from an interactive login)." -ForegroundColor DarkYellow
    }
}
else
{
    Write-Host "  Az PowerShell : NOT signed in (Get-AzContext returned nothing)" -ForegroundColor Red
}
Write-Host ""

# Get all subscriptions. Get-AzSubscription WARNS (does not throw) when token acquisition for a tenant fails (typically CA/MFA) and then returns nothing, which would otherwise let the wrapper report "All subscriptions processed!" over an empty inventory - so capture warnings and treat zero-results-with-warnings as a loud failure.
# -WarningVariable names the variable WITHOUT the sigil; it is spelled to MATCH the reads below (a case mismatch still populated $SubWarnings but read as a different, never-assigned variable, which a review pass then flagged as dead code).
$AllSubscriptions = Get-AzSubscription -TenantId $TenantID -WarningVariable SubWarnings -WarningAction SilentlyContinue
if ($null -eq $AllSubscriptions) { $AllSubscriptions = @() }
$AllSubscriptions = @($AllSubscriptions)

if ($AllSubscriptions.Count -eq 0)
{
    Write-Host ("ERROR: Get-AzSubscription returned no subscriptions for tenant {0}." -f $TenantID) -ForegroundColor Red
    if ($SubWarnings.Count -gt 0)
    {
        Write-Host "Underlying warnings:" -ForegroundColor Red
        foreach ($w in $SubWarnings) { Write-Host ("  - {0}" -f $w) -ForegroundColor Red }
        Write-Host "This typically indicates the cached session cannot acquire a token (Conditional Access / MFA), or the signed-in identity has no access to any subscription in this tenant." -ForegroundColor Yellow
        Write-Host "Try re-running with -DeviceLogin, or sign out and sign back in to the requested tenant." -ForegroundColor Yellow
    }
    else
    {
        Write-Host "The signed-in identity may have no subscriptions in this tenant. Verify with 'Get-AzSubscription -TenantId <id>' interactively." -ForegroundColor Yellow
    }
    Exit-Wrapper -Code 1
}

# Filter out non-Enabled subscriptions by default: Disabled/Warned/Deleted subs return little-to-no data yet still cost wall-clock time (which matters where the session has a hard maximum lifetime, e.g. Azure Cloud Shell). Pass -IncludeDisabled to inventory every subscription regardless of state.
if ($IncludeDisabled)
{
    $Subscriptions = $AllSubscriptions
    $Excluded = @()
}
else
{
    $Subscriptions = @($AllSubscriptions | Where-Object { $_.State -eq 'Enabled' })
    $Excluded = @($AllSubscriptions | Where-Object { $_.State -ne 'Enabled' })
}

Write-Host ("Subscriptions visible: {0}" -f $AllSubscriptions.Count) -ForegroundColor Cyan
if ($Excluded.Count -gt 0)
{
    $ByState = $Excluded | Group-Object -Property State | ForEach-Object { ('{0}: {1}' -f $_.Name, $_.Count) }
    Write-Host ("Excluded {0} non-Enabled subscription(s) [{1}]. Use -IncludeDisabled to inventory them anyway." -f $Excluded.Count, ($ByState -join ', ')) -ForegroundColor Yellow
}

# -Plan assess-only sizing: reuse the just-computed eligible set and this host's CPU/RAM to recommend a single-machine run (with concrete parallelism flags) or a shard count + ready-to-paste per-node commands, then EXIT without inventorying. Placed after the eligible/disabled split (so it sizes the real workload) but before the shard/access/consumption gates, since it is advice only and makes no per-sub calls.
if ($Plan)
{
    $PlanRec = Get-RecommendedParallelism
    # Honor an operator's EXPLICIT -ParallelStreams / -ConcurrencyLimit here (the auto-tune block later fills only the ones NOT passed) so -Plan sizes and prints the SAME parallelism the recommended command would actually use. $PSBoundParameters is reliable because the PS7 relaunch forwards only bound params.
    $PlanStreamsExplicit = $PSBoundParameters.ContainsKey('ParallelStreams')
    $PlanConcurrencyExplicit = $PSBoundParameters.ContainsKey('ConcurrencyLimit')
    $PlanStreams = if ($PlanStreamsExplicit) { $ParallelStreams } else { $PlanRec.Streams }
    $PlanConcurrency = if ($PlanConcurrencyExplicit) { $ConcurrencyLimit } else { $PlanRec.Concurrency }
    # Never recommend more parallel streams than there are subscriptions to
    # process (a tiny tenant would otherwise be told to use more streams than it
    # has work for; the real run clamps this too - see the -ParallelStreams path).
    if ($Subscriptions.Count -gt 0 -and $PlanStreams -gt $Subscriptions.Count) { $PlanStreams = $Subscriptions.Count }

    $FmtDur = {
        param([long]$Seconds)
        # Round to whole minutes FIRST, then split into h/m, so a remainder that
        # rounds to 60 rolls into the next hour (e.g. 7199s -> "2h 0m", not "1h 60m").
        $TotalMinutes = [long][math]::Round($Seconds / 60.0)
        $Hours = [math]::Floor($TotalMinutes / 60)
        $Minutes = $TotalMinutes % 60
        if ($Hours -gt 0) { '{0}h {1}m' -f $Hours, $Minutes } else { '{0}m' -f $Minutes }
    }

    # Render a value-bearing argument as a robust single-quoted PowerShell literal
    # (single quotes doubled) so a value with spaces or shell-significant
    # characters round-trips when the operator pastes the recommended command.
    $QuoteArg = { param($Value) "'" + ([string]$Value -replace "'", "''") + "'" }

    # Echo the phase/output flags the operator passed so the recommended command(s)
    # are copy-paste accurate (the parallelism flags come from the recommendation
    # or the operator's explicit values).
    $ExtraFlags = @()
    if ($Obfuscate) { $ExtraFlags += '-Obfuscate' }
    if ($DeviceLogin) { $ExtraFlags += '-DeviceLogin' }
    if ($IncludeDisabled) { $ExtraFlags += '-IncludeDisabled' }
    if ($AllowPartialAccess) { $ExtraFlags += '-AllowPartialAccess' }
    if ($Detailed) { $ExtraFlags += '-Detailed' }
    if ($Service) { $ExtraFlags += ('-Service {0}' -f (& $QuoteArg ($Service -join ','))) }
    if ($SkipMetrics) { $ExtraFlags += '-SkipMetrics' }
    if ($SkipConsumption) { $ExtraFlags += '-SkipConsumption' }
    if ($UseMetricsBatch) { $ExtraFlags += '-UseMetricsBatch' }
    if ($IncludeStorageMetrics) { $ExtraFlags += '-IncludeStorageMetrics' }
    if ($SkipDiskMetrics) { $ExtraFlags += '-SkipDiskMetrics' }
    if ($MetricsDetailed) { $ExtraFlags += '-MetricsDetailed' }
    if ($CapacityPlan) { $ExtraFlags += '-CapacityPlan' }
    if ($MetricsIntervalMinutes -gt 0) { $ExtraFlags += ('-MetricsIntervalMinutes {0}' -f $MetricsIntervalMinutes) }
    if ($PSBoundParameters.ContainsKey('MetricsLookbackDays')) { $ExtraFlags += ('-MetricsLookbackDays {0}' -f $MetricsLookbackDays) }
    if ($HeadRoom -gt 0) { $ExtraFlags += ('-HeadRoom {0}' -f $HeadRoom) }
    if ($UploadToBlobContainerUri) { $ExtraFlags += ('-UploadToBlobContainerUri {0}' -f (& $QuoteArg $UploadToBlobContainerUri)) }
    if ($StateBlobContainerUri) { $ExtraFlags += ('-StateBlobContainerUri {0}' -f (& $QuoteArg $StateBlobContainerUri)) }
    $ExtraStr = if ($ExtraFlags.Count -gt 0) { ' ' + ($ExtraFlags -join ' ') } else { '' }
    # InvariantCulture: a one-decimal double, and this console line is captured in
    # RunAllSubscriptions_transcript_*.txt, which the support bundle collects.
    $RamLabelPlan = if ($PlanRec.RamGB -gt 0) { '{0} GB RAM' -f $PlanRec.RamGB.ToString([cultureinfo]::InvariantCulture) } else { 'RAM undetected' }

    # Composition-aware sizing (preferred): count each sub's projected metric-query volume live via Resource Graph, then size shards from the BUSIEST shard under the real runtime hash partition. Falls through to the flat per-sub estimate below (byte-identical to the previous behaviour) when metrics are skipped, the Graph query is unavailable/fails, or there are no eligible subs.
    $WeightedPlan = $null
    $PlanArgUnavailable = $false
    $PlanZeroWeightSubs = 0
    $PlanCallPerQuery = 0.0
    $PlanBatchPerQuery = 0.0
    if (-not $SkipMetrics -and $Subscriptions.Count -gt 0)
    {
        # The storage capacity metric is OPT-IN, so the plan must drop its weight
        # term unless this run would actually collect it. Sizing with a term the
        # run will not spend would over-estimate the tenant and recommend more
        # shards than needed. This mirrors the runtime gate in Extension/Metrics.ps1
        # exactly.
        $PlanSkipStorage = -not $IncludeStorageMetrics
        $PlanSubWeights = Get-PlanSubscriptionWeights -SubscriptionIds @($Subscriptions | ForEach-Object { [string]$_.Id }) -SkipDiskMetrics:$SkipDiskMetrics -SkipStorageMetrics:$PlanSkipStorage
        # $null == the query was UNUSABLE (Search-AzGraph missing or it threw);
        # an EMPTY hashtable is a usable "no metric-eligible resources" answer.
        if ($null -ne $PlanSubWeights)
        {
            # Rough, DELIBERATELY CONSERVATIVE per-metric-query costs (seconds): per-call is the slow path, so under -UseMetricsBatch only the batchable types' portion gets the cheaper batch cost and the rest stays per-call. These are throttling-dependent estimates, not measurements, so the model rounds UP, never down; -PlanPerQuerySeconds overrides both.
            $PlanCallPerQuery = if ($PlanPerQuerySeconds -gt 0) { $PlanPerQuerySeconds } else { 9.5 }
            $PlanBatchPerQuery = if ($PlanPerQuerySeconds -gt 0) { $PlanPerQuerySeconds } else { 0.5 }
            # Fixed per-subscription overhead the metric weight does NOT capture:
            # inventory collection, consumption, packaging/upload, process
            # startup. Deliberately generous so a "fits" verdict keeps headroom.
            $PlanBaseSeconds = 90.0
            # Safety margin on the metric estimate to absorb intra-shard per-stream
            # imbalance and throttling variance (the sizing model is a lower bound,
            # not a full scheduler simulation).
            $PlanSafetyFactor = 1.3
            $PlanSubSeconds = @{}
            foreach ($PlanSub in $Subscriptions)
            {
                $SubKey = [string]$PlanSub.Id
                if ($PlanSubWeights.ContainsKey($SubKey))
                {
                    $SubW = $PlanSubWeights[$SubKey]
                    $BatchW = [double]$SubW.Batch
                    $CallW = [double]$SubW.Total - $BatchW
                    if ($CallW -lt 0) { $CallW = 0 }
                    $MetricSeconds = if ($UseMetricsBatch)
                    {
                        ($PlanBatchPerQuery * $BatchW) + ($PlanCallPerQuery * $CallW)
                    }
                    else
                    {
                        $PlanCallPerQuery * [double]$SubW.Total
                    }
                    $PlanSubSeconds[$SubKey] = $PlanBaseSeconds + ($MetricSeconds * $PlanSafetyFactor)
                }
                else
                {
                    # No ARG row for this subscription -> no metric-eligible
                    # resources in scope, so size it at base overhead. If the
                    # operator EXPECTS metrics here, the identity may simply lack
                    # Resource Graph visibility into it - surfaced in the note below.
                    $PlanZeroWeightSubs++
                    $PlanSubSeconds[$SubKey] = $PlanBaseSeconds
                }
            }
            $WeightedPlan = Get-WeightedInventoryPlan -SubSeconds $PlanSubSeconds -Streams $PlanStreams -MaxSingleMachineHours 2
        }
        else
        {
            $PlanArgUnavailable = $true
        }
    }

    if ($null -ne $WeightedPlan)
    {
        $CostSource = if ($PlanPerQuerySeconds -gt 0) { 'operator-supplied -PlanPerQuerySeconds' } elseif ($UseMetricsBatch) { 'auto: batched, rough' } else { 'auto: per-call, rough' }
        $StreamsSrcPlan = if ($PlanStreamsExplicit) { 'explicit' } else { 'auto' }
        $ConcSrcPlan = if ($PlanConcurrencyExplicit) { 'explicit' } else { 'auto' }
        Write-Host ""
        Write-Host "================ Inventory Plan (assessment only - nothing was inventoried) ================" -ForegroundColor Green
        Write-Host ("Eligible subscriptions   : {0}" -f $WeightedPlan.SubscriptionCount) -ForegroundColor Cyan
        Write-Host ("This machine             : {0} vCPU / {1}  ->  -ParallelStreams {2} ({3}) -ConcurrencyLimit {4} ({5})" -f $PlanRec.VCpu, $RamLabelPlan, $PlanStreams, $StreamsSrcPlan, $PlanConcurrency, $ConcSrcPlan) -ForegroundColor Cyan
        Write-Host "Sizing basis             : live metric-query volume (Resource Graph)" -ForegroundColor Cyan
        if ($UseMetricsBatch)
        {
            Write-Host ("Per-metric-query cost    : ~{0}s per-call, ~{1}s batched types [{2}]" -f $PlanCallPerQuery, $PlanBatchPerQuery, $CostSource) -ForegroundColor Cyan
        }
        else
        {
            Write-Host ("Per-metric-query cost    : ~{0}s [{1}]" -f $PlanCallPerQuery, $CostSource) -ForegroundColor Cyan
        }
        Write-Host ("Single-machine ceiling   : {0} h" -f $WeightedPlan.MaxSingleMachineHours) -ForegroundColor Cyan
        Write-Host ("Slowest single sub (est) : ~{0}" -f (& $FmtDur $WeightedPlan.LargestSingleSubSeconds)) -ForegroundColor Cyan
        Write-Host ""

        if ($WeightedPlan.CeilingUnreachable)
        {
            # LEAD with an accurate warning (keyed off the reason) BEFORE any
            # recommendation, so the operator never reads a "within the ceiling"
            # line the plan then contradicts. Never claim the sharded fallback
            # fits - it does not.
            if ($WeightedPlan.CeilingUnreachableReason -eq 'single-subscription-exceeds-ceiling')
            {
                Write-Host ("WARNING: the single slowest subscription alone is ~{0}, over the {1} h ceiling. Sharding splits work ACROSS subscriptions and cannot speed up ONE subscription, so NO shard count fixes this - reduce that subscription's metrics load instead (-SkipDiskMetrics removes the disk queries that dominate volume, -UseMetricsBatch cuts the per-query cost, -MetricsIntervalMinutes 60 shrinks each response, -MetricsLookbackDays 14 shortens the window each response covers). See docs/Plan.md." -f (& $FmtDur $WeightedPlan.LargestSingleSubSeconds), $WeightedPlan.MaxSingleMachineHours) -ForegroundColor Yellow
            }
            else
            {
                Write-Host ("WARNING: even at {0} shard(s) - one per subscription, the maximum useful - the busiest shard is ~{1}, over the {2} h ceiling, because the hash partition clumps several heavy subscriptions together. Reduce metrics load (-SkipDiskMetrics / -UseMetricsBatch / -MetricsIntervalMinutes 60 / -MetricsLookbackDays 14) to bring the busiest shard down. See docs/Plan.md." -f $WeightedPlan.ShardCount, (& $FmtDur $WeightedPlan.BusiestShardSeconds), $WeightedPlan.MaxSingleMachineHours) -ForegroundColor Yellow
            }
            Write-Host ""
            Write-Host ("Best achievable with the current settings: SHARD across {0} machine(s) (busiest shard still ~{1} - does NOT get under the ceiling)." -f $WeightedPlan.ShardCount, (& $FmtDur $WeightedPlan.BusiestShardSeconds)) -ForegroundColor Yellow
            $MaxToList = 10
            $ListCount = [math]::Min($WeightedPlan.ShardCount, $MaxToList)
            for ($i = 0; $i -lt $ListCount; $i++)
            {
                Write-Host ("    ./Run-AllSubscriptions.ps1 -TenantID {0} -ShardCount {1} -ShardIndex {2} -ParallelStreams {3} -ConcurrencyLimit {4}{5}" -f (& $QuoteArg $TenantID), $WeightedPlan.ShardCount, $i, $PlanStreams, $PlanConcurrency, $ExtraStr) -ForegroundColor White
            }
            if ($WeightedPlan.ShardCount -gt $MaxToList)
            {
                Write-Host ("    ... through -ShardIndex {0} (use -ShardIndex 0..{0}, one per machine)." -f ($WeightedPlan.ShardCount - 1)) -ForegroundColor DarkGray
            }
        }
        elseif ($WeightedPlan.Mode -eq 'Single')
        {
            Write-Host ("Recommendation: SINGLE MACHINE is sufficient (busiest-path est. ~{0}, under the {1} h ceiling)." -f (& $FmtDur $WeightedPlan.BusiestShardSeconds), $WeightedPlan.MaxSingleMachineHours) -ForegroundColor Green
            Write-Host "Run:" -ForegroundColor Green
            Write-Host ("  ./Run-AllSubscriptions.ps1 -TenantID {0} -ParallelStreams {1} -ConcurrencyLimit {2}{3}" -f (& $QuoteArg $TenantID), $PlanStreams, $PlanConcurrency, $ExtraStr) -ForegroundColor White
        }
        else
        {
            Write-Host ("Recommendation: SHARD across {0} machines (busiest shard est. ~{1}, within the {2} h ceiling)." -f $WeightedPlan.ShardCount, (& $FmtDur $WeightedPlan.BusiestShardSeconds), $WeightedPlan.MaxSingleMachineHours) -ForegroundColor Green
            Write-Host ("  ~{0} subscription(s) per machine (shards balanced by the real hash partition, so heavy subscriptions are spread out)." -f $WeightedPlan.PerMachineSubscriptions) -ForegroundColor Green
            Write-Host "  Run ONE of these per machine (same command, distinct -ShardIndex):" -ForegroundColor Green
            $MaxToList = 10
            $ListCount = [math]::Min($WeightedPlan.ShardCount, $MaxToList)
            for ($i = 0; $i -lt $ListCount; $i++)
            {
                Write-Host ("    ./Run-AllSubscriptions.ps1 -TenantID {0} -ShardCount {1} -ShardIndex {2} -ParallelStreams {3} -ConcurrencyLimit {4}{5}" -f (& $QuoteArg $TenantID), $WeightedPlan.ShardCount, $i, $PlanStreams, $PlanConcurrency, $ExtraStr) -ForegroundColor White
            }
            if ($WeightedPlan.ShardCount -gt $MaxToList)
            {
                Write-Host ("    ... through -ShardIndex {0} (use -ShardIndex 0..{0}, one per machine, across all {1} machines)." -f ($WeightedPlan.ShardCount - 1), $WeightedPlan.ShardCount) -ForegroundColor DarkGray
            }
            Write-Host "  Then upload each machine's AllSubscriptions_ResourcesReport_*.zip (see docs/horizontal-sharding.md)." -ForegroundColor DarkGray
        }

        if ($PlanZeroWeightSubs -gt 0)
        {
            Write-Host ("Note: {0} of {1} subscription(s) matched no metric-eligible resources and were sized at base overhead only. If you expect metrics there, the signed-in identity may lack Resource Graph visibility into them." -f $PlanZeroWeightSubs, $WeightedPlan.SubscriptionCount) -ForegroundColor DarkGray
        }
        foreach ($DirLine in (Get-PlanShardDirective -ShardCount $WeightedPlan.ShardCount))
        {
            if ($DirLine -like 'IMPORTANT:*') { Write-Host $DirLine -ForegroundColor Yellow }
            else { Write-Host $DirLine -ForegroundColor DarkGray }
        }
        Write-Host ""
        Write-Host "(Estimate only - the per-metric-query cost is throttling-dependent and the sizing is a conservative lower bound with a built-in safety margin; pass -PlanPerQuerySeconds measured from a prior run's Diagnostics timings for a tenant-accurate estimate. See docs/Plan.md.)" -ForegroundColor DarkGray
        Exit-Wrapper -Code 0
    }

    # Flat per-sub fallback estimate - reached only when the composition-aware
    # path above did NOT run (metrics skipped, Resource Graph unavailable/failed,
    # or no eligible subscriptions). Auto-picked from the phase switches:
    # inventory-only is fastest; metrics and consumption each add work.
    if ($PlanArgUnavailable)
    {
        Write-Host ""
        Write-Host "NOTE: could not size by live metric-query volume (Resource Graph unavailable or the query failed), so this is a COARSE flat per-subscription estimate - it ignores per-subscription metric composition and can under- or over-size a tenant with uneven metric load. For a composition-aware plan ensure the Az.ResourceGraph module is available; for a tenant-accurate figure pass -PlanPerQuerySeconds measured from a prior run's Diagnostics timings." -ForegroundColor Yellow
    }
    $PlanPerSub = 60.0
    $PlanMode = 'inventory + metrics + consumption'
    if ($SkipMetrics -and $SkipConsumption) { $PlanPerSub = 20.0; $PlanMode = 'inventory only' }
    elseif ($SkipMetrics -or $SkipConsumption) { $PlanPerSub = 40.0; $PlanMode = 'inventory + one of metrics/consumption' }
    $PlanResult = Get-InventoryPlan -SubscriptionCount $Subscriptions.Count -Streams $PlanStreams -PerSubSeconds $PlanPerSub -MaxSingleMachineHours 2

    Write-Host ""
    Write-Host "================ Inventory Plan (assessment only - nothing was inventoried) ================" -ForegroundColor Green
    Write-Host ("Eligible subscriptions : {0}" -f $PlanResult.SubscriptionCount) -ForegroundColor Cyan
    Write-Host ("This machine           : {0} vCPU / {1}  ->  -ParallelStreams {2} -ConcurrencyLimit {3}" -f $PlanRec.VCpu, $RamLabelPlan, $PlanStreams, $PlanConcurrency) -ForegroundColor Cyan
    Write-Host ("Per-subscription est.  : ~{0}s ({1})" -f [int]$PlanResult.PerSubSeconds, $PlanMode) -ForegroundColor Cyan
    Write-Host ("Single-machine ceiling : {0} h" -f $PlanResult.MaxSingleMachineHours) -ForegroundColor Cyan
    Write-Host ""

    if ($PlanResult.SubscriptionCount -le 0)
    {
        Write-Host "No eligible subscriptions to plan for." -ForegroundColor Yellow
    }
    elseif ($PlanResult.Mode -eq 'Single')
    {
        Write-Host ("Recommendation: SINGLE MACHINE is sufficient (est. ~{0}, under the {1} h ceiling)." -f (& $FmtDur $PlanResult.EstimatedSeconds), $PlanResult.MaxSingleMachineHours) -ForegroundColor Green
        Write-Host "Run:" -ForegroundColor Green
        Write-Host ("  ./Run-AllSubscriptions.ps1 -TenantID {0} -ParallelStreams {1} -ConcurrencyLimit {2}{3}" -f (& $QuoteArg $TenantID), $PlanStreams, $PlanConcurrency, $ExtraStr) -ForegroundColor White
    }
    else
    {
        Write-Host ("Recommendation: SHARD across {0} machines (a single machine would take ~{1}, over the {2} h ceiling)." -f $PlanResult.ShardCount, (& $FmtDur $PlanResult.EstimatedSeconds), $PlanResult.MaxSingleMachineHours) -ForegroundColor Green
        Write-Host ("  Each machine handles ~{0} subscription(s) in ~{1}." -f $PlanResult.PerMachineSubscriptions, (& $FmtDur $PlanResult.EstimatedPerMachineSeconds)) -ForegroundColor Green
        Write-Host "  Run ONE of these per machine (same command, distinct -ShardIndex):" -ForegroundColor Green
        $MaxToList = 10
        $ListCount = [math]::Min($PlanResult.ShardCount, $MaxToList)
        for ($i = 0; $i -lt $ListCount; $i++)
        {
            Write-Host ("    ./Run-AllSubscriptions.ps1 -TenantID {0} -ShardCount {1} -ShardIndex {2} -ParallelStreams {3} -ConcurrencyLimit {4}{5}" -f (& $QuoteArg $TenantID), $PlanResult.ShardCount, $i, $PlanStreams, $PlanConcurrency, $ExtraStr) -ForegroundColor White
        }
        if ($PlanResult.ShardCount -gt $MaxToList)
        {
            Write-Host ("    ... through -ShardIndex {0} (use -ShardIndex 0..{0}, one per machine, across all {1} machines)." -f ($PlanResult.ShardCount - 1), $PlanResult.ShardCount) -ForegroundColor DarkGray
        }
        Write-Host "  Then upload each machine's AllSubscriptions_ResourcesReport_*.zip (see docs/horizontal-sharding.md)." -ForegroundColor DarkGray
    }
    # Machine-readable shard-count token + (when sharding) an explicit "run ALL
    # 0..N-1" directive, so an automating wrapper does not have to scrape the
    # human prose (which caps the printed command list at 10) and an operator
    # cannot misread the required index range.
    foreach ($DirLine in (Get-PlanShardDirective -ShardCount $PlanResult.ShardCount))
    {
        if ($DirLine -like 'IMPORTANT:*') { Write-Host $DirLine -ForegroundColor Yellow }
        else { Write-Host $DirLine -ForegroundColor DarkGray }
    }
    Write-Host ""
    Write-Host "Throttling: Resource Graph queries auto-retry with exponential backoff + jitter (up to 30 retries, backoff capped per attempt) and honor the service's own Retry-After / quota-reset header when it sends one, so a shard rides out sustained tenant-wide throttling at scale instead of failing a subscription." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "(Estimate only - actual time varies with resource density and metrics/consumption volume.)" -ForegroundColor DarkGray
    Exit-Wrapper -Code 0
}

# Horizontal scale-out: keep only THIS shard's slice of the eligible subs. Applied here - after the Enabled/disabled split but BEFORE resume, the access gate, and the stream split - so every downstream phase operates on this shard's slice only. Deterministic per-sub-id hash (Select-ShardSubscriptions) makes the N shards disjoint and exhaustive; no-op and byte-identical when -ShardCount is 1.
if ($ShardCount -gt 1)
{
    $BeforeShard = $Subscriptions.Count
    $Subscriptions = @(Select-ShardSubscriptions -Subscriptions $Subscriptions -ShardIndex $ShardIndex -ShardCount $ShardCount)
    Write-Host ("Shard {0} of {1}: processing {2} of {3} eligible subscription(s) on this machine." -f $ShardIndex, $ShardCount, $Subscriptions.Count, $BeforeShard) -ForegroundColor Cyan
    Write-Host "  Run the other shards (same -ShardCount, different -ShardIndex) on separate machines to cover the full tenant." -ForegroundColor DarkGray
    if ($Subscriptions.Count -eq 0)
    {
        Write-Host ("Shard {0} of {1} has no subscriptions assigned to it; nothing to process on this machine." -f $ShardIndex, $ShardCount) -ForegroundColor Yellow
        Exit-Wrapper -Code 0
    }
}

Write-Host ("Subscriptions to process: {0}" -f $Subscriptions.Count) -ForegroundColor Cyan

# Build the passwordless state-blob context now that we are authenticated and the tenant is enumerated (New-StateBlobContext uses -UseConnectedAccount, which needs a live Az context). $StateBlobArgs splats the {BlobContext;BlobContainer;BlobName} trio into the state read/write helpers and is EMPTY when blob state is off, so those helpers take exactly the local-only path.
$StateBlobArgs = @{}
if ($null -ne $StateBlobParts)
{
    $StateBlobCtx = New-StateBlobContext -Account $StateBlobParts.Account
    $StateBlobArgs = @{
        BlobContext   = $StateBlobCtx
        BlobContainer = $StateBlobParts.Container
        BlobName      = Get-StateBlobName -Prefix $StateBlobParts.Prefix -Tenant $TenantID -ShardIndex $ShardIndex -ShardCount $ShardCount -StreamId -1
    }
}

# Read the existing resume state ONCE (blob-first, then local), then derive the
# completed / failed / start-snapshot views from it. -Resume only controls whether
# we *use* the completed list to skip subscriptions; reading it either way ensures
# the per-iteration writes below append to existing state instead of overwriting
# it. -ResumeFailedOnly uses the failed list to filter the subscription list.
$SeedState = Get-ResumeStateObject -Path $ResumeStateFile -Tenant $TenantID @StateBlobArgs
# Project the three resume views through the shared readers, passing the state already read above so the blob is fetched ONCE rather than once per projection.
# Get-CompletedSubscriptionIds / Get-FailedAttempts return @() by construction so an empty result can no longer collapse to $null (which once turned the first `$CompletedIds += $Sub.Id` into STRING concatenation, silently corrupting the completed set); the outer @(...) is kept as belt-and-braces and Tests/ResumeCycle.Tests.ps1 asserts it. Get-FailedAttempts also strips a phantom null left by a version that serialised an empty list as `[ null ]`.
$CompletedIds = @(Get-CompletedSubscriptionIds -Path $ResumeStateFile -Tenant $TenantID @StateBlobArgs -State $SeedState)
$FailedAttempts = @(Get-FailedAttempts -Path $ResumeStateFile -Tenant $TenantID @StateBlobArgs -State $SeedState)

# Start-of-run subscription universe, for end-of-run reconciliation of a MOVING target (another team creating/deleting subs mid-run). Prefer a snapshot already in state - a resumed/rescheduled run MUST keep the ORIGINAL universe, not re-capture an already-moved one - otherwise capture the current full-tenant enumeration ($AllSubscriptions, taken before the Enabled/scope filters). $StateSaveArgs persists it on every Save-CompletedSubscriptionIds.
$StartSnapshot = Get-StartSnapshot -Path $ResumeStateFile -Tenant $TenantID @StateBlobArgs -State $SeedState
if ($null -eq $StartSnapshot)
{
    $StartSnapshot = [pscustomobject]@{ CapturedUtc = (Get-Date).ToString('o'); SubscriptionIds = @($AllSubscriptions.Id) }
}
$StateSaveArgs = @{ StartSnapshot = $StartSnapshot } + $StateBlobArgs

# Fold in per-stream resume-state left by an INTERRUPTED parallel run: streams persist Completed/FailedAttempts to their own .resume-state-<tenant>-stream-<N>.json and only merge into the unified file at end-of-run, so a run killed before the merge (Ctrl+C, SIGKILL, Cloud Shell timeout) has failures ONLY in the per-stream files while the unified file is stale - without this -ResumeFailedOnly would read the unified file, see no failures, and wrongly report "Nothing to retry".
# Read (do NOT delete) the per-stream files so both -Resume and -ResumeFailedOnly see the full picture; the end-of-run merge owns cleanup. Runs at startup before any stream launches, so it cannot race live streams.
if ($Resume -or $ResumeFailedOnly)
{
    $StrandedStreamFiles = @(Get-StreamResumeStateFiles -InventoryRoot $InventoryRoot -Tenant $TenantID)
    if ($StrandedStreamFiles.Count -gt 0)
    {
        $StrandedCompleted = @()
        $StrandedFailed = @()
        foreach ($StreamFile in $StrandedStreamFiles)
        {
            try
            {
                $Obj = Get-Content -LiteralPath $StreamFile.FullName -Raw | ConvertFrom-Json
                if ($null -ne $Obj.Completed) { $StrandedCompleted += @($Obj.Completed) }
                if ($null -ne $Obj.FailedAttempts) { $StrandedFailed += @($Obj.FailedAttempts) }
            }
            catch
            {
                Write-Verbose ("Could not read stranded stream resume file {0}: {1}" -f $StreamFile.FullName, $_.Exception.Message)
            }
        }
        if ($StrandedCompleted.Count -gt 0)
        {
            $CompletedIds = @($CompletedIds + $StrandedCompleted | Sort-Object -Unique)
        }
        # Same recency-wins / prune-on-completed reconciliation the end-of-run
        # merge uses, so a sub that later succeeded in another stream is dropped.
        $FailedAttempts = Merge-FailedAttempts -ExistingFailedAttempts $FailedAttempts -StreamFailedAttempts $StrandedFailed -CompletedIds $CompletedIds
        if ($StrandedCompleted.Count -gt 0 -or @($StrandedFailed).Count -gt 0)
        {
            Write-Host ("Recovered per-stream state from an interrupted parallel run: {0} completed, {1} failed subscription record(s)." -f $StrandedCompleted.Count, @($StrandedFailed).Count) -ForegroundColor Cyan
            # Heal the unified file immediately so even a re-interrupted run keeps
            # the recovered picture. Per-stream files are intentionally left for
            # the end-of-run merge to reconcile and clean up.
            Save-CompletedSubscriptionIds -Path $ResumeStateFile -Tenant $TenantID -Ids $CompletedIds -FailedAttempts $FailedAttempts @StateSaveArgs
        }
    }
}

if ($Resume)
{
    if ($CompletedIds.Count -gt 0)
    {
        Write-Host ("Resume mode: {0} previously completed subscription(s) will be skipped." -f $CompletedIds.Count) -ForegroundColor Cyan
    }
    else
    {
        Write-Host "Resume mode: no previous state found; processing all subscriptions." -ForegroundColor Cyan
    }
}
else
{
    if ($CompletedIds.Count -gt 0)
    {
        Write-Host ("Note: resume state file exists at {0} ({1} previously completed). Pass -Resume to skip them." -f $ResumeStateFile, $CompletedIds.Count) -ForegroundColor Yellow
    }
}

# -ResumeFailedOnly narrows the eligible list to only subs with a FailedAttempts entry from a prior run (the targeted-retry workflow: re-run JUST the few failures instead of walking the whole tenant with -Resume). Filtered here BEFORE the -Resume "skip completed" check because in failed-only mode the resume list is the authority; the completed list is only consulted to defend against a sub that succeeded on an earlier retry whose FailedAttempts entry was not yet pruned.
if ($ResumeFailedOnly)
{
    if ($FailedAttempts.Count -eq 0)
    {
        Write-Host "ResumeFailedOnly: no failed subscriptions in resume state. Nothing to retry." -ForegroundColor Green
        Write-Host ("If you expected failures here, verify {0} has a non-empty FailedAttempts array." -f $ResumeStateFile) -ForegroundColor DarkGray
        Exit-Wrapper -Code 0
    }
    $FailedIds = @($FailedAttempts | ForEach-Object { $_.Id })
    $BeforeCount = $Subscriptions.Count
    $Subscriptions = @($Subscriptions | Where-Object { $FailedIds -contains $_.Id })
    Write-Host ("ResumeFailedOnly: filtered to {0} previously-failed subscription(s) (was {1})." -f $Subscriptions.Count, $BeforeCount) -ForegroundColor Cyan
    if ($Subscriptions.Count -eq 0)
    {
        # Could happen if the visible-subs list no longer contains the failed
        # IDs (sub was deleted, identity lost access, IncludeDisabled toggled
        # off relative to the prior run). Tell the user instead of silently
        # processing nothing.
        Write-Host "WARNING: FailedAttempts list contained IDs but none are visible in the current subscription set. Verify access and -IncludeDisabled flag matches the prior run." -ForegroundColor Yellow
        Exit-Wrapper -Code 0
    }
}

# Up-front subscription-COVERAGE gate: the access gate below proves the identity can READ the subs it enumerated; this proves it enumerated them ALL. Get-AzSubscription returns only subs the identity holds a role on, so an identity granted access per-subscription (not at the tenant root) SILENTLY MISSES the rest - so a shortfall, or any inability to verify the true total, HARD-STOPS by default (robust fix: Reader at the tenant-root management group, which inherits everywhere and makes the count verifiable). -AllowPartialAccess downgrades it to a loud warning.
# Compares the FULL-tenant enumeration ($AllSubscriptions - state-agnostic, before the Enabled filter and any shard/scope split) against the true count under the tenant-root MG, so the verdict is identical on every shard machine and independent of -Resume / -ParallelStreams scoping.
Write-Host "Verifying full subscription coverage (tenant-root management group)..." -ForegroundColor Cyan
$PreflightCoverageMsg = $null
$Coverage = Get-TenantSubscriptionId -TenantId $TenantID
if ($null -eq $Coverage.Ids)
{
    $PreflightCoverageMsg = $CoverageMsg = ("Could not verify full subscription coverage: the tenant-root management group (GroupName = tenant id) could not be read by this identity, so there is no way to confirm the {0} enumerated subscription(s) are ALL of them." -f $AllSubscriptions.Count)
    if ($AllowPartialAccess -or $Preflight)
    {
        Write-Host ("WARNING: {0}" -f $CoverageMsg) -ForegroundColor Yellow
        if (-not [string]::IsNullOrWhiteSpace($Coverage.Detail)) { Write-Host ("  Reason: {0}" -f $Coverage.Detail) -ForegroundColor DarkYellow }
        Write-Host "  -AllowPartialAccess set: continuing with the enumerated subscription(s), which may not be the full tenant." -ForegroundColor Yellow
    }
    else
    {
        Write-Host ("ERROR: {0}" -f $CoverageMsg) -ForegroundColor Red
        if (-not [string]::IsNullOrWhiteSpace($Coverage.Detail)) { Write-Host ("  Reason: {0}" -f $Coverage.Detail) -ForegroundColor Red }
        Write-Host "  Grant the identity Reader at the tenant-root management group (it inherits to every subscription and makes coverage verifiable), then re-run." -ForegroundColor Red
        Write-Host "  (Or pass -AllowPartialAccess to proceed with only the subscriptions this identity can currently see.)" -ForegroundColor Red
        Exit-Wrapper -Code 1
    }
}
else
{
    # Compare the actual ID SETS, not just counts: the missed subs are those present under the tenant-root MG but NOT enumerable by this identity. Using the id set (rather than a count delta) is immune to a transient count mismatch (e.g. a sub mid-deletion still listed in the MG tree) and lets us NAME exactly which subs would be missed. Compare case-insensitively (GUIDs, but normalise to be safe).
    $AccessibleIdSet = @{}
    foreach ($S in $AllSubscriptions) { $AccessibleIdSet[([string]$S.Id).ToLowerInvariant()] = $true }
    $MissedIds = @($Coverage.Ids | Where-Object { -not $AccessibleIdSet.ContainsKey(([string]$_).ToLowerInvariant()) })
    if ($MissedIds.Count -gt 0)
    {
        # Show the missed ids (capped) to make the gap actionable, mirroring how the
        # access gate below lists each inaccessible subscription id.
        $ShownMissed = @($MissedIds | Select-Object -First 10)
        $MoreNote = if ($MissedIds.Count -gt $ShownMissed.Count) { (' (+{0} more)' -f ($MissedIds.Count - $ShownMissed.Count)) } else { '' }
        $PreflightCoverageMsg = $CoverageMsg = ("Subscription coverage shortfall: the tenant-root management group contains {0} subscription(s) but this identity can enumerate only {1} - {2} would be SILENTLY MISSED from the inventory." -f $Coverage.Ids.Count, $AllSubscriptions.Count, $MissedIds.Count)
        if ($AllowPartialAccess -or $Preflight)
        {
            Write-Host ("WARNING: {0}" -f $CoverageMsg) -ForegroundColor Yellow
            Write-Host ("  Missed: {0}{1}" -f ($ShownMissed -join ', '), $MoreNote) -ForegroundColor DarkYellow
            Write-Host ("  -AllowPartialAccess set: continuing with the {0} visible subscription(s)." -f $AllSubscriptions.Count) -ForegroundColor Yellow
        }
        else
        {
            Write-Host ("ERROR: {0}" -f $CoverageMsg) -ForegroundColor Red
            Write-Host ("  Missed: {0}{1}" -f ($ShownMissed -join ', '), $MoreNote) -ForegroundColor Red
            Write-Host "  Grant the identity Reader at the tenant-root management group (it inherits to all subscriptions) instead of per-subscription, then re-run." -ForegroundColor Red
            Write-Host "  (Or pass -AllowPartialAccess to proceed with only the subscriptions this identity can currently see.)" -ForegroundColor Red
            Exit-Wrapper -Code 1
        }
    }
    else
    {
        Write-Host ("  Coverage verified: all {0} subscription(s) under the tenant-root management group are visible to this identity." -f $Coverage.Ids.Count) -ForegroundColor Green
    }
}

# Up-front access gate: before ANY per-sub work, verify the signed-in identity can read every in-scope sub. Azure Resource Graph returns 0 rows (not a 403) for a sub the identity has no role on, so a permission gap is otherwise invisible until the report comes back missing subs (and can feed the consumption cross-attribution bug). By default any inaccessible sub HARD-STOPS the run; -AllowPartialAccess skips the inaccessible ones and continues.
# On -Resume only the subs this run will actually process are probed. Runs once in the parent, before the sequential/parallel split, so it gates both.
$ScopeForProbe = if ($Resume) { @($Subscriptions | Where-Object { -not ($CompletedIds -contains $_.Id) }) } else { @($Subscriptions) }
if ($ScopeForProbe.Count -gt 0)
{
    Write-Host ("Verifying subscription access up front for {0} subscription(s)..." -f $ScopeForProbe.Count) -ForegroundColor Cyan
    $AccessProbed = Test-SubscriptionAccessAll -Subscriptions $ScopeForProbe
    $AccessDecision = Resolve-AccessPreflight -Probed $AccessProbed -AllowPartialAccess:$AllowPartialAccess
    if ($AccessDecision.Inaccessible.Count -gt 0)
    {
        Write-Host ("  {0} subscription(s) are NOT readable by the signed-in identity:" -f $AccessDecision.Inaccessible.Count) -ForegroundColor Red
        foreach ($NA in $AccessDecision.Inaccessible)
        {
            $Label = if ($NA.State -eq 'Unknown') { 'access probe inconclusive after retries' } else { 'no role on the subscription' }
            Write-Host ("    - {0} ({1}) - {2}" -f $NA.Name, $NA.Id, $Label) -ForegroundColor Red
        }
        if ($AccessDecision.ShouldBlock -and -not $Preflight)
        {
            Write-Host "  Stopping before any work. Grant the identity Reader on these subscriptions, then re-run." -ForegroundColor Red
            Write-Host "  (Or pass -AllowPartialAccess to skip them and inventory only the accessible subscriptions.)" -ForegroundColor Red
            Exit-Wrapper -Code 1
        }
        if ($Preflight) { Write-Host "  -Preflight: continuing so the permission matrix can report these subscriptions." -ForegroundColor Yellow }
        else { Write-Host "  -AllowPartialAccess set: skipping the above and continuing with the accessible subscription(s)." -ForegroundColor Yellow }
        # Remembered for the -Preflight matrix: these are removed from $Subscriptions
        # below, but the matrix must still show them (Reader Denied / Unavailable).
        $PreflightInaccessible = @($AccessDecision.Inaccessible)
        $Subscriptions = @($Subscriptions | Where-Object { $AccessDecision.InaccessibleIds -notcontains $_.Id })
        if ($Subscriptions.Count -eq 0 -and -not $Preflight)
        {
            Write-Host "No accessible subscriptions remain in scope; nothing to process." -ForegroundColor Yellow
            Exit-Wrapper -Code 1
        }
    }
    else
    {
        Write-Host ("  Access verified: all {0} in-scope subscription(s) are readable." -f $ScopeForProbe.Count) -ForegroundColor Green
    }
}

# ---------------------------------------------------------------------------
# -Preflight: permission matrix, then stop. Everything above (sign-in, tenant,
# coverage gate, Reader probe) has already run, so each remaining subscription
# is known to be control-plane readable; what is left to prove is the two
# data-phase permissions, per subscription rather than on a single sample.
if ($Preflight)
{
    Write-Host ""
    Write-Host ("Preflight: probing data-phase permissions on {0} subscription(s)..." -f $Subscriptions.Count) -ForegroundColor Cyan
    # The probes switch the Az context per subscription; put it back afterwards so
    # a preflight leaves the operator's session exactly as it found it.
    $PreflightOriginalContext = Get-AzContext -ErrorAction SilentlyContinue
    # Subscriptions the Reader gate rejected are not in $Subscriptions any more;
    # list them first so the matrix shows WHY they are absent from a real run. An
    # inconclusive probe ('Unknown') renders as Unavailable, and the real run
    # hard-stops on it too (Resolve-AccessPreflight), so it blocks here as well.
    $MatrixRows = @()
    if ($PreflightInaccessible)
    {
        $MatrixRows += foreach ($NA in $PreflightInaccessible)
        {
            $ReaderState = if ($NA.State -eq 'Unknown') { 'Unavailable' } else { 'Denied' }
            [pscustomobject]@{ Name = $NA.Name; Id = $NA.Id; Reader = $ReaderState; CostManagement = 'Skipped'; Monitoring = 'Skipped' }
        }
    }
    $MatrixRows += foreach ($PfSub in $Subscriptions)
    {
        $ReaderState = 'Ok'
        $CostState = 'Skipped'
        if (-not $SkipConsumption)
        {
            $CostProbe = Test-ConsumptionAccess -SubscriptionId $PfSub.Id
            $CostState = $CostProbe.Outcome
            if ($CostProbe.Detail) { Write-Verbose ("[preflight] consumption {0}: {1}" -f $PfSub.Name, $CostProbe.Detail) }
        }
        $MonState = 'Skipped'
        if (-not $SkipMetrics)
        {
            $MonProbe = Test-MetricsAccess -SubscriptionId $PfSub.Id
            $MonState = $MonProbe.Outcome
            if ($MonProbe.Detail) { Write-Verbose ("[preflight] metrics {0}: {1}" -f $PfSub.Name, $MonProbe.Detail) }
        }
        [pscustomobject]@{ Name = $PfSub.Name; Id = $PfSub.Id; Reader = $ReaderState; CostManagement = $CostState; Monitoring = $MonState }
    }
    if ($PreflightOriginalContext) { try { $null = Set-AzContext -Context $PreflightOriginalContext -ErrorAction Stop } catch { Write-Verbose "[preflight] could not restore the original Az context" } }
    $Matrix = Format-PreflightMatrix -Rows @($MatrixRows)
    $CoverageBlocking = $false
    if ($PreflightCoverageMsg)
    {
        $CoverageBlocking = $true
        Write-Host ""
        Write-Host ("Coverage: {0}" -f $PreflightCoverageMsg) -ForegroundColor Red
        Write-Host "  A real run stops here unless -AllowPartialAccess is passed. Grant Reader at the tenant-root management group to make coverage verifiable." -ForegroundColor Red
    }
    if ($Subscriptions.Count -eq 0) { Write-Host "  (no subscription passed the Reader gate, so the data-phase columns could not be probed)" -ForegroundColor Yellow }
    Write-Host ""
    foreach ($Line in $Matrix.Lines) { Write-Host $Line -ForegroundColor $(if ($Line -match 'Denied') { 'Red' } else { 'Gray' }) }
    Write-Host ""
    if ($Matrix.Blocking -or $CoverageBlocking)
    {
        Write-Host "Preflight result: at least one requested permission is DENIED or coverage could not be verified. Fix the roles above (or pass the matching -Skip* switch), then run without -Preflight." -ForegroundColor Red
        Exit-Wrapper -Code 1
    }
    Write-Host "Preflight result: no denials. Nothing was collected; run again without -Preflight to start the inventory." -ForegroundColor Green
    Exit-Wrapper -Code 0
}

# Up-front consumption (billing) access gate: consumption is REQUESTED unless -SkipConsumption, so if the identity cannot read it every sub's consumption phase would fail and the report would silently miss the billing data the operator asked for - a HARD failure, caught fast here before spending time on inventory and metrics.
# Runs AFTER the access gate, so $Subscriptions[0] is already control-plane-readable and a 403 here is a genuine BILLING-RBAC denial (billing RBAC is usually tenant-uniform, so probe the FIRST sub). Hard-fail ONLY on a clear authorization denial; a transient/token error is NOT fatal here - that recoverable class is handled by the per-sub consumption phase. Mixed per-sub billing access -> use -SkipConsumption.
if (-not $SkipConsumption -and $Subscriptions.Count -gt 0)
{
    $ConsumptionProbeSub = $Subscriptions[0]
    Write-Host ("Verifying consumption (billing) access using subscription '{0}'..." -f $ConsumptionProbeSub.Name) -ForegroundColor Cyan
    $ConsumptionAccess = Test-ConsumptionAccess -SubscriptionId $ConsumptionProbeSub.Id
    if ($ConsumptionAccess.Outcome -eq 'Denied')
    {
        Write-Host ""
        Write-Host "ERROR: Consumption data was requested (no -SkipConsumption), but the signed-in identity is not authorized to read consumption/billing data." -ForegroundColor Red
        Write-Host ("Probed subscription: {0}" -f $ConsumptionProbeSub.Name) -ForegroundColor Red
        if (-not [string]::IsNullOrWhiteSpace($ConsumptionAccess.Detail))
        {
            Write-Host ("Reason: {0}" -f $ConsumptionAccess.Detail) -ForegroundColor Red
        }
        Write-Host "Grant this identity 'Cost Management Reader' (or 'Billing Reader' on the billing scope), or re-run with -SkipConsumption to inventory without billing data." -ForegroundColor Yellow
        Exit-Wrapper -Code 1
    }
    elseif ($ConsumptionAccess.Outcome -eq 'Unavailable')
    {
        Write-Host "WARNING: Could not verify consumption access up front (a transient/token issue, not an authorization denial). Continuing; per-subscription consumption health is reported at the end of the run." -ForegroundColor Yellow
        if (-not [string]::IsNullOrWhiteSpace($ConsumptionAccess.Detail))
        {
            Write-Host ("  Probe error (why it could not be verified): {0}" -f $ConsumptionAccess.Detail) -ForegroundColor DarkYellow
        }
    }
    else
    {
        Write-Host "Consumption access confirmed." -ForegroundColor Green
    }
}

# Up-front blob-upload WRITE probe: the earlier URI-format + Az.Storage checks prove the request is well-formed but NOT that this identity can WRITE to the target container. Without this, a missing "Storage Blob Data Contributor" role is only discovered by the best-effort upload at the very END - after a multi-hour run - stranding the whole output. So prove write+delete NOW (passwordless -UseConnectedAccount, the SAME path the real upload uses) and fail fast on a genuine authorization denial.
# A transient/token error is NOT fatal here (mirrors the consumption gate): it warns and continues, since the end-of-run upload and its warning still cover that recoverable class. The probe blob is namespaced + GUID-suffixed and removed best-effort, so it never collides with a real shard artifact.
if ($UploadToBlobContainerUri)
{
    Write-Host "Verifying blob-upload write access..." -ForegroundColor Cyan
    $BlobProbeFile = $null
    $BlobProbeContext = $null
    $BlobProbeName = $null
    $BlobProbeContainer = $null
    $BlobProbeWritten = $false
    try
    {
        # Shared parser (see Split-BlobContainerUri). The write probe MUST resolve
        # the account/container/prefix the same way the real upload does, or it
        # would confirm access to a different location than the one used later.
        $BlobProbeParts = Split-BlobContainerUri -Uri $UploadToBlobContainerUri
        $BlobProbeAccount = $BlobProbeParts.Account
        $BlobProbeContainer = $BlobProbeParts.Container
        $BlobProbePrefix = $BlobProbeParts.Prefix

        $BlobProbeName = '{0}_rda-upload-probe/{1}.txt' -f $BlobProbePrefix, ([guid]::NewGuid().ToString('N'))
        $BlobProbeFile = Join-Path ([System.IO.Path]::GetTempPath()) ('rda-upload-probe-{0}.txt' -f ([guid]::NewGuid().ToString('N')))
        Set-Content -LiteralPath $BlobProbeFile -Value 'rda upload access probe' -Encoding UTF8

        $BlobProbeContext = New-AzStorageContext -StorageAccountName $BlobProbeAccount -UseConnectedAccount -ErrorAction Stop
        # WRITE is the only capability the real upload uses, so it is the only thing the probe verifies (a successful write = access confirmed; the probe blob is then removed best-effort in the finally below). Do NOT require delete to succeed - the tool never deletes blobs in normal operation, so a delete-permission gap must not fail an otherwise-valid write-only identity.
        $null = Set-AzStorageBlobContent -File $BlobProbeFile -Container $BlobProbeContainer -Blob $BlobProbeName -Context $BlobProbeContext -Force -ErrorAction Stop
        $BlobProbeWritten = $true
        Write-Host ("Blob-upload access confirmed (wrote a probe blob in {0}/{1})." -f $BlobProbeAccount, $BlobProbeContainer) -ForegroundColor Green
    }
    catch
    {
        $BlobProbeErr = $_.Exception.Message
        # Fatal up front on a DETERMINISTIC misconfiguration - an authorization denial (missing role -> 403) OR a container that does not exist (mistyped -> 404) - because both would fail the real upload identically. A mistyped storage ACCOUNT surfaces as a name-resolution error, which falls into the transient class below (warn and continue; the end-of-run upload surfaces it), as does any other transient token/throttling error (mirrors the consumption gate).
        if ($BlobProbeErr -match 'AuthorizationPermissionMismatch|AuthorizationFailure|AuthorizationFailed|\b403\b|Forbidden|not authorized|does not have|ContainerNotFound|\b404\b|does not exist')
        {
            Write-Host ""
            Write-Host "ERROR: Blob upload was requested (-UploadToBlobContainerUri), but the target container could not be written to (missing 'Storage Blob Data Contributor' role, or the container does not exist)." -ForegroundColor Red
            Write-Host ("Reason: {0}" -f $BlobProbeErr) -ForegroundColor Red
            Write-Host "Grant this identity 'Storage Blob Data Contributor' and verify the storage account/container name is correct, or re-run without -UploadToBlobContainerUri to keep each zip node-local." -ForegroundColor Yellow
            Exit-Wrapper -Code 1
        }
        else
        {
            Write-Host "WARNING: Could not verify blob-upload access up front (a transient/token issue, not an authorization denial). Continuing; the upload at the end of the run is best-effort and will warn if it fails." -ForegroundColor Yellow
            Write-Host ("  Probe error (why it could not be verified): {0}" -f $BlobProbeErr) -ForegroundColor DarkYellow
        }
    }
    finally
    {
        # Best-effort cleanup: attempt to remove the probe blob if it was written,
        # and always remove the local temp file. This removal is cleanup only, NOT
        # a verified capability - the probe passes on write alone, so a delete-
        # permission gap simply leaves the tiny GUID-named probe blob behind and
        # never fails the run.
        if ($BlobProbeWritten -and $BlobProbeContext -and $BlobProbeName -and $BlobProbeContainer)
        {
            Remove-AzStorageBlob -Container $BlobProbeContainer -Blob $BlobProbeName -Context $BlobProbeContext -Force -ErrorAction SilentlyContinue
        }
        if ($BlobProbeFile -and (Test-Path -LiteralPath $BlobProbeFile)) { Remove-Item -LiteralPath $BlobProbeFile -Force -ErrorAction SilentlyContinue }
    }
}

# Auto-tune parallelism to the host: when the operator passes neither -ParallelStreams nor -ConcurrencyLimit, size them from detected CPU/RAM so an out-of-the-box run does the sensible thing (e.g. a small 2 vCPU / 4 GB box runs sequentially, which is faster there than two streams fighting over the cores). Any value passed explicitly is honored as-is; only the omitted one is auto-filled.
# $PSBoundParameters is a reliable "did the operator set this?" test here because the PS7 relaunch above forwards only bound params. The existing clamp to the eligible subscription count still applies below.
$AutoTune = Get-RecommendedParallelism
$StreamsAuto = -not $PSBoundParameters.ContainsKey('ParallelStreams')
$ConcurrencyAuto = -not $PSBoundParameters.ContainsKey('ConcurrencyLimit')
if ($StreamsAuto) { $ParallelStreams = $AutoTune.Streams }
if ($ConcurrencyAuto) { $ConcurrencyLimit = $AutoTune.Concurrency }

# API headroom: scale down the metrics-collection concurrency (the run's heaviest ARM / Azure Monitor consumer) to leave part of the shared Azure throttle budget for other/production workloads. Applies on top of whatever ConcurrencyLimit was chosen (auto-tuned OR explicit), and because $ConcurrencyLimit is the single value forwarded to the inner script and every stream, one reduction here propagates everywhere. No-op when -HeadRoom is 0.
if ($HeadRoom -gt 0)
{
    $ConcurrencyBeforeHeadroom = $ConcurrencyLimit
    $ConcurrencyLimit = Get-HeadroomAdjustedConcurrency -Concurrency $ConcurrencyLimit -HeadRoomPercent $HeadRoom
    Write-Host ("API headroom: -HeadRoom {0} -> ConcurrencyLimit {1} -> {2} (leaving ~{0}% of concurrency in reserve for other workloads)." -f $HeadRoom, $ConcurrencyBeforeHeadroom, $ConcurrencyLimit) -ForegroundColor DarkGray
}

# InvariantCulture, as for the -Plan copy above: captured in the wrapper transcript.
$RamLabel = if ($AutoTune.RamGB -gt 0) { '{0} GB RAM' -f $AutoTune.RamGB.ToString([cultureinfo]::InvariantCulture) } else { 'RAM undetected' }
$StreamsSrc = if ($StreamsAuto) { 'auto' } else { 'explicit' }
$ConcurrencySrc = if ($ConcurrencyAuto) { 'auto' } else { 'explicit' }
# Reflect the headroom reduction in the source label so the single-line
# "Parallelism:" summary is not misread as the full un-reduced concurrency.
if ($HeadRoom -gt 0) { $ConcurrencySrc = '{0}, -HeadRoom {1}' -f $ConcurrencySrc, $HeadRoom }
Write-Host ("Host: {0} vCPU / {1}." -f $AutoTune.VCpu, $RamLabel) -ForegroundColor DarkGray
Write-Host ("Parallelism: -ParallelStreams {0} ({1}), -ConcurrencyLimit {2} ({3}). Pass either flag to override." -f $ParallelStreams, $StreamsSrc, $ConcurrencyLimit, $ConcurrencySrc) -ForegroundColor DarkGray

# Background-job capability guard: the parallel-streams path below launches each stream with Start-Job (a child pwsh process). Under a system-wide application-control policy (WDAC/AppLocker/__PSLockdownPolicy) the session can be FullLanguage while the machine enforces ConstrainedLanguage, so Start-Job throws synchronously and NO stream process is ever created - the run ends having produced nothing. Detect that up front and fall back to the sequential path (which never calls Start-Job) so a locked-down host still gets a full report, just single-threaded.
# Only probe when parallelism would actually be used (the auto-tuner can select >1 without the operator asking, so this also covers the out-of-the-box case).
if ($ParallelStreams -gt 1 -and -not (Test-BackgroundJobSupport))
{
    Write-Host ""
    Write-Host "WARNING: PowerShell background jobs (Start-Job) are unavailable in this session." -ForegroundColor Yellow
    Write-Host "         This host enforces a system-wide language-mode / application-control policy" -ForegroundColor Yellow
    Write-Host "         (WDAC / AppLocker) that is incompatible with Start-Job, so parallel streams" -ForegroundColor Yellow
    Write-Host "         cannot launch here. Falling back to the SEQUENTIAL path (one subscription at a" -ForegroundColor Yellow
    Write-Host "         time). The report content is identical - only slower. Pass -ParallelStreams 1" -ForegroundColor Yellow
    Write-Host "         explicitly to select the sequential path up front and silence this notice." -ForegroundColor Yellow
    Write-Host ""
    $ParallelStreams = 1
}

# Normalize the -Service filter (comma token / array, trim, de-dupe) then
# fail FAST if any requested collector name is unknown - otherwise every
# subscription's inner run would throw the same "matched no collectors" error.
# Mirrors ResourceInventory.ps1's own -Service validation, but up front and once.
$Service = Expand-ServiceFilter -Service $Service
if ($Service.Count -gt 0)
{
    $AvailableServices = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'Services') -Filter '*.ps1' -Recurse | ForEach-Object { $_.BaseName } | Sort-Object -Unique)
    $UnknownServices = @($Service | Where-Object { $_ -notin $AvailableServices })
    if ($UnknownServices.Count -gt 0)
    {
        Write-Host ("ERROR: -Service contains unknown collector name(s): [{0}]." -f ($UnknownServices -join ', ')) -ForegroundColor Red
        Write-Host ("Valid collector names: [{0}]" -f ($AvailableServices -join ', ')) -ForegroundColor Yellow
        Exit-Wrapper -Code 1
    }
    Write-Host ("Service filter active: collecting ONLY [{0}] across all in-scope subscriptions." -f ($Service -join ', ')) -ForegroundColor Cyan

    # -Service scopes the INVENTORY phase only; metrics and consumption still run for the WHOLE subscription. ResourceInventory.ps1 warns about this too but suppresses it under -RunAllSubs (it is invoked once per sub and the identical warning would repeat N times), so this is the once-up-front copy, emitted where the argument set is already known.
    # Per-phase accurate for the same reason as the inner one: a run that already passed a skip must not be told that phase still runs. Advisory only - the skips are NOT enforced, because the recovery recipe for a later Merge-RecoveryData intentionally runs -Service WITHOUT them.
    $UnscopedPhases = @()
    $SuggestedSkips = @()

    if (-not $SkipMetrics.IsPresent)
    {
        $UnscopedPhases += 'metrics'
        $SuggestedSkips += '-SkipMetrics'
    }

    if (-not $SkipConsumption.IsPresent)
    {
        $UnscopedPhases += 'consumption'
        $SuggestedSkips += '-SkipConsumption'
    }

    if (@($UnscopedPhases).Count -gt 0)
    {
        Write-Warning ("-Service scopes the INVENTORY phase only; these phases still run for the WHOLE subscription, for every subscription in scope: {0}. For a clean inventory-only run add {1}. (Ignore this if you are deliberately re-collecting for a later Merge-RecoveryData.)" -f ($UnscopedPhases -join ', '), ($SuggestedSkips -join ' '))
    }
}

# Build passthrough hashtable for optional switches
$InventoryPassthrough = @{}
if ($DeviceLogin) { $InventoryPassthrough['DeviceLogin'] = $true }
if ($Obfuscate) { $InventoryPassthrough['Obfuscate'] = $true }
if ($SkipMetrics) { $InventoryPassthrough['SkipMetrics'] = $true }
if ($SkipConsumption) { $InventoryPassthrough['SkipConsumption'] = $true }
if ($UseMetricsBatch) { $InventoryPassthrough['UseMetricsBatch'] = $true }
if ($IncludeStorageMetrics) { $InventoryPassthrough['IncludeStorageMetrics'] = $true }
if ($SkipDiskMetrics) { $InventoryPassthrough['SkipDiskMetrics'] = $true }
if ($MetricsDetailed) { $InventoryPassthrough['MetricsDetailed'] = $true }
if ($CapacityPlan) { $InventoryPassthrough['CapacityPlan'] = $true }
if ($MetricsIntervalMinutes -gt 0) { $InventoryPassthrough['MetricsIntervalMinutes'] = $MetricsIntervalMinutes }
# ContainsKey rather than a value sentinel: 0 is a REAL (and harmful) lookback
# value, not "unset", so -gt 0 would silently swallow it. Omitted -> the key is
# absent -> the inner script's 31-day default stands, byte-identical to before.
if ($PSBoundParameters.ContainsKey('MetricsLookbackDays')) { $InventoryPassthrough['MetricsLookbackDays'] = $MetricsLookbackDays }
if ($Service.Count -gt 0) { $InventoryPassthrough['Service'] = $Service }
# Always forward ConcurrencyLimit so the operator can tune metrics-phase
# throttling end-to-end from a single param instead of editing the inner
# script's default. Defaults to 6 (the inner script's existing default), so
# behavior is unchanged for runs that don't pass it.
$InventoryPassthrough['ConcurrencyLimit'] = $ConcurrencyLimit
# [bool] rather than a literal $true so an explicit -Debug:$false is honoured
# rather than inverted into $true. Matches the parallel path's forward above.
if ($PSBoundParameters.ContainsKey('Debug')) { $InventoryPassthrough['Debug'] = [bool]$PSBoundParameters['Debug'] }

# Loop through each subscription and run ResourceInventory
$SkippedCount = 0
$DiagFile = $null
# Per-subscription resource counts collected for the final summary so the user
# can see at a glance which subscriptions came back empty (the most common
# explanation is that the signed-in identity does not have Reader on the
# subscription, but it can also legitimately mean the subscription is empty).
$SubResourceCounts = @()

# Capture the in-scope (eligible, post-shard, post-access-gate) subscription COUNT now, before the first ResourceInventory.ps1 call, into a variable the inner script cannot clobber: the inner script sets $Global:Subscriptions to the full tenant list on every invocation, and when this wrapper is the entry script its top-level $Subscriptions IS that global, so the first sequential in-process `&` call overwrites our filtered/sharded list back to the whole tenant.
# The processing foreach is unaffected (it snapshots its collection at loop start), but the post-loop summary counts would otherwise read the clobbered global (e.g. a shard that processed 2 of 3 subs wrongly reporting 3). Parallel-streams mode runs the inner script in child processes, so the parent global is untouched there - capturing here is correct for both paths.
$EligibleCount = @($Subscriptions).Count

if ($ParallelStreams -le 1)
{
    # === SEQUENTIAL PATH (default) ============================================
    # Original behavior, unchanged. Selected when -ParallelStreams 1 or unset.
    $SubTotal = @($Subscriptions).Count
    $SubIndex = 0
    foreach ($Sub in $Subscriptions)
    {
        $SubIndex++
        # Unified progress reporter: interactive bar + non-interactive line. Counts
        # every subscription (including resume-skipped ones) so the position in the
        # list is accurate. See Write-RdaProgress in Functions/Common.Functions.ps1.
        Write-RdaProgress -Activity 'Processing subscriptions' -CurrentItem $Sub.Name -Index $SubIndex -Total $SubTotal
        if ($Resume -and ($CompletedIds -contains $Sub.Id))
        {
            Write-Host ("Skipping (already completed): {0} ({1})" -f $Sub.Name, $Sub.Id) -ForegroundColor DarkGray
            $SkippedCount++
            continue
        }

        Write-Host "Processing subscription: $($Sub.Name) ($($Sub.Id))" -ForegroundColor Cyan

        try
        {
            # Clear $LASTEXITCODE first: it is SHARED and STICKY, and the inner script is invoked with `&` in this same runspace, so a completion path that never calls `exit` leaves the PREVIOUS sub's value in place - making one non-zero sub mark every LATER sub in the loop as failed too. Reset per iteration so the check reflects only the invocation that just returned.
            # $Global:ZipOutputFile is sticky in exactly the same way and is cleared to $null for the same reason: the inner script has early gates that leave with a bare `Exit` (code 0) before computing an archive path, so without this reset such a sub would carry the PREVIOUS sub's archive path and pass output verification "by exact path" against another sub's file. $null classes the row unverifiable rather than falsely verified.
            $global:LASTEXITCODE = 0
            $Global:ZipOutputFile = $null
            & (Join-Path $PSScriptRoot "ResourceInventory.ps1") -TenantID $TenantID -SubscriptionID $Sub.Id @InventoryPassthrough -RunAllSubs
            # Only treat as failure if the inner script set a non-zero exit code.
            # Some completion paths leave $LASTEXITCODE unset ($null), and
            # PowerShell's `-ne 0` returns $true against $null - which would
            # spuriously fail every successful sub.
            if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0)
            {
                # Inner code 2 == the report archive could not be written, so a
                # report is missing rather than merely uncollected. Recorded before
                # the throw because the catch below cannot see $LASTEXITCODE
                # reliably once other commands have run.
                if ($LASTEXITCODE -eq 2) { $ArchiveWriteFailures += ("{0} ({1})" -f $Sub.Name, $Sub.Id) }
                throw "Script exited with code $LASTEXITCODE"
            }

            # Capture the per-subscription resource count from the inner script.
            # ResourceInventory.ps1 invokes via `& <path>` so its $Global:Resources
            # lives in this wrapper's scope. The inner script resets that variable
            # to @() at the start of every invocation, so the count after return
            # accurately reflects the subscription that just finished.
            $ResCount = if ($null -ne $Global:Resources) { @($Global:Resources).Count } else { 0 }
            # Capture the exact archive the inner script wrote, for the same
            # same-scope reason as $Global:Resources above. The output verification
            # gate further down tests THIS path so it can name the subscription
            # that lost its report, instead of only reporting a count gap the
            # operator then has to track down by hand.
            $SubResourceCounts += [pscustomobject]@{
                Name  = $Sub.Name
                Id    = $Sub.Id
                Count = $ResCount
                Zip   = $Global:ZipOutputFile
            }

            if ($ResCount -eq 0)
            {
                # Loud yellow signal so this stands out in the per-iteration narration and the wrapper transcript. The most common cause is the signed-in identity not having Reader on the subscription; second is a sub that genuinely has no resources. Either way the operator wants to know immediately rather than discover it when the consolidated report turns out empty for some subs.
                Write-Host ("WARNING: Subscription '{0}' returned 0 resources. Likely permission gap (no Reader on the subscription) or a genuinely empty subscription. Verify with: Search-AzGraph -Query 'resources | summarize count()' -Subscription {1}" -f $Sub.Name, $Sub.Id) -ForegroundColor Yellow
            }
            else
            {
                Write-Host ("Resources collected: {0:N0}" -f $ResCount) -ForegroundColor DarkGreen
            }

            Write-Host "Completed subscription: $($Sub.Name)" -ForegroundColor Green

            # Mark complete and persist immediately so a mid-run sign-out is recoverable.
            # If the sub was previously in FailedAttempts (i.e. this is a retry that
            # finally succeeded), remove its entry so the resume-state file reflects
            # current truth.
            $StateChanged = $false
            if (-not ($CompletedIds -contains $Sub.Id))
            {
                $CompletedIds += $Sub.Id
                $StateChanged = $true
            }
            $BeforeFailedCount = @($FailedAttempts).Count
            $FailedAttempts = Remove-FailedAttempt -Existing $FailedAttempts -Id $Sub.Id
            if (@($FailedAttempts).Count -ne $BeforeFailedCount) { $StateChanged = $true }
            if ($StateChanged)
            {
                Save-CompletedSubscriptionIds -Path $ResumeStateFile -Tenant $TenantID -Ids $CompletedIds -FailedAttempts $FailedAttempts @StateSaveArgs
            }
        }
        catch
        {
            # Surface the full exception chain so failures (e.g. report/JSON write
            # errors, OOM in long CloudShell runs, file-handle leaks) are
            # diagnosable instead of being summarised to a single line. See #16.
            $ErrRecord = $_
            Write-Host "ERROR processing subscription $($Sub.Name): $ErrRecord" -ForegroundColor Red

            $DiagLines = @()
            $DiagLines += "==== Failure for subscription: $($Sub.Name) ($($Sub.Id)) ===="
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

            # Environment snapshot — useful when CloudShell runs out of memory or disk
            try
            {
                $Proc = Get-Process -Id $PID
                $DiagLines += "Process WorkingSet (MB):  $([math]::Round($Proc.WorkingSet64 / 1MB, 1))"
                $DiagLines += "Process PrivateMemory (MB): $([math]::Round($Proc.PrivateMemorySize64 / 1MB, 1))"
            }
            catch { Write-Verbose ("Process snapshot failed: {0}" -f $_.Exception.Message) }

            try
            {
                # Read the root this run actually RESOLVED (pinned by the resolver at
                # startup) instead of recomputing "$HOME/InventoryReports" here. When
                # the preferred location was unwritable and the run fell back, the old
                # inline copy measured free space on a directory this run never used.
                $DiagRoot = if (-not [string]::IsNullOrWhiteSpace($env:RDA_INVENTORY_ROOT)) { $env:RDA_INVENTORY_ROOT } else { $InventoryRoot }
                if (-not [string]::IsNullOrWhiteSpace($DiagRoot) -and (Test-Path -LiteralPath $DiagRoot))
                {
                    $RootDrive = (Get-Item -LiteralPath $DiagRoot).PSDrive
                    if ($RootDrive)
                    {
                        $DiagLines += "Free disk on $($RootDrive.Name): (MB): $([math]::Round($RootDrive.Free / 1MB, 1))"
                    }
                }
            }
            catch { Write-Verbose ("Disk snapshot failed: {0}" -f $_.Exception.Message) }

            $DiagLines += ""

            # Write to a per-run failures file so we don't lose the detail when many subs fail.
            if ($null -eq $DiagFile)
            {
                # Same reason as the disk snapshot above: use the RESOLVED root so the
                # failures log lands beside the run's other artefacts rather than in a
                # directory the run fell back away from (or could not create at all).
                $FailRoot = if (-not [string]::IsNullOrWhiteSpace($env:RDA_INVENTORY_ROOT)) { $env:RDA_INVENTORY_ROOT } else { $InventoryRoot }
                if ([string]::IsNullOrWhiteSpace($FailRoot))
                {
                    $Resolved = Get-RdaInventoryRoot
                    if ($Resolved.Ok) { $FailRoot = $Resolved.Path }
                }
                if (-not [string]::IsNullOrWhiteSpace($FailRoot) -and -not (Test-Path -LiteralPath $FailRoot))
                {
                    try { New-Item -ItemType Directory -Path $FailRoot -Force -ErrorAction Stop | Out-Null }
                    catch { Write-Host ("WARNING: could not create {0} for the failures log: {1}" -f $FailRoot, $_.Exception.Message) -ForegroundColor Yellow }
                }
                $DiagFile = Join-Path $FailRoot ("RunAllSubscriptions_failures_{0}_{1}.log" -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss-fff'), [guid]::NewGuid().ToString().Substring(0, 4))
            }
            try { $DiagLines | Out-File -LiteralPath $DiagFile -Append -Encoding utf8 }
            catch { Write-Verbose ("DiagFile write failed at {0}: {1}" -f $DiagFile, $_.Exception.Message) }

            $FailedSubscriptions += $Sub.Name
            # Persist the failure to the resume-state file so a future run with
            # -ResumeFailedOnly can target it. Use the exception message as the
            # Reason so the operator can see at a glance why each sub failed
            # without opening the diag log.
            $FailedAttempts = Add-FailedAttempt -Existing $FailedAttempts `
                -Id $Sub.Id -Name $Sub.Name `
                -Reason $ErrRecord.Exception.Message
            Save-CompletedSubscriptionIds -Path $ResumeStateFile -Tenant $TenantID -Ids $CompletedIds -FailedAttempts $FailedAttempts @StateSaveArgs
        }

        Write-Host "-----------------------------------" -ForegroundColor Gray
    }

    Write-RdaProgress -Activity 'Processing subscriptions' -Completed

}
else
{
    # === PARALLEL-STREAMS PATH: each "stream" is a separate `pwsh` background job (Start-Job runs the ScriptBlock in a fresh process). Process-level isolation is what makes this safe - the inner script's Set-AzContext -Subscription (consumption phase) mutates PROCESS-GLOBAL Az state, so two streams in one process would race contexts and silently cross-contaminate consumption data.
    # Each stream owns its own subscription slice, its own resume-state file (.resume-state-<TenantID>-stream-<N>.json), its own summary JSON (the parent aggregates), and its own failures log. All streams share ONE parent-written Az context snapshot (Save-/Import-AzContext) - the only way to avoid an interactive sign-in per child - removed after all streams finish. Output is interleaved, each line prefixed [stream-N].

    $StreamCount = [Math]::Min($ParallelStreams, $Subscriptions.Count)
    Write-Host ""
    Write-Host ("Parallel-streams mode: {0} streams across {1} eligible subscription(s)" -f $StreamCount, $Subscriptions.Count) -ForegroundColor Cyan
    if ($ParallelStreams -gt $Subscriptions.Count)
    {
        Write-Host ("Note: -ParallelStreams {0} clamped to {1} (one stream per subscription is the practical limit)." -f $ParallelStreams, $StreamCount) -ForegroundColor DarkGray
    }
    Write-Host "Each stream is a separate pwsh background job with its own Az context and resume-state file." -ForegroundColor DarkGray
    Write-Host ""

    if ($StreamCount -le 1)
    {
        # User asked for parallel but only one (or zero) sub is eligible.
        # Process it inline using the same per-sub logic the sequential
        # branch uses, instead of bailing and asking the user to re-run.
        Write-Host "Only one eligible subscription; running sequentially." -ForegroundColor Yellow
        if ($Subscriptions.Count -gt 0)
        {
            $Sub = $Subscriptions[0]
            Write-Host "Processing subscription: $($Sub.Name) ($($Sub.Id))" -ForegroundColor Cyan
            try
            {
                # Same sticky-$LASTEXITCODE / $Global:ZipOutputFile resets as the
                # sequential branch above.
                $global:LASTEXITCODE = 0
                $Global:ZipOutputFile = $null
                & (Join-Path $PSScriptRoot "ResourceInventory.ps1") -TenantID $TenantID -SubscriptionID $Sub.Id @InventoryPassthrough -RunAllSubs
                # Same null-guard and archive-failure capture as the sequential
                # branch above.
                if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0)
                {
                    if ($LASTEXITCODE -eq 2) { $ArchiveWriteFailures += ("{0} ({1})" -f $Sub.Name, $Sub.Id) }
                    throw "Script exited with code $LASTEXITCODE"
                }
                $ResCount = if ($null -ne $Global:Resources) { @($Global:Resources).Count } else { 0 }
                $SubResourceCounts += [pscustomobject]@{ Name = $Sub.Name; Id = $Sub.Id; Count = $ResCount; Zip = $Global:ZipOutputFile }
                if ($ResCount -eq 0)
                {
                    Write-Host ("WARNING: '{0}' returned 0 resources." -f $Sub.Name) -ForegroundColor Yellow
                }
                else
                {
                    Write-Host ("Resources collected: {0:N0}" -f $ResCount) -ForegroundColor DarkGreen
                }
                if (-not ($CompletedIds -contains $Sub.Id))
                {
                    $CompletedIds += $Sub.Id
                    $FailedAttempts = Remove-FailedAttempt -Existing $FailedAttempts -Id $Sub.Id
                    Save-CompletedSubscriptionIds -Path $ResumeStateFile -Tenant $TenantID -Ids $CompletedIds -FailedAttempts $FailedAttempts @StateSaveArgs
                }
            }
            catch
            {
                # Match the sequential branch's diagnostic detail so users do not
                # get a degraded error report when -ParallelStreams collapses to a
                # single subscription. Mirrors the catch handler around line 615.
                $ErrRecord = $_
                Write-Host ("ERROR processing subscription {0}: {1}" -f $Sub.Name, $ErrRecord) -ForegroundColor Red
                $DiagLines = @()
                $DiagLines += "==== Failure for subscription: $($Sub.Name) ($($Sub.Id)) ===="
                $DiagLines += "Timestamp: $(Get-Date -Format 'o')"
                $DiagLines += "Message:   $($ErrRecord.Exception.Message)"
                $DiagLines += "Type:      $($ErrRecord.Exception.GetType().FullName)"
                $DiagLines += "StackTrace:"
                $DiagLines += $ErrRecord.ScriptStackTrace
                $DiagLines += ""
                if ($null -eq $DiagFile)
                {
                    $DiagFile = Join-Path $InventoryRoot ("RunAllSubscriptions_failures_{0}_{1}.log" -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss-fff'), [guid]::NewGuid().ToString().Substring(0, 4))
                }
                try { $DiagLines | Out-File -LiteralPath $DiagFile -Append -Encoding utf8 }
                catch { Write-Verbose ("DiagFile write failed at {0}: {1}" -f $DiagFile, $_.Exception.Message) }
                $FailedSubscriptions += $Sub.Name
                # Mirror the sequential branch: persist failure to the
                # resume-state file so -ResumeFailedOnly works even for the
                # single-sub-collapses-to-inline corner case.
                $FailedAttempts = Add-FailedAttempt -Existing $FailedAttempts `
                    -Id $Sub.Id -Name $Sub.Name `
                    -Reason $ErrRecord.Exception.Message
                Save-CompletedSubscriptionIds -Path $ResumeStateFile -Tenant $TenantID -Ids $CompletedIds -FailedAttempts $FailedAttempts @StateSaveArgs
            }
        }
        # Skip the parallel orchestration entirely; fall through to the
        # post-processing (consolidation, summary) below.
        $StreamCount = 0
    }
    if ($StreamCount -ge 2)
    {

        # Snapshot the parent's Az context to a shared file so each stream can Import-AzContext without prompting. Save-AzContext writes a JSON file containing a TOKEN CACHE, so it MUST NOT be left on disk after the run - that is the responsibility of the `finally` block below, which guarantees cleanup even on stream-launch crash, Receive-Job failure, or Ctrl+C.
        $AzContextSnapshot = Join-Path $InventoryRoot (".rda-stream-azcontext-{0}.json" -f ([guid]::NewGuid().ToString()))
        try
        {
            Save-AzContext -Path $AzContextSnapshot -Force -ErrorAction Stop | Out-Null
        }
        catch
        {
            Write-Host ("ERROR: could not snapshot Az context for stream workers: {0}" -f $_.Exception.Message) -ForegroundColor Red
            Write-Host "Re-run without -ParallelStreams to use the sequential code path." -ForegroundColor Yellow
            # No snapshot was successfully written, so no security cleanup needed -
            # but Save-AzContext can write a partial file before throwing on some
            # error paths, so still try to remove it.
            if (Test-Path -LiteralPath $AzContextSnapshot)
            {
                try { Remove-Item -LiteralPath $AzContextSnapshot -Force }
                catch { Write-Verbose ("Could not remove partial Az context snapshot: {0}" -f $_.Exception.Message) }
            }
            Exit-Wrapper -Code 1
        }

        # Everything from here until the matching `finally` is the orchestration
        # body. The `finally` guarantees the Az context snapshot is always wiped
        # AND that any background jobs are cleaned up, which is the primary
        # reason for this try/finally structure.
        # Declared outside the try so the finally can always see them.
        $Jobs = @()
        $StreamSummaries = @()
        try
        {
            $WorkerScript = Join-Path $PSScriptRoot 'Run-AllSubscriptions.Stream.ps1'
            if (-not (Test-Path -LiteralPath $WorkerScript -PathType Leaf))
            {
                Write-Host ("ERROR: parallel worker script not found at {0}." -f $WorkerScript) -ForegroundColor Red
                Write-Host "Make sure Run-AllSubscriptions.Stream.ps1 is present alongside Run-AllSubscriptions.ps1, or re-run without -ParallelStreams." -ForegroundColor Yellow
                Exit-Wrapper -Code 1
            }

            # Round-robin split: sub 0 -> stream 0, sub 1 -> stream 1, ..., sub N -> stream (N % StreamCount).
            # This balances the slices regardless of how subscription sizes vary,
            # and keeps slices roughly the same length even when the total
            # subscription count is not evenly divisible by StreamCount.
            $Slices = @()
            for ($i = 0; $i -lt $StreamCount; $i++)
            {
                $Slices += , (New-Object 'System.Collections.Generic.List[object]')
            }
            for ($i = 0; $i -lt $Subscriptions.Count; $i++)
            {
                $Slices[$i % $StreamCount].Add($Subscriptions[$i])
            }

            # Build per-stream output paths up front so we know where to look later.
            for ($S = 0; $S -lt $StreamCount; $S++)
            {
                $SliceList = $Slices[$S]
                $SliceIds = @($SliceList | ForEach-Object { $_.Id })
                $SliceNames = @($SliceList | ForEach-Object { $_.Name })

                $SummaryPath = Join-Path $InventoryRoot (".rda-stream-{0}-summary.json" -f $S)
                $FailuresPath = Join-Path $InventoryRoot ("RunAllSubscriptions_failures_{0}_stream-{1}.log" -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'), $S)

                $StreamSummaries += [pscustomobject]@{
                    StreamId     = $S
                    SummaryPath  = $SummaryPath
                    FailuresPath = $FailuresPath
                    SubCount     = $SliceList.Count
                }

                Write-Host ("[stream-{0}] queued: {1} subscription(s)" -f $S, $SliceList.Count) -ForegroundColor DarkCyan

                # Pass worker arguments as a single hashtable so its named parameters bind correctly: Start-Job's -FilePath mode passes ArgumentList POSITIONALLY, which collides with our named-parameter contract. Switches are included only when set, since a switch binds correctly from a splatted hashtable when present with value $true.
                $WorkerArgs = @{
                    TenantID           = $TenantID
                    StreamId           = [string]$S
                    InventoryRoot      = $InventoryRoot
                    ScriptRoot         = $PSScriptRoot
                    AzContextPath      = $AzContextSnapshot
                    StreamSummaryPath  = $SummaryPath
                    StreamFailuresPath = $FailuresPath
                    SubscriptionIds    = $SliceIds
                    SubscriptionNames  = $SliceNames
                    ConcurrencyLimit   = $ConcurrencyLimit
                }
                if ($Resume) { $WorkerArgs.Resume = $true }
                if ($ResumeFailedOnly) { $WorkerArgs.ResumeFailedOnly = $true }
                if ($DeviceLogin) { $WorkerArgs.DeviceLogin = $true }
                if ($Obfuscate) { $WorkerArgs.Obfuscate = $true }
                if ($SkipMetrics) { $WorkerArgs.SkipMetrics = $true }
                if ($SkipConsumption) { $WorkerArgs.SkipConsumption = $true }
                if ($UseMetricsBatch) { $WorkerArgs.UseMetricsBatch = $true }
                if ($IncludeStorageMetrics) { $WorkerArgs.IncludeStorageMetrics = $true }
                if ($SkipDiskMetrics) { $WorkerArgs.SkipDiskMetrics = $true }
                if ($MetricsDetailed) { $WorkerArgs.MetricsDetailed = $true }
                if ($CapacityPlan) { $WorkerArgs.CapacityPlan = $true }
                if ($MetricsIntervalMinutes -gt 0) { $WorkerArgs.MetricsIntervalMinutes = $MetricsIntervalMinutes }
                # NOT a key in the $WorkerArgs literal above: this form is what
                # Tests/ParamForwardingParity.Tests.ps1 harvests, and widening the
                # aligned literal would re-indent ConcurrencyLimit and break that
                # test's headroom-ordering probe.
                if ($PSBoundParameters.ContainsKey('MetricsLookbackDays')) { $WorkerArgs.MetricsLookbackDays = $MetricsLookbackDays }
                if ($Service.Count -gt 0) { $WorkerArgs.Service = $Service }
                # -Debug must be forwarded EXPLICITLY: background jobs do not inherit the parent's preference variables, so without this line the flag is accepted and silently dropped for every stream (which is exactly what happened - the sequential path forwarded it while -ParallelStreams produced no inner debug output).
                # [bool] rather than ContainsKey alone so an explicit -Debug:$false is honoured instead of being inverted into $true.
                if ($PSBoundParameters.ContainsKey('Debug')) { $WorkerArgs.Debug = [bool]$PSBoundParameters['Debug'] }
                # Forward the state-blob container + shard identity so each worker
                # mirrors its per-stream resume state to a shard+stream-namespaced
                # blob for AKS pod-reschedule durability. Omitted -> worker stays
                # local-only. ShardIndex/ShardCount are only meaningful for the
                # blob name, so they ride along only when the container is set.
                if ($StateBlobContainerUri)
                {
                    $WorkerArgs.StateBlobContainerUri = $StateBlobContainerUri
                    $WorkerArgs.ShardIndex = $ShardIndex
                    $WorkerArgs.ShardCount = $ShardCount
                }

                $Jobs += Start-Job -ScriptBlock {
                    param($WorkerScript, $WorkerArgs)
                    & $WorkerScript @WorkerArgs
                } -ArgumentList @($WorkerScript, $WorkerArgs)
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
            # Drain output once before the polling loop, in case every stream
            # finished (or crashed) synchronously between Start-Job and our first
            # poll: jobs reach Completed state in <1500 ms, so the loop predicate
            # would otherwise be false on first check and we would skip output
            # streaming entirely.
            $Jobs | Receive-Job
            # Explicit count check is safer than truthiness on the Where-Object
            # result: when zero jobs match, Where-Object returns $null which is
            # falsy, but when one matches it returns a single non-array object
            # whose truthiness varies by PowerShell edition. @(...).Count is
            # always an integer.
            while (@($Jobs | Where-Object { $_.State -eq 'Running' }).Count -gt 0)
            {
                $Jobs | Receive-Job
                Start-Sleep -Milliseconds 1500
            }
            # Drain anything still buffered after all jobs reached terminal state.
            $Jobs | Receive-Job

            # Capture exit codes and any errors from the jobs themselves before removing.
            foreach ($j in $Jobs)
            {
                if ($j.State -ne 'Completed')
                {
                    Write-Host ("[stream-{0}] job ended in state {1}" -f $j.Id, $j.State) -ForegroundColor Yellow
                }
            }
            # Job cleanup is in the `finally` block below so it runs even if any
            # exception was raised during Receive-Job polling or aggregation.

            # Aggregate per-stream summaries into the wrapper's existing
            # accumulators so the consolidated summary at end-of-run looks the
            # same shape as a sequential run.
            foreach ($S in $StreamSummaries)
            {
                if (-not (Test-Path -LiteralPath $S.SummaryPath -PathType Leaf))
                {
                    Write-Host ("[stream-{0}] WARNING: no summary file at {1} - the stream did not finish cleanly" -f $S.StreamId, $S.SummaryPath) -ForegroundColor Yellow
                    $FailedSubscriptions += ("stream-{0} (no summary)" -f $S.StreamId)
                    continue
                }
                try
                {
                    $StreamSummary = Get-Content -LiteralPath $S.SummaryPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                }
                catch
                {
                    Write-Host ("[stream-{0}] ERROR: could not parse summary file {1}: {2}" -f $S.StreamId, $S.SummaryPath, $_.Exception.Message) -ForegroundColor Red
                    $FailedSubscriptions += ("stream-{0} (corrupt summary)" -f $S.StreamId)
                    continue
                }

                # Surface stream-level failures (failed-to-start, etc.) so the
                # wrapper transcript distinguishes "the whole stream broke" from
                # "the stream ran fine but some subs in it failed". Per-sub
                # failures are still folded into $FailedSubscriptions via the
                # streamSummary.Failed enumeration below.
                if ($StreamSummary.Status -and $StreamSummary.Status -ne 'ok' -and $StreamSummary.Status -ne 'partial-failure')
                {
                    $ReasonText = if ($StreamSummary.Reason) { $StreamSummary.Reason } else { '(no reason given)' }
                    Write-Host ("[stream-{0}] stream status: {1} - {2}" -f $S.StreamId, $StreamSummary.Status, $ReasonText) -ForegroundColor Red
                }

                if ($StreamSummary.ResourceCounts)
                {
                    foreach ($rc in $StreamSummary.ResourceCounts)
                    {
                        if ($null -eq $rc) { continue }
                        # Zip may be absent from a summary written by an older
                        # build; the output verification gate treats an empty path
                        # as unverifiable rather than missing, and falls back to
                        # the count comparison for those rows.
                        $SubResourceCounts += [pscustomobject]@{
                            Name  = $rc.Name
                            Id    = $rc.Id
                            Count = [int]$rc.Count
                            Zip   = $rc.Zip
                        }
                    }
                }

                if ($StreamSummary.Failed)
                {
                    foreach ($f in $StreamSummary.Failed)
                    {
                        $FailedSubscriptions += ("{0} (stream-{1}: {2})" -f $f.Name, $S.StreamId, $f.Reason)
                    }
                }

                if ($null -ne $StreamSummary.ConsumptionRecords)
                {
                    if ($null -eq $Global:ConsumptionRecordCount) { $Global:ConsumptionRecordCount = 0 }
                    $Global:ConsumptionRecordCount = [int]$Global:ConsumptionRecordCount + [int]$StreamSummary.ConsumptionRecords
                }

                if ($null -ne $StreamSummary.MetricsApiCalls)
                {
                    if ($null -eq $Global:MetricsApiCallCount) { $Global:MetricsApiCallCount = 0 }
                    $Global:MetricsApiCallCount = [int]$Global:MetricsApiCallCount + [int]$StreamSummary.MetricsApiCalls
                }
                if ($StreamSummary.ConsumptionFailedSubs -and $StreamSummary.ConsumptionFailedSubs.Count -gt 0)
                {
                    if ($null -eq $Global:ConsumptionFailedSubs) { $Global:ConsumptionFailedSubs = @() }
                    $Global:ConsumptionFailedSubs += @($StreamSummary.ConsumptionFailedSubs)
                }

                if ($StreamSummary.MetricsFailedSubs -and $StreamSummary.MetricsFailedSubs.Count -gt 0)
                {
                    if ($null -eq $Global:MetricsFailedSubs) { $Global:MetricsFailedSubs = @() }
                    $Global:MetricsFailedSubs += @($StreamSummary.MetricsFailedSubs)
                }

                if ($StreamSummary.CollectorFailures -and $StreamSummary.CollectorFailures.Count -gt 0)
                {
                    if ($null -eq $Global:CollectorFailures) { $Global:CollectorFailures = @() }
                    $Global:CollectorFailures += @($StreamSummary.CollectorFailures)
                }
                # Absent from a summary written by an older build, in which case a
                # lost archive still surfaces as a failed subscription - just not in
                # the exit code.
                if ($StreamSummary.ArchiveWriteFailures -and $StreamSummary.ArchiveWriteFailures.Count -gt 0)
                {
                    $ArchiveWriteFailures += @($StreamSummary.ArchiveWriteFailures)
                }

                # If a stream wrote a failures log, add it to the wrapper's diag-file
                # accumulator so the final summary surfaces the path. The wrapper's
                # existing $DiagFile was nullable; using a single concatenated log
                # avoids breaking that contract.
                if ((Test-Path -LiteralPath $S.FailuresPath -PathType Leaf) -and ((Get-Item -LiteralPath $S.FailuresPath).Length -gt 0))
                {
                    if ($null -eq $DiagFile)
                    {
                        $DiagFile = Join-Path $InventoryRoot ("RunAllSubscriptions_failures_{0}_{1}.log" -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss-fff'), [guid]::NewGuid().ToString().Substring(0, 4))
                    }
                    try
                    {
                        Get-Content -LiteralPath $S.FailuresPath -Raw | Out-File -LiteralPath $DiagFile -Append -Encoding utf8
                    }
                    catch
                    {
                        Write-Verbose ("Failed to merge stream failures log {0}: {1}" -f $S.FailuresPath, $_.Exception.Message)
                    }
                }
            }

            # Clean up per-stream summary JSON files (the data is now folded into
            # the wrapper's accumulators). Per-stream failures logs are NOT deleted -
            # they are referenced from the merged $DiagFile via Append above. The
            # Az context snapshot cleanup lives in the `finally` block below so it
            # runs even on failure paths.
            foreach ($S in $StreamSummaries)
            {
                if (Test-Path -LiteralPath $S.SummaryPath)
                {
                    try { Remove-Item -LiteralPath $S.SummaryPath -Force } catch { Write-Verbose ("Could not remove stream summary {0}: {1}" -f $S.SummaryPath, $_.Exception.Message) }
                }
            }

            # When parallel streams have completed (clean or otherwise), merge each stream's resume-state file into the unified resume-state file so a subsequent -Resume picks up correctly (the unified file is also what the "clean run -> remove resume state" logic below reads).
            # Discover every per-stream resume file on disk for this tenant via a full-disk scan (see Get-StreamResumeStateFiles for why, rather than iterating over 0..StreamCount-1).
            $AllStreamFiles = @(Get-StreamResumeStateFiles -InventoryRoot $InventoryRoot -Tenant $TenantID)
            $AllCompletedFromStreams = @()
            $AllFailedFromStreams = @()
            foreach ($StreamFile in $AllStreamFiles)
            {
                $PerStreamFile = $StreamFile.FullName
                try
                {
                    $Obj = Get-Content -LiteralPath $PerStreamFile -Raw | ConvertFrom-Json
                    if ($null -ne $Obj.Completed)
                    {
                        $AllCompletedFromStreams += @($Obj.Completed)
                    }
                    # Per-stream files written by workers also carry their FailedAttempts entries. Merge by Id so the unified state file reflects every stream's failures, with the most-recent attempt's Reason/LastFailedAt winning when the same sub appears in multiple streams (which happens only across re-runs with different slicing).
                    if ($null -ne $Obj.FailedAttempts)
                    {
                        $AllFailedFromStreams += @($Obj.FailedAttempts)
                    }
                }
                catch
                {
                    Write-Verbose ("Could not read stream resume file {0}: {1}" -f $PerStreamFile, $_.Exception.Message)
                }
            }
            # Also fold in any per-stream state mirrored to BLOB. On AKS a pod that
            # died mid-parallel-run left its in-flight stream progress in blob, NOT
            # on this (possibly rescheduled) pod's local disk, so the local scan
            # above would miss it. Discovered by the shard-namespaced _state prefix
            # and merged into the SAME accumulators. No-op when blob state is off.
            if ($null -ne $StateBlobParts)
            {
                $StreamBlobNames = @(Get-StateBlobNames -Context $StateBlobCtx -Container $StateBlobParts.Container -Prefix $StateBlobParts.Prefix -Tenant $TenantID -ShardIndex $ShardIndex -ShardCount $ShardCount)
                foreach ($StreamBlobName in $StreamBlobNames)
                {
                    $BlobObj = Read-StateBlob -Context $StateBlobCtx -Container $StateBlobParts.Container -BlobName $StreamBlobName
                    if ($null -ne $BlobObj)
                    {
                        if ($null -ne $BlobObj.Completed) { $AllCompletedFromStreams += @($BlobObj.Completed) }
                        if ($null -ne $BlobObj.FailedAttempts) { $AllFailedFromStreams += @($BlobObj.FailedAttempts) }
                    }
                }
            }
            if ($AllCompletedFromStreams.Count -gt 0)
            {
                $CompletedIds = @($CompletedIds + $AllCompletedFromStreams | Sort-Object -Unique)
            }
            # Reconcile failed attempts from all streams against the unified list.
            # See Merge-FailedAttempts for the recency/completion rules.
            $FailedAttempts = Merge-FailedAttempts -ExistingFailedAttempts $FailedAttempts -StreamFailedAttempts $AllFailedFromStreams -CompletedIds $CompletedIds
            if ($AllCompletedFromStreams.Count -gt 0 -or $AllFailedFromStreams.Count -gt 0)
            {
                Save-CompletedSubscriptionIds -Path $ResumeStateFile -Tenant $TenantID -Ids $CompletedIds -FailedAttempts $FailedAttempts @StateSaveArgs
            }
            # Also delete the per-stream resume files now that the unified file holds the truth, to prevent drift if a future run uses a different stream count. Reuses the same on-disk discovery ($AllStreamFiles) as the merge loop above, so every file just merged is also the one cleaned up here - regardless of this run's -ParallelStreams value.
            foreach ($StreamFile in $AllStreamFiles)
            {
                $PerStreamFile = $StreamFile.FullName
                try { Remove-Item -LiteralPath $PerStreamFile -Force } catch { Write-Verbose ("Could not remove stream resume file {0}: {1}" -f $PerStreamFile, $_.Exception.Message) }
            }
            # Match the local cleanup for the per-stream BLOBS folded in above: once their progress is merged into the unified state (which IS preserved), remove the transient per-stream blobs so they do not accumulate under _state/ or resurrect stale FailedAttempts on a later run with a different stream count. Best-effort; the UNIFIED state blob is intentionally NOT deleted. $StreamBlobNames is in scope whenever $StateBlobParts is non-null.
            if ($null -ne $StateBlobParts)
            {
                foreach ($MergedStreamBlob in $StreamBlobNames)
                {
                    try { Remove-AzStorageBlob -Container $StateBlobParts.Container -Blob $MergedStreamBlob -Context $StateBlobCtx -Force -ErrorAction Stop }
                    catch { Write-Verbose ("Could not remove per-stream state blob {0}: {1}" -f $MergedStreamBlob, $_.Exception.Message) }
                }
            }
        }
        finally
        {
            # Unconditional cleanup of background jobs and the Az context snapshot.
            # Runs whether the orchestration succeeded, threw mid-aggregation, or
            # was interrupted via Ctrl+C while a child stream was still running.

            # 1. Background jobs. If we threw before $jobs was declared, the
            # variable is null/empty and Remove-Job is a no-op. Each job is a
            # separate `pwsh` process holding an Az context snapshot reference;
            # leaving them running after the parent exits would leak both
            # processes and authentication state.
            if ($null -ne $Jobs -and @($Jobs).Count -gt 0)
            {
                try
                {
                    # Stop any still-running jobs first so Remove-Job doesn't
                    # block waiting for them.
                    @($Jobs | Where-Object { $_.State -eq 'Running' }) | ForEach-Object {
                        try { Stop-Job -Job $_ -ErrorAction SilentlyContinue } catch {}
                    }
                    $Jobs | Remove-Job -Force -ErrorAction SilentlyContinue
                }
                catch
                {
                    Write-Host ("WARNING: could not fully clean up background jobs: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
                }
            }

            # 2. Az context snapshot. The snapshot file contains a token cache;
            # leaving it on disk is a security exposure (bounded by the ~1h
            # token lifetime, but real). Best-effort: log if the delete fails
            # but do not propagate the error - that would mask the real exit
            # reason.
            if (Test-Path -LiteralPath $AzContextSnapshot)
            {
                try
                {
                    Remove-Item -LiteralPath $AzContextSnapshot -Force -ErrorAction Stop
                }
                catch
                {
                    Write-Host ("WARNING: could not remove Az context snapshot at {0}: {1}" -f $AzContextSnapshot, $_.Exception.Message) -ForegroundColor Yellow
                    Write-Host "  This file contains an Azure token cache and should be deleted manually." -ForegroundColor Yellow
                }
            }
        }
    }
}

# === Moving-target subscription reconciliation: another team can create/delete subs DURING a long run, so the start-of-run Get-AzSubscription is stale by now. Re-enumerate and classify the delta against the ORIGINAL start snapshot ($StartSnapshot, preserved across resume) - subs deleted mid-run (Vanished) must NOT be reported as failures, and subs created mid-run (New) would otherwise be SILENTLY MISSING from the report.
# REPORT-ONLY (does not change the exit code - a moving tenant is expected here, not a fault) and best-effort (a re-enumeration blip must not fail an otherwise-complete run). No-op unless a start snapshot was recorded.
$StartIds = if ($StartSnapshot -and $StartSnapshot.SubscriptionIds) { @($StartSnapshot.SubscriptionIds) } else { @() }
if ($StartIds.Count -gt 0)
{
    try
    {
        $EndSubs = @(Get-AzSubscription -TenantId $TenantID -WarningAction SilentlyContinue)
        $EndIds = @($EndSubs | ForEach-Object { $_.Id })
        $Delta = Get-SubscriptionDelta -StartIds $StartIds -EndIds $EndIds -CompletedIds $CompletedIds
        # Scope Vanished + Incomplete to the subs THIS run was responsible for (the eligible, post-Enabled, post-shard, post-resume slice in $Subscriptions): the start snapshot is the FULL tenant so New can still flag subs that no shard will process, but "deleted that I owed" and "I did not finish" are only meaningful for this run's own slice - otherwise a default run flags every Disabled sub, and a sharded run every OTHER shard's subs, as not-completed. New stays tenant-level.
        $ResponsibleSet = @{}
        foreach ($ResponsibleSub in $Subscriptions) { $ResponsibleSet[([string]$ResponsibleSub.Id).ToLowerInvariant()] = $true }
        $VanishedMine = @($Delta.Vanished | Where-Object { $ResponsibleSet.ContainsKey(([string]$_).ToLowerInvariant()) })
        $IncompleteMine = @($Delta.Incomplete | Where-Object { $ResponsibleSet.ContainsKey(([string]$_).ToLowerInvariant()) })
        if ($VanishedMine.Count -gt 0 -or $Delta.New.Count -gt 0 -or $IncompleteMine.Count -gt 0)
        {
            Write-Host ""
            Write-Host "Subscription reconciliation (start-of-run vs now):" -ForegroundColor Cyan
        }
        if ($VanishedMine.Count -gt 0)
        {
            Write-Host ("  Deleted mid-run ({0}): {1}" -f $VanishedMine.Count, (($VanishedMine | Select-Object -First 10) -join ', ')) -ForegroundColor DarkYellow
            Write-Host "    These no longer exist; failures against them are expected and are dropped from the retry list (not run faults)." -ForegroundColor DarkGray
            # Prune vanished subs from the retry list so -ResumeFailedOnly does not
            # chase a deleted subscription, and persist the pruned state.
            $VanishedSet = @{}
            foreach ($VanishedId in $VanishedMine) { $VanishedSet[([string]$VanishedId).ToLowerInvariant()] = $true }
            $FailedAttempts = @($FailedAttempts | Where-Object { $_ -and -not $VanishedSet.ContainsKey(([string]$_.Id).ToLowerInvariant()) })
            Save-CompletedSubscriptionIds -Path $ResumeStateFile -Tenant $TenantID -Ids $CompletedIds -FailedAttempts $FailedAttempts @StateSaveArgs
        }
        if ($Delta.New.Count -gt 0)
        {
            Write-Host ("  Created mid-run ({0}): {1}" -f $Delta.New.Count, (($Delta.New | Select-Object -First 10) -join ', ')) -ForegroundColor Yellow
            Write-Host "    NOT in this report - they did not exist when the run started. Re-run with -Resume to pick them up." -ForegroundColor Yellow
        }
        if ($IncompleteMine.Count -gt 0)
        {
            Write-Host ("  Owed by this run but not completed ({0}): {1}" -f $IncompleteMine.Count, (($IncompleteMine | Select-Object -First 10) -join ', ')) -ForegroundColor Yellow
            Write-Host "    Re-run with -Resume to finish these." -ForegroundColor Yellow
        }
    }
    catch
    {
        Write-Host ("WARNING: subscription reconciliation skipped (re-enumeration failed): {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    }
}

Write-Host "All subscriptions processed!" -ForegroundColor Green

# === Per-subscription output verification (hard-stop): fail with exit code 2 (distinct from auth/runtime exit code 1) if any sub that ran to completion this invocation left no report archive on disk. Checks IDENTITY first (every successful sub records the exact $Global:ZipOutputFile it wrote, so a missing report is reported BY SUBSCRIPTION) and count second (catches an absent recorded path or a replaced archive).
# Why it matters: the consolidation step below globs *.zip, so a per-sub zip missing for any reason (AV quarantine, Cloud Shell eviction between worker exit and consolidation, a worker that crashed after logging completion but before the zip flushed, a swallowed out-of-disk write) would otherwise be silently consolidated and reported as success. Invariant: ResourceInventory.ps1 always writes a per-sub zip on a successful return (even for zero resources), so expected zip count = subs in $SubResourceCounts (appended ONLY on the successful return path); failed subs are intentionally NOT counted since their zip state is unreliable and already surfaced by the failure summary.
$ExpectedZipCount = @($SubResourceCounts).Count
if ($ExpectedZipCount -gt 0 -and (Test-Path -LiteralPath $InventoryRoot -PathType Container))
{
    $ActualSubZips = @(Get-ChildItem -LiteralPath $InventoryRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Filter "*.zip" -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $RunStartTime } })
    $ActualZipCount = $ActualSubZips.Count

    # A recorded path that is no longer a usable archive on disk is a NAMED missing report. "Usable" deliberately means present AND non-empty - the same standard ResourceInventory.ps1 applies to its own archive before reporting success - because a 0-byte file (a truncating quarantine or an eviction mid-flush) is not a report, and testing for presence only would let the two halves disagree.
    # A row with no recorded path cannot be checked this way and is counted UNVERIFIABLE rather than missing, so an older stream summary can never produce a false accusation against a specific sub; the count comparison below still covers it.
    $MissingSubs = @($SubResourceCounts | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Zip) -and -not (Test-ReportArchiveUsable -Path $_.Zip) })
    $UnverifiableSubs = @($SubResourceCounts | Where-Object { [string]::IsNullOrWhiteSpace($_.Zip) })

    if ($MissingSubs.Count -gt 0 -or $ActualZipCount -lt $ExpectedZipCount)
    {
        $MissingCount = $ExpectedZipCount - $ActualZipCount
        Write-Host ""
        Write-Host "ERROR: Per-subscription output verification failed." -ForegroundColor Red
        Write-Host ("  Expected zips: {0} (one per subscription that ran to completion this run)" -f $ExpectedZipCount) -ForegroundColor Red
        Write-Host ("  Found zips:    {0} (filter: under {1}, LastWriteTime >= {2:o})" -f $ActualZipCount, $InventoryRoot, $RunStartTime) -ForegroundColor Red
        if ($MissingCount -gt 0)
        {
            Write-Host ("  Gap:           {0} missing per-subscription zip(s)." -f $MissingCount) -ForegroundColor Red
        }
        Write-Host ""
        if ($MissingSubs.Count -gt 0)
        {
            Write-Host ("Subscription(s) whose report archive is MISSING ({0}):" -f $MissingSubs.Count) -ForegroundColor Red
            foreach ($M in $MissingSubs)
            {
                Write-Host ("  - {0} ({1}) [{2:N0} resources]" -f $M.Name, $M.Id, $M.Count) -ForegroundColor Red
                # Absent and present-but-empty are different faults with different
                # first suspects, so name which one it is rather than making the
                # operator go and look.
                if (Test-Path -LiteralPath $M.Zip -PathType Leaf)
                {
                    Write-Host ("      archive is present but EMPTY (0 bytes): {0}" -f $M.Zip) -ForegroundColor Red
                    Write-Host "      -> a truncating quarantine or a write cut off mid-flush; it is not a usable report." -ForegroundColor Red
                }
                else
                {
                    Write-Host ("      expected archive: {0}" -f $M.Zip) -ForegroundColor Red
                }
                # Name the uncompressed report folder explicitly (it is the salvage path) rather than making the operator derive it.
                # [IO.Path]::GetDirectoryName rather than Split-Path: Split-Path's -Parent switch pairs only with -Path, never -LiteralPath, so there is no literal-path form of it; the .NET call is literal by construction, which takes wildcard interpretation off the table for a path that can contain '[' or ']'.
                $MissingDir = try { [System.IO.Path]::GetDirectoryName($M.Zip) } catch { $null }
                if (-not [string]::IsNullOrWhiteSpace($MissingDir))
                {
                    if (Test-Path -LiteralPath $MissingDir -PathType Container)
                    {
                        # Deliberately neutral about the archive here: the line above
                        # already said whether it is absent or empty, and saying "only
                        # the archive is gone" contradicted the empty case.
                        Write-Host ("      report folder IS present: {0}" -f $MissingDir) -ForegroundColor Yellow
                        Write-Host "      -> the uncompressed report files in it can be zipped by hand instead of re-collecting." -ForegroundColor Yellow
                    }
                    else
                    {
                        Write-Host ("      report folder is ALSO gone: {0}" -f $MissingDir) -ForegroundColor Red
                        Write-Host "      -> the whole folder was removed after the run wrote it; re-collect this subscription." -ForegroundColor Red
                    }
                }
            }
            Write-Host ""
        }
        if ($UnverifiableSubs.Count -gt 0)
        {
            Write-Host ("Subscription(s) with no recorded archive path - cannot be checked individually ({0}):" -f $UnverifiableSubs.Count) -ForegroundColor Yellow
            foreach ($U in $UnverifiableSubs)
            {
                Write-Host ("  - {0} ({1})" -f $U.Name, $U.Id) -ForegroundColor Yellow
            }
            Write-Host ""
        }
        Write-Host "Subscriptions whose inner script reported success this run:" -ForegroundColor Yellow
        foreach ($S in $SubResourceCounts)
        {
            Write-Host ("  - {0} ({1}) [{2:N0} resources]" -f $S.Name, $S.Id, $S.Count) -ForegroundColor Yellow
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
        Write-Host "  - Inspecting the report folder named above and zipping its files by hand if they are still present, OR" -ForegroundColor Yellow
        Write-Host "  - Re-running with -Resume to re-collect any unprocessed/missing subscription." -ForegroundColor Yellow
        Write-Host "    NOTE: a subscription listed above is already recorded as complete in the resume state, so plain" -ForegroundColor Yellow
        Write-Host "    -Resume will SKIP it. To force a re-collect, either remove its id from the resume-state file" -ForegroundColor Yellow
        Write-Host "    above, or collect just that one directly with:" -ForegroundColor Yellow
        Write-Host "      ./ResourceInventory.ps1 -TenantID <tenant> -SubscriptionID <the id listed above>" -ForegroundColor Yellow
        if ($WrapperTranscriptStarted)
        {
            Write-Host ("Wrapper Transcript:      {0}" -f $WrapperTranscriptFile) -ForegroundColor Yellow
        }
        Exit-Wrapper -Code 2
    }
    # Report the expected and found counts SEPARATELY and state how many subs were checked by path versus only by count: the previous message used {0} twice against a single argument, echoing found as expected so a discrepancy could never show. Naming the per-path total matters because "no missing archives" is much weaker when nothing could be checked individually, and must not read like a full pass in that case.
    $VerifiedByPathCount = $ExpectedZipCount - $UnverifiableSubs.Count
    Write-Host ("Per-subscription output verification: OK ({0} archive(s) on disk for {1} successful sub(s); {2} verified by exact path)" -f $ActualZipCount, $ExpectedZipCount, $VerifiedByPathCount) -ForegroundColor Green
    if ($UnverifiableSubs.Count -gt 0)
    {
        Write-Host ("  Note: {0} sub(s) recorded no archive path and were covered by the count check only." -f $UnverifiableSubs.Count) -ForegroundColor Yellow
    }
}

# Consolidate per-subscription ZIPs into a single outer ZIP
$OuterZipFile = $null

if (Test-Path -LiteralPath $InventoryRoot -PathType Container)
{
    # Filter ZIPs by current run timestamp only
    $SubZips = @(Get-ChildItem -LiteralPath $InventoryRoot -Directory | ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Filter "*.zip" -File | Where-Object { $_.LastWriteTime -ge $RunStartTime } })
    if ($SubZips.Count -gt 0)
    {
        $Timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
        $OuterZipFile = Join-Path $InventoryRoot "AllSubscriptions_ResourcesReport_$Timestamp.zip"
        Write-Host ("Compressing {0} per-subscription report(s) into: {1}" -f $SubZips.Count, $OuterZipFile) -ForegroundColor Cyan
        # -LiteralPath (as Reveal.ps1 uses) so a report folder/zip name containing
        # [ ] is not treated as a wildcard glob and silently dropped.
        Compress-Archive -LiteralPath $SubZips.FullName -DestinationPath ([WildcardPattern]::Escape($OuterZipFile)) -Force
        # Deliberately NOT labelled "Reporting Data File": the inner per-sub script prints that label once PER SUBSCRIPTION for its own zip, so on a large tenant the operator saw the identical label N+1 times naming N+1 different files and could not tell which to send. This label names the bundle unambiguously - "created", not finished, since stages 2 and 3 below still fold in RunSummary.log, MainSummary.html, the VM CSV and per-sub HTML; the "What to send" block after stage 3 declares it the deliverable.
        Write-Host ("Consolidated bundle created: {0}" -f $OuterZipFile) -ForegroundColor Green
    }
    else
    {
        Write-Host ("No per-subscription zip files found under {0} to consolidate." -f $InventoryRoot) -ForegroundColor Yellow
    }
}
else
{
    Write-Host ("Inventory root not found at {0}. Nothing to consolidate." -f $InventoryRoot) -ForegroundColor Yellow
}

# Aggregate "main" HTML summary across all per-sub reports from THIS run, built on EVERY run that produced a consolidated zip (previously opt-in via -MainSummary, now always produced and folded into the bundle below; -Detailed still adds the run-wide by-service charts). Built purely from on-disk per-sub artefacts (Inventory_*.json + sibling .html) scoped to $RunStartTime - no Azure calls.
# A failure here must never fail the run (the per-sub reports and the zip are already written), so any error is downgraded to a warning and $MainSummaryFile is left $null.
$MainSummaryFile = $null
if ($null -ne $OuterZipFile)
{
    try
    {
        # The aggregate summary builder lives in a dot-sourced function
        # library (Functions/AllSubHtmlSummary.Functions.ps1), which also
        # holds the render helpers shared with Extension/Summary.ps1. A
        # missing file throws into the surrounding catch and downgrades to
        # a warning.
        $AllSubSummaryFunctions = Join-Path $PSScriptRoot 'Functions/AllSubHtmlSummary.Functions.ps1'
        if (-not (Test-Path -LiteralPath $AllSubSummaryFunctions -PathType Leaf))
        {
            throw "Main summary functions not found at '$AllSubSummaryFunctions'."
        }
        . $AllSubSummaryFunctions
        $MainSummaryFile = Join-Path $InventoryRoot ("MainSummary_{0}.html" -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'))
        # Source the version from Version.json rather than $Global:Version:
        # in parallel mode the inner script runs in child processes, so the
        # wrapper's $Global:Version is never set. Fall back to it (and then
        # blank) if the file can't be read.
        $MainVer = $Global:Version
        try
        {
            $VerObj = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Version.json') -Raw | ConvertFrom-Json
            $MainVer = ('{0}.{1}.{2}' -f $VerObj.MajorVersion, $VerObj.MinorVersion, $VerObj.BuildVersion)
        }
        catch { Write-Verbose ("MainSummary: could not read Version.json: {0}" -f $_.Exception.Message) }
        New-RdaAllSubHtmlSummary -RunOutputDirectory $InventoryRoot -HtmlFile $MainSummaryFile -SinceTime $RunStartTime `
            -FailedSubscriptions $FailedSubscriptions `
            -ConsumptionFailedSubs $Global:ConsumptionFailedSubs `
            -MetricsFailedSubs $Global:MetricsFailedSubs `
            -CollectorFailures $Global:CollectorFailures `
            -TenantId $TenantID -Version $MainVer -PlatOS $PSVersionTable.OS `
            -Detailed:$Detailed -Obfuscated:$Obfuscate
    }
    catch
    {
        Write-Host ("WARNING: Could not build the main summary: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    }
}

# Tenant-wide VM placement CSV, written next to MainSummary. Concatenates each per-sub VMPlacementPart_*.csv here (rather than having every run append to one shared file) so parallel streams cannot interleave writes into one CSV. Deliberately NOT an Inventory_*.json change: the zone identity this file carries would otherwise have to enter the VM collector's output object, which is the server-ingestion contract (see Extension/VMPlacement.ps1). Only parts from THIS run ($RunStartTime) are consumed.
# TIMESTAMPED to match its sibling MainSummary_<stamp>.html, and load-bearing rather than cosmetic: a fixed name would be overwritten in place, so on a -Resume run (skipped subs write no new part, and their earlier parts were already consumed) it would silently replace a COMPLETE tenant-wide file with one covering only this invocation's subs. Best-effort (a failure here is a warning), and nil-initialised so stage 3 below always has a defined variable to test.
$VmPlacementFile = $null
if ($CapacityPlan)
{
    try
    {
        # -LiteralPath on the container: $InventoryRoot is a user-supplied-ish path and
        # a '[' or ']' in it would otherwise be treated as a wildcard and match nothing.
        $PlacementParts = @(Get-ChildItem -LiteralPath $InventoryRoot -Filter 'VMPlacementPart_*.csv' -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $RunStartTime } | Sort-Object Name)

        $PlacementRows = @()
        foreach ($Part in $PlacementParts)
        {
            $PlacementRows += @(Import-Csv -LiteralPath $Part.FullName)
        }

        if ($PlacementRows.Count -gt 0)
        {
            $VmPlacementFile = Join-Path $InventoryRoot ("VMPlacement_{0}.csv" -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'))
            $PlacementRows | Export-Csv -LiteralPath $VmPlacementFile -Encoding utf8 -NoTypeInformation

            $ZonalRows = @($PlacementRows | Where-Object { $_.Zone -ne 'Regional' -and $_.Zone -ne 'Unknown' }).Count
            Write-Host ("VM placement CSV: {0} VM(s) across {1} subscription(s) written to {2} ({3} zonal)." -f `
                    $PlacementRows.Count, $PlacementParts.Count, (Split-Path -Path $VmPlacementFile -Leaf), $ZonalRows) -ForegroundColor Green
        }
        else
        {
            # State the zero rather than saying nothing, and name its scope, so the
            # operator does not have to guess whether the phase ran. A tenant with no
            # VMs at all is a legitimate outcome; so is every subscription being
            # skipped on a -Resume run.
            Write-Host ("VM placement CSV: not written - no VM rows were produced by this run (parts found: {0}). A tenant with no virtual machines, or a -Resume run whose remaining subscriptions have none, both land here." -f $PlacementParts.Count) -ForegroundColor Yellow
        }

        # Remove the parts unconditionally once read: they are an implementation detail
        # of the aggregation, and skipping the delete when the merge produced no rows
        # would leave orphans accumulating in InventoryRoot run after run.
        foreach ($Part in $PlacementParts)
        {
            Remove-Item -LiteralPath $Part.FullName -Force -ErrorAction SilentlyContinue
        }

        # Deliberately NOT an error when parts are fewer than subscriptions processed:
        # a subscription with no VMs legitimately writes none, and the inner run
        # already logs loudly when a VM collector failed. The subscription count in the
        # line above is what lets the operator judge coverage; claiming completeness we
        # have not verified would be the actual mistake.
    }
    catch
    {
        Write-Host ("WARNING: Could not build the tenant-wide VM placement CSV: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    }
}

# Clean up resume state on a fully successful run (all subs processed, no failures
# this run AND no pending retries from a prior run). Otherwise leave it so a
# future -Resume / -ResumeFailedOnly invocation can pick up where this stopped.
if ($FailedSubscriptions.Count -eq 0 -and $FailedAttempts.Count -eq 0 -and (Test-Path -LiteralPath $ResumeStateFile -PathType Leaf))
{
    try
    {
        Remove-Item -LiteralPath $ResumeStateFile -Force
        Write-Host "Resume state cleared (clean run)." -ForegroundColor Green
    }
    catch
    {
        Write-Host ("WARNING: Could not remove resume state file {0}: $_" -f $ResumeStateFile) -ForegroundColor Yellow
    }
}

# Final summary
$Elapsed = (Get-Date) - $RunStartTime
Write-Host ""
Write-Host "================ Summary ================" -ForegroundColor Green
Write-Host ("Subscriptions Visible:   {0}" -f $AllSubscriptions.Count) -ForegroundColor Green
if ($Excluded.Count -gt 0)
{
    Write-Host ("Subscriptions Excluded:  {0} (non-Enabled; use -IncludeDisabled to inventory them)" -f $Excluded.Count) -ForegroundColor Green
}
Write-Host ("Subscriptions Eligible:  {0}" -f $EligibleCount) -ForegroundColor Green
# In parallel mode, $SkippedCount is not populated by the foreach loop above
# (each worker skips independently). Derive it from the difference between
# the number of eligible subs and the number of subs that actually ran in
# this invocation (the union of $SubResourceCounts entries plus failures).
if ($ParallelStreams -gt 1 -and $Resume -and $SkippedCount -eq 0)
{
    $ActuallyProcessed = ($SubResourceCounts | Measure-Object).Count + $FailedSubscriptions.Count
    $DerivedSkip = $EligibleCount - $ActuallyProcessed
    if ($DerivedSkip -gt 0) { $SkippedCount = $DerivedSkip }
}
if ($Resume)
{
    Write-Host ("Subscriptions Skipped:   {0} (already completed)" -f $SkippedCount) -ForegroundColor Green
}
Write-Host ("Subscriptions Processed: {0}" -f ($EligibleCount - $SkippedCount)) -ForegroundColor Green

# Surface the per-subscription resource-count result so the user does not have
# to scan individual transcripts to find subs that came back empty. Empty subs
# are shown distinctly because they almost always indicate a permission gap;
# treating them as "successful" in the summary is misleading.
$EmptySubs = @($SubResourceCounts | Where-Object { $_.Count -eq 0 })
$NonEmptySubs = @($SubResourceCounts | Where-Object { $_.Count -gt 0 })
# Initialised here (not only inside the 0-resource branch below) so the
# run-summary finalization can read them unconditionally even when there
# were no empty subscriptions to classify.
$NoAccessSubs = @()
$GenuinelyEmptySubs = @()
$UnknownSubs = @()
if ($SubResourceCounts.Count -gt 0)
{
    $TotalRes = ($SubResourceCounts | Measure-Object -Property Count -Sum).Sum
    Write-Host ("Total Resources:         {0:N0} across {1} subscription(s)" -f $TotalRes, $NonEmptySubs.Count) -ForegroundColor Green
}
if ($EmptySubs.Count -gt 0)
{
    # A sub that returned 0 resources is either a permission gap (no role on the
    # sub) or genuinely empty. Probe each one to label it precisely so the user
    # knows whether to fix access or ignore it. The probe is one cheap ARM call
    # per empty sub (only empties, so no cost on normal runs).
    $NoAccessSubs = @()
    $GenuinelyEmptySubs = @()
    $UnknownSubs = @()
    foreach ($e in $EmptySubs)
    {
        switch (Get-SubscriptionAccessState -SubscriptionId $e.Id)
        {
            'NoAccess' { $NoAccessSubs += $e }
            'Empty' { $GenuinelyEmptySubs += $e }
            default { $UnknownSubs += $e }
        }
    }

    Write-Host ""
    Write-Host ("Subscriptions with 0 resources: {0}" -f $EmptySubs.Count) -ForegroundColor Yellow

    if ($NoAccessSubs.Count -gt 0)
    {
        Write-Host ("  NO ACCESS ({0}) - the signed-in identity has no role on these subscriptions:" -f $NoAccessSubs.Count) -ForegroundColor Red
        foreach ($e in $NoAccessSubs) { Write-Host ("    - {0} ({1})" -f $e.Name, $e.Id) -ForegroundColor Red }
        Write-Host "    Fix: grant the identity Reader on these subscriptions, then re-run." -ForegroundColor Red
    }
    if ($GenuinelyEmptySubs.Count -gt 0)
    {
        Write-Host ("  GENUINELY EMPTY ({0}) - access confirmed, the subscription has no resources:" -f $GenuinelyEmptySubs.Count) -ForegroundColor Yellow
        foreach ($e in $GenuinelyEmptySubs) { Write-Host ("    - {0} ({1})" -f $e.Name, $e.Id) -ForegroundColor Yellow }
        Write-Host "    No action needed - these are expected to be empty in the report." -ForegroundColor DarkGray
    }
    if ($UnknownSubs.Count -gt 0)
    {
        Write-Host ("  UNDETERMINED ({0}) - access probe was inconclusive (transient error / throttling):" -f $UnknownSubs.Count) -ForegroundColor Yellow
        foreach ($e in $UnknownSubs) { Write-Host ("    - {0} ({1})" -f $e.Name, $e.Id) -ForegroundColor Yellow }
        Write-Host "    Verify manually (PowerShell): (Invoke-AzRestMethod -Method GET -Path '/subscriptions/<id>/resourcegroups?api-version=2021-04-01').StatusCode" -ForegroundColor Yellow
    }

    # Persist the per-sub access verdict to the diagnostic log so it outlives the console/transcript and can be attached to a ticket or e-mail: the durable record behind the on-screen labels of which 0-resource subs are a permission gap (fix: grant Reader, re-run -Resume) vs genuinely empty (no action). Reuses the run's $DiagFile if one already exists, otherwise creates one.
    if ($null -eq $DiagFile)
    {
        $DiagFile = Join-Path $InventoryRoot ("RunAllSubscriptions_diagnostics_{0}_{1}.log" -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss-fff'), [guid]::NewGuid().ToString().Substring(0, 4))
    }
    $EmptyDiag = @()
    $EmptyDiag += "==== Subscriptions with 0 resources - access verdict ===="
    $EmptyDiag += "Timestamp: $(Get-Date -Format 'o')"
    foreach ($e in $NoAccessSubs)
    {
        $EmptyDiag += ("NO_ACCESS {0} ({1}) - identity has no role on the subscription; grant Reader and re-run with -Resume" -f $e.Name, $e.Id)
    }
    foreach ($e in $GenuinelyEmptySubs)
    {
        $EmptyDiag += ("EMPTY {0} ({1}) - access confirmed, no resources; no action needed" -f $e.Name, $e.Id)
    }
    foreach ($e in $UnknownSubs)
    {
        $EmptyDiag += ("UNDETERMINED   {0} ({1}) - access probe inconclusive; verify (PowerShell): (Invoke-AzRestMethod -Method GET -Path '/subscriptions/{1}/resourcegroups?api-version=2021-04-01').StatusCode" -f $e.Name, $e.Id)
    }
    $EmptyDiag += ""
    try
    {
        $EmptyDiag | Out-File -LiteralPath $DiagFile -Append -Encoding utf8
        Write-Host ("  Access verdict written to diagnostic log: {0}" -f $DiagFile) -ForegroundColor DarkGray
    }
    catch
    {
        Write-Verbose ("Diagnostic log write failed at {0}: {1}" -f $DiagFile, $_.Exception.Message)
    }
    Write-Host ""
}

# Surface consumption (billing) data health: the inner script's consumption loop populates these globals; if every Get-UsageAggregates call failed (typically a broken Az module that cannot load its bundled MSAL/Azure.Core assemblies) the customer ends up with an empty consumption sheet and no signal - make it loud here, before the report is shared.
$ConsumptionRecords = if ($null -ne $Global:ConsumptionRecordCount) { [int]$Global:ConsumptionRecordCount } else { 0 }
$ConsumptionFailures = if ($null -ne $Global:ConsumptionFailedSubs) { @($Global:ConsumptionFailedSubs) } else { @() }
# Report the consumption record count UNCONDITIONALLY when consumption was requested: the previous '-gt 0 -or failures' condition printed NOTHING in the one case this block exists for - zero records AND zero reported failures, the silent-failure signature (the billing API answered successfully but returned no rows) that ships an empty Consumption CSV with a clean-looking summary. Zero is legitimate only for a genuinely idle subscription, so state it in yellow and explain the likely causes.
if (-not $SkipConsumption)
{
    $ConsumptionRecordColor = if ($ConsumptionRecords -gt 0) { 'Green' } else { 'Yellow' }
    Write-Host ("Consumption Records:     {0:N0} record(s) collected" -f $ConsumptionRecords) -ForegroundColor $ConsumptionRecordColor
}
elseif ($ConsumptionRecords -gt 0 -or $ConsumptionFailures.Count -gt 0)
{
    Write-Host ("Consumption Records:     {0:N0} record(s) collected" -f $ConsumptionRecords) -ForegroundColor Green
}

# Consumption was requested, the phase reported no per-sub failure, and yet not a single usage record came back. The up-front gate cannot catch this - it classifies the billing probe's EXCEPTION text, and an empty-but-successful response raises none (see Test-ConsumptionAccess) - so call it out here with the causes that actually produce it, or the operator has no signal the billing data is missing.
# Gate CLOSELY MIRRORS the one in Get-RunSummaryLogContent's Health block so the console and the SHIPPED RunSummary.log do not disagree: both require at least one sub ATTEMPTED and at least one COMPLETED (the easy-to-lose half). Here that is @($SubResourceCounts).Count -gt 0; the builder cannot see that list so it APPROXIMATES with ($Processed - $Failed.Count) -gt 0, which is NOT interchangeable ($Processed still counts attempted-then-failed subs). This gate is never the looser of the two, but a stream with a missing/unparsable summary adds one $FailedSubscriptions entry for its K subs, so for K>1 the builder can still open while this gate correctly stays quiet.
if (-not $SkipConsumption -and $ConsumptionRecords -eq 0 -and $ConsumptionFailures.Count -eq 0 -and @($SubResourceCounts).Count -gt 0 -and ($EligibleCount - $SkippedCount) -gt 0)
{
    Write-Host ""
    Write-Host "WARNING: Consumption data was requested (no -SkipConsumption) but ZERO usage records were collected," -ForegroundColor Yellow
    Write-Host "         and no subscription reported a billing error. The billing API answered successfully with no rows." -ForegroundColor Yellow
    Write-Host "         The consumption CSV in the report will contain only its header row." -ForegroundColor Yellow
    Write-Host "         This is expected ONLY if the subscriptions genuinely have no usage in the queried window" -ForegroundColor Yellow
    Write-Host "         (the 30 days ending at midnight yesterday, host local time)." -ForegroundColor Yellow
    Write-Host "         Otherwise the most common causes are:" -ForegroundColor Yellow
    Write-Host "           - CSP / Partner-managed subscription: the partner's cost visibility policy is OFF by default." -ForegroundColor Yellow
    Write-Host "             Billing scope on CSP subscriptions is not governed by Azure RBAC, so granting Cost Management" -ForegroundColor Yellow
    Write-Host "             Reader does NOT help. The partner must enable cost visibility for the customer in Partner Center." -ForegroundColor Yellow
    Write-Host "           - The subscription has not been transitioned to the Azure plan (required for CSP billing APIs)." -ForegroundColor Yellow
    Write-Host "           - A subscription offer the legacy usage API does not serve (e.g. sponsored/sandbox offers)." -ForegroundColor Yellow
    Write-Host "         Confirm in the Azure portal under Cost Management + Billing before sharing this report." -ForegroundColor Yellow
    Write-Host ""
}
if ($ConsumptionFailures.Count -gt 0)
{
    Write-Host ""
    Write-Host ("Consumption Failures:    {0} subscription(s)" -f $ConsumptionFailures.Count) -ForegroundColor Yellow
    # List the affected subscriptions by name so the operator knows exactly
    # which subs are missing billing data (e.g. to go request Reader access
    # on them). Mirrors the metrics-failure block below. Exclude the '(auth)'
    # sentinel used for the whole-phase skip - it is not a specific sub.
    foreach ($cf in (@($ConsumptionFailures | Where-Object { $_.Id -ne '(auth)' }) | Sort-Object Name -Unique))
    {
        Write-Host ("  - {0} ({1})" -f $cf.Name, $cf.Id) -ForegroundColor Yellow
    }
    # The consumption failure message is repeated verbatim across every sub
    # when the cause is a broken Az module - dedupe to avoid screen wall.
    $UniqueMessages = @($ConsumptionFailures | Select-Object -ExpandProperty Message -Unique)
    foreach ($m in $UniqueMessages)
    {
        Write-Host ("  - {0}" -f $m) -ForegroundColor Yellow
    }
    if ($UniqueMessages | Where-Object { $_ -match 'context has not been properly initialized|Could not load file or assembly|MSAL|Azure\.Core' })
    {
        Write-Host "  This message strongly suggests the Az PowerShell module is broken on disk." -ForegroundColor Yellow
        Write-Host "  Reinstall with:" -ForegroundColor Yellow
        Write-Host "    Get-Module Az* -ListAvailable | Uninstall-Module -Force" -ForegroundColor Yellow
        Write-Host "    Install-Module -Name Az -Repository PSGallery -Force -AllowClobber -SkipPublisherCheck" -ForegroundColor Yellow
    }
    Write-Host "  Note: the consumption sheet in the output report may be empty or incomplete for these subscriptions." -ForegroundColor Yellow
    Write-Host ""
}

# Surface metrics-phase auth health (mirrors the consumption block above): metrics were requested (no -SkipMetrics) but skipped because no usable Azure context/token could be established even after a reconnect attempt. Without this the metrics sheet is silently empty and looks like "no metric-eligible resources" rather than an auth failure. Listed per-subscription so the operator knows exactly which subs are missing metrics.
$MetricsFailures = if ($null -ne $Global:MetricsFailedSubs) { @($Global:MetricsFailedSubs) } else { @() }
if ($MetricsFailures.Count -gt 0)
{
    Write-Host ""
    Write-Host ("Metrics Auth Failures:   {0} subscription(s) - metrics SKIPPED" -f $MetricsFailures.Count) -ForegroundColor Yellow
    foreach ($m in ($MetricsFailures | Sort-Object Name -Unique))
    {
        Write-Host ("  - {0} ({1})" -f $m.Name, $m.Id) -ForegroundColor Yellow
    }
    # The reason is the same across subs (auth), so show it once.
    $FirstMsg = @($MetricsFailures | Where-Object { -not [string]::IsNullOrEmpty($_.Message) } | Select-Object -First 1).Message
    if (-not [string]::IsNullOrEmpty($FirstMsg))
    {
        Write-Host ("  Reason: {0}" -f $FirstMsg) -ForegroundColor Yellow
    }
    Write-Host "  Re-authenticate (Connect-AzAccount) or pass -appid/-secret/-tenant, then re-run." -ForegroundColor Yellow
    Write-Host "  Note: the metrics sheet in the output report will be empty for these subscriptions." -ForegroundColor Yellow
    Write-Host ""
}

# Surface collector failures: a Services/*.ps1 collector threw for a specific subscription and was caught by ResourceInventory.ps1's circuit breaker (CreateResourceJobs), so that resource type is MISSING from the affected sub's report, not silently empty because none exist. Grouped by subscription so the operator can see exactly which sub(s) and which resource type(s) were affected without hunting through per-sub logs.
$CollectorFailuresList = if ($null -ne $Global:CollectorFailures) { @($Global:CollectorFailures) } else { @() }
if ($CollectorFailuresList.Count -gt 0)
{
    Write-Host ""
    Write-Host ("Collector Failures:      {0} failure(s) across {1} subscription(s)" -f $CollectorFailuresList.Count, (@($CollectorFailuresList | Select-Object -ExpandProperty Id -Unique)).Count) -ForegroundColor Yellow
    foreach ($SubGroup in ($CollectorFailuresList | Group-Object -Property Id))
    {
        Write-Host ("  - Subscription {0}:" -f $SubGroup.Name) -ForegroundColor Yellow
        foreach ($f in $SubGroup.Group)
        {
            Write-Host ("      {0}: {1}" -f $f.Module, $f.Message) -ForegroundColor Yellow
        }
    }
    Write-Host "  These resource types are missing (not empty) from the affected subscription's report." -ForegroundColor Yellow
    Write-Host "  Re-run to retry, or investigate the error(s) above if they repeat." -ForegroundColor Yellow
    Write-Host ""
}

if ($FailedSubscriptions.Count -gt 0)
{
    Write-Host ("Subscriptions Failed:    {0} ({1})" -f $FailedSubscriptions.Count, ($FailedSubscriptions -join ', ')) -ForegroundColor Red
    Write-Host ("Resume State:            {0}" -f $ResumeStateFile) -ForegroundColor Yellow
    Write-Host "Re-run with -Resume to retry failed and any unprocessed subscriptions." -ForegroundColor Yellow
    Write-Host "Or re-run with -ResumeFailedOnly to retry ONLY the failed subscriptions." -ForegroundColor Yellow
    if ($DiagFile -and (Test-Path -LiteralPath $DiagFile))
    {
        Write-Host ("Failure Diagnostics:     {0}" -f $DiagFile) -ForegroundColor Red
    }
    if ($WrapperTranscriptStarted)
    {
        Write-Host ("Wrapper Transcript:      {0}" -f $WrapperTranscriptFile) -ForegroundColor Red
    }
}
elseif ($FailedAttempts.Count -gt 0)
{
    # No new failures this run, but the resume-state file still has lingering
    # FailedAttempts from a prior run that have not yet been retried. Surface
    # them so the operator does not lose track of historical failures simply
    # because the most recent run was clean.
    Write-Host ("Pending Retries:         {0} subscription(s) from a prior run still in FailedAttempts" -f $FailedAttempts.Count) -ForegroundColor Yellow
    Write-Host "Re-run with -ResumeFailedOnly to retry them." -ForegroundColor Yellow
}
Write-Host ("Execution Time:          {0}" -f $Elapsed.ToString('hh\:mm\:ss')) -ForegroundColor Green
if ($OuterZipFile)
{
    # Location only. The authoritative "this is the file to send" instruction is
    # emitted AFTER stage 3 below, because that is the first point at which the
    # bundle's membership is final and verified - stating its contents here would
    # describe folds that have not happened yet.
    Write-Host ("Consolidated Report:     {0}" -f $OuterZipFile) -ForegroundColor Green
}
if ($WrapperTranscriptStarted)
{
    Write-Host ("Wrapper Transcript:      {0}" -f $WrapperTranscriptFile) -ForegroundColor Green
}
Write-Host "=========================================" -ForegroundColor Green

# --- Run summary (ALWAYS produced) + fold run-level extras into the bundle. The run summary (parameters + sub tally + health) is the ONE artefact we must never lose (a customer has already received a zip missing it), so its generation and on-disk write are decoupled from both the outer zip and the best-effort MainSummary/HTML bundling below - a failure in any later step can no longer suppress it.
# THE EXCEPTION: the per-sub zip-verification hard stop earlier calls Exit-Wrapper -Code 2 and returns BEFORE this block, so that path produces no RunSummary.log (it is the only exit after subs are inventoried that pre-empts this block; the earlier aborts have nothing to summarise, and the final exit sits downstream). Three independent try/catch stages follow: (1) generate RunSummary and write it to disk (always); (2) fold it into the zip as its own verified operation - a silent Compress-Archive -Update once dropped it - with the on-disk copy as fallback; (3) fold MainSummary.html, the tenant-wide VMPlacement.csv, and a copy of each per-sub HTML, additive members and NO loose *.json so the ingestion contract is unchanged. Every final claim is derived from one read of the finished archive.

# Version is display-only. Prefer Version.json (in parallel mode the wrapper's
# $Global:Version is never set - child processes set it), fall back to
# $Global:Version then blank. Resolved once and shared by the stages below.
$BundleVer = $Global:Version
try
{
    $BundleVerObj = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Version.json') -Raw | ConvertFrom-Json
    $BundleVer = ('{0}.{1}.{2}' -f $BundleVerObj.MajorVersion, $BundleVerObj.MinorVersion, $BundleVerObj.BuildVersion)
}
catch { Write-Verbose ("Bundle finalize: could not read Version.json: {0}" -f $_.Exception.Message) }

# --- Stage 1: generate RunSummary + durable on-disk copy (unconditional). Obfuscated runs emit counts only (the wrapper holds no per-sub obfuscation dictionary); default runs include per-sub detail. The on-disk copy lives next to the report(s) in $InventoryRoot so the operator always has it even when no consolidated zip was produced (e.g. a resume run that regenerated nothing) or the stage 2 fold fails.
$RunSummaryLocalFile = $null
try
{
    $ConsumptionRecordTotal = if ($null -ne $Global:ConsumptionRecordCount) { [int]$Global:ConsumptionRecordCount } else { 0 }
    $MetricsApiCallTotal = if ($null -ne $Global:MetricsApiCallCount) { [int]$Global:MetricsApiCallCount } else { 0 }
    $RunSummaryLines = Get-RunSummaryLogContent `
        -InvocationParameters $PSBoundParameters `
        -Version $BundleVer `
        -StartTime $RunStartTime -EndTime (Get-Date) `
        -Visible $AllSubscriptions.Count -Excluded $Excluded.Count `
        -Eligible $EligibleCount -Processed ($EligibleCount - $SkippedCount) -Skipped $SkippedCount `
        -EmptyNoAccess $NoAccessSubs -EmptyGenuinelyEmpty $GenuinelyEmptySubs -EmptyUndetermined $UnknownSubs `
        -FailedSubscriptions $FailedSubscriptions `
        -CollectorFailures $Global:CollectorFailures `
        -MetricsFailedSubs $Global:MetricsFailedSubs `
        -ConsumptionFailedSubs $Global:ConsumptionFailedSubs `
        -ConsumptionRecordCount $ConsumptionRecordTotal `
        -MetricsApiCallCount $MetricsApiCallTotal `
        -ConsumptionRequested:(-not $SkipConsumption.IsPresent) `
        -MetricsRequested:(-not $SkipMetrics.IsPresent) `
        -HostVCpu $AutoTune.VCpu -HostRamGB $AutoTune.RamGB `
        -Streams $ParallelStreams -StreamsSource $StreamsSrc `
        -Concurrency $ConcurrencyLimit -ConcurrencySource $ConcurrencySrc `
        -Obfuscated:$Obfuscate
    $RunSummaryLocalFile = Join-Path $InventoryRoot ('RunSummary_{0}.log' -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'))
    $RunSummaryLines | Out-File -LiteralPath $RunSummaryLocalFile -Encoding utf8
    Write-Host ("Run summary written: {0}" -f $RunSummaryLocalFile) -ForegroundColor Green
}
catch
{
    $RunSummaryLocalFile = $null
    Write-Host ("WARNING: Could not generate the run summary: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
}

# --- Stage 2: fold RunSummary.log into the zip (isolated + verified) ---------
# Its OWN operation so a MainSummary/HTML failure in stage 3 cannot prevent the
# run summary landing in the shared bundle. Verified afterwards via the
# cross-platform .NET zip reader; if it did not persist we say so loudly and
# point at the on-disk copy from stage 1.
if ($null -ne $RunSummaryLocalFile -and (Test-Path -LiteralPath $RunSummaryLocalFile) -and `
        $null -ne $OuterZipFile -and (Test-Path -LiteralPath $OuterZipFile))
{
    $RunSummaryStage = $null
    try
    {
        $RunSummaryStage = Join-Path $InventoryRoot ('.rda-runsummary-{0}' -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
        New-Item -ItemType Directory -Path $RunSummaryStage -Force | Out-Null
        Copy-Item -LiteralPath $RunSummaryLocalFile -Destination (Join-Path $RunSummaryStage 'RunSummary.log') -Force
        Compress-Archive -LiteralPath (Join-Path $RunSummaryStage 'RunSummary.log') -DestinationPath ([WildcardPattern]::Escape($OuterZipFile)) -Update

        if (Test-ZipArchiveEntry -ZipPath $OuterZipFile -EntryName 'RunSummary.log')
        {
            Write-Host ("Run summary folded into {0}" -f (Split-Path -Path $OuterZipFile -Leaf)) -ForegroundColor Green
        }
        else
        {
            Write-Host ("WARNING: RunSummary.log did not persist into {0}; the on-disk copy remains at {1}" -f (Split-Path -Path $OuterZipFile -Leaf), $RunSummaryLocalFile) -ForegroundColor Yellow
        }
    }
    catch
    {
        Write-Host ("WARNING: Could not fold RunSummary.log into the consolidated zip (on-disk copy at {0}): {1}" -f $RunSummaryLocalFile, $_.Exception.Message) -ForegroundColor Yellow
    }
    finally
    {
        if ($null -ne $RunSummaryStage) { Remove-Item -LiteralPath $RunSummaryStage -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# --- Stage 3: fold MainSummary.html + VMPlacement.csv + per-sub HTML into the bundle. Best-effort - any failure here is a warning and can no longer take the run summary (already folded in stage 2) down with it. The bundle is the ONE artifact an operator sends, so anything tenant-wide must be INSIDE it: the observed operator response to "collect several files" is to zip the whole InventoryReports folder, which ships the obfuscation dictionary (the de-obfuscation key) and the transcripts.
# NOTE VMPlacement.csv is the first loose DATA file at the outer root (the ingestible members - Inventory_*.json, Metrics_*.json, Consumption_*.csv - otherwise all live inside the inner zips). Its root placement is INTENTIONAL and CONFIRMED by the repository owner: it is a capacity-planning input read directly by a human/planner to size nodes per availability zone, so it must be reachable without unpacking an inner archive, and it is deliberately kept OUT of the Inventory_*.json ingestion contract - do NOT move it inside the inner zips or add its columns to Inventory_*.json. The fixed root name is also why a multi-shard merge must extract each shard into its OWN folder (see docs/horizontal-sharding.md). Obfuscation-safe: VMPlacement.ps1 sources every identifier column from already-obfuscated $Global:SmaResources.
$StagedLeafNames = @()
if ($null -ne $OuterZipFile -and (Test-Path -LiteralPath $OuterZipFile))
{
    $BundleStage = $null
    try
    {
        $BundleStage = Join-Path $InventoryRoot ('.rda-bundle-{0}' -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
        New-Item -ItemType Directory -Path $BundleStage -Force | Out-Null

        # 1. Unified MainSummary.html at the bundle root, renamed from the timestamped file (its links are relative to sibling folders, so renaming the summary itself does not break them). The drill-down link folders are renamed ResourcesReport<stamp>/ -> HTML<stamp>/ (step 2) so a report-HTML folder is distinguishable at a glance from the sibling ResourcesReport_<stamp>.zip data archives; rewrite the summary's hrefs to match - only the leading folder token changes (href="ResourcesReport... -> href="HTML...), the /<file>.html tail is untouched because it is not preceded by href=".
        $StagedMainSummary = Join-Path $BundleStage 'MainSummary.html'
        if ($null -ne $MainSummaryFile -and (Test-Path -LiteralPath $MainSummaryFile))
        {
            Copy-Item -LiteralPath $MainSummaryFile -Destination $StagedMainSummary -Force
            (Get-Content -LiteralPath $StagedMainSummary -Raw) -replace 'href="ResourcesReport', 'href="HTML' | Set-Content -LiteralPath $StagedMainSummary -Encoding utf8
        }

        # 2. A copy of each per-sub HTML at HTML<stamp>/ (the source ResourcesReport<stamp> with the leading 'ResourcesReport' replaced by 'HTML'), matching the rewritten summary links. HTML only - no *.json/csv - so nothing is double-ingested and the folder name signals "report HTML, not data". Scoped to THIS run by timestamp; a de-obfuscated *_revealed* report is never copied across.
        foreach ($SubDir in @(Get-ChildItem -LiteralPath $InventoryRoot -Directory -Filter 'ResourcesReport*' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $RunStartTime }))
        {
            $SubHtml = Get-ChildItem -LiteralPath $SubDir.FullName -Filter '*.html' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '*_revealed*' } | Select-Object -First 1
            if ($null -eq $SubHtml) { continue }
            $HtmlFolderName = ($SubDir.Name -replace '^ResourcesReport', 'HTML')
            $DestDir = Join-Path $BundleStage $HtmlFolderName
            New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
            Copy-Item -LiteralPath $SubHtml.FullName -Destination (Join-Path $DestDir $SubHtml.Name) -Force
        }

        # 3. The tenant-wide VM placement CSV at the bundle root, de-timestamped to VMPlacement.csv for the same reason MainSummary_<stamp>.html becomes MainSummary.html: inside the bundle the run is already identified by the archive's own name, so a consumer can bind to a fixed member name instead of globbing. The on-disk copy KEEPS its timestamp - load-bearing for -Resume coverage (see the aggregation block above) - so it is not changed here. Guarded on both variable and file: a run with no VM rows never assigns it, and the best-effort aggregation can fail before the export.
        if (-not [string]::IsNullOrEmpty($VmPlacementFile) -and (Test-Path -LiteralPath $VmPlacementFile))
        {
            Copy-Item -LiteralPath $VmPlacementFile -Destination (Join-Path $BundleStage 'VMPlacement.csv') -Force
        }

        # Fold the staged extras into the existing outer zip (additive; the
        # inner per-sub zips already inside it are preserved by -Update).
        $StageItems = @(Get-ChildItem -LiteralPath $BundleStage -Force -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
        if ($StageItems.Count -gt 0)
        {
            # -LiteralPath, matching the outer compress: $BundleStage derives from
            # $InventoryRoot, and a '[' or ']' anywhere in that path would otherwise
            # be read as a wildcard and silently fold nothing.
            Compress-Archive -LiteralPath $StageItems -DestinationPath ([WildcardPattern]::Escape($OuterZipFile)) -Update

            # Record only WHAT WAS STAGED here. Every claim about what the bundle
            # actually contains is derived from the finished archive below, in one
            # place, so no message can assert a member it has not confirmed.
            $StagedLeafNames = @($StageItems | ForEach-Object { Split-Path -Path $_ -Leaf })
        }
    }
    catch
    {
        Write-Host ("WARNING: Could not fold main-summary / VM placement CSV / per-subscription HTML into the consolidated zip: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    }
    finally
    {
        if ($null -ne $BundleStage) { Remove-Item -LiteralPath $BundleStage -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# --- The deliverable instruction, emitted HERE (after stages 2 and 3) because this is the first point at which the bundle's membership is final: the run summary above names the path, this states what to DO with it. It exists because the previous output named the bundle but never said to send it, while the inner script printed "safe to share" once PER SUBSCRIPTION - so operators zipped the whole InventoryReports folder instead, shipping the obfuscation dictionary (the key that reverses the masking) and the transcripts, defeating -Obfuscate.
# EVERY factual claim below is derived from ONE read of the finished archive: earlier revisions hand-wrote the contents in prose and were wrong three ways (named the placement CSV on a tenant with no VMs, named the summary HTML when its best-effort build had failed, and said "every subscription" on a sharded or resumed run).
if ($null -ne $OuterZipFile -and (Test-Path -LiteralPath $OuterZipFile))
{
    $BundleMembers = @()
    try
    {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $FinalArchive = [System.IO.Compression.ZipFile]::OpenRead($OuterZipFile)
        try { $BundleMembers = @($FinalArchive.Entries | ForEach-Object { $_.FullName }) }
        finally { $FinalArchive.Dispose() }
    }
    catch
    {
        # Unreadable archive: say so rather than describing contents we cannot see.
        Write-Host ("WARNING: could not read {0} to confirm its contents: {1}" -f (Split-Path -Path $OuterZipFile -Leaf), $_.Exception.Message) -ForegroundColor Yellow
    }

    $SubZipCount = @($BundleMembers | Where-Object { $_ -notmatch '[\\/]' -and $_ -like 'ResourcesReport_*.zip' }).Count
    $HtmlFolderCount = @($BundleMembers | Where-Object { $_ -like 'HTML*/*' } | ForEach-Object { ($_ -split '[\\/]')[0] } | Select-Object -Unique).Count
    $HasMainSummary = @($BundleMembers | Where-Object { $_ -ieq 'MainSummary.html' }).Count -gt 0
    $HasPlacementCsv = @($BundleMembers | Where-Object { $_ -ieq 'VMPlacement.csv' }).Count -gt 0
    $HasRunSummary = @($BundleMembers | Where-Object { $_ -ieq 'RunSummary.log' }).Count -gt 0

    Write-Host ""
    Write-Host "================ What to send ================" -ForegroundColor Green
    Write-Host ("SEND THIS ONE FILE:  {0}" -f $OuterZipFile) -ForegroundColor Green
    if ($ShardCount -gt 1)
    {
        # Under sharding each node holds a disjoint slice, so "one file" is one file
        # PER NODE. Saying otherwise would imply this bundle covers the tenant.
        Write-Host ("  This is shard {0} of {1} - it covers only this node's subscriptions. Send one such file from EVERY shard; together they cover the tenant once." -f $ShardIndex, $ShardCount) -ForegroundColor Yellow
    }
    Write-Host "  Confirmed contents:" -ForegroundColor Green
    Write-Host ("    - {0} per-subscription data archive(s) (the subscriptions this run processed)" -f $SubZipCount) -ForegroundColor Green
    if ($HasMainSummary) { Write-Host "    - MainSummary.html (tenant-wide summary)" -ForegroundColor Green }
    if ($HtmlFolderCount -gt 0) { Write-Host ("    - {0} per-subscription HTML report folder(s)" -f $HtmlFolderCount) -ForegroundColor Green }
    if ($HasPlacementCsv) { Write-Host "    - VMPlacement.csv (tenant-wide VM placement)" -ForegroundColor Green }
    if ($HasRunSummary) { Write-Host "    - RunSummary.log (run health, needed to triage the bundle)" -ForegroundColor Green }

    # Anything staged in stage 3 but absent from the finished archive is named
    # explicitly. Silence here is the failure mode this reconciliation exists for.
    $MissingMembers = @($StagedLeafNames | Where-Object { $Leaf = $_; @($BundleMembers | Where-Object { $_ -ieq $Leaf -or $_ -like ($Leaf + '/*') }).Count -eq 0 })
    if ($MissingMembers.Count -gt 0)
    {
        Write-Host ("  WARNING: staged but NOT found inside the bundle: {0}. Their on-disk copies remain under {1}." -f (($MissingMembers | Select-Object -Unique) -join ', '), $InventoryRoot) -ForegroundColor Yellow
    }

    # The "do not send the folder" list is MODE-DEPENDENT. An obfuscated run leaves
    # the dictionary on disk and keeps the debug log local; a default run writes no
    # dictionary at all and deliberately ships the debug log INSIDE the bundle (see
    # the packaging branches in ResourceInventory.ps1), so calling it local-only
    # there would be wrong.
    if ($Obfuscate.IsPresent)
    {
        Write-Host ("  Do NOT zip or send the {0} folder itself. It also holds files that must stay local: the obfuscation dictionary (which reverses the masking), the transcripts, and the debug logs." -f (Split-Path -Path $InventoryRoot -Leaf)) -ForegroundColor Yellow
    }
    else
    {
        Write-Host ("  Do NOT zip or send the {0} folder itself. It also holds the PowerShell transcripts, which carry your signed-in account and tenant id." -f (Split-Path -Path $InventoryRoot -Leaf)) -ForegroundColor Yellow
    }
    Write-Host "=============================================" -ForegroundColor Green
}

# Per-node blob upload: when -UploadToBlobContainerUri is set, ship THIS machine's finalized consolidated zip to the shared container so an operator running many shards does not have to collect output from each node by hand. Placed AFTER the bundle is finalized (MainSummary folded in) so the uploaded artifact is complete. Passwordless: current signed-in identity via Azure AD (-UseConnectedAccount), requiring "Storage Blob Data Contributor", no key or SAS.
# Best-effort by design: a failure warns loudly but does NOT fail the run, because the zip is already safe on local disk, and erroring the pod would also trigger Job retries of the whole (already-successful) shard.
if ($UploadToBlobContainerUri -and $null -ne $OuterZipFile -and (Test-Path -LiteralPath $OuterZipFile))
{
    try
    {
        # Expect https://<account>.blob.core.windows.net/<container>[/<prefix>], parsed by the shared helper rather than a hand-copy: three character-for-character identical copies of that parse existed in this repo (exactly how they would drift apart on the next change to any one), and all three now call the helper. A fourth copy remains in deploy/Test-NodeReadiness.ps1, left deliberately because that in-pod preflight dot-sources nothing.
        $BlobParts = Split-BlobContainerUri -Uri $UploadToBlobContainerUri
        $StorageAccountName = $BlobParts.Account
        $ContainerName = $BlobParts.Container
        $BlobPrefix = $BlobParts.Prefix
        # Retained deliberately after the parse moved into the helper: the Account half
        # is still REACHABLE. A URL like https://.blob.core.windows.net/<container>
        # satisfies the earlier -UploadToBlobContainerUri preflight (https scheme, host
        # matches '\.blob\.', non-empty path) yet yields an EMPTY account, which would
        # otherwise reach New-AzStorageContext as a blank name.
        if ([string]::IsNullOrWhiteSpace($StorageAccountName) -or [string]::IsNullOrWhiteSpace($ContainerName))
        {
            throw "Could not parse '<account>' and '<container>' from -UploadToBlobContainerUri '$UploadToBlobContainerUri' (expected https://<account>.blob.core.windows.net/<container>)."
        }

        # Unique per shard + timestamp so concurrent nodes never overwrite each other.
        $ShardTag = if ($ShardCount -gt 1) { 'shard-{0}of{1}-' -f $ShardIndex, $ShardCount } else { '' }
        $BlobName = '{0}{1}{2}' -f $BlobPrefix, $ShardTag, (Split-Path -Path $OuterZipFile -Leaf)

        Write-Host ("Uploading consolidated report to blob: {0} / {1} / {2}" -f $StorageAccountName, $ContainerName, $BlobName) -ForegroundColor Cyan
        # -UseConnectedAccount uses the CURRENT Az login's identity AND its cloud
        # environment, so a sovereign / gov-cloud account is targeted correctly
        # whenever the operator connected to that cloud - no explicit endpoint is
        # needed (and -EndpointSuffix is not valid in this parameter set).
        $StorageContext = New-AzStorageContext -StorageAccountName $StorageAccountName -UseConnectedAccount -ErrorAction Stop
        $null = Set-AzStorageBlobContent -File $OuterZipFile -Container $ContainerName -Blob $BlobName -Context $StorageContext -Force -ErrorAction Stop
        Write-Host ("Blob upload complete: {0}" -f $BlobName) -ForegroundColor Green

        # Decouple compute from storage for the obfuscation dictionaries too. Each sub's ObfuscationDictionary_*.json is a LOCAL file deliberately kept OUT of the shared report zip (it is the de-obfuscation key mapping every token back to the real value); on ephemeral compute (an AKS pod's emptyDir) it dies with the node, taking with it the ONLY record of this run's token mapping - and thus the only thing that lets a later scoped/recovery run reproduce the SAME tokens via -ObfuscationDictionary seeding. Since a blob target is already configured, mirror the dictionaries to that SAME container as their OWN objects under a _dictionaries/ prefix (still NOT inside the zip), like resume state and the support-log bundle.
        # That makes this container an operator-PRIVATE artefact store that must never be handed to a report consumer as-is. Its OWN try/catch + best-effort so a dictionary-upload problem can never mask or fail the (already-successful) report upload above. Only obfuscated runs produce dictionaries; scoped to THIS run by write time so a shared InventoryRoot does not resurface a prior run's.
        try
        {
            $DictionaryFiles = @(Get-ChildItem -LiteralPath $InventoryRoot -Recurse -Filter 'ObfuscationDictionary_*.json' -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $RunStartTime })
            if ($DictionaryFiles.Count -gt 0)
            {
                Write-Host ("Uploading {0} obfuscation dictionary file(s) to blob (PRIVATE - de-obfuscation key; never share this container as-is)..." -f $DictionaryFiles.Count) -ForegroundColor Cyan
                foreach ($DictFile in $DictionaryFiles)
                {
                    $DictBlobName = '{0}_dictionaries/{1}{2}' -f $BlobPrefix, $ShardTag, $DictFile.Name
                    $null = Set-AzStorageBlobContent -File $DictFile.FullName -Container $ContainerName -Blob $DictBlobName -Context $StorageContext -Force -ErrorAction Stop
                }
                Write-Host ("Obfuscation dictionaries uploaded to {0}/{1}_dictionaries/ (keep PRIVATE)." -f $ContainerName, $BlobPrefix) -ForegroundColor Green
            }
        }
        catch
        {
            Write-Host ("WARNING: Obfuscation dictionary upload failed ({0}). The dictionaries remain on local disk under {1} - capture them before the node is reclaimed if you need token-consistent recovery later." -f $_.Exception.Message, $InventoryRoot) -ForegroundColor Yellow
        }
    }
    catch
    {
        Write-Host ("WARNING: Blob upload failed ({0}). The consolidated zip remains on local disk at: {1}" -f $_.Exception.Message, $OuterZipFile) -ForegroundColor Yellow
    }
}
elseif ($UploadToBlobContainerUri)
{
    # Upload was explicitly requested but there is no consolidated zip to send
    # (consolidation produced nothing, or it is missing). Never skip a requested
    # feature silently - say so, so the operator knows nothing was uploaded and
    # can check why the AllSubscriptions_*.zip was not produced.
    $NoZipDetail = if ($OuterZipFile) { "expected zip not found at: $OuterZipFile" } else { 'no consolidated zip was produced' }
    Write-Host ("WARNING: Blob upload was requested (-UploadToBlobContainerUri) but nothing was uploaded - {0}. Check that the run produced an AllSubscriptions_*.zip (look for the earlier 'Consolidated bundle created:' line)." -f $NoZipDetail) -ForegroundColor Yellow
}

# Final, last-thing-the-user-sees banner when a requested data phase (metrics without -SkipMetrics, consumption without -SkipConsumption) could not be collected due to authentication. Printed AFTER the summary block so it is the final output on screen. The Excel sheets are intentionally NOT annotated (server-side ingestion expects fixed columns); this banner is the human-facing signal and the non-zero exit below is the machine-facing one.
$AuthSkippedPhases = @()
if (@($Global:MetricsFailedSubs).Count -gt 0) { $AuthSkippedPhases += 'Metrics' }
$ConsumptionAuthSkipped = @(
    if ($null -ne $Global:ConsumptionFailedSubs) { $Global:ConsumptionFailedSubs } else { @() }
) | Where-Object { $_.Id -eq '(auth)' }
if ($ConsumptionAuthSkipped.Count -gt 0) { $AuthSkippedPhases += 'Consumption' }

if ($AuthSkippedPhases.Count -gt 0)
{
    Write-Host ""
    Write-Host "===================== FAILED (auth) =====================" -ForegroundColor Red
    Write-Host ("Could not collect: {0}" -f ($AuthSkippedPhases -join ' and ')) -ForegroundColor Red
    Write-Host "Reason: no usable Azure context/token (even after one reconnect attempt)." -ForegroundColor Red
    Write-Host "These were requested (no matching -Skip switch) but returned no data." -ForegroundColor Red
    Write-Host "Fix: run Connect-AzAccount (or pass -appid/-secret/-tenant), then re-run." -ForegroundColor Red
    Write-Host "The rest of the inventory completed and the report was still produced." -ForegroundColor Yellow
    Write-Host "=========================================================" -ForegroundColor Red
}

# Machine-facing signal for collector failures, distinct from the auth banner above: a collector failure is not an auth problem - one or more resource types are silently MISSING from one or more subs' reports because a Services/*.ps1 collector threw. This must be machine-detectable (not just console-visible in the summary block above), per the same "do not sweep failures under the rug" rule that drove the circuit breaker itself - a human-only signal that scrolls past in a large run is not enough for CI/automation.
if (@($Global:CollectorFailures).Count -gt 0)
{
    Write-Host ""
    Write-Host "=================== FAILED (collectors) ===================" -ForegroundColor Red
    Write-Host ("{0} collector failure(s) across {1} subscription(s) - see 'Collector Failures' above for detail." -f @($Global:CollectorFailures).Count, (@($Global:CollectorFailures | Select-Object -ExpandProperty Id -Unique)).Count) -ForegroundColor Red
    Write-Host "One or more resource types are MISSING (not empty) from the affected subscription(s)' reports." -ForegroundColor Red
    Write-Host "Re-run to retry, or investigate the error(s) above if they repeat." -ForegroundColor Red
    Write-Host "The rest of the inventory completed and the report was still produced." -ForegroundColor Yellow
    Write-Host "=========================================================" -ForegroundColor Red
}

# A subscription that finished collecting but could not write its report archive.
# Printed HERE, alongside the other failure banners and BEFORE Stop-Transcript, so
# it is captured in the wrapper transcript and the support-log bundle rather than
# only appearing on a console nobody kept.
if (@($ArchiveWriteFailures).Count -gt 0)
{
    Write-Host ""
    Write-Host "=================== FAILED (report archive) ===================" -ForegroundColor Red
    Write-Host ("{0} subscription(s) completed collection but could NOT write a report archive:" -f @($ArchiveWriteFailures).Count) -ForegroundColor Red
    foreach ($A in @($ArchiveWriteFailures))
    {
        Write-Host ("  - {0}" -f $A) -ForegroundColor Red
    }
    Write-Host "Their reports are NOT in the consolidated bundle. The per-subscription log above gives the reason" -ForegroundColor Red
    Write-Host "(free disk space is the usual one). The uncompressed report files are still in each subscription's" -ForegroundColor Red
    Write-Host "report folder under the inventory root and can be zipped by hand instead of re-collecting." -ForegroundColor Red
    Write-Host "==============================================================" -ForegroundColor Red
}

# Stop the wrapper transcript on the normal-completion path. Error paths take
# Exit-Wrapper which does the same.
if ($WrapperTranscriptStarted)
{
    try { Stop-Transcript | Out-Null }
    catch { Write-Verbose ("Stop-Transcript on normal completion failed: {0}" -f $_.Exception.Message) }
}

# Even on a run that completed and produced a report, collect the LOCAL support logs when ANY per-phase failure occurred (failed subs, collector failures, or metrics/consumption auth-skips): the consolidated report already carries RunSummary.log + per-sub scrubbed diagnostics, but this additionally bundles the local detail logs (wrapper transcript + per-sub DebugLog/ErrorLog) never in the shared zip, so the operator has one ready-to-send artefact if support needs the detail.
# Collected AFTER Stop-Transcript so the finalized transcript is captured, and scoped to this run via $RunStartTime. Failure exits are handled separately by Exit-Wrapper.
$RunHadFailures = ($FailedSubscriptions.Count -gt 0) -or (@($Global:CollectorFailures).Count -gt 0) -or (@($Global:MetricsFailedSubs).Count -gt 0) -or (@($Global:ConsumptionFailedSubs).Count -gt 0)
# Also collect the local support logs whenever a blob upload target is configured (not just on failure): the bundle is uploaded to blob, so the logs become retrievable without pod/node access. This is what surfaces an otherwise-invisible "returned 0 resources (no Reader)" run - a clean success with no failure counters - which in AKS would otherwise give the operator only an empty report zip and no way to see the per-sub warnings.
if ($RunHadFailures -or -not [string]::IsNullOrWhiteSpace($UploadToBlobContainerUri))
{
    Invoke-RdaSupportLogCollection -InventoryRoot $InventoryRoot -SinceTime $RunStartTime -ContainerUri $UploadToBlobContainerUri -ShardIndex $ShardIndex -ShardCount $ShardCount
}


$AuthSkipped = $AuthSkippedPhases.Count -gt 0
$CollectorsFailed = @($Global:CollectorFailures).Count -gt 0
$WrapperExitCode = Get-WrapperExitCode -AuthSkipped $AuthSkipped -CollectorsFailed $CollectorsFailed

# A subscription whose report archive could not be written is a MISSING REPORT, which is what exit code 2 already means (the per-subscription output gap). The verification gate cannot catch this case on its own: the failed sub is correctly excluded from the expected archive count, so the counts agree and the gate stays silent.
# Code 2 takes PRECEDENCE over 3/4/5 rather than deferring to them: those all mean "the report was produced but is incomplete in a diagnosable way" (see the exit-code table in README.md), whereas this means a subscription's report is NOT IN THE BUNDLE AT ALL - the strictly worse outcome a consumer must not miss. Letting an auth skip mask it would be the same "sweep it under the rug" failure the 3-vs-4 split exists to prevent.
if (@($ArchiveWriteFailures).Count -gt 0)
{
    $WrapperExitCode = 2
}
# Always exit with the computed wrapper code (0 on a fully clean run): an explicit exit makes $LASTEXITCODE deterministic for callers and CI. In particular the Azure DevOps AzurePowerShell@5 task runs this script via a dot-sourced wrapper where a bare fall-through would leave $LASTEXITCODE at the last native command's value - so a clean run could look non-zero and a hard-stop's own exit code would not otherwise reach the task. Exiting unconditionally lets the pipeline fail loudly on any non-zero.
exit $WrapperExitCode

