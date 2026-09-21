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

