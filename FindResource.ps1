#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    Find every resource of a given type across an already-produced set of report
    bundles, and report how many there are and how big they are.

.DESCRIPTION
    Answers "does resource type X exist anywhere in this estate, and how large is
    it" from report output that has ALREADY been generated. Makes no Azure calls
    and writes nothing back into the scanned tree.

    Why this exists: a resource type can be collected into Inventory_*.json
    before server ingestion handles it, and in that case the report bundle is the
    only copy of the data. Searching for it inside the HTML report is not an
    option, because each per-subscription report covers exactly ONE subscription -
    there is no single report spanning an estate to search. This walks the
    bundles instead.

    Efficiency: a per-subscription zip is dominated by its Consumption_*.csv,
    while the Inventory_*.json this needs is a few kilobytes of it. Each zip is
    opened and ONLY the inventory entry is read, so a scan touches a small
    fraction of the bytes on disk. Reads run in parallel (see -ThrottleLimit).

    Absence claims: a wrong "no" is the worst thing this tool could produce, so
    it only calls a zero a CONFIRMED zero when the scan was complete AND every
    inventory it read actually carried the requested key. Otherwise it says what
    it could not establish. De-obfuscated (revealed) reports are refused and
    reported, never read.

.PARAMETER Path
    One or more places to search. Directories are searched recursively, so a
    whole scan root containing many sharded bundles can be given directly.
    Accepts any mix of:
      - a directory holding extracted per-subscription report folders
      - a directory holding per-subscription ResourcesReport*.zip files
      - a directory holding consolidated AllSubscriptions_*/shard-*.zip bundles
      - an individual ResourcesReport*.zip, consolidated bundle, or Inventory_*.json

.PARAMETER ResourceType
    Which collector's rows to return. These are the Inventory_*.json keys, which
    are the base names of the files under Services/ (for example VirtualMachines,
    StorageAcc, AKS, VMWare for Azure VMware Solution private clouds).

    Typo-protected: the value is validated at parameter-binding time against the
    Services tree on disk, and tab completion offers the valid names. The list is
    read from the filesystem rather than hardcoded, so it can never drift from the
    collectors that actually exist.

.PARAMETER SumBy
    Numeric field(s) to total across the matches. This is the "how big is it"
    figure - for Azure VMware Solution, ClusterSize gives the host count.
    Non-numeric and empty values are reported separately rather than folded
    silently into the total.

.PARAMETER GroupBy
    Field to break the match count down by, for example SKU or Location.

.PARAMETER CsvPath
    Also write the matched rows to this CSV.

.PARAMETER JsonPath
    Also write the matched rows to this JSON file.

.PARAMETER ThrottleLimit
    Parallel readers (default 12). The work is I/O bound on many small zip reads.
    Lower it when scanning consolidated bundles, because reading a report nested
    inside a bundle has to buffer that inner zip in memory.

.PARAMETER HeartbeatLogFile
    Optional durable progress log, useful for a long unattended scan.

.INPUTS
    None. Paths are passed by parameter.

.OUTPUTS
    One object per matching resource, carrying the collector's own fields plus
    RdaResourceType, RdaReportId and RdaSourceFile for provenance. Pipe them to
    Export-Csv, ConvertTo-Json, Group-Object and so on.

.EXAMPLE
    ./FindResource.ps1 -Path ./ScanRoot -ResourceType VMWare -SumBy ClusterSize -GroupBy SKU

    Find every Azure VMware Solution private cloud in the scan, total the host
    count, and break it down by host SKU.

.EXAMPLE
    ./FindResource.ps1 -Path ./ScanRoot -ResourceType VMWare -CsvPath ./avs.csv

    Same search, with the matched rows written to a CSV for further analysis.

.EXAMPLE
    ./FindResource.ps1 -Path ./ScanRoot -ResourceType StorageAcc | Group-Object Location

    Emit rows to the pipeline and post-process them with ordinary PowerShell.

