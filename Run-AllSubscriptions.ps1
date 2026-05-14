#Requires -Version 7.0

param (
    [Parameter(Mandatory=$true)]
    [string]$TenantID,

    [switch]$DeviceLogin,
    [switch]$Obfuscate,
    [switch]$SkipMetrics,
    [switch]$SkipConsumption
)

$RunStartTime = Get-Date
$FailedSubscriptions = @()

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
$subscriptions = Get-AzSubscription

# Build passthrough hashtable for optional switches
$InventoryPassthrough = @{}
if ($DeviceLogin)      { $InventoryPassthrough['DeviceLogin'] = $true }
if ($Obfuscate)        { $InventoryPassthrough['Obfuscate'] = $true }
if ($SkipMetrics)      { $InventoryPassthrough['SkipMetrics'] = $true }
if ($SkipConsumption)  { $InventoryPassthrough['SkipConsumption'] = $true }
if ($PSBoundParameters.ContainsKey('Debug')) { $InventoryPassthrough['Debug'] = $true }

# Loop through each subscription and run ResourceInventory
$DiagFile = $null
foreach ($sub in $subscriptions) {
    Write-Host "Processing subscription: $($sub.Name) ($($sub.Id))" -ForegroundColor Cyan

    try {
        & (Join-Path $PSScriptRoot "ResourceInventory.ps1") -TenantID $TenantID -SubscriptionID $sub.Id @InventoryPassthrough -RunAllSubs
        if ($LASTEXITCODE -ne 0) { throw "Script exited with code $LASTEXITCODE" }
        Write-Host "Completed subscription: $($sub.Name)" -ForegroundColor Green
    } catch {
        # Surface the full exception chain so failures (e.g. EPPlus Save errors,
        # OOM in long CloudShell runs, file-handle leaks) are diagnosable instead
        # of being summarised to a single line. See #16.
        $errRecord = $_
        Write-Host "ERROR processing subscription $($sub.Name): $errRecord" -ForegroundColor Red

        $diagLines = @()
        $diagLines += "==== Failure for subscription: $($sub.Name) ($($sub.Id)) ===="
        $diagLines += "Timestamp: $(Get-Date -Format 'o')"
        $diagLines += "Message:   $($errRecord.Exception.Message)"
        $diagLines += "Type:      $($errRecord.Exception.GetType().FullName)"

        $inner = $errRecord.Exception.InnerException
        $depth = 0
        while ($null -ne $inner -and $depth -lt 5) {
            $diagLines += "Inner[$depth] Type:    $($inner.GetType().FullName)"
            $diagLines += "Inner[$depth] Message: $($inner.Message)"
            $inner = $inner.InnerException
            $depth++
        }

        if ($null -ne $errRecord.InvocationInfo) {
            $diagLines += "ScriptName:    $($errRecord.InvocationInfo.ScriptName)"
            $diagLines += "Line:          $($errRecord.InvocationInfo.ScriptLineNumber)"
            $diagLines += "PositionMsg:   $($errRecord.InvocationInfo.PositionMessage)"
        }

        $diagLines += "StackTrace:"
        $diagLines += $errRecord.ScriptStackTrace
        if ($null -ne $errRecord.Exception.StackTrace) {
            $diagLines += "ExceptionStackTrace:"
            $diagLines += $errRecord.Exception.StackTrace
        }

        # Environment snapshot — useful when CloudShell runs out of memory or disk
        try {
            $proc = Get-Process -Id $PID
            $diagLines += "Process WorkingSet (MB):  $([math]::Round($proc.WorkingSet64 / 1MB, 1))"
            $diagLines += "Process PrivateMemory (MB): $([math]::Round($proc.PrivateMemorySize64 / 1MB, 1))"
        } catch { }

        try {
            $InventoryRoot = if ($PSVersionTable.Platform -eq 'Unix') { "$HOME/InventoryReports" } else { "C:\InventoryReports" }
            if (Test-Path $InventoryRoot) {
                $rootDrive = (Get-Item $InventoryRoot).PSDrive
                if ($rootDrive) {
                    $diagLines += "Free disk on $($rootDrive.Name): (MB): $([math]::Round($rootDrive.Free / 1MB, 1))"
                }
            }
        } catch { }

        $diagLines += ""

        # Write to a per-run failures file so we don't lose the detail when many subs fail.
        if ($null -eq $DiagFile) {
            $InventoryRoot = if ($PSVersionTable.Platform -eq 'Unix') { "$HOME/InventoryReports" } else { "C:\InventoryReports" }
            if (-not (Test-Path $InventoryRoot)) {
                try { New-Item -ItemType Directory -Path $InventoryRoot -Force | Out-Null } catch { }
            }
            $DiagFile = Join-Path $InventoryRoot ("RunAllSubscriptions_failures_{0}.log" -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'))
        }
        try { $diagLines | Out-File -FilePath $DiagFile -Append -Encoding utf8 } catch { }

        $FailedSubscriptions += $sub.Name
    }

    Write-Host "-----------------------------------" -ForegroundColor Gray
}

Write-Host "All subscriptions processed!" -ForegroundColor Green

# Consolidate per-subscription ZIPs into a single outer ZIP
$InventoryRoot = if ($PSVersionTable.Platform -eq 'Unix') { "$HOME/InventoryReports" } else { "C:\InventoryReports" }
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

# Final summary
$Elapsed = (Get-Date) - $RunStartTime
Write-Host ""
Write-Host "================ Summary ================" -ForegroundColor Green
Write-Host ("Subscriptions Processed: {0}" -f $subscriptions.Count) -ForegroundColor Green
if ($FailedSubscriptions.Count -gt 0) {
    Write-Host ("Subscriptions Failed:    {0} ({1})" -f $FailedSubscriptions.Count, ($FailedSubscriptions -join ', ')) -ForegroundColor Red
    if ($DiagFile -and (Test-Path $DiagFile)) {
        Write-Host ("Failure Diagnostics:     {0}" -f $DiagFile) -ForegroundColor Red
    }
}
Write-Host ("Execution Time:          {0}" -f $Elapsed.ToString('hh\:mm\:ss')) -ForegroundColor Green
if ($OuterZipFile) {
    Write-Host ("Consolidated Report:     {0}" -f $OuterZipFile) -ForegroundColor Green
}
Write-Host "=========================================" -ForegroundColor Green
