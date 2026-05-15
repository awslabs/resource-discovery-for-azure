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

# Authenticate
try {
    if ($DeviceLogin) {
        az login -t $TenantID --use-device-code --only-show-errors | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "az login failed with exit code $LASTEXITCODE" }
        Connect-AzAccount -Tenant $TenantID -UseDeviceAuthentication | Out-Null
    } else {
        az login -t $TenantID --only-show-errors | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "az login failed with exit code $LASTEXITCODE" }
        Connect-AzAccount -Tenant $TenantID | Out-Null
    }
} catch {
    Write-Host "ERROR: Authentication failed. $_" -ForegroundColor Red
    exit 1
}

# Get all Azure subscriptions
$allSubscriptions = Get-AzSubscription

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