.NOTES
    Exit codes:
      0  the scan completed and proved what it reports: every path was
         covered, every inventory read carried the requested key(s), and no
         matched count was inflated by a repeated read
      1  nothing was scanned - no report bundles were found under -Path
      2  the scan completed but some inventories could not be read
      3  the scan completed but did NOT prove what it reports: a path was
         missing or refused, a subtree could not be enumerated, a bundle was
         skipped, the requested key was absent from some or all of the
         inventories read (the summary's CANNOT CONFIRM ABSENCE and PARTIAL
         COVERAGE verdicts and its LOWER BOUND note), OR rows matched while a
         subscription was read more than once (the summary's INFLATED warning),
         so a zero is NOT a confirmed absence or a count is NOT a confirmed
         total. This code exists so a caller reading only $LASTEXITCODE
         reaches the same conclusion the printed summary does. A repeated read
         that matched NO rows cannot hide or inflate anything, so that case
         stays 0 alongside the summary's confirmed zero.
      4  the scan completed but -CsvPath or -JsonPath could not be written

    When more than one condition applies, the lowest matching code is returned
    (1 before 2 before 3 before 4), so a read failure outranks a coverage gap.

    A large match set is best piped or assigned rather than left to format to the
    console, since the rows are emitted to the pipeline after the summary.

    Reads only. Never modifies the scanned tree and never calls Azure.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string[]] $Path,

    [Parameter(Mandatory = $true)]
    [ArgumentCompleter({
            param($CommandName, $ParameterName, $WordToComplete, $CommandAst, $FakeBoundParameters)
            $ServiceDir = Join-Path (Split-Path -Parent $PSCommandPath) 'Services'
            if (-not (Test-Path -LiteralPath $ServiceDir)) { return @() }
            $Names = @(Get-ChildItem -LiteralPath $ServiceDir -Recurse -File -Filter '*.ps1' -ErrorAction SilentlyContinue | ForEach-Object { $_.BaseName })
            @($Names | Sort-Object -Unique | Where-Object { $_ -like "$WordToComplete*" })
        })]
    [ValidateScript({
            $Requested = [string]$_

            $ServiceDir = Join-Path (Split-Path -Parent $PSCommandPath) 'Services'
            if (-not (Test-Path -LiteralPath $ServiceDir))
            {
                throw ("Cannot validate -ResourceType: the Services folder was not found at {0}. Run this script from its own directory in the repo." -f $ServiceDir)
            }
            $Names = @(Get-ChildItem -LiteralPath $ServiceDir -Recurse -File -Filter '*.ps1' -ErrorAction SilentlyContinue | ForEach-Object { $_.BaseName })
            $Valid = @($Names | Sort-Object -Unique)
            if ($Requested -in $Valid) { return $true }

            $Stem = $Requested
            if ($Stem.Length -gt 3) { $Stem = $Stem.Substring(0, 3) }
            $Near = @($Valid | Where-Object { $_ -like ('{0}*' -f $Stem) })

            $Hint = ''
            if ($Near.Count -gt 0) { $Hint = ' Did you mean: {0}?' -f ($Near -join ', ') }
            throw ("Unknown resource type '{0}'.{1} Valid names are the Services/*.ps1 base names: {2}" -f $Requested, $Hint, ($Valid -join ', '))
        })]
    [string[]] $ResourceType,

    [string[]] $SumBy,

    [string]   $GroupBy,

    [string]   $CsvPath,

    [string]   $JsonPath,

    [ValidateRange(1, 128)]
    [int]      $ThrottleLimit = 12,

    [string]   $HeartbeatLogFile
)

$ErrorActionPreference = 'Stop'

$Script:WriteFailed = $false

foreach ($Library in @('Functions/Common.Functions.ps1', 'Functions/FindResource.Functions.ps1'))
{
    $LibraryPath = Join-Path $PSScriptRoot $Library
    if (-not (Test-Path -LiteralPath $LibraryPath -PathType Leaf))
    {
        throw "Cannot find required function library at $LibraryPath"
    }
    . $LibraryPath
}

$FindArgs = @{
    Path          = $Path
    ResourceType  = $ResourceType
    ThrottleLimit = $ThrottleLimit
}
if ($SumBy) { $FindArgs.SumBy = $SumBy }
if ($GroupBy) { $FindArgs.GroupBy = $GroupBy }
if ($HeartbeatLogFile) { $FindArgs.HeartbeatLogFile = $HeartbeatLogFile }

$Result = Find-RdaResource @FindArgs

Write-RdaFindSummary -Result $Result

$Rows = @($Result.Rows)

if ($CsvPath)
{
    if ($Rows.Count -gt 0)
    {
        $Union = Get-RdaRowField -Rows $Rows
        try
        {
            $Rows | Select-Object -Property $Union | Export-Csv -LiteralPath $CsvPath -NoTypeInformation -Encoding UTF8
            Write-Host ('  Wrote {0} row(s), {1} column(s) to {2}' -f $Rows.Count, @($Union).Count, $CsvPath) -ForegroundColor Cyan
        }
        catch
        {
            Write-Host ('  ERROR: could not write {0}: {1}' -f $CsvPath, $_.Exception.Message) -ForegroundColor Red
            $Script:WriteFailed = $true
        }
    }
    else
    {
        Write-Host ('  No rows matched, so {0} was NOT written.' -f $CsvPath) -ForegroundColor Yellow
    }
}

if ($JsonPath)
{
    if ($Rows.Count -gt 0)
    {
        try
        {
            $Rows | ConvertTo-Json -Depth 6 -AsArray | Set-Content -LiteralPath $JsonPath -Encoding UTF8
            Write-Host ('  Wrote {0} row(s) to {1}' -f $Rows.Count, $JsonPath) -ForegroundColor Cyan
        }
        catch
        {
            Write-Host ('  ERROR: could not write {0}: {1}' -f $JsonPath, $_.Exception.Message) -ForegroundColor Red
            $Script:WriteFailed = $true
        }
    }
    else
    {
        Write-Host ('  No rows matched, so {0} was NOT written.' -f $JsonPath) -ForegroundColor Yellow
    }
}

$Rows

if ([int]$Result.SourceCount -eq 0) { exit 1 }
if (@($Result.Failures).Count -gt 0) { exit 2 }
if ((@($Result.Missing).Count -gt 0) -or
    (@($Result.Rejected).Count -gt 0) -or
    (@($Result.Unreadable).Count -gt 0) -or
    (@($Result.Skipped).Count -gt 0)) { exit 3 }
$Coverage = Get-RdaTypeCoverage -Result $Result
# The empty-map clause is a fail-closed guard for a shape the mandatory, validated
# -ResourceType cannot produce. The duplicate-read clause applies only when rows
# matched: coverage is set-based, so a repeated read can inflate a count but
# cannot hide a row, and the summary calls a duplicated zero a confirmed zero.
if ((@($Coverage.psbase.Keys).Count -eq 0) -or
    (@($Coverage.psbase.Values | Where-Object { $_ -ne 'Full' }).Count -gt 0) -or
    (($Rows.Count -gt 0) -and ([int]$Result.UnitReadAttempts -gt [int]$Result.UnitsRead))) { exit 3 }
if ($Script:WriteFailed) { exit 4 }
exit 0

