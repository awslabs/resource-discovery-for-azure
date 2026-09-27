#Requires -Version 7.0

function Write-RdaProgress
{
    <#
    .SYNOPSIS
        Single, reusable progress reporter used across the tool.

    .DESCRIPTION
        Renders progress so it is visible in every host the tool runs in:
          1. Write-Progress - a live updating bar in an INTERACTIVE host.
          2. A throttled host line - because Write-Progress is a NO-OP in the
             non-interactive hosts the tool frequently uses (parallel `pwsh`
             stream processes, ForEach-Object -Parallel runspaces, transcripts,
             CI). In those hosts a single line per call is written so progress is
             still visible / captured by a parent process or transcript.
          3. An optional durable heartbeat line appended to -HeartbeatLogFile so
             a long run is observable live and after the fact.

        The function is intentionally generic: it knows nothing about
        subscriptions, collectors or staging folders. Every caller does its own
        trivial index/total math and calls this. Two display modes:
          - Determinate  (-Total > 0): "<item> (<index> of <total>)" + a percent.
          - Count-only    (-Total omitted or 0): "<item> (<index>)", no percent,
            for loops whose total is not known up front.

    .PARAMETER Activity
        Task label shown as the progress activity (e.g. 'Processing
        subscriptions', 'Revealing per-subscription reports').

    .PARAMETER CurrentItem
        Short description of the item being processed now (subscription/collector/
        folder name). Callers may enrich it, e.g. 'Sub-Prod-40 (already revealed)'.

    .PARAMETER Index
        1-based position of the current item.

    .PARAMETER Total
        Total number of items. 0 (or omitted) selects count-only mode.

    .PARAMETER Id
        Optional Write-Progress -Id to distinguish nested/parallel bars (default 0).

    .PARAMETER HeartbeatLogFile
        Optional path. When supplied, a timestamped progress line is appended so
        progress is durable even where Write-Progress is a no-op. A write failure
        never throws (best-effort).

    .PARAMETER NonInteractiveLine
        Force emitting the plain-text host line regardless of host detection.
        Useful for child stream processes whose stdout a parent captures.

    .PARAMETER BarOnly
        Suppress the non-interactive plain-text line entirely - emit only the
        Write-Progress bar (plus the optional heartbeat log). Use for
        high-frequency loops that run in non-interactive child processes (e.g.
        the per-collector Service Processing loop, which runs inside a parallel
        stream worker), where one line per item would flood the parent's
        captured stdout. Mirrors the pre-existing Write-Progress-only behavior of
        those loops while still routing through this single function.

    .PARAMETER Completed
        Clears the Write-Progress bar for this -Activity/-Id (and logs a
        completion line when -HeartbeatLogFile is set). Use once after the loop.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]   $Activity,

        [string]   $CurrentItem = '',
        [int]      $Index = 0,
        [int]      $Total = 0,
        [int]      $Id = 0,
        [string]   $HeartbeatLogFile,
        [switch]   $NonInteractiveLine,
        [switch]   $BarOnly,
        [switch]   $Completed
    )

    if ($Total -gt 0)
    {
        $Percent = [int](($Index / $Total) * 100)
        if ($Percent -lt 0) { $Percent = 0 }
        elseif ($Percent -gt 100) { $Percent = 100 }
        $Status = '{0} ({1} of {2})' -f $CurrentItem, $Index, $Total
    }
    else
    {
        $Percent = -1
        $Status = '{0} ({1})' -f $CurrentItem, $Index
    }

    if ($Completed)
    {
        Write-Progress -Activity $Activity -Id $Id -Completed
    }
    elseif ($Percent -ge 0)
    {
        Write-Progress -Activity $Activity -Id $Id -Status $Status -PercentComplete $Percent
    }
    else
    {
        Write-Progress -Activity $Activity -Id $Id -Status $Status
    }

    if (-not $Completed -and -not $BarOnly)
    {
        $HostIsInteractive = ([Environment]::UserInteractive -and -not [Console]::IsOutputRedirected)
        if ($NonInteractiveLine -or -not $HostIsInteractive)
        {
            Write-Host ('{0}: {1}' -f $Activity, $Status)
        }
    }

    if (-not [string]::IsNullOrEmpty($HeartbeatLogFile))
    {
        try
        {
            if ($Completed)
            {
                # In count-only mode (-Total omitted / 0) use the final -Index for the
                # item count, since $Total is 0 and would otherwise log 'complete (0
                # item(s))' regardless of how many items the loop processed. Callers
                # that clear the bar with -Completed can pass the final index.
                $CompletedCount = if ($Total -gt 0) { $Total } else { $Index }
                $Line = '[{0:dd-MM-yyyy} {0:HH:mm:ss}] {1}: complete ({2} item(s))' -f (Get-Date), $Activity, $CompletedCount
            }
            else
            {
                $Line = '[{0:dd-MM-yyyy} {0:HH:mm:ss}] {1}: {2}' -f (Get-Date), $Activity, $Status
            }
            Add-Content -LiteralPath $HeartbeatLogFile -Value $Line -ErrorAction Stop
        }
        catch
        {
        }
    }
}

