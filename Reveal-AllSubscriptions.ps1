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

.PARAMETER Resume
    Continue an interrupted run instead of starting fresh. Re-uses a prior run's
    staging directory (the revealed zips already in it are the record of the
    folders that completed) and SKIPS any folder whose revealed zip is already
    present, so a resumed run does not redo completed work - and gets past a
    folder that previously stalled. With -Resume and no explicit
    -StagingDirectory, the most recent RevealedStaging_* under the inventory root
    is auto-detected; if none is found the run stops and asks you to point
    -StagingDirectory at the folder holding the already-revealed zips.

.EXAMPLE
    # Default: reveal Subscription name + Resource Group across every sub, one outer zip
    ./Reveal-AllSubscriptions.ps1

.EXAMPLE
    # Continue an interrupted large run (skip folders already revealed last time)
    ./Reveal-AllSubscriptions.ps1 -Resume

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

    [switch]   $RemoveStaging,

    [switch]   $Resume
)

$ErrorActionPreference = 'Stop'

# The single-report reveal engine must sit next to this wrapper.
$RevealScript = Join-Path $PSScriptRoot 'Reveal-Obfuscation.ps1'
if (-not (Test-Path -LiteralPath $RevealScript -PathType Leaf))
{
    throw "Cannot find Reveal-Obfuscation.ps1 next to this script at $RevealScript"
}

# Shared helper functions (Write-RdaProgress). Dot-sourced so they load into this
# script's scope. Fail loud if missing rather than a confusing later error.
$CommonFunctions = Join-Path $PSScriptRoot 'Functions/Common.Functions.ps1'
if (-not (Test-Path -LiteralPath $CommonFunctions -PathType Leaf))
{
    throw "Cannot find shared functions at $CommonFunctions"
}
. $CommonFunctions

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
    if ($Resume)
    {
        # Resume re-uses a prior run's staging directory: the revealed zips
        # already in it are the record of which folders completed. Auto-detect
        # the most recent RevealedStaging_* under the inventory root. If none is
        # found we cannot resume, so stop and tell the caller to point
        # -StagingDirectory at the folder holding the already-revealed zips.
        $PriorStaging = Get-ChildItem -LiteralPath $InventoryRoot -Directory -Filter 'RevealedStaging_*' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($null -ne $PriorStaging)
        {
            $StagingDirectory = $PriorStaging.FullName
            Write-Host ("Resume: re-using most recent staging directory: {0}" -f $StagingDirectory) -ForegroundColor Cyan
        }
        else
        {
            throw "-Resume requested but no prior staging directory (RevealedStaging_*) was found under $InventoryRoot. Re-run with -StagingDirectory pointing at the folder that holds the already-revealed zips from the interrupted run."
        }
    }
    else
    {
        $StagingDirectory = Join-Path $InventoryRoot ("RevealedStaging_" + $Timestamp)
    }
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
$ResumedCount  = 0
$SkippedItems  = @()
$FailedItems   = @()
$FolderIndex   = 0
$FolderTotal   = $Folders.Count

# Hard cap on how long a single folder's reveal may run. A pathological report
# (e.g. an unusually large or malformed zip) can make Expand-Archive /
# Compress-Archive run effectively forever; without a cap one bad folder stalls
# the entire batch. When a folder exceeds this it is abandoned, recorded as a
# timeout failure, and the run continues with the next folder.
$RevealTimeoutSeconds = 20 * 60

foreach ($Folder in $Folders)
{
    $FolderIndex++
    # Unified progress reporter: interactive bar + non-interactive line + optional
    # heartbeat. See Write-RdaProgress in Functions/Common.Functions.ps1.
    Write-RdaProgress -Activity 'Revealing per-subscription reports' -CurrentItem $Folder.Name -Index $FolderIndex -Total $FolderTotal

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

    if ($Resume -and (Test-Path -LiteralPath $OutPath))
    {
        # Already revealed on a prior run: its zip is sitting in staging. Skip so
        # a resumed run does not redo completed work (and can advance past a
        # folder that previously stalled the batch).
        $ResumedCount++
        continue
    }

    if (Test-Path -LiteralPath $OutPath)
    {
        # Defensive: per-run stamps are unique so this is not expected, but never
        # silently overwrite one subscription's output with another's.
        $OutPath = Join-Path $StagingDirectory ($Folder.Name + '_' + $Zip.Name)
    }

    $RevealJob = $null
    try
    {
        # Run the single-report reveal as a background job bounded by
        # $RevealTimeoutSeconds. A folder whose zip is pathological (huge or
        # malformed) can make Expand-Archive / Compress-Archive run effectively
        # forever; an in-process call would hang the whole batch there with no
        # way to interrupt it. A job in a child process can be stopped, so one
        # bad folder becomes a recorded timeout instead of a dead run.
        #
        # Arguments are passed via -ArgumentList (object-based), so the
        # [string[]] $Fields array binds correctly - this does NOT suffer the
        # 'pwsh -File' string mis-split the in-process call was avoiding.
        # Reveal-Obfuscation.ps1 raises terminating errors via throw, which
        # surface as a job failure and are re-thrown by Receive-Job into the
        # catch below. Host chatter is redirected away to keep a large run
        # readable.
        $RevealJob = Start-Job -ScriptBlock {
            param($RevealScript, $InputZip, $DictionaryPath, $Fields, $OutputZip)
            & $RevealScript -InputZip $InputZip -DictionaryPath $DictionaryPath -Fields $Fields -OutputZip $OutputZip *> $null
        } -ArgumentList $RevealScript, $Zip.FullName, $Dict.FullName, $Fields, $OutPath

        $Finished = Wait-Job -Job $RevealJob -Timeout $RevealTimeoutSeconds

        if ($null -eq $Finished)
        {
            # Exceeded the per-folder cap. Kill the child process so it cannot
            # keep the batch hostage, record it, and move on to the next folder.
            Stop-Job -Job $RevealJob -ErrorAction SilentlyContinue
            Remove-Job -Job $RevealJob -Force -ErrorAction SilentlyContinue
            $RevealJob = $null
            # A Stop-Job mid-compress can leave a truncated zip at $OutPath.
            # Delete it so it is neither swept into the consolidated outer zip nor
            # mistaken for completed work by a later -Resume.
            Remove-Item -LiteralPath $OutPath -Force -ErrorAction SilentlyContinue
            $FailedItems += [pscustomobject]@{ Folder = $Folder.Name; Reason = ("timed out after {0} minutes" -f ($RevealTimeoutSeconds / 60)) }
            continue
        }

        # Re-throw any terminating error the child raised into the catch below.
        Receive-Job -Job $RevealJob -ErrorAction Stop | Out-Null
        Remove-Job -Job $RevealJob -Force -ErrorAction SilentlyContinue
        $RevealJob = $null

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
        if ($null -ne $RevealJob) { Remove-Job -Job $RevealJob -Force -ErrorAction SilentlyContinue }
        # Drop any partial/truncated output the failed reveal may have left, so it
        # is not consolidated or treated as done on a later -Resume.
        Remove-Item -LiteralPath $OutPath -Force -ErrorAction SilentlyContinue
        $FailedItems += [pscustomobject]@{ Folder = $Folder.Name; Reason = $_.Exception.Message }
    }
}

