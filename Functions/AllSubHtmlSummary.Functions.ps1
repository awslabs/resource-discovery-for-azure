#Requires -Version 7.0

# === HTML helpers =============================================================
function ConvertTo-HtmlSafe
{
    param([Parameter(ValueFromPipeline = $true)]$Value)
    process
    {
        if ($null -eq $Value) { return '' }
        $S = [string]$Value
        $S = $S.Replace('&', '&amp;')
        $S = $S.Replace('<', '&lt;')
        $S = $S.Replace('>', '&gt;')
        $S = $S.Replace('"', '&quot;')
        $S = $S.Replace("'", '&#39;')
        return $S
    }
}

# === Chart helpers ============================================================

function New-DonutChart
{
    param(
        [Parameter(Mandatory)] [object[]]$Data,
        [int]$Size = 240,
        [int]$Thickness = 50
    )

    $Total = ($Data | Measure-Object -Property Value -Sum).Sum
    if ($Total -le 0) { return '<div class="empty">No data</div>' }

    $Cx = $Size / 2
    $Cy = $Size / 2
    $Radius = ($Size / 2) - 10
    $InnerRadius = $Radius - $Thickness

    $Palette = @(
        '#0072B2', '#E69F00', '#009E73', '#CC79A7', '#56B4E9',
        '#D55E00', '#F0E442', '#999999', '#332288', '#117733',
        '#88CCEE', '#DDCC77', '#CC6677', '#AA4499', '#882255'
    )

    $Svg = New-Object System.Text.StringBuilder
    [void]$Svg.Append("<svg viewBox='0 0 $Size $Size' class='chart-donut' role='img' aria-label='Resource count by service'>")

    $AngleStart = -90.0
    $i = 0
    foreach ($item in $Data)
    {
        $Value = [double]$item.Value
        if ($Value -le 0) { $i++; continue }
        $Sweep = ($Value / $Total) * 360.0
        $AngleEnd = $AngleStart + $Sweep

        $X1 = $Cx + ($Radius * [math]::Cos($AngleStart * [math]::PI / 180.0))
        $Y1 = $Cy + ($Radius * [math]::Sin($AngleStart * [math]::PI / 180.0))
        $X2 = $Cx + ($Radius * [math]::Cos($AngleEnd * [math]::PI / 180.0))
        $Y2 = $Cy + ($Radius * [math]::Sin($AngleEnd * [math]::PI / 180.0))
        $LargeArc = if ($Sweep -gt 180) { 1 } else { 0 }

        $Color = $Palette[$i % $Palette.Count]
        $Label = ConvertTo-HtmlSafe $item.Label
        $Pct = [math]::Round(($Value / $Total) * 100, 1)
        $TitleText = "$Label`: $Value ($Pct%)"

        $Path = "M $Cx $Cy L $X1 $Y1 A $Radius $Radius 0 $LargeArc 1 $X2 $Y2 Z"
        [void]$Svg.AppendFormat("<path d='{0}' fill='{1}'><title>{2}</title></path>", $Path, $Color, $TitleText)

        $AngleStart = $AngleEnd
        $i++
    }

    [void]$Svg.AppendFormat([cultureinfo]::InvariantCulture, "<circle cx='{0}' cy='{1}' r='{2}' fill='white' />", $Cx, $Cy, $InnerRadius)
    [void]$Svg.AppendFormat([cultureinfo]::InvariantCulture, "<text x='{0}' y='{1}' text-anchor='middle' class='donut-total'>{2}</text>", $Cx, ($Cy - 6), $Total)
    [void]$Svg.AppendFormat([cultureinfo]::InvariantCulture, "<text x='{0}' y='{1}' text-anchor='middle' class='donut-label'>resources</text>", $Cx, ($Cy + 14))

    [void]$Svg.Append('</svg>')
    return $Svg.ToString()
}

