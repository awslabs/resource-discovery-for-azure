# Summary.ps1
#
# Generates the self-contained HTML report for a Resource Discovery for Azure
# (RDA) run. Reads the aggregated Inventory_*.json produced by the Processing
# phase and writes a single .html file with NO external dependencies (no CDN,
# no JS libraries, no images, no Excel/EPPlus). The output renders in any
# browser and is suitable for emailing, sharing, or opening in Cloud Shell.
#
# This replaces the previous Excel (ImportExcel/EPPlus) report. The data
# pipeline is unchanged: collectors still run in the Processing phase to build
# the Inventory JSON; this script only renders that JSON as HTML.
#
# Invoked from ResourceInventory.ps1 (ProcessSummary) via `& $SummaryPath ...`.
#
# Inputs (Inventory JSON schema):
#   The JSON file is a single object whose top-level keys are service-type
#   names (VirtualMachines, AppServices, StorageAcc, ...) and whose values
#   are arrays of records. Each record has a heterogeneous set of fields,
#   typically including: Name, Subscription, Location, ResourceGroup, ID,
#   plus service-specific fields. The report iterates these dynamically so a
#   new service type added in Services/* surfaces automatically.
#
# Outputs:
#   A single self-contained .html file. ~50 KB framework + ~1 KB per record.
param(
    # Path to the aggregated Inventory_*.json file (input).
    $JsonFile,

    # Path to write the .html report to (output).
    $HtmlFile,

    # Report title shown in <h1>. Defaults to a recognisable label.
    $Title = 'Azure Resource Inventory',

    # Subscription friendly name for the header. If empty, the first
    # resource record's Subscription field is used.
    $SubscriptionName,

    # Tenant ID (display only).
    $TenantId,

    # RDA version string (display only). If empty, falls back to the
    # Version key inside the Inventory JSON.
    $Version,

    # Extraction / reporting run durations (TimeSpan) for the header. Optional;
    # omitted on standalone invocations.
    $ExtractionRunTime,
    $ReportingRunTime,

    # Ordered hashtable of { phase label -> [TimeSpan] } giving a clear per-phase
    # timing breakdown (metrics / collectors / consumption) for the header, so it
    # is obvious which phase dominates a long run. Optional; when omitted only the
    # coarse extraction/total timers are shown.
    $PhaseTimings,

    # Environment label (e.g. 'Azure CloudShell', 'PowerShell Unix'). Display only.
    $PlatOS,

    # Path to the Consumption_*.csv produced by the consumption phase (input,
    # optional). When supplied and non-empty, the report cross-checks the count
    # of running VMs in the inventory against the count of VMs that produced a
    # compute-usage record. A large shortfall indicates consumption data was
    # incomplete for some subscriptions. Omitted on standalone runs and when
    # -SkipConsumption was used; the check is silently skipped in that case.
    $ConsumptionFile,

    # Minimum running-VM-vs-billed shortfall (count) required before the VM
    # billing-coverage banner is shown. Default 0 means any shortfall is
    # surfaced; raise it to suppress small billing-lag noise.
    [int]$VmBillingGapThreshold = 0
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($JsonFile) -or -not (Test-Path -Path $JsonFile -PathType Leaf))
{
    throw "Summary.ps1: Inventory JSON not found at '$JsonFile'."
}
if ([string]::IsNullOrWhiteSpace($HtmlFile))
{
    throw "Summary.ps1: -HtmlFile output path is required."
}

# Shared HTML-summary render helpers (ConvertTo-HtmlSafe / New-DonutChart /
# New-BarChart) live in Functions/AllSubHtmlSummary.Functions.ps1 - the single
# source of truth also used by the aggregate all-subscriptions summary. They are
# NOT in Common.Functions.ps1 on purpose: only the HTML-rendering paths need
# them, so they are dot-sourced only here (and by the wrapper's -MainSummary
# branch) rather than loaded into every entry point. This script sits in
# Extension/, so resolve the sibling Functions/ folder from the repo root.
$RenderFunctionsFile = Join-Path (Split-Path -Path $PSScriptRoot -Parent) 'Functions/AllSubHtmlSummary.Functions.ps1'
if (-not (Test-Path -Path $RenderFunctionsFile -PathType Leaf))
{
    throw "Summary.ps1: shared render helpers not found at '$RenderFunctionsFile'."
}
. $RenderFunctionsFile

# Self-measure the HTML render (JSON read + all fragment building). Summary CANNOT
# measure the collection phases - they already ran and are passed in via
# -PhaseTimings - but it CAN time its own render, so the report shows its own
# generation cost too. Stopped just before the header is assembled; the final
# here-string interpolation + file write after that is trivially fast.
$RenderStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

# Read input JSON. Top-level keys are service-type names; values are arrays of
# resource records. No schema validation - a new field simply appears as a new
# column in that service's table.
$RawJson = Get-Content -Path $JsonFile -Raw -Encoding utf8
$Inventory = $RawJson | ConvertFrom-Json

