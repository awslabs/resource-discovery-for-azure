#Requires -Version 7.0
# =============================================================================
# AllSubHtmlSummary.Functions.ps1
#
# The HTML-summary rendering library: the self-contained (no CDN / JS libs / no
# external module) chart + escaping helpers shared by the per-subscription
# report (Extension/Summary.ps1) AND the aggregate "all-subscriptions" summary
# builder (New-RdaAllSubHtmlSummary, used by Run-AllSubscriptions.ps1 after a
# run finishes).
#
# It deliberately lives in ITS OWN function file rather than in
# Functions/Common.Functions.ps1: Common is dot-sourced by every entry point
# (ResourceInventory.ps1, Reveal.ps1, the wrappers), most of which never render
# HTML/charts. Only the two summary-rendering paths need these functions, so
# they are dot-sourced ONLY where needed and not loaded into every script's
# scope. Definitions only - no top-level code.
#
# Consumers:
#   - Extension/Summary.ps1            dot-sources this for the render helpers.
#   - Run-AllSubscriptions.ps1         dot-sources this for New-RdaAllSubHtmlSummary
#                                      (only inside its -MainSummary branch).
# =============================================================================

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

    $Total = ($Data | Measure-Object -Property Value -Sum).Sum
    if ($Total -le 0) { return '<div class="empty">No data</div>' }

    $Cx = $Size / 2
    $Cy = $Size / 2
    $Radius = ($Size / 2) - 10
    $InnerRadius = $Radius - $Thickness

    # Color palette - colorblind-friendly (Okabe-Ito + neutrals). Wraps if
    # there are more services than colors, which is fine for visual purpose.
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

    # Inner cutout to make it a donut
    [void]$Svg.AppendFormat("<circle cx='{0}' cy='{1}' r='{2}' fill='white' />", $Cx, $Cy, $InnerRadius)
    [void]$Svg.AppendFormat("<text x='{0}' y='{1}' text-anchor='middle' class='donut-total'>{2}</text>", $Cx, ($Cy - 6), $Total)
    [void]$Svg.AppendFormat("<text x='{0}' y='{1}' text-anchor='middle' class='donut-label'>resources</text>", $Cx, ($Cy + 14))

    [void]$Svg.Append('</svg>')
    return $Svg.ToString()
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

        # Label on the left
        [void]$Svg.AppendFormat("<text x='{0}' y='{1}' class='bar-label' text-anchor='end'>{2}</text>", ($LabelWidth - 8), ($y + 17), $Label)
        # Bar
        [void]$Svg.AppendFormat("<rect x='{0}' y='{1}' width='{2}' height='{3}' rx='3' class='bar-fill' />", $LabelWidth, $y, $BarWidth, ($RowHeight - 8))
        # Count to the right of the bar
        [void]$Svg.AppendFormat("<text x='{0}' y='{1}' class='bar-value'>{2}</text>", ($LabelWidth + $BarWidth + 6), ($y + 17), $Value)

        $i++
    }

    [void]$Svg.Append('</svg>')
    return $Svg.ToString()
}

# =============================================================================
# New-RdaAllSubHtmlSummary
#
# Aggregate "all-subscriptions" HTML summary across every per-subscription
# report produced by one Run-AllSubscriptions.ps1 run. Self-contained (no
# CDN/JS libraries, no external module), same portability contract as the
# per-subscription report. Built purely from artefacts already on disk (each
# per-subscription Inventory_*.json and its sibling .html) and NEVER calls
# Azure/Graph.
#
# Tier 1 (default): run totals + per-subscription table with links to each
# per-sub report. Tier 2 (-Detailed): additionally parses each per-sub inventory
# for a by-service aggregate and renders run-wide donut/bar charts. Uses the
# ConvertTo-HtmlSafe / New-DonutChart / New-BarChart helpers defined above (same
# dot-sourced file), so it never has to dot-source or modify the per-subscription
# report generator. See docs/design/main-html-summary.md.
# =============================================================================
# How file and folder names compare inside the folder $Path (or, for a file,
# beside it): case aside when the file system there ignores case, else
# exactly. Found by looking for one name there with its letter case flipped:
# where case is ignored the flipped name finds the same item, which the
# folder lists once; where it is kept, it finds nothing, or a second item that
# the listing shows. In a folder with no name to probe it creates one empty
# probe file and removes it again. It is called on folders this module writes
# to: -OutputDirectory (a new one is empty, so it gets the probe file) and the
# report folders a rebuild wrote (they hold files). When nothing can be probed, or
# the listing cannot be read, the system's default: exact on Linux, case aside on Windows and macOS.
function Get-RdaPathComparer
{
    param([string]$Path)
    $Default = if ($IsLinux) { [System.StringComparer]::Ordinal } else { [System.StringComparer]::OrdinalIgnoreCase }
    try
    {
        if ([string]::IsNullOrWhiteSpace($Path)) { return $Default }
        $Probe = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
        # The names compared are those inside a folder, so probe an item in it.
        $ProbeFile = $null
        if (Test-Path -LiteralPath $Probe -PathType Container)
        {
            $Inside = @([System.IO.Directory]::GetFileSystemEntries($Probe) | Where-Object { [System.IO.Path]::GetFileName($_) -cne ([System.IO.Path]::GetFileName($_)).ToUpperInvariant() -or [System.IO.Path]::GetFileName($_) -cne ([System.IO.Path]::GetFileName($_)).ToLowerInvariant() } | Select-Object -First 1)
            if ($Inside.Count -gt 0) { $Probe = $Inside[0] }
            else
            {
                # Nothing inside to probe (a new folder, or a mount of its own):
                # a probe file inside it, so its own file system answers.
                try
                {
                    $ProbeFile = Join-Path $Probe ('rda-case-{0}-Probe.tmp' -f [guid]::NewGuid().ToString('N'))
                    [System.IO.File]::Open($ProbeFile, [System.IO.FileMode]::CreateNew).Dispose()
                    $Probe = $ProbeFile
                }
                catch { $ProbeFile = $null }
            }
        }
        while (-not [string]::IsNullOrEmpty($Probe))
        {
            $Parent = [System.IO.Path]::GetDirectoryName($Probe)
            if ([string]::IsNullOrEmpty($Parent)) { break }
            $Leaf = [System.IO.Path]::GetFileName($Probe)
            $Flipped = -join @($Leaf.ToCharArray() | ForEach-Object { if ([char]::IsUpper($_)) { [char]::ToLowerInvariant($_) } else { [char]::ToUpperInvariant($_) } })
            if ($Flipped -cne $Leaf -and (Test-Path -LiteralPath $Probe))
            {
                # Two entries whose names differ only in case are two items.
                $Alike = @([System.IO.Directory]::GetFileSystemEntries($Parent) | Where-Object { [System.IO.Path]::GetFileName($_) -ieq $Leaf }).Count
                $Result = if ($Alike -ge 2) { [System.StringComparer]::Ordinal } elseif (Test-Path -LiteralPath (Join-Path $Parent $Flipped)) { [System.StringComparer]::OrdinalIgnoreCase } else { [System.StringComparer]::Ordinal }
                if ($null -ne $ProbeFile) { Clear-RdaLeftover -Path $ProbeFile }
                return $Result
            }
            $Probe = $Parent
        }
    }
    catch
    {
        Write-Verbose ("Get-RdaPathComparer: could not probe {0}: {1}" -f $Path, $_.Exception.Message)
    }
    if ($null -ne $ProbeFile) { Clear-RdaLeftover -Path $ProbeFile }
    return $Default
}

