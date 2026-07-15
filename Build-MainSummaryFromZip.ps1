#Requires -Version 7.0
<#
.SYNOPSIS
    Build a working aggregate "main" HTML summary from a CONSOLIDATED outer zip
    (AllSubscriptions_ResourcesReport_*.zip).

.DESCRIPTION
    The consolidated zip a customer/operator hands you contains one
    per-subscription .zip per subscription (NOT extracted folders) and carries no
    aggregate summary, so you cannot just unzip it and open a main report. This
    script reconstructs the per-subscription report folders from the inner zips
    and builds MainSummary.html against them, so its links to each subscription's
    report resolve.

    It delegates to New-RdaAllSubHtmlSummaryFromZip in
    Functions/AllSubHtmlSummary.Functions.ps1. No Azure calls - it works purely
    from the zip you already have, so it runs against any consolidated zip, old
    or new.

.PARAMETER InputZip
    Path to the consolidated AllSubscriptions_ResourcesReport_*.zip.

.PARAMETER OutputDirectory
    Durable folder to reconstruct into and write MainSummary.html. The per-sub
    folders must live next to the html for its links to resolve, so this is not a
    temp dir. Defaults to <zipdir>/<zipbasename>_MainSummary.

.PARAMETER Detailed
    Add run-wide by-service donut/bar charts (parses each per-sub inventory).

.PARAMETER PackageZip
    Also emit a portable zip of the reconstructed folder whose links survive
    being moved/emailed.

.PARAMETER KeepOriginalReports
    By default each per-subscription report is re-rendered from its Inventory
    json with the current Extension/Summary.ps1, so drill-down reports reflect
    the latest renderer (e.g. the Tags column fix). Pass this to keep the
    original per-sub html from the zip verbatim instead.

.EXAMPLE
    ./Build-MainSummaryFromZip.ps1 -InputZip .\AllSubscriptions_ResourcesReport_2026-07-15_09-40-00.zip

.EXAMPLE
    ./Build-MainSummaryFromZip.ps1 -InputZip .\bundle.zip -Detailed -PackageZip
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]   $InputZip,

    [string]   $OutputDirectory,

    [switch]   $Detailed,

    [switch]   $PackageZip,

    [switch]   $KeepOriginalReports
)

$ErrorActionPreference = 'Stop'

# Shared function library: New-RdaAllSubHtmlSummaryFromZip + New-RdaAllSubHtmlSummary
# + the render helpers all live here. Dot-source so they load into this scope.
$SummaryFunctions = Join-Path $PSScriptRoot 'Functions/AllSubHtmlSummary.Functions.ps1'
if (-not (Test-Path -Path $SummaryFunctions -PathType Leaf))
{
    throw "Cannot find shared functions at $SummaryFunctions"
}
. $SummaryFunctions

$Params = @{
    InputZip            = $InputZip
    Detailed            = $Detailed
    PackageZip          = $PackageZip
    KeepOriginalReports = $KeepOriginalReports
    Version             = ''
    PlatOS              = $PSVersionTable.OS
}
if (-not [string]::IsNullOrWhiteSpace($OutputDirectory)) { $Params.OutputDirectory = $OutputDirectory }

# Source the tool version from Version.json if present (display-only header).
try
{
    $VerObj = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Version.json') -Raw | ConvertFrom-Json
    $Params.Version = ('{0}.{1}.{2}' -f $VerObj.MajorVersion, $VerObj.MinorVersion, $VerObj.BuildVersion)
}
catch { Write-Verbose ("Could not read Version.json: {0}" -f $_.Exception.Message) }

New-RdaAllSubHtmlSummaryFromZip @Params
