#Requires -Version 7.0
<#
.SYNOPSIS
    In-pod readiness check that proves an AKS worker NODE can authenticate with
    its workload identity and actually reach everything a real RDA shard needs:
    Azure Resource Graph (inventory) and - if you are collecting output centrally
    - WRITE access to the target blob container.

.DESCRIPTION
    Test-MultiNodeReadiness.ps1 checks the OPERATOR's workstation (can they build
    the cluster, do they have the CLI, is an x64 node size available). This script
    is the other half: it runs INSIDE a pod, as the pod's federated workload
    identity, and answers "will a shard on this node actually work?" - which the
    operator-side check cannot know because it depends on the UAMI's RBAC and the
    federated-credential wiring, not the operator's own rights.

    Run it as a one-off preflight Job/pod using the SAME image, ServiceAccount and
    workload-identity label as the real shard Job, but pointing the container
    command at THIS script instead of entrypoint.ps1, e.g.:

        command: ["pwsh","-NoProfile","-File","/rda/deploy/Test-NodeReadiness.ps1"]

    (optionally with -UploadToBlobContainerUri passed as an arg). If every check
    passes, deploy the real indexed Job with confidence; if the UAMI is missing a
    role, this tells you exactly which one before you fan out to N nodes.

    It is READ-MOSTLY: the only write it performs is a tiny probe blob that it
    deletes again immediately, purely to prove Storage Blob Data Contributor is
    effective. It creates no Azure infrastructure.

    Checks, in order:
      1. Workload-identity environment is injected (AZURE_CLIENT_ID /
         AZURE_TENANT_ID / AZURE_FEDERATED_TOKEN_FILE) - i.e. the pod really is
         using the annotated ServiceAccount + azure.workload.identity/use label.
      2. Az.Accounts present and federated sign-in succeeds (Connect-AzAccount
         -ServicePrincipal -FederatedToken) - the exact call entrypoint.ps1 makes.
      3. Az.ResourceGraph present and a Search-AzGraph query succeeds - proves the
         UAMI has Reader somewhere and the inventory phase can run.
      4. Subscription coverage: the count the identity can enumerate
         (Get-AzSubscription) equals the true count under the tenant-root
         management group (Get-AzManagementGroup -Recurse). A shortfall - OR any
         inability to verify the true total - is a HARD FAIL, because a
         per-subscription-scoped identity silently misses subscriptions and this
         tool must capture ALL of them. The robust fix is Reader at the
         tenant-root management group, which inherits to every subscription.
      5. (only if -UploadToBlobContainerUri is given) Az.Storage present and a
         probe blob can be WRITTEN then DELETED via -UseConnectedAccount - proves
         the UAMI has Storage Blob Data Contributor on the collection container,
         which the per-node upload (-UploadToBlobContainerUri) needs.

