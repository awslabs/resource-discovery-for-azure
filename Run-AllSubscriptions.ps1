#!/usr/bin/env pwsh
param (
    # NOT Mandatory, deliberately - see the -TenantID guard immediately after this
    # param block. Mandatory made PowerShell PROMPT for a missing value, which any
    # non-interactive caller (CI, a scheduled task, the AKS entrypoint, a run whose
    # output is redirected) experiences as a silent indefinite hang with no output.
    # The guard below fails loudly with a non-zero exit instead.
    #
    # The bare [Parameter()] MUST stay: it is the only [Parameter()] attribute in
    # this file and there is no [CmdletBinding()], so it is what makes this an
    # ADVANCED script. Dropping it would silently turn unrecognized arguments into
    # $args instead of an error - the same class of failure the equivalent guard in
    # ResourceInventory.ps1 exists to prevent.
    [Parameter()]
    [string]$TenantID,
    [switch]$DeviceLogin,
    [switch]$Obfuscate,
    [switch]$SkipMetrics,
    [switch]$SkipConsumption,

    # EXPERIMENTAL (default OFF). Forwarded to ResourceInventory.ps1's
    # -UseMetricsBatch (and on to Extension/Metrics.ps1) for every subscription,
    # in both the sequential and parallel-streams paths. When set, VM/disk/storage
    # metrics are collected via the Azure Monitor metrics:getBatch data-plane API
    # (one request per <=50 resources) instead of one Get-AzMetric per
    # (resource, metric), which is faster and lowers the metric-query API-call
    # count. The tool will attempt to register the Microsoft.Insights provider if
    # needed, and falls back to the per-call path on any batch failure (no data
    # lost). See the -UseMetricsBatch notes in Extension/Metrics.ps1.
    [switch]$UseMetricsBatch,

    # Metric-volume controls for very large tenants. Forwarded to every
    # subscription in both the sequential and parallel-streams paths, and honoured
    # by -Plan when it sizes the run - except -MetricsIntervalMinutes and
    # -MetricsLookbackDays, which -Plan cannot size from because neither changes
    # the metric-query COUNT.
    #   -IncludeStorageMetrics : OPT-IN to the Storage Account 'UsedCapacity'
    #                         metric (1 Azure Monitor call per storage account).
    #                         NOT collected by default: on a tenant with a very
    #                         large storage estate that one capacity figure can
    #                         dominate the metrics phase. Pass it when storage
    #                         capacity is actually wanted.
    #   -SkipDiskMetrics    : skip the four Managed Disk composite I/O metrics
    #                         (4 calls per attached disk - the biggest call source).
    #   -MetricsIntervalMinutes : override the sampling grain of the high-frequency
    #                         VM / Azure SQL DB / OSS-DB (MariaDB, MySQL, PostgreSQL
    #                         + Flexible) utilization series. 0 = each series' native
    #                         cadence (15 min VM, 30 min SQL, 60 min OSS-DB). Reduces
    #                         data-point volume / memory / JSON size; does NOT reduce
    #                         API-call count. Limited to Azure Monitor's supported
    #                         sub-hourly grains. See the notes in Extension/Metrics.ps1.
    #   -MetricsLookbackDays : how many days of history to request for the
    #                         lookback-bound trend / utilization series (VM +
    #                         VMSS CPU/memory, the Managed Disk composite I/O
    #                         metrics, SQL DB, OSS-DB, Functions execution
    #                         counts). Omit to leave the inner script's 31-day
    #                         default in force. Like -MetricsIntervalMinutes it
    #                         does NOT reduce the API-call count - it changes the
    #                         data points each query returns, so it trades
    #                         right-sizing sample depth for run time / memory /
    #                         Metrics_*.json size, and it MULTIPLIES with the
    #                         grain knob. Capacity and limit metrics (including
    #                         storage UsedCapacity) use a fixed 24h window and are
    #                         NOT affected. Note the Managed Disk grain is fixed
    #                         at 15 min, so -MetricsIntervalMinutes cannot offset
    #                         a long window there - only -SkipDiskMetrics can.
    #                         Upper bound is Azure Monitor's 93-day platform-metric
    #                         retention. See the notes in Extension/Metrics.ps1.
    [switch]$IncludeStorageMetrics,
    [switch]$SkipDiskMetrics,
    [ValidateSet(0, 5, 15, 30, 60)][int]$MetricsIntervalMinutes = 0,
    # Deliberately NO default: an omitted value must leave ResourceInventory.ps1's
    # own 31-day default as the single authority, so it is forwarded below only
    # when the operator actually passed it. A visible 31 here would pin a second
    # copy of that default and drift the day the inner one changes. Validation is
    # essential rather than cosmetic: the inner param is untyped and unvalidated,
    # and Extension/Metrics.ps1 runs the value through [math]::Abs, so a negative
    # would silently become positive and a 0 would produce a zero-width window
    # that reports Success while shipping every trend metric as a measured 0.
    [ValidateRange(1, 93)][int]$MetricsLookbackDays,

    # Re-collect ONLY these inventory collectors (by their Services/*.ps1
    # BaseName, e.g. VirtualMachines, Streamanalytics), across every in-scope
    # subscription. Forwarded to ResourceInventory.ps1's own -Service filter.
    # This scopes the INVENTORY phase ONLY - metrics and consumption still run for
    # the whole subscription - so it is intended for RECOVERING a specific failed
    # collector, and should be paired with -SkipMetrics -SkipConsumption for a
    # clean inventory-only run. It is NOT a general workload filter: to target a
    # single workload (and scope its metrics too) run ResourceInventory.ps1
    # directly with -SubscriptionID + -ResourceGroup instead. Omit to collect all
    # services (default). Accepts a comma list as one token
    # (-Service VirtualMachines,Streamanalytics) or a PowerShell array; unknown
    # names fail fast up front with the valid list.
    [string[]]$Service,

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

    # Check permissions and stop - collect nothing. Runs the normal sign-in,
    # tenant, coverage and Reader gates, then probes EVERY in-scope subscription
    # for the two data-phase permissions the run needs (Cost Management Reader
    # for consumption, Monitoring Reader for metrics) and prints a per-subscription
    # matrix with the exact role to grant. Today those two gaps otherwise surface
    # only mid-run (consumption is probed on one subscription; metrics not at
    # all). Exit 0 when nothing requested is denied, 1 otherwise. Honours
    # -SkipMetrics / -SkipConsumption (a skipped phase is not probed).
    [switch]$Preflight,

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
    [int]$ParallelStreams = 1,

    # API headroom: leave this PERCENTAGE of the host's chosen metrics-collection
    # concurrency unused, so the run intentionally consumes less of the shared
    # Azure API throttle budget and leaves room for the customer's other/production
    # workloads. 0 (default) = no reduction (full concurrency). Example:
    # -HeadRoom 20 keeps ~20% of the concurrency in reserve (the effective
    # -ConcurrencyLimit is scaled to 80% of its chosen value, floored, minimum 1).
    #
    # NOTE on scope: Azure Resource Manager throttles PER security principal PER
    # subscription/tenant, plus a shared tenant-wide/global ceiling and per-
    # resource-provider limits. Running under a dedicated identity already isolates
    # most of RDA's per-principal budget from production; -HeadRoom additionally
    # lowers RDA's peak request rate (it reduces the concurrent Get-AzMetric call
    # count - the run's heaviest ARM / Azure Monitor consumer) so it competes less
    # for the SHARED limits. It is a proportional throttle, not a hard reservation
    # of a fixed fraction of the hourly request bucket. Scaling ONLY concurrency
    # (not stream count) keeps the aggregate rate reduction predictable.
    [ValidateRange(0, 90)]
    [int]$HeadRoom = 0,

    # --- Horizontal scale-out (sharding) ------------------------------------
    # Split the tenant's subscriptions across N INDEPENDENT machines. Run the
    # same command on each machine with the SAME -ShardCount and a distinct
    # -ShardIndex (0..ShardCount-1); each machine processes ONLY its own shard of
    # the subscriptions. Assignment is a deterministic hash of each subscription
    # id, so the shards are disjoint and collectively cover every subscription
    # with NO coordination between machines - and a subscription added/removed
    # (or an access difference) on one machine only affects its own shard.
    #
    # This is orthogonal to -ParallelStreams: sharding scales ACROSS machines,
    # -ParallelStreams scales ACROSS cores within one machine. A typical 10k-sub
    # run uses one shard per machine, each still using parallel streams locally.
    # Each shard keeps its own resume-state file
    # (.resume-state-<TenantID>-shard-<Index>of<Count>.json) so shards never race
    # on progress. Default ShardCount=1 (no sharding) is byte-identical to a
    # non-sharded run. Each shard produces its OWN consolidated
    # AllSubscriptions_ResourcesReport_*.zip covering only its slice; because the
    # slices are disjoint they can be uploaded to the ingestion server separately
    # (recommended - spreads load, no merge step). To instead build ONE
    # tenant-wide MainSummary locally, extract the inner per-subscription zips out
    # of every shard's outer zip into one folder, re-zip them into a single outer
    # zip, then run Build-MainSummaryFromZip.ps1 -InputZip on that. See
    # docs/horizontal-sharding.md and the README "Horizontal scaling" section.
    [int]$ShardIndex = 0,
    [int]$ShardCount = 1,

    # After the run, upload THIS machine's consolidated report zip to an Azure
    # Blob container, so a multi-node / AKS operator does not have to SSH into
    # every worker to collect output - each node ships its own zip. Pass the
    # container URL, e.g. https://<account>.blob.core.windows.net/<container>
    # (an optional path after the container becomes a blob-name prefix).
    #
    # The upload uses the CURRENT signed-in identity (Connect-AzAccount, or the
    # AKS workload identity in a pod) via Azure AD - NO account key or SAS token -
    # so that identity needs the "Storage Blob Data Contributor" role on the
    # target account/container. When sharding (ShardCount > 1) the blob name is
    # prefixed with the shard index (shard-<i>of<N>-), so the disjoint shards
    # never collide; the report zip name also carries the run timestamp. The
    # upload is best-effort: if it fails, the run still succeeds and the zip
    # remains on the local disk (a loud WARNING is printed). Omit to skip upload
    # (default).
    [string]$UploadToBlobContainerUri,

    # Mirror the resume/state file to an Azure Blob container so a run survives
    # the loss of local disk - the case that matters on AKS, where a pod's
    # emptyDir is destroyed on eviction/reschedule/node-reclaim (exactly when
    # -Resume is needed). Same URL shape as -UploadToBlobContainerUri
    # (https://<account>.blob.core.windows.net/<container>[/<prefix>]); state
    # lives under a dedicated _state/ subfolder (shard-namespaced) so it never
    # collides with the report zips in the same container. Uses the SAME
    # passwordless identity as the upload (Storage Blob Data Contributor). Writes
    # are write-through (local atomic write first, then a best-effort blob PUT);
    # reads on start are blob-first with a local fallback. Omit to keep state
    # local-only (default) - behaviour is then byte-identical to before.
    [string]$StateBlobContainerUri,

    # Assess-only "getting started" bootstrap. When set, the wrapper authenticates,
    # enumerates the tenant's eligible subscriptions, and sizes the run against
    # THIS machine (CPU/RAM -> recommended parallel streams), then PRINTS a
    # recommendation and EXITS without inventorying anything. For a tenant that one
    # machine can finish within a ~2-hour wall-time ceiling it recommends a single
    # run with concrete -ParallelStreams/-ConcurrencyLimit; for a larger tenant it
    # recommends how many machines (shards) to split across and prints the ready-
    # to-paste per-node command (same command, distinct -ShardIndex). The per-
    # subscription time is a rough estimate (auto-picked from the -Skip* switches),
    # so treat the output as guidance, not a guarantee.
    [switch]$Plan,

    # -Plan only: override the estimated wall-time cost, in seconds, of a single
    # Azure Monitor metric query. -Plan sizes shards from each subscription's
    # projected metric-query volume (counted live via Resource Graph: attached
    # disks x4, VMs x2, SQL databases x8, storage accounts x1, scale sets x2,
    # Cosmos x4, etc.) multiplied by this per-query cost. When 0 (default) the
    # cost is auto-picked: a small value when -UseMetricsBatch is set (getBatch
    # amortizes up to 50 resources per REST call) and a larger throttled per-call
    # value otherwise. These defaults are deliberately rough - for an accurate
    # estimate on your tenant/config, pass a value measured from a prior run's
    # Diagnostics phase timings (metrics seconds / metric-query count).
    [double]$PlanPerQuerySeconds = 0
)