# Compute summary stats. Every array-valued key becomes a (service, count)
# pair. Empty services and the "Version" metadata key are filtered out.
$ServiceSummary = @()
foreach ($prop in $Inventory.PSObject.Properties)
{
    if ($prop.Name -eq 'Version') { continue }
    $Value = $prop.Value
    if ($null -eq $Value) { continue }
    $Count = @($Value).Count
    if ($Count -le 0) { continue }
    $ServiceSummary += [pscustomobject]@{
        Service = $prop.Name
        Count   = $Count
    }
}
$ServiceSummary = $ServiceSummary | Sort-Object -Property Count -Descending
$TotalResources = ($ServiceSummary | Measure-Object -Property Count -Sum).Sum

# Detect obfuscation so the header can carry a privacy-posture banner. Sample
# resource Names and Subscription values across the first few populated
# services; if most match the obfuscation signature treat the report as
# obfuscated, else identifiable (the safe default for an unclear posture).
$ObfuscationStatus = 'identifiable'
$ObfPattern = '^(prod_|nonprod_)[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
$Samples = New-Object System.Collections.Generic.List[string]
foreach ($svc in $ServiceSummary | Select-Object -First 5)
{
    $Records = $Inventory.($svc.Service)
    foreach ($r in (@($Records) | Select-Object -First 4))
    {
        if ($null -eq $r) { continue }
        if ($r.PSObject.Properties.Name -contains 'Name' -and -not [string]::IsNullOrWhiteSpace([string]$r.Name)) { $Samples.Add([string]$r.Name) }
        if ($r.PSObject.Properties.Name -contains 'Subscription' -and -not [string]::IsNullOrWhiteSpace([string]$r.Subscription)) { $Samples.Add([string]$r.Subscription) }
    }
}
if ($Samples.Count -gt 0)
{
    $ObfHits = ($Samples | Where-Object { $_ -match $ObfPattern }).Count
    if ($ObfHits -gt ($Samples.Count * 0.7))
    {
        $ObfuscationStatus = 'obfuscated'
    }
}

# VM billing-coverage check. The inventory (ARM/Resource Graph) lists every VM
# that EXISTS; the consumption CSV lists VMs that produced a compute-usage
# record in the billing window. A running VM with no compute-usage record is an
# anomaly - it usually means consumption data was incomplete for that VM's
# subscription (auth / billing-scope gap), not that the VM is idle. We compare
# COUNTS only (not identities): the inventory and consumption files obfuscate
# resource ids through different dictionaries, so a per-VM join is impossible in
# an obfuscated report. Counts of distinct tokens are preserved either way.
$VmBilling = $null
if (-not [string]::IsNullOrWhiteSpace($ConsumptionFile) -and (Test-Path -Path $ConsumptionFile -PathType Leaf))
{
    $RunningVmCount = 0
    $VmRecords = $Inventory.VirtualMachines
    if ($VmRecords)
    {
        $RunningVmCount = @($VmRecords | Where-Object { $_.PowerState -match 'running' }).Count
    }

    # Count distinct VM-meter resources in the consumption CSV. A header-only or
    # empty CSV (zero-billing subscription, or -SkipConsumption safety net) has
    # no data rows at all; in that case consumption coverage is unknown, so the
    # check is skipped rather than reporting a false 100% gap. A CSV that DOES
    # have rows but none in the 'Virtual Machines' meter is a legitimate zero -
    # the gap then reflects a real coverage shortfall.
    $BilledVmCount = 0
    $HasConsumptionData = $false
    try
    {
        $Consumption = @(Import-Csv -Path $ConsumptionFile -ErrorAction Stop)
        $HasConsumptionData = ($Consumption.Count -gt 0)
        $BilledVmCount = (@($Consumption | Where-Object { $_.MeterCategory -eq 'Virtual Machines' }).ResourceId | Sort-Object -Unique).Count
    }
    catch
    {
        # Unreadable CSV: leave the check disabled so no banner is rendered.
        $HasConsumptionData = $false
    }

    if ($HasConsumptionData -and $RunningVmCount -gt 0)
    {
        $Gap = $RunningVmCount - $BilledVmCount
        if ($Gap -gt $VmBillingGapThreshold)
        {
            $GapPct = [math]::Round((100.0 * $Gap / $RunningVmCount), 1)
            $VmBilling = [pscustomobject]@{
                Running = $RunningVmCount
                Billed  = $BilledVmCount
                Gap     = $Gap
                GapPct  = $GapPct
            }
        }
    }
}

# Resolve a sensible subscription label for the header.
if ([string]::IsNullOrWhiteSpace($SubscriptionName))
{
    foreach ($svc in $ServiceSummary)
    {
        $Records = $Inventory.($svc.Service)
        if ($Records -and @($Records).Count -gt 0)
        {
            $First = @($Records)[0]
            if ($First.PSObject.Properties.Name -contains 'Subscription' -and -not [string]::IsNullOrWhiteSpace($First.Subscription))
            {
                $SubscriptionName = [string]$First.Subscription
                break
            }
        }
    }
    if ([string]::IsNullOrWhiteSpace($SubscriptionName)) { $SubscriptionName = '(unknown)' }
}

