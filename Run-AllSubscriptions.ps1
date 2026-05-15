#Requires -Version 7.0

param (
    [Parameter(Mandatory=$true)]
    [string]$TenantID,

    [switch]$DeviceLogin,
    [switch]$Obfuscate,
    [switch]$SkipMetrics,
    [switch]$SkipConsumption,
    [switch]$Resume,
    [switch]$IncludeDisabled
)

$RunStartTime = Get-Date
$FailedSubscriptions = @()

# Resolve a tenant identifier to a tenant GUID.
#
# -TenantID may be passed as either a GUID (the canonical form) or as a verified
# domain (e.g. "contoso.onmicrosoft.com" or "contoso.com"). When given a domain,
# resolve it to the GUID via Microsoft's public OIDC discovery endpoint:
#
#   https://login.microsoftonline.com/<domain>/v2.0/.well-known/openid-configuration
#
# That endpoint is anonymous (no sign-in required) and returns a JSON document
# whose "issuer" field embeds the tenant GUID. Resolving up front means every
# downstream call (az login, Get-AzSubscription, the resume state filename, the
# auth gate) operates on a stable identifier even if Azure later renames the
# domain.
function Resolve-TenantId {
    param([Parameter(Mandatory=$true)][string]$Value)

    $guidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    if ($Value -match $guidPattern) { return $Value }

    $url = "https://login.microsoftonline.com/$Value/v2.0/.well-known/openid-configuration"
    Write-Host ("Resolving tenant '{0}' via OIDC discovery..." -f $Value) -ForegroundColor Cyan
    try {
        $config = Invoke-RestMethod -Uri $url -Method Get -ErrorAction Stop
    } catch {
        throw "Could not resolve tenant '$Value' to a GUID. Check that it is a valid Azure AD domain or pass the tenant GUID directly. Underlying error: $($_.Exception.Message)"
    }

    if ($null -eq $config -or [string]::IsNullOrWhiteSpace($config.issuer)) {
        throw "OIDC discovery for tenant '$Value' returned an unexpected response (no issuer)."
    }

    # issuer looks like https://login.microsoftonline.com/<guid>/v2.0
    $segments = $config.issuer -split '/'
    $resolved = $segments | Where-Object { $_ -match $guidPattern } | Select-Object -First 1
    if (-not $resolved) {
        throw "OIDC discovery for tenant '$Value' did not contain a recognizable tenant GUID. issuer='$($config.issuer)'"
    }

    Write-Host ("Resolved tenant '{0}' -> {1}" -f $Value, $resolved) -ForegroundColor Green
    return $resolved
}

try {
    $TenantID = Resolve-TenantId -Value $TenantID
} catch {
    Write-Host ("ERROR: {0}" -f $_.Exception.Message) -ForegroundColor Red
    exit 1
}

# Inventory root (used for resume state and consolidated output)
$InventoryRoot = if ($PSVersionTable.Platform -eq 'Unix') { "$HOME/InventoryReports" } else { "C:\InventoryReports" }
if (-not (Test-Path -Path $InventoryRoot -PathType Container)) {
    try { New-Item -Path $InventoryRoot -ItemType Directory -Force | Out-Null } catch { }
}

# Resume state helpers
$ResumeStateFile = Join-Path $InventoryRoot (".resume-state-{0}.json" -f $TenantID)

function Get-CompletedSubscriptionIds {
    param([string]$Path, [string]$Tenant)

    if (-not (Test-Path -Path $Path -PathType Leaf)) { return @() }
    try {
        $state = Get-Content -Path $Path -Raw | ConvertFrom-Json
        if ($state.TenantID -ne $Tenant) {
            Write-Host ("Resume state file is for a different tenant ({0}); ignoring." -f $state.TenantID) -ForegroundColor Yellow
            return @()
        }
        if ($null -eq $state.CompletedSubscriptionIds) { return @() }
        return @($state.CompletedSubscriptionIds)
    } catch {
        Write-Host ("Could not read resume state file ({0}); starting fresh. $_" -f $Path) -ForegroundColor Yellow
        return @()
    }
}

function Save-CompletedSubscriptionIds {
    param([string]$Path, [string]$Tenant, [string[]]$Ids)

    $state = [pscustomobject]@{
        TenantID                  = $Tenant
        CompletedSubscriptionIds  = @($Ids)
        LastUpdated               = (Get-Date).ToString('o')
    }
    try {
        $state | ConvertTo-Json -Depth 4 | Set-Content -Path $Path -Encoding utf8
    } catch {
        Write-Host ("WARNING: Failed to persist resume state to {0}: $_" -f $Path) -ForegroundColor Yellow
    }
}

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

