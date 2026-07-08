#Requires -Version 7.0
<#
.SYNOPSIS
    Bulk-reveal every per-subscription obfuscated report under an inventory root
    and consolidate the results into ONE outer zip ready to upload to the
    ingestion server.

.DESCRIPTION
    A multi-subscription run (Run-AllSubscriptions.ps1 -Obfuscate) leaves, under
    the inventory root, one folder per subscription. Each folder holds:
      - an obfuscated report zip : ResourcesReport_<stamp>.zip
      - its matching dictionary  : ObfuscationDictionary_<ReportName>_<stamp>.json

    This wrapper walks those folders, pairs each obfuscated zip with the
    dictionary sitting next to it, and runs Reveal-Obfuscation.ps1 on each pair
    to produce a selectively-revealed copy. By default it reveals ONLY the
    Subscription name and Resource Group (everything else stays masked). The
    revealed per-subscription zips are then packaged into a single outer zip
    with the same shape a normal multi-subscription run produces (an outer zip
    containing one per-subscription zip each), so the ingestion server consumes
    it exactly like an -Obfuscate outer zip - just with the chosen dimensions
    un-masked.

    Pairing is done WITHIN each folder (the dictionary and the report zip live
    together and share the same <stamp>), so it works regardless of -ReportName
    and never mismatches one subscription's tokens against another's dictionary.

    HANDLE WITH CARE. The output zip contains the real values you chose to
    reveal (subscription names and resource groups by default). Share it only
    with the party meant to ingest it. The dictionaries and any fully-revealed
    output stay local.

.PARAMETER InventoryRoot
    Folder that contains the per-subscription output folders. Defaults to
    C:\InventoryReports on Windows and $HOME/InventoryReports elsewhere - the
    same default Run-AllSubscriptions.ps1 uses.

.PARAMETER Fields
    Which dimensions to reveal, passed straight through to Reveal-Obfuscation.ps1.
    Valid: ResourceGroup, Subscription, Tag, ResourceName, ResourceId, FreeText.
    Defaults to ResourceGroup + Subscription. Ignored when -All is supplied.

.PARAMETER All
    Reveal every dimension the dictionaries can reverse (full un-obfuscate).
    Overrides -Fields. See Reveal-Obfuscation.ps1 for the caveat that this is
    not a perfect byte-for-byte undo (nulled / 'obfuscated'-sentinel fields do
    not come back).

.PARAMETER OutputZip
    Path for the single consolidated outer zip. Defaults to
    <InventoryRoot>/AllSubscriptions_Revealed_<timestamp>.zip.

.PARAMETER StagingDirectory
    Where the individual revealed per-subscription zips are written before they
    are consolidated. Defaults to <InventoryRoot>/RevealedStaging_<timestamp>.
    Kept after the run (not auto-deleted) so a partial run is recoverable; pass
    -RemoveStaging to delete it once the outer zip is built.

.PARAMETER RemoveStaging
    Delete the staging directory after the outer zip is successfully created.

.EXAMPLE
    # Default: reveal Subscription name + Resource Group across every sub, one outer zip
    ./Reveal-AllSubscriptions.ps1

.EXAMPLE
    # Point at a custom root and clean up the staging afterwards
    ./Reveal-AllSubscriptions.ps1 -InventoryRoot D:\Reports -RemoveStaging

.EXAMPLE
    # Full reveal of every dimension
    ./Reveal-AllSubscriptions.ps1 -All
#>
[CmdletBinding()]
param(
    [string]   $InventoryRoot,

    [ValidateSet('ResourceGroup', 'Subscription', 'Tag', 'ResourceName', 'ResourceId', 'FreeText')]
    [string[]] $Fields = @('ResourceGroup', 'Subscription'),

    [switch]   $All,

    [string]   $OutputZip,

    [string]   $StagingDirectory,

    [switch]   $RemoveStaging
)

$ErrorActionPreference = 'Stop'

# The single-report reveal engine must sit next to this wrapper.
$RevealScript = Join-Path $PSScriptRoot 'Reveal-Obfuscation.ps1'
if (-not (Test-Path -LiteralPath $RevealScript -PathType Leaf))
{
    throw "Cannot find Reveal-Obfuscation.ps1 next to this script at $RevealScript"
}