# The name of $Path as its folder lists it (with the letter case on disk,
# which can differ from the path given where the file system ignores case).
function Get-RdaOnDiskName
{
    param([Parameter(Mandatory = $true)][string]$Path)
    $Leaf = [System.IO.Path]::GetFileName($Path.TrimEnd([IO.Path]::DirectorySeparatorChar, '/'))
    $Listed = @([System.IO.Directory]::GetFileSystemEntries([System.IO.Path]::GetDirectoryName($Path.TrimEnd([IO.Path]::DirectorySeparatorChar, '/'))) | ForEach-Object { [System.IO.Path]::GetFileName($_) })
    $Exact = @($Listed | Where-Object { $_ -ceq $Leaf })
    if ($Exact.Count -gt 0) { return $Exact[0] }
    $Alike = @($Listed | Where-Object { $_ -ieq $Leaf })
    if ($Alike.Count -eq 1) { return $Alike[0] }
    return $Leaf
}

# The full path $Path stands for once every symbolic link or junction in it
# is followed, part by part (a part that does not exist yet, or whose link
# cannot be read, is kept as given), so two paths that reach one file through
# a linked folder compare equal. A link's target is followed the same way, so
# links in its own parent folders count too. '..' is folded by text first,
# as PowerShell and .NET fold it for every write this module makes.
# PowerShell 7.0/7.1 (.NET before 6) cannot read a link's target: there a
# path with a link in it stops (throws) instead, since it cannot be compared.
# shortcut: on 7.0/7.1 on macOS that refuses a rebuild under /tmp and /var
# (links to /private/...); fine while 7.0/7.1 are out of support.
$script:RdaCanResolveLinks = [bool]([System.IO.FileSystemInfo].GetMethod('ResolveLinkTarget'))
function Get-RdaPhysicalPath
{
    param([Parameter(Mandatory = $true)][string]$Path, [int]$Depth = 0)
    $Full = [System.IO.Path]::GetFullPath($Path)
    if ($Depth -gt 40) { return $Full }
    $Root = [System.IO.Path]::GetPathRoot($Full)
    $Current = $Root
    foreach ($Part in @($Full.Substring($Root.Length).Split([char[]]@([IO.Path]::DirectorySeparatorChar, '/'), [System.StringSplitOptions]::RemoveEmptyEntries)))
    {
        $Current = [System.IO.Path]::Combine($Current, $Part)
        if (-not $script:RdaCanResolveLinks)
        {
            # A part that does not exist yet is no link (read safely under strict mode).
            $Item = Get-Item -LiteralPath $Current -Force -ErrorAction SilentlyContinue
            if ($null -ne $Item -and $Item.LinkType -in 'SymbolicLink', 'Junction')
            {
                throw ('{0} is a link, which this PowerShell cannot follow (7.2 or later can). Use PowerShell 7.2 or later, or give a path without links.' -f $Current)
            }
            continue
        }
        try
        {
            $Info = if ([System.IO.Directory]::Exists($Current)) { [System.IO.DirectoryInfo]::new($Current) } elseif ([System.IO.File]::Exists($Current)) { [System.IO.FileInfo]::new($Current) } else { $null }
            if ($null -ne $Info -and $null -ne $Info.LinkTarget)
            {
                $Target = $Info.ResolveLinkTarget($true)
                if ($null -ne $Target) { $Current = Get-RdaPhysicalPath -Path $Target.FullName -Depth ($Depth + 1) }
            }
        }
        catch { Write-Verbose ('Get-RdaPhysicalPath: kept {0} as given: {1}' -f $Current, $_.Exception.Message) }
    }
    return $Current
}

# One file moved to a new name (a seam, so tests can make a move fail).
function Move-RdaFile
{
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Destination, [switch]$Overwrite)
    [System.IO.File]::Move($Path, $Destination, [bool]$Overwrite)
}

