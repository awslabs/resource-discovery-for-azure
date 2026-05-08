param (
    [Parameter(Mandatory=$true)]
    [string]$TenantID
)

az login -t $TenantID --only-show-errors | Out-Null
Connect-AzAccount -Tenant $TenantID | Out-Null

# Get all Azure subscriptions
$subscriptions = Get-AzSubscription

# Loop through each subscription and run ResourceInventory
foreach ($sub in $subscriptions) {
    Write-Host "Processing subscription: $($sub.Name) ($($sub.Id))" -ForegroundColor Cyan
    
    ./ResourceInventory.ps1 -SubscriptionID $sub.Id
    
    Write-Host "Completed subscription: $($sub.Name)" -ForegroundColor Green
    Write-Host "-----------------------------------" -ForegroundColor Gray
}

Write-Host "All subscriptions processed!" -ForegroundColor Green
