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
    # failures, prints "Nothing to retry", names any subscription an interrupted
    # run never reached, and exits 2 while one is named (0 when none). Works with
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
# A script folder whose path holds a wildcard character ([ ] * ?, the last two
# allowed in folder names on Linux and macOS) cannot be used: the collector
# (ResourceInventory.ps1) finds its own files and its Services/*.ps1 with
# wildcard paths, so it would fail, or load the scripts of another folder the
# pattern matches. Stopped here, before PowerShell 7, the Azure CLI or the Az
# modules are offered or installed and before any file is read or written
# (Windows PowerShell 5.1 syntax, like the block below).
if ($PSScriptRoot.IndexOfAny([char[]]'[]*?') -ge 0)
{
    Write-Host ("ERROR: The script folder {0} has [ ] * or ? in its path, which this tool cannot run from. Move the folder to a path without them and run again." -f $PSScriptRoot) -ForegroundColor Red
    exit 1
}
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
$RequiredAzSubModules = @('Az.Accounts', 'Az.Compute', 'Az.Monitor', 'Az.Billing')
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
    Write-Host "  Install-Module -Name Az.Accounts,Az.Compute,Az.Monitor,Az.Billing -Repository PSGallery -Force -AllowClobber -SkipPublisherCheck -Scope CurrentUser" -ForegroundColor Yellow
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
$FailedSubscriptions = @()
# Set by Save-CompletedSubscriptionIds when a save of the resume state fails.
$ResumeStateSaveFailed = $false

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
# The report folders and zips already there when this run starts: never this
# run's, whatever the clock says (a clock moved back could date an old one
# after this run's start), so the bundle cannot take an old copy of a
# subscription this run collects again.
$PreRunReportDirs = [System.Collections.Generic.HashSet[string]]::new([string[]]@(Get-ChildItem -Path $InventoryRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }), [System.StringComparer]::OrdinalIgnoreCase)
$PreRunZips = [System.Collections.Generic.HashSet[string]]::new([string[]]@(foreach ($Dir in $PreRunReportDirs) { Get-ChildItem -LiteralPath $Dir -Filter '*.zip' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName } }), [System.StringComparer]::OrdinalIgnoreCase)

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
$SubErrors = @()
$AllSubscriptions = Get-AzSubscription -TenantId $TenantID -WarningVariable subWarnings -WarningAction SilentlyContinue -ErrorVariable subErrors
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
# @() keeps it an array: an empty or one-id result comes back from the
# function as $null or a bare string, and `+=` on a string joins the next id
# onto it. Where-Object drops the null entry that a state file saved after a
# failed first subscription can hold.
$CompletedIds = @(Get-CompletedSubscriptionIds -Path $ResumeStateFile -Tenant $TenantID | Where-Object { $_ })
# Always seed $FailedAttempts the same way. Read on every run so the writes
# below preserve any existing failure history; -ResumeFailedOnly is what
# uses it to filter the subscription list.
$FailedAttempts = Get-FailedAttempts -Path $ResumeStateFile -Tenant $TenantID
# The report zip each completed subscription recorded (New-CompletedReportRecord).
# A -Resume run carries these into the consolidated zip for the subscriptions it
# skips; every save below writes them back.
$CompletedReports = Get-CompletedReports -Path $ResumeStateFile -Tenant $TenantID
# The subscriptions an earlier access check skipped as not readable, so
# -ResumeFailedOnly does not name them as never collected. Updated after this
# run's access check below.
$NotReadableIds = @(Get-NotReadableSubscriptionIds -Path $ResumeStateFile -Tenant $TenantID)
# Whether the state file was written before CompletedReports existed, for the
# message of the -Resume block below. Read now, before the fold of per-stream
# state can rewrite the file.
$StateWithoutReports = Test-ResumeStateWithoutReports -Path $ResumeStateFile -Tenant $TenantID