.PARAMETER UploadToBlobContainerUri
    The same blob container URL you will pass to Run-AllSubscriptions.ps1
    (https://<account>.blob.core.windows.net/<container>[/<prefix>]). When
    supplied, the script proves the node can write AND delete a blob there. Omit
    it if you are not using centralized upload (each node keeps its zip locally).

.EXAMPLE
    # as a preflight pod, inventory + graph only
    pwsh -NoProfile -File /rda/deploy/Test-NodeReadiness.ps1

.EXAMPLE
    # also prove the node can upload to the shared container
    pwsh -NoProfile -File /rda/deploy/Test-NodeReadiness.ps1 `
        -UploadToBlobContainerUri https://mystore.blob.core.windows.net/rda-output

.NOTES
    Exit code 0 = ready (no FAIL checks), 1 = one or more FAIL checks, 2 = the
    check could not run at all (no workload-identity environment - almost always
    means the pod is missing the ServiceAccount or the label).
#>
[CmdletBinding()]
param(
    [string]$UploadToBlobContainerUri
)

$ErrorActionPreference = 'Stop'

# Collected check results: each is { Name, Status (PASS/WARN/FAIL), Detail }.
$Results = [System.Collections.Generic.List[object]]::new()

function Add-Result
{
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('PASS', 'WARN', 'FAIL')][string]$Status,
        [string]$Detail = ''
    )
    $Results.Add([pscustomobject]@{ Name = $Name; Status = $Status; Detail = $Detail })
}

# Mask a caller identity for display. Under workload identity the signed-in
# Account.Id is the UAMI's app (client) id - a real identity value that could
# leak into captured CI/pod logs, so never print it verbatim.
function Get-MaskedIdentity
{
    param([string]$Identity)

    if ([string]::IsNullOrWhiteSpace($Identity)) { return '<unknown>' }
    if ($Identity.Length -gt 6) { return ($Identity.Substring(0, 6) + '***') }
    return '***'
}

# Recursively collect the subscription IDs (each subscription child's .Name is its
# subscription GUID) under a management-group tree returned by Get-AzManagementGroup
# -Expand -Recurse. Subscription children carry a Type like '/subscriptions'; nested
# management-group children carry a 'managementGroups' Type and their own .Children,
# so we recurse into those. Returning the ID SET (not just a count) lets check 4
# compare it directly against the ids the identity can enumerate - which is more
# robust than a raw count (immune to a phantom/transitioning subscription that could
# coincidentally balance a real missing one) and lets it NAME exactly which
# subscriptions would be silently missed. Establishes the TRUE subscription set under
# the tenant-root MG, independent of what the running identity can enumerate via
# Get-AzSubscription. Mirrors Get-RdaMgSubscriptionId in the wrapper's shared
# Functions library so the preflight and the runtime gate use the same logic.
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

Write-Host ''
Write-Host '=== RDA node (in-pod) readiness check - runs as the pod workload identity ===' -ForegroundColor Green
Write-Host ''

# 1. Workload-identity environment present. Without these three the webhook did
#    not inject a token, so the pod is not wired to the ServiceAccount/UAMI at all
#    - every downstream check is moot, so this is the exit-2 "cannot run" gate.
$ClientId = $env:AZURE_CLIENT_ID
$TenantId = $env:AZURE_TENANT_ID
$TokenFile = $env:AZURE_FEDERATED_TOKEN_FILE
$WiEnvPresent = -not ([string]::IsNullOrWhiteSpace($ClientId) -or
    [string]::IsNullOrWhiteSpace($TenantId) -or
    [string]::IsNullOrWhiteSpace($TokenFile))

if ($WiEnvPresent -and (Test-Path -LiteralPath $TokenFile))
{
    Add-Result -Name 'Workload-identity env injected' -Status 'PASS' `
        -Detail ('client {0}, token file present' -f (Get-MaskedIdentity $ClientId))
}
elseif ($WiEnvPresent)
{
    Add-Result -Name 'Workload-identity env injected' -Status 'FAIL' `
        -Detail ("AZURE_FEDERATED_TOKEN_FILE set but '{0}' does not exist - projected token volume missing." -f $TokenFile)
}
else
{
    Add-Result -Name 'Workload-identity env injected' -Status 'FAIL' `
        -Detail 'AZURE_CLIENT_ID / AZURE_TENANT_ID / AZURE_FEDERATED_TOKEN_FILE not all set. Add the annotated ServiceAccount and the azure.workload.identity/use=true pod label.'
}