function Get-AzCliSignedInTenant {
    $raw = az account show --output json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) { return $null }
    try { return ($raw | ConvertFrom-Json).tenantId } catch { return $null }
}

function Get-AzPsSignedInTenant {
    try {
        $ctx = Get-AzContext -ErrorAction Stop
        if ($null -eq $ctx -or $null -eq $ctx.Account) { return $null }
        return $ctx.Tenant.Id
    } catch {
        return $null
    }
}

# Probe whether az CLI can silently acquire a token for $TenantID.
# Returns $true on success, $false on any failure.
function Test-AzCliTokenSilent {
    param([Parameter(Mandatory=$true)][string]$Tenant)
    az account get-access-token --tenant $Tenant --output none 2>$null
    return ($LASTEXITCODE -eq 0)
}

# Probe whether Az PowerShell can silently acquire a token for $TenantID.
# Get-AzAccessToken in this configuration emits a non-terminating warning
# instead of throwing on token-acquisition failure, so we capture warnings
# explicitly and treat any warning as a failure signal in addition to
# catching outright exceptions.
function Test-AzPsTokenSilent {
    param([Parameter(Mandatory=$true)][string]$Tenant)
    $warnings = @()
    try {
        $token = Get-AzAccessToken -TenantId $Tenant -ErrorAction Stop -WarningVariable warnings -WarningAction SilentlyContinue
        if ($null -eq $token -or [string]::IsNullOrWhiteSpace($token.Token)) { return $false }
        if ($warnings.Count -gt 0) { return $false }
        return $true
    } catch {
        return $false
    }
}

try {
    $cliTenant = Get-AzCliSignedInTenant
    $psTenant  = Get-AzPsSignedInTenant

    $cliTenantOk = ($cliTenant -eq $TenantID)
    $psTenantOk  = ($psTenant  -eq $TenantID)

    $cliTokenOk = $false
    $psTokenOk  = $false
    if ($cliTenantOk) { $cliTokenOk = Test-AzCliTokenSilent -Tenant $TenantID }
    if ($psTenantOk)  { $psTokenOk  = Test-AzPsTokenSilent  -Tenant $TenantID }

    $cliOk = $cliTenantOk -and $cliTokenOk
    $psOk  = $psTenantOk  -and $psTokenOk

    if ($cliOk -and $psOk) {
        Write-Host ("Existing session detected for tenant {0} (token probe ok); skipping interactive login." -f $TenantID) -ForegroundColor Green
    } else {
        if (-not $cliOk) {
            if ($null -eq $cliTenant) {
                Write-Host "az CLI is not signed in; authenticating..." -ForegroundColor Cyan
            } elseif (-not $cliTenantOk) {
                Write-Host ("az CLI is signed in to tenant {0}; switching to {1}..." -f $cliTenant, $TenantID) -ForegroundColor Cyan
            } else {
                Write-Host ("az CLI session for tenant {0} cannot acquire a token silently (likely expired or CA/MFA-gated); re-authenticating..." -f $TenantID) -ForegroundColor Cyan
            }
            if ($DeviceLogin) {
                az login -t $TenantID --use-device-code --only-show-errors | Out-Null
            } else {
                az login -t $TenantID --only-show-errors | Out-Null
            }
            if ($LASTEXITCODE -ne 0) { throw "az login failed with exit code $LASTEXITCODE" }
        }

        if (-not $psOk) {
            if ($null -eq $psTenant) {
                Write-Host "Az PowerShell is not signed in; authenticating..." -ForegroundColor Cyan
            } elseif (-not $psTenantOk) {
                Write-Host ("Az PowerShell is signed in to tenant {0}; switching to {1}..." -f $psTenant, $TenantID) -ForegroundColor Cyan
            } else {
                Write-Host ("Az PowerShell session for tenant {0} cannot acquire a token silently (likely expired or CA/MFA-gated); re-authenticating..." -f $TenantID) -ForegroundColor Cyan
            }
            if ($DeviceLogin) {
                Connect-AzAccount -Tenant $TenantID -UseDeviceAuthentication | Out-Null
            } else {
                Connect-AzAccount -Tenant $TenantID | Out-Null
            }
        }
    }
} catch {
    Write-Host "ERROR: Authentication failed. $_" -ForegroundColor Red
    exit 1
}

