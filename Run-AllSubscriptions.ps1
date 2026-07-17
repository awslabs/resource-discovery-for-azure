param (
    [Parameter(Mandatory = $true)]
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

    # By DEFAULT the wrapper verifies control-plane read access to EVERY in-scope
    # subscription up front (one cheap native ARM resource-group read per sub)
    # and HARD-STOPS
    # before doing any work if the signed-in identity cannot read one or more of
    # them - so an auth/permission gap is surfaced and fixed up front instead of
    # producing a report silently missing subscriptions (and risking the
    # consumption cross-attribution class of bug). Pass -AllowPartialAccess to
    # override that gate: the inaccessible subscriptions are SKIPPED (listed
    # loudly in the summary) and the run proceeds with the accessible ones. Use
    # this only when you intentionally have Reader on a subset of the tenant.
    [switch]$AllowPartialAccess,

    # DEPRECATED / no-op: the aggregate "main" HTML summary (run-wide totals, a
    # per-subscription table with links to each per-sub report, and run-health
    # banners) is now produced on EVERY run and folded into the consolidated
    # AllSubscriptions zip as MainSummary.html, so the single bundle the customer
    # receives is self-contained. This switch is retained only for backward
    # compatibility with existing callers/scripts and has no effect.
    [switch]$MainSummary,

    # Also parse each per-subscription inventory to render a run-wide by-service
    # breakdown (donut + top-services bar chart) in the MainSummary. Slightly
    # slower on very large tenants (one JSON parse per subscription).
    [switch]$Detailed,

    # Forwarded to ResourceInventory.ps1's -ConcurrencyLimit. Default of 6 matches
    # the inner script's own default. The inner script uses this as the throttle
    # for its metrics-collection runspace pool (Get-AzMetric calls in
    # Extension/Metrics.ps1). Tenants with metric-heavy subscriptions (many VMs,
    # SQL DBs, Storage Accounts, Scale Sets, Container Registries) bottleneck on
    # this phase; raising the limit to 12-24 typically cuts that phase 30-50%
    # without hitting Azure Monitor's 12,000 reads/hour/subscription ceiling.
    # Don't go above ~24 in a single tenant - tenant-scoped Resource Graph
    # rate limits start to bite.
    #
    # When OMITTED, this is AUTO-TUNED from the host's CPU/RAM (see
    # Get-RecommendedParallelism in Functions/RunAllSubscriptions.Functions.ps1):
    # typically 2x vCPU bounded to [6,16]. The 6 here is only the fallback the
    # auto path clamps to; passing -ConcurrencyLimit explicitly always overrides
    # auto-tuning.
    [int]$ConcurrencyLimit = 6,

    # Number of parallel "streams" that process subscriptions concurrently.
    # When OMITTED, this is AUTO-TUNED from the host's CPU/RAM (see
    # Get-RecommendedParallelism in Functions/RunAllSubscriptions.Functions.ps1):
    # small boxes run sequentially (1), larger boxes scale to one stream per
    # ~2 vCPUs (RAM-capped), never above 6. Passing -ParallelStreams explicitly
    # always overrides auto-tuning; pass 1 to force sequential. Each stream is a
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

# ---------------------------------------------------------------------------
# PowerShell 7 bootstrap. This MUST run before the dot-source below: the helper
# files this script loads declare "#requires -Version 7.0", which Windows
# PowerShell 5.1 cannot load. Rather than fail with a blunt version error, this
# block (written in the 5.1 + 7 common language subset, so 5.1 reaches it
# instead of choking at parse time) re-launches the run under PowerShell 7,
# installing it first with consent if it is missing. On PS7+ it is a no-op and
# the script continues normally.
#
# KEEP THIS BLOCK FREE OF PS7-ONLY SYNTAX (no ternary ? :, no ?? / ??=, no
# && / ||, no ForEach-Object -Parallel). Adding any of those makes 5.1 fail to
# parse the whole script, and this bootstrap never runs.
# ---------------------------------------------------------------------------
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
            $ForwardArgs += [string]$BoundValue
        }
    }

    Write-Host ("Re-launching under PowerShell 7: {0}" -f $PwshPath) -ForegroundColor Cyan
    & $PwshPath -NoLogo -NoProfile -File $PSCommandPath @ForwardArgs
    exit $LASTEXITCODE
}

# ---------------------------------------------------------------------------
# Azure CLI bootstrap. The authentication flow and Resource Graph queries shell
# out to `az`; without it the run fails at auth with a confusing "'az' is not
# recognized". Mirror the PowerShell 7 bootstrap above: detect az, and if it is
# missing offer to install it (official Microsoft MSI) when interactive, or fail
# loud with guidance when non-interactive (never hang on a prompt).
#
# This only ever executes under PowerShell 7 (the block above re-launches 5.1
# before reaching here), but it is still kept in the 5.1 + 7 common syntax
# subset so the whole file continues to parse under Windows PowerShell 5.1.
# ---------------------------------------------------------------------------
function Resolve-AzCli
{
    $Cmd = Get-Command az -ErrorAction SilentlyContinue
    if ($Cmd)
    {
        return $Cmd.Source
    }
    # az may be installed but not yet on PATH in this session (e.g. immediately
    # after an MSI install). Probe the default install locations and, if found,
    # prepend to this process's PATH so `az` is usable without reopening.
    $WbinDirs = @()
    if ($env:ProgramFiles)
    {
        $WbinDirs += (Join-Path $env:ProgramFiles 'Microsoft SDKs\Azure\CLI2\wbin')
    }
    $ProgramFilesX86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    if ($ProgramFilesX86)
    {
        $WbinDirs += (Join-Path $ProgramFilesX86 'Microsoft SDKs\Azure\CLI2\wbin')
    }
    foreach ($WbinDir in $WbinDirs)
    {
        if (Test-Path -LiteralPath (Join-Path $WbinDir 'az.cmd'))
        {
            $env:PATH = $WbinDir + ';' + $env:PATH
            return (Join-Path $WbinDir 'az.cmd')
        }
    }
    return $null
}

