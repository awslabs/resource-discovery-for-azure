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

    # Environment label (e.g. 'Azure CloudShell', 'PowerShell Unix'). Display only.
    $PlatOS
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

# Read input JSON. Top-level keys are service-type names; values are arrays of
# resource records. No schema validation - a new field simply appears as a new
# column in that service's table.
$rawJson = Get-Content -Path $JsonFile -Raw -Encoding utf8
$Inventory = $rawJson | ConvertFrom-Json

# Compute summary stats. Every array-valued key becomes a (service, count)
# pair. Empty services and the "Version" metadata key are filtered out.
$ServiceSummary = @()
foreach ($prop in $Inventory.PSObject.Properties)
{
    if ($prop.Name -eq 'Version') { continue }
    $value = $prop.Value
    if ($null -eq $value) { continue }
    $count = @($value).Count
    if ($count -le 0) { continue }
    $ServiceSummary += [pscustomobject]@{
        Service = $prop.Name
        Count   = $count
    }
}
$ServiceSummary = $ServiceSummary | Sort-Object -Property Count -Descending
$TotalResources = ($ServiceSummary | Measure-Object -Property Count -Sum).Sum

# Detect obfuscation so the header can carry a privacy-posture banner. Sample
# resource Names and Subscription values across the first few populated
# services; if most match the obfuscation signature treat the report as
# obfuscated, else identifiable (the safe default for an unclear posture).
$ObfuscationStatus = 'identifiable'
$obfPattern = '^(prod_|nonprod_)[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
$samples = New-Object System.Collections.Generic.List[string]
foreach ($svc in $ServiceSummary | Select-Object -First 5)
{
    $records = $Inventory.($svc.Service)
    foreach ($r in (@($records) | Select-Object -First 4))
    {
        if ($null -eq $r) { continue }
        if ($r.PSObject.Properties.Name -contains 'Name' -and -not [string]::IsNullOrWhiteSpace([string]$r.Name)) { $samples.Add([string]$r.Name) }
        if ($r.PSObject.Properties.Name -contains 'Subscription' -and -not [string]::IsNullOrWhiteSpace([string]$r.Subscription)) { $samples.Add([string]$r.Subscription) }
    }
}
if ($samples.Count -gt 0)
{
    $obfHits = ($samples | Where-Object { $_ -match $obfPattern }).Count
    if ($obfHits -gt ($samples.Count * 0.7))
    {
        $ObfuscationStatus = 'obfuscated'
    }
}

