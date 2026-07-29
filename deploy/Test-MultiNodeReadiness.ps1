#Requires -Version 7.0
<#
.SYNOPSIS
    Read-only preflight readiness check for running Resource Discovery for Azure
    (RDA) as a MULTI-NODE horizontal-scale-out workload on AKS.

.DESCRIPTION
    Multi-node scale-out (see docs/horizontal-sharding.md) partitions the tenant's
    subscriptions across N independent worker pods, each running
    Run-AllSubscriptions.ps1 with a distinct -ShardIndex. It finishes a large
    tenant far faster than a single machine, but it needs MORE Azure access than a
    single laptop run: an identity the pods federate to, permission to stand up the
    cluster, and a place to collect each node's output.

    This script CHECKS - it never creates, changes, or deletes anything. It reports
    a PASS / WARN / FAIL readiness table so an operator knows what is missing before
    they follow the setup in docs/horizontal-sharding.md. It is safe to run as often
    as you like.

    It verifies, on THIS workstation / for the target subscription:
      1. PowerShell 7+.
      2. Azure CLI present and signed in (the documented AKS setup uses `az`).
      3. Az PowerShell modules the tool itself needs (Az.Accounts, Az.ResourceGraph).
      4. The resource providers AKS + ACR need are registered.
      5. An x64 node VM size is actually available in the target region (some
         subscriptions/regions only offer Arm64 B-series, which the amd64 container
         image cannot run on - this bit us in testing with Standard_B2s).
      6. Whether the signed-in caller can create the infrastructure (Contributor or
         Owner) and wire up workload identity (role assignments / federated creds,
         i.e. Owner or User Access Administrator).

    It also PRINTS the exact Azure RBAC the worker identity (UAMI) will need, so the
    platform team can request it up front.

.PARAMETER Location
    Azure region to check node-size availability in (e.g. eastus). Required.

.PARAMETER NodeVmSize
    The x64 node size you intend to use for the AKS node pool. Default
    Standard_D2s_v3 (a small, widely-available x64 size). The check fails if the
    size is unavailable or restricted in the target region.

.PARAMETER SubscriptionId
    Subscription to check against. Defaults to the current Az context subscription.

.EXAMPLE
    ./deploy/Test-MultiNodeReadiness.ps1 -Location eastus

.NOTES
    Read-only. Exit code 0 = ready (no FAIL checks), 1 = one or more FAIL checks,
    2 = the check could not run (e.g. not signed in at all).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Location,

    [string]$NodeVmSize = 'Standard_D2s_v3',

    [string]$SubscriptionId
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

# Mask a caller identity for display. Account.Id is usually a UPN/email (user) or
# an app id (service principal) - real identity PII that could leak into captured
# CI logs, so never print it verbatim.
function Get-MaskedIdentity
{
    param([string]$Identity)

    if ([string]::IsNullOrWhiteSpace($Identity)) { return '<unknown>' }
    if ($Identity -match '^(.)(.*)(@.+)$')
    {
        # UPN: keep first char + domain, mask the local part.
        return ('{0}***{1}' -f $Matches[1], $Matches[3])
    }
    # Service-principal app id / GUID: keep a short prefix only.
    if ($Identity.Length -gt 6) { return ($Identity.Substring(0, 6) + '***') }
    return '***'
}

Write-Host ''
Write-Host '=== RDA multi-node (AKS) readiness check - read-only, nothing is created ===' -ForegroundColor Green
Write-Host ''

# 1. PowerShell 7+
if ($PSVersionTable.PSVersion.Major -ge 7)
{
    Add-Result -Name 'PowerShell 7+' -Status 'PASS' -Detail $PSVersionTable.PSVersion.ToString()
}
else
{
    Add-Result -Name 'PowerShell 7+' -Status 'FAIL' -Detail "Found $($PSVersionTable.PSVersion); install PowerShell 7+."
}

# 2. Azure CLI present + signed in (the AKS setup commands use `az`).
$AzCli = Get-Command az -ErrorAction SilentlyContinue
if (-not $AzCli)
{
    Add-Result -Name 'Azure CLI installed' -Status 'FAIL' -Detail 'az not found on PATH. Install from https://aka.ms/azcli.'
}
else
{
    Add-Result -Name 'Azure CLI installed' -Status 'PASS' -Detail $AzCli.Source
    # `az account show` returns non-zero when not logged in.
    $null = az account show 2>$null
    if ($LASTEXITCODE -eq 0)
    {
        Add-Result -Name 'Azure CLI signed in' -Status 'PASS' -Detail 'az account show succeeded.'
    }
    else
    {
        Add-Result -Name 'Azure CLI signed in' -Status 'FAIL' -Detail 'Run: az login'
    }
}

