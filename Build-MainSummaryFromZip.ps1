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

    Each rebuilt file is written under a private name (<file>.rda-<id>.partial)
    and the file it replaces is moved aside (<file>.rda-<id>.bak) until every
    file is in place; a failed or stopped run puts the earlier files back. A
    file that cannot be put back or removed is named in the error (or in a
    warning), with what to do: an earlier file kept as .rda-<id>.bak replaces
    the new file of its name. A run killed outright (power loss, a killed
    process) can leave such files with no message. Nothing reads them: delete a
    .partial file, and use a .bak file in place of the file of its name
    without the .rda-<id>.bak end. A report whose zip holds no html gets one
    rendered as <folder>.html; a file of that name already in the folder is
    replaced only when the render works, so running the rebuild again keeps
    one html per report.

    One rebuild at a time writes into a folder: while it runs it holds a
    lock on the file .rda-rebuild.lock in -OutputDirectory, and a second one
    started into the same folder, by any user, stops before it changes
    anything, saying another rebuild is writing there. Run it again when the
    first has finished. The empty file stays in the folder (it is never in
    the summary or the bundle); a failed rebuild into a folder it made
    removes the folder with it.

.PARAMETER InputZip
    Path to the consolidated AllSubscriptions_ResourcesReport_*.zip.

.PARAMETER OutputDirectory
    Durable folder to reconstruct into and write MainSummary.html. The per-sub
    folders must live next to the html for its links to resolve, so this is not a
    temp dir. Defaults to <zipdir>/<zipbasename>_MainSummary.

.PARAMETER Detailed
    Add run-wide by-service donut/bar charts (parses each per-sub inventory).

.PARAMETER PackageZip
    Also emit a portable zip, next to the folder, of MainSummary.html and the
    per-subscription folders reconstructed from -InputZip, whose links survive
    being moved/emailed. Other files already in -OutputDirectory are left out.

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
if (-not (Test-Path -LiteralPath $SummaryFunctions -PathType Leaf))
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
