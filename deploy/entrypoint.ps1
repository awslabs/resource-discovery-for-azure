#Requires -Version 7.0
# AKS workload-identity entrypoint for one RDA shard: signs the pod in via a
# projected federated token (no client secret) using Az.Accounts, not the az CLI.
$ErrorActionPreference = 'Stop'

# Shard identity. An indexed Job sets JOB_COMPLETION_INDEX per pod (0..N-1);
# SHARD_COUNT is the total number of shards. Both default to the no-sharding
# case (index 0, count 1) so the image also runs as an ordinary single node.
$IndexPresent = -not [string]::IsNullOrWhiteSpace("$($env:JOB_COMPLETION_INDEX)")
$ShardIndex = if ($IndexPresent) { [int]$env:JOB_COMPLETION_INDEX } else { 0 }
$ShardCount = if (-not [string]::IsNullOrWhiteSpace("$($env:SHARD_COUNT)")) { [int]$env:SHARD_COUNT } else { 1 }

# Fail loud when SHARD_COUNT>1 but no per-pod JOB_COMPLETION_INDEX: otherwise every
# pod defaults to shard 0 and silently drops the other N-1 tenant slices.
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

# The federated token is read once here; a shard running longer than the projected
# Kubernetes SA-token lifetime (default 1h) can fail auth mid-run (not fixed here).
$Federated = (Get-Content -Raw $TokenFile).Trim()
Connect-AzAccount -ServicePrincipal -ApplicationId $ClientId -Tenant $TenantId -FederatedToken $Federated -ErrorAction Stop | Out-Null
Write-Host ("[entrypoint] signed in as: {0}" -f (Get-AzContext).Account.Id)
Write-Host "[entrypoint] NOTE: the federated token is read once at sign-in. If this shard runs longer than the projected Kubernetes token lifetime (default 1h) it can fail on refresh mid-run. Mitigations: raise SHARD_COUNT, set the azure.workload.identity/service-account-token-expiration annotation (max 86400), or re-run with RESUME=true. See deploy/AKS-WorkloadIdentity-Setup.md section 10."

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
# RESUME=true re-runs a shard skipping subscriptions already completed in the
# shared state blob - the recovery path the token-expiry NOTE above (and
# AKS-WorkloadIdentity-Setup.md) tells operators to use. RESUME_FAILED_ONLY=true
# narrows that to the subscriptions that previously failed.
if ("$($env:RESUME)" -eq 'true') { $WrapperArgs.Resume = $true }
if ("$($env:RESUME_FAILED_ONLY)" -eq 'true') { $WrapperArgs.ResumeFailedOnly = $true }
# ALLOW_PARTIAL_ACCESS=true forwards -AllowPartialAccess, downgrading the wrapper's
# unverifiable-coverage hard stop to a warning; only for a deliberate partial run.
if ("$($env:ALLOW_PARTIAL_ACCESS)" -eq 'true') { $WrapperArgs.AllowPartialAccess = $true }
# Metrics data-plane batch fast-path (metrics:getBatch). Opt-in; forwards to the
# wrapper's -UseMetricsBatch (VM/disk/storage/SQL/scale-set/Cosmos, with per-call
# fallback). Cuts the metrics phase's Azure Monitor call volume on large tenants.
if ("$($env:USE_METRICS_BATCH)" -eq 'true') { $WrapperArgs.UseMetricsBatch = $true }
# Storage Account 'UsedCapacity' metric. It is OPT-IN (one metric-query call per
# storage account, which dominates the metrics phase on a large storage estate),
# so without this the shard collects no storage capacity figure. Forwards to the
# wrapper's -IncludeStorageMetrics.
if ("$($env:INCLUDE_STORAGE_METRICS)" -eq 'true') { $WrapperArgs.IncludeStorageMetrics = $true }
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
# UPLOAD_BLOB_URI makes each pod upload its final zip to a shared container
# (passwordless, via the same workload identity); omit to keep each zip node-local.
if (-not [string]::IsNullOrWhiteSpace("$($env:UPLOAD_BLOB_URI)")) { $WrapperArgs.UploadToBlobContainerUri = $env:UPLOAD_BLOB_URI }
# State blob mirror for pod-reschedule durability (local disk is lost on reschedule):
# explicit STATE_BLOB_URI, else the UPLOAD_BLOB_URI container's _state/ subfolder.
$StateBlobUri = if (-not [string]::IsNullOrWhiteSpace("$($env:STATE_BLOB_URI)")) { $env:STATE_BLOB_URI }
elseif (-not [string]::IsNullOrWhiteSpace("$($env:UPLOAD_BLOB_URI)")) { $env:UPLOAD_BLOB_URI }
else { '' }
if (-not [string]::IsNullOrWhiteSpace($StateBlobUri)) { $WrapperArgs.StateBlobContainerUri = $StateBlobUri }

& /rda/Run-AllSubscriptions.ps1 @WrapperArgs
exit $LASTEXITCODE