# 3. Az PowerShell context + the modules the tool needs.
$Context = $null
try
{
    $Context = Get-AzContext -ErrorAction Stop
}
catch
{
    $Context = $null
}
if (-not $Context)
{
    Add-Result -Name 'Az PowerShell signed in' -Status 'FAIL' -Detail 'Run: Connect-AzAccount'
}
else
{
    Add-Result -Name 'Az PowerShell signed in' -Status 'PASS' -Detail (Get-MaskedIdentity $Context.Account.Id)
}

# Az.Accounts + Az.ResourceGraph are what the RDA tool itself needs; Az.Resources
# (Get-AzResourceProvider / Get-AzRoleAssignment) and Az.Compute
# (Get-AzComputeResourceSku) are what THIS preflight's own checks call - verify
# all four so a missing dependency is an actionable FAIL rather than an opaque WARN.
foreach ($Module in 'Az.Accounts', 'Az.ResourceGraph', 'Az.Resources', 'Az.Compute')
{
    $Found = Get-Module -ListAvailable -Name $Module | Select-Object -First 1
    if ($Found)
    {
        Add-Result -Name ("Module {0}" -f $Module) -Status 'PASS' -Detail $Found.Version.ToString()
    }
    else
    {
        Add-Result -Name ("Module {0}" -f $Module) -Status 'FAIL' -Detail ("Install-Module {0} -Scope CurrentUser" -f $Module)
    }
}

# Resolve the target subscription for the remaining checks.
if (-not $SubscriptionId -and $Context) { $SubscriptionId = $Context.Subscription.Id }