function Global:Write-Log([string]$Message, [string]$Severity, [switch]$NoConsole, [switch]$ToDebugLog)
{
    $DateTime = "[{0:dd-MM-yyyy} {0:HH:mm:ss}]" -f (Get-Date)

    $SubId = Get-Variable -Name 'SubscriptionID' -ValueOnly -ErrorAction SilentlyContinue
    $SubTag = if (-not [string]::IsNullOrEmpty($SubId)) { '[{0}] ' -f $SubId.Substring(0, [Math]::Min(8, $SubId.Length)) } else { '' }
    $Message = $SubTag + $Message

    if (-not $NoConsole)
    {
        switch ($Severity)
        {
            "Info" { Write-Host $Message -ForegroundColor Cyan }
            "Warning" { Write-Host $Message -ForegroundColor Yellow }
            "Error" { Write-Host $Message -ForegroundColor Red }
            "Success" { Write-Host $Message -ForegroundColor Green }
            default { Write-Host $Message }
        }
    }

    if ($Severity -eq 'Error' -and -not [string]::IsNullOrEmpty($Global:ErrorLogFile))
    {
        try
        {
            ('{0} {1}' -f $DateTime, $Message) | Out-File -LiteralPath $Global:ErrorLogFile -Append -Encoding utf8
        }
        catch
        {
        }
    }

    if ($ToDebugLog -and -not [string]::IsNullOrEmpty($Global:DebugLogFile))
    {
        try
        {
            ('{0} {1}' -f $DateTime, $Message) | Out-File -LiteralPath $Global:DebugLogFile -Append -Encoding utf8
        }
        catch
        {
        }
    }
}

function Test-ReportArchiveUsable
{
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try
    {
        return ((Get-Item -LiteralPath $Path -ErrorAction Stop).Length -gt 0)
    }
    catch
    {
        return $false
    }
}

