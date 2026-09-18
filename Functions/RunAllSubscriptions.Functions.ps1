#Requires -Version 7.0
# Shared helper library for the multi-subscription wrappers, dot-sourced by both
# the parent and stream-worker scripts. Definitions only (no top-level code); caller-scope vars ($WrapperTranscriptStarted, $Tag, $TenantID, $StreamId) resolve at CALL time.

# ---- Wrapper / shared -------------------------------------------------------
# Best-effort collection of this run's LOCAL support/diagnostic logs into one zip; fully ISOLATED (a failure is swallowed) so it can never disrupt the caller (an exit path or normal end-of-run).
function Invoke-RdaSupportLogCollection
{
    param(
        [string]$InventoryRoot,
        [datetime]$SinceTime,
        # When set, ALSO upload the support-log bundle to this blob container (passwordless, -UseConnectedAccount).
        # Best-effort; ShardIndex/ShardCount keep the blob name unique so concurrent shards don't overwrite each other.
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
                    # Shared parser (see Split-BlobContainerUri, later in this file -
                    # PowerShell resolves the call at invocation time, so definition
                    # order does not matter once the file is dot-sourced).
                    $LogParts = Split-BlobContainerUri -Uri $ContainerUri
                    $LogAccount = $LogParts.Account
                    $LogContainer = $LogParts.Container
                    $LogPrefix = $LogParts.Prefix
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

    # Collect this run's LOCAL support logs into one zip (and upload when configured) so a hard-stopped run still leaves a single support artefact.
    # Guard fires on any failure exit OR whenever upload is enabled; vars come from caller scope and the helper never changes the exit code.
    if ($Code -ne 0 -or -not [string]::IsNullOrWhiteSpace($UploadToBlobContainerUri))
    {
        Invoke-RdaSupportLogCollection -InventoryRoot $InventoryRoot -SinceTime $RunStartTime -ContainerUri $UploadToBlobContainerUri -ShardIndex $ShardIndex -ShardCount $ShardCount
    }

    exit $Code
}

# Auto-tune parallelism to the host: recommend { VCpu, RamGB, Streams, Concurrency } from CPU count and physical RAM.
# Streams = 1 per ~2 vCPU, capped at 6 (tenant RG ceiling) and by RAM (~1.5GB/stream, ~2GB reserved); concurrency = 2x vCPU bounded [6,16]. Caller applies these only where the operator passed nothing.
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
            $MemLine = Select-String -LiteralPath '/proc/meminfo' -Pattern '^MemTotal:\s+(\d+)\s+kB' -ErrorAction Stop | Select-Object -First 1
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

# Reduce metrics concurrency by the requested API-headroom %, leaving throttle budget for other workloads. PURE (unit-tested).
# Scale concurrency ONLY, not streams, so the reduction stays linear (scaling both would compound to ~64%); HeadRoomPercent clamped [0,90], result floored to >=1 (0 would stall the runspace pool).
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

# Probe whether Start-Job actually works in this session; $true when jobs are usable, $false otherwise (caller then falls back to the sequential path).
# WHY a live probe not a language-mode check: under system-wide WDAC/AppLocker ConstrainedLanguage, Start-Job throws synchronously and the parallel run silently yields an empty report. Probe job is always removed.
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

# Disable Windows conhost "QuickEdit Mode" for this session (best-effort). WHY: its mark/select mode SUSPENDS the process on the next console write, which looks like a random hang during a long run.
# Windows- and interactive-only (no-ops elsewhere and when I/O is redirected); any failure is swallowed so tweaking the console never breaks a run.
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

# Classify a 0-resource subscription as 'NoAccess' / 'Empty' / 'Unknown'. Resource Graph can't tell them apart (it returns empty, not 403, when a role is missing).
# One access-scoped ARM RG GET via Invoke-AzRestMethod (native Az, NOT the az CLI - portability, no per-OS shell quoting): 200=Empty, 401/403=NoAccess, 404=hidden sub.
function Get-SubscriptionAccessState
{
    param([Parameter(Mandatory = $true)][string]$SubscriptionId)

    # Access-scoped ARM RG GET via native Az (Invoke-AzRestMethod). It returns .StatusCode for HTTP responses including 4xx, and throws ONLY for client-side failures (no token, network/DNS).
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

# Up-front control-plane access probe for a set of subs via Get-SubscriptionAccessState; returns one { Id, Name, State } per sub (Empty/NoAccess/Unknown).
# Retries transient 'Unknown' with backoff so a throttle/network blip is not mistaken for a permission gap. Side-effecting; the proceed/skip decision lives in the pure Resolve-AccessPreflight.
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

# Decide from the access-probe results whether the run may proceed. PURE (unit-testable). Returns { Inaccessible, InaccessibleIds, ShouldBlock }.
# Both 'NoAccess' AND 'Unknown' count as inaccessible - 'Unknown' is treated as BLOCKING so a genuine access/throttle problem is never silently skipped. ShouldBlock unless -AllowPartialAccess.
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
# Recursively collect subscription IDs (a subscription child's .Name is its GUID) from a Get-AzManagementGroup -Expand -Recurse tree. WHY the MG tree: Get-AzSubscription returns ONLY subs the identity has a role on, so it silently misses per-sub grants; returns the ID SET (not a count) so the caller can NAME what's missed. PURE.
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

# Fetch the TRUE subscription-ID set under the tenant-root MG (GroupName == tenant id), independent of Get-AzSubscription. Side-effecting; traversal is the pure Get-RdaMgSubscriptionId.
# Returns { Ids, Detail }: Ids=$null signals "unverifiable" (no MG read / cmdlet absent / empty tree) - distinct from a real set - and Detail carries the reason for the operator.
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
# Deterministically map a subscription to one of $ShardCount shards purely from its OWN id, so N machines' slices are DISJOINT and EXHAUSTIVE with no coordination (a positional split would misalign if two machines saw different sub lists).
# Hash: SHA-256 of the lowercased id, first 4 bytes big-endian mod ShardCount - stable across process/OS/arch (unlike the per-process-randomized GetHashCode). ShardCount<=1 returns 0.
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

# Assess-only -Plan capacity planner: from eligible sub COUNT, host $Streams and a per-sub time estimate, decide if one machine finishes under the wall-time ceiling, else the fewest shards that do. PURE (unit-tested).
# Model: wall-time ~= ceil(SubscriptionCount / Streams) * PerSubSeconds; estimates only. Returns { Mode, ShardCount, Streams, PerSubSeconds, EstimatedSeconds, PerMachineSubscriptions, EstimatedPerMachineSeconds, MaxSingleMachineHours }.
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

# Render the -Plan shard-directive lines. PURE. Emits a machine-readable 'PLAN_SHARDCOUNT=<n>' token (a stable grep target - the prose caps its command list at 10) in every case.
# When sharding (n>1), also emits the explicit 0..n-1 range directive: any -ShardIndex not run is silently omitted from the combined result (shards are disjoint, no coordinator). Returns [string[]].
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

# Authoritative per-resource-type metric-query weight table for -Plan sizing (Weight = metric queries issued per resource). Weights MIRROR Extension/Metrics.ps1 - keep the two in sync when metric names change.
# ExtraFilter scopes the type; Gate marks conditional weights (Disk via -SkipDiskMetrics, Storage opt-in); Batched marks metrics:getBatch-eligible types. SQL weight is the serverless worst case (9, a deliberate +1 over-estimate). PURE.
function Get-MetricQueryWeightMap
{
    return @(
        [pscustomobject]@{ Type = 'microsoft.compute/virtualmachines'; Weight = 2; ExtraFilter = $null; Gate = $null; Batched = $true }
        [pscustomobject]@{ Type = 'microsoft.compute/disks'; Weight = 4; ExtraFilter = 'isnotempty(managedBy)'; Gate = 'Disk'; Batched = $true }
        [pscustomobject]@{ Type = 'microsoft.storage/storageaccounts'; Weight = 1; ExtraFilter = $null; Gate = 'Storage'; Batched = $true }
        [pscustomobject]@{ Type = 'microsoft.sql/servers/databases'; Weight = 9; ExtraFilter = "name != 'master'"; Gate = $null; Batched = $true }
        [pscustomobject]@{ Type = 'microsoft.web/sites'; Weight = 2; ExtraFilter = "kind contains 'functionapp'"; Gate = $null; Batched = $false }
        [pscustomobject]@{ Type = 'microsoft.dbformariadb/servers'; Weight = 3; ExtraFilter = $null; Gate = $null; Batched = $false }
        [pscustomobject]@{ Type = 'microsoft.dbforpostgresql/servers'; Weight = 3; ExtraFilter = $null; Gate = $null; Batched = $false }
        [pscustomobject]@{ Type = 'microsoft.dbformysql/servers'; Weight = 3; ExtraFilter = $null; Gate = $null; Batched = $false }
        [pscustomobject]@{ Type = 'microsoft.dbformysql/flexibleservers'; Weight = 3; ExtraFilter = $null; Gate = $null; Batched = $false }
        [pscustomobject]@{ Type = 'microsoft.dbforpostgresql/flexibleservers'; Weight = 3; ExtraFilter = $null; Gate = $null; Batched = $false }
        [pscustomobject]@{ Type = 'microsoft.compute/virtualmachinescalesets'; Weight = 2; ExtraFilter = $null; Gate = $null; Batched = $true }
        [pscustomobject]@{ Type = 'microsoft.documentdb/databaseaccounts'; Weight = 4; ExtraFilter = $null; Gate = $null; Batched = $true }
        [pscustomobject]@{ Type = 'microsoft.containerregistry/registries'; Weight = 1; ExtraFilter = $null; Gate = $null; Batched = $false }
    )
}

# Build the Resource Graph (KQL) query returning per-subscription projected metric-query weight, honoring the same gating the metrics phase uses so the estimate matches the real run. PURE.
# -SkipStorageMetrics here is INTERNAL (caller passes the effective -not IncludeStorageMetrics); there is no public -SkipStorageMetrics switch - do not add one back.
function Get-PlanWeightKql
{
    param(
        [switch]$SkipDiskMetrics,
        [switch]$SkipStorageMetrics
    )
    $Cases = @()
    $BatchCases = @()
    foreach ($Entry in (Get-MetricQueryWeightMap))
    {
        if ($Entry.Gate -eq 'Disk' -and $SkipDiskMetrics) { continue }
        if ($Entry.Gate -eq 'Storage' -and $SkipStorageMetrics) { continue }
        $Pred = "type =~ '{0}'" -f $Entry.Type
        if ($Entry.ExtraFilter) { $Pred += ' and ' + $Entry.ExtraFilter }
        $Cases += ('{0}, {1}' -f $Pred, $Entry.Weight)
        # __bw carries the weight ONLY for types the metrics phase can batch, so
        # -Plan can apply the batch discount to just those and keep the per-call
        # cost for the rest (Function Apps, OSS DBs, ACR).
        if ($Entry.Batched) { $BatchCases += ('{0}, {1}' -f $Pred, $Entry.Weight) }
    }
    $CaseBody = $Cases -join ",`n    "
    $BatchCaseBody = if ($BatchCases.Count -gt 0) { $BatchCases -join ",`n    " } else { "1 == 0, 0" }
    return @"
Resources
| extend __w = case(
    $CaseBody,
    0)
| extend __bw = case(
    $BatchCaseBody,
    0)
| where __w > 0
| summarize QueryWeight = sum(__w), BatchWeight = sum(__bw) by subscriptionId
"@
}

# Deterministic per-subscription hash VALUE (uint32 from the first 4 big-endian SHA-256 bytes of the lowercased id) - the same value Get-ShardKeyForSubscription reduces mod ShardCount.
# Exposed separately so -Plan sizing hashes ONCE per sub then reduces % N cheaply across candidate shard counts; consistency with Get-ShardKeyForSubscription is locked by a unit test.
function Get-SubscriptionHashValue
{
    param(
        [Parameter(Mandatory = $true)][string]$SubscriptionId
    )
    $Bytes = [System.Text.Encoding]::UTF8.GetBytes($SubscriptionId.ToLowerInvariant())
    $Sha = [System.Security.Cryptography.SHA256]::Create()
    try { $Hash = $Sha.ComputeHash($Bytes) } finally { $Sha.Dispose() }
    return ([uint32]$Hash[0] -shl 24) -bor ([uint32]$Hash[1] -shl 16) -bor ([uint32]$Hash[2] -shl 8) -bor [uint32]$Hash[3]
}

# One bounded-retry Search-AzGraph call for the -Plan weight query. Declared at FILE scope (not nested) so its existence never depends on whether -Plan has run yet.
# Plain exponential backoff + jitter, NOT the server-directed Get-RetryWaitSeconds - that helper lives in ResourceInventory.Functions.ps1, which this wrapper does not dot-source, so calling it would throw on the first real throttle.
function Invoke-PlanWeightQuery
{
    param([hashtable]$GraphArgs, [int]$MaxRetries)

    for ($Attempt = 0; ; $Attempt++)
    {
        try
        {
            return Search-AzGraph @GraphArgs -ErrorAction Stop
        }
        catch
        {
            if ($Attempt -ge $MaxRetries) { throw }

            # The clamp is a CEILING for future growth of $MaxRetries, not a limit that
            # bites today: with 4 retries the waits are 1, 2, 4, 8 so it is never
            # reached. It is set to the largest wait the current schedule produces, so
            # raising the retry budget cannot silently introduce a minute-long sleep in
            # a pre-flight sizing query.
            $Wait = [math]::Min([math]::Pow(2, $Attempt), 8)
            Start-Sleep -Seconds ([math]::Round($Wait + ((Get-Random -Minimum 0 -Maximum 1000) / 1000.0), 2))
        }
    }
}

# Query the live tenant (Search-AzGraph) for each subscription's projected metric-query weight; chunks by <=1000 (ARG per-query cap) and pages via SkipToken. Returns { subscriptionId -> { Total; Batch } }, keys only for weight>0.
# Returns $null ONLY when the query is UNUSABLE (cmdlet missing or threw) so the caller flat-fallback-and-warns; a successful-but-empty result is @{}, a real answer the caller must NOT treat as failure.
function Get-PlanSubscriptionWeights
{
    param(
        [Parameter(Mandatory = $true)][string[]]$SubscriptionIds,
        [switch]$SkipDiskMetrics,
        [switch]$SkipStorageMetrics
    )
    if (-not (Get-Command Search-AzGraph -ErrorAction SilentlyContinue)) { return $null }
    $Kql = Get-PlanWeightKql -SkipDiskMetrics:$SkipDiskMetrics -SkipStorageMetrics:$SkipStorageMetrics
    $Weights = @{}

    # Bounded retry around each Search-AzGraph call - the most throttle-prone query in the tool, where a single 429 otherwise drops shard sizing back to the coarse flat estimate.
    # Deliberately smaller than discovery's 30-attempt budget (4 retries = 5 tries, ~15s+jitter): -Plan runs before any work, so an operator should not wait minutes before the flat fallback.
    $PlanQueryMaxRetries = 4

    # ONE constant for chunk stride, slice width AND -First: all three must stay equal or the completeness argument below breaks (a smaller stride SKIPS ids, larger OVERLAPS, a different -First breaks the row bound).
    # 1000 is the Resource Graph per-query subscription cap; it doubles as the row page size ONLY because this aggregate emits at most one row per subscription. Do not reuse for a non-aggregate query.
    $PlanQueryChunkSize = 1000

    try
    {
        $Ids = @($SubscriptionIds | Where-Object { $_ })
        for ($Offset = 0; $Offset -lt $Ids.Count; $Offset += $PlanQueryChunkSize)
        {
            $Chunk = @($Ids[$Offset..([math]::Min($Offset + ($PlanQueryChunkSize - 1), $Ids.Count - 1))])
            $GraphArgs = @{ Query = $Kql; Subscription = $Chunk; First = $PlanQueryChunkSize }
            $Batch = Invoke-PlanWeightQuery -GraphArgs $GraphArgs -MaxRetries $PlanQueryMaxRetries
            while ($true)
            {
                foreach ($Row in $Batch)
                {
                    $SubId = [string]$Row.subscriptionId
                    if ($SubId)
                    {
                        $Weights[$SubId] = [pscustomobject]@{
                            Total = [double]$Row.QueryWeight
                            Batch = [double]$Row.BatchWeight
                        }
                    }
                }

                # Row-limit truncation is structurally impossible here: the 'summarize by subscriptionId' aggregate emits at most one row per sub and the chunk is capped at $PlanQueryChunkSize (== -First), so an absent SkipToken really means "done".
                # SIZE-based truncation stays genuinely undetectable (Search-AzGraph does not surface the REST truncation flag); a resultTruncated / rows>=page guard here is dead or fires only falsely, so none is used.
                if (-not $Batch.SkipToken) { break }
                $GraphArgs['SkipToken'] = $Batch.SkipToken
                $Batch = Invoke-PlanWeightQuery -GraphArgs $GraphArgs -MaxRetries $PlanQueryMaxRetries
            }
        }
    }
    catch
    {
        # Tell the operator WHY the composition-aware estimate was abandoned. Returning
        # a bare $null made the caller print its generic "falling back to the flat
        # estimate" warning with no cause, so a throttle, a permission gap and a
        # refusing-to-guess truncation check were indistinguishable - and the two that
        # are fixable looked like the one that is not.
        Write-Warning ("Plan weight query failed, so shard sizing will use the coarse flat estimate instead of per-subscription composition: {0}" -f $_.Exception.Message)
        return $null
    }
    # A successful-but-empty result ($Weights.Count -eq 0) is a USABLE answer (no
    # metric-eligible resources in scope), NOT a failure - return the empty map so
    # the caller sizes every subscription at base overhead rather than triggering
    # the coarse flat fallback + warning.
    return $Weights
}

# Composition-aware shard sizing: from each sub's estimated wall-time seconds, find the smallest shard count whose BUSIEST shard fits the ceiling, simulating the ACTUAL hash partition (%N) so heavy-sub clumping counts (not an even split). Shard wall = max(largest single sub, sum/Streams). PURE.
# Never recommends more shards than subscriptions. On no fit: CeilingUnreachable=$true with CeilingUnreachableReason ('single-subscription-exceeds-ceiling' or 'shard-cap-or-hash-collisions').
function Get-WeightedInventoryPlan
{
    param(
        [Parameter(Mandatory = $true)][hashtable]$SubSeconds,
        [int]$Streams = 1,
        [double]$MaxSingleMachineHours = 2,
        [int]$MaxShards = 1000
    )
    if ($Streams -lt 1) { $Streams = 1 }
    if ($MaxSingleMachineHours -le 0) { $MaxSingleMachineHours = 2 }
    if ($MaxShards -lt 1) { $MaxShards = 1 }
    $CeilingSeconds = $MaxSingleMachineHours * 3600
    $SubIds = @($SubSeconds.Keys)
    $SubCount = $SubIds.Count

    if ($SubCount -eq 0)
    {
        return [pscustomobject]@{
            Mode = 'Single'; ShardCount = 1; Streams = $Streams; SubscriptionCount = 0
            TotalSeconds = 0; BusiestShardSeconds = 0; LargestSingleSubSeconds = 0
            PerMachineSubscriptions = 0; MaxSingleMachineHours = $MaxSingleMachineHours
            CeilingUnreachable = $false; CeilingUnreachableReason = $null
        }
    }

    # Never recommend more shards than there are subscriptions - a shard needs at
    # least one subscription to do any work. Also bounds the candidate search.
    if ($MaxShards -gt $SubCount) { $MaxShards = $SubCount }

    $TotalSeconds = 0.0
    $LargestSingle = 0.0
    $HashVal = @{}
    foreach ($Id in $SubIds)
    {
        $Sec = [double]$SubSeconds[$Id]
        $TotalSeconds += $Sec
        if ($Sec -gt $LargestSingle) { $LargestSingle = $Sec }
        $HashVal[$Id] = Get-SubscriptionHashValue -SubscriptionId $Id
    }

    # Busiest-shard wall time for a candidate shard count N, using the real hash
    # partition. Local scriptblock so the per-N loop stays a single pass.
    $BusiestForN = {
        param([int]$N)
        $BucketSum = @{}
        $BucketMax = @{}
        foreach ($Id in $SubIds)
        {
            $K = [int]($HashVal[$Id] % [uint32]$N)
            $Sec = [double]$SubSeconds[$Id]
            $BucketSum[$K] = ([double]$BucketSum[$K]) + $Sec
            if ($Sec -gt ([double]$BucketMax[$K])) { $BucketMax[$K] = $Sec }
        }
        $Busiest = 0.0
        foreach ($K in $BucketSum.Keys)
        {
            $Wall = [math]::Max([double]$BucketMax[$K], [math]::Ceiling(([double]$BucketSum[$K]) / $Streams))
            if ($Wall -gt $Busiest) { $Busiest = $Wall }
        }
        return $Busiest
    }

    $CeilingUnreachable = $false
    $CeilingUnreachableReason = $null
    $ChosenN = 0
    $Busiest = 0.0

    if ($LargestSingle -gt $CeilingSeconds)
    {
        # No amount of sharding can help: sharding splits work ACROSS
        # subscriptions, never within one, so the single slowest subscription is
        # a hard floor on the busiest shard. Skip the (pointless) search - this
        # also avoids up to SubCount x MaxShards bucket passes for an estate that
        # provably cannot fit.
        $ChosenN = $MaxShards
        $Busiest = [double](& $BusiestForN $MaxShards)
        $CeilingUnreachable = $true
        $CeilingUnreachableReason = 'single-subscription-exceeds-ceiling'
    }
    else
    {
        # Start the search at the aggregate lower bound (a smaller N provably
        # cannot fit the total work under the ceiling), then grow until the
        # busiest shard fits. Bounded by MaxShards (already clamped to the
        # subscription count), so it is a handful of candidates in practice.
        $Lower = [long][math]::Ceiling($TotalSeconds / ($Streams * $CeilingSeconds))
        if ($Lower -lt 1) { $Lower = 1 }
        if ($Lower -gt $MaxShards) { $Lower = $MaxShards }

        for ($N = $Lower; $N -le $MaxShards; $N++)
        {
            $B = [double](& $BusiestForN $N)
            if ($B -le $CeilingSeconds) { $ChosenN = $N; $Busiest = $B; break }
        }

        if ($ChosenN -eq 0)
        {
            # Every candidate up to the cap still has a shard over the ceiling
            # even though no single subscription exceeds it: the hash partition
            # clumps enough mid-weight subscriptions together that the cap
            # (=subscription count) cannot separate them.
            $ChosenN = $MaxShards
            $Busiest = [double](& $BusiestForN $MaxShards)
            $CeilingUnreachable = $true
            $CeilingUnreachableReason = 'shard-cap-or-hash-collisions'
        }
    }

    return [pscustomobject]@{
        Mode                     = if ($ChosenN -le 1) { 'Single' } else { 'Sharded' }
        ShardCount               = $ChosenN
        Streams                  = $Streams
        SubscriptionCount        = $SubCount
        TotalSeconds             = [long]$TotalSeconds
        BusiestShardSeconds      = [long]$Busiest
        LargestSingleSubSeconds  = [long]$LargestSingle
        PerMachineSubscriptions  = [int][math]::Ceiling($SubCount / $ChosenN)
        MaxSingleMachineHours    = $MaxSingleMachineHours
        CeilingUnreachable       = $CeilingUnreachable
        CeilingUnreachableReason = $CeilingUnreachableReason
    }
}

# === Pre-flight checks ===
# Detect common environment problems (before auth / tenant / any per-sub work); each check either hard-fails via Exit-Wrapper or warns and continues.
# ResourceInventory.ps1 keeps its OWN inline variant (honors -OutputDirectory, throws instead of Exit-Wrapper, gated on -not $RunAllSubs) - keep the two behaviorally in sync.
function Invoke-PreFlightChecks
{
    param(
        [Parameter(Mandatory = $true)] [string] $InventoryRoot
    )

    Write-Host "Running pre-flight checks..." -ForegroundColor Cyan

    # 1. Cloud Shell mount detection. Get-CloudDrive ships only with Cloud Shell's preloaded Az.CloudShell, so the cmdlet's EXISTENCE probes "in Cloud Shell" and its RETURN VALUE probes "drive mounted" ($null = ephemeral mode).
    # 3>$null suppresses its noisy "not mounted" warning so our message shows first.
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

    # 2. Disk space probe at the inventory root: a 100+ sub run writes 200-500 MB of zips, and low free space otherwise fails late and confusingly during report generation or zip packaging.
    try
    {
        $RootItem = Get-Item -LiteralPath $InventoryRoot -ErrorAction Stop
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
                # InvariantCulture: a bare "{0:N0}" formats with CURRENT culture, so on an
                # en-NL host 22378 rendered as "22.378 MB" and read as a fraction of a MB
                # when the disk actually had ~22 GB free.
                Write-Host ("Free disk space: {0} MB at {1}" -f $FreeMB.ToString('N0', [cultureinfo]::InvariantCulture), $InventoryRoot) -ForegroundColor Green
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
        Set-Content -LiteralPath $ProbePath -Value 'preflight write probe' -Encoding utf8 -ErrorAction Stop
        $ProbeRead = Get-Content -LiteralPath $ProbePath -Raw -ErrorAction Stop
        if ($ProbeRead -notmatch 'preflight write probe')
        {
            throw "Write probe content mismatch (read back '$ProbeRead')"
        }
        Remove-Item -LiteralPath $ProbePath -Force -ErrorAction Stop
        Write-Host ("Write probe: OK ({0})" -f $InventoryRoot) -ForegroundColor Green
    }
    catch
    {
        Write-Host ("ERROR: Cannot write to {0}: {1}" -f $InventoryRoot, $_.Exception.Message) -ForegroundColor Red
        Write-Host "  This usually means: readonly directory, denied permissions, antivirus or DLP product blocking writes, or a stale handle." -ForegroundColor Red
        Write-Host "  Verify the directory is writable and re-run." -ForegroundColor Red
        # Best-effort cleanup in case Set-Content partially succeeded.
        try { if (Test-Path -LiteralPath $ProbePath) { Remove-Item -LiteralPath $ProbePath -Force -ErrorAction SilentlyContinue } }
        catch { Write-Verbose ("Probe cleanup failed at {0}: {1}" -f $ProbePath, $_.Exception.Message) }
        Exit-Wrapper -Code 1
    }

    # 4. (removed) ImportExcel / EPPlus health probe - the report is now self-contained HTML (Extension/Summary.ps1) with no external module dependency, so there is nothing to preflight.

    Write-Host "Pre-flight checks passed." -ForegroundColor Green
    Write-Host ""
}

# Resolve a tenant identifier (GUID or verified domain) to a tenant GUID. A domain is resolved via the anonymous OIDC discovery endpoint, whose "issuer" embeds the GUID.
# Resolving up front keeps every downstream call on a stable identifier even if the domain is later renamed.
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

# Single blob-first (local-file fallback) reader of the tenant's resume-state object, or $null when neither exists/reads/matches the tenant. Blob-first because a rescheduled AKS pod has no local file.
# Centralises the read + tenant guard for every Get-* projection below; the blob branch is skipped when no blob is configured, keeping the local path byte-for-byte historical.
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
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try
    {
        $State = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
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

# Single owner of the "-State supplied or not" decision for the three projections below. -State lets a caller read the state blob ONCE and project many; omitting it preserves the original self-reading behaviour.
# -StateSupplied (via PSBoundParameters), NOT a $null default: the seed is legitimately $null on a fresh run / tenant mismatch / unreadable blob, and treating that as "not supplied" would re-hit the blob on the very recovery path this spares. The tenant guard is RE-ASSERTED here because the value it protects gates which subscriptions are SKIPPED.
function Resolve-ResumeState
{
    param(
        [string]$Path,
        [string]$Tenant,
        $BlobContext = $null,
        [string]$BlobContainer = $null,
        [string]$BlobName = $null,
        $State = $null,
        [switch]$StateSupplied
    )

    if (-not $StateSupplied)
    {
        return Get-ResumeStateObject -Path $Path -Tenant $Tenant -BlobContext $BlobContext -BlobContainer $BlobContainer -BlobName $BlobName
    }

    if ($null -eq $State) { return $null }

    if ($State.TenantID -ne $Tenant)
    {
        Write-Host ("Supplied resume state is for a different tenant ({0}); ignoring." -f $State.TenantID) -ForegroundColor Yellow
        return $null
    }

    return $State
}

# -State: an ALREADY-READ resume-state object (see Resolve-ResumeState).
function Get-CompletedSubscriptionIds
{
    param([string]$Path, [string]$Tenant, $BlobContext = $null, [string]$BlobContainer = $null, [string]$BlobName = $null,
        $State = $null)

    $State = Resolve-ResumeState -Path $Path -Tenant $Tenant -BlobContext $BlobContext -BlobContainer $BlobContainer -BlobName $BlobName `
        -State $State -StateSupplied:$PSBoundParameters.ContainsKey('State')

    if ($null -eq $State -or $null -eq $State.CompletedSubscriptionIds) { return @() }
    return @($State.CompletedSubscriptionIds)
}

# Project the FailedAttempts list ({ Id, Name, LastFailedAt, Reason, Attempts }) from the resume-state, or @() when absent/malformed/wrong-tenant. Backward-compatible: older state without the key reads back empty.
# -State: an ALREADY-READ resume-state object (see Resolve-ResumeState).
function Get-FailedAttempts
{
    param([string]$Path, [string]$Tenant, $BlobContext = $null, [string]$BlobContainer = $null, [string]$BlobName = $null,
        $State = $null)

    $State = Resolve-ResumeState -Path $Path -Tenant $Tenant -BlobContext $BlobContext -BlobContainer $BlobContainer -BlobName $BlobName `
        -State $State -StateSupplied:$PSBoundParameters.ContainsKey('State')

    if ($null -eq $State -or $null -eq $State.FailedAttempts) { return @() }
    # Strip nulls: state written by a version that serialised an empty list as
    # `[ null ]` reads back as a one-element array holding a null; the existing
    # $null guard above does not catch that (the array itself is not $null). This
    # self-heals such a file so a phantom null never enters the retry list.
    return @($State.FailedAttempts | Where-Object { $null -ne $_ })
}

# Project the EnumeratedAtStart object ({ CapturedUtc; SubscriptionIds }) from the resume-state, or $null if none. Preserves the ORIGINAL start-of-run universe across resume/reschedule for the end-of-run reconciliation.
# -State: an ALREADY-READ resume-state object (see Resolve-ResumeState).
function Get-StartSnapshot
{
    param([string]$Path, [string]$Tenant, $BlobContext = $null, [string]$BlobContainer = $null, [string]$BlobName = $null,
        $State = $null)

    $State = Resolve-ResumeState -Path $Path -Tenant $Tenant -BlobContext $BlobContext -BlobContainer $BlobContainer -BlobName $BlobName `
        -State $State -StateSupplied:$PSBoundParameters.ContainsKey('State')

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
        TenantID                 = $Tenant
        CompletedSubscriptionIds = @($Ids)
        # FailedAttempts is the canonical "what to retry" list (appended on each catch, removed on the next success).
        # The `Where-Object { $null -ne $_ }` is REQUIRED: an empty list collapses to $null upstream and `@($null)` would serialise to `[ null ]` instead of `[]`.
        FailedAttempts           = @($FailedAttempts | Where-Object { $null -ne $_ })
        LastUpdated              = (Get-Date).ToString('o')
    }
    if ($null -ne $StartSnapshot) { $StateMap['EnumeratedAtStart'] = $StartSnapshot }
    $State = [pscustomobject]$StateMap
    try
    {
        # Atomic write: serialize to a sibling temp file (same volume), then File.Move(overwrite) - a same-volume rename is atomic, so a crash/SIGKILL/disk-full never leaves a truncated file that Get-CompletedSubscriptionIds would read as "start fresh" and discard all progress.
        # Depth 5 (was 4) so the nested EnumeratedAtStart.SubscriptionIds array serialises fully.
        $TmpPath = "$Path.tmp"
        $State | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $TmpPath -Encoding utf8
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
        # [object], NOT [IEnumerable]: a single prior failure collapses to a scalar PSCustomObject (not IEnumerable), which threw a parameter-transformation error; the @(...) below normalizes scalar/$null/array.
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

# Discover per-stream resume-state files by globbing, NOT by iterating 0..($StreamCount-1): an earlier interrupted run with a LARGER -ParallelStreams leaves higher-numbered files that iteration would neither read (losing data) nor clean up.
# -Force is required because these dot-prefixed filenames are hidden by Get-ChildItem on Unix.
function Get-StreamResumeStateFiles
{
    param(
        [Parameter(Mandatory = $true)][string]$InventoryRoot,
        [Parameter(Mandatory = $true)][string]$Tenant
    )
    return @(Get-ChildItem -LiteralPath $InventoryRoot -Filter (".resume-state-{0}-stream-*.json" -f $Tenant) -File -Force -ErrorAction SilentlyContinue)
}

# Reconcile FailedAttempts from multiple streams (plus pre-existing) against the unified CompletedIds: drop any sub now in CompletedIds; when a sub failed in more than one place, the most-recent LastFailedAt wins so a stale failure never shadows a later one.
function Merge-FailedAttempts
{
    param(
        # [object], NOT [IEnumerable], for all three: same single-element-collapse hazard as Add-/Remove-FailedAttempt (a lone item is a scalar, not IEnumerable, and threw); the @()-wraps below normalize scalar/$null/array.
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

# Probe whether Az can silently acquire a token for $TenantID. Get-AzAccessToken warns (not throws) on failure, so warnings are treated as failure alongside exceptions.
# EXCEPT the Az.Accounts 4.x deprecation banner, which fires on every SUCCESSFUL call - treating it as failure would force users on the new module to re-authenticate every run.
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

# Machine-facing exit-code signal from two booleans: 3 = a requested data phase was auth-skipped, 4 = collector(s) failed (#22), 5 = BOTH. The combined 5 exists so neither problem masks the other (an if/elseif would).
# Distinct from 1 (hard preflight/auth/setup), 2 (output-verification gap), 0 (clean). PURE two-bool -> code so it is unit-testable.
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
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @{ Completed = @(); Failed = @() } }
    try
    {
        $Obj = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        return @{
            Completed = if ($null -eq $Obj.Completed) { @() } else { @($Obj.Completed) }
            # Backward-compatible: state files written by an older worker had
            # no FailedAttempts key, so default to @(). Also strip nulls so a file
            # written as `[ null ]` (empty list collapsed to $null upstream) does
            # not fold a phantom null into the parent's unified state.
            Failed    = if ($null -eq $Obj.FailedAttempts) { @() } else { @($Obj.FailedAttempts | Where-Object { $null -ne $_ }) }
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
            # Strip nulls (see Save-CompletedSubscriptionIds): an empty
            # FailedAttempts collapsed to $null upstream would otherwise serialise
            # to `[ null ]` here too, and the parent folds this file straight back
            # into the unified state.
            FailedAttempts = @($FailedAttempts | Where-Object { $null -ne $_ })
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

# Normalize the -Service collector filter so both call forms behave identically: `pwsh -File ... -Service a,b` binds the single element 'a,b' (not @('a','b')), so split on comma, then trim/drop-empty/dedupe. PURE.
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


# Classify a consumption-probe error message into 'Ok' / 'Denied' / 'Unavailable'. PURE (unit-testable).
# 'Denied' (RBAC / no Cost Management|Billing Reader) is a HARD failure because consumption was requested - shipping a report silently missing billing data is worse than stopping. 'Unavailable' (token/CA/MFA/throttle) is the recoverable warn-and-continue class.
function Get-ConsumptionAccessOutcome
{
    param([string]$ErrorMessage)
    if ([string]::IsNullOrWhiteSpace($ErrorMessage)) { return 'Ok' }
    # Denial signatures live in Test-RdaConsumptionDenial (Common.Functions.ps1), one owner shared with ResourceInventory.ps1's retry loop - drift would be hard to spot since this gate STOPS the run while the loop stops retrying.
    if (Test-RdaConsumptionDenial -ErrorMessage $ErrorMessage)
    {
        return 'Denied'
    }
    return 'Unavailable'
}

# Probe billing/consumption READ access via the same tiny Get-UsageAggregates call the consumption phase uses. Access-but-zero-usage returns empty (not an error) -> 'Ok'; a context-switch failure is 'Unavailable' (session/token, not a denial).
# Returns { Outcome ('Ok'/'Denied'/'Unavailable' via Get-ConsumptionAccessOutcome), Detail (the exception reason for the operator, or $null) }.
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

    # Get-UsageAggregates Daily requires the reported times at UTC midnight (00:00:00Z). (Get-Date).Date serialises with the host offset, so for a non-UTC operator the API rejects it and the probe misclassified every run as 'Unavailable'. [DateTime]::UtcNow.Date is 00:00:00 Kind=Utc -> serialises as Z.
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

# Probe metrics READ access (Monitoring Reader) by fetching the metric DEFINITIONS of one metric-eligible resource (the cheapest call on that permission), found via the same Resource Graph path the inventory uses.
# Returns { Outcome ('Ok'/'Denied'/'Unavailable'/'NoResource' - NoResource = nothing eligible to prove, not a failure), Detail }. Denial reuses Test-RdaConsumptionDenial (same RBAC signatures) to avoid drift.
function Test-MetricsAccess
{
    param([Parameter(Mandatory = $true)][string]$SubscriptionId)

    $Query = "resources | where subscriptionId =~ '{0}' and type in~ ('microsoft.compute/virtualmachines','microsoft.storage/storageaccounts','microsoft.sql/servers/databases','microsoft.web/sites','microsoft.network/publicipaddresses') | project id | take 1" -f $SubscriptionId
    try
    {
        # Same collection form as Invoke-AzGraphRequest: never @(Search-AzGraph ...), which wraps the single response object instead of enumerating its rows.
        $ProbeResponse = Search-AzGraph -Query $Query -Subscription $SubscriptionId -First 1 -ErrorAction Stop
        $Probe = if ($null -eq $ProbeResponse) { @() } else { @($ProbeResponse) }
    }
    catch
    {
        return [pscustomobject]@{ Outcome = 'Unavailable'; Detail = ('could not locate a metric-eligible resource: {0}' -f $_.Exception.Message) }
    }
    if ($Probe.Count -eq 0 -or [string]::IsNullOrWhiteSpace([string]$Probe[0].id))
    {
        return [pscustomobject]@{ Outcome = 'NoResource'; Detail = 'no VM, storage account, SQL database, web app or public IP to probe' }
    }
    $ResourceId = [string]$Probe[0].id
    try
    {
        $null = Get-AzMetricDefinition -ResourceId $ResourceId -ErrorAction Stop -WarningAction SilentlyContinue | Select-Object -First 1
        return [pscustomobject]@{ Outcome = 'Ok'; Detail = $null }
    }
    catch
    {
        $Outcome = if (Test-RdaConsumptionDenial -ErrorMessage $_.Exception.Message) { 'Denied' } else { 'Unavailable' }
        return [pscustomobject]@{ Outcome = $Outcome; Detail = ('{0} (probed {1})' -f $_.Exception.Message, $ResourceId) }
    }
}

# Render the -Preflight permission matrix (per-sub rows of Name/Id/Reader/CostManagement/Monitoring, each Ok/Denied/Unavailable/NoResource/Skipped) to printable lines. PURE (unit-testable).
# Also returns a Blocking flag: any 'Denied' on a REQUESTED (not Skipped) phase blocks, mirroring the run-time gates, since a known denial would silently miss requested data.
function Format-PreflightMatrix
{
    param([Parameter(Mandatory = $true)]$Rows)

    $Rows = @($Rows)
    $Lines = [System.Collections.Generic.List[string]]::new()
    $Lines.Add('Permission matrix (per subscription):')
    $Lines.Add(('  {0,-40} {1,-13} {2,-16} {3,-13}' -f 'Subscription', 'Reader', 'Cost Mgmt', 'Monitoring'))
    $Lines.Add('  ' + ('-' * 86))
    $Blocking = $false
    $Hints = [System.Collections.Generic.List[string]]::new()
    foreach ($R in $Rows)
    {
        $Name = [string]$R.Name
        if ($Name.Length -gt 40) { $Name = $Name.Substring(0, 37) + '...' }
        $Lines.Add(('  {0,-40} {1,-13} {2,-16} {3,-13}' -f $Name, $R.Reader, $R.CostManagement, $R.Monitoring))
        if ($R.Reader -eq 'Denied') { $Blocking = $true; $Hints.Add(('Grant Reader on {0} ({1}) - or Reader at the tenant-root management group, which inherits to every subscription.' -f $R.Name, $R.Id)) }
        if ($R.Reader -eq 'Unavailable') { $Blocking = $true; $Hints.Add(('Reader on {0} ({1}) could not be verified; the real run stops on this unless -AllowPartialAccess is passed. Re-check the sign-in/token and re-run.' -f $R.Name, $R.Id)) }
        if ($R.CostManagement -eq 'Denied') { $Blocking = $true; $Hints.Add(('Grant Cost Management Reader on {0} ({1}) (or Billing Reader on the billing scope), or run with -SkipConsumption.' -f $R.Name, $R.Id)) }
        if ($R.Monitoring -eq 'Denied') { $Blocking = $true; $Hints.Add(('Grant Monitoring Reader on {0} ({1}), or run with -SkipMetrics.' -f $R.Name, $R.Id)) }
    }
    $Lines.Add('')
    $Lines.Add('  Ok = verified   Denied = RBAC denial (blocks the run)   Unavailable = could not verify (token/transient): Cost Mgmt / Monitoring retry per subscription in a real run, an unverifiable Reader stops it')
    $Lines.Add('  NoResource = nothing metric-eligible to probe   Skipped = phase not requested (-SkipMetrics / -SkipConsumption)')
    if ($Hints.Count -gt 0)
    {
        $Lines.Add('')
        $Lines.Add('To fix before running:')
        foreach ($H in ($Hints | Select-Object -Unique)) { $Lines.Add('  - ' + $H) }
    }
    return [pscustomobject]@{ Lines = @($Lines); Blocking = $Blocking }
}

# Build the run-level "RunSummary.log" content for the consolidated zip. PURE apart from the generation timestamp (unit-testable offline).
# Safety: the wrapper holds NO obfuscation dictionaries (child-process scope), so it CANNOT tokenize an identifier - an obfuscated run emits COUNTS ONLY (never names/ids/raw messages), and TenantID/SubscriptionID are always dropped from the recorded parameters.
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
        # Was each optional phase REQUESTED (its -Skip* NOT passed)? Passed by the caller, NOT re-derived from $InvocationParameters - guessing that bag's membership method once shipped a bundle with no RunSummary.log at all.
        # Default $true = "requested", the safe reading: report the real count rather than let a forgotten argument silently claim a skip the operator never asked for.
        [bool]$ConsumptionRequested = $true,
        [bool]$MetricsRequested = $true,
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

    # Allowlist of valued (non-switch) params whose VALUE is safe to print in an obfuscated bundle (tuning knobs, never identifiers); any other valued param has its value omitted so a future one cannot leak.
    # The metric knobs are attribute-bounded ints (ValidateSet/ValidateRange), so they can't carry an identifier and recording them keeps an obfuscated run's metric window auditable.
    $SafeValueParamNames = @('ParallelStreams', 'ConcurrencyLimit', 'MetricsIntervalMinutes', 'MetricsLookbackDays')

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
    # InvariantCulture on every timestamp below: a format string with no provider takes
    # the YEAR from CurrentCulture's Calendar and the ':' from its TimeSeparator, so a
    # th-TH host stamps 2569 and an ar-SA host 1448-04-03 into this SHIPPED log.
    # Measured, not theoretical.
    # Same fix and rationale as Functions/AllSubHtmlSummary.Functions.ps1:313-318.
    $Lines.Add(('Generated (UTC) : {0}' -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [cultureinfo]::InvariantCulture)))
    $Lines.Add(('Tool version    : {0}' -f [string]$Version))
    if ($StartTime -is [datetime] -and $StartTime -ne [datetime]::MinValue)
    {
        $Lines.Add(('Run started     : {0}' -f $StartTime.ToString('yyyy-MM-dd HH:mm:ss', [cultureinfo]::InvariantCulture)))
    }
    if ($EndTime -is [datetime] -and $EndTime -ne [datetime]::MinValue)
    {
        $Lines.Add(('Run finished    : {0}' -f $EndTime.ToString('yyyy-MM-dd HH:mm:ss', [cultureinfo]::InvariantCulture)))
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
    # InvariantCulture: $HostRamGB is a one-decimal [double] GB value from
    # Get-RecommendedParallelism, so a bare -f writes '15,6' on this en-NL host into the
    # SHIPPED RunSummary.log, which a reader treating ',' as a group separator sees as
    # 156 GB.
    if ($HostRamGB -gt 0) { $HostLines.Add(('  Host RAM (GB)     : {0}' -f $HostRamGB.ToString([cultureinfo]::InvariantCulture))) }
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
    # Report a skipped phase as 'n/a (-Skip* was passed)', not a bare 0 (which reads as a failure of what the operator turned off). Requested-ness arrives as -ConsumptionRequested/-MetricsRequested. The n/a wording is verbatim-identical to Write-RdaShareableDiagnosticsLog's (same bundle; a cross-surface Pester test pins each phrase).
    # Each n/a is gated on a ZERO count so a contradictory nonzero count from a skipped phase falls through to the numeric form. InvariantCulture on both numeric branches: a bare {0:N0} formats per current culture and misreads by orders of magnitude in this shipped log.
    if ((-not $ConsumptionRequested) -and ($ConsumptionRecordCount -eq 0))
    {
        $Lines.Add('  Consumption records collected : n/a (-SkipConsumption was passed)')
    }
    else
    {
        $Lines.Add(('  Consumption records collected : {0}' -f $ConsumptionRecordCount.ToString('N0', [cultureinfo]::InvariantCulture)))
    }
    if ((-not $MetricsRequested) -and ($MetricsApiCallCount -eq 0))
    {
        $Lines.Add('  Metric-query API calls issued : n/a (-SkipMetrics was passed)')
    }
    else
    {
        $Lines.Add(('  Metric-query API calls issued : {0}' -f $MetricsApiCallCount.ToString('N0', [cultureinfo]::InvariantCulture)))
    }
    $Lines.Add(('  Failed subscriptions          : {0}' -f $Failed.Count))
    $Lines.Add(('  Collector failures            : {0}' -f $Collector.Count))
    $Lines.Add(('  Metrics auth-skipped subs     : {0}' -f $Metrics.Count))
    $Lines.Add(('  Consumption failed subs       : {0}' -f $Consumption.Count))

    # Warn when consumption WAS requested, >=1 sub ran without a billing error, yet zero usage records came back - the up-front gate can't catch this (it classifies an EXCEPTION, and an empty-but-successful response raises none). Carries no identifiers, so emitted for obfuscated runs too.
    # The ($Processed - $Failed.Count) -gt 0 term requires at least one attempted sub that did NOT fail, so an all-failed run (whose zero count is explained by the failures) does not trigger this. Closely mirrors the console gate in Run-AllSubscriptions.ps1.
    if ($ConsumptionRequested -and ($ConsumptionRecordCount -eq 0) -and ($Consumption.Count -eq 0) -and ($Processed -gt 0) -and (($Processed - $Failed.Count) -gt 0))
    {
        $Lines.Add('')
        $Lines.Add('  WARNING - consumption was requested but ZERO usage records were collected,')
        $Lines.Add('  and no subscription reported a billing error. The billing API answered')
        $Lines.Add('  successfully with no rows, so the Consumption CSV holds only its header.')
        $Lines.Add('  Expected ONLY if there is genuinely no usage in the queried window (the 30')
        $Lines.Add('  days ending at midnight yesterday, host local time). Otherwise the usual causes are:')
        $Lines.Add('    - CSP / Partner-managed subscription with the partner cost visibility')
        $Lines.Add('      policy OFF (the default). Billing scope on CSP subscriptions is not')
        $Lines.Add('      governed by Azure RBAC, so granting Cost Management Reader does not')
        $Lines.Add('      help - the partner must enable it in Partner Center.')
        $Lines.Add('    - Subscription not transitioned to the Azure plan.')
        $Lines.Add('    - A subscription offer the legacy usage API does not serve.')
    }

    # Per-subscription detail is emitted ONLY for a non-obfuscated bundle, where
    # real names already appear throughout the report. An obfuscated bundle stops
    # at the counts above.
    if (-not $Obfuscated)
    {
        if ($Failed.Count -gt 0)
        {
            $Lines.Add('')
            $Lines.Add('Failed subscriptions (detail):')
            # This list holds either a plain STRING (every wrapper append site) or a { Name; Id } object (test fixtures / future callers); reading only .Name/.Id once rendered every shipped line as "  - ()". Render whichever shape arrived, and omit the parenthesised id when absent.
            foreach ($FailedSub in $Failed)
            {
                if ($FailedSub -is [string])
                {
                    $FailedName = $FailedSub
                    $FailedId = ''
                }
                else
                {
                    $FailedName = [string]$FailedSub.Name
                    $FailedId = [string]$FailedSub.Id
                    # An object with neither field would otherwise render blank; its own
                    # ToString() is strictly more informative than nothing.
                    if ([string]::IsNullOrWhiteSpace($FailedName)) { $FailedName = [string]$FailedSub }
                }

                if ([string]::IsNullOrWhiteSpace($FailedId)) { $Lines.Add(('  - {0}' -f $FailedName)) }
                else { $Lines.Add(('  - {0} ({1})' -f $FailedName, $FailedId)) }
            }
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

# Return $true if the consolidated zip contains an entry (case-insensitive on name or full path). Verifies the run summary actually folded into the bundle, so a silent Compress-Archive -Update failure is surfaced instead of shipping a summary-less bundle.
# Uses the cross-platform .NET System.IO.Compression API (no shelling to an archive tool); any error (locked/unreadable/missing) returns $false and the caller keeps the on-disk fallback.
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

# Collect the LOCAL support/diagnostic logs (wrapper transcript, failure/access-verdict logs, per-sub Diagnostics_/DebugLog_/ErrorLog_/Transcript_) into one zip + MANIFEST, for a FAILED run that produced no report bundle. Best-effort; returns $null (with a warning) when nothing matched.
# NOT public-safe: it carries real UPN / tenant / subscription ids / resource names, so it is a PRIVATE artefact for a secure channel. The obfuscation dictionary (ObfuscationDictionary_* / Full_*) is EXPLICITLY excluded so collecting can never leak the de-obfuscation key.
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
        # InvariantCulture: a bare -Format takes the year from CurrentCulture's Calendar,
        # which would put a Buddhist/Hijri year in the support-bundle FILENAME.
        $DestinationPath = Join-Path $InventoryRoot ('RdaSupportLogs_{0}.zip' -f (Get-Date).ToString('yyyy-MM-dd_HH-mm-ss', [cultureinfo]::InvariantCulture))
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
            foreach ($File in @(Get-ChildItem -LiteralPath $InventoryRoot -File -Filter $Pattern -ErrorAction SilentlyContinue))
            {
                if ((& $IsExcluded $File.Name) -or -not (& $PassesSince $File)) { continue }
                try { Copy-Item -LiteralPath $File.FullName -Destination (Join-Path $Stage $File.Name) -Force; $Collected++ }
                catch { Write-Verbose ("Support-log collection: skipped '{0}': {1}" -f $File.FullName, $_.Exception.Message) }
            }
        }

        foreach ($SubDir in @(Get-ChildItem -LiteralPath $InventoryRoot -Directory -Filter 'ResourcesReport*' -ErrorAction SilentlyContinue))
        {
            $DestSubDir = Join-Path $Stage $SubDir.Name
            foreach ($Pattern in $PerSubPatterns)
            {
                foreach ($File in @(Get-ChildItem -LiteralPath $SubDir.FullName -File -Filter $Pattern -ErrorAction SilentlyContinue))
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
        # InvariantCulture for the same reason as the RunSummary timestamps above.
        $Manifest.Add(('Generated (UTC) : {0}' -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [cultureinfo]::InvariantCulture)))
        $Manifest.Add(('Inventory root  : {0}' -f $InventoryRoot))
        if ($PSBoundParameters.ContainsKey('SinceTime')) { $Manifest.Add(('Scoped to files at/after : {0}' -f $SinceTime.ToString('yyyy-MM-dd HH:mm:ss', [cultureinfo]::InvariantCulture))) }
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
        $Manifest.ToArray() | Out-File -LiteralPath (Join-Path $Stage 'MANIFEST.txt') -Encoding utf8

        # -LiteralPath: -Path globs, so '[' or ']' anywhere in the inventory root would match a sibling instead (silently wrong content).
        $StageItems = @(Get-ChildItem -LiteralPath $Stage -Force -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
        Compress-Archive -LiteralPath $StageItems -DestinationPath ([WildcardPattern]::Escape($DestinationPath)) -Force
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
# The resume-state file is MIRRORED to Azure Blob (write-through: local-atomic first, then blob; reads blob-first with local fallback) so a rescheduled AKS pod, which has no local file, can recover.
# SDK (Az.Storage) not blobfuse: blobfuse breaks the atomic-rename crash-safety, while a whole-object block-blob PUT commits atomically. Every state-blob name is shard-namespaced via Get-StateBlobShardSegment (single owner), because the per-stream filename is keyed by tenant+stream only and a SHARED container would otherwise collide across shard pods.
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

# Single owner of the shard namespace segment used by every state-blob path.
# Applied whenever ShardCount > 1 because the blob container is shared across
# shard pods (see region header). Pure.
function Get-StateBlobShardSegment
{
    param(
        [int]$ShardIndex = 0,
        [int]$ShardCount = 1
    )
    if ($ShardCount -gt 1) { return ('shard-{0}of{1}/' -f $ShardIndex, $ShardCount) }
    return ''
}

# Single owner of the per-stream state-blob name PREFIX. PURE.
# The WRITE path (Get-StateBlobName) and DISCOVERY path (Get-StateBlobNames) must agree exactly; deriving both from here makes divergence impossible - if they drifted, a rescheduled pod would silently find no per-stream state and redo finished work.
function Get-StateBlobStreamPrefix
{
    param(
        # Empty string is a valid prefix (the container root, when the container
        # URL carries no path segment), so it must be allowed past the mandatory
        # non-empty default that [string] parameters enforce.
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Prefix,
        [Parameter(Mandatory = $true)][string]$Tenant,
        [int]$ShardIndex = 0,
        [int]$ShardCount = 1
    )
    $ShardSeg = Get-StateBlobShardSegment -ShardIndex $ShardIndex -ShardCount $ShardCount
    return ('{0}_state/{1}.resume-state-{2}-stream-' -f $Prefix, $ShardSeg, $Tenant)
}

# Build the shard-namespaced state-blob NAME under a dedicated _state/ area (kept out of the report-zip glob). StreamId<0 = the shard's unified file, StreamId>=0 = a per-stream file. PURE.
# The per-stream branch is built from Get-StateBlobStreamPrefix so it cannot drift from what Get-StateBlobNames lists on.
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
    if ($StreamId -ge 0)
    {
        $StreamPrefix = Get-StateBlobStreamPrefix -Prefix $Prefix -Tenant $Tenant -ShardIndex $ShardIndex -ShardCount $ShardCount
        return ('{0}{1}.json' -f $StreamPrefix, $StreamId)
    }

    $ShardSeg = Get-StateBlobShardSegment -ShardIndex $ShardIndex -ShardCount $ShardCount
    return ('{0}_state/{1}.resume-state-{2}.json' -f $Prefix, $ShardSeg, $Tenant)
}

# Classify how the subscription universe moved between the START-of-run snapshot and an END re-enumeration (subs can be created/deleted mid-run, so a single start-time list is stale by the end). PURE, case-insensitive on ids.
# Returns { Vanished (deleted mid-run - a failure there is expected), New (created mid-run - silently missing from the report unless handled), Incomplete (existed throughout but not completed) }; New and Incomplete are deliberately disjoint.
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

# Whole-blob PUT of a local file; a block-blob upload commits atomically, so a reader never sees a truncated doc (no temp+rename needed on the blob side). Returns $true on success.
# -BestEffort (hot per-sub write path) downgrades a transient failure to a WARNING + $false instead of throwing, because the local atomic write already succeeded and a blob blip must never abort a multi-hour run.
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

# Download and parse a state blob for a blob-first resume read (a rescheduled pod has no local file), or $null when there is no usable state. Never throws.
# The key distinction: a genuinely ABSENT blob correctly means "start fresh", but a present-but-UNREADABLE one silently re-runs the WHOLE estate. So retry with backoff, then probe existence via Get-AzStorageBlob (not exception types, which vary by Az.Storage version) and, if present-but-unreadable, WARN loudly - still returning $null rather than throwing, since callers aren't wrapped and throwing would discard a completed run's output.
function Read-StateBlob
{
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Container,
        [Parameter(Mandatory = $true)][string]$BlobName,
        # Small on purpose. This runs before any inventory work on the recovery path, so an
        # operator waiting to resume should not sit through a long backoff; 3 attempts
        # (1s + 2s of waiting) clears a momentary blip without stalling the run.
        [int]$MaxAttempts = 3
    )

    $LastError = $null
    for ($Attempt = 1; $Attempt -le $MaxAttempts; $Attempt++)
    {
        # A fresh temp path per attempt: a partial download left by a failed attempt must
        # not be re-read as though it were complete.
        $Tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('rda-state-dl-{0}.json' -f ([guid]::NewGuid().ToString('N')))
        try
        {
            $null = Get-AzStorageBlobContent -Container $Container -Blob $BlobName -Destination $Tmp -Context $Context -Force -ErrorAction Stop
            return (Get-Content -LiteralPath $Tmp -Raw | ConvertFrom-Json)
        }
        catch
        {
            $LastError = $_.Exception.Message
            if ($Attempt -lt $MaxAttempts) { Start-Sleep -Seconds $Attempt }
        }
        finally
        {
            Remove-Item -LiteralPath $Tmp -Force -ErrorAction SilentlyContinue
        }
    }

    # Every attempt failed. Absent, or present-but-unreadable?
    $Exists = $false
    try
    {
        $Probe = Get-AzStorageBlob -Container $Container -Blob $BlobName -Context $Context -ErrorAction Stop
        $Exists = ($null -ne $Probe)
    }
    catch
    {
        # The probe failing tells us nothing either way, so do not claim it does. Fall
        # through to the quiet branch rather than asserting the blob is present.
        $Exists = $false
        Write-Verbose ("Read-StateBlob: existence probe for {0} also failed: {1}" -f $BlobName, $_.Exception.Message)
    }

    if ($Exists)
    {
        Write-Host ("WARNING: resume state blob '{0}' EXISTS but could not be read after {1} attempt(s): {2}" -f $BlobName, $MaxAttempts, $LastError) -ForegroundColor Yellow
        Write-Host "  This is NOT the same as having no resume state. Treating it as absent means this run may RE-PROCESS subscriptions an earlier attempt already completed." -ForegroundColor Yellow
        Write-Host "  If that matters, stop now and re-run once the storage account is reachable, rather than paying for the whole estate again." -ForegroundColor Yellow
    }
    else
    {
        # Genuinely absent (the normal first-run signal), or absence could not be
        # confirmed. Quiet either way - this is the historical behaviour and the case the
        # blob-absence contract test pins.
        Write-Verbose ("Read-StateBlob: no usable state blob '{0}' ({1}); starting fresh." -f $BlobName, $LastError)
    }

    return $null
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
    # Shared with Get-StateBlobName's per-stream branch, so what is listed here is
    # by construction what was written there.
    $ListPrefix = Get-StateBlobStreamPrefix -Prefix $Prefix -Tenant $Tenant -ShardIndex $ShardIndex -ShardCount $ShardCount
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