Write-RdaProgress -Activity 'Revealing per-subscription reports' -Completed

# Consolidate the revealed per-sub zips into one outer zip for upload.
$StagedZips = @(Get-ChildItem -LiteralPath $StagingDirectory -Filter '*.zip' -File -ErrorAction SilentlyContinue)
$ConsolidationError = $null
if ($StagedZips.Count -gt 0)
{
    try
    {
        # -LiteralPath (not -Path): staged names are taken verbatim. -Path treats
        # each value as a wildcard, so a report name containing '[' or ']' would
        # silently fail to match and abort the archive.
        Compress-Archive -LiteralPath $StagedZips.FullName -DestinationPath $OutputZip -Force
    }
    catch
    {
        # Fail LOUD but do not die here. The revealed per-subscription zips are
        # already in staging, so the run is recoverable. Record the reason and
        # fall through to the summary instead of terminating before it prints
        # (which looked like a silent crash - header shown, no summary).
        $ConsolidationError = $_.Exception.Message
    }
}

# ---- Summary ---------------------------------------------------------------
Write-Host ""
Write-Host "================ Reveal Summary ================" -ForegroundColor Green
Write-Host ("Per-subscription folders scanned : {0}" -f $FolderTotal) -ForegroundColor Green
Write-Host ("Paired (zip + dictionary)        : {0}" -f $PairedCount) -ForegroundColor Green
Write-Host ("Revealed successfully            : {0}" -f $RevealedCount) -ForegroundColor Green
Write-Host ("Skipped (already revealed-resume): {0}" -f $ResumedCount) -ForegroundColor $(if ($ResumedCount -gt 0) { 'Cyan' } else { 'Green' })
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
if ($null -eq $ConsolidationError -and $StagedZips.Count -gt 0 -and (Test-Path -LiteralPath $OutputZip))
{
    Write-Host ("Consolidated {0} revealed report(s) into:" -f $StagedZips.Count) -ForegroundColor Green
    Write-Host ("  {0}" -f $OutputZip) -ForegroundColor Green
    Write-Host "Upload this single zip to the ingestion server." -ForegroundColor Green
}
elseif ($null -ne $ConsolidationError)
{
    Write-Host ("Revealed {0} report(s), but consolidating them into the outer zip FAILED:" -f $StagedZips.Count) -ForegroundColor Red
    Write-Host ("  {0}" -f $ConsolidationError) -ForegroundColor Red
    Write-Host ("The revealed per-subscription zips are intact in staging - re-run or zip them manually:" ) -ForegroundColor Yellow
    Write-Host ("  {0}" -f $StagingDirectory) -ForegroundColor Yellow
}
else
{
    Write-Host "No revealed reports were produced - nothing to consolidate. Check the SKIP/FAIL list above." -ForegroundColor Red
}

# Only tear down staging on a fully CLEAN run (outer zip built, nothing failed
# or timed out, no consolidation error). If any folder failed/timed out, the
# staged zips are the only record of what already completed - deleting them
# would defeat a later -Resume. So keep staging and say why.
$CleanRun = ($FailedItems.Count -eq 0 -and $null -eq $ConsolidationError)
if ($RemoveStaging -and $CleanRun -and (Test-Path -LiteralPath $OutputZip))
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
elseif ($RemoveStaging -and -not $CleanRun)
{
    Write-Host ("-RemoveStaging skipped: {0} folder(s) failed or timed out. Staging kept so you can recover them with -Resume:" -f $FailedItems.Count) -ForegroundColor Yellow
    Write-Host ("  {0}" -f $StagingDirectory) -ForegroundColor Yellow
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
if ($null -ne $ConsolidationError)
{
    exit 1
}
if ($FailedItems.Count -gt 0)
{
    exit 4
}
exit 0
