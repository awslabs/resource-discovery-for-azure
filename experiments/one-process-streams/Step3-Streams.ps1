# Step 3 prototype: run the same subscriptions through the inventory three ways and measure them.
#   processes : what Run-AllSubscriptions.ps1 does today - one Start-Job pwsh process per stream, each
#               importing a saved Az context snapshot with autosave off, then running its subscriptions.
#   runspaces : ONE process. Each stream is a runspace that takes the next subscription from a shared
#               ConcurrentQueue and scopes every Az call to it through its own
#               $PSDefaultParameterValues['*:DefaultProfile'] (Get-RdaSubscriptionProfile, step 2).
#   sequential: ONE process, one runspace, the subscriptions one after another (the floor).
# Each run calls ResourceInventory.ps1 -RunAllSubs exactly as a stream does. Measurement only.
param(
    [Parameter(Mandatory)] [string]$Tree,
    [Parameter(Mandatory)] [ValidateSet('processes', 'runspaces', 'sequential')] [string]$Design,
    [int]$Streams = 3,
    [int]$ConcurrencyLimit = 6,
    [string]$ResultFile
)
$ErrorActionPreference = 'Stop'
Import-Module Az.Accounts -WarningAction SilentlyContinue
. (Join-Path $Tree 'Functions/Common.Functions.ps1')
$InventoryRoot = Join-Path $HOME 'InventoryReports'
Set-RdaInventoryRootForChildren -Path $InventoryRoot
$Tenant = (Get-AzContext).Tenant.Id
$Subs = @(Get-AzSubscription -TenantId $Tenant -WarningAction SilentlyContinue | Where-Object { $_.State -eq 'Enabled' } | Sort-Object Name | ForEach-Object { [pscustomobject]@{ Id = $_.Id; Name = $_.Name } })
$Inventory = Join-Path $Tree 'ResourceInventory.ps1'
$Results = [System.Collections.Concurrent.ConcurrentBag[psobject]]::new()
$Clock = [System.Diagnostics.Stopwatch]::StartNew()

# The per-stream loop, shared by all three designs. $Scope = 'profile' scopes every Az call to the
# subscription through this runspace's PSDefaultParameterValues; 'process' relies on the process's
# own context, as the processes design must.
$StreamLoop = {
    param($Inventory, $Common, $Tenant, $Queue, $Results, $ConcurrencyLimit, $Scope, $StreamNo)
    $ErrorActionPreference = 'Stop'
    . $Common
    $Global:ConsumptionRecordCount = 0; $Global:ConsumptionRowsFetchedCount = 0; $Global:ConsumptionFailedSubs = @()
    $Global:MetricsApiCallCount = 0; $Global:MetricsFailedSubs = @(); $Global:MarketplaceRecordCount = 0
    $Global:MarketplaceFailedSubs = @(); $Global:CollectorFailures = @(); $Global:MemoryReadings = @()
    $Sub = $null
    while ($Queue.TryDequeue([ref]$Sub))
    {
        $T = [System.Diagnostics.Stopwatch]::StartNew(); $Err = $null; $Rows = $Global:ConsumptionRecordCount
        try
        {
            if ($Scope -eq 'profile') { $PSDefaultParameterValues['*:DefaultProfile'] = Get-RdaSubscriptionProfile -SubscriptionId $Sub.Id }
            $Global:ZipOutputFile = $null
            & $Inventory -TenantID $Tenant -SubscriptionID $Sub.Id -ConcurrencyLimit $ConcurrencyLimit -RunAllSubs *> $null
        }
        catch { $Err = $_.Exception.Message }
        $Results.Add([pscustomobject]@{ Stream = $StreamNo; Sub = $Sub.Name; Seconds = [math]::Round($T.Elapsed.TotalSeconds, 1); Ok = (-not $Err -and $Global:ZipOutputFile); Error = $Err; ConsumptionRows = $Global:ConsumptionRecordCount - $Rows; Zip = [string]$Global:ZipOutputFile })
    }
}