# Resolve a sensible subscription label for the header.
if ([string]::IsNullOrWhiteSpace($SubscriptionName))
{
    foreach ($svc in $ServiceSummary)
    {
        $records = $Inventory.($svc.Service)
        if ($records -and @($records).Count -gt 0)
        {
            $first = @($records)[0]
            if ($first.PSObject.Properties.Name -contains 'Subscription' -and -not [string]::IsNullOrWhiteSpace($first.Subscription))
            {
                $SubscriptionName = [string]$first.Subscription
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

# === HTML helpers =============================================================
#
# All output is HTML-escaped by default. The report embeds JSON-derived strings
# from a downstream system (Azure Resource Graph) which could legitimately
# contain HTML-significant characters in a name or tag. Escaping at the edge
# is the only safe pattern; we never trust the input.
function ConvertTo-HtmlSafe
{
    param([Parameter(ValueFromPipeline = $true)]$Value)
    process
    {
        if ($null -eq $Value) { return '' }
        $s = [string]$Value
        $s = $s.Replace('&', '&amp;')
        $s = $s.Replace('<', '&lt;')
        $s = $s.Replace('>', '&gt;')
        $s = $s.Replace('"', '&quot;')
        $s = $s.Replace("'", '&#39;')
        return $s
    }
}

# === Chart helpers ============================================================
#
# Hand-rolled SVG. Two chart types: donut (proportions) and horizontal bar
# (top-N counts). Both produce strings that drop straight into the HTML body.
# No JS, no external library, ~5 KB combined.

function New-DonutChart
{
    param(
        [Parameter(Mandatory)] [object[]]$Data,    # array of @{Label; Value}
        [int]$Size = 240,
        [int]$Thickness = 50
    )

    $total = ($Data | Measure-Object -Property Value -Sum).Sum
    if ($total -le 0) { return '<div class="empty">No data</div>' }

    $cx = $Size / 2
    $cy = $Size / 2
    $radius = ($Size / 2) - 10
    $innerRadius = $radius - $Thickness

    # Color palette - colorblind-friendly (Okabe-Ito + neutrals). Wraps if
    # there are more services than colors, which is fine for visual purpose.
    $palette = @(
        '#0072B2', '#E69F00', '#009E73', '#CC79A7', '#56B4E9',
        '#D55E00', '#F0E442', '#999999', '#332288', '#117733',
        '#88CCEE', '#DDCC77', '#CC6677', '#AA4499', '#882255'
    )

    $svg = New-Object System.Text.StringBuilder
    [void]$svg.Append("<svg viewBox='0 0 $Size $Size' class='chart-donut' role='img' aria-label='Resource count by service'>")

    $angleStart = -90.0
    $i = 0
    foreach ($item in $Data)
    {
        $value = [double]$item.Value
        if ($value -le 0) { $i++; continue }
        $sweep = ($value / $total) * 360.0
        $angleEnd = $angleStart + $sweep

        $x1 = $cx + ($radius * [math]::Cos($angleStart * [math]::PI / 180.0))
        $y1 = $cy + ($radius * [math]::Sin($angleStart * [math]::PI / 180.0))
        $x2 = $cx + ($radius * [math]::Cos($angleEnd * [math]::PI / 180.0))
        $y2 = $cy + ($radius * [math]::Sin($angleEnd * [math]::PI / 180.0))
        $largeArc = if ($sweep -gt 180) { 1 } else { 0 }

        $color = $palette[$i % $palette.Count]
        $label = ConvertTo-HtmlSafe $item.Label
        $pct = [math]::Round(($value / $total) * 100, 1)
        $titleText = "$label`: $value ($pct%)"

        $path = "M $cx $cy L $x1 $y1 A $radius $radius 0 $largeArc 1 $x2 $y2 Z"
        [void]$svg.AppendFormat("<path d='{0}' fill='{1}'><title>{2}</title></path>", $path, $color, $titleText)

        $angleStart = $angleEnd
        $i++
    }

    # Inner cutout to make it a donut
    [void]$svg.AppendFormat("<circle cx='{0}' cy='{1}' r='{2}' fill='white' />", $cx, $cy, $innerRadius)
    [void]$svg.AppendFormat("<text x='{0}' y='{1}' text-anchor='middle' class='donut-total'>{2}</text>", $cx, ($cy - 6), $total)
    [void]$svg.AppendFormat("<text x='{0}' y='{1}' text-anchor='middle' class='donut-label'>resources</text>", $cx, ($cy + 14))

    [void]$svg.Append('</svg>')
    return $svg.ToString()
}

function New-BarChart
{
    param(
        [Parameter(Mandatory)] [object[]]$Data,    # array of @{Label; Value}
        [int]$Width = 480,
        [int]$RowHeight = 26,
        [int]$LabelWidth = 160
    )

    if ($Data.Count -eq 0) { return '<div class="empty">No data</div>' }

    $maxValue = ($Data | Measure-Object -Property Value -Maximum).Maximum
    if ($maxValue -le 0) { return '<div class="empty">No data</div>' }

    $height = $RowHeight * $Data.Count + 8
    $barAreaWidth = $Width - $LabelWidth - 60

    $svg = New-Object System.Text.StringBuilder
    [void]$svg.Append("<svg viewBox='0 0 $Width $height' class='chart-bar' role='img' aria-label='Top services by count'>")

    $i = 0
    foreach ($item in $Data)
    {
        $y = ($i * $RowHeight) + 4
        $label = ConvertTo-HtmlSafe $item.Label
        $value = [int]$item.Value
        $barWidth = [int](($value / $maxValue) * $barAreaWidth)
        if ($barWidth -lt 1) { $barWidth = 1 }

        # Label on the left
        [void]$svg.AppendFormat("<text x='{0}' y='{1}' class='bar-label' text-anchor='end'>{2}</text>", ($LabelWidth - 8), ($y + 17), $label)
        # Bar
        [void]$svg.AppendFormat("<rect x='{0}' y='{1}' width='{2}' height='{3}' rx='3' class='bar-fill' />", $LabelWidth, $y, $barWidth, ($RowHeight - 8))
        # Count to the right of the bar
        [void]$svg.AppendFormat("<text x='{0}' y='{1}' class='bar-value'>{2}</text>", ($LabelWidth + $barWidth + 6), ($y + 17), $value)

        $i++
    }

    [void]$svg.Append('</svg>')
    return $svg.ToString()
}

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
        [Parameter(Mandatory)] $Records
    )

    $records = @($Records)
    $count = $records.Count
    if ($count -eq 0)
    {
        return ''
    }

    # Discover columns from the records themselves. Frequency ordering puts
    # the most consistently-populated columns first.
    $colCounts = @{}
    foreach ($r in $records)
    {
        if ($null -eq $r) { continue }
        if ($r -is [string] -or $r -is [int] -or $r -is [bool])
        {
            # Defensive: collectors should emit objects, not scalars. If a
            # scalar slips in, surface it under a fixed column name so the
            # table still renders.
            if (-not $colCounts.ContainsKey('Value')) { $colCounts['Value'] = 0 }
            $colCounts['Value'] += 1
            continue
        }
        foreach ($p in $r.PSObject.Properties)
        {
            if (-not $colCounts.ContainsKey($p.Name)) { $colCounts[$p.Name] = 0 }
            $colCounts[$p.Name] += 1
        }
    }

    # Promote a stable preferred-column order for fields that almost every
    # service has, so the most useful columns lead. Anything not in this list
    # falls back to frequency order.
    $preferredOrder = @('Name', 'Subscription', 'ResourceGroup', 'Location', 'SKU', 'Tier', 'State', 'Status', 'Kind', 'AppType', 'OSType', 'Size')
    $columns = @()
    foreach ($p in $preferredOrder)
    {
        if ($colCounts.ContainsKey($p))
        {
            $columns += $p
            $colCounts.Remove($p)
        }
    }
    # Append remaining columns ordered by descending frequency, but skip
    # nested-object fields (they don't render usefully in a table cell).
    $remaining = $colCounts.GetEnumerator() | Sort-Object -Property Value -Descending | ForEach-Object { $_.Key }
    $columns += $remaining

    # Drop columns that always contain a complex object - they render as
    # "@{...}" which is noise. Detect by sampling the first non-null value.
    $columnsClean = @()
    foreach ($col in $columns)
    {
        $sample = $null
        foreach ($r in $records)
        {
            if ($null -eq $r) { continue }
            $v = $null
            try { $v = $r.$col } catch { $v = $null }
            if ($null -ne $v) { $sample = $v; break }
        }
        if ($null -eq $sample) { $columnsClean += $col; continue }
        if ($sample -is [psobject] -and -not ($sample -is [string]) -and -not ($sample -is [int]) -and -not ($sample -is [bool]) -and -not ($sample -is [double]) -and -not ($sample -is [long]) -and -not ($sample -is [array]))
        {
            # Skip nested objects but keep arrays - we render arrays joined.
            continue
        }
        $columnsClean += $col
    }
    $columns = $columnsClean

    # Cap column count to keep the table readable. 12 is a soft limit that
    # fits the most informative columns without horizontal scroll on most
    # screens.
    if ($columns.Count -gt 12) { $columns = $columns[0..11] }

    # Render header
    $sb = New-Object System.Text.StringBuilder
    $safeServiceName = ConvertTo-HtmlSafe $ServiceName
    $sectionId = ($ServiceName -replace '[^a-zA-Z0-9]', '-').ToLower()
    [void]$sb.AppendFormat('<details class="service-section" id="svc-{0}">', $sectionId)
    [void]$sb.AppendFormat('<summary><span class="svc-name">{0}</span><span class="svc-count">{1}</span></summary>', $safeServiceName, $count)
    [void]$sb.Append('<div class="svc-body">')
    [void]$sb.AppendFormat('<input type="search" class="svc-search" placeholder="Filter {0}..." aria-label="Filter {0}" />', $safeServiceName)
    [void]$sb.Append('<div class="table-scroll"><table class="svc-table"><thead><tr>')
    foreach ($col in $columns)
    {
        $colSafe = ConvertTo-HtmlSafe $col
        [void]$sb.AppendFormat('<th data-col="{0}">{0}</th>', $colSafe)
    }
    [void]$sb.Append('</tr></thead><tbody>')

    foreach ($r in $records)
    {
        [void]$sb.Append('<tr>')
        foreach ($col in $columns)
        {
            $val = $null
            try { $val = $r.$col } catch { $val = $null }

            if ($null -eq $val)
            {
                [void]$sb.Append('<td class="empty">&mdash;</td>')
            }
            elseif ($val -is [array])
            {
                # Render arrays joined. Truncate ID arrays for readability.
                $joined = ($val | ForEach-Object {
                    if ($null -eq $_) { return '' }
                    if ($_ -is [psobject] -and -not ($_ -is [string])) { '(obj)' } else { [string]$_ }
                }) -join ', '
                if ($joined.Length -gt 200) { $joined = $joined.Substring(0, 200) + '...' }
                [void]$sb.AppendFormat('<td>{0}</td>', (ConvertTo-HtmlSafe $joined))
            }
            elseif ($val -is [bool])
            {
                $cls = if ($val) { 'val-true' } else { 'val-false' }
                [void]$sb.AppendFormat('<td class="{0}">{1}</td>', $cls, $val)
            }
            else
            {
                $s = [string]$val
                if ($s.Length -gt 200) { $s = $s.Substring(0, 200) + '...' }
                [void]$sb.AppendFormat('<td>{0}</td>', (ConvertTo-HtmlSafe $s))
            }
        }
        [void]$sb.Append('</tr>')
    }

    [void]$sb.Append('</tbody></table></div></div></details>')
    return $sb.ToString()
}

# === Page assembly ============================================================

# Build the chart row data. Top 10 services by count for the bar chart;
# all services for the donut.
$topN = $ServiceSummary | Select-Object -First 10
$donutData = $ServiceSummary | ForEach-Object { @{ Label = $_.Service; Value = $_.Count } }
$barData   = $topN           | ForEach-Object { @{ Label = $_.Service; Value = $_.Count } }
$donutSvg  = if ($donutData) { New-DonutChart -Data $donutData } else { '<div class="empty">No data</div>' }
$barSvg    = if ($barData)   { New-BarChart   -Data $barData }   else { '<div class="empty">No data</div>' }

# Build per-service tables in summary-order (highest count first) so the
# scroll order matches the bar chart.
$serviceSectionsHtml = New-Object System.Text.StringBuilder
foreach ($svc in $ServiceSummary)
{
    $records = $Inventory.($svc.Service)
    [void]$serviceSectionsHtml.Append((New-ServiceTable -ServiceName $svc.Service -Records $records))
}

$generated = Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'
$titleSafe = ConvertTo-HtmlSafe $Title
$subSafe   = ConvertTo-HtmlSafe $SubscriptionName
$tenantSafe = if ([string]::IsNullOrWhiteSpace($TenantId)) { '' } else { (ConvertTo-HtmlSafe $TenantId) }
$versionSafe = if (-not [string]::IsNullOrWhiteSpace([string]$Version)) { ConvertTo-HtmlSafe ([string]$Version) } else { '' }

# Optional run-stats carried over from the old Excel Overview sheet so no
# information is lost in the HTML migration. Each is rendered only when
# supplied by the caller.
$extractTimeText = ''
if ($ExtractionRunTime -is [TimeSpan])
{
    $extractTimeText = if ($ExtractionRunTime.TotalMinutes -lt 1) { ('{0} Seconds' -f $ExtractionRunTime.Seconds) } else { ('{0} Minutes' -f $ExtractionRunTime.TotalMinutes.ToString('#######.##')) }
}
$reportTimeText = ''
if ($ReportingRunTime -is [TimeSpan])
{
    $reportTimeText = ('{0} Minutes' -f $ReportingRunTime.TotalMinutes.ToString('#######.##'))
}
$platSafe = if ([string]::IsNullOrWhiteSpace([string]$PlatOS)) { '' } else { (ConvertTo-HtmlSafe ([string]$PlatOS)) }

# CSS - inlined. Print rules expand all <details> and strip non-essential
# chrome so Cmd+P produces a clean PDF.
$css = @'
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
.container { max-width: 1280px; margin: 0 auto; padding: 24px; }
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
$js = @'
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
})();
'@