# 4. Resource providers AKS + ACR require.
foreach ($Provider in 'Microsoft.ContainerService', 'Microsoft.ContainerRegistry')
{
    try
    {
        $State = (Get-AzResourceProvider -ProviderNamespace $Provider -ErrorAction Stop |
            Select-Object -First 1).RegistrationState
        if ($State -eq 'Registered')
        {
            Add-Result -Name ("Provider {0}" -f $Provider) -Status 'PASS' -Detail 'Registered'
        }
        else
        {
            Add-Result -Name ("Provider {0}" -f $Provider) -Status 'FAIL' `
                -Detail ("State '{0}'. Register with: az provider register -n {1}" -f $State, $Provider)
        }
    }
    catch
    {
        Add-Result -Name ("Provider {0}" -f $Provider) -Status 'WARN' `
            -Detail ("Could not query ({0}). Check manually: az provider show -n {1}" -f $_.Exception.Message, $Provider)
    }
}

# 5. An x64 node VM size is actually available in the target region.
#    WHY: some subscriptions/regions only offer Arm64 B-series (e.g. Standard_B2s
#    was rejected as "not allowed" in testing) and the amd64 PowerShell container
#    image cannot be scheduled on Arm64 nodes. Confirm the chosen x64 size is
#    offered AND not restricted before the AKS create.
try
{
    $Sku = Get-AzComputeResourceSku -Location $Location -ErrorAction Stop |
        Where-Object { $_.ResourceType -eq 'virtualMachines' -and $_.Name -eq $NodeVmSize } |
        Select-Object -First 1
    if (-not $Sku)
    {
        Add-Result -Name ("Node size {0} in {1}" -f $NodeVmSize, $Location) -Status 'FAIL' `
            -Detail 'Not offered in this region. List options: az vm list-skus --location <loc> --resource-type virtualMachines -o table'
    }
    else
    {
        # Distinguish restriction SCOPE. A 'Location'-type restriction means the
        # size is not available for this subscription in the region at all (this is
        # what blocked Standard_B2s in testing) -> FAIL. A 'Zone'-type restriction
        # only removes some availability zones; the size is still creatable (AKS
        # lands it in an available zone or non-zonally, as Standard_D2s_v3 did in
        # testing) -> WARN, not a blocker.
        $LocationRestricted = @($Sku.Restrictions | Where-Object { $_.Type -eq 'Location' }).Count -gt 0
        $ZoneRestricted = @($Sku.Restrictions | Where-Object { $_.Type -eq 'Zone' }).Count -gt 0
        if ($LocationRestricted)
        {
            Add-Result -Name ("Node size {0} in {1}" -f $NodeVmSize, $Location) -Status 'FAIL' `
                -Detail 'Not available for this subscription in this region (region-level restriction). Pick another x64 size or request quota.'
        }
        elseif ($ZoneRestricted)
        {
            Add-Result -Name ("Node size {0} in {1}" -f $NodeVmSize, $Location) -Status 'WARN' `
                -Detail 'Available, but restricted in some availability zones. Creatable (AKS selects an available zone); pin zones only if you require specific ones.'
        }
        else
        {
            Add-Result -Name ("Node size {0} in {1}" -f $NodeVmSize, $Location) -Status 'PASS' -Detail 'Available and unrestricted.'
        }
    }
}
catch
{
    Add-Result -Name ("Node size {0} in {1}" -f $NodeVmSize, $Location) -Status 'WARN' `
        -Detail ("Could not query SKUs ({0})." -f $_.Exception.Message)
}

# 6. Can the signed-in caller create the infra and wire up workload identity?
#    Creating AKS/ACR needs Contributor (or Owner) on the subscription/RG.
#    Creating role assignments + federated credentials for workload identity needs
#    Owner or User Access Administrator. We check the caller's role assignments at
#    subscription scope - a WARN (not FAIL) when absent, since the rights may be
#    granted at a management-group or resource-group scope this check can't see.
if ($Context -and $SubscriptionId)
{
    try
    {
        $Scope = "/subscriptions/$SubscriptionId"
        # A service-principal context (e.g. a CI identity) does not resolve via
        # -SignInName (that is for user UPNs); query by -ApplicationId instead so
        # the RBAC check is meaningful for both user and SP callers.
        if ($Context.Account.Type -eq 'ServicePrincipal')
        {
            $MyRoles = @(Get-AzRoleAssignment -ApplicationId $Context.Account.Id -Scope $Scope -ErrorAction Stop |
                Select-Object -ExpandProperty RoleDefinitionName)
        }
        else
        {
            $MyRoles = @(Get-AzRoleAssignment -SignInName $Context.Account.Id -Scope $Scope -ErrorAction Stop |
                Select-Object -ExpandProperty RoleDefinitionName)
        }
        $CanCreate = $MyRoles -contains 'Owner' -or $MyRoles -contains 'Contributor'
        $CanAssign = $MyRoles -contains 'Owner' -or $MyRoles -contains 'User Access Administrator'

        if ($CanCreate)
        {
            Add-Result -Name 'Rights to create AKS/ACR' -Status 'PASS' -Detail (($MyRoles | Sort-Object -Unique) -join ', ')
        }
        else
        {
            Add-Result -Name 'Rights to create AKS/ACR' -Status 'WARN' `
                -Detail 'No Owner/Contributor seen at subscription scope (may be granted at MG/RG scope).'
        }

        if ($CanAssign)
        {
            Add-Result -Name 'Rights to grant workload-identity RBAC' -Status 'PASS' -Detail 'Owner or User Access Administrator.'
        }
        else
        {
            Add-Result -Name 'Rights to grant workload-identity RBAC' -Status 'WARN' `
                -Detail 'Need Owner or User Access Administrator to create role assignments + federated credentials.'
        }
    }
    catch
    {
        Add-Result -Name 'Caller RBAC' -Status 'WARN' -Detail ("Could not read role assignments ({0})." -f $_.Exception.Message)
    }
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
Write-Host 'Worker identity (UAMI) RBAC required for multi-node - grant these before deploying:' -ForegroundColor Cyan
Write-Host '  - Reader                        (inventory)                 at tenant-root MG or per subscription' -ForegroundColor Gray
Write-Host '  - Cost Management Reader         (consumption)              at the billing/subscription scope' -ForegroundColor Gray
Write-Host '  - Monitoring Reader             (metrics)                  at the subscription scope' -ForegroundColor Gray
Write-Host '  - Storage Blob Data Contributor (output upload)            on the collection storage account' -ForegroundColor Gray
Write-Host ''

# Exit 2 = the check could not meaningfully run: not signed in to Azure at all
# (neither an Az PowerShell context nor an az CLI session), so every Azure-side
# check is moot. Distinct from exit 1 (signed in, but a specific requirement failed).
$AzurePsOk = @($Results | Where-Object { $_.Name -eq 'Az PowerShell signed in' -and $_.Status -eq 'PASS' }).Count -gt 0
$AzCliOk = @($Results | Where-Object { $_.Name -eq 'Azure CLI signed in' -and $_.Status -eq 'PASS' }).Count -gt 0
if (-not $AzurePsOk -and -not $AzCliOk)
{
    Write-Host 'CANNOT RUN: not signed in to Azure (no Az PowerShell context and az not signed in). Sign in (Connect-AzAccount / az login), then re-run.' -ForegroundColor Red
    exit 2
}

if ($FailCount -eq 0)
{
    Write-Host ("READY: no blocking checks failed ({0} warning(s)). Follow docs/horizontal-sharding.md." -f $WarnCount) -ForegroundColor Green
    exit 0
}
else
{
    Write-Host ("NOT READY: {0} check(s) failed, {1} warning(s). Resolve the FAILs above, then re-run." -f $FailCount, $WarnCount) -ForegroundColor Red
    exit 1
}