# ---------------------------------------------------------------------------
# -TenantID guard: fail loudly instead of prompting.
#
# -TenantID used to be Mandatory, so PowerShell prompted when it was missing. A
# prompt is invisible to a non-interactive caller - CI, a scheduled task, the AKS
# entrypoint, or any run whose output is redirected - so the run simply hung with
# no output and no exit code, indistinguishable from work in progress. Failing
# here turns that into an immediate, diagnosable error.
#
# Placed BEFORE the PowerShell 7 bootstrap below on purpose: there is no point
# re-launching (or offering to INSTALL) PowerShell 7 for an invocation that cannot
# succeed either way. For the same reason this block stays inside the 5.1 + 7
# common language subset the bootstrap documents - no ternary, no ?? / ??=, no
# && / ||, no -Parallel - so Windows PowerShell 5.1 reaches it and reports the
# same error rather than choking at parse time.
#
# exit 1 (not throw) matches how the other entry points reject bad input, so a
# wrapper-driven or CI-driven run sees a non-zero exit code it can act on.
if ([string]::IsNullOrWhiteSpace($TenantID))
{
    Write-Host "ERROR: -TenantID is required." -ForegroundColor Red
    Write-Host "Supply the tenant to inventory, either its GUID or its domain name:" -ForegroundColor Yellow
    Write-Host "    ./Run-AllSubscriptions.ps1 -TenantID contoso.onmicrosoft.com" -ForegroundColor Yellow
    Write-Host "To read it from an existing signed-in session: (Get-AzContext).Tenant.Id" -ForegroundColor Yellow
    exit 1
}

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

# ---------------------------------------------------------------------------
# Az PowerShell module bootstrap. The wrapper (Connect-AzAccount, Get-AzSubscription)
# and the inner script (Get-AzMetric, consumption) all require the Az module.
# Detect it, and if missing offer to install it when interactive, or fail loud
# when non-interactive - the same pre-flight treatment as PowerShell 7.
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
# This tool only calls cmdlets from five Az submodules (Accounts / Compute /
# Monitor / Billing / ResourceGraph - the same set the ResourceInventory.ps1
# preflight validates), so install and check ONLY those, NOT the full `Az`
# rollup. Installing `Az` pulls in ~80 submodules (hundreds of DLLs) and takes
# several minutes plus a 20-40s import on every run; the slim set installs in a
# fraction of the time and cannot cause "command not found" because nothing
# outside these five is ever called.
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

# -MainSummary is accepted for backward compatibility and has NO effect: the
# aggregate MainSummary.html is now produced on every run and folded into the
# consolidated bundle regardless. Say so when it is actually passed, rather than
# only documenting it at the param block - an operator who passes a flag and sees
# nothing acknowledge it has no way to tell "retained no-op" from "silently
# ignored because I typo'd the intent". The operator still gets what they asked
# for, so this is Info, not a warning.
if ($PSBoundParameters.ContainsKey('MainSummary'))
{
    Write-Host "Note: -MainSummary is a retained no-op. The aggregate MainSummary.html is produced on EVERY run and folded into the consolidated bundle, so you already get it without this flag." -ForegroundColor DarkGray
}

$FailedSubscriptions = @()

# Subscriptions whose inner script could not write its report archive
# (ResourceInventory.ps1 exit code 2). Tracked separately from
# $FailedSubscriptions because it is the one failure class that means "a report
# is MISSING from the bundle" rather than "this subscription did not collect",
# and that is exactly what the wrapper's exit code 2 already signals. Without
# this the run would exit 0: the sub is correctly excluded from the expected
# archive count, so the per-subscription output verification gate has nothing to
# compare and stays silent, leaving a human-visible failure that automation
# checking only the exit code would read as success.
$ArchiveWriteFailures = @()

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
# Get-RdaInventoryRoot (Functions/Common.Functions.ps1) is the SINGLE resolver for
# this path. It creates the directory, PROVES it writable with a real write, and
# degrades to a writable fallback (naming it loudly) rather than letting the run
# continue toward a directory it cannot use. The previous inline computation
# swallowed a creation failure to Write-Verbose, so on a machine where the path was
# not writable the run carried on and failed later somewhere unrelated.
#
# -NoInherit because this is the process that ESTABLISHES the root for the whole
# run: a stale RDA_INVENTORY_ROOT left in the operator's shell from an earlier run
# must not be trusted. The resolved value is then pinned for children, so the inner
# script and every -ParallelStreams worker write under the SAME root instead of
# each re-deriving it - which is what keeps the consolidation step below looking in
# the directory the subscriptions actually wrote to.
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