function New-BarChart
{
    param(
        [Parameter(Mandatory)] [object[]]$Data,
        [int]$Width = 480,
        [int]$RowHeight = 26,
        [int]$LabelWidth = 160
    )

    if ($Data.Count -eq 0) { return '<div class="empty">No data</div>' }

    $MaxValue = ($Data | Measure-Object -Property Value -Maximum).Maximum
    if ($MaxValue -le 0) { return '<div class="empty">No data</div>' }

    $Height = $RowHeight * $Data.Count + 8
    $BarAreaWidth = $Width - $LabelWidth - 60

    $Svg = New-Object System.Text.StringBuilder
    [void]$Svg.Append("<svg viewBox='0 0 $Width $Height' class='chart-bar' role='img' aria-label='Top services by count'>")

    $i = 0
    foreach ($item in $Data)
    {
        $y = ($i * $RowHeight) + 4
        $Label = ConvertTo-HtmlSafe $item.Label
        $Value = [int]$item.Value
        $BarWidth = [int](($Value / $MaxValue) * $BarAreaWidth)
        if ($BarWidth -lt 1) { $BarWidth = 1 }

        [void]$Svg.AppendFormat("<text x='{0}' y='{1}' class='bar-label' text-anchor='end'>{2}</text>", ($LabelWidth - 8), ($y + 17), $Label)
        [void]$Svg.AppendFormat("<rect x='{0}' y='{1}' width='{2}' height='{3}' rx='3' class='bar-fill' />", $LabelWidth, $y, $BarWidth, ($RowHeight - 8))
        [void]$Svg.AppendFormat("<text x='{0}' y='{1}' class='bar-value'>{2}</text>", ($LabelWidth + $BarWidth + 6), ($y + 17), $Value)

        $i++
    }

    [void]$Svg.Append('</svg>')
    return $Svg.ToString()
}