# Takes the lock that lets one rebuild at a time write into the output folder
# $Path, and returns it; disposing it lets the next one in. The lock is the file
# .rda-rebuild.lock in the folder itself, held open with no sharing (an
# operating-system lock on Windows, flock on Linux and macOS), so every writer
# of the folder finds it, whatever its user or temp folder. The file stays in
# the folder after the rebuild: removing it would let a caller that opened it
# just before the removal lock the removed file while another locks a new one.
# It is removed only after a failed or refused rebuild, together with a
# -OutputDirectory this call made, while the lock is still held (see
# $RemoveMadeDirs). The operating system lets go of the lock when the process
# ends, so a stopped run never leaves the folder locked. Only a lock held by
# another caller is reported as another rebuild; any other failure (a folder
# that cannot be written, a full disk) is passed on with its own message.
function Lock-RdaOutputDirectory
{
    param([Parameter(Mandatory = $true)][string]$Path)
    $LockFile = Join-Path $Path '.rda-rebuild.lock'
    try
    {
        $Lock = [System.IO.File]::Open($LockFile, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        # On Linux and macOS the open and the lock are two steps: a caller that
        # opened the file just before its holder removed it (a failed rebuild
        # into a folder it made) locks a file no longer in the folder. That is
        # seen here, and the rebuild is refused as if the lock were held.
        # shortcut: a third caller that makes a new lock file in the moment
        # between that removal and this check is not seen; compare the file
        # ids (inode) if rebuilds into one new folder must be safe in that case.
        if (-not (Test-Path -LiteralPath $LockFile -PathType Leaf))
        {
            $Lock.Dispose()
            throw [System.IO.IOException]::new('the lock file was removed by the rebuild that held it', 11)
        }
        return $Lock
    }
    catch
    {
        $Inner = $_.Exception
        while ($null -ne $Inner.InnerException) { $Inner = $Inner.InnerException }
        # A lock held by another caller: a sharing violation on Windows (32 or
        # 33), EWOULDBLOCK on Linux (11) and macOS (35). Other I/O errors are
        # subclasses or carry another code.
        if ($Inner.GetType() -eq [System.IO.IOException] -and @(11, 32, 33, 35) -contains ($Inner.HResult -band 0xFFFF))
        {
            throw ("New-RdaAllSubHtmlSummaryFromZip: another rebuild is writing into {0} (it holds {1}). Wait for it to finish, then run again." -f $Path, $LockFile)
        }
        throw ("New-RdaAllSubHtmlSummaryFromZip: could not take the rebuild lock {0}: {1}" -f $LockFile, $Inner.Message)
    }
}

# Removes a private file or folder this module left; one that cannot be
# removed is named in a warning, never passed over in silence.
function Clear-RdaLeftover
{
    param([Parameter(Mandatory = $true)][string]$Path, [switch]$Recurse)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    try { Remove-Item -LiteralPath $Path -Force -Recurse:$Recurse -ErrorAction Stop }
    catch { Write-Warning ('Could not remove {0}: {1} Delete it by hand.' -f $Path, $_.Exception.Message) }
}

# Stops (throws) before anything is extracted from the zip $Path when it is
# outside the limits downstream accepts a report zip within: more than 2000
# entries, an entry over 16 GB, over 32 GB in all, an entry or the whole
# packed more than 100 to 1, or an entry path that is rooted or holds '..'.
# Reads only the zip's directory.
function Assert-RdaZipWithinLimit
{
    param([Parameter(Mandatory = $true)][string]$Path)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $Archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try
    {
        $Entries = @($Archive.Entries)
        $Name = Split-Path -Path $Path -Leaf
        if ($Entries.Count -gt 2000) { throw ('{0} holds {1} entries, more than 2000.' -f $Name, $Entries.Count) }
        [long]$Total = 0
        [long]$Packed = 0
        foreach ($E in $Entries)
        {
            $Parts = @($E.FullName -split '[\\/]')
            # Rooted on any system: a leading / or \ (also \\server and \\?\ forms) or a drive letter.
            if ([System.IO.Path]::IsPathRooted($E.FullName) -or $E.FullName -match '^([\\/]|[A-Za-z]:)' -or $Parts -contains '..') { throw ('{0} holds an entry with a rooted or .. path: {1}' -f $Name, $E.FullName) }
            if ($E.Length -gt 16GB) { throw ('{0} holds an entry over 16 GB: {1}' -f $Name, $E.FullName) }
            if ($E.CompressedLength -gt 0 -and ($E.Length / $E.CompressedLength) -gt 100) { throw ('{0} holds an entry packed more than 100 to 1: {1}' -f $Name, $E.FullName) }
            $Total += $E.Length
            $Packed += $E.CompressedLength
        }
        if ($Total -gt 32GB) { throw ('{0} holds more than 32 GB in all.' -f $Name) }
        if ($Packed -gt 0 -and ($Total / $Packed) -gt 100) { throw ('{0} is packed more than 100 to 1 in all.' -f $Name) }
    }
    finally { $Archive.Dispose() }
}

function New-RdaAllSubHtmlSummary
{
    param(
        # Directory holding the per-subscription report folders (ResourcesReport*).
        [Parameter(Mandatory = $true)] $RunOutputDirectory,

        # Output path for the aggregate .html.
        [Parameter(Mandatory = $true)] $HtmlFile,

        # Optional: only include report folders modified at/after this time, so the
        # summary is scoped to a single wrapper run rather than every run ever left
        # in the output directory. When omitted, every ResourcesReport* folder is
        # included.
        $SinceTime,

        # Optional run-health collections passed through from the wrapper. Each is an
        # array; when empty the corresponding banner is omitted.
        $FailedSubscriptions = @(),
        $ConsumptionFailedSubs = @(),
        $MetricsFailedSubs = @(),
        $CollectorFailures = @(),

        # Display-only header fields.
        $TenantId,
        $Version,
        $PlatOS,

        # Tier 2 (per-service aggregate + charts) when set; Tier 1 index-only otherwise.
        [switch]$Detailed,

        # When set, this summary is part of a shareable (obfuscated) bundle and must
        # carry NO real identifiers: the tenant id is suppressed and the run-health
        # banners are rendered as COUNTS ONLY (no subscription names). The caller
        # (the wrapper) knows the true obfuscation mode and passes it; even without
        # it, a summary whose sampled per-sub names look obfuscated is treated the
        # same way (safe default).
        [switch]$Obfuscated,

        # Optional: the report folder names to list. When given, only these
        # folders are listed and counted, so other ResourcesReport* folders in
        # -RunOutputDirectory are not.
        $ReportFolders = $null,

        # Optional: the full paths of the files to read in those folders. When
        # given, a folder's inventory and report html are taken only from
        # these, so other files in a folder of the same name are not read.
        $ReportFiles = $null
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

    # --- Discover per-subscription report folders and read their inventories ---
    # Each per-sub run writes a ResourcesReport<stamp> folder containing a loose
    # Inventory_*.json and its sibling .html. We read only those; no Azure calls.
    $Folders = @(Get-ChildItem -LiteralPath $RunOutputDirectory -Directory -Filter 'ResourcesReport*' -ErrorAction SilentlyContinue)
    if ($null -ne $SinceTime)
    {
        $Folders = @($Folders | Where-Object { $_.LastWriteTime -ge $SinceTime })
    }

    $ObfPattern = '^(prod_|nonprod_)[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    $Samples = New-Object System.Collections.Generic.List[string]
    $AllowedFiles = $null
    if ($null -ne $ReportFiles)
    {
        # Grouped by report folder (folder names compared as the run folder
        # compares them); each folder's files compared as that folder does,
        # since a report folder can treat letter case apart from its parent.
        $AllowedFiles = [System.Collections.Generic.Dictionary[string, object]]::new((Get-RdaPathComparer -Path $RunOutputDirectory))
        foreach ($F in @(@($ReportFiles) | Where-Object { $_ } | ForEach-Object { [string]$_ }))
        {
            $Parent = [System.IO.Path]::GetDirectoryName($F)
            if (-not $AllowedFiles.ContainsKey($Parent)) { $AllowedFiles[$Parent] = New-Object System.Collections.Generic.List[string] }
            $AllowedFiles[$Parent].Add([System.IO.Path]::GetFileName($F))
        }
    }
    # Only the folders -ReportFolders names, when given.
    if ($null -ne $ReportFolders)
    {
        $Listed = [System.Collections.Generic.HashSet[string]]::new([string[]]@(@($ReportFolders) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ }), (Get-RdaPathComparer -Path $RunOutputDirectory))
        $Folders = @($Folders | Where-Object { $Listed.Contains($_.Name) })
    }
    $SubReports = @()
    $ServiceAgg = [ordered]@{}
    # Keyed by the folder name as each row holds it (the same string), so no
    # file system comparer is needed. Filled after the loop, not in the catch:
    # the catch's row line is edited by the summary-wording change.
    $LinkByFolder = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)

    foreach ($Folder in $Folders)
    {
        # The folder found as the run folder compares names; its file names
        # as the folder compares them (asked only of a folder with files).
        $FolderAllowed = $null
        if ($null -ne $AllowedFiles)
        {
            if ($AllowedFiles.ContainsKey($Folder.FullName))
            {
                $FolderAllowed = [System.Collections.Generic.HashSet[string]]::new((Get-RdaPathComparer -Path $Folder.FullName))
                foreach ($F in $AllowedFiles[$Folder.FullName]) { [void]$FolderAllowed.Add($F) }
            }
            else { $FolderAllowed = [System.Collections.Generic.HashSet[string]]::new() }
        }
        $InvFile = Get-ChildItem -LiteralPath $Folder.FullName -Filter 'Inventory_*.json' -File -ErrorAction SilentlyContinue | Where-Object { $null -eq $FolderAllowed -or $FolderAllowed.Contains($_.Name) } | Select-Object -First 1
        if ($null -eq $InvFile) { continue }
        $HtmlItem = Get-ChildItem -LiteralPath $Folder.FullName -Filter '*.html' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notlike '*_revealed*' -and ($null -eq $FolderAllowed -or $FolderAllowed.Contains($_.Name)) } | Select-Object -First 1
        # Relative link so the summary travels with the report folder; found
        # before the inventory is read, so a report whose inventory cannot be
        # read still links its html.
        $Link = if ($null -ne $HtmlItem) { (Join-Path $Folder.Name $HtmlItem.Name) } else { $null }

        $LinkByFolder[$Folder.Name] = $Link
        try
        {
            $Inv = Get-Content -LiteralPath $InvFile.FullName -Raw -Encoding utf8 | ConvertFrom-Json
        }
        catch
        {
            # A single unreadable inventory must not abort the whole summary.
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

        $SubReports += [pscustomobject]@{ Name = $SubName; Total = $Total; Link = $Link; Folder = $Folder.Name }
    }

    # A report whose inventory could not be read keeps its html link.
    foreach ($Sr in $SubReports) { if (-not $Sr.Link -and $LinkByFolder.ContainsKey($Sr.Folder) -and $LinkByFolder[$Sr.Folder]) { $Sr.Link = $LinkByFolder[$Sr.Folder] } }

    # Detect obfuscation posture the same way Summary.ps1 does (safe default: identifiable).
    $ObfuscationStatus = 'identifiable'
    if ($Samples.Count -gt 0)
    {
        $ObfHits = @($Samples | Where-Object { $_ -match $ObfPattern }).Count
        if ($ObfHits -gt ($Samples.Count * 0.7)) { $ObfuscationStatus = 'obfuscated' }
    }

    # Redaction gate for the shareable bundle: explicit -Obfuscated from the caller
    # OR a sampled-obfuscated posture. When set, the tenant id and health-banner
    # subscription names (real identifiers the wrapper cannot tokenize) are omitted.
    $IsObfuscated = $Obfuscated.IsPresent -or ($ObfuscationStatus -eq 'obfuscated')

    $SubReports = @($SubReports | Sort-Object -Property Total -Descending)
    # A plain sum: 0 with no reports, also under strict mode.
    $RunTotalResources = 0; foreach ($SubRow in $SubReports) { $RunTotalResources += [int]$SubRow.Total }
    $SubCount = $SubReports.Count
    $EmptyCount = @($SubReports | Where-Object { $_.Total -eq 0 }).Count

    # --- Render --------------------------------------------------------------
    $Generated = Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'
    $TenantSafe = if ($IsObfuscated -or [string]::IsNullOrWhiteSpace([string]$TenantId)) { '' } else { ConvertTo-HtmlSafe ([string]$TenantId) }
    $VersionSafe = if ([string]::IsNullOrWhiteSpace([string]$Version)) { '' } else { ConvertTo-HtmlSafe ([string]$Version) }
    $PlatSafe = if ([string]::IsNullOrWhiteSpace([string]$PlatOS)) { '' } else { ConvertTo-HtmlSafe ([string]$PlatOS) }

    # Follows the redaction gate ($IsObfuscated), so an -Obfuscated run whose
    # reports hold no records to sample still says it is obfuscated. "Safe to
    # share" only when the caller says the run masked its output (-Obfuscated,
    # which the wrapper passes for -Obfuscate): names that only look masked in
    # a sample of records prove nothing about the rest.
    $PrivacyBanner = if ($Obfuscated.IsPresent)
    {
        '<div class="privacy-banner obfuscated"><span>&#128274;</span><div><b>Obfuscated.</b> Names shown are deterministic pseudonyms (prod_/nonprod_ prefixes); no real identifiers are present. Safe to share.</div></div>'
    }
    elseif ($IsObfuscated)
    {
        '<div class="privacy-banner obfuscated"><span>&#128274;</span><div><b>Obfuscated.</b> The names in a sample of the reports are deterministic pseudonyms (prod_/nonprod_ prefixes). Only a sample was checked: review the reports before sharing them.</div></div>'
    }
    else
    {
        '<div class="privacy-banner identifiable"><span>&#9888;</span><div><b>Identifiable.</b> This summary and the linked reports contain real resource and subscription names. Treat as confidential.</div></div>'
    }

    # Health banners built from the passed-through wrapper collections. Each is
    # read-only; a null/empty collection renders nothing.
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

    # Tier 2 charts (only when -Detailed and there is data).
    $ChartsHtml = ''
    if ($Detailed -and $ServiceAgg.Keys.Count -gt 0)
    {
        $DonutData = @($ServiceAgg.GetEnumerator() | ForEach-Object { @{ Label = $_.Key; Value = $_.Value } })
        $TopN = @($ServiceAgg.GetEnumerator() | Sort-Object -Property Value -Descending | Select-Object -First 12 | ForEach-Object { @{ Label = $_.Key; Value = $_.Value } })
        $DonutSvg = New-DonutChart -Data $DonutData
        $BarSvg = New-BarChart -Data $TopN
        $ChartsHtml = "<div class='charts'><div class='chart-card'><h3>Resources by service (run-wide)</h3>$DonutSvg</div><div class='chart-card'><h3>Top services</h3>$BarSvg</div></div>"
    }

    # Per-subscription table.
    $Rows = New-Object System.Text.StringBuilder
    foreach ($Sr in $SubReports)
    {
        $NameSafe = ConvertTo-HtmlSafe $Sr.Name
        $CountText = '{0:N0}' -f $Sr.Total
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
  <div class="card"><div class="n">$('{0:N0}' -f $RunTotalResources)</div><div class="l">Total resources</div></div>
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

    # Written under a private name beside it and moved over it only when the
    # write worked, so a failed write keeps an earlier summary whole.
    $HtmlPartial = '{0}.rda-{1}.partial' -f $HtmlFile, [guid]::NewGuid().ToString('N')
    try
    {
        $Html | Out-File -LiteralPath $HtmlPartial -Encoding utf8
        [System.IO.File]::Move($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($HtmlPartial), $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($HtmlFile), $true)
    }
    finally
    {
        Clear-RdaLeftover -Path $HtmlPartial
    }
    Write-Host ("Main summary written: {0}" -f $HtmlFile) -ForegroundColor Green
    # The same gate as the privacy banner, so an obfuscated run whose reports
    # hold no records to sample does not call itself identifiable here either.
    $PrivacyText = if ($Obfuscated.IsPresent) { 'obfuscated' } elseif ($IsObfuscated) { 'obfuscated (sample only; review before sharing)' } else { 'identifiable' }
    Write-Host ("  {0} subscription(s), {1:N0} total resource(s), {2} empty, {3} failed. Privacy: {4}." -f $SubCount, $RunTotalResources, $EmptyCount, $FailedList.Count, $PrivacyText) -ForegroundColor DarkGray
}

# =============================================================================
# New-RdaAllSubHtmlSummaryFromZip
#
# Receiver-side convenience: build a working aggregate summary from a
# CONSOLIDATED outer zip (AllSubscriptions_ResourcesReport_*.zip) - the artifact
# a customer/operator hands you. That zip contains one per-subscription .zip per
# sub (NOT extracted folders) and carries no summary, so the summary's
# folder-relative links have nothing to resolve against until the inner zips are
# unpacked. This function does exactly that reconstruction, then calls
# New-RdaAllSubHtmlSummary against it:
#   1. Expand the outer zip to a temp staging dir.
#   2. Extract each inner ResourcesReport*.zip into its own ResourcesReport*/
#      folder under -OutputDirectory, pulling only the per-sub .html (the link
#      target) and Inventory_*.json (the summary's input). The per-sub HTML is
#      self-contained, so navigation works without the bulky csv/metrics members.
#   3. Build MainSummary.html in -OutputDirectory (links now resolve on disk).
#   4. Optionally (-PackageZip) zip the summary and the folders reconstructed
#      in step 2 into a portable bundle whose links survive being moved/emailed.
#
# Backward-compatible: works on any consolidated zip, old or new, because it only
# relies on the long-standing inner-zip layout. Falls back to already-extracted
# ResourcesReport*/ folders if the archive contains those instead of inner zips.
# =============================================================================
function New-RdaAllSubHtmlSummaryFromZip
{
    param(
        # Consolidated outer zip (AllSubscriptions_ResourcesReport_*.zip).
        [Parameter(Mandatory = $true)] $InputZip,

        # Durable folder to reconstruct into + write MainSummary.html. The per-sub
        # folders MUST live next to the html for its relative links to resolve, so
        # this is NOT a temp dir. Defaults to <zipdir>/<zipbasename>_MainSummary.
        $OutputDirectory,

        # Explicit output path for the summary html. Defaults to
        # <OutputDirectory>/MainSummary.html.
        $HtmlFile,

        # Tier 2 (run-wide by-service donut/bar charts).
        [switch]$Detailed,

        # Also emit a portable zip of the reconstructed folder (summary + per-sub
        # HTMLs) whose links survive extraction elsewhere.
        [switch]$PackageZip,

        # By default each per-subscription report is RE-RENDERED from its
        # Inventory_*.json with the current Extension/Summary.ps1, so drill-down
        # reports reflect the latest renderer (e.g. the Tags column fix) instead of
        # whatever version produced the html inside the source zip. Pass this to
        # keep the original per-sub html verbatim instead.
        [switch]$KeepOriginalReports,

        # Display-only header fields (forwarded to New-RdaAllSubHtmlSummary).
        $TenantId,
        $Version,
        $PlatOS
    )

    # The rebuild itself; the lock it takes on the output folder is held
    # until it returns or fails.
    $HeldLocks = [System.Collections.Generic.List[System.IDisposable]]::new()
    try { Invoke-RdaAllSubHtmlSummaryFromZip @PSBoundParameters -HeldLocks $HeldLocks }
    finally { foreach ($Held in $HeldLocks) { $Held.Dispose() } }
}

# The body of New-RdaAllSubHtmlSummaryFromZip, with its parameters (documented
# there). It adds the output folder's lock to -HeldLocks, which that function
# releases.
function Invoke-RdaAllSubHtmlSummaryFromZip
{
    param($InputZip, $OutputDirectory, $HtmlFile, [switch]$Detailed, [switch]$PackageZip, [switch]$KeepOriginalReports, $TenantId, $Version, $PlatOS, [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[System.IDisposable]]$HeldLocks)

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
    $OutputDirectory = [System.IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory))
    # A drive or file system root is never the output folder: the reports
    # would sit at the root and the bundle would be named after no folder.
    # Also not through a link or junction to a root (the path as followed). On
    # PowerShell 7.0/7.1, which cannot follow a link, a path with a link in it
    # stops here (Get-RdaPhysicalPath throws), as it does for -PackageZip.
    $OutputPhysical = Get-RdaPhysicalPath -Path $OutputDirectory
    $IsRoot = { param($P) $P.TrimEnd([IO.Path]::DirectorySeparatorChar, '/') -eq ([string][System.IO.Path]::GetPathRoot($P)).TrimEnd([IO.Path]::DirectorySeparatorChar, '/') }
    if ((& $IsRoot $OutputDirectory) -or (& $IsRoot $OutputPhysical))
    {
        throw ("New-RdaAllSubHtmlSummaryFromZip: -OutputDirectory cannot be the root {0}. Choose a folder." -f $OutputDirectory)
    }
    $OutputDirectory = $OutputDirectory.TrimEnd([IO.Path]::DirectorySeparatorChar, '/')
    # -PackageZip writes <OutputDirectory>.zip, replacing a file of that name:
    # never the input zip itself, also not when a linked folder makes the two
    # paths look different.
    if ($PackageZip)
    {
        $PlannedPackage = $OutputDirectory + '.zip'
        if ((Get-RdaPathComparer -Path $ZipItem.FullName).Equals((Get-RdaPhysicalPath -Path $PlannedPackage), (Get-RdaPhysicalPath -Path $ZipItem.FullName)))
        {
            throw ("New-RdaAllSubHtmlSummaryFromZip: -PackageZip would write {0}, which is -InputZip. Choose another -OutputDirectory." -f $PlannedPackage)
        }
    }
    # Checked before anything is created or extracted, as downstream checks a
    # report zip.
    Assert-RdaZipWithinLimit -Path $ZipItem.FullName

    if ([string]::IsNullOrWhiteSpace($HtmlFile))
    {
        $HtmlFile = Join-Path $OutputDirectory 'MainSummary.html'
    }
    # The summary links the report folders by relative path, so it must sit in
    # -OutputDirectory beside them (and only there can -PackageZip bundle it).
    # Checked before -OutputDirectory is made.
    $HtmlParent = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($HtmlFile)))
    if (-not (Get-RdaPathComparer -Path $OutputDirectory).Equals($HtmlParent.TrimEnd([IO.Path]::DirectorySeparatorChar, '/'), $OutputDirectory))
    {
        throw ("New-RdaAllSubHtmlSummaryFromZip: -HtmlFile must be in -OutputDirectory ({0}), beside the report folders its links point to; it was {1}." -f $OutputDirectory, $HtmlFile)
    }

    # The folders New-Item -Force makes (-OutputDirectory and any missing
    # parent), deepest first, so a refused or failed rebuild can remove the
    # empty ones again.
    $MadeDirs = New-Object System.Collections.Generic.List[string]
    $Walk = $OutputDirectory
    while ($Walk -and -not (Test-Path -LiteralPath $Walk)) { $MadeDirs.Add($Walk); $Walk = [System.IO.Path]::GetDirectoryName($Walk) }
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    $OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).ProviderPath
    # Lets go of the lock and removes the empty folders this call made
    # (-OutputDirectory and its parents, deepest first), with the lock file when
    # this call made -OutputDirectory: on a failed or refused rebuild.
    $RemoveMadeDirs = {
        # The walk above starts at -OutputDirectory, so any entry means this
        # call made it.
        if ($MadeDirs.Count -gt 0)
        {
            $LockFile = Join-Path $OutputDirectory '.rda-rebuild.lock'
            # On Linux and macOS the file is removed while the lock is still
            # held: a caller that opens the path afterwards makes a new one (and
            # the folder is then not empty, so it stays), and one that opened
            # it just before locks a removed file, which Lock-RdaOutputDirectory
            # sees and refuses. Windows does not
            # remove a file that is open, and no caller can open it while it is
            # held, so there it is let go first; if another rebuild takes it in
            # between, the file and the folder stay for that rebuild.
            if (-not $IsWindows) { Clear-RdaLeftover -Path $LockFile }
            foreach ($Held in $HeldLocks) { $Held.Dispose() }
            $HeldLocks.Clear()
            if ($IsWindows) { try { Remove-Item -LiteralPath $LockFile -Force -ErrorAction Stop } catch { Write-Verbose ('Left the lock file {0} to the rebuild that took it: {1}' -f $LockFile, $_.Exception.Message) } }
        }
        foreach ($Dir in @($MadeDirs))
        {
            # Only if empty, in one step that never prompts: a folder another
            # rebuild has just started to use is left to it.
            if ($Dir -and [System.IO.Directory]::Exists($Dir)) { try { [System.IO.Directory]::Delete($Dir, $false) } catch { Write-Verbose ('Left the folder {0}: {1}' -f $Dir, $_.Exception.Message) } }
        }
    }
    # One rebuild at a time into this folder, from here on: every check below
    # of what is already there, and every file this call moves, replaces or
    # puts back, is then its own. A rebuild that cannot take the lock removes
    # only the empty folders it made: when another rebuild holds it, that one
    # has made or is using the folder, so nothing is removed.
    try { $HeldLocks.Add((Lock-RdaOutputDirectory -Path $OutputDirectory)) }
    catch
    {
        if ($_.Exception.Message -notlike '*another rebuild is writing into*') { & $RemoveMadeDirs }
        throw
    }

    # Extract the outer zip to a temp staging dir; we only pull the inner per-sub
    # zips out of it, then reconstruct one folder per sub under $OutputDirectory.
    # A new folder of its own (an existing one is an error, never reused),
    # readable by this user only on Linux and macOS: it holds customer reports.
    $Staging = Join-Path ([System.IO.Path]::GetTempPath()) ('RdaFromZip_' + [guid]::NewGuid().ToString('N'))
    $StagingMade = $false
    # Files written under a private name until all are written, the report
    # folders planned, and those of them this call made.
    $StagedFiles = New-Object System.Collections.Generic.List[object]
    $DirsPlanned = New-Object System.Collections.Generic.List[string]
    $MadeReportDirs = New-Object System.Collections.Generic.List[string]
    $SwapDone = $false
    $SwapUndone = $false
    $PartialsCleared = $false
    # Targets already swapped, per report folder, compared as that folder
    # compares names (it can treat letter case apart from -OutputDirectory).
    $SwapSeen = [System.Collections.Generic.Dictionary[string, object]]::new((Get-RdaPathComparer -Path $OutputDirectory))
    # Puts every target back as it was before the swap, last swapped first
    # (a target written twice is put back in turn). One that cannot be put
    # back does not stop the rest; each file left out of place is returned as
    # a line saying what it is, so the error or warning can name it.
    $UndoSwap = {
        for ($I = $StagedFiles.Count - 1; $I -ge 0; $I--)
        {
            $Staged = $StagedFiles[$I]
            try
            {
                if ($Staged.Swapped -and -not $Staged.Backup -and (Test-Path -LiteralPath $Staged.Target)) { Remove-Item -LiteralPath $Staged.Target -Force -ErrorAction Stop }
                if ($Staged.Backup -and (Test-Path -LiteralPath $Staged.Backup)) { Move-RdaFile -Path $Staged.Backup -Destination $Staged.Target -Overwrite }
            }
            catch
            {
                if ($Staged.Backup -and (Test-Path -LiteralPath $Staged.Backup))
                {
                    # A target written twice: the second one's old file is
                    # from this run, and the first one's restore follows.
                    if ($Staged.Earlier) { '{0} is the earlier file; {1} now holds the new one: replace it with the earlier file' -f $Staged.Backup, $Staged.Target }
                    else { Clear-RdaLeftover -Path $Staged.Backup }
                }
                elseif (Test-Path -LiteralPath $Staged.Target) { '{0} is a new file that could not be removed: delete it' -f $Staged.Target }
            }
        }
    }
    try
    {
        New-Item -ItemType Directory -Path $Staging -ErrorAction Stop | Out-Null
        $StagingMade = $true
        if (-not $IsWindows)
        {
            # File.SetUnixFileMode needs .NET 7 (PowerShell 7.3); chmod otherwise.
            if ('System.IO.UnixFileMode' -as [type]) { [System.IO.File]::SetUnixFileMode($Staging, ('System.IO.UnixFileMode' -as [type])::UserRead -bor ('System.IO.UnixFileMode' -as [type])::UserWrite -bor ('System.IO.UnixFileMode' -as [type])::UserExecute) }
            else
            {
                & chmod 700 $Staging
                if ($LASTEXITCODE -ne 0) { throw ('New-RdaAllSubHtmlSummaryFromZip: could not make the staging folder {0} private (chmod 700 failed).' -f $Staging) }
            }
        }
        Expand-Archive -LiteralPath $InputZip -DestinationPath $Staging -Force
        # Exclude any leftover *_revealed.zip (de-obfuscated single-report archive
        # from a prior Reveal run) at SELECTION time: the reveal engine renames only
        # the OUTER zip with the _revealed suffix and rewrites the inner html/json
        # members IN PLACE (their names keep no _revealed marker), so a member-name
        # filter alone would let real-data reports through. Mirrors Reveal.ps1.
        $InnerZips = @(Get-ChildItem -LiteralPath $Staging -Recurse -Filter 'ResourcesReport*.zip' -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notlike '*_revealed*' })

        $Reconstructed = 0
        # Folders this call writes; -PackageZip bundles only these.
        $ReconstructedDirs = New-Object System.Collections.Generic.List[string]
        # Case aside: on Windows and macOS two names that differ only in case
        # are one folder.
        $DestSeen = [System.Collections.Generic.HashSet[string]]::new((Get-RdaPathComparer -Path $OutputDirectory))
        # The files this call writes in each of those folders. A folder of the
        # same name may already hold other files (an earlier bundle's report, a
        # revealed copy); -PackageZip bundles only these files, never the rest.
        $WrittenFiles = [System.Collections.Generic.Dictionary[string, object]]::new((Get-RdaPathComparer -Path $OutputDirectory))
        # First, read only: which report zips to rebuild and which of their
        # entries to write. A second zip of a name already planned is skipped
        # (the first one is kept), so is a zip with no inventory (it is not a
        # report), and nothing is written until every planned entry fits one
        # budget for the whole rebuild: the 2000 entries and 32 GB a report
        # zip may hold in all.
        $Plan = New-Object System.Collections.Generic.List[object]
        $PlanSeen = [System.Collections.Generic.HashSet[string]]::new((Get-RdaPathComparer -Path $OutputDirectory))
        [long]$PlanBytes = 0
        $PlanCount = 1
        # The re-render writes an html for a report that has none, but only
        # when it runs (not with -KeepOriginalReports, nor without the renderer).
        $WillRender = (-not $KeepOriginalReports) -and (Test-Path -LiteralPath (Join-Path (Split-Path -Path $PSScriptRoot -Parent) 'Extension/Summary.ps1') -PathType Leaf)
        foreach ($InnerZip in $InnerZips)
        {
            # Folder named after the inner zip base (ResourcesReport_<stamp>), which
            # matches the ResourcesReport* glob New-RdaAllSubHtmlSummary discovers.
            $FolderName = [System.IO.Path]::GetFileNameWithoutExtension($InnerZip.Name)
            $Dest = Join-Path $OutputDirectory $FolderName
            if ($PlanSeen.Contains($Dest))
            {
                Write-Warning ("Skipped a second report zip named {0} in the input zip; the first one is used." -f $InnerZip.Name)
                continue
            }
            Assert-RdaZipWithinLimit -Path $InnerZip.FullName
            $Archive = [System.IO.Compression.ZipFile]::OpenRead($InnerZip.FullName)
            try
            {
                # Never pull a *_revealed* (de-obfuscated) report across: it holds
                # real identifiers and would otherwise ride along in a shareable
                # -PackageZip bundle. Only the obfuscated per-sub html + the
                # Inventory json (the summary's input) are reconstructed.
                $Picked = @($Archive.Entries | Where-Object { ($_.Name -like 'Inventory_*.json') -or (($_.Name -like '*.html') -and ($_.Name -notlike '*_revealed*')) } | ForEach-Object { [pscustomobject]@{ Name = $_.Name; FullName = $_.FullName; Length = $_.Length } })
            }
            finally { $Archive.Dispose() }
            if (@($Picked | Where-Object { $_.Name -like 'Inventory_*.json' }).Count -eq 0)
            {
                Write-Warning ("Skipped {0}: it holds no Inventory_*.json." -f $InnerZip.Name)
                continue
            }
            # A report folder already there that is a link or junction would take
            # the writes outside -OutputDirectory: stop before anything is written.
            # (Only a real link: a OneDrive or dedup folder is a reparse point too.)
            if (@(Get-Item -LiteralPath $Dest -Force -ErrorAction SilentlyContinue | Where-Object { $_.LinkType -in 'SymbolicLink', 'Junction' }).Count -gt 0)
            {
                throw ('New-RdaAllSubHtmlSummaryFromZip: {0} is a link or junction; a report folder must be a real folder in -OutputDirectory.' -f $Dest)
            }
            # The re-render writes an html for a report that has none, and the
            # summary is one file more: both count too.
            $PlanCount += $Picked.Count
            if ($WillRender -and @($Picked | Where-Object { $_.Name -like '*.html' }).Count -eq 0) { $PlanCount++ }
            foreach ($P in $Picked) { $PlanBytes += $P.Length }
            if ($PlanCount -gt 2000) { throw ('New-RdaAllSubHtmlSummaryFromZip: the report zips in {0} would write more than 2000 files in all.' -f $ZipItem.Name) }
            if ($PlanBytes -gt 32GB) { throw ('New-RdaAllSubHtmlSummaryFromZip: the report zips in {0} would write more than 32 GB in all.' -f $ZipItem.Name) }
            [void]$PlanSeen.Add($Dest)
            $Plan.Add([pscustomobject]@{ Zip = $InnerZip; Dest = $Dest; Entries = @($Picked | ForEach-Object { $_.FullName }) })
        }

        # Then the writes, only the planned entries. Each file is written under
        # a private name beside its target first; only when every file is
        # written do they take their targets' places, each old file kept under
        # a private name until all have, so a failure before or while they
        # take their places puts the reports already in a reused folder back
        # as they were. (A failure later, in the summary or the bundle, keeps
        # the new reports: the old MainSummary.html then stays as it was.)
        foreach ($Item in $Plan)
        {
            $Dest = $Item.Dest
            if (-not (Test-Path -LiteralPath $Dest)) { $MadeReportDirs.Add($Dest) }
            New-Item -ItemType Directory -Path $Dest -Force | Out-Null
            $Archive = [System.IO.Compression.ZipFile]::OpenRead($Item.Zip.FullName)
            try
            {
                foreach ($Entry in @($Archive.Entries | Where-Object { $Item.Entries -ccontains $_.FullName }))
                {
                    $Target = Join-Path $Dest $Entry.Name
                    $Staged = [pscustomobject]@{ Dest = $Dest; Target = $Target; Partial = ('{0}.rda-{1}.partial' -f $Target, [guid]::NewGuid().ToString('N')); Backup = $null; Swapped = $false; Earlier = $false }
                    $StagedFiles.Add($Staged)
                    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($Entry, $Staged.Partial, $false)
                }
            }
            finally { $Archive.Dispose() }
            $DirsPlanned.Add($Dest)
        }

        # Fallback for an archive that already holds extracted ResourcesReport*/
        # folders instead of inner zips: copy their html + Inventory json across.
        if ($DirsPlanned.Count -eq 0)
        {
            $ExtractedFolders = @(Get-ChildItem -LiteralPath $Staging -Recurse -Directory -Filter 'ResourcesReport*' -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -notlike '*_revealed*' })
            # Planned first, against the same budget as report zips.
            $FolderPlan = New-Object System.Collections.Generic.List[object]
            foreach ($Ef in $ExtractedFolders)
            {
                $Files = @(Get-ChildItem -LiteralPath $Ef.FullName -File -ErrorAction SilentlyContinue | Where-Object { ($_.Name -like 'Inventory_*.json') -or (($_.Name -like '*.html') -and ($_.Name -notlike '*_revealed*')) })
                # A report needs its inventory.
                if (@($Files | Where-Object { $_.Name -like 'Inventory_*.json' }).Count -eq 0) { continue }
                $Dest = Join-Path $OutputDirectory $Ef.Name
                # A second folder of the same name: the first one is kept, as for report zips.
                if ($PlanSeen.Contains($Dest))
                {
                    Write-Warning ("Skipped a second report folder named {0} in the input zip; the first one is used." -f $Ef.Name)
                    continue
                }
                # A report folder already there that is a link or junction would take
                # the writes outside -OutputDirectory: stop before anything is written.
                # (Only a real link: a OneDrive or dedup folder is a reparse point too.)
                if (@(Get-Item -LiteralPath $Dest -Force -ErrorAction SilentlyContinue | Where-Object { $_.LinkType -in 'SymbolicLink', 'Junction' }).Count -gt 0)
                {
                    throw ('New-RdaAllSubHtmlSummaryFromZip: {0} is a link or junction; a report folder must be a real folder in -OutputDirectory.' -f $Dest)
                }
                $PlanCount += $Files.Count
                if ($WillRender -and @($Files | Where-Object { $_.Name -like '*.html' }).Count -eq 0) { $PlanCount++ }
                foreach ($F in $Files) { $PlanBytes += $F.Length }
                if ($PlanCount -gt 2000) { throw ('New-RdaAllSubHtmlSummaryFromZip: the report folders in {0} would write more than 2000 files in all.' -f $ZipItem.Name) }
                if ($PlanBytes -gt 32GB) { throw ('New-RdaAllSubHtmlSummaryFromZip: the report folders in {0} would write more than 32 GB in all.' -f $ZipItem.Name) }
                [void]$PlanSeen.Add($Dest)
                $FolderPlan.Add([pscustomobject]@{ Dest = $Dest; Files = $Files })
            }
            # Written under private names first too, as for report zips.
            foreach ($Item in $FolderPlan)
            {
                $Dest = $Item.Dest
                if (-not (Test-Path -LiteralPath $Dest)) { $MadeReportDirs.Add($Dest) }
                New-Item -ItemType Directory -Path $Dest -Force | Out-Null
                foreach ($F in $Item.Files)
                {
                    $Target = Join-Path $Dest $F.Name
                    $Staged = [pscustomobject]@{ Dest = $Dest; Target = $Target; Partial = ('{0}.rda-{1}.partial' -f $Target, [guid]::NewGuid().ToString('N')); Backup = $null; Swapped = $false; Earlier = $false }
                    $StagedFiles.Add($Staged)
                    Copy-Item -LiteralPath $F.FullName -Destination $Staged.Partial
                }
                $DirsPlanned.Add($Dest)
            }
        }

        if ($DirsPlanned.Count -eq 0)
        {
            throw "New-RdaAllSubHtmlSummaryFromZip: no per-subscription reports found inside '$InputZip'. Is this a consolidated AllSubscriptions_ResourcesReport_*.zip?"
        }

        # Every file is written: each now takes its target's place, the old
        # file moved aside first (put back if any later step fails).
        foreach ($Staged in $StagedFiles)
        {
            # The first write of a target moves the user's earlier file aside.
            if (-not $SwapSeen.ContainsKey($Staged.Dest)) { $SwapSeen[$Staged.Dest] = [System.Collections.Generic.HashSet[string]]::new((Get-RdaPathComparer -Path $Staged.Dest)) }
            $Staged.Earlier = $SwapSeen[$Staged.Dest].Add($Staged.Target)
            if (Test-Path -LiteralPath $Staged.Target)
            {
                $Staged.Backup = '{0}.rda-{1}.bak' -f $Staged.Target, [guid]::NewGuid().ToString('N')
                Move-RdaFile -Path $Staged.Target -Destination $Staged.Backup
            }
            # Marked first: a stop right after the move must still undo it.
            $Staged.Swapped = $true
            Move-RdaFile -Path $Staged.Partial -Destination $Staged.Target
        }
        $SwapDone = $true
        foreach ($Staged in $StagedFiles)
        {
            # One entry per file as its folder compares names, so two
            # spellings of one file are listed (and bundled) once.
            if (-not $WrittenFiles.ContainsKey($Staged.Dest)) { $WrittenFiles[$Staged.Dest] = [System.Collections.Generic.HashSet[string]]::new((Get-RdaPathComparer -Path $Staged.Dest)) }
            [void]$WrittenFiles[$Staged.Dest].Add($Staged.Target)
        }
        foreach ($Dest in $DirsPlanned) { if ($DestSeen.Add($Dest)) { $ReconstructedDirs.Add($Dest) } }
        $Reconstructed = $DirsPlanned.Count
    }
    catch
    {
        # A refused or failed rebuild leaves no empty folder it made: the
        # report folders, -OutputDirectory and its parents, deepest first.
        $Kept = @()
        if (-not $SwapDone) { $SwapUndone = $true; $Kept = @(& $UndoSwap) }
        foreach ($Staged in $StagedFiles) { Clear-RdaLeftover -Path $Staged.Partial }
        $PartialsCleared = $true
        # The report folders this call made go first, while the lock is held.
        foreach ($Dir in @($MadeReportDirs))
        {
            # Only if empty, in one step that never prompts: a folder another
            # rebuild has just started to use is left to it.
            if ($Dir -and [System.IO.Directory]::Exists($Dir)) { try { [System.IO.Directory]::Delete($Dir, $false) } catch { Write-Verbose ('Left the folder {0}: {1}' -f $Dir, $_.Exception.Message) } }
        }
        # A -OutputDirectory this call made goes too, with its lock file, so the
        # lock is let go and its file removed first.
        & $RemoveMadeDirs
        if ($Kept.Count -gt 0)
        {
            throw [System.Exception]::new(('{0} Not every file could be put back as it was: {1}.' -f $_.Exception.Message, ($Kept -join '; ')), $_.Exception)
        }
        throw
    }
    finally
    {
        # A stopped run (no catch) is put back too. Then the old files moved
        # aside, the private names left by a failed write, and the staging
        # folder (only the one this call made).
        if (-not $SwapDone -and -not $SwapUndone)
        {
            $Kept = @(& $UndoSwap)
            if ($Kept.Count -gt 0) { Write-Warning ('New-RdaAllSubHtmlSummaryFromZip stopped; not every file could be put back as it was: {0}.' -f ($Kept -join '; ')) }
        }
        if ($SwapDone) { foreach ($Staged in $StagedFiles) { if ($Staged.Backup) { Clear-RdaLeftover -Path $Staged.Backup } } }
        if (-not $PartialsCleared) { foreach ($Staged in $StagedFiles) { Clear-RdaLeftover -Path $Staged.Partial } }
        if ($StagingMade) { Clear-RdaLeftover -Path $Staging -Recurse }
    }

    # Re-render each per-subscription report from its Inventory_*.json with the
    # CURRENT Extension/Summary.ps1, so drill-down reports reflect the latest
    # renderer (e.g. the Tags column fix) rather than whatever version produced
    # the html inside the source zip. The per-sub report is built entirely from
    # the inventory json; only the optional consumption billing-coverage banner
    # (which needs the csv, not extracted) is skipped. Fail-soft per sub: one that
    # cannot be re-rendered keeps its original html so its drill-down link still
    # resolves. $PSScriptRoot here is the Functions/ folder (where this function is
    # defined), so the sibling Extension/Summary.ps1 resolves from the repo root.
    # Only the folders this call reconstructed: other ResourcesReport* folders in
    # -OutputDirectory are left as they are.
    if (-not $KeepOriginalReports)
    {
        $SummaryScript = Join-Path (Split-Path -Path $PSScriptRoot -Parent) 'Extension/Summary.ps1'
        if (Test-Path -LiteralPath $SummaryScript -PathType Leaf)
        {
            $ReRendered = 0
            foreach ($SubDir in @($ReconstructedDirs | ForEach-Object { Get-Item -LiteralPath $_ }))
            {
                # Only the files this call wrote in the folder: one already there
                # is not from -InputZip.
                $Mine = @($WrittenFiles[$SubDir.FullName] | Where-Object { $_ } | ForEach-Object { Get-Item -LiteralPath $_ -ErrorAction SilentlyContinue } | Where-Object { $_ })
                $InvJson = $Mine | Where-Object { $_.Name -like 'Inventory_*.json' } | Select-Object -First 1
                if ($null -eq $InvJson) { continue }
                # Replace the html this call wrote (single html per folder keeps
                # the summary's link stable); with none, <folder>.html. A file
                # of that name already there is replaced only by a good render
                # (moved aside, and put back if the move in fails), and is
                # listed for the summary and the bundle only once replaced.
                $ExistingHtml = $Mine | Where-Object { $_.Name -like '*.html' -and $_.Name -notlike '*_revealed*' } | Select-Object -First 1
                $TargetHtml = if ($null -ne $ExistingHtml) { $ExistingHtml.FullName } else { Join-Path $SubDir.FullName ($SubDir.Name + '.html') }
                # Rendered to a private name beside it and moved in only when
                # it worked, so a failed render keeps the original.
                $RenderPartial = '{0}.rda-{1}.partial' -f $TargetHtml, [guid]::NewGuid().ToString('N')
                $RenderBackup = $null
                $RenderDone = $false
                $RenderError = $null
                try
                {
                    & $SummaryScript -JsonFile $InvJson.FullName -HtmlFile $RenderPartial -Title 'Azure Resource Inventory' -Version $Version -PlatOS $PlatOS *> $null
                    if (Test-Path -LiteralPath $TargetHtml)
                    {
                        $RenderBackup = '{0}.rda-{1}.bak' -f $TargetHtml, [guid]::NewGuid().ToString('N')
                        Move-RdaFile -Path $TargetHtml -Destination $RenderBackup
                    }
                    Move-RdaFile -Path $RenderPartial -Destination $TargetHtml
                    $RenderDone = $true
                    # Listed only once it is written.
                    [void]$WrittenFiles[$SubDir.FullName].Add($TargetHtml)
                    $ReRendered++
                }
                catch { $RenderError = $_.Exception.Message }
                finally
                {
                    # The earlier html is removed only once the new one is in;
                    # a failed or stopped move puts it back (or keeps and names
                    # it when it cannot be), never removes it.
                    if ($RenderBackup -and (Test-Path -LiteralPath $RenderBackup))
                    {
                        if ($RenderDone) { Clear-RdaLeftover -Path $RenderBackup }
                        else
                        {
                            try { Move-RdaFile -Path $RenderBackup -Destination $TargetHtml -Overwrite }
                            catch { Write-Warning ('{0} is the earlier html; it could not be put back as {1}: rename it.' -f $RenderBackup, $TargetHtml) }
                        }
                    }
                    Clear-RdaLeftover -Path $RenderPartial
                }
                # Said after the put-back, so it tells what is on disk.
                if ($null -ne $RenderError)
                {
                    $Kept = if ($null -eq $ExistingHtml) { 'no html for this report' } elseif (Test-Path -LiteralPath $TargetHtml) { 'kept original' } else { 'the earlier html is not in place; see the warning' }
                    Write-Host ("  Re-render skipped for {0} ({1}): {2}" -f $SubDir.Name, $Kept, $RenderError) -ForegroundColor Yellow
                }
            }
            Write-Host ("Re-rendered {0} per-subscription report(s) with the current renderer." -f $ReRendered) -ForegroundColor Green
        }
        else
        {
            Write-Host ("Extension/Summary.ps1 not found at '{0}'; keeping original per-sub reports." -f $SummaryScript) -ForegroundColor Yellow
        }
    }

    # Build the summary against the reconstructed folder (links resolve on disk),
    # listing only the folders reconstructed from -InputZip: -OutputDirectory may
    # already hold other ResourcesReport* folders, which are not in this zip.
    # Unique as the file system compares names (two folders whose names
    # differ only in case are two where it keeps case apart).
    $NameSeen = [System.Collections.Generic.HashSet[string]]::new((Get-RdaPathComparer -Path $OutputDirectory))
    $ReconstructedNames = @($ReconstructedDirs | ForEach-Object { Split-Path -Path $_ -Leaf } | Where-Object { $NameSeen.Add($_) })
    New-RdaAllSubHtmlSummary -RunOutputDirectory $OutputDirectory -HtmlFile $HtmlFile -Detailed:$Detailed `
        -ReportFolders $ReconstructedNames -ReportFiles @($WrittenFiles.Values | ForEach-Object { $_ }) -TenantId $TenantId -Version $Version -PlatOS $PlatOS

    Write-Host ("Reconstructed {0} per-subscription report(s) into: {1}" -f $Reconstructed, $OutputDirectory) -ForegroundColor Green
    Write-Host ("Open this summary (links resolve from here): {0}" -f $HtmlFile) -ForegroundColor Green

    # Optional portable bundle: the summary and the per-sub folders this call
    # reconstructed, so they travel together with working links. Only those:
    # -OutputDirectory may already hold other files (other bundles' reports, a
    # dictionary, the wrapper's .resume-state-*.json), and a wildcard over the
    # folder takes them too; on Windows a leading dot does not hide a file.
    if ($PackageZip)
    {
        $PackageZipPath = $OutputDirectory.TrimEnd([IO.Path]::DirectorySeparatorChar) + '.zip'
        # Entries: the summary at the top, then <folder>/<file> for each file
        # this call wrote, so a file that was already in a folder of the same
        # name never travels with the bundle.
        $Entries = New-Object System.Collections.Generic.List[object]
        $HtmlFullPath = (Resolve-Path -LiteralPath $HtmlFile).ProviderPath
        if ((Get-RdaPathComparer -Path $OutputDirectory).Equals((Split-Path -Path $HtmlFullPath -Parent).TrimEnd([IO.Path]::DirectorySeparatorChar, '/'), $OutputDirectory.TrimEnd([IO.Path]::DirectorySeparatorChar, '/')))
        {
            $Entries.Add([pscustomobject]@{ Path = $HtmlFullPath; Name = (Split-Path -Path $HtmlFullPath -Leaf) })
        }
        foreach ($Dir in $ReconstructedDirs)
        {
            # The names as they are on disk, which the summary's links use (a
            # folder or file that was there keeps its own letter case).
            $FolderName = Get-RdaOnDiskName -Path $Dir
            foreach ($File in @($WrittenFiles[$Dir] | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) }))
            {
                $Entries.Add([pscustomobject]@{ Path = $File; Name = ('{0}/{1}' -f $FolderName, (Get-RdaOnDiskName -Path $File)) })
            }
        }
        # Built under a name of its own beside it, then moved over the old
        # bundle, so a write that fails part-way never leaves an incomplete
        # bundle under the name.
        $PartialPackage = '{0}.rda-{1}.partial' -f $PackageZipPath, [guid]::NewGuid().ToString('N')
        try
        {
            $Package = [System.IO.Compression.ZipFile]::Open($PartialPackage, [System.IO.Compression.ZipArchiveMode]::Create)
            try
            {
                foreach ($E in $Entries) { $null = [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($Package, $E.Path, $E.Name) }
            }
            finally { $Package.Dispose() }
            # Checked as written, with the limits a report zip is held to (the
            # re-rendered html can be larger than what was extracted, and
            # recompressing can pack it tighter), before it takes its name.
            Assert-RdaZipWithinLimit -Path $PartialPackage
            [System.IO.File]::Move($PartialPackage, $PackageZipPath, $true)
        }
        finally
        {
            Clear-RdaLeftover -Path $PartialPackage
        }
        Write-Host ("Portable summary bundle (links survive extraction): {0}" -f $PackageZipPath) -ForegroundColor Green
    }

    return $HtmlFile
}
