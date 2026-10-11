# Step 1 evidence: how Set-AzContext changes the SAVED default subscription, and which RDA code does it.
# Read-only against Azure. Every check reads the saved default in a NEW pwsh process, which is what an
# operator's next session sees. The saved default is put back to the starting subscription at the end.
param(
    [Parameter(Mandatory)] [string]$Tree,
    [Parameter(Mandatory)] [string]$HomeSubName,      # the subscription the saved default should be on
    [Parameter(Mandatory)] [string]$OtherSubName      # a second subscription to switch to
)
$ErrorActionPreference = 'Stop'
$Pwsh = (Get-Process -Id $PID).Path
Import-Module Az.Accounts -WarningAction SilentlyContinue
$HomeSub = Get-AzSubscription -SubscriptionName $HomeSubName -WarningAction SilentlyContinue
$OtherSub = Get-AzSubscription -SubscriptionName $OtherSubName -WarningAction SilentlyContinue

function Invoke-Child([string]$Script)
{
    $File = Join-Path ([IO.Path]::GetTempPath()) ('rda-step1-{0}.ps1' -f [guid]::NewGuid())
    Set-Content -LiteralPath $File -Value ("Import-Module Az.Accounts -WarningAction SilentlyContinue`n" + $Script)
    try { & $Pwsh -NoProfile -NonInteractive -File $File 2>&1 | ForEach-Object { [string]$_ } }
    finally { Remove-Item -LiteralPath $File -Force -ErrorAction SilentlyContinue }
}
function Get-SavedDefault { (Invoke-Child '(Get-AzContext).Subscription.Name' | Select-Object -Last 1) }
function Set-SavedDefault([string]$Id) { $null = Invoke-Child ("`$null = Set-AzContext -Subscription '{0}' -WarningAction SilentlyContinue" -f $Id) }

$Lines = [System.Collections.Generic.List[string]]::new()
function Note([string]$Text) { $Lines.Add($Text); $Text }

$Autosave = Get-AzContextAutosaveSetting
Note ('Context autosave: mode {0}, context file {1}' -f $Autosave.Mode, $Autosave.ContextFile)
Note ('Saved default at the start: {0}' -f (Get-SavedDefault))
Set-SavedDefault $HomeSub.Id
Note ('Saved default reset to: {0}' -f (Get-SavedDefault))

# A. The mechanism, outside RDA.
$null = Invoke-Child ("`$null = Set-AzContext -Subscription '{0}' -Scope Process -WarningAction SilentlyContinue" -f $OtherSub.Id)
Note ('A1. a process ran Set-AzContext -Subscription <other> -Scope Process; the next new session sees: {0}' -f (Get-SavedDefault))
$null = Invoke-Child ("`$null = Set-AzContext -Subscription '{0}' -WarningAction SilentlyContinue" -f $OtherSub.Id)
Note ('A2. a process ran Set-AzContext -Subscription <other> (no -Scope); the next new session sees: {0}' -f (Get-SavedDefault))
Set-SavedDefault $HomeSub.Id
$null = Invoke-Child ("Disable-AzContextAutosave -Scope Process | Out-Null; `$null = Set-AzContext -Subscription '{0}' -WarningAction SilentlyContinue" -f $OtherSub.Id)
Note ('A3. a process disabled autosave for itself (what each parallel stream does), then ran Set-AzContext <other>; the next new session sees: {0}' -f (Get-SavedDefault))

# B. The inventory script, standalone, on the other subscription.
$Inv = Join-Path $Tree 'ResourceInventory.ps1'
$Common = "-TenantID '{1}' -SubscriptionID '{0}' -SkipMetrics -SkipMarketplace -SkipFoundryCoverage -ReportName Step1" -f $OtherSub.Id, $OtherSub.TenantId
Set-SavedDefault $HomeSub.Id
$null = Invoke-Child ("& '{0}' {1} -SkipConsumption" -f $Inv, $Common)
Note ('B1. ResourceInventory.ps1 on <other> with every billing phase skipped; the next new session sees: {0}' -f (Get-SavedDefault))
Set-SavedDefault $HomeSub.Id
$null = Invoke-Child ("& '{0}' {1}" -f $Inv, $Common)
Note ('B2. ResourceInventory.ps1 on <other> with consumption on; the next new session sees: {0}' -f (Get-SavedDefault))

# C. The wrapper's up-front consumption probe, run on its own.
Set-SavedDefault $HomeSub.Id
$null = Invoke-Child (". '{0}'; . '{1}'; `$null = Test-ConsumptionAccess -SubscriptionId '{2}'" -f (Join-Path $Tree 'Functions/Common.Functions.ps1'), (Join-Path $Tree 'Functions/RunAllSubscriptions.Functions.ps1'), $OtherSub.Id)
Note ('C1. Run-AllSubscriptions.ps1''s Test-ConsumptionAccess probe on <other>; the next new session sees: {0}' -f (Get-SavedDefault))

# D. Inside ONE process: does a second runspace's switch reach the first? (the reason streams are processes)
$D = Invoke-Child (@'
$null = Set-AzContext -Subscription '{0}' -Scope Process -WarningAction SilentlyContinue
$Rs = [runspacefactory]::CreateRunspace(); $Rs.Open(); $P = [powershell]::Create(); $P.Runspace = $Rs
[void]$P.AddScript("Import-Module Az.Accounts -WarningAction SilentlyContinue; `$null = Set-AzContext -Subscription '{1}' -Scope Process -WarningAction SilentlyContinue")
$null = $P.Invoke(); $P.Dispose(); $Rs.Dispose()
(Get-AzContext).Subscription.Name
'@ -f $HomeSub.Id, $OtherSub.Id) | Select-Object -Last 1
Note ('D1. in one process the main runspace selected <home>, a second runspace then selected <other>; the main runspace now reads: {0}' -f $D)

Set-SavedDefault $HomeSub.Id
Note ('Saved default restored to: {0}' -f (Get-SavedDefault))