switch ($Design)
{
    'processes'
    {
        $Snapshot = Join-Path $InventoryRoot ('.rda-proto-azcontext-{0}.json' -f [guid]::NewGuid())
        Save-AzContext -Path $Snapshot -Force | Out-Null
        try
        {
            $Slices = @(for ($StreamIndex = 0; $StreamIndex -lt $Streams; $StreamIndex++) { , @(for ($i = $StreamIndex; $i -lt $Subs.Count; $i += $Streams) { $Subs[$i] }) })
            $Jobs = for ($StreamIndex = 0; $StreamIndex -lt $Streams; $StreamIndex++)
            {
                if ($Slices[$StreamIndex].Count -eq 0) { continue }
                Start-Job -ArgumentList $Inventory, (Join-Path $Tree 'Functions/Common.Functions.ps1'), $Tenant, ($Slices[$StreamIndex] | ConvertTo-Json -Compress -AsArray), $ConcurrencyLimit, $Snapshot, $StreamIndex, $StreamLoop.ToString(), $InventoryRoot -ScriptBlock {
                    param($Inventory, $Common, $Tenant, $SliceJson, $ConcurrencyLimit, $Snapshot, $StreamNo, $LoopText, $InventoryRoot)
                    Import-Module Az.Accounts -WarningAction SilentlyContinue
                    Disable-AzContextAutosave -Scope Process | Out-Null
                    Import-AzContext -Path $Snapshot | Out-Null
                    $env:RDA_INVENTORY_ROOT = $InventoryRoot
                    $Queue = [System.Collections.Concurrent.ConcurrentQueue[psobject]]::new()
                    foreach ($S in ($SliceJson | ConvertFrom-Json)) { $Queue.Enqueue($S) }
                    $Bag = [System.Collections.Concurrent.ConcurrentBag[psobject]]::new()
                    & ([scriptblock]::Create($LoopText)) $Inventory $Common $Tenant $Queue $Bag $ConcurrencyLimit 'process' $StreamNo
                    $Bag.ToArray() | ConvertTo-Json -Compress -AsArray
                }
            }
            $Jobs = @($Jobs)
            $null = $Jobs | Wait-Job
            foreach ($J in $Jobs) { foreach ($R in (Receive-Job $J | Select-Object -Last 1 | ConvertFrom-Json)) { $Results.Add($R) } }
            $Jobs | Remove-Job -Force
        }
        finally { Remove-Item -LiteralPath $Snapshot -Force -ErrorAction SilentlyContinue }
    }
    default
    {
        $N = if ($Design -eq 'sequential') { 1 } else { [math]::Min($Streams, $Subs.Count) }
        $Queue = [System.Collections.Concurrent.ConcurrentQueue[psobject]]::new()
        foreach ($S in $Subs) { $Queue.Enqueue($S) }
        $Workers = for ($StreamIndex = 0; $StreamIndex -lt $N; $StreamIndex++)
        {
            $Rs = [runspacefactory]::CreateRunspace([initialsessionstate]::CreateDefault2())
            $Rs.Open()
            $Ps = [powershell]::Create(); $Ps.Runspace = $Rs
            [void]$Ps.AddScript($StreamLoop.ToString()).AddArgument($Inventory).AddArgument((Join-Path $Tree 'Functions/Common.Functions.ps1')).AddArgument($Tenant).AddArgument($Queue).AddArgument($Results).AddArgument($ConcurrencyLimit).AddArgument('profile').AddArgument($StreamIndex)
            [pscustomobject]@{ Ps = $Ps; Rs = $Rs; Handle = $Ps.BeginInvoke() }
        }
        foreach ($W in @($Workers)) { try { [void]$W.Ps.EndInvoke($W.Handle) } catch { $Results.Add([pscustomobject]@{ Stream = -1; Error = $_.Exception.Message }) }; $W.Ps.Dispose(); $W.Rs.Dispose() }
    }
}
$Clock.Stop()
$Summary = [pscustomobject]@{
    Design = $Design; Streams = $(if ($Design -eq 'sequential') { 1 } else { $Streams }); ConcurrencyLimit = $ConcurrencyLimit
    WallSeconds = [math]::Round($Clock.Elapsed.TotalSeconds, 1); ProcessContextAfter = (Get-AzContext).Subscription.Name
    Subscriptions = @($Results | Sort-Object Sub)
}
$Summary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ResultFile
