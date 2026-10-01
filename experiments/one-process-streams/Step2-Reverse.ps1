# Reverse check: process default on the EMPTY subscription, per-sub profile on the one with data.
param([string]$DataSub, [string]$EmptySub)
$ErrorActionPreference = 'Stop'
Import-Module Az.Accounts, Az.Billing -WarningAction SilentlyContinue
$D = Get-AzSubscription -SubscriptionName $DataSub -WarningAction SilentlyContinue
$E = Get-AzSubscription -SubscriptionName $EmptySub -WarningAction SilentlyContinue
$null = Set-AzContext -Subscription $E.Id -Scope Process -WarningAction SilentlyContinue
$C = [Microsoft.Azure.Commands.Profile.Models.Core.PSAzureContext]::new([Microsoft.Azure.Commands.Common.Authentication.Abstractions.IAzureContext](Get-AzContext)); $C.Subscription = $D
$P = [System.Management.Automation.LanguagePrimitives]::ConvertTo($C, ('Microsoft.Azure.Commands.Common.Authentication.Abstractions.Core.IAzureContextContainer' -as [type]))
$Day = [DateTime]::SpecifyKind([DateTime]::UtcNow.Date, [DateTimeKind]::Utc)
$W = @{ ReportedStartTime = $Day.AddDays(-20); ReportedEndTime = $Day.AddDays(-1); AggregationGranularity = 'Daily'; ShowDetails = $true }
$Rows = 0; $Tok = $null; $Ids = @{}
do { $A = $W.Clone(); if ($Tok) { $A['ContinuationToken'] = $Tok }; $R = Get-UsageAggregates @A -DefaultProfile $P; foreach ($U in $R.UsageAggregations) { $Rows++; if ($U.Properties.InstanceData -match '/subscriptions/([0-9a-f-]{36})/') { $Ids[$Matches[1]] = 1 } }; $Tok = $R.ContinuationToken } while ($Tok)
'process default {0} (empty); per-sub profile {1}: {2} rows; subscription ids named in the rows'' resource uris: {3}; process default afterwards: {4}' -f $E.Name, $D.Name, $Rows, $(if ($Ids.Count -eq 1 -and $Ids.ContainsKey($D.Id)) { 'only the profile''s subscription' } else { $Ids.Count }), (Get-AzContext).Subscription.Name