# Build the full document. Using a here-string so the layout reads top-down.
$tenantBlock  = if ([string]::IsNullOrWhiteSpace($tenantSafe))  { '' } else { "<div><b>Tenant:</b> $tenantSafe</div>" }
$versionBlock = if ([string]::IsNullOrWhiteSpace($versionSafe)) { '' } else { "<div><b>RDA version:</b> $versionSafe</div>" }
$extractBlock = if ([string]::IsNullOrWhiteSpace($extractTimeText)) { '' } else { "<div><b>Extraction time:</b> $extractTimeText</div>" }
$reportBlock  = if ([string]::IsNullOrWhiteSpace($reportTimeText))  { '' } else { "<div><b>Reporting time:</b> $reportTimeText</div>" }
$platBlock    = if ([string]::IsNullOrWhiteSpace($platSafe))        { '' } else { "<div><b>Environment:</b> $platSafe</div>" }

# Privacy banner. Obfuscated runs surface a green confirmation; identifiable
# runs surface an amber warning so anyone opening the report is reminded the
# content carries real subscription / resource names.
if ($ObfuscationStatus -eq 'obfuscated')
{
    $privacyBanner = '<div class="privacy-banner obfuscated"><span class="privacy-icon">&#128274;</span><div><b>Obfuscated report.</b> Resource and subscription names have been replaced with deterministic pseudonyms (prod_/nonprod_ prefixes). Real identifiers are not present. Suitable for sharing.</div></div>'
}
else
{
    $privacyBanner = '<div class="privacy-banner identifiable"><span class="privacy-icon">&#9888;</span><div><b>Identifiable report.</b> Contains real subscription, resource group, and resource names. Treat as confidential and avoid sharing outside intended recipients. Re-run with <code>-Obfuscate</code> to produce a sharable report.</div></div>'
}