# Get all Azure subscriptions.
#
# Get-AzSubscription emits warnings (rather than throwing) when token
# acquisition for a tenant fails - typically due to CA/MFA gating. In that
# state the cmdlet returns no subscriptions, which would otherwise cause
# this wrapper to report "All subscriptions processed!" with an empty
# inventory. Capture warnings and treat zero-results-with-warnings as a
# loud failure instead of a silent one.
$subWarnings = @()
$allSubscriptions = Get-AzSubscription -TenantId $TenantID -WarningVariable subWarnings -WarningAction SilentlyContinue
if ($null -eq $allSubscriptions) { $allSubscriptions = @() }
$allSubscriptions = @($allSubscriptions)

if ($allSubscriptions.Count -eq 0) {
    Write-Host ("ERROR: Get-AzSubscription returned no subscriptions for tenant {0}." -f $TenantID) -ForegroundColor Red
    if ($subWarnings.Count -gt 0) {
        Write-Host "Underlying warnings:" -ForegroundColor Red
        foreach ($w in $subWarnings) { Write-Host ("  - {0}" -f $w) -ForegroundColor Red }
        Write-Host "This typically indicates the cached session cannot acquire a token (Conditional Access / MFA), or the signed-in identity has no access to any subscription in this tenant." -ForegroundColor Yellow
        Write-Host "Try re-running with -DeviceLogin, or sign out and sign back in to the requested tenant." -ForegroundColor Yellow
    } else {
        Write-Host "The signed-in identity may have no subscriptions in this tenant. Verify with 'Get-AzSubscription -TenantId <id>' interactively." -ForegroundColor Yellow
    }
    exit 1
}

# Filter out non-Enabled subscriptions by default. Disabled / Warned / Deleted
# subscriptions return little-to-no data from Resource Graph and most ARM
# data-plane calls, so processing them produces near-empty per-subscription
# reports while still costing wall-clock time (which matters for environments
# like Azure Cloud Shell where the session has a hard maximum lifetime).
# Pass -IncludeDisabled to inventory every subscription regardless of state.
if ($IncludeDisabled) {
    $subscriptions = $allSubscriptions
    $excluded = @()
} else {
    $subscriptions = @($allSubscriptions | Where-Object { $_.State -eq 'Enabled' })
    $excluded     = @($allSubscriptions | Where-Object { $_.State -ne 'Enabled' })
}

Write-Host ("Subscriptions visible: {0}" -f $allSubscriptions.Count) -ForegroundColor Cyan
if ($excluded.Count -gt 0) {
    $byState = $excluded | Group-Object -Property State | ForEach-Object { ('{0}: {1}' -f $_.Name, $_.Count) }
    Write-Host ("Excluded {0} non-Enabled subscription(s) [{1}]. Use -IncludeDisabled to inventory them anyway." -f $excluded.Count, ($byState -join ', ')) -ForegroundColor Yellow
}
Write-Host ("Subscriptions to process: {0}" -f $subscriptions.Count) -ForegroundColor Cyan

# Apply resume filter (only when -Resume is explicitly passed)
$CompletedIds = @()
if ($Resume) {
    $CompletedIds = Get-CompletedSubscriptionIds -Path $ResumeStateFile -Tenant $TenantID
    if ($CompletedIds.Count -gt 0) {
        Write-Host ("Resume mode: {0} previously completed subscription(s) will be skipped." -f $CompletedIds.Count) -ForegroundColor Cyan
    } else {
        Write-Host "Resume mode: no previous state found; processing all subscriptions." -ForegroundColor Cyan
    }
} else {
    # Without -Resume, do not auto-skip. Inform the user if stale state exists.
    if (Test-Path -Path $ResumeStateFile -PathType Leaf) {
        Write-Host ("Note: resume state file exists at {0}. Pass -Resume to skip previously completed subscriptions." -f $ResumeStateFile) -ForegroundColor Yellow
    }
}

# Build passthrough hashtable for optional switches
$InventoryPassthrough = @{}
if ($DeviceLogin)      { $InventoryPassthrough['DeviceLogin'] = $true }
if ($Obfuscate)        { $InventoryPassthrough['Obfuscate'] = $true }
if ($SkipMetrics)      { $InventoryPassthrough['SkipMetrics'] = $true }
if ($SkipConsumption)  { $InventoryPassthrough['SkipConsumption'] = $true }
if ($PSBoundParameters.ContainsKey('Debug')) { $InventoryPassthrough['Debug'] = $true }