# Per-stream resume state files that could not be read, at the start or in the
# end-of-run merge. Their records are not used, so the run is not clean while
# one is there: it keeps the state and ends with exit 2, and it names each file
# with what to do: it is renamed aside to <name>.unreadable-<time>, out of reach
# of every later run, to be fixed and renamed back, or deleted.
$UnreadableStreamFiles = @()
# A resume state an earlier run put aside because it could not be saved (see
# FAILED (resume state not saved) at the end). With no resume state file since,
# -ResumeFailedOnly cannot tell what is owed, so it does not run; -Resume and a
# plain run skip no subscription as done (the failures of the put-aside state
# and of kept per-stream files are still read in). A clean run, or one whose resume state was saved, removes
# these files at its end.
$StatePutAside = @(Get-ChildItem -LiteralPath $InventoryRoot -Filter ((Split-Path -Path $ResumeStateFile -Leaf) + '.not-saved-*') -File -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
$StatePutAsideOnly = $StatePutAside.Count -gt 0 -and -not (Test-Path -LiteralPath $ResumeStateFile -PathType Leaf)
# Fail-safe rule, as for a kept per-stream file: only the failures of a put-aside
# state are used (never its completions or reports), so no retry entry is lost,
# and the run saves them with its own state.
if ($StatePutAsideOnly)
{
    foreach ($Aside in $StatePutAside) { $FailedAttempts = Merge-RecoveredFailedAttempts -ExistingFailedAttempts $FailedAttempts -RecoveredFailedAttempts @(Get-FailedAttempts -Path $Aside -Tenant $TenantID) -CompletedIds @() }
}
if ($ResumeFailedOnly -and $StatePutAsideOnly)
{
    Write-Host ("ERROR: An earlier run could not save the resume state and put it aside as {0}, so -ResumeFailedOnly cannot tell which subscriptions are owed. Nothing was collected (exit 2). Run again with -Resume, or without either switch: it collects every subscription." -f ($StatePutAside -join ', ')) -ForegroundColor Red
    Exit-Wrapper -Code 2
}
# Per-stream resume state files the end-of-run merge read and saved but could
# not remove: a later -Resume would fold their records in again, so the run
# keeps the state and ends with exit 2 too, and names each one.
$LeftStreamFiles = @()
# A parallel run persists each stream's Completed/FailedAttempts to its own
# .resume-state-<tenant>-stream-<N>.json and only merges them into the unified
# file at end-of-run. If that run was killed before the merge (Ctrl+C, SIGKILL,
# Cloud Shell timeout), the failures live ONLY in the per-stream files while the
# unified file is stale. Without this, -ResumeFailedOnly reads the unified file,
# sees no failures, and wrongly reports "Nothing to retry" - silently dropping
# the retry set. Read the per-stream files here so BOTH -Resume (skip-completed)
# and -ResumeFailedOnly (retry list) see the full picture, write what they hold
# into the unified file, and then remove them: a run that does not reach the
# streams merge (sequential, one subscription, or nothing left) would otherwise
# leave them, and every later -Resume would fold the same old records in again.
# A run without -Resume or -ResumeFailedOnly collects every subscription and
# writes its own state, so the files of an earlier interrupted run are stale and
# are removed too. Safe on non-interrupted runs: a cleanly-finished parallel run
# deletes its per-stream files, so this finds none. Runs at startup before any
# stream is launched, so it cannot race live streams.
if ($Resume -or $ResumeFailedOnly)
{
    # A per-stream file an earlier run put aside as unreadable may hold a
    # failure that is newer than a completion in the unified file, so every
    # -Resume and -ResumeFailedOnly run names it and keeps the state with exit 2
    # until it is fixed and renamed back (and folded in) or deleted.
    foreach ($Aside in @(Get-ChildItem -LiteralPath $InventoryRoot -Filter (".resume-state-{0}-stream-*.json.unreadable-*" -f $TenantID) -File -Force -ErrorAction SilentlyContinue))
    {
        $AsideOf = $Aside.FullName -replace '\.unreadable-[0-9]+$', ''
        Write-Host ("WARNING: The per-stream resume state file {0}, put aside by an earlier run because it could not be read, is still there. Its records are not used, so this run keeps the resume state and ends with exit 2. Fix it and rename it back to {1} for the next -Resume to fold it in, or delete it (a run without -Resume or -ResumeFailedOnly removes it as stale once it has collected, unless the resume state still lists as completed a subscription that run did not collect)." -f $Aside.FullName, $AsideOf) -ForegroundColor Yellow
        $UnreadableStreamFiles += $Aside.FullName
    }
    # Fold in any per-stream resume-state left behind by an INTERRUPTED parallel run.
    $StrandedStreamFiles = @(Get-StreamResumeStateFiles -InventoryRoot $InventoryRoot -Tenant $TenantID)
    # Fail-safe rule (see the end-of-run merge): a per-stream file left here
    # belongs to a run that was cut off, or whose save could not be verified,
    # so that run never proved its results saved. Only its failures are folded in; its completions and
    # reports are not, so those subscriptions are collected again.
    if ($StrandedStreamFiles.Count -gt 0)
    {
        $StrandedFailed = @()
        # The files read: only these are removed once their records are saved.
        $FoldedStreamFiles = @()
        foreach ($StreamFile in $StrandedStreamFiles)
        {
            try
            {
                # Stop on any read error, and on an empty file: either one would
                # otherwise read as a file with no record, and be removed.
                $Obj = Get-Content -LiteralPath $StreamFile.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                if ($null -eq $Obj -or $Obj -isnot [System.Management.Automation.PSCustomObject] -or -not $Obj.PSObject.Properties['Completed']) { throw 'the file is empty or is not a per-stream resume state' }
                if ($null -ne $Obj.FailedAttempts) { $StrandedFailed += @($Obj.FailedAttempts) }
                $FoldedStreamFiles += $StreamFile
            }
            catch
            {
                $Aside = Move-UnreadableStreamFile -Path $StreamFile.FullName -Reason $_.Exception.Message -Interrupted
                if ($Aside -eq $StreamFile.FullName)
                {
                    # Left under its own name, a stream of this run could write
                    # over it, and every later run would try it again.
                    Write-Host ("ERROR: Rename or delete {0}, then run again. Nothing was collected (exit 1)." -f $StreamFile.FullName) -ForegroundColor Red
                    Exit-Wrapper -Code 1
                }
                $UnreadableStreamFiles += $Aside
            }
        }
        # A subscription a per-stream file lists as failed is not completed,
        # whatever the unified file or another (older) stream file recorded:
        # the files carry no completion time, so the failure wins (the worst
        # case is one more collection), and its old report is not carried.
        $StrandedFailedIds = @($StrandedFailed | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_.Id })
        $CompletedIds = @($CompletedIds | Where-Object { $StrandedFailedIds -notcontains [string]$_ })
        $CompletedReports = @($CompletedReports | Where-Object { $null -ne $_ -and $StrandedFailedIds -notcontains [string]$_.Id })
        # The most failed runs win (Merge-RecoveredFailedAttempts), and a sub
        # still completed is dropped from the retry list.
        $FailedAttempts = Merge-RecoveredFailedAttempts -ExistingFailedAttempts $FailedAttempts -RecoveredFailedAttempts $StrandedFailed -CompletedIds $CompletedIds
        if ($FoldedStreamFiles.Count -gt 0)
        {
            Write-Host ("Recovered per-stream state an earlier parallel run left (it was cut off, or could not save its results): {0} failed subscription record(s); what it completed is collected again, since that run never confirmed those results were saved." -f @($StrandedFailed).Count) -ForegroundColor Cyan
        }
        # Heal the unified file immediately so even a re-interrupted run keeps
        # the recovered picture. Saved whenever a file was read, also one with no
        # record: the state in memory is reconciled above (Merge-RecoveredFailedAttempts),
        # and the read-back below compares the file with it.
        if ($FoldedStreamFiles.Count -gt 0)
        {
            Save-CompletedSubscriptionIds -Path $ResumeStateFile -Tenant $TenantID -Ids $CompletedIds -FailedAttempts $FailedAttempts -Reports $CompletedReports
        }
        # The files read are removed only when the unified file on disk holds
        # the whole state they were folded into (read back by
        # Test-ResumeStateSaved); otherwise they are kept and named, and the
        # next run folds them in again.
        if ($FoldedStreamFiles.Count -eq 0 -or (Test-ResumeStateSaved -Path $ResumeStateFile -Tenant $TenantID -Ids $CompletedIds -FailedAttempts $FailedAttempts -Reports $CompletedReports))
        {
            foreach ($StreamFile in $FoldedStreamFiles)
            {
                try { Remove-Item -LiteralPath $StreamFile.FullName -Force -ErrorAction Stop }
                catch
                {
                    # Left, every later run would fold its old records in again,
                    # and its old failure would win over a newer completion.
                    Write-Host ("ERROR: Could not remove the per-stream resume state file {0}: {1}. Its records are saved in {2}. Remove it, then run again. Nothing was collected (exit 1)." -f $StreamFile.FullName, $_.Exception.Message, $ResumeStateFile) -ForegroundColor Red
                    Exit-Wrapper -Code 1
                }
            }
        }
        else
        {
            # Left under their names, a stream of this run would write over the
            # only copy of what they hold, so the run stops before any stream.
            Write-Host ("ERROR: The resume state file {0} could not be written with every record of the per-stream files of an earlier parallel run, so they are kept: {1}. Free disk space or fix the folder, then run again. Nothing was collected (exit 1)." -f $ResumeStateFile, (@($FoldedStreamFiles | ForEach-Object { $_.FullName }) -join ', ')) -ForegroundColor Red
            Exit-Wrapper -Code 1
        }
    }
}
else
{
    # Stale: see above. This run collects every subscription, but it can stop
    # before it reaches one (an access or consumption check, Ctrl+C), and it
    # adds to the unified file rather than starting it again: so each retry
    # entry a stale file holds is merged into the unified file first, as at the
    # start of -Resume (the entry with the most failed runs wins, so its count and reason are kept,
    # and it ends the completion an older run recorded), and -Resume or
    # -ResumeFailedOnly still collects that subscription. A stale file that
    # cannot be read is put aside, like one an earlier run put aside: those
    # (and only those, not one this run's own merge puts aside) are removed
    # once this run has collected (see below; not while the state lists an
    # older completion of one it left out). A file that cannot be removed,
    # or a state that cannot be saved, stops the run.
    # (The rename is written here, not with Move-UnreadableStreamFile: that
    # one's warning says the file keeps the state with exit 2 and is to be
    # renamed back, which a run without -Resume does not do.)
    $StaleFailed = @()
    $StaleAsideFiles = @(Get-ChildItem -LiteralPath $InventoryRoot -Filter (".resume-state-{0}-stream-*.json.unreadable-*" -f $TenantID) -File -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    foreach ($StreamFile in @(Get-StreamResumeStateFiles -InventoryRoot $InventoryRoot -Tenant $TenantID))
    {
        try
        {
            $Obj = Get-Content -LiteralPath $StreamFile.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($null -eq $Obj -or $Obj -isnot [System.Management.Automation.PSCustomObject] -or -not $Obj.PSObject.Properties['Completed']) { throw 'the file is empty or is not a per-stream resume state' }
            if ($Obj.PSObject.Properties['FailedAttempts'] -and $null -ne $Obj.FailedAttempts) { $StaleFailed += @($Obj.FailedAttempts | Where-Object { $null -ne $_ }) }
        }
        catch
        {
            $Why = $_.Exception.Message
            $Aside = '{0}.unreadable-{1}' -f $StreamFile.FullName, (Get-Date -Format 'yyyyMMddHHmmssfff')
            try { Move-Item -LiteralPath $StreamFile.FullName -Destination $Aside -ErrorAction Stop }
            catch
            {
                Write-Host ("ERROR: Could not read the per-stream resume state file {0} of an earlier run ({1}), and could not rename it aside: {2}. Rename or delete it, then run again. Nothing was collected (exit 1)." -f $StreamFile.FullName, $Why, $_.Exception.Message) -ForegroundColor Red
                Exit-Wrapper -Code 1
            }
            Write-Host ("WARNING: Could not read the per-stream resume state file {0} of an earlier run: {1} It is put aside as {2} and removed once this run has collected, unless the resume state still lists as completed a subscription this run did not collect." -f $StreamFile.FullName, $Why, $Aside) -ForegroundColor Yellow
            $StaleAsideFiles += $Aside
            continue
        }
    }
    $StaleFailed = @($StaleFailed | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_.Id) })
    if ($StaleFailed.Count -gt 0)
    {
        $StaleFailedIds = @($StaleFailed | ForEach-Object { [string]$_.Id } | Sort-Object -Unique)
        $CompletedIds = @($CompletedIds | Where-Object { $StaleFailedIds -notcontains [string]$_ })
        $CompletedReports = @($CompletedReports | Where-Object { $null -ne $_ -and $StaleFailedIds -notcontains [string]$_.Id })
        # The most failed runs win, as in the -Resume fold (Merge-RecoveredFailedAttempts).
        $FailedAttempts = Merge-RecoveredFailedAttempts -ExistingFailedAttempts $FailedAttempts -RecoveredFailedAttempts $StaleFailed -CompletedIds $CompletedIds
        Save-CompletedSubscriptionIds -Path $ResumeStateFile -Tenant $TenantID -Ids $CompletedIds -FailedAttempts $FailedAttempts -Reports $CompletedReports
        if (-not (Test-ResumeStateSaved -Path $ResumeStateFile -Tenant $TenantID -Ids $CompletedIds -FailedAttempts $FailedAttempts -Reports $CompletedReports))
        {
            Write-Host ("ERROR: The resume state file {0} could not be written with the retry entries of the per-stream files of an earlier run, so they are kept. Free disk space or fix the folder, then run again. Nothing was collected (exit 1)." -f $ResumeStateFile) -ForegroundColor Red
            Exit-Wrapper -Code 1
        }
    }
    foreach ($StreamFile in @(Get-StreamResumeStateFiles -InventoryRoot $InventoryRoot -Tenant $TenantID))
    {
        try { Remove-Item -LiteralPath $StreamFile.FullName -Force -ErrorAction Stop }
        catch
        {
            # Left, a later -Resume would fold its old records in.
            Write-Host ("ERROR: Could not remove the per-stream resume state file {0} of an earlier run: {1}. Remove it, then run again. Nothing was collected (exit 1)." -f $StreamFile.FullName, $_.Exception.Message) -ForegroundColor Red
            Exit-Wrapper -Code 1
        }
    }
}