# Resolve the inventory root (same default Run-AllSubscriptions.ps1 uses).
if ([string]::IsNullOrEmpty($InventoryRoot))
{
    $InventoryRoot = if ($PSVersionTable.Platform -eq 'Unix') { Join-Path $HOME 'InventoryReports' } else { 'C:\InventoryReports' }
}
if (-not (Test-Path -LiteralPath $InventoryRoot -PathType Container))
{
    throw "Inventory root not found: $InventoryRoot (pass -InventoryRoot to point at the folder holding the per-subscription folders)."
}
# Canonicalize to an absolute path so the staging-directory exclusion compare
# below is airtight even when the caller passes a relative -InventoryRoot.
$InventoryRoot = (Resolve-Path -LiteralPath $InventoryRoot).Path

if ($All)
{
    $Fields = @('ResourceGroup', 'Subscription', 'Tag', 'ResourceName', 'ResourceId', 'FreeText')
}

$Timestamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
if ([string]::IsNullOrEmpty($StagingDirectory))
{
    $StagingDirectory = Join-Path $InventoryRoot ("RevealedStaging_" + $Timestamp)
}
if ([string]::IsNullOrEmpty($OutputZip))
{
    $OutputZip = Join-Path $InventoryRoot ("AllSubscriptions_Revealed_" + $Timestamp + ".zip")
}
New-Item -ItemType Directory -Path $StagingDirectory -Force | Out-Null
# Canonicalize staging too, so the per-folder exclusion compare below matches
# the absolute FullName that Get-ChildItem returns.
$StagingDirectory = (Resolve-Path -LiteralPath $StagingDirectory).Path

# The output zip must not live inside the staging directory, or it would be
# swept into itself on the final Compress-Archive.
# NB: Split-Path's -Parent switch is only valid with -Path, not -LiteralPath
# (the two are in different parameter sets), so -Path is required here.
$OutputZipParent = Split-Path -Path $OutputZip -Parent
if (-not [string]::IsNullOrEmpty($OutputZipParent) -and (Test-Path -LiteralPath $OutputZipParent -PathType Container))
{
    $OutputZipParent = (Resolve-Path -LiteralPath $OutputZipParent).Path
    if ($OutputZipParent -eq $StagingDirectory)
    {
        throw "-OutputZip must not be inside the staging directory ($StagingDirectory); it would be included in itself. Choose a path outside staging."
    }
}

Write-Host ("Inventory root : {0}" -f $InventoryRoot) -ForegroundColor Cyan
Write-Host ("Revealing      : {0}" -f ($Fields -join ', ')) -ForegroundColor Cyan
Write-Host ("Staging        : {0}" -f $StagingDirectory) -ForegroundColor Cyan
Write-Host ("Output zip     : {0}" -f $OutputZip) -ForegroundColor Cyan
Write-Host ""

$Folders = @(Get-ChildItem -LiteralPath $InventoryRoot -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -ne $StagingDirectory })

$PairedCount   = 0
$RevealedCount = 0
$SkippedItems  = @()
$FailedItems   = @()
$FolderIndex   = 0
$FolderTotal   = $Folders.Count

foreach ($Folder in $Folders)
{
    $FolderIndex++
    Write-Progress -Activity 'Revealing per-subscription reports' -Status ("{0} of {1}" -f $FolderIndex, $FolderTotal) -PercentComplete ([int](($FolderIndex / [math]::Max($FolderTotal, 1)) * 100))

    $Dict = Get-ChildItem -LiteralPath $Folder.FullName -Filter 'ObfuscationDictionary_*.json' -File -ErrorAction SilentlyContinue |
        Select-Object -First 1

    # The obfuscated per-sub report, excluding any *_revealed.zip left by a prior run.
    $Zip = Get-ChildItem -LiteralPath $Folder.FullName -Filter 'ResourcesReport_*.zip' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike '*_revealed.zip' } |
        Select-Object -First 1

    if ($null -eq $Dict -or $null -eq $Zip)
    {
        $Reason = if ($null -eq $Zip) { 'no obfuscated report zip in folder' } else { 'no obfuscation dictionary in folder' }
        $SkippedItems += [pscustomobject]@{ Folder = $Folder.Name; Reason = $Reason }
        continue
    }

    $PairedCount++

    # Write the revealed copy straight into staging under the ORIGINAL zip name
    # so the consolidated outer zip matches the structure the ingestion server
    # expects from a normal multi-subscription run.
    $OutPath = Join-Path $StagingDirectory $Zip.Name
    if (Test-Path -LiteralPath $OutPath)
    {
        # Defensive: per-run stamps are unique so this is not expected, but never
        # silently overwrite one subscription's output with another's.
        $OutPath = Join-Path $StagingDirectory ($Folder.Name + '_' + $Zip.Name)
    }

    try
    {
        # In-process call so the [string[]] -Fields array binds correctly (a
        # 'pwsh -File' child would mis-split it). Reveal-Obfuscation.ps1 raises
        # terminating errors via throw, so a single bad subscription is caught
        # here and the run continues with the next one. Its host chatter is
        # redirected away to keep a large run readable.
        & $RevealScript -InputZip $Zip.FullName -DictionaryPath $Dict.FullName -Fields $Fields -OutputZip $OutPath *> $null

        if (Test-Path -LiteralPath $OutPath)
        {
            $RevealedCount++
        }
        else
        {
            $FailedItems += [pscustomobject]@{ Folder = $Folder.Name; Reason = 'reveal completed but produced no output zip' }
        }
    }
    catch
    {
        $FailedItems += [pscustomobject]@{ Folder = $Folder.Name; Reason = $_.Exception.Message }
    }
}

