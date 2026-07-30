#Requires -Version 7.0
# AKS workload-identity entrypoint for a single RDA horizontal shard.
#
# The workload-identity webhook injects AZURE_CLIENT_ID / AZURE_TENANT_ID /
# AZURE_FEDERATED_TOKEN_FILE and projects a signed federated token into the pod -
# NO client secret is stored, mounted, or relayed. Each pod signs itself in,
# derives its shard index from the indexed-Job completion index, and runs the
# wrapper for THIS shard only.
#
# Sign-in uses the Az PowerShell module (Connect-AzAccount), so the pod runtime
# has NO dependency on the az CLI.
$ErrorActionPreference = 'Stop'

# Shard identity. An indexed Job sets JOB_COMPLETION_INDEX per pod (0..N-1);
# SHARD_COUNT is the total number of shards. Both default to the no-sharding
# case (index 0, count 1) so the image also runs as an ordinary single node.
$IndexPresent = -not [string]::IsNullOrWhiteSpace("$($env:JOB_COMPLETION_INDEX)")
$ShardIndex = if ($IndexPresent) { [int]$env:JOB_COMPLETION_INDEX } else { 0 }
$ShardCount = if (-not [string]::IsNullOrWhiteSpace("$($env:SHARD_COUNT)")) { [int]$env:SHARD_COUNT } else { 1 }

# Guard against silent shard collapse. With SHARD_COUNT>1, every pod MUST receive
# a distinct JOB_COMPLETION_INDEX (a completionMode: Indexed Job supplies it). If
# the index is absent - e.g. the Job is not Indexed, or the image is run outside a
# Job with SHARD_COUNT set by hand - every pod would default to shard 0, collect
# the SAME 1/N slice, and silently drop the other N-1 slices of the tenant. That
# is exactly the kind of silent partial collection this tool must never do, so
# fail loud instead of producing a deceptively "successful" partial run.
if ($ShardCount -gt 1 -and -not $IndexPresent)
{
    throw "SHARD_COUNT is $ShardCount but JOB_COMPLETION_INDEX is not set, so every pod would run shard 0 and the other $($ShardCount - 1) slice(s) would be silently skipped. Use a Job with 'completionMode: Indexed' (see deploy/k8s/job.yaml), which injects JOB_COMPLETION_INDEX per pod."
}
$HeadRoom = if (-not [string]::IsNullOrWhiteSpace("$($env:HEAD_ROOM)")) { [int]$env:HEAD_ROOM } else { 0 }
# Clamp to the wrapper's accepted range so a bad HEAD_ROOM gives a clear signal
# here rather than a ValidateRange(0,90) parameter-binding failure deeper in.
$RequestedHeadRoom = $HeadRoom
if ($HeadRoom -lt 0) { $HeadRoom = 0 }
if ($HeadRoom -gt 90) { $HeadRoom = 90 }
if ($HeadRoom -ne $RequestedHeadRoom) { Write-Host ("[entrypoint] HEAD_ROOM {0} is out of range [0,90]; clamped to {1}." -f $RequestedHeadRoom, $HeadRoom) }

$ClientId = $env:AZURE_CLIENT_ID
$TenantId = $env:AZURE_TENANT_ID
$TokenFile = $env:AZURE_FEDERATED_TOKEN_FILE
if ([string]::IsNullOrWhiteSpace($ClientId) -or [string]::IsNullOrWhiteSpace($TenantId) -or [string]::IsNullOrWhiteSpace($TokenFile))
{
    throw "Workload-identity environment not present (AZURE_CLIENT_ID / AZURE_TENANT_ID / AZURE_FEDERATED_TOKEN_FILE). Ensure the pod uses the annotated ServiceAccount and carries the azure.workload.identity/use=true label."
}

Write-Host ("[entrypoint] shard {0} of {1}; HeadRoom {2}%; signing in via workload identity." -f $ShardIndex, $ShardCount, $HeadRoom)

