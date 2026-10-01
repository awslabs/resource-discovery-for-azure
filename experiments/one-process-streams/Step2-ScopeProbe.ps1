# Step 2 probe: can one process query a subscription's billing data WITHOUT switching its context?
# Read-only. Measurement only.
param([Parameter(Mandatory)] [string]$HomeSubName, [Parameter(Mandatory)] [string]$OtherSubName)
$ErrorActionPreference = 'Stop'
Import-Module Az.Accounts, Az.Billing -WarningAction SilentlyContinue
$HomeSub = Get-AzSubscription -SubscriptionName $HomeSubName -WarningAction SilentlyContinue
$Other = Get-AzSubscription -SubscriptionName $OtherSubName -WarningAction SilentlyContinue
$null = Set-AzContext -Subscription $HomeSub.Id -Scope Process -WarningAction SilentlyContinue
$Base = Get-AzContext
'process default: ' + $Base.Subscription.Name

# 1. A context for <other>, built from the signed-in context, with only the subscription changed.
$CtxType = 'Microsoft.Azure.Commands.Profile.Models.Core.PSAzureContext' -as [type]
$Copy = $CtxType::new([Microsoft.Azure.Commands.Common.Authentication.Abstractions.IAzureContext]$Base)
'copy type: ' + $Copy.GetType().Name + '; Subscription settable: ' + [bool]($CtxType.GetProperty('Subscription').CanWrite)
$Copy.Subscription = $Other
$Container = [System.Management.Automation.LanguagePrimitives]::ConvertTo($Copy, ('Microsoft.Azure.Commands.Common.Authentication.Abstractions.Core.IAzureContextContainer' -as [type]))
'1. per-sub profile: Get-AzContext -DefaultProfile reads {0}; process default still {1}' -f (Get-AzContext -DefaultProfile $Container).Subscription.Name, (Get-AzContext).Subscription.Name

# 2. Same billing window, two ways: switching the process context vs passing the per-sub profile.
$Day = [DateTime]::SpecifyKind([DateTime]::UtcNow.Date, [DateTimeKind]::Utc)
$Window = @{ ReportedStartTime = $Day.AddDays(-20); ReportedEndTime = $Day.AddDays(-1); AggregationGranularity = 'Daily'; ShowDetails = $true }
function Get-Rows($Extra)
{
    $Rows = [System.Collections.Generic.List[object]]::new(); $Token = $null; $Pages = 0
    do
    {
        $CallArgs = $Window.Clone(); foreach ($K in $Extra.Keys) { $CallArgs[$K] = $Extra[$K] }
        if ($Token) { $CallArgs['ContinuationToken'] = $Token }
        $R = Get-UsageAggregates @Args
        foreach ($U in $R.UsageAggregations) { $Rows.Add($U) }
        $Token = $R.ContinuationToken; $Pages++
    } while ($Token -and $Pages -lt 50)
    $Rows
}
foreach ($Target in $HomeSub, $Other)
{
    $null = Set-AzContext -Subscription $Target.Id -Scope Process -WarningAction SilentlyContinue
    $Switched = @(Get-Rows @{})
    $null = Set-AzContext -Subscription $HomeSub.Id -Scope Process -WarningAction SilentlyContinue
    $C = $CtxType::new([Microsoft.Azure.Commands.Common.Authentication.Abstractions.IAzureContext](Get-AzContext)); $C.Subscription = $Target
    $P = [System.Management.Automation.LanguagePrimitives]::ConvertTo($C, ('Microsoft.Azure.Commands.Common.Authentication.Abstractions.Core.IAzureContextContainer' -as [type]))
    $Scoped = @(Get-Rows @{ DefaultProfile = $P })
    $Key = { param($U) '{0}|{1}|{2}|{3}' -f $U.Properties.MeterId, $U.Properties.UsageStartTime, $U.Properties.Quantity, $U.Properties.InstanceData }
    $A = @($Switched | ForEach-Object { & $Key $_ } | Sort-Object); $B = @($Scoped | ForEach-Object { & $Key $_ } | Sort-Object)
    $SubsInRows = @($Scoped | ForEach-Object { $_.Properties.SubscriptionId } | Sort-Object -Unique)
    '2. {0}: switched-context rows {1}, per-sub-profile rows {2}, identical: {3}; subscription ids in the scoped rows: {4}' -f $Target.Name, $A.Count, $B.Count, (($A -join "`n") -ceq ($B -join "`n")), $(if ($SubsInRows.Count -eq 0) { '(no rows)' } elseif ($SubsInRows.Count -eq 1 -and $SubsInRows[0] -eq $Target.Id) { 'only the target' } else { 'OTHER: ' + ($SubsInRows.Count) })
}
'   process default after the scoped pulls: ' + (Get-AzContext).Subscription.Name

# 3. $PSDefaultParameterValues as the scoping mechanism: does a function-local copy reach Az cmdlets
#    called below it, and vanish when the function returns?
function Invoke-Scoped
{
    $PSDefaultParameterValues = [System.Management.Automation.DefaultParameterDictionary]::new($PSDefaultParameterValues)
    $PSDefaultParameterValues['*:DefaultProfile'] = $Container
    function Inner { (Get-AzContext).Subscription.Name }
    'inside the function: Get-AzContext reads {0}; a nested function reads {1}' -f (Get-AzContext).Subscription.Name, (Inner)
}
'3. ' + (Invoke-Scoped)
'   after the function returned: Get-AzContext reads {0}; global PSDefaultParameterValues has DefaultProfile: {1}' -f (Get-AzContext).Subscription.Name, $PSDefaultParameterValues.ContainsKey('*:DefaultProfile')
