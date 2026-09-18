#Requires -Version 7.0
# Cross-cutting helper functions shared by the entry-point scripts, dot-sourced into each script's scope.
# Definitions only - no top-level code.

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

    # Build the "(index of total)" or "(index)" suffix once.
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

    # Non-interactive fallback: Write-Progress renders nothing in redirected /
    # non-interactive hosts, so emit a plain line there (or when forced) so a
    # parent process or transcript still sees movement. Skip on -Completed.
    if (-not $Completed -and -not $BarOnly)
    {
        $HostIsInteractive = ([Environment]::UserInteractive -and -not [Console]::IsOutputRedirected)
        if ($NonInteractiveLine -or -not $HostIsInteractive)
        {
            Write-Host ('{0}: {1}' -f $Activity, $Status)
        }
    }

    # Durable heartbeat (best-effort; never throws).
    if (-not [string]::IsNullOrEmpty($HeartbeatLogFile))
    {
        try
        {
            if ($Completed)
            {
                $Line = '[{0:dd-MM-yyyy} {0:HH:mm:ss}] {1}: complete ({2} item(s))' -f (Get-Date), $Activity, $Total
            }
            else
            {
                $Line = '[{0:dd-MM-yyyy} {0:HH:mm:ss}] {1}: {2}' -f (Get-Date), $Activity, $Status
            }
            Add-Content -LiteralPath $HeartbeatLogFile -Value $Line -ErrorAction Stop
        }
        catch
        {
            # Best-effort only - progress reporting must never break a run.
        }
    }
}

# Write-Log: the single logging entry point; Global: so collectors invoked via '&' can see it. -NoConsole/-ToDebugLog are additive (default output unchanged).
# The -ToDebugLog file ($Global:DebugLogFile) is UNSCRUBBED and ships inside the zip on a default (non-obfuscated) run, so never write a credential or token to it.
function Global:Write-Log([string]$Message, [string]$Severity, [switch]$NoConsole, [switch]$ToDebugLog)
{
    $DateTime = "[{0:dd-MM-yyyy} {0:HH:mm:ss}]" -f (Get-Date)

    # Tag each line with the current subscription (first 8 chars of its GUID)
    # when one is in scope. Read via Get-Variable so it resolves the script-scope
    # $SubscriptionID up the call chain without throwing when no subscription is
    # in scope (e.g. a standalone full-tenant run) - in that case no tag is added
    # and the output is byte-for-byte unchanged.
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

    # Errors-only local sink: append error-severity messages to $Global:ErrorLogFile when set.
    # LOCAL-ONLY - it carries raw exception text with real Azure identifiers, so never add it to the obfuscated (server-bound) zip without scrubbing first.
    if ($Severity -eq 'Error' -and -not [string]::IsNullOrEmpty($Global:ErrorLogFile))
    {
        try
        {
            ('{0} {1}' -f $DateTime, $Message) | Out-File -LiteralPath $Global:ErrorLogFile -Append -Encoding utf8
        }
        catch
        {
            # Never let an error-log write failure interrupt the run.
        }
    }

    # Consolidated debug log sink (opt-in via -ToDebugLog) into $Global:DebugLogFile; silent best-effort.
    # UNSCRUBBED, and its zipping is MODE-DEPENDENT: LOCAL-only under -Obfuscate, INCLUDED in the zip on a default run.
    if ($ToDebugLog -and -not [string]::IsNullOrEmpty($Global:DebugLogFile))
    {
        try
        {
            ('{0} {1}' -f $DateTime, $Message) | Out-File -LiteralPath $Global:DebugLogFile -Append -Encoding utf8
        }
        catch
        {
            # Never let a debug-log write failure interrupt the run.
        }
    }
}

# Return $true only if $Path is a real, NON-EMPTY leaf file - the single definition of "the report archive is on disk".
# A 0-byte file (AV/DLP quarantine or a cut-off write) or a directory at that path is not usable; shared so both packaging sides apply the SAME test and cannot drift.
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