# Validate the blob-upload request up front (before the multi-hour run). The
# operator EXPLICITLY asked to upload, so a malformed URL or a missing Az.Storage
# module must fail LOUD here rather than silently degrading to a warning at the
# very end - otherwise a whole run's output would be stranded on an ephemeral
# node with no way to collect it. (The upload itself, later, stays best-effort
# for transient/RBAC issues.)
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

# Resume state helpers. When sharding (ShardCount>1) each shard keeps its OWN
# unified resume-state file so shards never clobber each other's completed/failed
# progress. NOTE the intended topology is ONE shard per machine (each with its own
# InventoryRoot): the PER-STREAM artefacts used by -ParallelStreams (the
# .resume-state-<Tenant>-stream-<N>.json files, stream summaries and stream
# failure logs) are keyed by tenant + stream index only, NOT by shard, so running
# two shards concurrently on the SAME host with the SAME InventoryRoot and
# -ParallelStreams>1 would collide on those. Run each shard on its own machine (or,
# for same-box testing, give each a distinct InventoryRoot). The non-sharded
# filename is unchanged, so a normal run resumes exactly as before.
$ResumeStateFile = if ($ShardCount -gt 1)
{
    Join-Path $InventoryRoot (".resume-state-{0}-shard-{1}of{2}.json" -f $TenantID, $ShardIndex, $ShardCount)
}
else
{
    Join-Path $InventoryRoot (".resume-state-{0}.json" -f $TenantID)
}

# Blob-backed resume state (AKS pod-reschedule durability). Validate the URL
# shape + Az.Storage module up front - mirroring the -UploadToBlobContainerUri
# preflight - so a malformed URL / missing module fails LOUD here rather than
# after a multi-hour run. The passwordless storage CONTEXT is built later (after
# authentication + enumeration), just before the state is first read/written.
# $StateBlobParts is $null when the feature is off, keeping every downstream
# blob step a no-op and the run byte-identical to a local-only run.
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








# Authenticate, but only if needed.
#
# In environments like Azure Cloud Shell the shell already has a valid Az
# PowerShell session for the signed-in user. Unconditionally calling
# Connect-AzAccount from the wrapper produces a redundant browser/device-code
# prompt every run.
#
# Two things have to be true to skip the interactive login:
#   1. The cached context must be on the requested tenant.
#   2. That cached context must still be able to *acquire a token* silently.
# Condition 1 alone is not enough: a context can persist on disk (e.g. in
# ~/.Azure/AzureRmContext.json) with the right tenant ID but an expired or
# revoked refresh token. In that state Azure AD requires user interaction
# (typically driven by Conditional Access or MFA), so any data-plane call
# from inside the script will emit a warning like "Unable to acquire token
# for tenant ... User interaction is required" and silently return nothing -
# producing an empty inventory rather than failing loudly.
#
# Therefore the gate probes token acquisition for the requested tenant. Only
# if that probe succeeds do we skip the login.





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

        # Do not launch an interactive sign-in in a non-interactive/headless session
        # (e.g. an Azure DevOps agent, cron, or any redirected-stdin run):
        # Connect-AzAccount would block on a browser/device-code prompt that no one
        # can answer, hanging the run until it times out. Fail loud with actionable
        # guidance and a non-zero exit instead. -DeviceLogin is an explicit opt-in to
        # the device-code flow, so it is still honored. Uses the same interactivity
        # test as the PowerShell 7 / Az module install prompts above.
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

# ---------------------------------------------------------------------------
# Identity banner. Print WHO this run is authenticated as, before any work.
# Diagnostic aid: on AKS / workload identity the pod signs in as a service
# principal / managed identity (Connect-AzAccount -ServicePrincipal
# -FederatedToken), whereas an operator on a VM signs in as themselves. A run
# that returns 0 resources for an identity that "should" see them is almost
# always a DIFFERENT principal (Account.Type != 'User') than the interactive
# user - the Account.Type line below surfaces that at a glance.
#
# Native Az only: the tool depends solely on the Az PowerShell context
# (Search-AzGraph, Get-AzSubscription, Get-AzMetric, Get-UsageAggregates,
# Invoke-AzRestMethod are all Az module cmdlets) and never invokes the az CLI at
# runtime, so this banner reads the identity from Get-AzContext - no az shell-out
# and no az.cmd/cmd.exe quoting boundary.
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
    # When the sign-in is a service principal / workload identity (type != 'User' -
    # e.g. 'ClientAssertion' under an Azure DevOps AzurePowerShell@5 service
    # connection), Account.Id is the Application (client) id. Azure DevOps' log
    # scrubber masks that id as '***' in pipeline output because the service
    # connection registered it as a secret - that is ADO masking the LOG, not the
    # tool hiding it (Tenant / Active sub are not secrets, so they print normally).
    # Explain it inline, since this masked principal is exactly the identity that
    # must hold Reader (+ Cost Management / Monitoring Reader) for the run to see
    # resources, and it differs from an interactive VM login.
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

# Get all Azure subscriptions.
#
# Get-AzSubscription emits warnings (rather than throwing) when token
# acquisition for a tenant fails - typically due to CA/MFA gating. In that
# state the cmdlet returns no subscriptions, which would otherwise cause
# this wrapper to report "All subscriptions processed!" with an empty
# inventory. Capture warnings and treat zero-results-with-warnings as a
# loud failure instead of a silent one.
# -WarningVariable names the variable WITHOUT the sigil and populates it itself, so it
# is spelled to match the reads below. PowerShell variable names are case-insensitive,
# so the previous lowercase 'subWarnings' did populate $SubWarnings - but it read as a
# different, never-assigned variable, and a review pass duly flagged the block below as
# dead code on that basis. Matching the case removes the misreading.
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

