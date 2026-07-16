#Requires -Version 7.0
<#
.SYNOPSIS
    Reveal obfuscated Azure inventory reports back to their real values - either
    a SINGLE report zip or an entire multi-subscription inventory tree.

.DESCRIPTION
    This is the single entry point for the reveal feature. It runs in one of two
    modes, selected by which parameter you pass:

    SINGLE-REPORT MODE (-InputZip)
        Reveal one obfuscated report zip against its ObfuscationDictionary and
        write a selectively-revealed copy. Delegates to the Invoke-RdaReveal
        engine in Functions/RevealObfuscation.Functions.ps1.

    ALL-SUBSCRIPTIONS MODE (-InventoryRoot, or no mode parameter at all)
        A multi-subscription run (Run-AllSubscriptions.ps1 -Obfuscate) leaves,
        under the inventory root, one folder per subscription. Each folder holds:
          - an obfuscated report zip : ResourcesReport_<stamp>.zip
          - its matching dictionary  : ObfuscationDictionary_<ReportName>_<stamp>.json
        This mode walks those folders, pairs each obfuscated zip with the
        dictionary sitting next to it, runs the reveal engine on each pair (in a
        time-bounded background job so one pathological folder cannot stall the
        batch), and consolidates the revealed per-subscription zips into ONE
        outer zip with the same shape a normal multi-subscription run produces,
        so the ingestion server consumes it exactly like an -Obfuscate outer zip
        - just with the chosen dimensions un-masked.

    Both modes reveal ONLY the dimensions you select (default: Subscription name
    + Resource Group); everything else stays masked. Pairing in all-mode is done
    WITHIN each folder (dictionary and report zip share the same <stamp>), so it
    works regardless of -ReportName and never crosses one subscription's tokens
    against another's dictionary.

    HANDLE WITH CARE. The output contains the real values you chose to reveal.
    Share it only with the party meant to ingest it. Dictionaries and any
    fully-revealed output stay local.

.PARAMETER InputZip
    SINGLE-REPORT MODE. Path to one obfuscated report zip to reveal. Presence of
    this parameter selects single-report mode.

.PARAMETER DictionaryPath
    SINGLE-REPORT MODE. Path to the ObfuscationDictionary_*.json for -InputZip.
    If omitted, the newest ObfuscationDictionary_*.json in the current directory
    is used.

.PARAMETER InventoryRoot
    ALL-SUBSCRIPTIONS MODE. Folder that contains the per-subscription output
    folders. Defaults to C:\InventoryReports on Windows and
    $HOME/InventoryReports elsewhere - the same default Run-AllSubscriptions.ps1
    uses.

.PARAMETER StagingDirectory
    ALL-SUBSCRIPTIONS MODE. Where the individual revealed per-subscription zips
    are written before consolidation. Defaults to
    <InventoryRoot>/RevealedStaging_<timestamp>. Kept after the run (not
    auto-deleted) so a partial run is recoverable; pass -RemoveStaging to delete
    it once the outer zip is built.

.PARAMETER RemoveStaging
    ALL-SUBSCRIPTIONS MODE. Delete the staging directory after the outer zip is
    successfully created (only on a fully clean run).

.PARAMETER Resume
    ALL-SUBSCRIPTIONS MODE. Continue an interrupted run instead of starting
    fresh. Re-uses a prior run's staging directory and SKIPS any folder whose
    revealed zip is already present, so a resumed run does not redo completed
    work - and gets past a folder that previously stalled. With -Resume and no
    explicit -StagingDirectory, the most recent RevealedStaging_* under the
    inventory root is auto-detected.

.PARAMETER FolderTimeoutMinutes
    ALL-SUBSCRIPTIONS MODE. Hard cap, in minutes, on how long a single folder's
    reveal may run before it is abandoned (recorded as a timeout failure) so the
    batch can move on to the next folder. Defaults to 20. Lower it (e.g. 1) to
    blast quickly past folders that stall - combine with -Resume so already
    revealed folders are skipped and only the previously stuck ones are retried
    under the shorter cap. Accepts fractional minutes (e.g. 0.5).

.PARAMETER Fields
    BOTH MODES. Which dimensions to reveal. Valid: ResourceGroup, Subscription,
    Tag, ResourceName, ResourceId, FreeText. Defaults to
    ResourceGroup + Subscription. Ignored when -All is supplied.

.PARAMETER All
    BOTH MODES. Reveal every dimension the dictionary can reverse (full
    un-obfuscate). Overrides -Fields. NOTE this is not a perfect byte-for-byte
    undo: fields nulled or stamped with the lossy 'obfuscated' sentinel at
    obfuscation time do not come back.