function Get-RdaInventoryRoot
{
    [CmdletBinding()]
    param(
        [string]$Requested,

        [switch]$NoInherit
    )

    $TestRoot = {
        param([string]$Candidate)

        if ([string]::IsNullOrWhiteSpace($Candidate)) { return 'empty path' }

        try
        {
            if (-not (Test-Path -LiteralPath $Candidate -PathType Container))
            {
                New-Item -Path $Candidate -ItemType Directory -Force -ErrorAction Stop | Out-Null
            }
        }
        catch
        {
            return ("cannot create directory: {0}" -f $_.Exception.Message)
        }

        $Probe = Join-Path $Candidate (".rda-root-probe-{0}.tmp" -f ([guid]::NewGuid()))
        try
        {
            Set-Content -LiteralPath $Probe -Value 'probe' -Encoding utf8 -ErrorAction Stop
        }
        catch
        {
            return ("directory exists but is not writable: {0}" -f $_.Exception.Message)
        }
        finally
        {
            try { if (Test-Path -LiteralPath $Probe) { Remove-Item -LiteralPath $Probe -Force -ErrorAction Stop } }
            catch { Write-Verbose ("root probe cleanup failed at {0}: {1}" -f $Probe, $_.Exception.Message) }
        }

        return $null
    }

    $Trim = { param([string]$P) $P.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) }

    if (-not [string]::IsNullOrWhiteSpace($Requested))
    {
        $Explicit = & $Trim $Requested
        $Err = & $TestRoot $Explicit
        if ($null -eq $Err)
        {
            return [pscustomobject]@{ Ok = $true; Path = $Explicit; Source = 'Explicit'; IsFallback = $false
                Message = ("Output directory: {0} (from -OutputDirectory)" -f $Explicit)
            }
        }
        return [pscustomobject]@{ Ok = $false; Path = $Explicit; Source = 'Explicit'; IsFallback = $false
            Message = ("-OutputDirectory '{0}' is not usable: {1}. Choose a writable path, or omit -OutputDirectory to use the default location." -f $Explicit, $Err)
        }
    }

    if (-not $NoInherit -and -not [string]::IsNullOrWhiteSpace($env:RDA_INVENTORY_ROOT))
    {
        $Inherited = & $Trim $env:RDA_INVENTORY_ROOT
        $Err = & $TestRoot $Inherited
        if ($null -eq $Err)
        {
            return [pscustomobject]@{ Ok = $true; Path = $Inherited; Source = 'Inherited'; IsFallback = $false
                Message = ("Output directory: {0}" -f $Inherited)
            }
        }
        Write-Verbose ("Inherited RDA_INVENTORY_ROOT '{0}' unusable ({1}); re-probing." -f $Inherited, $Err)
    }

    $Candidates = @()
    if ($PSVersionTable.Platform -eq 'Unix')
    {
        if (-not [string]::IsNullOrWhiteSpace($HOME)) { $Candidates += (Join-Path $HOME 'InventoryReports') }
    }
    else
    {
        $WinBase = if (-not [string]::IsNullOrWhiteSpace($env:SystemDrive)) { $env:SystemDrive + '\' } else { 'C:\' }
        $Candidates += (Join-Path $WinBase 'InventoryReports')
        if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) { $Candidates += (Join-Path $env:USERPROFILE 'InventoryReports') }
    }
    $Candidates += (Join-Path ([IO.Path]::GetTempPath()) 'InventoryReports')

    $Attempts = @()
    $Index = 0
    foreach ($Candidate in $Candidates)
    {
        $Clean = & $Trim $Candidate
        $Err = & $TestRoot $Clean
        if ($null -eq $Err)
        {
            $IsFallback = ($Index -gt 0)
            $Msg = if ($IsFallback)
            {
                ("The default output location was not usable, so this run is writing to {0} instead. Tried: {1}. Pass -OutputDirectory to choose a specific location." -f $Clean, ($Attempts -join '; '))
            }
            else
            {
                ("Output directory: {0}" -f $Clean)
            }
            return [pscustomobject]@{ Ok = $true; Path = $Clean; Source = $(if ($IsFallback) { 'Fallback' } else { 'Default' }); IsFallback = $IsFallback; Message = $Msg }
        }
        $Attempts += ("{0} ({1})" -f $Clean, $Err)
        $Index++
    }

    return [pscustomobject]@{ Ok = $false; Path = $null; Source = 'Default'; IsFallback = $false
        Message = ("No writable output directory could be established. Tried: {0}. Pass -OutputDirectory with a writable path." -f ($Attempts -join '; '))
    }
}

function Set-RdaInventoryRootForChildren
{
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $env:RDA_INVENTORY_ROOT = $Path
}