# 2. Federated sign-in - the exact call entrypoint.ps1 makes for a real shard.
$SignedIn = $false
if ($WiEnvPresent -and (Test-Path -LiteralPath $TokenFile))
{
    $AzAccounts = Get-Module -ListAvailable -Name Az.Accounts | Select-Object -First 1
    if (-not $AzAccounts)
    {
        Add-Result -Name 'Module Az.Accounts' -Status 'FAIL' -Detail 'Not in the image. The azure-powershell base image should include it.'
    }
    else
    {
        Add-Result -Name 'Module Az.Accounts' -Status 'PASS' -Detail $AzAccounts.Version.ToString()
        try
        {
            Import-Module Az.Accounts -ErrorAction Stop
            $Federated = (Get-Content -Raw $TokenFile).Trim()
            Connect-AzAccount -ServicePrincipal -ApplicationId $ClientId -Tenant $TenantId `
                -FederatedToken $Federated -ErrorAction Stop | Out-Null
            $Ctx = Get-AzContext -ErrorAction Stop
            $SignedIn = $true
            Add-Result -Name 'Workload-identity sign-in' -Status 'PASS' `
                -Detail (Get-MaskedIdentity $Ctx.Account.Id)
        }
        catch
        {
            Add-Result -Name 'Workload-identity sign-in' -Status 'FAIL' `
                -Detail ('Connect-AzAccount failed: {0}. Check the federated credential subject is system:serviceaccount:<ns>:<sa>.' -f $_.Exception.Message)
        }
    }
}

# 3. Resource Graph read - proves the UAMI has Reader and the inventory phase can
#    run. An identity with Reader but zero in-scope subscriptions returns an empty
#    result (not an error); that still proves the API call is authorized, so it is
#    a PASS. Only a thrown auth error is a FAIL.
if ($SignedIn)
{
    $AzRg = Get-Module -ListAvailable -Name Az.ResourceGraph | Select-Object -First 1
    if (-not $AzRg)
    {
        Add-Result -Name 'Module Az.ResourceGraph' -Status 'FAIL' -Detail 'Not in the image; the inventory phase (Search-AzGraph) cannot run.'
    }
    else
    {
        Add-Result -Name 'Module Az.ResourceGraph' -Status 'PASS' -Detail $AzRg.Version.ToString()
        try
        {
            Import-Module Az.ResourceGraph -ErrorAction Stop
            $Graph = Search-AzGraph -Query 'Resources | project id | limit 1' -ErrorAction Stop
            $Seen = @($Graph).Count
            if ($Seen -gt 0)
            {
                Add-Result -Name 'Resource Graph read (inventory)' -Status 'PASS' -Detail 'Query returned a resource - Reader is effective.'
            }
            else
            {
                Add-Result -Name 'Resource Graph read (inventory)' -Status 'WARN' `
                    -Detail 'Query authorized but returned no resources. The UAMI can call Resource Graph but currently sees no subscriptions in scope - confirm its Reader assignment covers the target subscriptions.'
            }
        }
        catch
        {
            Add-Result -Name 'Resource Graph read (inventory)' -Status 'FAIL' `
                -Detail ('Search-AzGraph failed: {0}. The UAMI likely lacks Reader on the target scope.' -f $_.Exception.Message)
        }
    }
}

# 4. Subscription coverage (tenant-root management-group scope) - the silent
#    blind-spot guard. Get-AzSubscription only returns subscriptions the identity
#    holds a role on, so an identity scoped per-subscription can SILENTLY MISS
#    subscriptions (a report that looks complete but isn't - at scale, potentially
#    hundreds). The robust fix is Reader at the tenant-root management group, which
#    inherits to every subscription. Here we compare what the identity can ACCESS
#    (Get-AzSubscription) against what the tenant-root MG actually CONTAINS
#    (Get-AzManagementGroup -Recurse). A definite shortfall is a FAIL (subs will be
#    missed). If the MG cannot be read (no management-group read, or Az.Resources
#    absent) the total is unknowable - which is itself a HARD FAIL, not a warning:
#    this tool must capture ALL subscriptions, so an unverifiable coverage claim is
#    unacceptable. The tenant-root MG's GroupId equals the tenant id.
if ($SignedIn)
{
    try
    {
        # Enumerate ALL subscriptions the identity can see (state-agnostic). The MG
        # side (Get-RdaMgSubscriptionId) also collects every subscription child
        # regardless of enabled/disabled state, so the comparison is
        # apples-to-apples: a genuine shortfall reflects a real visibility gap
        # (subscriptions the identity has no role on), not a state mismatch. We
        # compare the actual ID SETS (not just counts), mirroring the wrapper's
        # runtime gate: the missed subscriptions are exactly the ids present under
        # the tenant-root MG but NOT enumerable by this identity, which is immune to
        # a phantom/transitioning subscription coincidentally balancing the counts
        # and lets us NAME which subscriptions would be missed.
        $AccessibleSubs = @(Get-AzSubscription -TenantId $TenantId -ErrorAction Stop)
        $AccessibleCount = $AccessibleSubs.Count

        $MgIds = $null
        try
        {
            $RootMg = Get-AzManagementGroup -GroupName $TenantId -Expand -Recurse -ErrorAction Stop
            $MgIds = @(Get-RdaMgSubscriptionId -Node $RootMg | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
        }
        catch
        {
            # No management-group read (or Az.Resources / Get-AzManagementGroup
            # unavailable): cannot establish the true set. Leave $MgIds null ->
            # HARD FAIL below (unverifiable coverage is not acceptable).
            $MgIds = $null
        }

        if ($null -eq $MgIds)
        {
            # MG set unknowable: the tenant-root management group could not be read -
            # either this identity has no management-group read, or the Az.Resources
            # cmdlet Get-AzManagementGroup is not in the image. Either way
            # completeness cannot be verified, and this tool's purpose is to capture
            # ALL subscriptions, so it is a HARD FAIL, not a warning - proceeding
            # could yield a silently incomplete inventory. The fix (Reader at the
            # tenant-root MG) both guarantees access to every subscription and makes
            # this check verifiable.
            Add-Result -Name 'Subscription coverage (MG scope)' -Status 'FAIL' `
                -Detail ("Cannot verify full subscription coverage: the tenant-root management group could not be read (this identity lacks management-group read, or the Az.Resources module / Get-AzManagementGroup is unavailable), so there is no way to confirm the {0} accessible subscription(s) are ALL of them. Grant the identity Reader at the tenant-root management group (GroupId = tenant id) - it inherits to every subscription AND lets this check confirm coverage - then re-run." -f $AccessibleCount)
        }
        elseif ($MgIds.Count -eq 0)
        {
            # MG read SUCCEEDED but reported zero subscriptions under the root -
            # implausible for a real tenant (there is at least the one this identity
            # signed in against), so the MG tree is not returning true membership
            # and coverage cannot be trusted. Still a HARD FAIL for the same reason.
            Add-Result -Name 'Subscription coverage (MG scope)' -Status 'FAIL' `
                -Detail ("Cannot verify full subscription coverage: the tenant-root management group was read but reported zero subscriptions, while the identity can access {0} - the management-group hierarchy is not returning its true membership, so coverage cannot be confirmed. Grant the identity Reader at the tenant-root management group (GroupId = tenant id) and ensure it can read the full MG hierarchy, then re-run." -f $AccessibleCount)
        }
        else
        {
            # Compare the actual ID SETS: the missed subscriptions are the ones
            # present under the tenant-root MG but NOT enumerable by this identity.
            # Compare case-insensitively - subscription ids are GUIDs but normalise
            # to be safe. If NOTHING under the root MG is missing, coverage is
            # complete by definition (any extra subs the identity sees are still
            # being captured, so they are not a gap); otherwise the missed ids would
            # be SILENTLY dropped - a HARD FAIL, naming them (capped) so the gap is
            # actionable. A subscription mid-transition (e.g. Deleting) can briefly
            # linger in the MG tree while dropping out of Get-AzSubscription; the
            # FAIL message tells the operator to re-run, which clears that edge.
            $AccessibleIdSet = @{}
            foreach ($S in $AccessibleSubs) { $AccessibleIdSet[([string]$S.Id).ToLowerInvariant()] = $true }
            $MissedIds = @($MgIds | Where-Object { -not $AccessibleIdSet.ContainsKey(([string]$_).ToLowerInvariant()) })
            if ($MissedIds.Count -gt 0)
            {
                $ShownMissed = @($MissedIds | Select-Object -First 10)
                $MoreNote = if ($MissedIds.Count -gt $ShownMissed.Count) { (' (+{0} more)' -f ($MissedIds.Count - $ShownMissed.Count)) } else { '' }
                Add-Result -Name 'Subscription coverage (MG scope)' -Status 'FAIL' `
                    -Detail ("Identity can access only {0} of {1} subscription(s) under the tenant-root management group - {2} would be SILENTLY MISSED from the inventory (missed: {3}{4}). Grant Reader at the tenant-root management group (it inherits to all subscriptions) instead of per-subscription, then re-run." -f $AccessibleCount, $MgIds.Count, $MissedIds.Count, ($ShownMissed -join ', '), $MoreNote)
            }
            else
            {
                Add-Result -Name 'Subscription coverage (MG scope)' -Status 'PASS' `
                    -Detail ("Identity can access all {0} subscription(s) under the tenant-root management group - full coverage confirmed." -f $MgIds.Count)
            }
        }
    }
    catch
    {
        # Could not even list subscriptions / evaluate coverage. Cannot guarantee a
        # complete inventory, so fail hard rather than risk a partial run.
        Add-Result -Name 'Subscription coverage (MG scope)' -Status 'FAIL' `
            -Detail ("Could not evaluate subscription coverage ({0}). Grant the identity Reader at the tenant-root management group so full coverage can be confirmed, then re-run." -f $_.Exception.Message)
    }
}