function New-RdaAllSubHtmlSummary
{
    param(
        [Parameter(Mandatory = $true)] $RunOutputDirectory,

        [Parameter(Mandatory = $true)] $HtmlFile,

        $SinceTime,

        $FailedSubscriptions = @(),
        $ConsumptionFailedSubs = @(),
        $MetricsFailedSubs = @(),
        $CollectorFailures = @(),

        $TenantId,
        $Version,
        $PlatOS,

        [switch]$Detailed,

        [switch]$Obfuscated
    )

    $ErrorActionPreference = 'Stop'

    if ([string]::IsNullOrWhiteSpace($HtmlFile))
    {
        throw 'New-RdaAllSubHtmlSummary: -HtmlFile output path is required.'
    }
    if ([string]::IsNullOrWhiteSpace($RunOutputDirectory) -or -not (Test-Path -LiteralPath $RunOutputDirectory -PathType Container))
    {
        throw "New-RdaAllSubHtmlSummary: -RunOutputDirectory not found: '$RunOutputDirectory'."
    }

    $Folders = @(Get-ChildItem -LiteralPath $RunOutputDirectory -Directory -Filter 'ResourcesReport*' -ErrorAction SilentlyContinue)
    if ($null -ne $SinceTime)
    {
        $Folders = @($Folders | Where-Object { $_.LastWriteTime -ge $SinceTime })
    }

    $ObfPattern = '^(prod_|nonprod_)(databricks_|aks_|vmss_)?[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    $Samples = New-Object System.Collections.Generic.List[string]
    $SubReports = @()
    $ServiceAgg = [ordered]@{}

    foreach ($Folder in $Folders)
    {
        $InvFile = Get-ChildItem -LiteralPath $Folder.FullName -Filter 'Inventory_*.json' -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $InvFile) { continue }
        try
        {
            $Inv = Get-Content -LiteralPath $InvFile.FullName -Raw -Encoding utf8 | ConvertFrom-Json
        }
        catch
        {
            $SubReports += [pscustomobject]@{ Name = ('(unreadable inventory: {0})' -f $Folder.Name); Total = 0; Link = $null; Folder = $Folder.Name }
            continue
        }

        $Total = 0
        $SubName = $null
        foreach ($Prop in $Inv.PSObject.Properties)
        {
            if ($Prop.Name -eq 'Version') { continue }
            $Records = @($Prop.Value | Where-Object { $null -ne $_ })
            if ($Records.Count -le 0) { continue }
            $Total += $Records.Count
            if (-not $ServiceAgg.Contains($Prop.Name)) { $ServiceAgg[$Prop.Name] = 0 }
            $ServiceAgg[$Prop.Name] += $Records.Count
            if (-not $SubName)
            {
                $Named = $Records | Where-Object { ($_.PSObject.Properties.Name -contains 'Subscription') -and -not [string]::IsNullOrWhiteSpace([string]$_.Subscription) } | Select-Object -First 1
                if ($Named) { $SubName = [string]$Named.Subscription }
            }
            foreach ($Rec in ($Records | Select-Object -First 4))
            {
                if (($Rec.PSObject.Properties.Name -contains 'Name') -and -not [string]::IsNullOrWhiteSpace([string]$Rec.Name)) { $Samples.Add([string]$Rec.Name) }
                if (($Rec.PSObject.Properties.Name -contains 'Subscription') -and -not [string]::IsNullOrWhiteSpace([string]$Rec.Subscription)) { $Samples.Add([string]$Rec.Subscription) }
            }
        }
        if (-not $SubName) { $SubName = '(name unavailable - 0 resources)' }

        $HtmlItem = Get-ChildItem -LiteralPath $Folder.FullName -Filter '*.html' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notlike '*_revealed*' } | Select-Object -First 1
        $Link = if ($null -ne $HtmlItem) { (Join-Path $Folder.Name $HtmlItem.Name) } else { $null }

        $SubReports += [pscustomobject]@{ Name = $SubName; Total = $Total; Link = $Link; Folder = $Folder.Name }
    }

    $ObfuscationStatus = 'identifiable'
    if ($Samples.Count -gt 0)
    {
        $ObfHits = ($Samples | Where-Object { $_ -match $ObfPattern }).Count
        if ($ObfHits -gt ($Samples.Count * 0.7)) { $ObfuscationStatus = 'obfuscated' }
    }

    $IsObfuscated = $Obfuscated.IsPresent -or ($ObfuscationStatus -eq 'obfuscated')

    $SubReports = @($SubReports | Sort-Object -Property Total -Descending)
    $RunTotalResources = [int](($SubReports | Measure-Object -Property Total -Sum).Sum)
    $SubCount = $SubReports.Count
    $EmptyCount = @($SubReports | Where-Object { $_.Total -eq 0 }).Count

    $Generated = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz', [cultureinfo]::InvariantCulture)
    $TenantSafe = if ($IsObfuscated -or [string]::IsNullOrWhiteSpace([string]$TenantId)) { '' } else { ConvertTo-HtmlSafe ([string]$TenantId) }
    $VersionSafe = if ([string]::IsNullOrWhiteSpace([string]$Version)) { '' } else { ConvertTo-HtmlSafe ([string]$Version) }
    $PlatSafe = if ([string]::IsNullOrWhiteSpace([string]$PlatOS)) { '' } else { ConvertTo-HtmlSafe ([string]$PlatOS) }

    $PrivacyBanner = if ($ObfuscationStatus -eq 'obfuscated')
    {
        '<div class="privacy-banner obfuscated"><span>&#128274;</span><div><b>Obfuscated.</b> Names shown are deterministic pseudonyms (prod_/nonprod_ prefixes); no real identifiers are present. Safe to share.</div></div>'
    }
    else
    {
        '<div class="privacy-banner identifiable"><span>&#9888;</span><div><b>Identifiable.</b> This summary and the linked reports contain real resource and subscription names. Treat as confidential.</div></div>'
    }

    $FailedList = @(@($FailedSubscriptions) | Where-Object { $_ })
    $ConsumpList = @(@($ConsumptionFailedSubs) | Where-Object { $_ -and $_.Id -ne '(auth)' })
    $MetricsList = @(@($MetricsFailedSubs) | Where-Object { $_ })
    $CollectorList = @(@($CollectorFailures) | Where-Object { $_ })

    $Banners = New-Object System.Text.StringBuilder
    if ($FailedList.Count -gt 0)
    {
        if ($IsObfuscated)
        {
            [void]$Banners.AppendFormat('<div class="banner err"><b>{0} subscription(s) failed to process.</b> These are missing from the totals below.</div>', $FailedList.Count)
        }
        else
        {
            [void]$Banners.AppendFormat('<div class="banner err"><b>{0} subscription(s) failed to process.</b> These are missing from the totals below: {1}</div>', $FailedList.Count, (ConvertTo-HtmlSafe (($FailedList | ForEach-Object { [string]$_ }) -join ', ')))
        }
    }
    if ($EmptyCount -gt 0)
    {
        [void]$Banners.AppendFormat('<div class="banner warn"><b>{0} subscription(s) returned 0 resources.</b> Often a Reader-permission gap rather than a genuinely empty subscription.</div>', $EmptyCount)
    }
    if ($ConsumpList.Count -gt 0)
    {
        if ($IsObfuscated)
        {
            [void]$Banners.AppendFormat('<div class="banner warn"><b>{0} subscription(s) had consumption (billing) issues.</b> Cost data may be incomplete for those subscriptions.</div>', $ConsumpList.Count)
        }
        else
        {
            [void]$Banners.AppendFormat('<div class="banner warn"><b>{0} subscription(s) had consumption (billing) issues.</b> Cost data may be incomplete for: {1}</div>', $ConsumpList.Count, (ConvertTo-HtmlSafe (($ConsumpList | ForEach-Object { [string]$_.Name }) -join ', ')))
        }
    }
    if ($MetricsList.Count -gt 0)
    {
        if ($IsObfuscated)
        {
            [void]$Banners.AppendFormat('<div class="banner warn"><b>{0} subscription(s) had metrics issues.</b> Metric data may be incomplete for those subscriptions.</div>', $MetricsList.Count)
        }
        else
        {
            [void]$Banners.AppendFormat('<div class="banner warn"><b>{0} subscription(s) had metrics issues.</b> Metric data may be incomplete for: {1}</div>', $MetricsList.Count, (ConvertTo-HtmlSafe (($MetricsList | ForEach-Object { [string]$_.Name }) -join ', ')))
        }
    }
    if ($CollectorList.Count -gt 0)
    {
        [void]$Banners.AppendFormat('<div class="banner warn"><b>{0} collector failure(s)</b> across the run (individual resource types that threw during collection).</div>', $CollectorList.Count)
    }

    $ChartsHtml = ''
    if ($Detailed -and $ServiceAgg.Keys.Count -gt 0)
    {
        $DonutData = @($ServiceAgg.GetEnumerator() | ForEach-Object { @{ Label = $_.Key; Value = $_.Value } })
        $TopN = @($ServiceAgg.GetEnumerator() | Sort-Object -Property Value -Descending | Select-Object -First 12 | ForEach-Object { @{ Label = $_.Key; Value = $_.Value } })
        $DonutSvg = New-DonutChart -Data $DonutData
        $BarSvg = New-BarChart -Data $TopN
        $ChartsHtml = "<div class='charts'><div class='chart-card'><h3>Resources by service (run-wide)</h3>$DonutSvg</div><div class='chart-card'><h3>Top services</h3>$BarSvg</div></div>"
    }

    $Rows = New-Object System.Text.StringBuilder
    foreach ($Sr in $SubReports)
    {
        $NameSafe = ConvertTo-HtmlSafe $Sr.Name
        $CountText = $Sr.Total.ToString('N0', [cultureinfo]::InvariantCulture)
        $HealthCell = if ($Sr.Total -eq 0) { '<span class="tag warn">0 resources</span>' } else { '<span class="tag ok">ok</span>' }
        $LinkCell = if ($Sr.Link) { ('<a href="{0}">open &#8599;</a>' -f (ConvertTo-HtmlSafe $Sr.Link)) } else { '<span class="muted">no report</span>' }
        [void]$Rows.AppendFormat('<tr><td>{0}</td><td class="num">{1}</td><td>{2}</td><td>{3}</td></tr>', $NameSafe, $CountText, $HealthCell, $LinkCell)
    }
    if ($SubReports.Count -eq 0)
    {
        [void]$Rows.Append('<tr><td colspan="4" class="muted">No per-subscription reports were found in the run output directory.</td></tr>')
    }

    $MetaBits = @()
    if ($TenantSafe) { $MetaBits += "<div><b>Tenant:</b> $TenantSafe</div>" }
    if ($VersionSafe) { $MetaBits += "<div><b>RDA version:</b> $VersionSafe</div>" }
    if ($PlatSafe) { $MetaBits += "<div><b>Environment:</b> $PlatSafe</div>" }
    $MetaBits += "<div><b>Generated:</b> $Generated</div>"
    $MetaHtml = ($MetaBits -join '')

    $Css = @'