# Loop through each subscription and run ResourceInventory
$SkippedCount = 0
foreach ($sub in $subscriptions) {
    if ($Resume -and ($CompletedIds -contains $sub.Id)) {
        Write-Host ("Skipping (already completed): {0} ({1})" -f $sub.Name, $sub.Id) -ForegroundColor DarkGray
        $SkippedCount++
        continue
    }

    Write-Host "Processing subscription: $($sub.Name) ($($sub.Id))" -ForegroundColor Cyan

    try {
        & (Join-Path $PSScriptRoot "ResourceInventory.ps1") -TenantID $TenantID -SubscriptionID $sub.Id @InventoryPassthrough -RunAllSubs
        if ($LASTEXITCODE -ne 0) { throw "Script exited with code $LASTEXITCODE" }
        Write-Host "Completed subscription: $($sub.Name)" -ForegroundColor Green

        # Mark complete and persist immediately so a mid-run sign-out is recoverable.
        if (-not ($CompletedIds -contains $sub.Id)) {
            $CompletedIds += $sub.Id
            Save-CompletedSubscriptionIds -Path $ResumeStateFile -Tenant $TenantID -Ids $CompletedIds
        }
    } catch {
        Write-Host "ERROR processing subscription $($sub.Name): $_" -ForegroundColor Red
        $FailedSubscriptions += $sub.Name
    }

    Write-Host "-----------------------------------" -ForegroundColor Gray
}

Write-Host "All subscriptions processed!" -ForegroundColor Green

# Consolidate per-subscription ZIPs into a single outer ZIP
$OuterZipFile = $null

if (Test-Path -Path $InventoryRoot -PathType Container) {
    # Filter ZIPs by current run timestamp only
    $subZips = @(Get-ChildItem -Path $InventoryRoot -Directory | ForEach-Object {
        Get-ChildItem -Path $_.FullName -Filter "*.zip" -File |
            Where-Object { $_.LastWriteTime -ge $RunStartTime }
    })

    if ($subZips.Count -gt 0) {
        $Timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
        $OuterZipFile = Join-Path $InventoryRoot "AllSubscriptions_ResourcesReport_$Timestamp.zip"

        Write-Host ("Compressing {0} per-subscription report(s) into: {1}" -f $subZips.Count, $OuterZipFile) -ForegroundColor Cyan
        Compress-Archive -Path $subZips.FullName -DestinationPath $OuterZipFile -Force

        Write-Host ("Reporting Data File: {0}" -f $OuterZipFile) -ForegroundColor Green
    } else {
        Write-Host ("No per-subscription zip files found under {0} to consolidate." -f $InventoryRoot) -ForegroundColor Yellow
    }
} else {
    Write-Host ("Inventory root not found at {0}. Nothing to consolidate." -f $InventoryRoot) -ForegroundColor Yellow
}

# Clean up resume state on a fully successful run (all subs processed, no failures).
# Otherwise leave it so the next invocation with -Resume can pick up where this stopped.
if ($FailedSubscriptions.Count -eq 0 -and (Test-Path -Path $ResumeStateFile -PathType Leaf)) {
    try {
        Remove-Item -Path $ResumeStateFile -Force
        Write-Host "Resume state cleared (clean run)." -ForegroundColor Green
    } catch {
        Write-Host ("WARNING: Could not remove resume state file {0}: $_" -f $ResumeStateFile) -ForegroundColor Yellow
    }
}

# Final summary
$Elapsed = (Get-Date) - $RunStartTime
Write-Host ""
Write-Host "================ Summary ================" -ForegroundColor Green
Write-Host ("Subscriptions Visible:   {0}" -f $allSubscriptions.Count) -ForegroundColor Green
if ($excluded.Count -gt 0) {
    Write-Host ("Subscriptions Excluded:  {0} (non-Enabled; use -IncludeDisabled to inventory them)" -f $excluded.Count) -ForegroundColor Green
}
Write-Host ("Subscriptions Eligible:  {0}" -f $subscriptions.Count) -ForegroundColor Green
if ($Resume) {
    Write-Host ("Subscriptions Skipped:   {0} (already completed)" -f $SkippedCount) -ForegroundColor Green
}
Write-Host ("Subscriptions Processed: {0}" -f ($subscriptions.Count - $SkippedCount)) -ForegroundColor Green
if ($FailedSubscriptions.Count -gt 0) {
    Write-Host ("Subscriptions Failed:    {0} ({1})" -f $FailedSubscriptions.Count, ($FailedSubscriptions -join ', ')) -ForegroundColor Red
    Write-Host ("Resume State:            {0}" -f $ResumeStateFile) -ForegroundColor Yellow
    Write-Host "Re-run with -Resume to retry failed and any unprocessed subscriptions." -ForegroundColor Yellow
}
Write-Host ("Execution Time:          {0}" -f $Elapsed.ToString('hh\:mm\:ss')) -ForegroundColor Green
if ($OuterZipFile) {
    Write-Host ("Consolidated Report:     {0}" -f $OuterZipFile) -ForegroundColor Green
}
Write-Host "=========================================" -ForegroundColor Green