# Resolve and prove-writable the ONE output root; returns a result object (Ok/Path/Source/IsFallback/Message) rather than throwing (a bare throw is swallowed under this project's $ErrorActionPreference = 'SilentlyContinue').
# An explicit -OutputDirectory is NEVER silently redirected (unusable -> Ok=$false); only the DEFAULT location degrades to the temp dir, and the chosen path is pinned into $env:RDA_INVENTORY_ROOT so -ParallelStreams child processes use the same directory.
function Get-RdaInventoryRoot
{
    [CmdletBinding()]
    param(
        # An operator-supplied -OutputDirectory. Never silently redirected.
        [string]$Requested,

        # Ignore $env:RDA_INVENTORY_ROOT. Used by the process that ESTABLISHES the
        # root so it re-probes rather than trusting a value left over in its own
        # environment from an earlier run in the same shell.
        [switch]$NoInherit
    )

    # Create + prove writable in one step. A Test-Path/permission inspection is not
    # enough: DLP products, read-only mounts and ACL edge cases all present as a
    # directory that exists and looks fine until something writes to it. The probe
    # file is removed again, and a cleanup failure does not fail the probe - the
    # write itself already succeeded, which is the thing being established.
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

    # 1. Explicit -OutputDirectory. Pass or fail, never redirect.
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

    # 2. A root already established by a parent process in this run.
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
        # Fall through and re-probe rather than failing: a stale value from an
        # earlier shell session must not break this run.
        Write-Verbose ("Inherited RDA_INVENTORY_ROOT '{0}' unusable ({1}); re-probing." -f $Inherited, $Err)
    }

    # 3. Preferred default, then the temp fallback. $HOME is only a candidate when
    # it is actually set - otherwise "$HOME/InventoryReports" degrades to the
    # filesystem root, which is the exact silent failure this ordering prevents.
    $Candidates = @()
    if ($PSVersionTable.Platform -eq 'Unix')
    {
        if (-not [string]::IsNullOrWhiteSpace($HOME)) { $Candidates += (Join-Path $HOME 'InventoryReports') }
    }
    else
    {
        $WinBase = if (-not [string]::IsNullOrWhiteSpace($env:SystemDrive)) { $env:SystemDrive + '\' } else { 'C:\' }
        $Candidates += (Join-Path $WinBase 'InventoryReports')
        # A locked-down estate frequently refuses the drive root but allows the
        # user profile, so try that before giving up on a persistent location.
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

# Pin the resolved root so child processes (the -ParallelStreams stream workers)
# use the SAME directory as their parent instead of re-probing independently.
function Set-RdaInventoryRootForChildren
{
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $env:RDA_INVENTORY_ROOT = $Path
}

# Consumption/billing error classification: returns $true only for an unambiguous AUTHORIZATION denial (the caller then ABANDONS that subscription's billing data).
# Throttling, auth-expiry, 5xx and 404 are deliberately NOT denials - a false denial throws away retrievable billing data, while a missed one only costs wasted backoff.
function Test-RdaConsumptionDenial
{
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$ErrorMessage)

    if ([string]::IsNullOrWhiteSpace($ErrorMessage)) { return $false }

    # Authorization/permission denial signatures. Every branch is anchored with (?<![\w-])...(?![\w-]), NOT plain \b,
    # because a billing exception echoes resource ids/names back and \b treats '-' as a boundary, so a name like 'rg-forbidden-01' would otherwise match and wrongly abandon retrievable data.
    $DenialPattern = '(?i)(' + (@(
            # (?<!un) rather than \b. \b excluded 'Unauthorized' correctly but ALSO
            # excluded 'LinkedAuthorizationFailed', which is a REAL ARM error code, so the
            # 401 fix had introduced a false NEGATIVE. A negative lookbehind on 'un' says
            # exactly what is meant: any 'authoriz' except the unauthenticated one.
            '(?<!un)authoriz'                           # Authorization / AuthorizationFailed / LinkedAuthorizationFailed / not authorized
            '(?<![\w-])forbidden(?![\w-])'              # the HTTP 403 reason phrase, how ARM actually renders it
            '\(403\)'                                   # '(403)' when only the numeric status is present
            # \s? and a 40-char gap because .NET renders 'Response status code does not
            # indicate success: 403 (Forbidden).' - a 27-char gap that the previous
            # {0,15} could not span - and 'StatusCode: 403' as a single token. \D cannot
            # cross another digit, so this still cannot reach the 403 inside a request id.
            '\bstatus\s?code\D{0,40}403\b'
            'does not have (?:authorization|permission|access|the required)'
            '\bnot authorized\b'
            '\binsufficient privileg'
            '\baccess is denied\b'
            '(?<![\w-])RBAC(?![\w-])'
        ) -join '|') + ')'

    return [bool]($ErrorMessage -match $DenialPattern)
}

# Recognise a FAILED AUTHENTICATION (expired/invalid/missing token) - the class a token REFRESH can fix - as distinct from an authorization DENIAL and from THROTTLING.
# 403 / AuthorizationFailed are intentionally ABSENT (those are denials owned by Test-RdaConsumptionDenial, which the caller checks first).
function Test-RdaAuthExpiry
{
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$ErrorMessage)

    if ([string]::IsNullOrWhiteSpace($ErrorMessage)) { return $false }

    $AuthExpiryPattern = '(?i)(' + (@(
            'ExpiredAuthenticationToken'
            'InvalidAuthenticationToken'
            'AuthenticationFailed'                       # the ARM error CODE for a rejected/failed bearer. Verified against the live ARM server: a malformed or otherwise unusable token returns '{ "error": { "code": "AuthenticationFailed", "message": "Authentication failed." } }' as a 401. Like its two sibling *AuthenticationToken codes above it is a compound identifier that cannot appear inside a resource name, so it needs no hyphen anchoring. It is a 401 (authentication), NOT a 403 - it stays out of Test-RdaConsumptionDenial so the loop refreshes and retries rather than abandoning the subscription.
            '\baccess token\b[^.]{0,40}\bexpir'          # 'the access token expiry ...' / 'access token has expired'
            '\btoken\b[^.]{0,20}\bhas expired\b'
            '\bauthentication failed\b'                  # the human-readable message form ('Authentication failed.') that accompanies the AuthenticationFailed code, in case only the message survives. \b-anchored like the phrase branches above; it is a two-word auth phrase with no hyphen-in-name hazard.
            '\(401\)'                                    # '(401)' when only the numeric status is present
            '\bstatus\s?code\D{0,40}401\b'               # '... status code does not indicate success: 401'
            '(?<![\w-])unauthorized(?![\w-])'            # the HTTP 401 reason phrase. Anchored with (?<![\w-])...(?![\w-]) - NOT plain \b - because \b treats '-' as a boundary, so a resource group or id echoed back in a billing exception ('rg-unauthorized-01') would otherwise trip a false auth-expiry match and a spurious token refresh. Same guard the denial predicate uses.
        ) -join '|') + ')'

    return [bool]($ErrorMessage -match $AuthExpiryPattern)
}
