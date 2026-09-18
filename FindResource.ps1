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
      0  the scan completed and covered everything requested
      1  nothing was scanned - no report bundles were found under -Path
      2  the scan completed but some inventories could not be read
      3  the scan completed but did NOT cover everything requested (a path was
         missing or refused, a subtree could not be enumerated, or a bundle was
         skipped). The counts are a lower bound, so a zero is NOT a confirmed
         absence. This code exists so a caller reading only $LASTEXITCODE reaches
         the same conclusion the printed summary does.
      4  the scan completed but -CsvPath or -JsonPath could not be written

    A large match set is best piped or assigned rather than left to format to the
    console, since the rows are emitted to the pipeline after the summary.

    Reads only. Never modifies the scanned tree and never calls Azure.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string[]] $Path,

    # Valid collector names are read from the Services tree at bind time (completer + validator below),
    # not a hardcoded [ValidateSet] that would drift; $PSCommandPath because $PSScriptRoot is empty in an attribute scriptblock.
    [Parameter(Mandatory = $true)]
    [ArgumentCompleter({
            param($CommandName, $ParameterName, $WordToComplete, $CommandAst, $FakeBoundParameters)
            $ServiceDir = Join-Path (Split-Path -Parent $PSCommandPath) 'Services'
            if (-not (Test-Path -LiteralPath $ServiceDir)) { return @() }
            $Names = @(Get-ChildItem -LiteralPath $ServiceDir -Recurse -File -Filter '*.ps1' -ErrorAction SilentlyContinue | ForEach-Object { $_.BaseName })
            @($Names | Sort-Object -Unique | Where-Object { $_ -like "$WordToComplete*" })
        })]
    [ValidateScript({
            # Captured FIRST. Inside the Where-Object below, $_ rebinds to the
            # pipeline item, so comparing $_ to $_ would match every name and the
            # "did you mean" hint would list the entire collector set.
            $Requested = [string]$_

            $ServiceDir = Join-Path (Split-Path -Parent $PSCommandPath) 'Services'
            if (-not (Test-Path -LiteralPath $ServiceDir))
            {
                throw ("Cannot validate -ResourceType: the Services folder was not found at {0}. Run this script from its own directory in the repo." -f $ServiceDir)
            }
            $Names = @(Get-ChildItem -LiteralPath $ServiceDir -Recurse -File -Filter '*.ps1' -ErrorAction SilentlyContinue | ForEach-Object { $_.BaseName })
            $Valid = @($Names | Sort-Object -Unique)
            if ($Requested -in $Valid) { return $true }

            # "Did you mean" hint: match on a shared 3-char prefix (not 4) so a dropped/transposed
            # letter like 'VMWre' still shares the stem with 'VMWare' - the very typo shape this catches.
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

# Set when an output file cannot be written, so the run can exit 4
# ("scanned, but a result could not be written") instead of the exit 0
# a scan-only failure would otherwise report.
$Script:WriteFailed = $false

# Common.Functions.ps1 first: it owns Write-RdaProgress, which the scan uses for
# progress on a long run. It is pure function definitions, so dot-sourcing it
# standalone establishes no orchestrator state.
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
        # Project through the UNION of all rows' field names: Export-Csv takes its header from the first
        # object only and drops later columns - schemas differ across resource types / bundle vintages and parallel arrival order.
        $Union = Get-RdaRowField -Rows $Rows
        try
        {
            $Rows | Select-Object -Property $Union | Export-Csv -LiteralPath $CsvPath -NoTypeInformation -Encoding UTF8
            Write-Host ('  Wrote {0} row(s), {1} column(s) to {2}' -f $Rows.Count, @($Union).Count, $CsvPath) -ForegroundColor Cyan
        }
        catch
        {
            # Reported as itself. Left unguarded under $ErrorActionPreference =
            # 'Stop' this would abort after the scan and exit 1, which the exit
            # contract defines as "nothing was scanned" - a misleading answer to
            # what is actually an output-path problem.
            Write-Host ('  ERROR: could not write {0}: {1}' -f $CsvPath, $_.Exception.Message) -ForegroundColor Red
            $Script:WriteFailed = $true
        }
    }
    else
    {
        # Said explicitly rather than leaving an absent file to be interpreted as
        # a failed run.
        Write-Host ('  No rows matched, so {0} was NOT written.' -f $CsvPath) -ForegroundColor Yellow
    }
}

if ($JsonPath)
{
    if ($Rows.Count -gt 0)
    {
        try
        {
            # -AsArray so the top-level shape is invariant. Without it a single
            # match serialises as an object and two or more as an array, forcing
            # every consumer to special-case the one-match run.
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

# Rows go to the pipeline so the caller can post-process them; the summary above
# went to the host, so a pipe into Export-Csv stays clean.
$Rows

# Exit code 3 keeps the exit code and summary in agreement: a scan that refused a revealed bundle or could not
# enumerate a subtree is NOT a confirmed zero and must not exit 0. (An empty match on a complete scan is success.)
if ([int]$Result.SourceCount -eq 0) { exit 1 }
if (@($Result.Failures).Count -gt 0) { exit 2 }
if ((@($Result.Missing).Count -gt 0) -or
    (@($Result.Rejected).Count -gt 0) -or
    (@($Result.Unreadable).Count -gt 0) -or
    (@($Result.Skipped).Count -gt 0)) { exit 3 }
if ($Script:WriteFailed) { exit 4 }
exit 0