function Test-RdaConsumptionDenial
{
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$ErrorMessage)

    if ([string]::IsNullOrWhiteSpace($ErrorMessage)) { return $false }

    $DenialPattern = '(?i)(' + (@(
            '(?<!un)authoriz'
            '(?<![\w-])forbidden(?![\w-])'
            '\(403\)'
            '\bstatus\s?code\D{0,40}403\b'
            'does not have (?:authorization|permission|access|the required)'
            '\bnot authorized\b'
            '\binsufficient privileg'
            '\baccess is denied\b'
            '(?<![\w-])RBAC(?![\w-])'
        ) -join '|') + ')'

    return [bool]($ErrorMessage -match $DenialPattern)
}

function Test-RdaAuthExpiry
{
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$ErrorMessage)

    if ([string]::IsNullOrWhiteSpace($ErrorMessage)) { return $false }

    $AuthExpiryPattern = '(?i)(' + (@(
            'ExpiredAuthenticationToken'
            'InvalidAuthenticationToken'
            'AuthenticationFailed'
            '\baccess token\b[^.]{0,40}\bexpir'
            '\btoken\b[^.]{0,20}\bhas expired\b'
            '\bauthentication failed\b'
            '\(401\)'
            '\bstatus\s?code\D{0,40}401\b'
            '(?<![\w-])unauthorized(?![\w-])'
        ) -join '|') + ')'

    return [bool]($ErrorMessage -match $AuthExpiryPattern)
}

function Test-RdaOutOfMemory
{
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$ErrorMessage)

    if ([string]::IsNullOrWhiteSpace($ErrorMessage)) { return $false }

    # Matches only the two default .NET out-of-memory messages, case-sensitively: the runtime's
    # "Exception of type 'System.OutOfMemoryException' was thrown." (Az cmdlets can wrap it in
    # "One or more errors occurred. (...)"), and the default text of a constructed
    # OutOfMemoryException or InsufficientMemoryException. A bare type name does not match, so
    # an echoed resource name such as 'rg-OutOfMemoryException-01' is not mistaken for one.
    # Text alone cannot tell this process running out of memory from a service error that
    # echoes the same sentence; such an echo gets one immediate retry instead of the backoff.
    $OutOfMemoryPattern = '(' + (@(
            'Exception of type ''System\.OutOfMemoryException'' was thrown'
            'Insufficient memory to continue the execution of the program'
        ) -join '|') + ')'

    return [bool]($ErrorMessage -cmatch $OutOfMemoryPattern)
}