:root{--bg:#f6f8fa;--card:#fff;--ink:#1b1f24;--muted:#57606a;--line:#d0d7de;--accent:#0969da}
*{box-sizing:border-box}body{margin:0;font:14px/1.5 -apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;color:var(--ink);background:var(--bg)}
.wrap{max-width:1100px;margin:0 auto;padding:24px}
h1{font-size:22px;margin:0 0 4px}h3{margin:0 0 8px;font-size:14px;color:var(--muted)}
.meta{color:var(--muted);font-size:12px;display:flex;gap:16px;flex-wrap:wrap;margin-bottom:16px}
.privacy-banner{display:flex;gap:10px;align-items:flex-start;padding:10px 14px;border-radius:8px;margin:12px 0;font-size:13px}
.privacy-banner.obfuscated{background:#ddf4e4;border:1px solid #52c41a}
.privacy-banner.identifiable{background:#fff3cd;border:1px solid #e0b000}
.banner{padding:10px 14px;border-radius:8px;margin:8px 0;font-size:13px}
.banner.err{background:#ffebe9;border:1px solid #ff818a}.banner.warn{background:#fff8c5;border:1px solid #e0c000}
.cards{display:flex;gap:12px;flex-wrap:wrap;margin:16px 0}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:14px 18px;min-width:150px}
.card .n{font-size:26px;font-weight:700}.card .l{color:var(--muted);font-size:12px}
.charts{display:flex;gap:16px;flex-wrap:wrap;margin:16px 0}
.chart-card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:14px}
.chart-donut{width:240px;height:240px}.chart-bar{width:100%;max-width:520px}
.donut-total{font-size:26px;font-weight:700}.donut-label{font-size:12px;fill:var(--muted)}
.bar-label{font-size:12px;fill:var(--ink)}.bar-value{font-size:12px;fill:var(--muted)}.bar-fill{fill:var(--accent)}
table{width:100%;border-collapse:collapse;background:var(--card);border:1px solid var(--line);border-radius:10px;overflow:hidden}
th,td{text-align:left;padding:8px 12px;border-bottom:1px solid var(--line)}th{background:#f0f3f6;font-size:12px;text-transform:uppercase;letter-spacing:.03em;color:var(--muted)}
td.num,th.num{text-align:right;font-variant-numeric:tabular-nums}
.tag{display:inline-block;padding:1px 8px;border-radius:999px;font-size:12px}.tag.ok{background:#ddf4e4;color:#1a7f37}.tag.warn{background:#fff1c2;color:#7a5c00}
.muted{color:var(--muted)}a{color:var(--accent);text-decoration:none}a:hover{text-decoration:underline}
footer{color:var(--muted);font-size:12px;margin-top:20px}
'@

    $Html = @"
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Azure Resource Discovery - Run Summary</title><style>$Css</style></head>
<body><div class="wrap">
<h1>Azure Resource Discovery &mdash; Run Summary</h1>
<div class="meta">$MetaHtml</div>
$PrivacyBanner
$($Banners.ToString())
<div class="cards">
  <div class="card"><div class="n">$($RunTotalResources.ToString('N0', [cultureinfo]::InvariantCulture))</div><div class="l">Total resources</div></div>
  <div class="card"><div class="n">$SubCount</div><div class="l">Subscriptions</div></div>
  <div class="card"><div class="n">$EmptyCount</div><div class="l">Empty (0 resources)</div></div>
  <div class="card"><div class="n">$($FailedList.Count)</div><div class="l">Failed</div></div>
</div>
$ChartsHtml
<table><thead><tr><th>Subscription</th><th class="num">Resources</th><th>Health</th><th>Report</th></tr></thead>
<tbody>$($Rows.ToString())</tbody></table>
<footer>Resource Discovery for Azure$(if ($VersionSafe){" v$VersionSafe"}). Aggregate summary built from on-disk per-subscription reports; no Azure calls. Links open each subscription's own report.</footer>
</div></body></html>
"@

    $Html | Out-File -LiteralPath $HtmlFile -Encoding utf8
    Write-Host ("Main summary written: {0}" -f $HtmlFile) -ForegroundColor Green
    Write-Host ("  {0} subscription(s), {1} total resource(s), {2} empty, {3} failed. Privacy: {4}." -f $SubCount, $RunTotalResources.ToString('N0', [cultureinfo]::InvariantCulture), $EmptyCount, $FailedList.Count, $ObfuscationStatus) -ForegroundColor DarkGray
}

function New-RdaAllSubHtmlSummaryFromZip
{
    param(
        [Parameter(Mandatory = $true)] $InputZip,

        $OutputDirectory,

        $HtmlFile,

        [switch]$Detailed,

        [switch]$PackageZip,

        [switch]$KeepOriginalReports,

        $TenantId,
        $Version,
        $PlatOS
    )

    $ErrorActionPreference = 'Stop'

    if ([string]::IsNullOrWhiteSpace($InputZip) -or -not (Test-Path -LiteralPath $InputZip -PathType Leaf))
    {
        throw "New-RdaAllSubHtmlSummaryFromZip: -InputZip not found: '$InputZip'."
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $ZipItem = Get-Item -LiteralPath $InputZip
    if ([string]::IsNullOrWhiteSpace($OutputDirectory))
    {
        $BaseName = [System.IO.Path]::GetFileNameWithoutExtension($ZipItem.Name)
        $OutputDirectory = Join-Path $ZipItem.DirectoryName ($BaseName + '_MainSummary')
    }
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    $OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path

    if ([string]::IsNullOrWhiteSpace($HtmlFile))
    {
        $HtmlFile = Join-Path $OutputDirectory 'MainSummary.html'
    }

    $Staging = Join-Path ([System.IO.Path]::GetTempPath()) ('RdaFromZip_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $Staging -Force | Out-Null
    try
    {
        Expand-Archive -LiteralPath $InputZip -DestinationPath $Staging -Force
        $InnerZips = @(Get-ChildItem -LiteralPath $Staging -Recurse -Filter 'ResourcesReport*.zip' -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notlike '*_revealed*' })

        $Reconstructed = 0
        foreach ($InnerZip in $InnerZips)
        {
            $FolderName = [System.IO.Path]::GetFileNameWithoutExtension($InnerZip.Name)
            $Dest = Join-Path $OutputDirectory $FolderName
            New-Item -ItemType Directory -Path $Dest -Force | Out-Null
            $Archive = [System.IO.Compression.ZipFile]::OpenRead($InnerZip.FullName)
            try
            {
                foreach ($Entry in $Archive.Entries)
                {
                    if (($Entry.Name -like 'Inventory_*.json') -or (($Entry.Name -like '*.html') -and ($Entry.Name -notlike '*_revealed*')))
                    {
                        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($Entry, (Join-Path $Dest $Entry.Name), $true)
                    }
                }
            }
            finally { $Archive.Dispose() }
            $Reconstructed++
        }

        if ($Reconstructed -eq 0)
        {
            $ExtractedFolders = @(Get-ChildItem -LiteralPath $Staging -Recurse -Directory -Filter 'ResourcesReport*' -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -notlike '*_revealed*' })
            foreach ($Ef in $ExtractedFolders)
            {
                $Files = @(Get-ChildItem -LiteralPath $Ef.FullName -File -ErrorAction SilentlyContinue | Where-Object { ($_.Name -like 'Inventory_*.json') -or (($_.Name -like '*.html') -and ($_.Name -notlike '*_revealed*')) })
                if ($Files.Count -eq 0) { continue }
                $Dest = Join-Path $OutputDirectory $Ef.Name
                New-Item -ItemType Directory -Path $Dest -Force | Out-Null
                foreach ($F in $Files) { Copy-Item -LiteralPath $F.FullName -Destination (Join-Path $Dest $F.Name) -Force }
                $Reconstructed++
            }
        }
    }
    finally
    {
        Remove-Item -LiteralPath $Staging -Recurse -Force -ErrorAction SilentlyContinue
    }

    if ($Reconstructed -eq 0)
    {
        throw "New-RdaAllSubHtmlSummaryFromZip: no per-subscription reports found inside '$InputZip'. Is this a consolidated AllSubscriptions_ResourcesReport_*.zip?"
    }

    if (-not $KeepOriginalReports)
    {
        $SummaryScript = Join-Path (Split-Path -Path $PSScriptRoot -Parent) 'Extension/Summary.ps1'
        if (Test-Path -LiteralPath $SummaryScript -PathType Leaf)
        {
            $ReRendered = 0
            foreach ($SubDir in @(Get-ChildItem -LiteralPath $OutputDirectory -Directory -Filter 'ResourcesReport*' -ErrorAction SilentlyContinue))
            {
                $InvJson = Get-ChildItem -LiteralPath $SubDir.FullName -Filter 'Inventory_*.json' -File -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($null -eq $InvJson) { continue }
                $ExistingHtml = Get-ChildItem -LiteralPath $SubDir.FullName -Filter '*.html' -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -notlike '*_revealed*' } | Select-Object -First 1
                $TargetHtml = if ($null -ne $ExistingHtml) { $ExistingHtml.FullName } else { Join-Path $SubDir.FullName ($SubDir.Name + '.html') }
                try
                {
                    & $SummaryScript -JsonFile $InvJson.FullName -HtmlFile $TargetHtml -Title 'Azure Resource Inventory' -Version $Version -PlatOS $PlatOS *> $null
                    $ReRendered++
                }
                catch
                {
                    Write-Host ("  Re-render skipped for {0} (kept original): {1}" -f $SubDir.Name, $_.Exception.Message) -ForegroundColor Yellow
                }
            }
            Write-Host ("Re-rendered {0} per-subscription report(s) with the current renderer." -f $ReRendered) -ForegroundColor Green
        }
        else
        {
            Write-Host ("Extension/Summary.ps1 not found at '{0}'; keeping original per-sub reports." -f $SummaryScript) -ForegroundColor Yellow
        }
    }

    New-RdaAllSubHtmlSummary -RunOutputDirectory $OutputDirectory -HtmlFile $HtmlFile -Detailed:$Detailed `
        -TenantId $TenantId -Version $Version -PlatOS $PlatOS

    Write-Host ("Reconstructed {0} per-subscription report(s) into: {1}" -f $Reconstructed, $OutputDirectory) -ForegroundColor Green
    Write-Host ("Open this summary (links resolve from here): {0}" -f $HtmlFile) -ForegroundColor Green

    if ($PackageZip)
    {
        $PackageZipPath = $OutputDirectory.TrimEnd([IO.Path]::DirectorySeparatorChar) + '.zip'
        if (Test-Path -LiteralPath $PackageZipPath) { Remove-Item -LiteralPath $PackageZipPath -Force -ErrorAction SilentlyContinue }
        $PackageItems = @(Get-ChildItem -LiteralPath $OutputDirectory -Force | Select-Object -ExpandProperty FullName)
        Compress-Archive -LiteralPath $PackageItems -DestinationPath ([WildcardPattern]::Escape($PackageZipPath)) -Force
        Write-Host ("Portable summary bundle (links survive extraction): {0}" -f $PackageZipPath) -ForegroundColor Green
    }

    return $HtmlFile
}

