# Step 2 E2E: the per-subscription scoping must still collect the TARGET subscription's billing data
# when the process's current context is on a DIFFERENT subscription. Runs ResourceInventory.ps1 from a
# given tree on <target> with the process default deliberately on <decoy>, then prints what it wrote.
param([Parameter(Mandatory)] [string]$Tree, [Parameter(Mandatory)] [string]$TargetSubName, [Parameter(Mandatory)] [string]$DecoySubName, [Parameter(Mandatory)] [string]$Label)
$ErrorActionPreference = 'Stop'
Import-Module Az.Accounts -WarningAction SilentlyContinue
$Target = Get-AzSubscription -SubscriptionName $TargetSubName -WarningAction SilentlyContinue
$Decoy = Get-AzSubscription -SubscriptionName $DecoySubName -WarningAction SilentlyContinue
$null = Set-AzContext -Subscription $Decoy.Id -Scope Process -WarningAction SilentlyContinue
'[{0}] process context before the run: {1}' -f $Label, (Get-AzContext).Subscription.Name
$Before = @(Get-ChildItem -LiteralPath (Join-Path $HOME 'InventoryReports') -Directory | ForEach-Object { $_.FullName })
& (Join-Path $Tree 'ResourceInventory.ps1') -TenantID $Target.TenantId -SubscriptionID $Target.Id -ReportName $Label -SkipMetrics *> $null
'[{0}] process context after the run: {1}' -f $Label, (Get-AzContext).Subscription.Name
$New = @(Get-ChildItem -LiteralPath (Join-Path $HOME 'InventoryReports') -Directory | Where-Object { $_.FullName -notin $Before })
$Csv = Get-ChildItem -LiteralPath $New.FullName -Filter 'Consumption_*.csv' -Recurse | Select-Object -First 1
$Rows = @(Import-Csv -LiteralPath $Csv.FullName)
$SubIds = @($Rows | ForEach-Object { if ("$($_.AdditionalInfo)$($_.ResourceId)" -match '/subscriptions/([0-9a-f-]{36})') { $Matches[1] } } | Sort-Object -Unique)
$Kinds = $Rows | Group-Object MeterCategory | Sort-Object Name | ForEach-Object { '{0}={1}' -f $_.Name, $_.Count }
'[{0}] Consumption rows {1}; subscription ids in the rows: {2}; by category: {3}' -f $Label, $Rows.Count, $(if ($SubIds.Count -eq 1 -and $SubIds[0] -eq $Target.Id) { 'only the target' } elseif ($SubIds.Count -eq 0) { 'none' } else { 'MIXED ' + $SubIds.Count }), ($Kinds -join ', ')
$Sorted = @($Rows | ForEach-Object { ($_.PSObject.Properties | Where-Object { $_.Name -notmatch 'Time|Date' } | ForEach-Object { "$($_.Value)" }) -join '|' } | Sort-Object)
$Hash = [System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($Sorted -join "`n"))).Replace('-', '').Substring(0, 16)
'[{0}] content hash of the rows (date/time columns excluded): {1}' -f $Label, $Hash
'[{0}] report folder: {1}' -f $Label, (Split-Path $New[0].FullName -Leaf)