function Write-RdaMemorySnapshot
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Phase,
        [switch]$Compact,
        [switch]$Record
    )

    # Writes how much memory this process holds to the local debug log only, so a run that runs out
    # of memory shows which phase grew. -Compact first runs a full blocking collection that also
    # compacts the large object heap. A long-lived session such as Cloud Shell otherwise never
    # compacts that heap, so large strings and arrays freed by earlier subscriptions can leave it
    # too fragmented for the next large allocation.
    # -Record also appends the reading to $Global:MemoryReadings, keyed by the subscription being
    # processed and the run stamp, so the wrapper's RunSummary.log and the shareable Diagnostics
    # log can show how much memory each phase of each subscription held. The figures carry no
    # identifier, so the same rows are safe in an obfuscated bundle.
    try
    {
        if ($Compact)
        {
            [System.Runtime.GCSettings]::LargeObjectHeapCompactionMode = [System.Runtime.GCLargeObjectHeapCompactionMode]::CompactOnce
            [System.GC]::Collect([System.GC]::MaxGeneration, [System.GCCollectionMode]::Forced, $true, $true)
        }
        $HeapMB = [math]::Round([System.GC]::GetTotalMemory($false) / 1MB, 1)
        $WorkingSetMB = [math]::Round([System.Diagnostics.Process]::GetCurrentProcess().WorkingSet64 / 1MB, 1)
        $LimitMB = [math]::Round([System.GC]::GetGCMemoryInfo().TotalAvailableMemoryBytes / 1MB, 0)
        if ($Record)
        {
            $SubId = Get-Variable -Name 'SubscriptionID' -ValueOnly -ErrorAction SilentlyContinue
            $ResourceCount = if ($null -ne $Global:ResourceCount) { [int]$Global:ResourceCount } else { 0 }
            if ($null -eq $Global:MemoryReadings) { $Global:MemoryReadings = @() }
            $Global:MemoryReadings += [pscustomobject]@{
                Id           = [string]$SubId
                Stamp        = [string]$Global:CurrentDateTime
                Phase        = $Phase
                Resources    = $ResourceCount
                HeapMB       = $HeapMB
                WorkingSetMB = $WorkingSetMB
                LimitMB      = $LimitMB
            }
        }
        $CompactNote = if ($Compact) { ', after a compacting collection' } else { '' }
        Write-Log -Message ('[Memory] {0}: managed heap {1} MB, process working set {2} MB, memory available to the runtime {3} MB{4}.' -f $Phase, $HeapMB.ToString([cultureinfo]::InvariantCulture), $WorkingSetMB.ToString([cultureinfo]::InvariantCulture), $LimitMB.ToString([cultureinfo]::InvariantCulture), $CompactNote) -Severity 'Info' -NoConsole -ToDebugLog
    }
    catch
    {
        Write-Log -Message ('[Memory] {0}: snapshot unavailable: {1}' -f $Phase, $_.Exception.Message) -Severity 'Info' -NoConsole -ToDebugLog
    }
}