.PARAMETER OutputZip
    BOTH MODES. Path for the output zip. Single mode defaults to
    <InputZip>_revealed.zip next to the input; all-mode defaults to
    <InventoryRoot>/AllSubscriptions_Revealed_<timestamp>.zip.

.EXAMPLE
    # Single report: reveal Subscription name + Resource Group
    ./Reveal.ps1 -InputZip .\ResourcesReport_2026-01-01.zip

.EXAMPLE
    # Single report: full reveal, explicit dictionary and output
    ./Reveal.ps1 -InputZip .\report.zip -DictionaryPath .\ObfuscationDictionary_report.json -All -OutputZip .\report_full.zip

.EXAMPLE
    # All subscriptions: reveal Subscription name + Resource Group, one outer zip
    ./Reveal.ps1

.EXAMPLE
    # All subscriptions: continue an interrupted large run
    ./Reveal.ps1 -Resume

.EXAMPLE
    # All subscriptions: custom root, clean up staging, full reveal
    ./Reveal.ps1 -InventoryRoot D:\Reports -All -RemoveStaging
#>
[CmdletBinding(DefaultParameterSetName = 'All')]
param(
    # ---- Single-report mode ----
    [Parameter(ParameterSetName = 'Single', Mandatory = $true)]
    [string]   $InputZip,

    [Parameter(ParameterSetName = 'Single')]
    [string]   $DictionaryPath,

    [Parameter(ParameterSetName = 'Single')]
    [string]   $SearchDirectory = '.',

    # ---- All-subscriptions mode ----
    [Parameter(ParameterSetName = 'All')]
    [string]   $InventoryRoot,

    [Parameter(ParameterSetName = 'All')]
    [string]   $StagingDirectory,

    [Parameter(ParameterSetName = 'All')]
    [switch]   $RemoveStaging,

    [Parameter(ParameterSetName = 'All')]
    [switch]   $Resume,

    [Parameter(ParameterSetName = 'All')]
    [ValidateRange(0.1, 10080)]
    [double]   $FolderTimeoutMinutes = 20,

    # ---- Common to both modes ----
    [ValidateSet('ResourceGroup', 'Subscription', 'Tag', 'ResourceName', 'ResourceId', 'FreeText')]
    [string[]] $Fields = @('ResourceGroup', 'Subscription'),

    [switch]   $All,

    [string]   $OutputZip
)

$ErrorActionPreference = 'Stop'

# Shared functions: Invoke-RdaReveal + its helpers live in
# RevealObfuscation.Functions.ps1; Write-RdaProgress lives in
# Common.Functions.ps1. Dot-source both so they load into this script's scope.
# Fail loud if missing rather than a confusing later error.
$RevealFunctions = Join-Path $PSScriptRoot 'Functions/RevealObfuscation.Functions.ps1'
$CommonFunctions = Join-Path $PSScriptRoot 'Functions/Common.Functions.ps1'
foreach ($FunctionFile in @($RevealFunctions, $CommonFunctions))
{
    if (-not (Test-Path -LiteralPath $FunctionFile -PathType Leaf))
    {
        throw "Cannot find shared functions at $FunctionFile"
    }
    . $FunctionFile
}

# -All is a full reveal: expand to every reversible dimension (overrides
# -Fields). Done once here so both modes see the expanded list.
if ($All)
{
    $Fields = @('ResourceGroup', 'Subscription', 'Tag', 'ResourceName', 'ResourceId', 'FreeText')
}

# =============================================================================
# SINGLE-REPORT MODE - delegate straight to the engine.
# =============================================================================
if ($PSCmdlet.ParameterSetName -eq 'Single')
{
    $EngineParams = @{
        InputZip = $InputZip
        Fields   = $Fields
    }
    if (-not [string]::IsNullOrEmpty($DictionaryPath)) { $EngineParams.DictionaryPath = $DictionaryPath }
    if (-not [string]::IsNullOrEmpty($SearchDirectory)) { $EngineParams.SearchDirectory = $SearchDirectory }
    if (-not [string]::IsNullOrEmpty($OutputZip)) { $EngineParams.OutputZip = $OutputZip }
    if ($All) { $EngineParams.All = $true }

    Invoke-RdaReveal @EngineParams
    return
}

# =============================================================================
# ALL-SUBSCRIPTIONS MODE
# =============================================================================

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

$PairedCount = 0
$RevealedCount = 0
$ResumedCount = 0
$SkippedItems = @()
$FailedItems = @()
$FolderIndex = 0
$FolderTotal = $Folders.Count