# 5. Blob write+delete - only when centralized upload is requested. Proves the
#    UAMI has Storage Blob Data Contributor on the collection container, which the
#    per-node -UploadToBlobContainerUri upload needs. Uses -UseConnectedAccount
#    (passwordless, same as the real upload); writes a tiny probe blob then
#    deletes it so the check leaves nothing behind.
if ($SignedIn -and -not [string]::IsNullOrWhiteSpace($UploadToBlobContainerUri))
{
    $AzStorage = Get-Module -ListAvailable -Name Az.Storage | Select-Object -First 1
    if (-not $AzStorage)
    {
        Add-Result -Name 'Module Az.Storage' -Status 'FAIL' -Detail 'Not in the image; -UploadToBlobContainerUri cannot upload.'
    }
    else
    {
        Add-Result -Name 'Module Az.Storage' -Status 'PASS' -Detail $AzStorage.Version.ToString()
        # Track the probe artifacts OUTSIDE the try so finally can always clean up,
        # even if the write succeeds but the in-try delete (or anything after it)
        # throws - that window must never leave an orphaned probe blob behind.
        $ProbeFile = $null
        $ProbeContext = $null
        $ProbeBlobName = $null
        $ProbeWritten = $false
        try
        {
            $BlobUri = [System.Uri]$UploadToBlobContainerUri
            $StorageAccountName = $BlobUri.Host.Split('.')[0]
            $PathParts = $BlobUri.AbsolutePath.Trim('/').Split('/', 2)
            $ContainerName = $PathParts[0]
            $BlobPrefix = if ($PathParts.Count -gt 1 -and $PathParts[1]) { $PathParts[1].Trim('/') + '/' } else { '' }
            if ([string]::IsNullOrWhiteSpace($StorageAccountName) -or [string]::IsNullOrWhiteSpace($ContainerName))
            {
                throw "Could not parse '<account>' and '<container>' from '$UploadToBlobContainerUri'."
            }

            # Probe blob is namespaced + GUID-suffixed so it never collides with a
            # real shard artifact and is trivial to spot if a delete ever fails.
            $ProbeBlobName = '{0}_rda-readiness-probe/{1}.txt' -f $BlobPrefix, ([guid]::NewGuid().ToString('N'))
            $ProbeFile = Join-Path ([System.IO.Path]::GetTempPath()) ('rda-probe-{0}.txt' -f ([guid]::NewGuid().ToString('N')))
            Set-Content -LiteralPath $ProbeFile -Value 'rda node readiness probe' -Encoding UTF8

            $ProbeContext = New-AzStorageContext -StorageAccountName $StorageAccountName -UseConnectedAccount -ErrorAction Stop
            $null = Set-AzStorageBlobContent -File $ProbeFile -Container $ContainerName -Blob $ProbeBlobName -Context $ProbeContext -Force -ErrorAction Stop
            $ProbeWritten = $true
            # Delete on the happy path so a PASS genuinely reflects both write AND
            # delete working; a delete failure here is a real permission gap
            # (Storage Blob Data Contributor grants both) so it surfaces as FAIL,
            # and the finally block below still removes the orphan.
            Remove-AzStorageBlob -Container $ContainerName -Blob $ProbeBlobName -Context $ProbeContext -Force -ErrorAction Stop
            $ProbeWritten = $false
            Add-Result -Name 'Blob write+delete (upload)' -Status 'PASS' `
                -Detail ('Wrote and deleted a probe blob in {0}/{1} - Storage Blob Data Contributor is effective.' -f $StorageAccountName, $ContainerName)
        }
        catch
        {
            Add-Result -Name 'Blob write+delete (upload)' -Status 'FAIL' `
                -Detail ('Probe upload failed: {0}. Grant the UAMI "Storage Blob Data Contributor" on the storage account/container.' -f $_.Exception.Message)
        }
        finally
        {
            # Best-effort: if the blob was written but not yet deleted (in-try delete
            # threw), remove it now so the container is left untouched regardless.
            if ($ProbeWritten -and $ProbeContext -and $ProbeBlobName)
            {
                Remove-AzStorageBlob -Container $ContainerName -Blob $ProbeBlobName -Context $ProbeContext -Force -ErrorAction SilentlyContinue
            }
            if ($ProbeFile -and (Test-Path -LiteralPath $ProbeFile)) { Remove-Item -LiteralPath $ProbeFile -Force -ErrorAction SilentlyContinue }
        }
    }
}
elseif ($SignedIn -and [string]::IsNullOrWhiteSpace($UploadToBlobContainerUri))
{
    Add-Result -Name 'Blob write+delete (upload)' -Status 'WARN' `
        -Detail 'Skipped - no -UploadToBlobContainerUri given. Pass it to prove the node can upload; omit only if each node keeps its zip locally.'
}

# --- Render the readiness table -------------------------------------------------
Write-Host ''
foreach ($R in $Results)
{
    $Color = switch ($R.Status) { 'PASS' { 'Green' } 'WARN' { 'Yellow' } 'FAIL' { 'Red' } }
    Write-Host ('  [{0}] {1}' -f $R.Status, $R.Name) -ForegroundColor $Color
    if ($R.Detail) { Write-Host ('         {0}' -f $R.Detail) -ForegroundColor DarkGray }
}

$FailCount = @($Results | Where-Object { $_.Status -eq 'FAIL' }).Count
$WarnCount = @($Results | Where-Object { $_.Status -eq 'WARN' }).Count

Write-Host ''

# Exit 2 = could not run at all: no workload-identity environment, so the pod is
# not federated to any identity and no Azure-side check was meaningful. Distinct
# from exit 1 (federated fine, but a specific capability failed).
if (-not $WiEnvPresent)
{
    Write-Host 'CANNOT RUN: no workload-identity environment in this pod. Ensure it uses the annotated ServiceAccount (serviceAccountName: rda-sa) and the azure.workload.identity/use=true label, then re-run.' -ForegroundColor Red
    exit 2
}

if ($FailCount -eq 0)
{
    Write-Host ("READY: this node can run a shard ({0} warning(s))." -f $WarnCount) -ForegroundColor Green
    exit 0
}
else
{
    Write-Host ("NOT READY: {0} check(s) failed, {1} warning(s). Fix the FAILs (usually a missing UAMI role or federated-credential subject), then re-run." -f $FailCount, $WarnCount) -ForegroundColor Red
    exit 1
}