function Get-RdaMemoryReadingLines
{
    [CmdletBinding()]
    param(
        $Readings = @(),
        [string]$Stamp,
        [switch]$Obfuscated
    )

    # Renders the readings Write-RdaMemorySnapshot -Record collected: one row per subscription with
    # the managed heap and working set at each phase, then the highest working set seen, the memory
    # the runtime says it may use, and the per-resource cost of the largest subscription. The rows
    # carry counts and megabytes. Under -Obfuscated a subscription is named by its position;
    # otherwise by its id, which the diagnostics writer masks like its other sections. -Stamp keeps
    # a standalone run's log to its own readings when the same prompt has run the script before.
    $Lines = [System.Collections.Generic.List[string]]::new()
    $Rows = @(@($Readings) | Where-Object { $null -ne $_ -and -not [string]::IsNullOrEmpty([string]$_.Phase) })
    if (-not [string]::IsNullOrEmpty($Stamp))
    {
        $Rows = @($Rows | Where-Object { [string]$_.Stamp -eq $Stamp })
    }
    if ($Rows.Count -eq 0) { return $Lines.ToArray() }

    $Phases = @('start', 'discovery', 'collectors', 'released', 'end')
    $Groups = [ordered]@{}
    foreach ($Row in $Rows)
    {
        $Key = [string]$Row.Id
        if ([string]::IsNullOrEmpty($Key)) { $Key = [string]$Row.Stamp }
        if (-not $Groups.Contains($Key)) { $Groups[$Key] = @() }
        $Groups[$Key] += $Row
    }

    $Inv = [cultureinfo]::InvariantCulture
    $Lines.Add('Memory (MB, managed heap after a full collection / process working set):')
    $Position = 0
    $HighestWorkingSet = 0
    $Limit = 0
    $Largest = $null
    foreach ($Key in $Groups.Keys)
    {
        $Position++
        $Group = @($Groups[$Key])
        $Resources = 0
        foreach ($Row in $Group)
        {
            $RowResources = 0
            if ([int]::TryParse([string]$Row.Resources, [ref]$RowResources) -and $RowResources -gt $Resources) { $Resources = $RowResources }
            $RowWs = 0.0
            if ([double]::TryParse([string]$Row.WorkingSetMB, [System.Globalization.NumberStyles]::Float, $Inv, [ref]$RowWs) -and $RowWs -gt $HighestWorkingSet) { $HighestWorkingSet = $RowWs }
            $RowLimit = 0.0
            if ([double]::TryParse([string]$Row.LimitMB, [System.Globalization.NumberStyles]::Float, $Inv, [ref]$RowLimit) -and $RowLimit -gt $Limit) { $Limit = $RowLimit }
        }
        $Label = if ($Obfuscated -or [string]::IsNullOrEmpty([string]$Group[0].Id)) { 'sub {0}' -f $Position } else { 'sub {0}' -f [string]$Group[0].Id }
        $Cells = [System.Collections.Generic.List[string]]::new()
        $Cells.Add(('resources {0}' -f $Resources.ToString('N0', $Inv)))
        foreach ($Phase in $Phases)
        {
            $Reading = @($Group | Where-Object { [string]$_.Phase -eq $Phase } | Select-Object -Last 1)
            if ($Reading.Count -eq 0) { $Cells.Add(('{0} -' -f $Phase)); continue }
            $Heap = 0.0; $Ws = 0.0
            [void][double]::TryParse([string]$Reading[0].HeapMB, [System.Globalization.NumberStyles]::Float, $Inv, [ref]$Heap)
            [void][double]::TryParse([string]$Reading[0].WorkingSetMB, [System.Globalization.NumberStyles]::Float, $Inv, [ref]$Ws)
            $Cells.Add(('{0} {1}/{2}' -f $Phase, [math]::Round($Heap).ToString($Inv), [math]::Round($Ws).ToString($Inv)))
        }
        $Lines.Add(('  [{0}]  {1}' -f $Label, ($Cells -join '  ')))
        if ($null -eq $Largest -or $Resources -gt $Largest.Resources)
        {
            $Largest = [pscustomobject]@{ Resources = $Resources; Group = $Group }
        }
    }

    $Lines.Add(('  Highest working set sampled : {0} MB' -f [math]::Round($HighestWorkingSet).ToString($Inv)))
    if ($Limit -gt 0)
    {
        $Lines.Add(('  Memory available to runtime : {0} MB' -f [math]::Round($Limit).ToString($Inv)))
    }

    if ($null -ne $Largest -and $Largest.Resources -gt 0)
    {
        $HeapAt = @{}
        foreach ($Phase in @('start', 'discovery', 'collectors'))
        {
            $Reading = @($Largest.Group | Where-Object { [string]$_.Phase -eq $Phase } | Select-Object -Last 1)
            if ($Reading.Count -gt 0)
            {
                $Heap = 0.0
                if ([double]::TryParse([string]$Reading[0].HeapMB, [System.Globalization.NumberStyles]::Float, $Inv, [ref]$Heap)) { $HeapAt[$Phase] = $Heap }
            }
        }
        if ($HeapAt.ContainsKey('start') -and $HeapAt.ContainsKey('discovery') -and $HeapAt.ContainsKey('collectors'))
        {
            $PerResourceKB = {
                param([double]$FromMB, [double]$ToMB)
                [math]::Max(0, [math]::Round((($ToMB - $FromMB) * 1024) / $Largest.Resources))
            }
            $RawKB = & $PerResourceKB $HeapAt['start'] $HeapAt['discovery']
            $CollectorKB = & $PerResourceKB $HeapAt['discovery'] $HeapAt['collectors']
            $TotalKB = & $PerResourceKB $HeapAt['start'] $HeapAt['collectors']
            $Lines.Add(('  Per resource, largest sub   : raw rows ~{0} KB, collector output ~{1} KB, total ~{2} KB ({3} resources)' -f $RawKB.ToString($Inv), $CollectorKB.ToString($Inv), $TotalKB.ToString($Inv), $Largest.Resources.ToString('N0', $Inv)))
        }
    }

    return $Lines.ToArray()
}