$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="generator" content="Resource Discovery for Azure (Summary.ps1)">
<title>$titleSafe - $subSafe</title>
<style>
$css
</style>
</head>
<body>
<div class="container">
<header>
<h1>$titleSafe</h1>
<div class="meta">
<div><b>Subscription:</b> $subSafe</div>
$tenantBlock
<div><b>Generated:</b> $generated</div>
$versionBlock
$extractBlock
$reportBlock
$platBlock
<div><b>Total Resources:</b> $TotalResources</div>
<div><b>Service Types:</b> $($ServiceSummary.Count)</div>
</div>
</header>

$privacyBanner

<div class="charts">
<section class="card">
<h2>By Service</h2>
$donutSvg
</section>
<section class="card">
<h2>Top Services by Count</h2>
$barSvg
</section>
</div>

<div class="card" style="margin-bottom: 20px;">
<h2>Services <button id="expand-all" type="button" style="float:right; margin-left:8px;">Expand all</button><button id="collapse-all" type="button" style="float:right;">Collapse all</button></h2>
$($serviceSectionsHtml.ToString())
</div>

<footer>
Generated by Resource Discovery for Azure (RDA) - Summary.ps1
</footer>
</div>
<script>
$js
</script>
</body>
</html>
"@

Set-Content -Path $HtmlFile -Value $html -Encoding utf8
Write-Host ("HTML report written: {0}" -f $HtmlFile) -ForegroundColor Green
Write-Host ("  Total resources: {0:N0} across {1} service type(s)" -f $TotalResources, $ServiceSummary.Count) -ForegroundColor Green
$fileSize = (Get-Item $HtmlFile).Length
Write-Host ("  File size: {0:N0} bytes ({1:N1} KB)" -f $fileSize, ($fileSize / 1KB)) -ForegroundColor Green
if ($ObfuscationStatus -eq 'obfuscated')
{
    Write-Host "  Privacy posture: obfuscated (safe to share)" -ForegroundColor Green
}
else
{
    Write-Host "  Privacy posture: identifiable (contains real names; treat as confidential)" -ForegroundColor Yellow
}
