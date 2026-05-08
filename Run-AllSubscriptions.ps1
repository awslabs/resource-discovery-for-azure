param (
    [Parameter(Mandatory=$true)]
    [string]$TenantID,
    [switch]$Debug
)

$RunStartTime = Get-Date

az login -t $TenantID --only-show-errors | Out-Null
Connect-AzAccount -Tenant $TenantID | Out-Null

# Get all Azure subscriptions
$subscriptions = Get-AzSubscription

# Pass-through parameters for each inner invocation
$InventoryPassthrough = @{}
if ($Debug.IsPresent) { $InventoryPassthrough['Debug'] = $true }

# Loop through each subscription and run ResourceInventory
foreach ($sub in $subscriptions) {
    Write-Host "Processing subscription: $($sub.Name) ($($sub.Id))" -ForegroundColor Cyan
    
    ./ResourceInventory.ps1 -SubscriptionID $sub.Id @InventoryPassthrough
    
    Write-Host "Completed subscription: $($sub.Name)" -ForegroundColor Green
    Write-Host "-----------------------------------" -ForegroundColor Gray
}

Write-Host "All subscriptions processed!" -ForegroundColor Green

# Consolidate per-subscription ZIPs into a single outer ZIP
$InventoryRoot = if ($PSVersionTable.Platform -eq 'Unix') { "$HOME/InventoryReports" } else { "C:\InventoryReports" }
$OuterZipFile = $null

if (Test-Path -Path $InventoryRoot -PathType Container) {
    $subZips = @(Get-ChildItem -Path $InventoryRoot -Directory | ForEach-Object {
        Get-ChildItem -Path $_.FullName -Filter "*.zip" -File
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
Write-Host ("Execution Time:          {0}" -f $Elapsed.ToString('hh\:mm\:ss')) -ForegroundColor Green
if ($OuterZipFile) {
    Write-Host ("Consolidated Report:     {0}" -f $OuterZipFile) -ForegroundColor Green
}
Write-Host "=========================================" -ForegroundColor Green