# Resolve version: explicit -Version wins, else the JSON's Version key.
if ([string]::IsNullOrWhiteSpace([string]$Version) -and $null -ne $Inventory.Version)
{
    $Version = [string]$Inventory.Version
}

# === HTML + chart helpers ====================================================
#
# ConvertTo-HtmlSafe / New-DonutChart / New-BarChart now live in
# Functions/AllSubHtmlSummary.Functions.ps1 (dot-sourced near the top of this
# script) so the per-subscription report and the aggregate all-subscriptions
# summary share ONE copy instead of duplicating them. Behaviour is unchanged;
# see that file for the definitions.

# === Per-service table builder ================================================
#
# Each service section is an HTML <details> element (so it's collapsible
# without any JS) wrapping a search input + a sortable <table>.
#
# Column selection: the union of all field names across the records, ordered
# by frequency. This avoids the trap of letting a single record with many
# fields blow out the column list.

function New-ServiceTable
{
    param(
        [Parameter(Mandatory)] [string]$ServiceName,
        [Parameter(Mandatory)] $Records,
        # When the report is obfuscated, certain columns carry only opaque
        # pseudonym GUIDs (the resource ID and the scale-set reference) and add
        # no analytical value, so they are dropped to reduce horizontal width.
        [string]$ObfuscationStatus = 'identifiable'
    )

    $Records = @($Records)
    $Count = $Records.Count
    if ($Count -eq 0)
    {
        return ''
    }

    # Discover columns from the records themselves. Frequency ordering puts
    # the most consistently-populated columns first.
    $ColCounts = @{}
    foreach ($r in $Records)
    {
        if ($null -eq $r) { continue }
        if ($r -is [string] -or $r -is [int] -or $r -is [bool])
        {
            # Defensive: collectors should emit objects, not scalars. If a
            # scalar slips in, surface it under a fixed column name so the
            # table still renders.
            if (-not $ColCounts.ContainsKey('Value')) { $ColCounts['Value'] = 0 }
            $ColCounts['Value'] += 1
            continue
        }
        foreach ($p in $r.PSObject.Properties)
        {
            if (-not $ColCounts.ContainsKey($p.Name)) { $ColCounts[$p.Name] = 0 }
            $ColCounts[$p.Name] += 1
        }
    }

    # Promote a stable preferred-column order for fields that almost every
    # service has, so the most useful columns lead. Anything not in this list
    # falls back to frequency order.
    $PreferredOrder = @('Name', 'Subscription', 'ResourceGroup', 'Location', 'SKU', 'Tier', 'State', 'Status', 'Kind', 'AppType', 'OSType', 'OS', 'OSName', 'OSVersion', 'Size')
    $Columns = @()
    foreach ($p in $PreferredOrder)
    {
        if ($ColCounts.ContainsKey($p))
        {
            $Columns += $p
            $ColCounts.Remove($p)
        }
    }
    # Append remaining columns ordered by descending frequency, but skip
    # nested-object fields (they don't render usefully in a table cell).
    # Tie-break on the column name (ascending) so the order is fully
    # deterministic: without a secondary key, equal-frequency columns fall back
    # to the enumeration order of an unordered hashtable, which varies run to
    # run and made columns (e.g. OSName) drift in and out of the 12-column cap.
    $Remaining = $ColCounts.GetEnumerator() | Sort-Object -Property @{ Expression = 'Value'; Descending = $true }, @{ Expression = 'Key'; Descending = $false } | ForEach-Object { $_.Key }
    $Columns += $Remaining

    # Drop columns that always contain a complex object - they render as
    # "@{...}" which is noise. Detect by sampling the first non-null value.
    $ColumnsClean = @()
    foreach ($col in $Columns)
    {
        $Sample = $null
        foreach ($r in $Records)
        {
            if ($null -eq $r) { continue }
            $V = $null
            try { $V = $r.$col } catch { $V = $null }
            if ($null -ne $V) { $Sample = $V; break }
        }
        if ($null -eq $Sample) { $ColumnsClean += $col; continue }
        if ($Sample -is [psobject] -and -not ($Sample -is [string]) -and -not ($Sample -is [int]) -and -not ($Sample -is [bool]) -and -not ($Sample -is [double]) -and -not ($Sample -is [long]) -and -not ($Sample -is [array]))
        {
            # Skip nested objects but keep arrays - we render arrays joined.
            continue
        }
        $ColumnsClean += $col
    }
    $Columns = $ColumnsClean

    # When the report is obfuscated, drop columns that carry only opaque
    # pseudonym GUIDs and add no analytical value (the full resource ID and the
    # scale-set reference). Identity columns (Name/Subscription/ResourceGroup)
    # are kept because they still let rows be correlated.
    if ($ObfuscationStatus -eq 'obfuscated')
    {
        $ObfuscatedNoiseColumns = @('ID', 'Set')
        $Columns = $Columns | Where-Object { $ObfuscatedNoiseColumns -notcontains $_ }
    }

    # A 12-column cap used to be applied here to avoid horizontal scrolling on
    # narrow screens, but it silently DROPPED genuinely useful collected columns
    # (e.g. ImageSku = the OS image edition, OSType). Now that every table has a
    # synced top+bottom horizontal scrollbar (see .table-scroll-top /
    # setupTopScroll in the CSS/JS), the width is fully navigable, so ALL
    # collected columns are shown rather than hidden behind a cap.

    # Render header
    $Sb = New-Object System.Text.StringBuilder
    $SafeServiceName = ConvertTo-HtmlSafe $ServiceName
    $SectionId = ($ServiceName -replace '[^a-zA-Z0-9]', '-').ToLower()
    [void]$Sb.AppendFormat('<details class="service-section" id="svc-{0}">', $SectionId)
    [void]$Sb.AppendFormat('<summary><span class="svc-name">{0}</span><span class="svc-count">{1}</span></summary>', $SafeServiceName, $Count)
    [void]$Sb.Append('<div class="svc-body">')
    [void]$Sb.AppendFormat('<input type="search" class="svc-search" placeholder="Filter {0}..." aria-label="Filter {0}" />', $SafeServiceName)
    [void]$Sb.Append('<div class="table-scroll"><table class="svc-table"><thead><tr>')
    foreach ($col in $Columns)
    {
        $ColSafe = ConvertTo-HtmlSafe $col
        [void]$Sb.AppendFormat('<th data-col="{0}">{0}</th>', $ColSafe)
    }
    [void]$Sb.Append('</tr></thead><tbody>')

    foreach ($r in $Records)
    {
        [void]$Sb.Append('<tr>')
        foreach ($col in $Columns)
        {
            $Val = $null
            try { $Val = $r.$col } catch { $Val = $null }

            if ($null -eq $Val)
            {
                [void]$Sb.Append('<td class="empty">&mdash;</td>')
            }
            elseif ($Val -is [array])
            {
                # Render arrays joined. Truncate ID arrays for readability.
                $Joined = ($Val | ForEach-Object {
                        if ($null -eq $_) { return '' }
                        if ($_ -is [string]) { return [string]$_ }
                        # Tag-style objects ({ Name; Value }) - e.g. the Tags column -
                        # render as key=value instead of an opaque placeholder. Any
                        # other object falls back to its default string form (e.g.
                        # "@{...}") rather than "(obj)".
                        if ($_ -is [psobject])
                        {
                            $ElemProps = @($_.PSObject.Properties.Name)
                            if (($ElemProps -contains 'Name') -and ($ElemProps -contains 'Value'))
                            {
                                return ('{0}={1}' -f $_.Name, $_.Value)
                            }
                        }
                        [string]$_
                    }) -join ', '
                if ($Joined.Length -gt 200) { $Joined = $Joined.Substring(0, 200) + '...' }
                [void]$Sb.AppendFormat('<td>{0}</td>', (ConvertTo-HtmlSafe $Joined))
            }
            elseif ($Val -is [bool])
            {
                $Cls = if ($Val) { 'val-true' } else { 'val-false' }
                [void]$Sb.AppendFormat('<td class="{0}">{1}</td>', $Cls, $Val)
            }
            else
            {
                $S = [string]$Val
                if ($S.Length -gt 200) { $S = $S.Substring(0, 200) + '...' }
                [void]$Sb.AppendFormat('<td>{0}</td>', (ConvertTo-HtmlSafe $S))
            }
        }
        [void]$Sb.Append('</tr>')
    }

    [void]$Sb.Append('</tbody></table></div></div></details>')
    return $Sb.ToString()
}

