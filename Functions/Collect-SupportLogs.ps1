#Requires -Version 7.0
<#
.SYNOPSIS
    Collect the LOCAL Resource Discovery for Azure support/diagnostic logs a run
    leaves behind into a single zip to hand to support.

.DESCRIPTION
    A run - especially one that FAILED before producing a consolidated report
    bundle (auth / access-gate / consumption hard-fail) - leaves its evidence in
    loose, timestamped files under the inventory root ($HOME/InventoryReports on
    Linux/macOS, C:\InventoryReports on Windows) and in per-subscription
    ResourcesReport<stamp>/ subfolders. This gathers the wrapper transcript +
    failure / access-verdict diagnostics logs and every per-subscription log into
    one RdaSupportLogs_<stamp>.zip so there is a single artefact to send.

    The bundle contains REAL identifiers (signed-in account, tenant / subscription
    IDs, resource names) and raw error text, so it is a PRIVATE support artefact:
    send it over a secure / private channel, never post it publicly. The
    obfuscation dictionary (the de-obfuscation reveal key) is deliberately
    EXCLUDED.

    Delegates to New-RdaSupportLogBundle in RunAllSubscriptions.Functions.ps1
    (its sibling in this folder). No Azure calls - it works purely from the local
    files a run already wrote.

    NOTE: a FAILED run of Run-AllSubscriptions.ps1 now collects this bundle
    automatically on its way out, so you usually only need to run this script by
    hand to (re)collect after the fact or to include the aggregate MainSummary.

.PARAMETER InventoryRoot
    Root the run wrote to. Defaults to the platform inventory root the wrapper
    uses ($HOME/InventoryReports on Unix, C:\InventoryReports otherwise).

.PARAMETER SinceTime
    Only include files last written at/after this time (scope to a single run).
    Omit to collect everything currently present under the inventory root.

.PARAMETER IncludeMainSummary
    Also include the aggregate MainSummary_*.html for context.

.PARAMETER DestinationPath
    Where to write the zip. Defaults to RdaSupportLogs_<stamp>.zip in the
    inventory root.

.EXAMPLE
    pwsh ./Functions/Collect-SupportLogs.ps1

.EXAMPLE
    pwsh ./Functions/Collect-SupportLogs.ps1 -IncludeMainSummary
#>
[CmdletBinding()]
param(
    [string]$InventoryRoot,
    [datetime]$SinceTime,
    [switch]$IncludeMainSummary,
    [string]$DestinationPath
)

. (Join-Path $PSScriptRoot 'RunAllSubscriptions.Functions.ps1')

# Forward only the parameters the caller actually supplied so New-RdaSupportLogBundle
# applies its own defaults (platform inventory root, timestamped destination) for
# the rest.
$CollectParams = @{}
foreach ($Name in @('InventoryRoot', 'SinceTime', 'IncludeMainSummary', 'DestinationPath'))
{
    if ($PSBoundParameters.ContainsKey($Name)) { $CollectParams[$Name] = $PSBoundParameters[$Name] }
}

$Bundle = New-RdaSupportLogBundle @CollectParams
if ($Bundle)
{
    Write-Host ("Support log bundle created: {0}" -f $Bundle) -ForegroundColor Green
    Write-Host "Send this file to support over a secure/private channel - it contains real identifiers (account, tenant/subscription IDs, resource names)." -ForegroundColor Yellow
}
else
{
    Write-Host "No support logs were found to collect under the inventory root." -ForegroundColor Yellow
}