if ($Resume)
{
    # A completed subscription with no recorded report zip (every one in a state
    # file written by a version without CompletedReports, and any other the file
    # lists without its record) could not be carried into this run's
    # consolidated zip. Collect those again instead of skipping them; this run
    # saves their records, so the next -Resume skips them as usual. Only the ids
    # still completed after the start-up fold count: one it took off as failed
    # is collected again anyway, and is not counted here.
    $RecollectIds = @()
    if ($CompletedIds.Count -gt 0)
    {
        $RecordedReports = Get-LatestCompletedReports -Reports $CompletedReports
        $RecollectIds = @($CompletedIds | Where-Object { -not $RecordedReports.ContainsKey([string]$_) })
        $CompletedIds = @($CompletedIds | Where-Object { $RecollectIds -notcontains $_ })
    }
    if ($RecollectIds.Count -gt 0)
    {
        if ($StateWithoutReports) { Write-Host ("Resume mode: the resume state was written by an older version, so {0} subscription(s) will be collected again for the bundle to hold their reports." -f $RecollectIds.Count) -ForegroundColor Cyan }
        else { Write-Host ("Resume mode: the resume state lists {0} completed subscription(s) with no recorded report, so they will be collected again for the bundle to hold their reports." -f $RecollectIds.Count) -ForegroundColor Cyan }
    }
    if ($CompletedIds.Count -gt 0)
    {
        Write-Host ("Resume mode: {0} previously completed subscription(s) will be skipped." -f $CompletedIds.Count) -ForegroundColor Cyan
    }
    elseif ($RecollectIds.Count -eq 0)
    {
        if ($StatePutAsideOnly) { Write-Host ("Resume mode: an earlier run could not save the resume state (put aside as {0}); processing all subscriptions." -f ($StatePutAside -join ', ')) -ForegroundColor Cyan }
        elseif (Test-Path -LiteralPath $ResumeStateFile -PathType Leaf) { Write-Host "Resume mode: no completed subscriptions to skip; processing all subscriptions." -ForegroundColor Cyan }
        else { Write-Host "Resume mode: no previous state found; processing all subscriptions." -ForegroundColor Cyan }
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
# A retry-list entry for a subscription the signed-in identity no longer sees
# at all (deleted, moved to another tenant) can never be retried or counted, so
# it would keep the resume state forever. Every run drops it, with or without
# -Resume (a run without it reads and writes the same retry list), before the
# entries past the retry limit are worked out, so a gone one is never owed.
# A disabled subscription is still listed by Get-AzSubscription, so its entry
# stays (-IncludeDisabled retries it). A listing that came back with warnings or
# errors can leave out a subscription that is only hidden for now, so then no
# entry is dropped, and the warnings and errors are printed.
$DroppedGoneEntries = $false
$KeptNotListedIds = @()
# The ids dropped here, kept out of the per-stream records merged later too.
$GoneIds = @()
if (@($FailedAttempts | Where-Object { $null -ne $_ }).Count -gt 0)
{
    $VisibleIds = @($AllSubscriptions | ForEach-Object { [string]$_.Id })
    $GoneAttempts = @($FailedAttempts | Where-Object { $null -ne $_ -and $VisibleIds -notcontains [string]$_.Id })
    $ListingProblems = @(@($SubWarnings) + @($SubErrors) | Where-Object { $_ } | ForEach-Object {
            $Text = if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } elseif ($_ -is [System.Management.Automation.WarningRecord]) { $_.Message } else { [string]$_ }
            # An Az notice of a coming breaking change says nothing about the
            # list, so it does not hold back a drop.
            if ($_ -isnot [System.Management.Automation.ErrorRecord] -and [string]$Text -match '(?i)breaking change') { return }
            # The first line, at most 300 characters: what to fix, not the whole record.
            $Line = @(([string]$Text) -split "`r?`n" | Where-Object { $_.Trim() })[0]
            if ($null -eq $Line) { $Line = '' }
            if ($Line.Length -gt 300) { $Line = $Line.Substring(0, 300) + '...' }
            $Line.Trim()
        } | Where-Object { $_ } | Select-Object -Unique)
    if ($GoneAttempts.Count -gt 0 -and $ListingProblems.Count -gt 0)
    {
        Write-Host ("Kept on the retry list: {0} subscription(s) not in the subscription list ({1}), because Get-AzSubscription returned warnings or errors, so the list may be incomplete:" -f $GoneAttempts.Count, (@($GoneAttempts | ForEach-Object { '{0} ({1})' -f $_.Name, $_.Id }) -join ', ')) -ForegroundColor Yellow
        foreach ($Problem in @($ListingProblems | Select-Object -First 5)) { Write-Host ("  - {0}" -f $Problem) -ForegroundColor Yellow }
        if ($ListingProblems.Count -gt 5) { Write-Host ("  - ... and {0} more" -f ($ListingProblems.Count - 5)) -ForegroundColor Yellow }
        $KeptNotListedIds = @($GoneAttempts | ForEach-Object { [string]$_.Id })
    }
    elseif ($GoneAttempts.Count -gt 0)
    {
        foreach ($Gone in $GoneAttempts)
        {
            Write-Host ("Dropped from the retry list: {0} ({1}) is no longer visible to the signed-in identity, so no run can retry it." -f $Gone.Name, $Gone.Id) -ForegroundColor Yellow
        }
        $GoneIds = @($GoneAttempts | ForEach-Object { [string]$_.Id })
        $FailedAttempts = @($FailedAttempts | Where-Object { $null -ne $_ -and $GoneIds -notcontains [string]$_.Id })
        Save-CompletedSubscriptionIds -Path $ResumeStateFile -Tenant $TenantID -Ids $CompletedIds -FailedAttempts $FailedAttempts -Reports $CompletedReports
        $DroppedGoneEntries = $true
    }
}

if ($ResumeFailedOnly)
{
    if ($FailedAttempts.Count -eq 0)
    {
        Write-Host "ResumeFailedOnly: no failed subscriptions in resume state. Nothing to retry." -ForegroundColor Green
        Write-Host ("If you expected failures here, verify {0} has a non-empty FailedAttempts array." -f $ResumeStateFile) -ForegroundColor DarkGray
        # After an interrupted run the state still lists what completed, so name
        # the subscriptions it never reached. Without a state file (a clean run
        # deleted it) there is nothing to name.
        # Exit 2 while that list is not empty: work remains that this mode does
        # not do, so the run is not reported as a success (a -Resume collects it).
        $NotReachedIds = @()
        if (Test-Path -LiteralPath $ResumeStateFile -PathType Leaf)
        {
            $NotReached = @(Get-NotCollectedSubscriptions -Eligible $Subscriptions -CompletedIds $CompletedIds -NotReadableIds $NotReadableIds)
            $NotReachedIds = @($NotReached | Where-Object { $null -ne $_ })
            Write-NotCollectedSummary -NotCollected $NotReached -ResumeStateFile $ResumeStateFile
        }
        # The drop above emptied the retry list and no subscription is left that
        # no run has completed: nothing is owed, so the state is removed as at the
        # end of a clean run. Otherwise it would stay behind on every repeat.
        if ($DroppedGoneEntries -and $NotReachedIds.Count -eq 0 -and $UnreadableStreamFiles.Count -eq 0 -and (Test-Path -LiteralPath $ResumeStateFile -PathType Leaf))
        {
            try
            {
                # (The per-stream files of an interrupted run were folded in and
                # removed at the start.)
                Remove-Item -LiteralPath $ResumeStateFile -Force -ErrorAction Stop
                Write-Host "Resume state cleared (clean run)." -ForegroundColor Green
            }
            catch
            {
                Write-Host ("WARNING: Could not remove resume state file {0}: {1}" -f $ResumeStateFile, $_.Exception.Message) -ForegroundColor Yellow
            }
        }
        # A drop that reached neither a save nor the removal above leaves the
        # dropped entries in the file, and every later -ResumeFailedOnly run
        # would drop them again: exit 2, with the way out, so the repeat does
        # not read as a success.
        $DropNotSaved = $DroppedGoneEntries -and $ResumeStateSaveFailed -and (Test-Path -LiteralPath $ResumeStateFile -PathType Leaf)
        if ($DropNotSaved)
        {
            Write-Host ("ERROR: The resume state file {0} could not be written or removed, so it still lists the retry entries dropped above, and every -ResumeFailedOnly run would drop them again. Fix the cause (for example, free up disk space), then run again, or delete the resume state files .resume-state-{1}.json and .resume-state-{1}-stream-*.json in the inventory folder to start over." -f $ResumeStateFile, $TenantID) -ForegroundColor Red
        }
        # A per-stream state file that could not be read may hold failures
        # (named above): the run is not clean while it is there.
        Exit-Wrapper -Code $(if ($NotReachedIds.Count -gt 0 -or $UnreadableStreamFiles.Count -gt 0 -or $DropNotSaved) { 2 } else { 0 })
    }
    $FailedIds = @($FailedAttempts | ForEach-Object { $_.Id })
    $BeforeCount = $Subscriptions.Count
    # Kept for the resume-state cleanup at the end, which names any of these that
    # no run has completed. Copied here because in the sequential path the inner
    # script can replace $Subscriptions.
    $EligibleBeforeRetryFilter = @($Subscriptions)
    $Subscriptions = @($Subscriptions | Where-Object { $FailedIds -contains $_.Id })
    Write-Host ("ResumeFailedOnly: filtered to {0} previously-failed subscription(s) (was {1})." -f $Subscriptions.Count, $BeforeCount) -ForegroundColor Cyan
    if ($Subscriptions.Count -eq 0)
    {
        # Could happen if the visible-subs list no longer contains the failed
        # IDs (sub was deleted, identity lost access, IncludeDisabled toggled
        # off relative to the prior run). Tell the user instead of silently
        # processing nothing.
        # The retry list still holds them (the state is kept), so this is not a
        # success: exit 2, as for any report the run could not produce.
        Write-Host "WARNING: FailedAttempts list contained IDs but none are visible in the current subscription set. Verify access and -IncludeDisabled flag matches the prior run." -ForegroundColor Yellow
        # Nothing else takes such an entry off the list, so every later
        # -ResumeFailedOnly run would end the same way: name the way out.
        Write-Host ("  If they are gone for good, delete the resume state files .resume-state-{0}.json and .resume-state-{0}-stream-*.json in the inventory folder to start over with an empty retry list: the next run collects every subscription." -f $TenantID) -ForegroundColor Yellow
        Exit-Wrapper -Code 2
    }
}

# A subscription past the retry limit (Get-RetryLimitedAttempts) is not
# collected by -Resume or -ResumeFailedOnly; a run without either still
# collects it. Its entry stays on the retry list, so the summary keeps listing
# it as incomplete and the count goes on if a later run fails it again.
$SkippedForRetryLimit = @()
if (($Resume -or $ResumeFailedOnly) -and @($FailedAttempts | Where-Object { $null -ne $_ }).Count -gt 0)
{
    $EligibleIds = @($Subscriptions | ForEach-Object { [string]$_.Id })
    $SkippedForRetryLimit = @(Get-RetryLimitedAttempts -FailedAttempts $FailedAttempts | Where-Object { $EligibleIds -contains [string]$_.Id })
    foreach ($Limited in $SkippedForRetryLimit)
    {
        Write-Host ("Not retried: {0} ({1}) failed {2} runs in a row; last reason: {3}. To try it again, start a run without -Resume or -ResumeFailedOnly." -f $Limited.Name, $Limited.Id, (Get-FailedAttemptCount -Entry $Limited), $Limited.Reason) -ForegroundColor Yellow
    }
    if ($SkippedForRetryLimit.Count -gt 0)
    {
        $SkippedLimitIds = @($SkippedForRetryLimit | ForEach-Object { [string]$_.Id })
        $Subscriptions = @($Subscriptions | Where-Object { $SkippedLimitIds -notcontains [string]$_.Id })
        if ($ResumeFailedOnly -and $Subscriptions.Count -eq 0)
        {
            Write-Host "ResumeFailedOnly: nothing left to retry; the subscriptions on the retry list are past the retry limit (named above)." -ForegroundColor Green
            # As when the retry list is empty: name the subscriptions no run has
            # reached. Those past the limit are on the retry list, so not among them.
            Write-NotCollectedSummary -NotCollected (Get-NotCollectedSubscriptions -Eligible $EligibleBeforeRetryFilter -CompletedIds $CompletedIds -RetryIds @($FailedAttempts | Where-Object { $_ } | ForEach-Object { [string]$_.Id }) -NotReadableIds $NotReadableIds) -ResumeStateFile $ResumeStateFile
            # Their reports are missing, so exit 2 (the advice above says how to
            # try them again); the state is kept, so the limit is not forgotten.
            Exit-Wrapper -Code 2
        }
    }
}

# The access check's result. Set by the check below, which does not run when
# nothing is left to probe; the end of the run reads it either way.
$AccessDecision = $null

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

# The retry-list entries past the limit that this run does not collect: those
# skipped above, those the access check skipped as not readable, and those
# outside this run's subscription set (for example a disabled subscription
# without -IncludeDisabled, or one a listing with warnings or errors did not show).
# Built after every start-up filter of the subscription list. While one is
# still on the retry list at the end, its report is missing, so the run ends
# with exit 2.
$RunSubscriptionIds = @($Subscriptions | ForEach-Object { [string]$_.Id })
# Every retry-list entry this run does not collect, below the limit too: while
# one is still on the retry list at the end, the run is not a success (exit 2).
$RetryNotInRunIds = @($FailedAttempts | Where-Object { $null -ne $_ -and $RunSubscriptionIds -notcontains [string]$_.Id } | ForEach-Object { [string]$_.Id })
$RetryLimitedNotInRunIds = @(Get-RetryLimitedAttempts -FailedAttempts $FailedAttempts | Where-Object { $RunSubscriptionIds -notcontains [string]$_.Id } | ForEach-Object { [string]$_.Id })

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

# Keep the subscriptions the access check above skipped as not readable in the
# resume state, so a later -ResumeFailedOnly run does not name them as never
# collected (the run that skipped them lists them). A subscription this run did
# not check keeps the earlier answer. The state is written only when the list
# changed.
if ($ScopeForProbe.Count -gt 0)
{
    $NotReadableBefore = (@($NotReadableIds | Where-Object { $_ } | ForEach-Object { [string]$_ } | Sort-Object -Unique) -join ',')
    $CheckedIds = @($ScopeForProbe | ForEach-Object { [string]$_.Id })
    $SkippedNotReadable = @(if ($null -ne $AccessDecision) { @($AccessDecision.InaccessibleIds) | Where-Object { $_ } })
    $NotReadableIds = @(@($NotReadableIds | Where-Object { $_ -and $CheckedIds -notcontains [string]$_ }) + $SkippedNotReadable | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    if (($NotReadableIds -join ',') -ne $NotReadableBefore)
    {
        Save-CompletedSubscriptionIds -Path $ResumeStateFile -Tenant $TenantID -Ids $CompletedIds -FailedAttempts $FailedAttempts -Reports $CompletedReports -NotReadable $NotReadableIds
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
# The subscriptions this -Resume run skipped because an earlier run completed
# them ({ Id, Name }). Their recorded reports are carried into this run's
# consolidated zip (see Get-ResumeCarriedReports below).
$SkippedSubscriptions = @()
$DiagFile = $null
# Per-subscription resource counts collected for the final summary so the user
# can see at a glance which subscriptions came back empty (the most common
# explanation is that the signed-in identity does not have Reader on the
# subscription, but it can also legitimately mean the subscription is empty).
$SubResourceCounts = @()

# Stream summaries earlier runs left are never read: each run names its own
# with its run id (below) and reads only those. Every run that goes on to
# collect removes every one here, before the sequential or parallel path,
# whatever its stream number and whether or not it uses streams, so they do
# not pile up (a run that stops earlier leaves them for the next): the older
# shared name (.rda-stream-<N>-summary.json), earlier runs' run-named ones and
# their temporary files. One that cannot be removed gets a warning and the
# run goes on.
foreach ($StaleSummary in @(Get-ChildItem -LiteralPath $InventoryRoot -Filter '.rda-stream-*-summary*.json*' -File -Force -ErrorAction SilentlyContinue))
{
    try { Remove-Item -LiteralPath $StaleSummary.FullName -Force -ErrorAction Stop }
    catch { Write-Host ("WARNING: Could not remove the stream summary {0} an earlier run left: {1}. It is not read; remove it when you can." -f $StaleSummary.FullName, $_.Exception.Message) -ForegroundColor Yellow }
}

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
            $SkippedSubscriptions += [pscustomobject]@{ Id = $Sub.Id; Name = $Sub.Name }
            continue
        }

        Write-Host "Processing subscription: $($Sub.Name) ($($Sub.Id))" -ForegroundColor Cyan

        try
        {
            # Cleared first so a stale path from the previous subscription is never recorded as this one's.
            $Global:ZipOutputFile = $null
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
            # Record the zip this run wrote, replacing any earlier record for the sub.
            $NewReport = New-CompletedReportRecord -InventoryRoot $InventoryRoot -Id $Sub.Id -Name $Sub.Name -ZipPath $Global:ZipOutputFile -Obfuscated ([bool]$Obfuscate)
            if ($null -eq $NewReport)
            {
                # The run left no zip, so there is no report a later -Resume could
                # carry: the sub is not completed. As after a failed attempt, an
                # earlier run's completion of it ends here, so the next -Resume
                # collects it again instead of carrying the older report.
                if ($CompletedIds -contains $Sub.Id)
                {
                    $CompletedIds = @($CompletedIds | Where-Object { $_ -ne $Sub.Id })
                    $CompletedReports = @($CompletedReports | Where-Object { $null -ne $_ -and [string]$_.Id -ne $Sub.Id })
                    $StateChanged = $true
                }
            }
            else
            {
                if (-not ($CompletedIds -contains $Sub.Id))
                {
                    $CompletedIds += $Sub.Id
                }
                $CompletedReports = @(@($CompletedReports) + $NewReport)
                $StateChanged = $true
                $FailedAttempts = Remove-FailedAttempt -Existing $FailedAttempts -Id $Sub.Id
            }
            if ($StateChanged)
            {
                Save-CompletedSubscriptionIds -Path $ResumeStateFile -Tenant $TenantID -Ids $CompletedIds -FailedAttempts $FailedAttempts -Reports $CompletedReports
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
            # A failed attempt ends an earlier run's completion of this sub: take
            # it off the completed list and drop its report record, so a later
            # -Resume collects it again instead of skipping it and carrying the
            # older report.
            if ($CompletedIds -contains $Sub.Id)
            {
                $CompletedIds = @($CompletedIds | Where-Object { $_ -ne $Sub.Id })
                $CompletedReports = @($CompletedReports | Where-Object { $null -ne $_ -and [string]$_.Id -ne $Sub.Id })
            }
            # Persist the failure to the resume-state file so a future run with
            # -ResumeFailedOnly can target it. Use the exception message as the
            # Reason so the operator can see at a glance why each sub failed
            # without opening the diag log.
            $FailedAttempts = Add-FailedAttempt -Existing $FailedAttempts `
                -Id $Sub.Id -Name $Sub.Name `
                -Reason $ErrRecord.Exception.Message
            Save-CompletedSubscriptionIds -Path $ResumeStateFile -Tenant $TenantID -Ids $CompletedIds -FailedAttempts $FailedAttempts -Reports $CompletedReports
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
    #   - Its own per-stream summary JSON (.rda-stream-<N>-summary-<run id>.json)
    #     which the parent aggregates at the end.
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

    # On -Resume, leave out what an earlier run completed before the streams
    # are counted and sliced, as the sequential loop does. A stream worker
    # knows only its own per-stream state file, which the end-of-run merge
    # folds in and deletes, and the one-subscription path below has no resume
    # check of its own, so left to them every subscription is collected again.
    $PendingSubscriptions = @()
    foreach ($Sub in $Subscriptions)
    {
        if ($Resume -and ($CompletedIds -contains $Sub.Id))
        {
            Write-Host ("Skipping (already completed): {0} ({1})" -f $Sub.Name, $Sub.Id) -ForegroundColor DarkGray
            $SkippedCount++
            # Recorded as the sequential loop does, so the end of the run carries
            # its earlier report into the consolidated zip (the streams never see it).
            $SkippedSubscriptions += [pscustomobject]@{ Id = $Sub.Id; Name = $Sub.Name }
            continue
        }
        $PendingSubscriptions += $Sub
    }

    $StreamCount = [Math]::Min($ParallelStreams, $PendingSubscriptions.Count)
    Write-Host ""
    Write-Host ("Parallel-streams mode: {0} streams across {1} subscription(s) to process" -f $StreamCount, $PendingSubscriptions.Count) -ForegroundColor Cyan
    if ($ParallelStreams -gt $PendingSubscriptions.Count -and $PendingSubscriptions.Count -gt 0)
    {
        Write-Host ("Note: -ParallelStreams {0} clamped to {1} (one stream per subscription is the practical limit)." -f $ParallelStreams, $StreamCount) -ForegroundColor DarkGray
    }
    Write-Host "Each stream is a separate pwsh background job with its own Az context and resume-state file." -ForegroundColor DarkGray
    Write-Host ""

    if ($StreamCount -le 1)
    {
        # User asked for parallel but only one (or zero) sub is left to process.
        # Process it inline using the same per-sub logic the sequential
        # branch uses, instead of bailing and asking the user to re-run.
        if ($PendingSubscriptions.Count -eq 0) { Write-Host "No subscription left to process." -ForegroundColor Yellow }
        else { Write-Host "Only one subscription left to process; running sequentially." -ForegroundColor Yellow }
        if ($PendingSubscriptions.Count -gt 0)
        {
            $Sub = $PendingSubscriptions[0]
            Write-Host "Processing subscription: $($Sub.Name) ($($Sub.Id))" -ForegroundColor Cyan
            try
            {
                # Cleared first so a stale path is never recorded as this subscription's zip.
                $Global:ZipOutputFile = $null
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
                $NewReport = New-CompletedReportRecord -InventoryRoot $InventoryRoot -Id $Sub.Id -Name $Sub.Name -ZipPath $Global:ZipOutputFile -Obfuscated ([bool]$Obfuscate)
                if ($null -ne $NewReport) { $CompletedReports = @(@($CompletedReports) + $NewReport) }
                if ($null -eq $NewReport)
                {
                    # Same as the sequential branch: a run that left no zip does not
                    # complete the sub, and ends an earlier run's completion of it.
                    if ($CompletedIds -contains $Sub.Id)
                    {
                        $CompletedIds = @($CompletedIds | Where-Object { $_ -ne $Sub.Id })
                        $CompletedReports = @($CompletedReports | Where-Object { $null -ne $_ -and [string]$_.Id -ne $Sub.Id })
                        Save-CompletedSubscriptionIds -Path $ResumeStateFile -Tenant $TenantID -Ids $CompletedIds -FailedAttempts $FailedAttempts -Reports $CompletedReports
                    }
                }
                elseif (-not ($CompletedIds -contains $Sub.Id))
                {
                    $CompletedIds += $Sub.Id
                    $FailedAttempts = Remove-FailedAttempt -Existing $FailedAttempts -Id $Sub.Id
                    Save-CompletedSubscriptionIds -Path $ResumeStateFile -Tenant $TenantID -Ids $CompletedIds -FailedAttempts $FailedAttempts -Reports $CompletedReports
                }
                else
                {
                    # Already recorded as completed: still save, so this run's zip replaces the earlier one.
                    Save-CompletedSubscriptionIds -Path $ResumeStateFile -Tenant $TenantID -Ids $CompletedIds -FailedAttempts $FailedAttempts -Reports $CompletedReports
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
                # Same as the sequential branch: a failed attempt takes the sub
                # off the completed list and drops its report record.
                if ($CompletedIds -contains $Sub.Id)
                {
                    $CompletedIds = @($CompletedIds | Where-Object { $_ -ne $Sub.Id })
                    $CompletedReports = @($CompletedReports | Where-Object { $null -ne $_ -and [string]$_.Id -ne $Sub.Id })
                }
                # Mirror the sequential branch: persist failure to the
                # resume-state file so -ResumeFailedOnly works even for the
                # single-sub-collapses-to-inline corner case.
                $FailedAttempts = Add-FailedAttempt -Existing $FailedAttempts `
                    -Id $Sub.Id -Name $Sub.Name `
                    -Reason $ErrRecord.Exception.Message
                Save-CompletedSubscriptionIds -Path $ResumeStateFile -Tenant $TenantID -Ids $CompletedIds -FailedAttempts $FailedAttempts -Reports $CompletedReports
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
        # This run's id: it names this run's stream summaries, and each stream
        # writes it into its summary and its state file. A summary without it
        # is not used; a state file without it gives its failures only (see the
        # fail-safe rule at the end-of-run merge).
        $StreamRunId = [guid]::NewGuid().ToString('N')
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
            for ($i = 0; $i -lt $PendingSubscriptions.Count; $i++)
            {
                $Slices[$i % $StreamCount].Add($PendingSubscriptions[$i])
            }

            # Build per-stream output paths up front so we know where to look later.
            for ($S = 0; $S -lt $StreamCount; $S++)
            {
                $SliceList = $Slices[$S]
                $SliceIds = @($SliceList | ForEach-Object { $_.Id })
                $SliceNames = @($SliceList | ForEach-Object { $_.Name })

                # Named with this run's id, so a worker of an earlier run cannot
                # write over it.
                $SummaryPath = Join-Path $InventoryRoot (".rda-stream-{0}-summary-{1}.json" -f $S, $StreamRunId)
                $FailuresPath = Join-Path $InventoryRoot ("RunAllSubscriptions_failures_{0}_stream-{1}.log" -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'), $S)

                $StreamSummaries += [pscustomobject]@{
                    StreamId     = $S
                    SummaryPath  = $SummaryPath
                    FailuresPath = $FailuresPath
                    SubCount     = $SliceList.Count
                    # The ids this stream was given: with no usable summary, none
                    # of them is proven done (fail-safe rule at the merge).
                    SubIds       = @($SliceIds)
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
                    # The retry-list entries for this slice, so a stream that fails
                    # a subscription adds one run to its count (Add-FailedAttempt).
                    PriorFailedAttempts = @($FailedAttempts | Where-Object { $null -ne $_ -and $SliceIds -contains [string]$_.Id })
                    SubscriptionNames  = $SliceNames
                    ConcurrencyLimit   = $ConcurrencyLimit
                    RunId              = $StreamRunId
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
            $StreamFailedIds = @()
            # The same subs as given in the summaries (Id, Name, Reason), for the
            # retry list when a stream's own state file cannot be read.
            $StreamFailedEntries = @()
            $StreamNoReportIds = @()
            # The subs whose result this run must prove saved at the merge below
            # (fail-safe rule): those a summary lists as completed, and every sub
            # of a stream with no usable summary. Each with the reason it gets
            # when it is not proven.
            $StreamUnproven = @()
            $StreamNoSummary = @()
            foreach ($S in $StreamSummaries)
            {
                if (-not (Test-Path -LiteralPath $S.SummaryPath -PathType Leaf))
                {
                    Write-Host ("[stream-{0}] WARNING: no summary file at {1} - the stream did not finish cleanly" -f $S.StreamId, $S.SummaryPath) -ForegroundColor Yellow
                    $FailedSubscriptions += ("stream-{0} (no summary)" -f $S.StreamId)
                    $StreamNoSummary += $S
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
                    $StreamNoSummary += $S
                    continue
                }
                # A summary that is not this run's summary of this stream (its run
                # id, tenant or stream id differs) is not used at all, and the
                # stream counts as failed, as for one with a corrupt summary.
                if ([string]$StreamSummary.RunId -ne [string]$StreamRunId -or [string]$StreamSummary.Tenant -ne [string]$TenantID -or [string]$StreamSummary.StreamId -ne [string]$S.StreamId)
                {
                    Write-Host ("[stream-{0}] ERROR: summary file {1} is not this run's summary of this stream (run {2}, tenant {3}, stream {4}; this run is {5}); it is not used." -f $S.StreamId, $S.SummaryPath, $StreamSummary.RunId, $StreamSummary.Tenant, $StreamSummary.StreamId, $StreamRunId) -ForegroundColor Red
                    $FailedSubscriptions += ("stream-{0} (summary not this run's)" -f $S.StreamId)
                    $StreamNoSummary += $S
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
                    # The subs this stream attempted and failed this run, for the
                    # merge of per-stream state below. A stream that did not start
                    # lists its whole slice as failed but attempted none of it, so
                    # an earlier completion of its subs stays; each sub it leaves
                    # not done still counts one more failed run (below), so the
                    # retry limit ends a stream that never starts.
                    if ($StreamSummary.Status -ne 'failed-to-start')
                    {
                        $StreamFailedIds += @($StreamSummary.Failed | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_.Id) } | ForEach-Object { [string]$_.Id })
                    }
                    $StreamFailedEntries += @($StreamSummary.Failed | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_.Id) })
                }

                # The subs this stream collected this run without a zip being written.
                if ($StreamSummary.NoReport)
                {
                    $StreamNoReportIds += @($StreamSummary.NoReport | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_.Id) } | ForEach-Object { [string]$_.Id })
                }

                # The subs this stream says it completed: each must also be in its
                # own saved state file, with its report, to count (see the merge).
                if ($StreamSummary.Status -ne 'failed-to-start' -and $StreamSummary.Completed)
                {
                    $StreamUnproven += @($StreamSummary.Completed | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ Id = [string]$_; StreamId = $S.StreamId; Reason = 'its stream could not save its result, so it is collected again' } })
                }

                # A stream skips only what its own state file of this run lists as
                # completed; the parent's pre-filter leaves out every completed
                # sub before it slices, so this list is empty today.
                if ($StreamSummary.Skipped)
                {
                    foreach ($k in @($StreamSummary.Skipped))
                    {
                        if ($null -ne $k -and -not [string]::IsNullOrWhiteSpace([string]$k.Id))
                        {
                            $SkippedSubscriptions += [pscustomobject]@{ Id = [string]$k.Id; Name = [string]$k.Name }
                        }
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
                if (Test-Path -LiteralPath $S.SummaryPath)
                {
                    try { Remove-Item -LiteralPath $S.SummaryPath -Force } catch { Write-Verbose ("Could not remove stream summary {0}: {1}" -f $S.SummaryPath, $_.Exception.Message) }
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
            $ThisRunFailedFromStreams = @()
            $AllReportsFromStreams = @()
            # The files read: only these are removed, once their records are saved.
            $MergedStreamFiles = @()
            foreach ($StreamFile in $AllStreamFiles)
            {
                $PerStreamFile = $StreamFile.FullName
                try
                {
                    # As at the start: a read error or an empty file is unreadable.
                    $Obj = Get-Content -LiteralPath $PerStreamFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                    if ($null -eq $Obj -or $Obj -isnot [System.Management.Automation.PSCustomObject] -or -not $Obj.PSObject.Properties['Completed']) { throw 'the file is empty or is not a per-stream resume state' }
                    $MergedStreamFiles += $StreamFile
                    # FAIL-SAFE RULE. A subscription counts as done (taken off the
                    # retry list, skipped by a later -Resume, its report carried)
                    # only when this run can prove its result was saved: it is in
                    # a per-stream state file of THIS run (its RunId) with its
                    # report record, and the unified resume state is then saved
                    # and read back (Test-ResumeStateSaved). Anything else (a
                    # state or report write that failed, a file of another run or
                    # of a parent that was cut off, a completion only a summary
                    # names) is not done: it stays on, or goes on, the retry list
                    # and the next -Resume or -ResumeFailedOnly collects it again.
                    # Collecting again adds no duplicate row: the bundle takes
                    # only this run's zips and the reports of subs it skipped as
                    # done, so a sub not done has no carried report. The retry
                    # limit ends a sub that keeps failing this way. This one rule
                    # covers every case where a save cannot be proven.
                    if ([string]$Obj.RunId -eq [string]$StreamRunId)
                    {
                        $FileReports = Get-LatestCompletedReports -Reports @($Obj.Reports)
                        $AllCompletedFromStreams += @($Obj.Completed | Where-Object { $_ -and $FileReports.ContainsKey([string]$_) } | ForEach-Object { [string]$_ })
                        $AllReportsFromStreams += @($FileReports.Values)
                        # Only this run's failures count as this run's (below).
                        if ($null -ne $Obj.FailedAttempts) { $ThisRunFailedFromStreams += @($Obj.FailedAttempts) }
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
                    $Aside = Move-UnreadableStreamFile -Path $PerStreamFile -Reason $_.Exception.Message
                    if ($Aside -eq $PerStreamFile) { Write-Host ("WARNING: This run keeps the resume state and ends with exit 2. Rename or delete {0} before the next run." -f $PerStreamFile) -ForegroundColor Yellow }
                    $UnreadableStreamFiles += $Aside
                }
            }
            # A sub whose result no state file of this run holds (its stream
            # could not save it, or left no usable summary) is not done: it
            # counts as one more failed run, so it stays on the retry list and
            # the retry limit ends it if this keeps happening. Named below.
            $SavedDoneIds = @($AllCompletedFromStreams | Where-Object { $_ } | ForEach-Object { [string]$_ })
            foreach ($S in $StreamNoSummary) { $StreamUnproven += @($S.SubIds | ForEach-Object { [pscustomobject]@{ Id = [string]$_; StreamId = $S.StreamId; Reason = 'its stream ended without a usable summary, so it is collected again' } }) }
            $UnsavedDone = @($StreamUnproven | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace($_.Id) -and $SavedDoneIds -notcontains [string]$_.Id -and $GoneIds -notcontains [string]$_.Id } | Sort-Object -Property Id -Unique)
            foreach ($U in $UnsavedDone)
            {
                # Its name as this run lists it, else as the retry list has it, else its id.
                $UName = [string](@(@($PendingSubscriptions) + @($FailedAttempts) | Where-Object { $null -ne $_ -and [string]$_.Id -eq $U.Id -and $_.Name } | Select-Object -First 1).Name)
                $U | Add-Member -NotePropertyName Name -NotePropertyValue $(if ($UName) { $UName } else { $U.Id })
                Write-Host ("[stream-{0}] WARNING: {1} is not counted done: {2}." -f $U.StreamId, $U.Name, $U.Reason) -ForegroundColor Yellow
                $FailedSubscriptions += ("{0} (stream-{1}: {2})" -f $U.Name, $U.StreamId, $U.Reason)
            }
            if ($AllCompletedFromStreams.Count -gt 0)
            {
                $CompletedIds = @($CompletedIds + $AllCompletedFromStreams | Sort-Object -Unique)
            }
            # Last, so a report a stream recorded this run replaces an earlier one.
            $CompletedReports = @(@($CompletedReports) + @($AllReportsFromStreams))
            # A sub a stream failed this run is not completed, even when an earlier
            # run completed it: take it off the list and drop its report record,
            # as the sequential branch does, so Merge-FailedAttempts keeps the
            # failure and a later -Resume collects the sub again. The same goes for
            # a sub a stream collected this run without a zip being written.
            $FailedThisRun = @($StreamFailedIds | Where-Object { $_ })
            $NotCompletedThisRun = @(@($FailedThisRun) + @($StreamNoReportIds | Where-Object { $_ }) + @($UnsavedDone | ForEach-Object { [string]$_.Id }))
            if ($NotCompletedThisRun.Count -gt 0)
            {
                $CompletedIds = @($CompletedIds | Where-Object { $NotCompletedThisRun -notcontains $_ })
                $CompletedReports = @($CompletedReports | Where-Object { $null -ne $_ -and $NotCompletedThisRun -notcontains [string]$_.Id })
            }
            # Reconcile failed attempts from all streams against the unified list.
            # See Merge-FailedAttempts for the recency/completion rules.
            # A stream reads its own file, which can still hold an entry this
            # run dropped as gone at the start (an interrupted run left it).
            $AllFailedFromStreams = @($AllFailedFromStreams | Where-Object { $null -ne $_ -and $GoneIds -notcontains [string]$_.Id })
            # This run's streams start from the parent's entries and count on
            # from them, so an entry of this run's files with more failed runs
            # than the parent's is this run's failure, whatever the clocks say:
            # the parent's is dropped before the merge picks by time. Counts are
            # read as everywhere (Get-FailedAttemptCount).
            $PriorAttempts = @{}
            foreach ($P in @($FailedAttempts | Where-Object { $null -ne $_ })) { $PriorAttempts[[string]$P.Id] = Get-FailedAttemptCount -Entry $P }
            $Counted = @{}
            foreach ($E in @($ThisRunFailedFromStreams | Where-Object { $null -ne $_ -and $GoneIds -notcontains [string]$_.Id })) { $Id = [string]$E.Id; if ($PriorAttempts.ContainsKey($Id) -and (Get-FailedAttemptCount -Entry $E) -gt $PriorAttempts[$Id]) { $Counted[$Id] = $true } }
            $FailedAttempts = @($FailedAttempts | Where-Object { $null -ne $_ -and -not $Counted.ContainsKey([string]$_.Id) })
            $FailedAttempts = Merge-FailedAttempts -ExistingFailedAttempts $FailedAttempts -StreamFailedAttempts $AllFailedFromStreams -CompletedIds $CompletedIds
            # A sub with no parent entry counts from 0, so its first failure counts.
            $FailedThisRunIds = @($ThisRunFailedFromStreams | Where-Object {
                    $null -ne $_ -and $GoneIds -notcontains [string]$_.Id -and (Get-FailedAttemptCount -Entry $_) -gt $(if ($PriorAttempts.ContainsKey([string]$_.Id)) { $PriorAttempts[[string]$_.Id] } else { 0 })
                } | ForEach-Object { [string]$_.Id })
            # A sub a stream's summary lists as failed whose failure this run its
            # stream's own file does not hold (that file could not be read, or
            # holds only the parent's entry because a save did not reach the disk)
            # goes on the retry list here as one more failed run, so
            # -ResumeFailedOnly retries it and the count stays right. A stream
            # starts from the parent's entries for its slice and saves them as
            # they are, so only an entry that counts one more failed run than
            # the parent's (or a first one) is this run's.
            foreach ($FailedEntry in @($StreamFailedEntries | Where-Object { $null -ne $_ -and $FailedThisRunIds -notcontains [string]$_.Id -and $GoneIds -notcontains [string]$_.Id -and $CompletedIds -notcontains [string]$_.Id } | Sort-Object -Property Id -Unique))
            {
                $EntryName = if ($FailedEntry.PSObject.Properties['Name']) { [string]$FailedEntry.Name } else { '' }
                $EntryReason = if ($FailedEntry.PSObject.Properties['Reason']) { [string]$FailedEntry.Reason } else { '' }
                $FailedAttempts = Add-FailedAttempt -Existing $FailedAttempts -Id ([string]$FailedEntry.Id) -Name $EntryName -Reason $EntryReason
            }
            # Fail-safe rule: a collected sub whose result was not saved is one
            # more failed run (counted once), so the retry limit ends it.
            foreach ($U in @($UnsavedDone | Where-Object { $FailedThisRunIds -notcontains [string]$_.Id }))
            {
                $FailedAttempts = Add-FailedAttempt -Existing $FailedAttempts -Id ([string]$U.Id) -Name $U.Name -Reason $U.Reason
            }
            if ($AllCompletedFromStreams.Count -gt 0 -or $AllFailedFromStreams.Count -gt 0 -or $NotCompletedThisRun.Count -gt 0 -or $StreamFailedEntries.Count -gt 0)
            {
                Save-CompletedSubscriptionIds -Path $ResumeStateFile -Tenant $TenantID -Ids $CompletedIds -FailedAttempts $FailedAttempts -Reports $CompletedReports
            }
            # Also delete the per-stream resume files that were read, once the
            # unified file on disk holds the whole state they were merged into
            # (read back by Test-ResumeStateSaved). This prevents
            # drift if a future run uses a different stream count. A file that
            # could not be read, or whose records are not all saved, is kept and
            # named, so a later run can fold it in.
            # (Nothing was saved when the streams gave no record: then there is
            # nothing in their files to keep.)
            $StreamStateSaved = $true
            if ($AllCompletedFromStreams.Count -gt 0 -or $AllFailedFromStreams.Count -gt 0 -or $NotCompletedThisRun.Count -gt 0 -or $StreamFailedEntries.Count -gt 0)
            {
                $StreamStateSaved = Test-ResumeStateSaved -Path $ResumeStateFile -Tenant $TenantID -Ids $CompletedIds -FailedAttempts $FailedAttempts -Reports $CompletedReports
            }
            if ($StreamStateSaved)
            {
                foreach ($StreamFile in $MergedStreamFiles)
                {
                    $PerStreamFile = $StreamFile.FullName
                    try { Remove-Item -LiteralPath $PerStreamFile -Force -ErrorAction Stop }
                    catch
                    {
                        Write-Host ("WARNING: Could not remove the per-stream resume state file {0}: {1}. Its records are saved; this run keeps the resume state and ends with exit 2. Remove it before the next run." -f $PerStreamFile, $_.Exception.Message) -ForegroundColor Yellow
                        $LeftStreamFiles += $PerStreamFile
                    }
                }
            }
            else
            {
                # Fail-safe rule: the save is not proven, so nothing this run did
                # counts as done. Its per-stream files are kept, and the next
                # run's start folds in only their failures.
                if (@($MergedStreamFiles).Count -gt 0) { Write-Host ("WARNING: The resume state file {0} does not hold every record of this run's per-stream files, so they are kept for the next run: {1}" -f $ResumeStateFile, (@($MergedStreamFiles | ForEach-Object { $_.FullName }) -join ', ')) -ForegroundColor Yellow }
                else { Write-Host ("WARNING: The resume state file {0} could not be saved with this run's results, so none of them counts as done; see FAILED (resume state not saved) below." -f $ResumeStateFile) -ForegroundColor Yellow }
                # The file does not hold this run's results, as after a save that
                # failed: at the end of the run it is put aside (FAILED (resume
                # state not saved), exit 2), unless the end-of-run clean-run rule
                # removes it first.
                $script:ResumeStateSaveFailed = $true
                # They keep the resume state too: the run neither clears it nor
                # calls itself clean while they wait for the next run (exit 2).
                $LeftStreamFiles += @($MergedStreamFiles | ForEach-Object { $_.FullName })
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

# A run without -Resume or -ResumeFailedOnly has now collected every
# subscription, so a per-stream file of an earlier run put aside as unreadable
# (before this run, or by its start) holds nothing newer than this run's own
# records: it is removed, so no later -Resume names it again or folds it in.
# One this run's own merge put aside holds this run's records and is kept (it
# is named, with exit 2). All are kept while the state still lists as completed
# a subscription this run did not collect (left out of its set, or missing
# from a listing that came back incomplete): a file can hold a newer failure of
# it, which a later -Resume would otherwise skip as completed. Any other
# subscription it holds was collected by this run or has no completion to
# skip. One that cannot be removed is named, with the advice to delete it, not
# to rename it back.
if (-not ($Resume -or $ResumeFailedOnly))
{
    $OlderCompletions = @($CompletedIds | Where-Object { $_ -and $RunSubscriptionIds -notcontains [string]$_ })
    # Those kept here: removed below if the run then clears the resume state.
    $KeptAsideFiles = @()
    foreach ($Aside in @($StaleAsideFiles | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) }))
    {
        if ($OlderCompletions.Count -gt 0)
        {
            Write-Host ("Kept: {0}, a per-stream resume state file put aside as unreadable. The resume state still lists {1} subscription(s) this run did not collect as completed, and the file may hold a newer failure of one, so every -Resume names it until it is fixed and renamed back, or deleted." -f $Aside, $OlderCompletions.Count) -ForegroundColor Yellow
            $KeptAsideFiles += $Aside
            continue
        }
        try { Remove-Item -LiteralPath $Aside -Force -ErrorAction Stop }
        catch { Write-Host ("WARNING: Could not remove {0}, a per-stream resume state file put aside as unreadable that this run makes stale: {1}. Delete it; do not rename it back." -f $Aside, $_.Exception.Message) -ForegroundColor Yellow }
    }
}
Write-Host "All subscriptions processed!" -ForegroundColor Green
# From here on a step that stops the run (Exit-Wrapper with a non-zero code)
# still puts aside a resume state this run could not save (fail-safe rule).
$script:RdaNotSavedStateFile = $ResumeStateFile
$script:RdaNotSavedOnExit = $true

# A -Resume run skips the subscriptions an earlier run completed, but their
# reports still belong in this run's consolidated zip. Each one's recorded zip is
# carried in after Get-ResumeCarriedReports checks it; one that cannot be carried
# is named under the FAILED (earlier report not carried) banner at the end and
# sets exit code 2.
$CarriedReports = @()
$UncarriedSkipped = @()
if ($Resume -and @($SkippedSubscriptions).Count -gt 0)
{
    $ResumeCarry = Get-ResumeCarriedReports -SkippedSubscriptions $SkippedSubscriptions -Reports $CompletedReports -InventoryRoot $InventoryRoot -Obfuscated ([bool]$Obfuscate)
    $CarriedReports = @($ResumeCarry.Carried)
    $UncarriedSkipped = @($ResumeCarry.Missing)
    if ($CarriedReports.Count -gt 0)
    {
        Write-Host ("Resume: carrying {0} report(s) of subscription(s) completed by an earlier run into the consolidated zip." -f $CarriedReports.Count) -ForegroundColor Cyan
        # When each carried report was written, so an old one is visible here.
        # There is no age limit; the age is read from the zip's last-write time.
        foreach ($Carried in $CarriedReports)
        {
            $ZipItem = Get-Item -LiteralPath $Carried.Zip -ErrorAction SilentlyContinue
            if ($null -eq $ZipItem)
            {
                Write-Host ("  - {0}: report date unknown" -f $Carried.Name) -ForegroundColor Cyan
                continue
            }
            $AgeDays = [int][math]::Max(0, [math]::Floor(((Get-Date).ToUniversalTime() - $ZipItem.LastWriteTimeUtc).TotalDays))
            Write-Host ("  - {0}: report written {1}, {2} day(s) ago" -f $Carried.Name, $ZipItem.LastWriteTime.ToString('yyyy-MM-dd HH:mm'), $AgeDays) -ForegroundColor Cyan
        }
    }
}
$CarriedFolderNames = @($CarriedReports | ForEach-Object { $_.Folder })

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
# On -Resume, the zips carried from an earlier run count on both sides: they
# were checked when carried and are added to the found set below.
$ExpectedZipCount = @($SubResourceCounts).Count + $CarriedReports.Count
if ($ExpectedZipCount -gt 0 -and (Test-Path -Path $InventoryRoot -PathType Container))
{
    $ActualSubZips = @(Get-ChildItem -Path $InventoryRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object { Get-ChildItem -Path $_.FullName -Filter "*.zip" -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $RunStartTime -and -not ($PreRunZips -and $PreRunZips.Contains($_.FullName)) } })
    $ActualSubZips = @(Join-CarriedReportZips -Zips $ActualSubZips -CarriedReports $CarriedReports)
    $ActualZipCount = $ActualSubZips.Count
    if ($ActualZipCount -lt $ExpectedZipCount)
    {
        $MissingCount = $ExpectedZipCount - $ActualZipCount
        $CarriedNote = if ($CarriedReports.Count -gt 0) { ', plus {0} carried from an earlier run' -f $CarriedReports.Count } else { '' }
        Write-Host ""
        Write-Host "ERROR: Per-subscription output verification failed." -ForegroundColor Red
        Write-Host ("  Expected zips: {0} (one per subscription that ran to completion this run{1})" -f $ExpectedZipCount, $CarriedNote) -ForegroundColor Red
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
    if ($UncarriedSkipped.Count -gt 0)
    {
        Write-Host ("Per-subscription output verification: INCOMPLETE ({0} zip(s) found, but {1} subscription(s) skipped by -Resume have no earlier report to carry - see FAILED (earlier report not carried) below)" -f $ActualZipCount, $UncarriedSkipped.Count) -ForegroundColor Red
    }
    elseif ($CarriedReports.Count -gt 0)
    {
        Write-Host ("Per-subscription output verification: OK ({0} zip(s) match {1} successful sub(s) this run + {2} carried from an earlier run)" -f $ActualZipCount, @($SubResourceCounts).Count, $CarriedReports.Count) -ForegroundColor Green
    }
    else
    {
        Write-Host ("Per-subscription output verification: OK ({0} zip(s) match {0} successful sub(s))" -f $ActualZipCount) -ForegroundColor Green
    }
}

# Consolidate per-subscription ZIPs into a single outer ZIP
$OuterZipFile = $null

if (Test-Path -Path $InventoryRoot -PathType Container)
{
    # Filter ZIPs by current run timestamp only, plus the zips carried from an earlier run on -Resume
    # (and never one that was there when this run started: see $PreRunZips).
    # shortcut: a second wrapper writing to the same inventory folder at the same time
    # could add its zips; one wrapper per folder is supported. A cut-off run leaves no
    # late writer: its stream jobs end with it (measured on Linux; Windows not checked).
    $SubZips = @(Get-ChildItem -Path $InventoryRoot -Directory | ForEach-Object { Get-ChildItem -Path $_.FullName -Filter "*.zip" -File | Where-Object { $_.LastWriteTime -ge $RunStartTime -and -not ($PreRunZips -and $PreRunZips.Contains($_.FullName)) } })
    $SubZips = @(Join-CarriedReportZips -Zips $SubZips -CarriedReports $CarriedReports)
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
        New-RdaAllSubHtmlSummary -RunOutputDirectory $InventoryRoot -HtmlFile $MainSummaryFile -SinceTime $RunStartTime -IncludeFolders $CarriedFolderNames -ExcludeFolders @($PreRunReportDirs) `
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
# -ResumeFailedOnly collects only the retry list, so an eligible subscription
# that is neither completed nor on the retry list (one an interrupted run never
# reached) is still owed: the state is kept, so a later -Resume collects it and
# still skips the completed ones. The summary below names them.
$NotCollected = @()
if ($ResumeFailedOnly)
{
    $RetryListIds = @($FailedAttempts | Where-Object { $_ } | ForEach-Object { [string]$_.Id })
    $NotCollected = @(Get-NotCollectedSubscriptions -Eligible $EligibleBeforeRetryFilter -CompletedIds $CompletedIds -RetryIds $RetryListIds -NotReadableIds $NotReadableIds)
}
# The retry-list entries past the retry limit, listed as incomplete in the
# summary. They keep the state (see $RetryOwedCount), so the next -Resume or
# -ResumeFailedOnly run skips them again and ends with exit 2.
$RetryLimited = @(Get-RetryLimitedAttempts -FailedAttempts $FailedAttempts)
$RetryLimitedOwed = @($RetryLimited | Where-Object { $RetryLimitedNotInRunIds -contains [string]$_.Id })
# Retry-list entries this run did not collect because their subscription was
# not in its set (see $RetryNotInRunIds), below the retry limit (those past it
# are named under Retry Limit Reached): their reports are missing, so the run
# ends with exit 2 and says how to end that.
$RetryOwedNotInRun = @($FailedAttempts | Where-Object { $null -ne $_ -and $RetryNotInRunIds -contains [string]$_.Id -and @($RetryLimitedOwed | ForEach-Object { [string]$_.Id }) -notcontains [string]$_.Id })
# Every entry keeps the state, those past the limit included: clearing the
# state would forget their count, so the next -Resume would collect them again
# from the first attempt and the limit would never end the cycle. They leave
# the state only when a run without -Resume or -ResumeFailedOnly collects them,
# or when they are no longer visible. ResourceInventory.ps1 run on its own does
# not read or write the state.
$RetryOwedCount = @($FailedAttempts | Where-Object { $null -ne $_ }).Count
$RunClean = ($FailedSubscriptions.Count -eq 0 -and $RetryOwedCount -eq 0 -and $NotCollected.Count -eq 0 -and $UnreadableStreamFiles.Count -eq 0 -and $LeftStreamFiles.Count -eq 0)
if ($RunClean -and (Test-Path -LiteralPath $ResumeStateFile -PathType Leaf))
{
    try
    {
        Remove-Item -LiteralPath $ResumeStateFile -Force -ErrorAction Stop
        if (-not (Test-Path -LiteralPath $ResumeStateFile))
        {
            Write-Host "Resume state cleared (clean run)." -ForegroundColor Green
        }
        else { Write-Host ("WARNING: Could not remove resume state file {0}: it is still there after the removal." -f $ResumeStateFile) -ForegroundColor Yellow }
    }
    catch
    {
        Write-Host ("WARNING: Could not remove resume state file {0}: $_" -f $ResumeStateFile) -ForegroundColor Yellow
    }
}
# A state file that stays although this clean run could not save its results
# is not shown to hold them: it is handled as not saved below (put aside, exit 2).
if ($RunClean -and $ResumeStateSaveFailed -and (Test-Path -LiteralPath $ResumeStateFile -PathType Leaf)) { $RunClean = $false }

# A state an earlier run put aside as not saved goes once it is out of date: a
# clean run owes nothing, and a run whose resume state was saved holds its
# failures (read in at the start by the run that found no state, and kept by
# every save since). One that cannot be removed is named.
if ($RunClean -or (-not $ResumeStateSaveFailed -and (Test-Path -LiteralPath $ResumeStateFile -PathType Leaf)))
{
    foreach ($Aside in @($StatePutAside | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) }))
    {
        try { Remove-Item -LiteralPath $Aside -Force -ErrorAction Stop }
        catch { Write-Host ("WARNING: Could not remove {0}, a resume state an earlier run put aside as not saved, which is now out of date: {1}. Delete it: while it is there with no resume state file, -ResumeFailedOnly does not run." -f $Aside, $_.Exception.Message) -ForegroundColor Yellow }
    }
}

# A put-aside file kept above for an older completion: once a clean run has
# cleared the resume state there is no completion left for a -Resume to skip,
# so it goes too, and no later -Resume names it.
if (-not ($Resume -or $ResumeFailedOnly) -and @($KeptAsideFiles).Count -gt 0 -and -not (Test-Path -LiteralPath $ResumeStateFile -PathType Leaf))
{
    foreach ($Aside in @($KeptAsideFiles | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) }))
    {
        try
        {
            Remove-Item -LiteralPath $Aside -Force -ErrorAction Stop
            Write-Host ("Removed: {0}, kept above. The resume state is cleared, so no completion is left for a -Resume to skip." -f $Aside) -ForegroundColor Green
        }
        catch { Write-Host ("WARNING: Could not remove {0}, a per-stream resume state file put aside as unreadable that this run makes stale: {1}. Delete it; do not rename it back." -f $Aside, $_.Exception.Message) -ForegroundColor Yellow }
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
# In parallel mode the parent counts $SkippedCount as it builds the list it
# slices (the completed subscriptions it leaves out on -Resume).
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
elseif ((@($FailedAttempts | Where-Object { $null -ne $_ }).Count - $RetryLimited.Count - $RetryOwedNotInRun.Count) -gt 0)
{
    # No new failures this run, but the resume-state file still has lingering
    # FailedAttempts from a prior run that have not yet been retried. Surface
    # them so the operator does not lose track of historical failures simply
    # because the most recent run was clean. The entries past the retry limit
    # are named under Retry Limit Reached instead, and those not in this run's
    # subscription set under Not In This Run; -ResumeFailedOnly does not
    # retry them, so they are not counted here.
    Write-Host ("Pending Retries:         {0} subscription(s) from a prior run still in FailedAttempts" -f (@($FailedAttempts | Where-Object { $null -ne $_ }).Count - $RetryLimited.Count - $RetryOwedNotInRun.Count)) -ForegroundColor Yellow
    Write-Host "Re-run with -ResumeFailedOnly to retry them." -ForegroundColor Yellow
}
if ($NotCollected.Count -gt 0)
{
    # Set by the resume-state cleanup above on a -ResumeFailedOnly run.
    Write-NotCollectedSummary -NotCollected $NotCollected -ResumeStateFile $ResumeStateFile
}
if ($RetryLimited.Count -gt 0)
{
    # Set by the resume-state cleanup above.
    Write-RetryLimitSummary -RetryLimited $RetryLimited -TenantID $TenantID -ExcludedIds @($Excluded | ForEach-Object { [string]$_.Id }) -NotListedIds $KeptNotListedIds -NotReadableIds @(if ($null -ne $AccessDecision) { @($AccessDecision.InaccessibleIds) | Where-Object { $_ } | ForEach-Object { [string]$_ } })
}
if ($RetryOwedNotInRun.Count -gt 0)
{
    Write-Host ("Not In This Run:         {0} ({1}) - on the retry list, but not in this run's subscription set (disabled without -IncludeDisabled, not listed, or not readable)" -f $RetryOwedNotInRun.Count, (@($RetryOwedNotInRun | ForEach-Object { '{0} ({1})' -f $_.Name, $_.Id }) -join ', ')) -ForegroundColor Yellow
    Write-Host ("  Fix that and run again, or delete the resume state files .resume-state-{0}.json and .resume-state-{0}-stream-*.json in the inventory folder to start over with an empty retry list." -f $TenantID) -ForegroundColor Yellow
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
            -RetryLimited $RetryLimited `
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
        #    data". Scoped to THIS run by timestamp, plus the report folders
        #    carried from an earlier run on -Resume; a de-obfuscated
        #    *_revealed* report is never copied across.
        foreach ($SubDir in @(Get-ChildItem -Path $InventoryRoot -Directory -Filter 'ResourcesReport*' -ErrorAction SilentlyContinue | Where-Object { ($_.LastWriteTime -ge $RunStartTime -and -not ($PreRunReportDirs -and $PreRunReportDirs.Contains($_.FullName))) -or $CarriedFolderNames -contains $_.Name }))
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

# A subscription -Resume skipped as completed whose earlier report zip could not
# be carried is missing from the consolidated zip. Named here with the reason and
# the way to collect it; sets exit code 2 below.
if (@($UncarriedSkipped).Count -gt 0)
{
    Write-Host ""
    Write-Host "============== FAILED (earlier report not carried) ==============" -ForegroundColor Red
    Write-Host ("{0} subscription(s) were skipped by -Resume as completed by an earlier run, but that run's report could not be carried into the consolidated zip:" -f @($UncarriedSkipped).Count) -ForegroundColor Red
    foreach ($U in @($UncarriedSkipped))
    {
        Write-Host ("  - {0} ({1}): {2}" -f $U.Name, $U.Id, $U.Reason) -ForegroundColor Red
    }
    Write-Host "Their reports are NOT in the consolidated zip. Re-run without -Resume to collect every subscription again," -ForegroundColor Red
    Write-Host "or collect each one listed above on its own with:" -ForegroundColor Red
    foreach ($U in @($UncarriedSkipped))
    {
        Write-Host ("  ./ResourceInventory.ps1 -TenantID {0} -SubscriptionID {1}" -f $TenantID, $U.Id) -ForegroundColor Red
    }
    Write-Host "=================================================================" -ForegroundColor Red
}

# A save of the resume state that failed this run (Save-CompletedSubscriptionIds
# warned, or the end-of-run merge could not read back what it saved), with no
# later save that reached the disk, can leave the file listing a subscription
# this run failed as completed, so a -Resume run would skip it and carry its old
# report, and a -ResumeFailedOnly run would miss it. Fail-safe rule: a file that
# cannot be shown to hold this run's results is not used again. Unless the run
# is clean (then it was removed above, and nothing is owed), it is put aside as
# <file>.not-saved-<time> (a rename, which works on a full disk); with no file to
# put aside, an empty one of that name is made, as a mark. While such a mark is
# there and no resume state file is, -ResumeFailedOnly refuses to run (it cannot
# tell what is owed) and no -Resume skips a subscription as done. Only when neither
# works does the note ask to run without -Resume or -ResumeFailedOnly. The run
# ends with exit 2 (see the exit code below).
# Done here at the end, or by Exit-Wrapper when a later step stops the run (see
# $RdaNotSavedOnExit below "All subscriptions processed!").
$script:RdaNotSavedOnExit = $false
if ($ResumeStateSaveFailed -and -not $RunClean) { $null = Set-NotSavedResumeStateAside -ResumeStateFile $ResumeStateFile }

# Stop the wrapper transcript on the normal-completion path. Error paths take
# Exit-Wrapper which does the same.
if ($WrapperTranscriptStarted)
{
    try { Stop-Transcript | Out-Null }
    catch { Write-Verbose ("Stop-Transcript on normal completion failed: {0}" -f $_.Exception.Message) }
}


$AuthSkipped = $AuthSkippedPhases.Count -gt 0
$CollectorsFailed = @($Global:CollectorFailures).Count -gt 0
$WrapperExitCode = Get-WrapperExitCode -AuthSkipped $AuthSkipped -CollectorsFailed $CollectorsFailed -ReportsMissing (($ResumeStateSaveFailed -and -not $RunClean) -or (@($UncarriedSkipped).Count -gt 0) -or (@($RetryLimitedOwed).Count -gt 0) -or (@($UnreadableStreamFiles).Count -gt 0) -or (@($LeftStreamFiles).Count -gt 0) -or (@($RetryOwedNotInRun).Count -gt 0)) -SubscriptionsFailed (@($FailedSubscriptions | Where-Object { $null -ne $_ }).Count -gt 0)
if ($WrapperExitCode -ne 0)
{
    exit $WrapperExitCode
}