# === Page assembly ============================================================

# Build the chart row data. Top 10 services by count for the bar chart;
# all services for the donut.
$TopN = $ServiceSummary | Select-Object -First 10
$DonutData = $ServiceSummary | ForEach-Object { @{ Label = $_.Service; Value = $_.Count } }
$BarData = $TopN           | ForEach-Object { @{ Label = $_.Service; Value = $_.Count } }
$DonutSvg = if ($DonutData) { New-DonutChart -Data $DonutData } else { '<div class="empty">No data</div>' }
$BarSvg = if ($BarData) { New-BarChart   -Data $BarData }   else { '<div class="empty">No data</div>' }

# Build per-service tables in summary-order (highest count first) so the
# scroll order matches the bar chart.
$ServiceSectionsHtml = New-Object System.Text.StringBuilder
foreach ($svc in $ServiceSummary)
{
    $Records = $Inventory.($svc.Service)
    [void]$ServiceSectionsHtml.Append((New-ServiceTable -ServiceName $svc.Service -Records $Records -ObfuscationStatus $ObfuscationStatus))
}

$Generated = Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'
$TitleSafe = ConvertTo-HtmlSafe $Title
$SubSafe = ConvertTo-HtmlSafe $SubscriptionName
$TenantSafe = if ([string]::IsNullOrWhiteSpace($TenantId)) { '' } else { (ConvertTo-HtmlSafe $TenantId) }
$VersionSafe = if (-not [string]::IsNullOrWhiteSpace([string]$Version)) { ConvertTo-HtmlSafe ([string]$Version) } else { '' }

