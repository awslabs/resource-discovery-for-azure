#Requires -Version 7.0
$ErrorActionPreference = 'Stop'

$IndexPresent = -not [string]::IsNullOrWhiteSpace("$($env:JOB_COMPLETION_INDEX)")
$ShardIndex = if ($IndexPresent) { [int]$env:JOB_COMPLETION_INDEX } else { 0 }
$ShardCount = if (-not [string]::IsNullOrWhiteSpace("$($env:SHARD_COUNT)")) { [int]$env:SHARD_COUNT } else { 1 }

if ($ShardCount -gt 1 -and -not $IndexPresent)
{
    throw "SHARD_COUNT is $ShardCount but JOB_COMPLETION_INDEX is not set, so every pod would run shard 0 and the other $($ShardCount - 1) slice(s) would be silently skipped. Use a Job with 'completionMode: Indexed' (see deploy/k8s/job.yaml), which injects JOB_COMPLETION_INDEX per pod."
}
$HeadRoom = 0
if (-not [string]::IsNullOrWhiteSpace("$($env:HEAD_ROOM)"))
{
    $ParsedHeadRoom = 0
    if ([int]::TryParse("$($env:HEAD_ROOM)", [ref]$ParsedHeadRoom))
    {
        $HeadRoom = $ParsedHeadRoom
    }
    else
    {
        throw "HEAD_ROOM is '$($env:HEAD_ROOM)', which is not an integer. Set HEAD_ROOM to a whole number in [0,90] (leave it unset for the default 0)."
    }
}
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
Write-Host "[entrypoint] NOTE: the federated token is read once at sign-in. If this shard runs longer than the projected Kubernetes token lifetime (default 1h) it can fail on refresh mid-run. Mitigations: raise SHARD_COUNT, set the azure.workload.identity/service-account-token-expiration annotation (max 86400), or re-run with RESUME=true. See deploy/AKS-WorkloadIdentity-Setup.md section 10."

$WrapperArgs = @{
    TenantID   = $TenantId
    ShardCount = $ShardCount
    ShardIndex = $ShardIndex
}
if ($HeadRoom -gt 0) { $WrapperArgs.HeadRoom = $HeadRoom }
if ("$($env:SKIP_METRICS)" -eq 'true') { $WrapperArgs.SkipMetrics = $true }
if ("$($env:SKIP_CONSUMPTION)" -eq 'true') { $WrapperArgs.SkipConsumption = $true }
if ("$($env:RESUME)" -eq 'true') { $WrapperArgs.Resume = $true }
if ("$($env:RESUME_FAILED_ONLY)" -eq 'true') { $WrapperArgs.ResumeFailedOnly = $true }
if ("$($env:ALLOW_PARTIAL_ACCESS)" -eq 'true') { $WrapperArgs.AllowPartialAccess = $true }
if ("$($env:USE_METRICS_BATCH)" -eq 'true') { $WrapperArgs.UseMetricsBatch = $true }
if ("$($env:INCLUDE_STORAGE_METRICS)" -eq 'true') { $WrapperArgs.IncludeStorageMetrics = $true }
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
if (-not [string]::IsNullOrWhiteSpace("$($env:UPLOAD_BLOB_URI)")) { $WrapperArgs.UploadToBlobContainerUri = $env:UPLOAD_BLOB_URI }
$StateBlobUri = if (-not [string]::IsNullOrWhiteSpace("$($env:STATE_BLOB_URI)")) { $env:STATE_BLOB_URI }
elseif (-not [string]::IsNullOrWhiteSpace("$($env:UPLOAD_BLOB_URI)")) { $env:UPLOAD_BLOB_URI }
else { '' }
if (-not [string]::IsNullOrWhiteSpace($StateBlobUri)) { $WrapperArgs.StateBlobContainerUri = $StateBlobUri }

& /rda/Run-AllSubscriptions.ps1 @WrapperArgs
exit $LASTEXITCODE