Write-Progress -Activity 'Revealing per-subscription reports' -Completed

# Consolidate the revealed per-sub zips into one outer zip for upload.
$StagedZips = @(Get-ChildItem -LiteralPath $StagingDirectory -Filter '*.zip' -File -ErrorAction SilentlyContinue)
if ($StagedZips.Count -gt 0)
{
    Compress-Archive -Path $StagedZips.FullName -DestinationPath $OutputZip -Force
}

# ---- Summary ---------------------------------------------------------------
Write-Host ""
Write-Host "================ Reveal Summary ================" -ForegroundColor Green
Write-Host ("Per-subscription folders scanned : {0}" -f $FolderTotal) -ForegroundColor Green
Write-Host ("Paired (zip + dictionary)        : {0}" -f $PairedCount) -ForegroundColor Green
Write-Host ("Revealed successfully            : {0}" -f $RevealedCount) -ForegroundColor Green
Write-Host ("Skipped (missing zip or dict)    : {0}" -f $SkippedItems.Count) -ForegroundColor $(if ($SkippedItems.Count -gt 0) { 'Yellow' } else { 'Green' })
Write-Host ("Failed during reveal             : {0}" -f $FailedItems.Count) -ForegroundColor $(if ($FailedItems.Count -gt 0) { 'Red' } else { 'Green' })

foreach ($s in $SkippedItems)
{
    Write-Host ("  SKIP: {0} - {1}" -f $s.Folder, $s.Reason) -ForegroundColor Yellow
}
foreach ($f in $FailedItems)
{
    Write-Host ("  FAIL: {0} - {1}" -f $f.Folder, $f.Reason) -ForegroundColor Red
}

Write-Host ""
if ($StagedZips.Count -gt 0 -and (Test-Path -LiteralPath $OutputZip))
{
    Write-Host ("Consolidated {0} revealed report(s) into:" -f $StagedZips.Count) -ForegroundColor Green
    Write-Host ("  {0}" -f $OutputZip) -ForegroundColor Green
    Write-Host "Upload this single zip to the ingestion server." -ForegroundColor Green
}
else
{
    Write-Host "No revealed reports were produced - nothing to consolidate. Check the SKIP/FAIL list above." -ForegroundColor Red
}

if ($RemoveStaging -and (Test-Path -LiteralPath $OutputZip))
{
    try
    {
        Remove-Item -LiteralPath $StagingDirectory -Recurse -Force
        Write-Host ("Removed staging directory: {0}" -f $StagingDirectory) -ForegroundColor DarkGray
    }
    catch
    {
        Write-Host ("WARNING: could not remove staging directory {0}: {1}" -f $StagingDirectory, $_.Exception.Message) -ForegroundColor Yellow
    }
}
else
{
    Write-Host ("Individual revealed zips kept in: {0}" -f $StagingDirectory) -ForegroundColor DarkGray
}

# Non-zero exit if nothing was produced, or if any subscription failed to reveal,
# so an automated/large run surfaces problems instead of looking clean.
if ($StagedZips.Count -eq 0)
{
    exit 1
}
if ($FailedItems.Count -gt 0)
{
    exit 4
}
exit 0