# Optional run-stats carried over from the old Excel Overview sheet so no
# information is lost in the HTML migration. Each is rendered only when
# supplied by the caller.
$ExtractTimeText = ''
if ($ExtractionRunTime -is [TimeSpan])
{
    $ExtractTimeText = if ($ExtractionRunTime.TotalMinutes -lt 1) { ('{0} Seconds' -f $ExtractionRunTime.Seconds) } else { ('{0} Minutes' -f $ExtractionRunTime.TotalMinutes.ToString('#######.##')) }
}
$ReportTimeText = ''
if ($ReportingRunTime -is [TimeSpan])
{
    $ReportTimeText = if ($ReportingRunTime.TotalMinutes -lt 1) { ('{0} Seconds' -f [int]$ReportingRunTime.TotalSeconds) } else { ('{0} Minutes' -f $ReportingRunTime.TotalMinutes.ToString('#######.##')) }
}
$PlatSafe = if ([string]::IsNullOrWhiteSpace([string]$PlatOS)) { '' } else { (ConvertTo-HtmlSafe ([string]$PlatOS)) }

# CSS - inlined. Print rules expand all <details> and strip non-essential
# chrome so Cmd+P produces a clean PDF.
$Css = @'
:root {
    --bg: #fafbfc;
    --panel: #ffffff;
    --border: #e1e4e8;
    --text: #24292e;
    --muted: #6a737d;
    --accent: #0366d6;
    --accent-soft: #f1f8ff;
    --bar-fill: #0072B2;
    --row-alt: #f6f8fa;
    --warn: #d73a49;
    --good: #28a745;
}
* { box-sizing: border-box; }
body {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    margin: 0;
    padding: 0;
    background: var(--bg);
    color: var(--text);
    font-size: 14px;
    line-height: 1.5;
}
.container { max-width: 1800px; margin: 0 auto; padding: 24px; }
@media (min-width: 1980px) { .container { max-width: 95%; } }
header {
    background: var(--panel);
    border: 1px solid var(--border);
    border-radius: 6px;
    padding: 20px 24px;
    margin-bottom: 20px;
}
header h1 { margin: 0 0 8px 0; font-size: 22px; }
.meta { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 8px 24px; color: var(--muted); font-size: 13px; }
.meta b { color: var(--text); font-weight: 600; }
.charts {
    display: grid;
    grid-template-columns: 280px 1fr;
    gap: 20px;
    margin-bottom: 20px;
}
@media (max-width: 768px) { .charts { grid-template-columns: 1fr; } }
.card {
    background: var(--panel);
    border: 1px solid var(--border);
    border-radius: 6px;
    padding: 16px 20px;
}
.card h2 { margin: 0 0 12px 0; font-size: 14px; font-weight: 600; color: var(--muted); text-transform: uppercase; letter-spacing: 0.05em; }
.chart-donut { width: 100%; height: auto; }
.chart-bar   { width: 100%; height: auto; }
.donut-total { font-size: 24px; font-weight: 600; fill: var(--text); }
.donut-label { font-size: 11px; fill: var(--muted); }
.bar-fill    { fill: var(--bar-fill); }
.bar-label   { font-size: 12px; fill: var(--text); }
.bar-value   { font-size: 12px; fill: var(--muted); }
.svc-section, .service-section {
    background: var(--panel);
    border: 1px solid var(--border);
    border-radius: 6px;
    margin-bottom: 8px;
    overflow: hidden;
}
.service-section summary {
    padding: 12px 20px;
    cursor: pointer;
    display: flex;
    justify-content: space-between;
    align-items: center;
    user-select: none;
    list-style: none;
}
.service-section summary::-webkit-details-marker { display: none; }
.service-section summary::before {
    content: '\25B6';
    font-size: 10px;
    margin-right: 10px;
    color: var(--muted);
    transition: transform 150ms;
    display: inline-block;
}
.service-section[open] summary::before { transform: rotate(90deg); }
.svc-name { font-weight: 600; font-size: 15px; }
.svc-count {
    background: var(--accent-soft);
    color: var(--accent);
    border-radius: 12px;
    padding: 2px 10px;
    font-size: 12px;
    font-weight: 600;
}
.svc-body { padding: 0 20px 16px 20px; border-top: 1px solid var(--border); }
.svc-search {
    width: 100%;
    padding: 8px 12px;
    margin-top: 12px;
    margin-bottom: 12px;
    border: 1px solid var(--border);
    border-radius: 4px;
    font-size: 13px;
    font-family: inherit;
}
.table-scroll { overflow-x: auto; }
/* Force a visible horizontal scrollbar even on macOS (which hides overlay
   scrollbars until scroll). Insurance for narrow screens / wide tables. */