# -Plan: assess-only "getting started" sizing. Reuses the just-computed eligible
# subscription set and this host's CPU/RAM to recommend either a single-machine
# run (with concrete parallelism flags) or a shard count + ready-to-paste per-node
# commands, then EXITS without inventorying anything. Placed after the
# eligible/disabled split (so it sizes the real workload) but before the shard
# filter / access gate / consumption gate, since it is advice only and makes no
# per-subscription calls.
if ($Plan)
{
    $PlanRec = Get-RecommendedParallelism
    # Honor an operator's EXPLICIT -ParallelStreams / -ConcurrencyLimit exactly as
    # the real run does (the auto-tune block later only fills the ones NOT passed),
    # so the plan sizes and prints the SAME parallelism the recommended command
    # would actually use rather than always the auto-tuned recommendation.
    # $PSBoundParameters is reliable here because the PS7 relaunch forwards only
    # bound params.
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
    if ($MetricsIntervalMinutes -gt 0) { $ExtraFlags += ('-MetricsIntervalMinutes {0}' -f $MetricsIntervalMinutes) }
    if ($PSBoundParameters.ContainsKey('MetricsLookbackDays')) { $ExtraFlags += ('-MetricsLookbackDays {0}' -f $MetricsLookbackDays) }
    if ($HeadRoom -gt 0) { $ExtraFlags += ('-HeadRoom {0}' -f $HeadRoom) }
    if ($UploadToBlobContainerUri) { $ExtraFlags += ('-UploadToBlobContainerUri {0}' -f (& $QuoteArg $UploadToBlobContainerUri)) }
    if ($StateBlobContainerUri) { $ExtraFlags += ('-StateBlobContainerUri {0}' -f (& $QuoteArg $StateBlobContainerUri)) }
    $ExtraStr = if ($ExtraFlags.Count -gt 0) { ' ' + ($ExtraFlags -join ' ') } else { '' }
    # InvariantCulture: a one-decimal double, and this console line is captured in
    # RunAllSubscriptions_transcript_*.txt, which the support bundle collects.
    $RamLabelPlan = if ($PlanRec.RamGB -gt 0) { '{0} GB RAM' -f $PlanRec.RamGB.ToString([cultureinfo]::InvariantCulture) } else { 'RAM undetected' }

    # Composition-aware sizing (preferred): count each subscription's projected
    # metric-query volume live via Resource Graph, then size shards from the
    # BUSIEST shard under the real runtime hash partition. Falls through to the
    # flat per-sub estimate below (byte-identical to the previous behaviour) when
    # metrics are skipped, the Graph query is unavailable/fails, or there are no
    # eligible subscriptions.
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
            # Rough, DELIBERATELY CONSERVATIVE per-metric-query costs (seconds).
            # Per-call is the slow path; the batchable types (VM/disk/storage/SQL/
            # VMSS/Cosmos) cost far less per query, so under -UseMetricsBatch only
            # their portion of the weight gets the batch cost - the rest stays
            # per-call. An operator-supplied -PlanPerQuerySeconds overrides both.
            # These are throttling-dependent estimates, not measurements (see the
            # note printed below), so the model rounds UP, never down.
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

# Horizontal scale-out: keep only THIS shard's slice of the eligible
# subscriptions. Applied here - after the Enabled/disabled split but BEFORE
# resume, the access gate, and the stream split - so every downstream phase
# (resume skip, up-front access probe, parallel streams) operates only on this
# shard's slice, not the whole tenant. Deterministic per-subscription-id hash
# (Select-ShardSubscriptions) makes the N shards disjoint and exhaustive with no
# cross-machine coordination. No-op when -ShardCount is 1 (returns the list
# unchanged), so a non-sharded run is byte-identical.
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

# Build the passwordless state-blob context now that we are authenticated and the
# tenant is enumerated (New-StateBlobContext uses -UseConnectedAccount, which
# needs a live Az context). $StateBlobArgs splats the { BlobContext; BlobContainer;
# BlobName } trio into the state read/write helpers; it is EMPTY when blob state
# is off, so those helpers take exactly the local-only path. The unified
# (non-stream) blob name is shard-namespaced under the container's _state/ area.
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
# Project the three views through the shared readers, passing the state already
# read above so the blob is fetched ONCE rather than once per projection.
#
# These used to be hand-rolled `@(if ($SeedState -and ...) { ... } else { @() })`
# expressions. The outer @(...) was load-bearing: without it a bare `else { @() }`
# captured from an if expression collapses to $null (PowerShell unrolls the empty
# array on assignment), which makes the first `$CompletedIds += $Sub.Id` do STRING
# concatenation instead of array append - silently corrupting the completed set
# into one mashed-together string. That regression has happened, and parse, review
# and the pure-helper unit tests all missed it.
#
# Get-CompletedSubscriptionIds and Get-FailedAttempts return @() by construction,
# so the collapse is now prevented by the callee rather than by remembering to
# wrap the call site. The @(...) is kept anyway as belt-and-braces, and a source
# guard in Tests/ResumeCycle.Tests.ps1 still asserts it is here.
#
# -Path and the blob args are passed even though a supplied -State makes them
# unused: if -State were ever dropped from these calls the readers would still
# resolve the same state instead of silently reading nothing. -Tenant IS consulted
# on this path - the readers re-assert the tenant guard on a supplied state.
#
# Get-FailedAttempts additionally strips a phantom null left by a version that
# serialised an empty list as `[ null ]`. The inline expression did not, so state
# written by that version put a null into the retry list; going through the reader
# self-heals it.
$CompletedIds = @(Get-CompletedSubscriptionIds -Path $ResumeStateFile -Tenant $TenantID @StateBlobArgs -State $SeedState)
$FailedAttempts = @(Get-FailedAttempts -Path $ResumeStateFile -Tenant $TenantID @StateBlobArgs -State $SeedState)

# Start-of-run subscription universe, for the end-of-run reconciliation of a
# MOVING target (another team creating/deleting subscriptions mid-run). Prefer a
# snapshot already recorded in the state - a resumed / rescheduled run MUST keep
# the ORIGINAL universe rather than re-capture an already-moved one - otherwise
# capture the CURRENT full-tenant enumeration ($AllSubscriptions is state-agnostic,
# taken before the Enabled/scope filters). $StateSaveArgs adds this snapshot to the
# blob trio so every Save-CompletedSubscriptionIds call persists it.
$StartSnapshot = Get-StartSnapshot -Path $ResumeStateFile -Tenant $TenantID @StateBlobArgs -State $SeedState
if ($null -eq $StartSnapshot)
{
    $StartSnapshot = [pscustomobject]@{ CapturedUtc = (Get-Date).ToString('o'); SubscriptionIds = @($AllSubscriptions.Id) }
}
$StateSaveArgs = @{ StartSnapshot = $StartSnapshot } + $StateBlobArgs

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
# Up-front subscription-COVERAGE gate. The access gate below proves the identity
# can READ the subscriptions it enumerated; this proves it enumerated them ALL.
# Get-AzSubscription returns ONLY subscriptions the identity holds a role on, so
# an identity granted access per-subscription (rather than at the tenant-root
# management group) SILENTLY MISSES the rest - a report that looks complete but
# is not, at scale potentially hundreds of subscriptions. This tool's purpose is
# to capture EVERY subscription, so a shortfall - or any inability to verify the
# true total - HARD-STOPS by default. The robust fix is Reader at the tenant-root
# management group (its GroupName/GroupId equals the TenantID), which inherits to
# every subscription AND makes the true count verifiable. -AllowPartialAccess is
# the conscious override (the SAME switch as the access gate): it downgrades the
# shortfall/unverifiable case to a loud warning and proceeds with whatever the
# identity can currently see.
#
# Compares the FULL-tenant enumeration ($AllSubscriptions - state-agnostic,
# BEFORE the Enabled filter and before any shard/scope split) against the true
# count under the tenant-root MG, so the verdict is identical on every shard
# machine and independent of -Resume / -ParallelStreams scoping (each shard still
# hashes over the whole tenant, so an incomplete enumeration would blind every
# shard).
Write-Host "Verifying full subscription coverage (tenant-root management group)..." -ForegroundColor Cyan
$Coverage = Get-TenantSubscriptionId -TenantId $TenantID
if ($null -eq $Coverage.Ids)
{
    $CoverageMsg = ("Could not verify full subscription coverage: the tenant-root management group (GroupName = tenant id) could not be read by this identity, so there is no way to confirm the {0} enumerated subscription(s) are ALL of them." -f $AllSubscriptions.Count)
    if ($AllowPartialAccess)
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
    # Compare the actual ID SETS, not just counts: the missed subscriptions are the
    # ones present under the tenant-root MG but NOT enumerable by this identity.
    # Using the id set (rather than a count delta) is immune to a transient count
    # mismatch (e.g. a subscription mid-deletion still listed in the MG tree) and
    # lets us NAME exactly which subscriptions would be silently missed. Compare
    # case-insensitively - subscription ids are GUIDs but normalise to be safe.
    $AccessibleIdSet = @{}
    foreach ($S in $AllSubscriptions) { $AccessibleIdSet[([string]$S.Id).ToLowerInvariant()] = $true }
    $MissedIds = @($Coverage.Ids | Where-Object { -not $AccessibleIdSet.ContainsKey(([string]$_).ToLowerInvariant()) })
    if ($MissedIds.Count -gt 0)
    {
        # Show the missed ids (capped) to make the gap actionable, mirroring how the
        # access gate below lists each inaccessible subscription id.
        $ShownMissed = @($MissedIds | Select-Object -First 10)
        $MoreNote = if ($MissedIds.Count -gt $ShownMissed.Count) { (' (+{0} more)' -f ($MissedIds.Count - $ShownMissed.Count)) } else { '' }
        $CoverageMsg = ("Subscription coverage shortfall: the tenant-root management group contains {0} subscription(s) but this identity can enumerate only {1} - {2} would be SILENTLY MISSED from the inventory." -f $Coverage.Ids.Count, $AllSubscriptions.Count, $MissedIds.Count)
        if ($AllowPartialAccess)
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
    if ($Subscriptions.Count -eq 0) { Write-Host "  (no subscription passed the Reader gate, so the data-phase columns could not be probed)" -ForegroundColor Yellow }
    Write-Host ""
    foreach ($Line in $Matrix.Lines) { Write-Host $Line -ForegroundColor $(if ($Line -match 'Denied') { 'Red' } else { 'Gray' }) }
    Write-Host ""
    if ($Matrix.Blocking)
    {
        Write-Host "Preflight result: at least one requested permission is DENIED. Fix the roles above (or pass the matching -Skip* switch), then run without -Preflight." -ForegroundColor Red
        Exit-Wrapper -Code 1
    }
    Write-Host "Preflight result: no denials. Nothing was collected; run again without -Preflight to start the inventory." -ForegroundColor Green
    Exit-Wrapper -Code 0
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
# Up-front blob-upload WRITE probe. The URI-format + Az.Storage checks earlier
# prove the request is well-formed, but NOT that this identity can actually write
# to the target container. Without this, a missing "Storage Blob Data Contributor"
# role is only discovered by the best-effort upload at the very END - after a
# potentially multi-hour run - stranding the whole output on an ephemeral node.
# So when an upload was requested, prove write+delete NOW (passwordless,
# -UseConnectedAccount, the SAME path the real upload uses) and fail fast on a
# genuine authorization denial. A transient/token error is NOT fatal here (mirrors
# the consumption gate above): it warns and continues, and the end-of-run upload
# and its warning still cover that recoverable class. The probe blob is namespaced
# + GUID-suffixed and removed best-effort after the write, so it never collides
# with a real shard artifact.
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
        # WRITE is the only capability the real upload uses, so it is the only
        # thing the probe verifies. A successful write = access confirmed; the
        # probe blob is then removed best-effort in the finally below. We do NOT
        # require delete to succeed - the tool never deletes blobs in normal
        # operation, so a delete-permission gap must not fail an otherwise-valid
        # write-only identity.
        $null = Set-AzStorageBlobContent -File $BlobProbeFile -Container $BlobProbeContainer -Blob $BlobProbeName -Context $BlobProbeContext -Force -ErrorAction Stop
        $BlobProbeWritten = $true
        Write-Host ("Blob-upload access confirmed (wrote a probe blob in {0}/{1})." -f $BlobProbeAccount, $BlobProbeContainer) -ForegroundColor Green
    }
    catch
    {
        $BlobProbeErr = $_.Exception.Message
        # Fatal up front on a DETERMINISTIC misconfiguration - an authorization
        # denial (missing "Storage Blob Data Contributor" -> 403) OR a container
        # that does not exist (mistyped container -> ContainerNotFound / 404). Both
        # would fail the real upload identically, so catch them now rather than
        # after a multi-hour run. A mistyped storage ACCOUNT surfaces as a name-
        # resolution error, which falls into the transient class below (warn and
        # continue) - the best-effort upload at the end will then surface it. Any
        # other transient token/throttling error is likewise NOT fatal here
        # (mirrors the consumption gate).
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

# API headroom: intentionally leave part of the shared Azure API throttle budget
# for other/production workloads by scaling down the metrics-collection
# concurrency (the run's heaviest ARM / Azure Monitor consumer). Applies on top of
# whatever ConcurrencyLimit was chosen (auto-tuned OR explicit), and because
# $ConcurrencyLimit is the single source forwarded to the inner script and to
# every parallel-stream worker, one reduction here propagates everywhere. No-op
# when -HeadRoom is 0 (the default).
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

# Background-job capability guard. The parallel-streams path below launches each
# stream with Start-Job (a child pwsh process). On a Windows host under a
# system-wide application-control policy (WDAC / AppLocker / __PSLockdownPolicy)
# the interactive session can be FullLanguage while the machine enforces
# ConstrainedLanguage system-wide; Start-Job then throws synchronously ("Cannot
# start job. The language mode for this session is incompatible with the
# system-wide language mode.") and NO stream process is ever created - the run
# ends having produced nothing to consolidate. Detect that up front and fall
# back to the sequential path (which never calls Start-Job) so a locked-down
# host still gets a full report, just single-threaded. Only probe when we would
# actually use parallelism (the auto-tuner can select >1 without the operator
# asking, so this also covers the out-of-the-box case).
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
    $AvailableServices = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Services') -Filter '*.ps1' -Recurse | ForEach-Object { $_.BaseName } | Sort-Object -Unique)
    $UnknownServices = @($Service | Where-Object { $_ -notin $AvailableServices })
    if ($UnknownServices.Count -gt 0)
    {
        Write-Host ("ERROR: -Service contains unknown collector name(s): [{0}]." -f ($UnknownServices -join ', ')) -ForegroundColor Red
        Write-Host ("Valid collector names: [{0}]" -f ($AvailableServices -join ', ')) -ForegroundColor Yellow
        Exit-Wrapper -Code 1
    }
    Write-Host ("Service filter active: collecting ONLY [{0}] across all in-scope subscriptions." -f ($Service -join ', ')) -ForegroundColor Cyan

    # -Service scopes the INVENTORY phase only; metrics and consumption still run
    # for the WHOLE subscription. ResourceInventory.ps1 warns about this too, but
    # suppresses it under -RunAllSubs because it is invoked once PER SUBSCRIPTION
    # and the identical warning would repeat N times. This is the once-up-front
    # copy, emitted here where the argument set is already known.
    #
    # Per-phase accurate for the same reason as the inner one: a run that already
    # passed a skip must not be told that phase still runs, nor be told to add a
    # switch it supplied. No -ResourceGroup tip here - this wrapper has no such
    # parameter, so suggesting it would point at a switch this entry point cannot
    # accept (the inner script offers it only on a standalone run).
    #
    # Advisory only. The skips are NOT enforced, because the recovery recipe that
    # re-collects for a later Merge-RecoveryData -RecoverMetrics/-RecoverConsumption
    # intentionally runs -Service WITHOUT them.
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

# Capture the in-scope (eligible, post-shard, post-access-gate) subscription
# COUNT now, before the first ResourceInventory.ps1 call, into a variable the
# inner script cannot clobber. WHY: the inner script sets
# $Global:Subscriptions = @(Get-AzSubscription | Where HomeTenantId -eq TenantID)
# (the full tenant list) on every invocation. When THIS wrapper is the entry
# script (pwsh -File ...), its top-level $Subscriptions IS the global, so the
# first sequential inner call (invoked in-process via &) overwrites our
# filtered/sharded list back to the whole tenant. The processing foreach is
# unaffected (it snapshots its collection at loop start), but the POST-loop
# summary/run-summary counts would otherwise read the clobbered global - e.g.
# a shard that processed 2 of 3 subs would wrongly report "Eligible/Processed: 3".
# (Parallel-streams mode runs the inner script in child processes, so the parent
# global is never touched there; capturing here is correct for both paths.)
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
            # Clear $LASTEXITCODE first. It is a SHARED, STICKY variable: the inner
            # script is invoked with `&` in this same runspace, and a completion
            # path that does not call `exit` leaves whatever the PREVIOUS
            # subscription set still in place. Without this reset, one subscription
            # exiting non-zero makes every LATER subscription in the loop look like
            # it exited non-zero too - they get reported as failures even though
            # their reports were written correctly. Resetting per iteration means
            # the check below reflects only the invocation that just returned.
            #
            # $Global:ZipOutputFile is sticky in exactly the same way, and must be
            # cleared for the same reason: the inner script has early gates that
            # leave with a BARE `Exit` (exit code 0) before it ever computes an
            # archive path, so without this reset such a subscription would be
            # recorded as successful carrying the PREVIOUS subscription's archive
            # path - and would then pass output verification "by exact path"
            # against a file that belongs to a different subscription. Cleared to
            # $null so the row is classed unverifiable rather than falsely verified.
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
                if (-not [string]::IsNullOrWhiteSpace($DiagRoot) -and (Test-Path $DiagRoot))
                {
                    $RootDrive = (Get-Item $DiagRoot).PSDrive
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
                if (-not [string]::IsNullOrWhiteSpace($FailRoot) -and -not (Test-Path $FailRoot))
                {
                    try { New-Item -ItemType Directory -Path $FailRoot -Force -ErrorAction Stop | Out-Null }
                    catch { Write-Host ("WARNING: could not create {0} for the failures log: {1}" -f $FailRoot, $_.Exception.Message) -ForegroundColor Yellow }
                }
                $DiagFile = Join-Path $FailRoot ("RunAllSubscriptions_failures_{0}_{1}.log" -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss-fff'), [guid]::NewGuid().ToString().Substring(0, 4))
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
            Save-CompletedSubscriptionIds -Path $ResumeStateFile -Tenant $TenantID -Ids $CompletedIds -FailedAttempts $FailedAttempts @StateSaveArgs
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
                try { $DiagLines | Out-File -FilePath $DiagFile -Append -Encoding utf8 }
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
                if ($UseMetricsBatch) { $WorkerArgs.UseMetricsBatch = $true }
                if ($IncludeStorageMetrics) { $WorkerArgs.IncludeStorageMetrics = $true }
                if ($SkipDiskMetrics) { $WorkerArgs.SkipDiskMetrics = $true }
                if ($MetricsIntervalMinutes -gt 0) { $WorkerArgs.MetricsIntervalMinutes = $MetricsIntervalMinutes }
                # NOT a key in the $WorkerArgs literal above: this form is what
                # Tests/ParamForwardingParity.Tests.ps1 harvests, and widening the
                # aligned literal would re-indent ConcurrencyLimit and break that
                # test's headroom-ordering probe.
                if ($PSBoundParameters.ContainsKey('MetricsLookbackDays')) { $WorkerArgs.MetricsLookbackDays = $MetricsLookbackDays }
                if ($Service.Count -gt 0) { $WorkerArgs.Service = $Service }
                # -Debug must be forwarded EXPLICITLY. Background jobs do not inherit
                # the parent's preference variables, so without this line the flag is
                # accepted and silently dropped for every stream - which is exactly
                # what happened: the sequential path forwarded it (see the matching
                # line further down) while -ParallelStreams produced no inner debug
                # output at all.
                #
                # [bool] rather than ContainsKey alone so an explicit -Debug:$false is
                # honoured instead of being inverted into $true.
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
            # Match the local cleanup for the per-stream BLOBS folded in above:
            # once their progress is merged into the unified state (which IS
            # preserved), remove the transient per-stream blobs so they do not
            # accumulate under _state/ or resurrect stale FailedAttempts on a later
            # run with a different stream count. Best-effort; the UNIFIED state
            # blob is intentionally NOT deleted. $StreamBlobNames is in scope
            # whenever $StateBlobParts is non-null (both set in the merge block).
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

# === Moving-target subscription reconciliation ==============================
#
# Another team can create/delete subscriptions DURING a long run, so the single
# start-of-run Get-AzSubscription is stale by now. Re-enumerate and classify the
# delta against the ORIGINAL start snapshot ($StartSnapshot, preserved across
# resume): subs deleted mid-run (Vanished) must NOT be reported as failures, and
# subs created mid-run (New) would otherwise be SILENTLY MISSING from the report.
# This is REPORT-ONLY and does not change the exit code - a moving tenant is
# expected here, not a run fault. Best-effort: a re-enumeration blip must not fail
# an otherwise-complete run. No-op unless a start snapshot was recorded.
$StartIds = if ($StartSnapshot -and $StartSnapshot.SubscriptionIds) { @($StartSnapshot.SubscriptionIds) } else { @() }
if ($StartIds.Count -gt 0)
{
    try
    {
        $EndSubs = @(Get-AzSubscription -TenantId $TenantID -WarningAction SilentlyContinue)
        $EndIds = @($EndSubs | ForEach-Object { $_.Id })
        $Delta = Get-SubscriptionDelta -StartIds $StartIds -EndIds $EndIds -CompletedIds $CompletedIds
        # Scope Vanished + Incomplete to the subscriptions THIS run was responsible
        # for (the eligible, post-Enabled, post-shard, post-resume slice in
        # $Subscriptions). The start snapshot is the FULL tenant so New can still
        # flag subs that NO shard will ever process, but "deleted that I owed" and
        # "I did not finish" are only meaningful for this run's own slice -
        # otherwise a default run would flag every Disabled sub, and a sharded run
        # every OTHER shard's subs, as not-completed. New stays tenant-level.
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

# === Per-subscription output verification (hard-stop) ========================
#
# Hard-fail with exit code 2 (distinct from auth/runtime exit code 1) if any
# subscription that ran to completion this invocation did not leave a report
# archive on disk.
#
# This checks IDENTITY first and count second. Every successful sub records the
# exact archive path the inner script wrote (its $Global:ZipOutputFile), so a
# missing report is reported BY SUBSCRIPTION - which is the thing the operator
# actually needs. The count comparison is kept as a second, independent test: it
# catches a sub whose recorded path is absent (a stream summary from an older
# build) and an archive that was replaced rather than simply deleted.
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

    # A row with a recorded path that is no longer a usable archive on disk is a
    # NAMED missing report. "Usable" deliberately means present AND non-empty, the
    # same standard ResourceInventory.ps1 applies to its own archive before it
    # reports success: a 0-byte file is not a report, and a truncating quarantine
    # or an eviction mid-flush leaves exactly that. Testing only for presence
    # would let the two halves disagree - the inner script rejecting an archive
    # the wrapper would happily consolidate.
    #
    # A row with no recorded path cannot be checked this way; it is counted as
    # unverifiable rather than missing, so an older stream summary can never
    # produce a false accusation against a specific subscription - the count
    # comparison below still covers it.
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
                # The uncompressed report files are the salvage path, so name the
                # folder explicitly rather than making the operator derive it.
                #
                # [IO.Path]::GetDirectoryName rather than Split-Path: Split-Path's
                # -Parent switch only pairs with -Path, never -LiteralPath (they are
                # different parameter sets), so there is no literal-path form of it
                # to reach for. The .NET call is literal by construction, which takes
                # wildcard interpretation off the table entirely for a path that can
                # contain '[' or ']'. Verified equivalent to Split-Path -Parent on
                # both Windows and macOS for plain, bracketed and spaced paths.
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
    # Report both numbers separately, and state how many subs were checked by
    # path versus only by count. The previous message used {0} twice against a
    # single argument, so it echoed the found count as if it were also the
    # expected count and could never have shown a discrepancy. Naming the
    # per-path total matters for the same reason: "no missing archives" is a
    # much weaker statement when nothing could be checked individually, and the
    # message must not read like a full pass in that case.
    $VerifiedByPathCount = $ExpectedZipCount - $UnverifiableSubs.Count
    Write-Host ("Per-subscription output verification: OK ({0} archive(s) on disk for {1} successful sub(s); {2} verified by exact path)" -f $ActualZipCount, $ExpectedZipCount, $VerifiedByPathCount) -ForegroundColor Green
    if ($UnverifiableSubs.Count -gt 0)
    {
        Write-Host ("  Note: {0} sub(s) recorded no archive path and were covered by the count check only." -f $UnverifiableSubs.Count) -ForegroundColor Yellow
    }
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
        # -LiteralPath (as Reveal.ps1 uses) so a report folder/zip name containing
        # [ ] is not treated as a wildcard glob and silently dropped.
        Compress-Archive -LiteralPath $SubZips.FullName -DestinationPath $OuterZipFile -Force
        # Deliberately NOT labelled "Reporting Data File" - the inner
        # per-subscription script prints that same label once PER SUBSCRIPTION for
        # its own zip, so on a large tenant the operator saw the identical label N+1
        # times naming N+1 different files and could not tell which one to send.
        # This label names the bundle unambiguously. It is "created", not finished:
        # stages 2 and 3 further below still fold in RunSummary.log, MainSummary.html,
        # the VM placement CSV and the per-subscription HTML. The "What to send"
        # block after stage 3 is what declares it the deliverable.
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

# ---------------------------------------------------------------------------
# Tenant-wide VM placement CSV, written next to MainSummary.
#
# Each per-subscription run writes a VMPlacementPart_*.csv into InventoryRoot
# (see the placement block in ResourceInventory.ps1). Concatenating them here -
# rather than having every run append to one shared file - is what keeps parallel
# streams from interleaving writes into a single CSV.
#
# Deliberately NOT an Inventory_*.json change: the zone identity this file exists
# to carry would otherwise have to be added to the VM collector's output object,
# which is the server-ingestion contract. See Extension/VMPlacement.ps1.
#
# Only parts from THIS run are consumed. $RunStartTime is the same filter the main
# summary uses, so a crashed previous run's leftover parts cannot be folded in.
#
# The file is TIMESTAMPED, matching its sibling MainSummary_<stamp>.html in this
# same directory, and that is load-bearing rather than cosmetic. A fixed
# VMPlacement.csv would be overwritten in place, and on a -Resume run that is
# actively misleading: the subscriptions being skipped write no new part (and
# their parts from the earlier attempt were already consumed and deleted), so a
# fixed name would silently replace a COMPLETE tenant-wide file with one covering
# only the subscriptions this invocation happened to process. Timestamping makes
# each run's coverage its own artifact, and the count reported below tells the
# operator how many subscriptions actually contributed.
#
# Best-effort by design: the per-subscription reports and the consolidated zip are
# already written by this point, so any failure here is a warning, never fatal.
#
# Nil-initialised so stage 3 below always has a defined variable to test. The
# assignment lives inside the row-count branch, and this block is best-effort, so
# a run with no VM rows - or a throw before the export - otherwise leaves it
# never assigned. Defensive rather than required (this script sets no StrictMode,
# so an unassigned read would already yield $null); it makes the contract with
# stage 3 explicit instead of relying on that default.
$VmPlacementFile = $null
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
# Report the record count UNCONDITIONALLY when consumption was requested. The
# previous '-gt 0 -or failures' condition printed NOTHING in the one case this
# block exists to make loud: zero records AND zero reported failures. That is
# the silent-failure signature - the billing API answered successfully but
# returned no rows - and it is exactly what ships an empty Consumption CSV with
# a clean-looking summary. Zero is only legitimate for a genuinely idle
# subscription, so state it in yellow and explain the likely causes rather than
# staying quiet.
if (-not $SkipConsumption)
{
    $ConsumptionRecordColor = if ($ConsumptionRecords -gt 0) { 'Green' } else { 'Yellow' }
    Write-Host ("Consumption Records:     {0:N0} record(s) collected" -f $ConsumptionRecords) -ForegroundColor $ConsumptionRecordColor
}
elseif ($ConsumptionRecords -gt 0 -or $ConsumptionFailures.Count -gt 0)
{
    Write-Host ("Consumption Records:     {0:N0} record(s) collected" -f $ConsumptionRecords) -ForegroundColor Green
}

# Consumption was requested, the phase reported no per-subscription failure, and
# yet not a single usage record came back. The up-front gate cannot catch this:
# it classifies the billing probe's EXCEPTION text, and an empty-but-successful
# response raises no exception (see Test-ConsumptionAccess). Call it out here
# with the causes that actually produce it, because the operator otherwise has
# no signal at all that the billing data they asked for is missing.
# Gate CLOSELY MIRRORS the one in Get-RunSummaryLogContent's Health block so the
# console and the SHIPPED RunSummary.log do not disagree about whether to warn. Both
# require that at least one subscription was ATTEMPTED and that at least one of those
# actually COMPLETED - the second half is the part that is easy to lose. Here it is
# @($SubResourceCounts).Count -gt 0, which has three producers: appended per
# subscription on the inner script's successful return in the sequential path, the same
# per-subscription append in the inline path taken when -ParallelStreams collapses to a
# single stream, and in MULTI-STREAM mode rebuilt from each stream's summary JSON
# ResourceCounts. The builder cannot see that list, so it APPROXIMATES the same
# condition with ($Processed - $Failed.Count) -gt 0.
#
# The two halves are NOT interchangeable: $Processed is eligible-minus-skipped, so
# it still counts subscriptions that were attempted and then failed. Gating on it
# alone would warn about billing causes on a run whose zero record count is fully
# explained by those failures.
#
# THIS gate is never the looser of the two - at least as strict, and in most modes
# exactly equal - so the mirror is close but not guaranteed exact. Where it diverges: a
# stream whose summary file is missing or unparsable adds ONE $FailedSubscriptions entry
# for the K subscriptions it owned, so for K > 1 the builder's arithmetic can still open
# while this gate correctly stays quiet. That residual gap is recorded at the builder
# too; closing it needs a real completed count passed into the builder.
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

# --- Run summary (ALWAYS produced) + fold run-level extras into the bundle ---
# The run summary (parameters + sub tally + health) is the ONE artefact we must
# never lose: it is how a shared bundle is triaged, and a customer has already
# received a zip that was missing it. So its generation and on-disk write are
# decoupled from both the outer zip and the best-effort MainSummary/HTML bundling
# below - a failure in any later step can no longer suppress it.
#
# THE EXCEPTION THAT MATTERS, stated because the guarantee is otherwise easy to
# over-read: the per-subscription zip-verification hard stop earlier in this script
# calls Exit-Wrapper -Code 2 and returns BEFORE this block, so that path produces no
# RunSummary.log at all. Of this script's many Exit-Wrapper and bare-exit sites it is
# the only one that PRE-EMPTS this block after subscriptions have been inventoried - the
# earlier aborts (argument validation, the access and coverage gates, -Plan, an empty
# shard) emit no summary either, but at that point there is genuinely nothing to
# summarise, and the final exit sits downstream of this block. Making
# the Code 2 path emit one would be a real improvement - a run declared broken is
# exactly when triage matters - but it needs the health aggregation this block depends
# on, including the parallel-mode $SkippedCount derivation and $BundleVer, to be
# available that much earlier, so it is a separate change rather than a comment.
#
# Three independent stages, each in its own try/catch:
#   1. Generate RunSummary content and write it to disk (always).
#   2. Fold RunSummary.log into the consolidated zip as its OWN operation, then
#      verify it actually persisted (a silent Compress-Archive -Update failure
#      previously dropped it); the on-disk copy from stage 1 is the fallback.
#   3. Fold the unified MainSummary.html, the tenant-wide VMPlacement.csv, and a
#      copy of each per-subscription HTML (drill-down targets) into the zip. Only
#      additive members and NO loose *.json, so the ingestion contract (inner-zip
#      *.json members) is unchanged and nothing is double-ingested. VMPlacement.csv
#      is the one sanctioned loose data file at the outer root - see the NOTE on
#      bundle membership at the stage 3 block itself.
# Then: report the deliverable, with every claim derived from one read of the
# finished archive rather than from what was staged.

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

# --- Stage 1: generate RunSummary + durable on-disk copy (unconditional) -----
# Obfuscated runs emit counts only (the wrapper holds no per-sub obfuscation
# dictionary); default runs include per-sub detail. The on-disk copy lives next
# to the report(s) in $InventoryRoot so the operator always has it even when no
# consolidated zip was produced (e.g. a resume run that regenerated nothing) or
# when the zip fold in stage 2 fails.
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
    $RunSummaryLines | Out-File -FilePath $RunSummaryLocalFile -Encoding utf8
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
        Compress-Archive -Path (Join-Path $RunSummaryStage 'RunSummary.log') -DestinationPath $OuterZipFile -Update

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

# --- Stage 3: fold MainSummary.html + VMPlacement.csv + per-sub HTML in ------
# Best-effort: any failure here is a warning and can no longer take the run
# summary (already folded in stage 2) down with it.
#
# The bundle is the ONE artifact an operator sends. Anything tenant-wide that a
# consumer needs therefore has to be INSIDE it: a deliverable left loose in
# InventoryRoot is a second thing to remember, and the observed operator response
# to "collect several files" is to zip the whole InventoryReports folder - which
# ships the obfuscation dictionary (the de-obfuscation key) and the transcripts.
# That is why the tenant-wide VMPlacement CSV is folded in here rather than being
# left beside MainSummary_<stamp>.html on disk.
#
# NOTE on bundle membership: VMPlacement.csv is the first loose DATA file at this
# outer root - previously the root held only per-subscription .zip archives plus
# presentation/summary files (MainSummary.html, RunSummary.log). The per-subscription
# ingestible members (Inventory_*.json, Metrics_*.json, Consumption_*.csv) all live
# INSIDE the inner zips, and the shareable Diagnostics log is deliberately a .log so
# it is not table-ingested. A consumer that discovers ingestible files by extension
# at the outer root would therefore see this CSV where it previously saw none.
#
# CONFIRMED by the repository owner: the root placement is INTENTIONAL and is the
# point of the file. It is a capacity-planning input, read directly by a human or a
# planner to size how many nodes are needed per availability zone, so it must be
# reachable without unpacking an inner per-subscription archive first. It is
# deliberately NOT part of the Inventory_*.json server-ingestion contract - keeping
# the zone identity out of the VM collector's output object is exactly why this file
# exists as a separate CSV. Do not move it inside the inner zips and do not add its
# columns to Inventory_*.json.
# The fixed root name is also why a multi-shard merge must extract each shard into
# its OWN folder: all shards use this same name, so a shared destination overwrites
# every copy but the last. See the merge sequence in docs/horizontal-sharding.md.
# Its obfuscation posture is safe either way: Extension/VMPlacement.ps1 sources every
# identifier column from $Global:SmaResources, which CreateResourceJobs has already
# obfuscated, so an -Obfuscate run's CSV carries tokens and no new identifier class.
# Leaf names staged for the fold, captured for the post-fold reconciliation below.
# Declared out here so it survives a throw inside the try.
$StagedLeafNames = @()
if ($null -ne $OuterZipFile -and (Test-Path -LiteralPath $OuterZipFile))
{
    $BundleStage = $null
    try
    {
        $BundleStage = Join-Path $InventoryRoot ('.rda-bundle-{0}' -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
        New-Item -ItemType Directory -Path $BundleStage -Force | Out-Null

        # 1. Unified MainSummary.html at the bundle root (renamed from the
        #    timestamped file; its links are relative to sibling folders, so
        #    renaming the summary itself does not break them). The drill-down
        #    link folders are then renamed from ResourcesReport<stamp>/ to
        #    HTML<stamp>/ (see step 2) - these bundle folders carry ONLY the
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

        # 2. A copy of each per-subscription HTML at HTML<stamp>/ (the folder
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

        # 3. The tenant-wide VM placement CSV at the bundle root, de-timestamped to
        #    VMPlacement.csv for the same reason MainSummary_<stamp>.html becomes
        #    MainSummary.html: inside the bundle the run is already identified by
        #    the archive's own name, so a consumer can bind to a fixed member name
        #    instead of globbing. The on-disk copy KEEPS its timestamp - that is
        #    load-bearing for -Resume coverage (see the aggregation block above)
        #    and is deliberately not changed here.
        #    Guarded on both the variable and the file: a run with no VM rows never
        #    assigns it, and the aggregation block is best-effort so it can fail
        #    before the export.
        if (-not [string]::IsNullOrEmpty($VmPlacementFile) -and (Test-Path -LiteralPath $VmPlacementFile))
        {
            Copy-Item -LiteralPath $VmPlacementFile -Destination (Join-Path $BundleStage 'VMPlacement.csv') -Force
        }

        # Fold the staged extras into the existing outer zip (additive; the
        # inner per-sub zips already inside it are preserved by -Update).
        $StageItems = @(Get-ChildItem -Path $BundleStage -Force -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
        if ($StageItems.Count -gt 0)
        {
            # -LiteralPath, matching the outer compress: $BundleStage derives from
            # $InventoryRoot, and a '[' or ']' anywhere in that path would otherwise
            # be read as a wildcard and silently fold nothing.
            Compress-Archive -LiteralPath $StageItems -DestinationPath $OuterZipFile -Update

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

# --- The deliverable instruction --------------------------------------------
# Emitted HERE, after stages 2 and 3, because this is the first point at which
# the bundle's membership is final. The run summary above names the path; this
# states what to DO with it.
#
# Why this exists at all: the previous output named the bundle ("Consolidated
# Report: <path>") but never said to send it, while the inner per-subscription
# script printed "safe to share" once PER SUBSCRIPTION about its own zip. On a
# large tenant the operator saw that sharing language many times, always attached
# to a per-subscription file, and never once attached to the bundle. The observed
# result is operators zipping the whole InventoryReports folder instead - which
# ships the obfuscation dictionary (the key that reverses the masking) and the
# transcripts, defeating the point of -Obfuscate. So: name the single file, and
# state the negative explicitly.
#
# EVERY factual claim below is derived from ONE read of the finished archive.
# Earlier revisions of this block hand-wrote the contents in prose and were wrong
# three separate ways (they named the placement CSV on a tenant with no VMs, named
# the summary HTML when its best-effort build had failed, and said "every
# subscription" on a sharded or resumed run). Enumerating the real members removes
# that whole class rather than correcting each sentence.
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

# Per-node blob upload. When -UploadToBlobContainerUri is set, ship THIS
# machine's finalized consolidated zip to the shared blob container so an
# operator running many shards does not have to collect output from each node by
# hand. Placed AFTER the bundle is finalized (MainSummary folded in) so the
# uploaded artifact is complete. Passwordless: uses the current signed-in
# identity (Connect-AzAccount / AKS workload identity) via Azure AD
# (-UseConnectedAccount), requiring "Storage Blob Data Contributor" on the
# target - no account key or SAS. Best-effort by design: a failure warns loudly
# but does NOT fail the run, because the zip is already safe on local disk and
# can be retrieved manually; making the pod error would also trigger Job retries
# of the whole (already-successful) shard.
if ($UploadToBlobContainerUri -and $null -ne $OuterZipFile -and (Test-Path -LiteralPath $OuterZipFile))
{
    try
    {
        # Expect https://<account>.blob.core.windows.net/<container>[/<prefix>].
        # Parsed by the shared helper rather than a hand-copy of it. Three copies of
        # that parse existed in this repo and were character-for-character identical,
        # which is exactly how they would have drifted apart on the next change to any
        # one of them; all three now call the helper. A fourth copy remains in
        # deploy/Test-NodeReadiness.ps1, left deliberately because that script is a
        # self-contained in-pod preflight that dot-sources nothing.
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

        # Decouple compute from storage for the obfuscation dictionaries too.
        # Each subscription's ObfuscationDictionary_*.json is a LOCAL file that is
        # deliberately kept OUT of the shared report zip (it is the de-obfuscation
        # key - it maps every obfuscated token back to the real value). On
        # ephemeral compute (an AKS pod's emptyDir) that local file dies with the
        # node, taking with it the ONLY record of this run's token mapping - and
        # thus the only thing that lets a later scoped/recovery run reproduce the
        # SAME tokens via -ObfuscationDictionary seeding. Since a blob target is
        # already configured, mirror the dictionaries to that SAME container - as
        # their OWN objects under a _dictionaries/ prefix, still NOT inside the zip
        # - exactly as the resume state and support-log bundle (which also carry
        # real identifiers) already do. That makes this container an operator-
        # PRIVATE artefact store: it must never be handed to a report consumer
        # as-is. Its OWN try/catch + best-effort so a dictionary-upload problem can
        # never mask or fail the (already-successful) report upload above. Only
        # obfuscated runs produce dictionaries; scoped to THIS run by write time so
        # a shared InventoryRoot does not resurface a prior run's dictionaries.
        try
        {
            $DictionaryFiles = @(Get-ChildItem -Path $InventoryRoot -Recurse -Filter 'ObfuscationDictionary_*.json' -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $RunStartTime })
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

# Even on a run that completed and produced a report, collect the local support
# logs when ANY per-phase failure occurred (failed subscriptions, collector
# failures, or metrics/consumption auth-skips). The consolidated report already
# carries RunSummary.log (failure counts) + the per-sub scrubbed diagnostics;
# this additionally bundles the LOCAL detail logs (wrapper transcript + per-sub
# DebugLog / ErrorLog) that are never in the shared report zip, so the operator
# has one ready-to-send artefact if support needs the detail. Collected AFTER
# Stop-Transcript so the finalized transcript is captured, and scoped to this
# run via $RunStartTime. Failure exits are handled separately by Exit-Wrapper.
$RunHadFailures = ($FailedSubscriptions.Count -gt 0) -or (@($Global:CollectorFailures).Count -gt 0) -or (@($Global:MetricsFailedSubs).Count -gt 0) -or (@($Global:ConsumptionFailedSubs).Count -gt 0)
# Collect the local support logs when the run had any per-phase failure, and ALSO
# whenever a blob upload target is configured - in the latter case the bundle is
# uploaded to blob so the logs are retrievable without pod/node access. This is
# what surfaces an otherwise-invisible "returned 0 resources (no Reader)" run: it
# is a clean success (no failure counters), so without this an operator running in
# AKS would get only an empty report zip and no way to see the per-sub warnings.
if ($RunHadFailures -or -not [string]::IsNullOrWhiteSpace($UploadToBlobContainerUri))
{
    Invoke-RdaSupportLogCollection -InventoryRoot $InventoryRoot -SinceTime $RunStartTime -ContainerUri $UploadToBlobContainerUri -ShardIndex $ShardIndex -ShardCount $ShardCount
}


$AuthSkipped = $AuthSkippedPhases.Count -gt 0
$CollectorsFailed = @($Global:CollectorFailures).Count -gt 0
$WrapperExitCode = Get-WrapperExitCode -AuthSkipped $AuthSkipped -CollectorsFailed $CollectorsFailed

# A subscription whose report archive could not be written is a MISSING REPORT,
# which is what exit code 2 already means (the per-subscription output gap). The
# verification gate cannot catch this case on its own: the failed sub is correctly
# excluded from the expected archive count, so the counts agree and the gate stays
# silent.
#
# Code 2 takes PRECEDENCE over 3/4/5 rather than deferring to them. Those codes
# all mean "the report was produced but is incomplete in a diagnosable way" (see
# the exit-code table in README.md), whereas this means a subscription's report is
# NOT IN THE BUNDLE AT ALL - the strictly worse outcome, and the one a consumer
# must not miss. Letting an auth skip mask it would be the same "sweep it under
# the rug" failure the 3-vs-4 split exists to prevent. The banner above prints
# every condition independently, so nothing is hidden from a human either way.
if (@($ArchiveWriteFailures).Count -gt 0)
{
    $WrapperExitCode = 2
}
# Always exit with the computed wrapper code (0 on a fully clean run). An explicit
# exit makes $LASTEXITCODE deterministic for callers and CI. In particular the
# Azure DevOps AzurePowerShell@5 task runs this script via a dot-sourced wrapper
# where a bare fall-through would leave $LASTEXITCODE at the last native command's
# value - so a clean run could look non-zero, and a hard-stop's own exit code does
# not otherwise reach the task. Exiting unconditionally lets the pipeline check
# $LASTEXITCODE and fail loudly on any non-zero (access gate, auth skip, collector
# failures) instead of showing green.
exit $WrapperExitCode