$AzCliPath = Resolve-AzCli
if (-not $AzCliPath)
{
    # Install guidance is platform-specific. The automatic install below uses the
    # official Windows MSI (msiexec), which only exists on Windows; on macOS/Linux
    # there is no MSI to run, so point the operator at the correct install docs for
    # their platform and let them install it, then re-run.
    if ($IsMacOS)
    {
        $AzManualHint = '  macOS: brew install azure-cli   (docs: https://learn.microsoft.com/cli/azure/install-azure-cli-macos)'
    }
    elseif ($IsLinux)
    {
        $AzManualHint = '  Linux: https://learn.microsoft.com/cli/azure/install-azure-cli-linux'
    }
    else
    {
        $AzManualHint = '  https://aka.ms/installazurecliwindows'
    }
    $AzInteractive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected

    # Automatic install is Windows-only. On macOS/Linux, show the correct link and
    # exit instead of attempting a Windows MSI install that cannot succeed here.
    if ($IsMacOS -or $IsLinux)
    {
        Write-Host "Azure CLI (az) is required but was not found." -ForegroundColor Red
        Write-Host "Install the Azure CLI and re-run. See:" -ForegroundColor Yellow
        Write-Host $AzManualHint -ForegroundColor Yellow
        exit 1
    }

    if (-not $AzInteractive)
    {
        Write-Host "Azure CLI (az) was not found, and this is a non-interactive session, so I will not prompt to install it." -ForegroundColor Red
        Write-Host "Install the Azure CLI and re-run. See:" -ForegroundColor Yellow
        Write-Host $AzManualHint -ForegroundColor Yellow
        exit 1
    }

    Write-Host ""
    $AzAnswer = Read-Host "Azure CLI (az) is required but not installed. Install it now? [y/N]"
    if ($AzAnswer -notmatch '^(y|yes)$')
    {
        Write-Host "Not installing. Install the Azure CLI and re-run. See:" -ForegroundColor Yellow
        Write-Host $AzManualHint -ForegroundColor Yellow
        exit 1
    }

    Write-Host "Installing the Azure CLI via the official Microsoft MSI (this may prompt for elevation and can take a few minutes)..." -ForegroundColor Cyan
    try
    {
        $AzMsiPath = Join-Path $env:TEMP ('AzureCLI-' + [guid]::NewGuid().ToString() + '.msi')
        $PriorProgress = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri 'https://aka.ms/installazurecliwindowsx64' -OutFile $AzMsiPath
        $ProgressPreference = $PriorProgress
        $MsiProc = Start-Process -FilePath 'msiexec.exe' -ArgumentList ('/i "' + $AzMsiPath + '" /quiet /norestart') -Wait -PassThru
        Remove-Item -LiteralPath $AzMsiPath -Force -ErrorAction SilentlyContinue
        # 0 = success; 3010 = success but a reboot is required (az still works in
        # this session). Anything else is a genuine failure.
        if ($MsiProc.ExitCode -ne 0 -and $MsiProc.ExitCode -ne 3010)
        {
            throw ("msiexec exited with code {0}." -f $MsiProc.ExitCode)
        }
    }
    catch
    {
        Write-Host ("Automatic install failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
        Write-Host "Install the Azure CLI manually from https://aka.ms/installazurecliwindows then re-run." -ForegroundColor Yellow
        exit 1
    }

    $AzCliPath = Resolve-AzCli
    if (-not $AzCliPath)
    {
        Write-Host "Azure CLI was installed but is not visible in this session yet." -ForegroundColor Yellow
        Write-Host "Close this window, open a new PowerShell 7 (pwsh) prompt, then re-run the same command." -ForegroundColor Yellow
        exit 1
    }
    Write-Host ("Azure CLI is now available: {0}" -f $AzCliPath) -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Az PowerShell module bootstrap. The wrapper (Connect-AzAccount, Get-AzSubscription)
# and the inner script (Get-AzMetric, consumption) all require the Az module.
# Detect it, and if missing offer to install it when interactive, or fail loud
# when non-interactive - the same pre-flight treatment as PowerShell 7 and az.
#
# Why the verify step (below) matters: an earlier version installed Az from
# INSIDE the inventory run, mid-collection. That produced a half-installed module
# whose manifests were present (so a naive Get-Module -ListAvailable looked fine)
# but whose bundled MSAL/Azure.Core assemblies were missing - so the run limped on
# for ~an hour and silently produced zero consumption records. The safe pattern,
# used here, is: install BEFORE any Az call, then VERIFY by actually importing
# Az.Accounts (which loads those assemblies) and fail loud if it cannot load.
#
# 5.1 + 7 common syntax subset (only executes under 7, but must parse under 5.1).
# ---------------------------------------------------------------------------
# This tool only calls cmdlets from four Az submodules (Accounts / Compute /
# Monitor / Billing - the same set the ResourceInventory.ps1 preflight validates),
# so install and check ONLY those, NOT the full `Az` rollup. Installing `Az` pulls
# in ~80 submodules (hundreds of DLLs) and takes several minutes plus a 20-40s
# import on every run; the slim set installs in a fraction of the time and cannot
# cause "command not found" because nothing outside these four is ever called.
# Check per-submodule (a slim install has no `Az` meta-module, so the old
# Get-Module -Name Az check would have false-negatived a perfectly good install).
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
if (-not (Test-Path -Path $FunctionsFile -PathType Leaf))
{
    Write-Host "ERROR: Required functions file not found: $FunctionsFile" -ForegroundColor Red
    Write-Host "Ensure the 'Functions' folder ships alongside this script." -ForegroundColor Yellow
    exit 1
}
. $FunctionsFile

# Shared cross-cutting helpers (Write-RdaProgress). Same dot-source pattern.
$CommonFunctionsFile = Join-Path $PSScriptRoot 'Functions/Common.Functions.ps1'
if (-not (Test-Path -Path $CommonFunctionsFile -PathType Leaf))
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
if (-not (Test-Path -Path $InventoryRoot -PathType Container))
{
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
try
{
    Start-Transcript -Path $WrapperTranscriptFile -UseMinimalHeader -Force | Out-Null
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

# Resume state helpers
$ResumeStateFile = Join-Path $InventoryRoot (".resume-state-{0}.json" -f $TenantID)








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





try
{
    $CliTenant = Get-AzCliSignedInTenant
    $PsTenant = Get-AzPsSignedInTenant

    $CliTenantOk = ($CliTenant -eq $TenantID)
    $PsTenantOk = ($PsTenant -eq $TenantID)

    $CliTokenOk = $false
    $PsTokenOk = $false
    if ($CliTenantOk) { $CliTokenOk = Test-AzCliTokenSilent -Tenant $TenantID }
    if ($PsTenantOk) { $PsTokenOk = Test-AzPsTokenSilent  -Tenant $TenantID }

    $CliOk = $CliTenantOk -and $CliTokenOk
    $PsOk = $PsTenantOk -and $PsTokenOk

    if ($CliOk -and $PsOk)
    {
        Write-Host ("Existing session detected for tenant {0} (token probe ok); skipping interactive login." -f $TenantID) -ForegroundColor Green
    }
    else
    {
        if (-not $CliOk)
        {
            if ($null -eq $CliTenant)
            {
                Write-Host "az CLI is not signed in; authenticating..." -ForegroundColor Cyan
            }
            elseif (-not $CliTenantOk)
            {
                Write-Host ("az CLI is signed in to tenant {0}; switching to {1}..." -f $CliTenant, $TenantID) -ForegroundColor Cyan
            }
            else
            {
                Write-Host ("az CLI session for tenant {0} cannot acquire a token silently (likely expired or CA/MFA-gated); re-authenticating..." -f $TenantID) -ForegroundColor Cyan
            }
            if ($DeviceLogin)
            {
                az login -t $TenantID --use-device-code --only-show-errors | Out-Null
            }
            else
            {
                az login -t $TenantID --only-show-errors | Out-Null
            }
            if ($LASTEXITCODE -ne 0) { throw "az login failed with exit code $LASTEXITCODE" }
        }

        if (-not $PsOk)
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
}
catch
{
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
$SubWarnings = @()
$AllSubscriptions = Get-AzSubscription -TenantId $TenantID -WarningVariable subWarnings -WarningAction SilentlyContinue
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

# Filter out non-Enabled subscriptions by default. Disabled / Warned / Deleted
# subscriptions return little-to-no data from Resource Graph and most ARM
# data-plane calls, so processing them produces near-empty per-subscription
# reports while still costing wall-clock time (which matters for environments
# like Azure Cloud Shell where the session has a hard maximum lifetime).
# Pass -IncludeDisabled to inventory every subscription regardless of state.
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
Write-Host ("Subscriptions to process: {0}" -f $Subscriptions.Count) -ForegroundColor Cyan

# Always seed $CompletedIds from the existing state file. -Resume only
# controls whether we *use* that list to skip subscriptions; reading it
# either way ensures the per-iteration writes below append to existing
# state instead of overwriting it.
$CompletedIds = Get-CompletedSubscriptionIds -Path $ResumeStateFile -Tenant $TenantID
# Always seed $FailedAttempts the same way. Read on every run so the writes
# below preserve any existing failure history; -ResumeFailedOnly is what
# uses it to filter the subscription list.
$FailedAttempts = Get-FailedAttempts -Path $ResumeStateFile -Tenant $TenantID

# Fold in any per-stream resume-state left behind by an INTERRUPTED parallel run.
# A parallel run persists each stream's Completed/FailedAttempts to its own
# .resume-state-<tenant>-stream-<N>.json and only merges them into the unified
# file at end-of-run. If that run was killed before the merge (Ctrl+C, SIGKILL,
# Cloud Shell timeout), the failures live ONLY in the per-stream files while the
# unified file is stale. Without this, -ResumeFailedOnly reads the unified file,
# sees no failures, and wrongly reports "Nothing to retry" - silently dropping
# the retry set. Read (do NOT delete) the per-stream files here so BOTH -Resume
# (skip-completed) and -ResumeFailedOnly (retry list) see the full picture; the
# end-of-run merge still owns per-stream cleanup. Safe on non-interrupted runs: a
# cleanly-finished parallel run deletes its per-stream files, so this finds none.
# Runs at startup before any stream is launched, so it cannot race live streams.
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
                $Obj = Get-Content -Path $StreamFile.FullName -Raw | ConvertFrom-Json
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
            Save-CompletedSubscriptionIds -Path $ResumeStateFile -Tenant $TenantID -Ids $CompletedIds -FailedAttempts $FailedAttempts
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

# -ResumeFailedOnly narrows the eligible-subscription list to only those that
# have a FailedAttempts entry from a prior run. This is the targeted-retry
# workflow: a run had a handful of failures, the operator wants to re-run
# JUST those instead of walking the whole tenant again with -Resume.
#
# Filter happens here, BEFORE the -Resume "skip completed" check below, because
# in failed-only mode the resume list is the authority on what to do; the
# completed list is only checked to defend against a sub that succeeded on a
# previous retry but whose FailedAttempts entry was not yet pruned (shouldn't
# happen if the catch/success paths are correct, but cheap to defend).
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

# ---------------------------------------------------------------------------
# Up-front access gate. Before ANY per-subscription work, verify the signed-in
# identity can actually read every in-scope subscription. Azure Resource Graph
# returns 0 rows (not a 403) for a subscription the identity has no role on, so a
# permission gap is otherwise invisible until the report comes back silently
# missing subscriptions - and can feed the consumption cross-attribution class of
# bug. Catch it here instead. By default any inaccessible subscription HARD-STOPS
# the run so the operator fixes access first; -AllowPartialAccess overrides that
# to skip the inaccessible ones and continue. On -Resume only the subscriptions
# this run will actually process (not already-completed ones) are probed. Runs
# once in the parent, before the sequential/parallel split, so it gates both.
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
        if ($AccessDecision.ShouldBlock)
        {
            Write-Host "  Stopping before any work. Grant the identity Reader on these subscriptions, then re-run." -ForegroundColor Red
            Write-Host "  (Or pass -AllowPartialAccess to skip them and inventory only the accessible subscriptions.)" -ForegroundColor Red
            Exit-Wrapper -Code 1
        }
        Write-Host "  -AllowPartialAccess set: skipping the above and continuing with the accessible subscription(s)." -ForegroundColor Yellow
        $Subscriptions = @($Subscriptions | Where-Object { $AccessDecision.InaccessibleIds -notcontains $_.Id })
        if ($Subscriptions.Count -eq 0)
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
# Up-front consumption (billing) access gate. Consumption was REQUESTED unless
# -SkipConsumption was passed. If the signed-in identity is not authorized to
# read consumption data, every subscription's consumption phase would fail and
# the run would produce reports silently missing the billing data the operator
# explicitly asked for. That is a HARD failure - fail fast, before spending
# time on inventory and metrics, rather than hand back an incomplete report.
#
# Runs AFTER the access gate above, so $Subscriptions[0] is already known to be
# control-plane-readable (inaccessible subs have either hard-stopped the run or,
# under -AllowPartialAccess, been removed from $Subscriptions) - a 403 here is
# therefore a genuine BILLING-RBAC denial, not just "no role on that sub".
# consumption/billing RBAC is usually uniform across a tenant, so we probe the
# FIRST subscription as the access signal. We hard-fail ONLY on a clear
# authorization denial; a transient/token error (Conditional Access, expired
# token, throttling) is NOT treated as a hard failure here - that is the
# recoverable class the per-subscription consumption phase already handles and
# reports. Operators who genuinely have mixed per-subscription billing access
# can use -SkipConsumption.
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

# ---------------------------------------------------------------------------
# Auto-tune parallelism to the host (dummy-proof defaults).
#
# When the operator does not pass -ParallelStreams / -ConcurrencyLimit, size them
# from the detected CPU/RAM so an out-of-the-box run does the sensible thing on
# this machine - e.g. a small 2 vCPU / 4 GB box runs sequentially, which is
# faster there than two streams fighting over the cores. Advanced users keep
# full control: any value passed explicitly is honored as-is and only the omitted
# one is auto-filled. $PSBoundParameters is a reliable "did the operator set
# this?" test here because the PS7 relaunch above forwards only bound params.
# The existing clamp to the eligible subscription count still applies below.
$AutoTune = Get-RecommendedParallelism
$StreamsAuto = -not $PSBoundParameters.ContainsKey('ParallelStreams')
$ConcurrencyAuto = -not $PSBoundParameters.ContainsKey('ConcurrencyLimit')
if ($StreamsAuto) { $ParallelStreams = $AutoTune.Streams }
if ($ConcurrencyAuto) { $ConcurrencyLimit = $AutoTune.Concurrency }

$RamLabel = if ($AutoTune.RamGB -gt 0) { '{0} GB RAM' -f $AutoTune.RamGB } else { 'RAM undetected' }
$StreamsSrc = if ($StreamsAuto) { 'auto' } else { 'explicit' }
$ConcurrencySrc = if ($ConcurrencyAuto) { 'auto' } else { 'explicit' }
Write-Host ("Host: {0} vCPU / {1}." -f $AutoTune.VCpu, $RamLabel) -ForegroundColor DarkGray
Write-Host ("Parallelism: -ParallelStreams {0} ({1}), -ConcurrencyLimit {2} ({3}). Pass either flag to override." -f $ParallelStreams, $StreamsSrc, $ConcurrencyLimit, $ConcurrencySrc) -ForegroundColor DarkGray

# Build passthrough hashtable for optional switches
$InventoryPassthrough = @{}
if ($DeviceLogin) { $InventoryPassthrough['DeviceLogin'] = $true }
if ($Obfuscate) { $InventoryPassthrough['Obfuscate'] = $true }
if ($SkipMetrics) { $InventoryPassthrough['SkipMetrics'] = $true }
if ($SkipConsumption) { $InventoryPassthrough['SkipConsumption'] = $true }
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
            & (Join-Path $PSScriptRoot "ResourceInventory.ps1") -TenantID $TenantID -SubscriptionID $Sub.Id @InventoryPassthrough -RunAllSubs
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
            $ResCount = if ($null -ne $Global:Resources) { @($Global:Resources).Count } else { 0 }
            $SubResourceCounts += [pscustomobject]@{
                Name  = $Sub.Name
                Id    = $Sub.Id
                Count = $ResCount
            }

            if ($ResCount -eq 0)
            {
                # Loud yellow signal so this stands out in the per-iteration narration
                # and in the wrapper transcript. The most common cause is the signed-in
                # identity not having Reader on the subscription; second is a sub that
                # genuinely has no resources. Either way the user almost always wants
                # to know immediately rather than discover it days later when the
                # consolidated report turns out to be empty for some subs.
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
                Save-CompletedSubscriptionIds -Path $ResumeStateFile -Tenant $TenantID -Ids $CompletedIds -FailedAttempts $FailedAttempts
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
                $InventoryRoot = if ($PSVersionTable.Platform -eq 'Unix') { "$HOME/InventoryReports" } else { "C:\InventoryReports" }
                if (Test-Path $InventoryRoot)
                {
                    $RootDrive = (Get-Item $InventoryRoot).PSDrive
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
                $InventoryRoot = if ($PSVersionTable.Platform -eq 'Unix') { "$HOME/InventoryReports" } else { "C:\InventoryReports" }
                if (-not (Test-Path $InventoryRoot))
                {
                    try { New-Item -ItemType Directory -Path $InventoryRoot -Force | Out-Null }
                    catch { Write-Verbose ("InventoryRoot create failed at {0}: {1}" -f $InventoryRoot, $_.Exception.Message) }
                }
                $DiagFile = Join-Path $InventoryRoot ("RunAllSubscriptions_failures_{0}_{1}.log" -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss-fff'), [guid]::NewGuid().ToString().Substring(0, 4))
            }
            try { $DiagLines | Out-File -FilePath $DiagFile -Append -Encoding utf8 }
            catch { Write-Verbose ("DiagFile write failed at {0}: {1}" -f $DiagFile, $_.Exception.Message) }

            $FailedSubscriptions += $Sub.Name
            # Persist the failure to the resume-state file so a future run with
            # -ResumeFailedOnly can target it. Use the exception message as the
            # Reason so the operator can see at a glance why each sub failed
            # without opening the diag log.
            $FailedAttempts = Add-FailedAttempt -Existing $FailedAttempts `
                -Id $Sub.Id -Name $Sub.Name `
                -Reason $ErrRecord.Exception.Message
            Save-CompletedSubscriptionIds -Path $ResumeStateFile -Tenant $TenantID -Ids $CompletedIds -FailedAttempts $FailedAttempts
        }

        Write-Host "-----------------------------------" -ForegroundColor Gray
    }

    Write-RdaProgress -Activity 'Processing subscriptions' -Completed

}
else
{
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
                & (Join-Path $PSScriptRoot "ResourceInventory.ps1") -TenantID $TenantID -SubscriptionID $Sub.Id @InventoryPassthrough -RunAllSubs
                # Same null-guard as the sequential branch above.
                if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "Script exited with code $LASTEXITCODE" }
                $ResCount = if ($null -ne $Global:Resources) { @($Global:Resources).Count } else { 0 }
                $SubResourceCounts += [pscustomobject]@{ Name = $Sub.Name; Id = $Sub.Id; Count = $ResCount }
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
                    Save-CompletedSubscriptionIds -Path $ResumeStateFile -Tenant $TenantID -Ids $CompletedIds -FailedAttempts $FailedAttempts
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
                try { $DiagLines | Out-File -FilePath $DiagFile -Append -Encoding utf8 }
                catch { Write-Verbose ("DiagFile write failed at {0}: {1}" -f $DiagFile, $_.Exception.Message) }
                $FailedSubscriptions += $Sub.Name
                # Mirror the sequential branch: persist failure to the
                # resume-state file so -ResumeFailedOnly works even for the
                # single-sub-collapses-to-inline corner case.
                $FailedAttempts = Add-FailedAttempt -Existing $FailedAttempts `
                    -Id $Sub.Id -Name $Sub.Name `
                    -Reason $ErrRecord.Exception.Message
                Save-CompletedSubscriptionIds -Path $ResumeStateFile -Tenant $TenantID -Ids $CompletedIds -FailedAttempts $FailedAttempts
            }
        }
        # Skip the parallel orchestration entirely; fall through to the
        # post-processing (consolidation, summary) below.
        $StreamCount = 0
    }
    if ($StreamCount -ge 2)
    {

        # Snapshot the parent's Az context to a shared file so each stream can
        # Import-AzContext without prompting. Save-AzContext writes a JSON file
        # containing a token cache, so it MUST NOT be left on disk after the
        # run completes - that's the responsibility of the `finally` block
        # below, which guarantees cleanup even on stream-launch crash, on
        # Receive-Job failure, or on Ctrl+C.
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
            if (Test-Path -Path $AzContextSnapshot)
            {
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
        $Jobs = @()
        $StreamSummaries = @()
        try
        {
            $WorkerScript = Join-Path $PSScriptRoot 'Run-AllSubscriptions.Stream.ps1'
            if (-not (Test-Path -Path $WorkerScript -PathType Leaf))
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

                # Pass arguments to the worker via a single hashtable so the worker
                # script's named parameters bind correctly. Start-Job's -FilePath
                # mode passes ArgumentList positionally which collides with our
                # named-parameter contract. Switches are only included when they
                # are set, since switch parameters bind correctly from a splatted
                # hashtable when present with value $true.
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
            # Initial drain handles the case where every stream crashes immediately
            # (jobs reach Completed state in <1500 ms, so the loop predicate would
            # otherwise be false on first check and we'd skip output streaming).
            # Drain output once before the polling loop, in case all streams
            # finished synchronously between Start-Job and our first poll
            # (jobs reach Completed state in <1500 ms, so the loop predicate would
            # otherwise be false on first check and we'd skip output streaming).
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
                if (-not (Test-Path -Path $S.SummaryPath -PathType Leaf))
                {
                    Write-Host ("[stream-{0}] WARNING: no summary file at {1} - the stream did not finish cleanly" -f $S.StreamId, $S.SummaryPath) -ForegroundColor Yellow
                    $FailedSubscriptions += ("stream-{0} (no summary)" -f $S.StreamId)
                    continue
                }
                try
                {
                    $StreamSummary = Get-Content -Path $S.SummaryPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
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
                        $SubResourceCounts += [pscustomobject]@{
                            Name  = $rc.Name
                            Id    = $rc.Id
                            Count = [int]$rc.Count
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

                # If a stream wrote a failures log, add it to the wrapper's diag-file
                # accumulator so the final summary surfaces the path. The wrapper's
                # existing $DiagFile was nullable; using a single concatenated log
                # avoids breaking that contract.
                if ((Test-Path -Path $S.FailuresPath -PathType Leaf) -and ((Get-Item $S.FailuresPath).Length -gt 0))
                {
                    if ($null -eq $DiagFile)
                    {
                        $DiagFile = Join-Path $InventoryRoot ("RunAllSubscriptions_failures_{0}_{1}.log" -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss-fff'), [guid]::NewGuid().ToString().Substring(0, 4))
                    }
                    try
                    {
                        Get-Content -Path $S.FailuresPath -Raw | Out-File -FilePath $DiagFile -Append -Encoding utf8
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
                if (Test-Path -Path $S.SummaryPath)
                {
                    try { Remove-Item -Path $S.SummaryPath -Force } catch { Write-Verbose ("Could not remove stream summary {0}: {1}" -f $S.SummaryPath, $_.Exception.Message) }
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
            $AllCompletedFromStreams = @()
            $AllFailedFromStreams = @()
            foreach ($StreamFile in $AllStreamFiles)
            {
                $PerStreamFile = $StreamFile.FullName
                try
                {
                    $Obj = Get-Content -Path $PerStreamFile -Raw | ConvertFrom-Json
                    if ($null -ne $Obj.Completed)
                    {
                        $AllCompletedFromStreams += @($Obj.Completed)
                    }
                    # Per-stream files written by workers also carry their
                    # FailedAttempts entries. Merge by Id so the unified
                    # state file reflects every stream's failures, with the
                    # most-recent attempt's Reason/LastFailedAt winning when
                    # the same sub appears in multiple streams (which would
                    # only happen across re-runs with different slicing).
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
            if ($AllCompletedFromStreams.Count -gt 0)
            {
                $CompletedIds = @($CompletedIds + $AllCompletedFromStreams | Sort-Object -Unique)
            }
            # Reconcile failed attempts from all streams against the unified list.
            # See Merge-FailedAttempts for the recency/completion rules.
            $FailedAttempts = Merge-FailedAttempts -ExistingFailedAttempts $FailedAttempts -StreamFailedAttempts $AllFailedFromStreams -CompletedIds $CompletedIds
            if ($AllCompletedFromStreams.Count -gt 0 -or $AllFailedFromStreams.Count -gt 0)
            {
                Save-CompletedSubscriptionIds -Path $ResumeStateFile -Tenant $TenantID -Ids $CompletedIds -FailedAttempts $FailedAttempts
            }
            # Also delete per-stream resume files now that the unified file holds
            # the truth - this prevents drift if a future run uses a different
            # stream count. Reuses the same on-disk discovery ($AllStreamFiles)
            # as the merge loop above, so every file that was just merged is also
            # the one that gets cleaned up here - regardless of this run's
            # -ParallelStreams value.
            foreach ($StreamFile in $AllStreamFiles)
            {
                $PerStreamFile = $StreamFile.FullName
                try { Remove-Item -Path $PerStreamFile -Force } catch { Write-Verbose ("Could not remove stream resume file {0}: {1}" -f $PerStreamFile, $_.Exception.Message) }
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
            if (Test-Path -Path $AzContextSnapshot)
            {
                try
                {
                    Remove-Item -Path $AzContextSnapshot -Force -ErrorAction Stop
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
$ExpectedZipCount = @($SubResourceCounts).Count
if ($ExpectedZipCount -gt 0 -and (Test-Path -Path $InventoryRoot -PathType Container))
{
    $ActualSubZips = @(Get-ChildItem -Path $InventoryRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object { Get-ChildItem -Path $_.FullName -Filter "*.zip" -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $RunStartTime } })
    $ActualZipCount = $ActualSubZips.Count
    if ($ActualZipCount -lt $ExpectedZipCount)
    {
        $MissingCount = $ExpectedZipCount - $ActualZipCount
        Write-Host ""
        Write-Host "ERROR: Per-subscription output verification failed." -ForegroundColor Red
        Write-Host ("  Expected zips: {0} (one per subscription that ran to completion this run)" -f $ExpectedZipCount) -ForegroundColor Red
        Write-Host ("  Found zips:    {0} (filter: under {1}, LastWriteTime >= {2:o})" -f $ActualZipCount, $InventoryRoot, $RunStartTime) -ForegroundColor Red
        Write-Host ("  Gap:           {0} missing per-subscription zip(s)." -f $MissingCount) -ForegroundColor Red
        Write-Host ""
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
        Write-Host "  - Locating the missing per-sub directory under the inventory root and inspecting why its zip is absent, OR" -ForegroundColor Yellow
        Write-Host "  - Re-running with -Resume to re-collect any unprocessed/missing subscription." -ForegroundColor Yellow
        if ($WrapperTranscriptStarted)
        {
            Write-Host ("Wrapper Transcript:      {0}" -f $WrapperTranscriptFile) -ForegroundColor Yellow
        }
        Exit-Wrapper -Code 2
    }
    Write-Host ("Per-subscription output verification: OK ({0} zip(s) match {0} successful sub(s))" -f $ActualZipCount) -ForegroundColor Green
}

# Consolidate per-subscription ZIPs into a single outer ZIP
$OuterZipFile = $null

if (Test-Path -Path $InventoryRoot -PathType Container)
{
    # Filter ZIPs by current run timestamp only
    $SubZips = @(Get-ChildItem -Path $InventoryRoot -Directory | ForEach-Object { Get-ChildItem -Path $_.FullName -Filter "*.zip" -File | Where-Object { $_.LastWriteTime -ge $RunStartTime } })
    if ($SubZips.Count -gt 0)
    {
        $Timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
        $OuterZipFile = Join-Path $InventoryRoot "AllSubscriptions_ResourcesReport_$Timestamp.zip"
        Write-Host ("Compressing {0} per-subscription report(s) into: {1}" -f $SubZips.Count, $OuterZipFile) -ForegroundColor Cyan
        Compress-Archive -Path $SubZips.FullName -DestinationPath $OuterZipFile -Force
        Write-Host ("Reporting Data File: {0}" -f $OuterZipFile) -ForegroundColor Green
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

# Aggregate "main" HTML summary across all per-subscription reports from
# THIS run. Built on EVERY run that produced a consolidated zip (it was
# previously opt-in via -MainSummary; that switch is now implied and the
# summary is always produced + folded into the bundle below). -Detailed
# still adds the run-wide by-service charts. Built purely from the on-disk
# per-sub artefacts (Inventory_*.json + sibling .html) scoped to
# $RunStartTime - no Azure calls. A failure here must never fail the run:
# the per-sub reports and the consolidated zip are already written, so any
# error is downgraded to a warning and $MainSummaryFile is left $null.
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
        if (-not (Test-Path -Path $AllSubSummaryFunctions -PathType Leaf))
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

# Clean up resume state on a fully successful run (all subs processed, no failures
# this run AND no pending retries from a prior run). Otherwise leave it so a
# future -Resume / -ResumeFailedOnly invocation can pick up where this stopped.
if ($FailedSubscriptions.Count -eq 0 -and $FailedAttempts.Count -eq 0 -and (Test-Path -Path $ResumeStateFile -PathType Leaf))
{
    try
    {
        Remove-Item -Path $ResumeStateFile -Force
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
Write-Host ("Subscriptions Eligible:  {0}" -f $Subscriptions.Count) -ForegroundColor Green
# In parallel mode, $SkippedCount is not populated by the foreach loop above
# (each worker skips independently). Derive it from the difference between
# the number of eligible subs and the number of subs that actually ran in
# this invocation (the union of $SubResourceCounts entries plus failures).
if ($ParallelStreams -gt 1 -and $Resume -and $SkippedCount -eq 0)
{
    $ActuallyProcessed = ($SubResourceCounts | Measure-Object).Count + $FailedSubscriptions.Count
    $DerivedSkip = $Subscriptions.Count - $ActuallyProcessed
    if ($DerivedSkip -gt 0) { $SkippedCount = $DerivedSkip }
}
if ($Resume)
{
    Write-Host ("Subscriptions Skipped:   {0} (already completed)" -f $SkippedCount) -ForegroundColor Green
}
Write-Host ("Subscriptions Processed: {0}" -f ($Subscriptions.Count - $SkippedCount)) -ForegroundColor Green

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

    # Persist the per-subscription access verdict to the diagnostic log so it
    # outlives the console/transcript and can be attached to a ticket or e-mail.
    # This is the durable record behind the on-screen labels above: which
    # 0-resource subs are a permission gap (fix: grant Reader, re-run -Resume)
    # vs genuinely empty (no action). Reuses the run's $DiagFile if one already
    # exists (e.g. from a failure), otherwise creates one.
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
        $EmptyDiag | Out-File -FilePath $DiagFile -Append -Encoding utf8
        Write-Host ("  Access verdict written to diagnostic log: {0}" -f $DiagFile) -ForegroundColor DarkGray
    }
    catch
    {
        Write-Verbose ("Diagnostic log write failed at {0}: {1}" -f $DiagFile, $_.Exception.Message)
    }
    Write-Host ""
}

# Surface consumption (billing) data health. The inner script's consumption
# loop populates these globals; if every Get-UsageAggregates call failed
# (typically because the Az PowerShell module is broken on disk and cannot
# load its bundled MSAL/Azure.Core assemblies) the customer ends up with an
# empty consumption sheet and no signal that anything went wrong. Make it
# loud here so it's caught before the report is shared.
$ConsumptionRecords = if ($null -ne $Global:ConsumptionRecordCount) { [int]$Global:ConsumptionRecordCount } else { 0 }
$ConsumptionFailures = if ($null -ne $Global:ConsumptionFailedSubs) { @($Global:ConsumptionFailedSubs) } else { @() }
if ($ConsumptionRecords -gt 0 -or $ConsumptionFailures.Count -gt 0)
{
    Write-Host ("Consumption Records:     {0:N0} record(s) collected" -f $ConsumptionRecords) -ForegroundColor Green
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

# Surface metrics-phase auth health. Mirrors the consumption block above:
# metrics were requested (no -SkipMetrics) but skipped because no usable Azure
# context/token could be established even after a reconnect attempt. Without
# this the metrics sheet is silently empty and looks like "no metric-eligible
# resources" rather than an auth failure. Listed per-subscription so the
# operator knows exactly which subs are missing metrics.
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

# Surface collector failures (#22). A Services/*/*.ps1 collector threw for a
# specific subscription and was caught by ResourceInventory.ps1's circuit
# breaker (CreateResourceJobs); that resource type is missing from the
# affected subscription's report, not silently empty because none exist.
# Grouped by subscription so the operator can see exactly which sub(s) and
# which resource type(s) were affected without hunting through per-sub logs.
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
    if ($DiagFile -and (Test-Path $DiagFile))
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
    Write-Host ("Consolidated Report:     {0}" -f $OuterZipFile) -ForegroundColor Green
}
if ($WrapperTranscriptStarted)
{
    Write-Host ("Wrapper Transcript:      {0}" -f $WrapperTranscriptFile) -ForegroundColor Green
}
Write-Host "=========================================" -ForegroundColor Green

# --- Fold run-level extras into the consolidated bundle --------------
# Make the single AllSubscriptions zip the customer receives self-contained.
# It already holds the per-subscription inner zips (the ingestion payload,
# left untouched); here we ADD a run-level RunSummary.log (parameters + sub
# tally + health) and the unified MainSummary.html, plus a copy of each
# per-subscription HTML so the summary's drill-down links resolve straight
# out of the extracted zip. Only additive members are folded in and NO loose
# *.json is added, so the ingestion contract (inner-zip *.json members) is
# unchanged and nothing is double-ingested. Best-effort: any failure is a
# warning - the per-sub reports and the outer zip are already written.
if ($null -ne $OuterZipFile -and (Test-Path -LiteralPath $OuterZipFile))
{
    try
    {
        $BundleStage = Join-Path $InventoryRoot ('.rda-bundle-{0}' -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
        New-Item -ItemType Directory -Path $BundleStage -Force | Out-Null

        # Version is display-only. Prefer Version.json (in parallel mode the
        # wrapper's $Global:Version is never set - child processes set it),
        # fall back to $Global:Version then blank.
        $BundleVer = $Global:Version
        try
        {
            $BundleVerObj = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Version.json') -Raw | ConvertFrom-Json
            $BundleVer = ('{0}.{1}.{2}' -f $BundleVerObj.MajorVersion, $BundleVerObj.MinorVersion, $BundleVerObj.BuildVersion)
        }
        catch { Write-Verbose ("Bundle finalize: could not read Version.json: {0}" -f $_.Exception.Message) }

        # 1. RunSummary.log - run-level parameters + tally + health. Obfuscated
        #    runs emit counts only (the wrapper holds no per-sub obfuscation
        #    dictionary); default runs include per-sub detail.
        $ConsumptionRecordTotal = if ($null -ne $Global:ConsumptionRecordCount) { [int]$Global:ConsumptionRecordCount } else { 0 }
        $RunSummaryLines = Get-RunSummaryLogContent `
            -InvocationParameters $PSBoundParameters `
            -Version $BundleVer `
            -StartTime $RunStartTime -EndTime (Get-Date) `
            -Visible $AllSubscriptions.Count -Excluded $Excluded.Count `
            -Eligible $Subscriptions.Count -Processed ($Subscriptions.Count - $SkippedCount) -Skipped $SkippedCount `
            -EmptyNoAccess $NoAccessSubs -EmptyGenuinelyEmpty $GenuinelyEmptySubs -EmptyUndetermined $UnknownSubs `
            -FailedSubscriptions $FailedSubscriptions `
            -CollectorFailures $Global:CollectorFailures `
            -MetricsFailedSubs $Global:MetricsFailedSubs `
            -ConsumptionFailedSubs $Global:ConsumptionFailedSubs `
            -ConsumptionRecordCount $ConsumptionRecordTotal `
            -HostVCpu $AutoTune.VCpu -HostRamGB $AutoTune.RamGB `
            -Streams $ParallelStreams -StreamsSource $StreamsSrc `
            -Concurrency $ConcurrencyLimit -ConcurrencySource $ConcurrencySrc `
            -Obfuscated:$Obfuscate
        $RunSummaryLines | Out-File -FilePath (Join-Path $BundleStage 'RunSummary.log') -Encoding utf8

        # 2. Unified MainSummary.html at the bundle root (renamed from the
        #    timestamped file; its links are relative to sibling folders, so
        #    renaming the summary itself does not break them). The drill-down
        #    link folders are then renamed from ResourcesReport<stamp>/ to
        #    HTML<stamp>/ (see step 3) - these bundle folders carry ONLY the
        #    report HTML, so the HTML prefix distinguishes them at a glance
        #    from the sibling ResourcesReport_<stamp>.zip data archives (which
        #    hold the Inventory/Metrics/Consumption members). Rewrite the
        #    summary's hrefs to match: only the leading folder token changes
        #    (href="ResourcesReport... -> href="HTML...); the /<file>.html tail
        #    is untouched because it is not preceded by href=".
        $StagedMainSummary = Join-Path $BundleStage 'MainSummary.html'
        if ($null -ne $MainSummaryFile -and (Test-Path -LiteralPath $MainSummaryFile))
        {
            Copy-Item -LiteralPath $MainSummaryFile -Destination $StagedMainSummary -Force
            (Get-Content -LiteralPath $StagedMainSummary -Raw) -replace 'href="ResourcesReport', 'href="HTML' | Set-Content -LiteralPath $StagedMainSummary -Encoding utf8
        }

        # 3. A copy of each per-subscription HTML at HTML<stamp>/ (the folder
        #    name is the source ResourcesReport<stamp> with the leading
        #    'ResourcesReport' replaced by 'HTML'), matching the rewritten
        #    summary links. HTML only - no *.json/csv - so nothing is
        #    double-ingested and the folder name signals "report HTML, not
        #    data". Scoped to THIS run by timestamp; a de-obfuscated
        #    *_revealed* report is never copied across.
        foreach ($SubDir in @(Get-ChildItem -Path $InventoryRoot -Directory -Filter 'ResourcesReport*' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $RunStartTime }))
        {
            $SubHtml = Get-ChildItem -Path $SubDir.FullName -Filter '*.html' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '*_revealed*' } | Select-Object -First 1
            if ($null -eq $SubHtml) { continue }
            $HtmlFolderName = ($SubDir.Name -replace '^ResourcesReport', 'HTML')
            $DestDir = Join-Path $BundleStage $HtmlFolderName
            New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
            Copy-Item -LiteralPath $SubHtml.FullName -Destination (Join-Path $DestDir $SubHtml.Name) -Force
        }

        # Fold the staged extras into the existing outer zip (additive; the
        # inner per-sub zips already inside it are preserved by -Update).
        $StageItems = @(Get-ChildItem -Path $BundleStage -Force -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
        if ($StageItems.Count -gt 0)
        {
            Compress-Archive -Path $StageItems -DestinationPath $OuterZipFile -Update
            Write-Host ("Bundle finalized: RunSummary.log + MainSummary.html folded into {0}" -f (Split-Path -Path $OuterZipFile -Leaf)) -ForegroundColor Green
        }
        Remove-Item -LiteralPath $BundleStage -Recurse -Force -ErrorAction SilentlyContinue
    }
    catch
    {
        Write-Host ("WARNING: Could not fold run-summary / main-summary into the consolidated zip: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    }
}

# Final, last-thing-the-user-sees banner when a requested data phase could not
# be collected due to authentication. Printed AFTER the summary block so it is
# the final output on screen. Covers metrics (no -SkipMetrics) and consumption
# (no -SkipConsumption) auth skips. The Excel sheets are intentionally NOT
# annotated (server-side ingestion expects fixed columns); this banner is the
# human-facing signal, and the non-zero exit below is the machine-facing one.
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

# Machine-facing signal for collector failures (#22), distinct from the auth
# banner above. A collector failure is not an auth problem - it means one or
# more resource types are silently MISSING from one or more subscriptions'
# reports because a Services/*/*.ps1 collector threw. This must be
# machine-detectable (not just console-visible in the summary block above),
# per the same "do not sweep failures under the rug" requirement that drove
# the circuit breaker itself - a human-only signal that scrolls past in a
# large multi-subscription run is not good enough for CI/automation.
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

# Stop the wrapper transcript on the normal-completion path. Error paths take
# Exit-Wrapper which does the same.
if ($WrapperTranscriptStarted)
{
    try { Stop-Transcript | Out-Null }
    catch { Write-Verbose ("Stop-Transcript on normal completion failed: {0}" -f $_.Exception.Message) }
}


$AuthSkipped = $AuthSkippedPhases.Count -gt 0
$CollectorsFailed = @($Global:CollectorFailures).Count -gt 0
$WrapperExitCode = Get-WrapperExitCode -AuthSkipped $AuthSkipped -CollectorsFailed $CollectorsFailed
if ($WrapperExitCode -ne 0)
{
    exit $WrapperExitCode
}