.table-scroll { scrollbar-width: thin; scrollbar-color: #b0b6bd transparent; }
.table-scroll::-webkit-scrollbar { height: 10px; }
.table-scroll::-webkit-scrollbar-track { background: var(--row-alt); border-radius: 5px; }
.table-scroll::-webkit-scrollbar-thumb { background: #b0b6bd; border-radius: 5px; }
.table-scroll::-webkit-scrollbar-thumb:hover { background: #8a9099; }
/* Synced TOP horizontal scrollbar for wide tables. The native scrollbar sits at
   the BOTTOM of a tall table (hundreds of rows) and is unreachable without
   scrolling the whole page down; this mirror sits ABOVE the table so far-right
   columns can be reached immediately. The element is injected by JS. */
.table-scroll-top { overflow-x: auto; overflow-y: hidden; scrollbar-width: thin; scrollbar-color: #b0b6bd transparent; }
.table-scroll-top::-webkit-scrollbar { height: 10px; }
.table-scroll-top::-webkit-scrollbar-track { background: var(--row-alt); border-radius: 5px; }
.table-scroll-top::-webkit-scrollbar-thumb { background: #b0b6bd; border-radius: 5px; }
.table-scroll-top::-webkit-scrollbar-thumb:hover { background: #8a9099; }
.table-scroll-top-inner { height: 1px; }
.svc-table { border-collapse: collapse; width: 100%; font-size: 12.5px; }
.svc-table th, .svc-table td { padding: 6px 10px; text-align: left; border-bottom: 1px solid var(--border); white-space: nowrap; }
.svc-table th { background: var(--row-alt); font-weight: 600; cursor: pointer; user-select: none; }
.svc-table th:hover { background: #ebedef; }
.svc-table th[data-sort="asc"]::after { content: ' \25B2'; color: var(--accent); font-size: 10px; }
.svc-table th[data-sort="desc"]::after { content: ' \25BC'; color: var(--accent); font-size: 10px; }
.svc-table tbody tr:nth-child(even) { background: var(--row-alt); }
.svc-table .empty { color: var(--muted); }
.svc-table .val-true  { color: var(--good); font-weight: 600; }
.svc-table .val-false { color: var(--warn); }
footer {
    margin-top: 24px;
    padding: 16px 0;
    color: var(--muted);
    font-size: 12px;
    text-align: center;
    border-top: 1px solid var(--border);
}
.empty { padding: 16px; text-align: center; color: var(--muted); }
.privacy-banner {
    border-radius: 6px;
    padding: 10px 16px;
    margin-bottom: 16px;
    font-size: 13px;
    display: flex;
    align-items: center;
    gap: 10px;
}
.privacy-banner.obfuscated {
    background: #d4edda;
    border: 1px solid #28a745;
    color: #155724;
}
.privacy-banner.identifiable {
    background: #fff3cd;
    border: 1px solid #ffc107;
    color: #856404;
}
.privacy-banner b { font-weight: 600; }
.privacy-icon { font-size: 16px; }
.coverage-banner {
    border-radius: 6px;
    padding: 10px 16px;
    margin-bottom: 16px;
    font-size: 13px;
    display: flex;
    align-items: center;
    gap: 10px;
    background: #fff3cd;
    border: 1px solid #ffc107;
    color: #856404;
}
.coverage-banner b { font-weight: 600; }
.coverage-icon { font-size: 16px; }
@media print {
    body { background: white; font-size: 11px; }
    .container { max-width: none; padding: 12px; }
    .charts { display: block; }
    .card { break-inside: avoid; margin-bottom: 12px; }
    .service-section { break-inside: avoid; }
    .service-section[open] summary::before { transform: rotate(90deg); }
    .service-section { page-break-inside: auto; }
    details > summary { pointer-events: none; }
    details > div { display: block !important; }
    .svc-search { display: none; }
}
'@

# JS - also inlined. Provides per-table search + click-to-sort. Vanilla,
# no dependencies. Tables degrade to plain HTML if JS is disabled.
$Js = @'
(function () {
    "use strict";

    // Per-section search filter
    function attachSearch(input) {
        var section = input.closest('.service-section');
        if (!section) return;
        var rows = section.querySelectorAll('tbody tr');
        input.addEventListener('input', function () {
            var q = input.value.trim().toLowerCase();
            var visible = 0;
            rows.forEach(function (tr) {
                var match = !q || tr.textContent.toLowerCase().indexOf(q) !== -1;
                tr.style.display = match ? '' : 'none';
                if (match) visible++;
            });
        });
    }

    // Click-to-sort on column header
    function attachSort(table) {
        var headers = table.querySelectorAll('thead th');
        headers.forEach(function (th, idx) {
            th.addEventListener('click', function () {
                var dir = th.dataset.sort === 'asc' ? 'desc' : 'asc';
                headers.forEach(function (h) { h.dataset.sort = ''; });
                th.dataset.sort = dir;

                var tbody = table.querySelector('tbody');
                var rows = Array.prototype.slice.call(tbody.querySelectorAll('tr'));
                rows.sort(function (a, b) {
                    var av = (a.children[idx] && a.children[idx].textContent || '').trim();
                    var bv = (b.children[idx] && b.children[idx].textContent || '').trim();
                    // Numeric sort if both look numeric
                    var an = parseFloat(av);
                    var bn = parseFloat(bv);
                    var bothNumeric = !isNaN(an) && !isNaN(bn) && av !== '' && bv !== '';
                    var cmp;
                    if (bothNumeric) cmp = an - bn;
                    else cmp = av.localeCompare(bv);
                    return dir === 'asc' ? cmp : -cmp;
                });
                rows.forEach(function (r) { tbody.appendChild(r); });
            });
        });
    }

    document.querySelectorAll('.svc-search').forEach(attachSearch);
    document.querySelectorAll('.svc-table').forEach(attachSort);

    // "Expand all" / "Collapse all" toolbar
    var btnExpand = document.getElementById('expand-all');
    var btnCollapse = document.getElementById('collapse-all');
    if (btnExpand) btnExpand.addEventListener('click', function () {
        document.querySelectorAll('.service-section').forEach(function (d) { d.open = true; });
    });
    if (btnCollapse) btnCollapse.addEventListener('click', function () {
        document.querySelectorAll('.service-section').forEach(function (d) { d.open = false; });
    });

    // Synced TOP horizontal scrollbar for wide tables. The native scrollbar sits
    // at the BOTTOM of a tall table (e.g. hundreds of VMs) and can't be reached
    // without scrolling the whole page down; this mirror above the table scrolls
    // the same content horizontally so far-right columns are reachable at once.
    // Width is (re)computed when a section is expanded (a collapsed <details> has
    // no dimensions) and on resize. If JS is off the table still scrolls natively.
    function setupTopScroll(wrap) {
        var top = document.createElement('div');
        top.className = 'table-scroll-top';
        var inner = document.createElement('div');
        inner.className = 'table-scroll-top-inner';
        top.appendChild(inner);
        wrap.parentNode.insertBefore(top, wrap);
        function sync() {
            inner.style.width = wrap.scrollWidth + 'px';
            top.style.display = (wrap.scrollWidth > wrap.clientWidth + 1) ? 'block' : 'none';
        }
        top.addEventListener('scroll', function () { wrap.scrollLeft = top.scrollLeft; });
        wrap.addEventListener('scroll', function () { top.scrollLeft = wrap.scrollLeft; });
        var det = wrap.closest('details');
        if (det) det.addEventListener('toggle', function () { if (det.open) sync(); });
        window.addEventListener('resize', sync);
        sync();
    }
    document.querySelectorAll('.table-scroll').forEach(setupTopScroll);
})();
'@

# Build the full document. Using a here-string so the layout reads top-down.
$TenantBlock = if ([string]::IsNullOrWhiteSpace($TenantSafe)) { '' } else { "<div><b>Tenant:</b> $TenantSafe</div>" }
$VersionBlock = if ([string]::IsNullOrWhiteSpace($VersionSafe)) { '' } else { "<div><b>RDA version:</b> $VersionSafe</div>" }
$ExtractBlock = if ([string]::IsNullOrWhiteSpace($ExtractTimeText)) { '' } else { "<div><b>Setup and resource discovery:</b> $ExtractTimeText</div>" }
$ReportBlock = if ([string]::IsNullOrWhiteSpace($ReportTimeText)) { '' } else { "<div><b>Total collection (all phases):</b> $ReportTimeText</div>" }

# Clear per-phase timing breakdown (metrics / collectors / consumption) from
# -PhaseTimings, rendered as individual header lines so it is obvious which phase
# dominates a long run. Labels are our own fixed text; HTML-escaped defensively.
$PhaseBlocks = ''
if ($PhaseTimings)
{
    foreach ($phaseName in $PhaseTimings.Keys)
    {
        $PhaseSpan = $PhaseTimings[$phaseName]
        if ($PhaseSpan -is [TimeSpan])
        {
            $PhaseDurText = if ($PhaseSpan.TotalMinutes -lt 1) { ('{0} Seconds' -f [int]$PhaseSpan.TotalSeconds) } else { ('{0} Minutes' -f $PhaseSpan.TotalMinutes.ToString('#######.##')) }
            $PhaseBlocks += ("<div><b>{0}:</b> {1}</div>" -f (ConvertTo-HtmlSafe ([string]$phaseName)), $PhaseDurText)
        }
    }
}

# Stop the render self-timer now: everything expensive (JSON read + all HTML
# fragment building) is done; only the final here-string assembly + file write
# remain, which are trivially fast.
$RenderStopwatch.Stop()
$RenderTimeText = if ($RenderStopwatch.Elapsed.TotalMinutes -lt 1) { ('{0} Seconds' -f [int]$RenderStopwatch.Elapsed.TotalSeconds) } else { ('{0} Minutes' -f $RenderStopwatch.Elapsed.TotalMinutes.ToString('#######.##')) }
$RenderBlock = "<div><b>Report generation (HTML):</b> $RenderTimeText</div>"
$PlatBlock = if ([string]::IsNullOrWhiteSpace($PlatSafe)) { '' } else { "<div><b>Environment:</b> $PlatSafe</div>" }

# Privacy banner. Obfuscated runs surface a green confirmation; identifiable
# runs surface an amber warning so anyone opening the report is reminded the
# content carries real subscription / resource names.
if ($ObfuscationStatus -eq 'obfuscated')
{
    $PrivacyBanner = '<div class="privacy-banner obfuscated"><span class="privacy-icon">&#128274;</span><div><b>Obfuscated report.</b> Resource and subscription names have been replaced with deterministic pseudonyms (prod_/nonprod_ prefixes). Real identifiers are not present. Suitable for sharing.</div></div>'
}
else
{
    $PrivacyBanner = '<div class="privacy-banner identifiable"><span class="privacy-icon">&#9888;</span><div><b>Identifiable report.</b> Contains real subscription, resource group, and resource names. Treat as confidential and avoid sharing outside intended recipients. Re-run with <code>-Obfuscate</code> to produce a sharable report.</div></div>'
}

# VM billing-coverage banner. Rendered only when the inventory shows materially
# more running VMs than the consumption data billed for (see the $VmBilling
# detection above). Frames the inventory as authoritative and points at
# consumption-collection completeness, not at the report being inaccurate. In
# an obfuscated report the per-VM identities cannot be joined (separate
# dictionaries), so this is a count-level signal; the wording reflects that.
$CoverageBanner = ''
if ($null -ne $VmBilling)
{
    $IdNote = if ($ObfuscationStatus -eq 'obfuscated')
    {
        ' Per-VM identification is unavailable in an obfuscated report; re-run without <code>-Obfuscate</code> (locally) to list the specific VMs.'
    }
    else
    {
        ''
    }
    $CoverageBanner = ('<div class="coverage-banner"><span class="coverage-icon">&#9888;</span><div><b>VM billing-coverage check:</b> {0} running VMs were discovered in the inventory, but only {1} VMs have compute-usage records in the consumption window &mdash; {2} running VMs ({3}%) have no compute charge. This usually means consumption data was incomplete for some subscriptions (auth or billing-scope gaps), not that the VMs are idle. Verify consumption collection for the affected subscriptions.{4}</div></div>' -f $VmBilling.Running, $VmBilling.Billed, $VmBilling.Gap, $VmBilling.GapPct, $IdNote)
}

$Html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="generator" content="Resource Discovery for Azure (Summary.ps1)">
<title>$TitleSafe - $SubSafe</title>
<style>
$Css
</style>
</head>
<body>
<div class="container">
<header>
<h1>$TitleSafe</h1>
<div class="meta">
<div><b>Subscription:</b> $SubSafe</div>
$TenantBlock
<div><b>Generated:</b> $Generated</div>
$VersionBlock
$ExtractBlock
$PhaseBlocks
$ReportBlock
$RenderBlock
$PlatBlock
<div><b>Total Resources:</b> $TotalResources</div>
<div><b>Service Types:</b> $($ServiceSummary.Count)</div>
</div>
</header>

$PrivacyBanner

$CoverageBanner

<div class="charts">
<section class="card">
<h2>By Service</h2>
$DonutSvg
</section>
<section class="card">
<h2>Top Services by Count</h2>
$BarSvg
</section>
</div>

<div class="card" style="margin-bottom: 20px;">
<h2>Services <button id="expand-all" type="button" style="float:right; margin-left:8px;">Expand all</button><button id="collapse-all" type="button" style="float:right;">Collapse all</button></h2>
$($ServiceSectionsHtml.ToString())
</div>

<footer>
Generated by Resource Discovery for Azure (RDA) - Summary.ps1
</footer>
</div>
<script>
$Js
</script>
</body>
</html>
"@

Set-Content -Path $HtmlFile -Value $Html -Encoding utf8
Write-Host ("HTML report written: {0}" -f $HtmlFile) -ForegroundColor Green
Write-Host ("  Total resources: {0:N0} across {1} service type(s)" -f $TotalResources, $ServiceSummary.Count) -ForegroundColor Green
$FileSize = (Get-Item $HtmlFile).Length
Write-Host ("  File size: {0:N0} bytes ({1:N1} KB)" -f $FileSize, ($FileSize / 1KB)) -ForegroundColor Green
if ($ObfuscationStatus -eq 'obfuscated')
{
    Write-Host "  Privacy posture: obfuscated (safe to share)" -ForegroundColor Green
}
else
{
    Write-Host "  Privacy posture: identifiable (contains real names; treat as confidential)" -ForegroundColor Yellow
}