# Hard cap on how long a single folder's reveal may run. A pathological report
# (e.g. an unusually large or malformed zip) can make Expand-Archive /
# Compress-Archive run effectively forever; without a cap one bad folder stalls
# the entire batch. When a folder exceeds this it is abandoned, recorded as a
# timeout failure, and the run continues with the next folder. Configurable via
# -FolderTimeoutMinutes (default 20); Ceiling keeps a fractional-minute value
# (e.g. 0.5) at a whole >=1s Wait-Job timeout.
$RevealTimeoutSeconds = [int][math]::Ceiling($FolderTimeoutMinutes * 60)

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
        # The job dot-sources the reveal functions file into its own (child
        # process) scope, then calls Invoke-RdaReveal. Arguments are passed via
        # -ArgumentList (object-based), so the [string[]] $Fields array binds
        # correctly. Invoke-RdaReveal raises terminating errors via throw, which
        # surface as a job failure and are re-thrown by Receive-Job into the
        # catch below. Host chatter is redirected away to keep a large run
        # readable.
        $RevealJob = Start-Job -ScriptBlock {
            param($RevealFunctions, $InputZip, $DictionaryPath, $Fields, $OutputZip)
            . $RevealFunctions
            Invoke-RdaReveal -InputZip $InputZip -DictionaryPath $DictionaryPath -Fields $Fields -OutputZip $OutputZip *> $null
        } -ArgumentList $RevealFunctions, $Zip.FullName, $Dict.FullName, $Fields, $OutPath

        # Poll the job in short slices so the operator sees a live per-folder
        # heartbeat (elapsed vs cap) instead of one frozen line for the whole
        # reveal: a big folder's Expand/Compress can run for minutes and the
        # child job's own output is suppressed, so without this the run looks
        # hung. $Finished stays $null iff the per-folder cap ($RevealTimeoutSeconds)
        # is reached, which drives the existing timeout-abandon path below.
        $FolderStart = [DateTime]::UtcNow
        $Deadline = $FolderStart.AddSeconds($RevealTimeoutSeconds)
        $Finished = $null
        while ($true)
        {
            $Finished = Wait-Job -Job $RevealJob -Timeout 3
            if ($null -ne $Finished) { break }
            if ([DateTime]::UtcNow -ge $Deadline) { break }
            $ElapsedSec = [int]([DateTime]::UtcNow - $FolderStart).TotalSeconds
            Write-RdaProgress -Activity 'Revealing per-subscription reports' `
                -CurrentItem ('{0}  [elapsed {1}s / cap {2}s]' -f $Folder.Name, $ElapsedSec, $RevealTimeoutSeconds) `
                -Index $FolderIndex -Total $FolderTotal
        }

        if ($null -eq $Finished)
        {
            # Exceeded the per-folder cap. Kill the child process so it cannot
            # keep the batch hostage, record it, and move on to the next folder.
            Stop-Job -Job $RevealJob -ErrorAction SilentlyContinue
            Remove-Job -Job $RevealJob -Force -ErrorAction SilentlyContinue
            $RevealJob = $null
            # A Stop-Job mid-compress leaves the engine's *.partial.zip behind
            # (the final $OutPath only ever appears after a successful atomic
            # rename). Delete both defensively so neither is swept into the
            # consolidated outer zip nor mistaken for completed work by -Resume.
            Remove-Item -LiteralPath $OutPath -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath (($OutPath -replace '\.zip$', '') + '.partial.zip') -Force -ErrorAction SilentlyContinue
            $FailedItems += [pscustomobject]@{ Folder = $Folder.Name; Reason = ("timed out after {0:0.##} minutes" -f ($RevealTimeoutSeconds / 60)) }
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
        # Drop any partial/truncated output the failed reveal may have left (both
        # the engine's *.partial.zip and, defensively, the final name) so neither
        # is consolidated or treated as done on a later -Resume.
        Remove-Item -LiteralPath $OutPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (($OutPath -replace '\.zip$', '') + '.partial.zip') -Force -ErrorAction SilentlyContinue
        $FailedItems += [pscustomobject]@{ Folder = $Folder.Name; Reason = $_.Exception.Message }
    }
}

Write-RdaProgress -Activity 'Revealing per-subscription reports' -Completed

# Consolidate the revealed per-sub zips into one outer zip for upload.
# Exclude *.partial.zip: the single-report engine compresses to a sibling
# .partial.zip and atomically renames it to the final name on success, so a
# .partial.zip only ever exists if a reveal was hard-killed mid-compress. Such
# a truncated file must never be folded into the consolidated outer zip.
$StagedZips = @(Get-ChildItem -LiteralPath $StagingDirectory -Filter '*.zip' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '*.partial.zip' })
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