Import-Module Az.Accounts -ErrorAction Stop
$Federated = (Get-Content -Raw $TokenFile).Trim()
Connect-AzAccount -ServicePrincipal -ApplicationId $ClientId -Tenant $TenantId -FederatedToken $Federated -ErrorAction Stop | Out-Null
Write-Host ("[entrypoint] signed in as: {0}" -f (Get-AzContext).Account.Id)

# Build the wrapper arguments. The skip switches are env-driven so the Job
# manifest controls collection scope without rebuilding the image; the default
# (no env set) is full collection - inventory + metrics + consumption.
$WrapperArgs = @{
    TenantID   = $TenantId
    ShardCount = $ShardCount
    ShardIndex = $ShardIndex
}
if ($HeadRoom -gt 0) { $WrapperArgs.HeadRoom = $HeadRoom }
if ("$($env:SKIP_METRICS)" -eq 'true') { $WrapperArgs.SkipMetrics = $true }
if ("$($env:SKIP_CONSUMPTION)" -eq 'true') { $WrapperArgs.SkipConsumption = $true }
# Coverage / access gate override. By default the wrapper HARD-STOPS a shard if
# it cannot verify full subscription coverage (identity can read every
# subscription under the tenant-root management group) or cannot read a
# subscription it enumerated - the tool's purpose is to capture ALL subscriptions,
# so an unverifiable/partial run is refused. The correct production fix is to grant
# the UAMI Reader at the tenant-root management group (it inherits to every
# subscription AND makes coverage verifiable). Set ALLOW_PARTIAL_ACCESS=true only
# for a deliberate partial/test run (e.g. a first demo before MG-root Reader is in
# place): it downgrades that hard stop to a loud warning and proceeds with whatever
# subscriptions this identity can currently see. Forwards to -AllowPartialAccess.
if ("$($env:ALLOW_PARTIAL_ACCESS)" -eq 'true') { $WrapperArgs.AllowPartialAccess = $true }
# Metrics data-plane batch fast-path (metrics:getBatch). Opt-in; forwards to the
# wrapper's -UseMetricsBatch (VM/disk/storage/SQL/scale-set/Cosmos, with per-call
# fallback). Cuts the metrics phase's Azure Monitor call volume on large tenants.
if ("$($env:USE_METRICS_BATCH)" -eq 'true') { $WrapperArgs.UseMetricsBatch = $true }
# Per-pod parallelism (streams across THIS pod's cores; distinct from sharding
# across pods). Omit / 0 / non-numeric = let the wrapper auto-tune from the pod's
# CPU/RAM (capped at ~6 by the tenant ARG rate limit). A positive integer overrides.
if (-not [string]::IsNullOrWhiteSpace("$($env:PARALLEL_STREAMS)"))
{
    $ParsedStreams = 0
    if ([int]::TryParse("$($env:PARALLEL_STREAMS)", [ref]$ParsedStreams) -and $ParsedStreams -gt 0)
    {
        $WrapperArgs.ParallelStreams = $ParsedStreams
    }
    else
    {
        Write-Host ("[entrypoint] PARALLEL_STREAMS '{0}' is not a positive integer; ignoring (wrapper will auto-tune)." -f "$($env:PARALLEL_STREAMS)")
    }
}
# Per-node upload. When UPLOAD_BLOB_URI is set, each pod ships its finalized
# consolidated zip to the shared blob container (blob name is made unique per
# shard by the wrapper), so an operator running N pods collects all output from
# one container instead of exec-ing into every node. Passwordless: the wrapper
# uploads via the SAME workload identity signed in above (Storage Blob Data
# Contributor on the target). Omit the env var to keep each zip node-local.
if (-not [string]::IsNullOrWhiteSpace("$($env:UPLOAD_BLOB_URI)")) { $WrapperArgs.UploadToBlobContainerUri = $env:UPLOAD_BLOB_URI }

& /rda/Run-AllSubscriptions.ps1 @WrapperArgs
exit $LASTEXITCODE
