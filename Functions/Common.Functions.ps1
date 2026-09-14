#Requires -Version 7.0
# =============================================================================
# Common.Functions.ps1
#
# Cross-cutting helper functions shared by the entry-point scripts
# (Run-AllSubscriptions.ps1, Run-AllSubscriptions.Stream.ps1,
# ResourceInventory.ps1, Reveal.ps1). Dot-sourced from the top
# of each so the functions load into that script's scope. Definitions only -
# no top-level code.
# =============================================================================

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
            Add-Content -Path $HeartbeatLogFile -Value $Line -ErrorAction Stop
        }
        catch
        {
            # Best-effort only - progress reporting must never break a run.
        }
    }
}

# =============================================================================
# Write-Log
#
# The single logging entry point for the whole tool. Moved here (from
# ResourceInventory.Functions.ps1) and defined Global: so EVERYTHING that logs
# routes through it - the orchestrator, the wrapper scripts, the metrics
# extension, and the Services/*/*.ps1 collectors (which run via '& $Module' and
# therefore only see Global functions, exactly like Protect-FreeTextValue).
#
# Default behavior is UNCHANGED from the original: with no switches it writes a
# severity-colored line to the console and, for Error severity, appends to the
# local error sink ($Global:ErrorLogFile). The two switches are purely additive
# so existing callers are byte-for-byte unaffected:
#   -NoConsole   suppress the console line (for high-volume diagnostics that
#                must NOT flood the terminal - metrics phase, per-collector
#                heartbeat). The line still goes to any file sink selected.
#   -ToDebugLog  also append the line to the consolidated debug log
#                ($Global:DebugLogFile) - the one file the heartbeat and metrics
#                diagnostics share. Its contents are UNSCRUBBED (real
#                service/resource names, raw exception text), and its zipping
#                posture is MODE-DEPENDENT: LOCAL-only under -Obfuscate, but
#                INCLUDED in the zip on a default (non-obfuscated) run, whose
#                report already carries real names. So treat anything written
#                here as potentially shipping to a report consumer, and never
#                write a credential or token to it.
#
# NOTE on scope: the per-line '[<8-char sub>]' tag is read via Get-Variable so it
# resolves the caller's script-scope $SubscriptionID without throwing when none
# is set. From a collector invoked via '&' that lookup may not cross the scope
# boundary, in which case the tag is simply omitted (the debug/error log
# filenames are already SubscriptionID-tagged, so nothing is lost).
#
# Deliberately NOT baked in (kept separate on purpose):
#   - Progress UI: that is Write-RdaProgress above (a bar, not a log line).
#   - Obfuscation scrubbing (Protect-DiagnosticText): only the SHAREABLE
#     Diagnostics_*.log needs scrubbing, and it is built once at packaging time
#     from aggregated health globals - NOT line-by-line here. Scrubbing every
#     log line would be slow and would destroy the local logs' raw
#     troubleshooting value, so it stays out of the hot path.
#   - Per-call logging from inside ForEach-Object -Parallel workers: concurrent
#     appends to one file are not safe. Those paths record into a thread-safe
#     bag and are logged as an aggregated summary on the main thread instead.
# =============================================================================
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

    # Errors-only local sink: when an error-log path has been established append
    # error-severity messages to a dedicated, timestamped file.
    #
    # IMPORTANT: this log is written LOCALLY ONLY and is deliberately NOT added
    # to the obfuscated (server-bound) zip. Error-severity messages can
    # interpolate raw $_.Exception.Message text and local paths (e.g. collector
    # failures, reconnect failures, HTML-gen failures) that carry real Azure
    # identifiers the obfuscation layer never touches. Shipping this file would
    # leak them. Do NOT add $Global:ErrorLogFile to the Compress-Archive Path
    # array without first scrubbing/obfuscating its contents. It is kept on disk
    # for local troubleshooting only, at the same trust level as the transcript.
    if ($Severity -eq 'Error' -and -not [string]::IsNullOrEmpty($Global:ErrorLogFile))
    {
        try
        {
            ('{0} {1}' -f $DateTime, $Message) | Out-File -FilePath $Global:ErrorLogFile -Append -Encoding utf8
        }
        catch
        {
            # Never let an error-log write failure interrupt the run.
        }
    }

    # Consolidated debug log sink (opt-in via -ToDebugLog): the single file the
    # per-collector heartbeat and the metrics-phase diagnostics share
    # ($Global:DebugLogFile). UNSCRUBBED - it carries real service/resource names
    # and, for FAIL lines, raw exception text. Zipping posture is MODE-DEPENDENT:
    # LOCAL-only under -Obfuscate, INCLUDED in the zip on a default run. Silent
    # best-effort like the error sink; nothing is written until the global path
    # exists, so callers before setup (or a standalone extension run) are
    # unaffected.
    if ($ToDebugLog -and -not [string]::IsNullOrEmpty($Global:DebugLogFile))
    {
        try
        {
            ('{0} {1}' -f $DateTime, $Message) | Out-File -FilePath $Global:DebugLogFile -Append -Encoding utf8
        }
        catch
        {
            # Never let a debug-log write failure interrupt the run.
        }
    }
}

# Return $true only if $Path is a real, NON-EMPTY file - the single definition of
# "this subscription's report archive is actually on disk".
#
# Presence alone is not enough. A 0-byte file is not a report, and it is exactly
# what a truncating antivirus/DLP quarantine, or a write cut off mid-flush by an
# out-of-space or ephemeral-storage eviction, leaves behind.
#
# -PathType Leaf matters independently: a DIRECTORY sitting at the archive path is
# not an archive either, and it also blocks the write outright.
#
# This lives in Common.Functions.ps1 because BOTH sides of the packaging seam must
# apply the SAME standard, and both dot-source this file:
#   - ResourceInventory.ps1 checks its own archive before it reports success, and
#   - Run-AllSubscriptions.ps1's per-subscription output verification re-checks it
#     at the end of the run (a quarantine can strike in between).
# Two separate definitions would drift, and the failure mode of that drift is the
# wrapper consolidating an archive the inner script would have rejected.
#
# Pure and side-effect free, so it is unit-testable without a live run. Any error
# reading the item returns $false: an archive we cannot confirm is not one we
# should claim.
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


# Resolve the ONE directory this run writes everything under, and guarantee it is
# actually usable before anything derives a path from it.
#
# WHY THIS IS SHARED. The root used to be computed inline as
#   if ($PSVersionTable.Platform -eq 'Unix') { "$HOME/InventoryReports" } else { "C:\InventoryReports" }
# in SIX separate places across Run-AllSubscriptions.ps1 and ResourceInventory.ps1.
# The wrapper does NOT tell the inner script where it chose - the inner script
# derives its own - so the two agreed only because the arithmetic was duplicated
# identically. Any per-site divergence (a fallback applied in one place but not
# another) would leave the wrapper consolidating from a directory the inner script
# never wrote to. One function removes that class of bug by construction.
#
# WHY A FALLBACK AT ALL. The previous behaviour on a machine where that path is
# not writable was: creation fails, the failure is swallowed to Write-Verbose
# (invisible by default), and the run continues and fails later somewhere
# confusing. Verified failure modes:
#   - $HOME unset or empty (daemon, container, `sudo -E`, some CI runners). The
#     Unix branch then produced the literal '/InventoryReports' - the FILESYSTEM
#     ROOT - which a normal user cannot create.
#   - A managed macOS/Windows estate where MDM/DLP blocks writes to that path.
#   - Windows C:\ root writes refused without elevation.
# The tool should still produce a report in those cases rather than demand the
# operator diagnose a path problem, so an unwritable preferred location degrades
# to the OS temp directory with a LOUD warning naming where the output went.
#
# EXPLICIT REQUESTS ARE NEVER SILENTLY REDIRECTED. When the caller passed
# -OutputDirectory they named a location on purpose, very often a mount or share
# they intend to collect from. Quietly writing somewhere else would be worse than
# failing, so an unusable explicit path returns Ok=$false and the caller hard-fails.
# Only the DEFAULT location is allowed to degrade.
#
# PROCESS AGREEMENT. The chosen path is pinned into $env:RDA_INVENTORY_ROOT, which
# child processes inherit. -ParallelStreams launches stream workers as separate
# pwsh processes, so this is what makes a fallback chosen by the parent bind for
# every worker instead of each one re-probing and possibly deciding differently.
# It is an internal implementation detail, NOT a supported operator knob, and it is
# deliberately not a script parameter: adding one would change the wrapper's
# parameter surface and its passthrough key sets.
#
# Returns a result object rather than throwing, because the two callers hard-fail
# differently (the wrapper calls Exit-Wrapper, the inner script uses exit 1) and
# because a bare throw at script scope is SWALLOWED under this project's normal
# $ErrorActionPreference = 'SilentlyContinue'.
#   Ok         - $true when Path is created and proven writable
#   Path       - the resolved root (no trailing separator)
#   Source     - 'Explicit' | 'Inherited' | 'Default' | 'Fallback'
#   IsFallback - $true when the preferred location was unusable
#   Message    - operator-facing detail; caller decides the severity
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

# =============================================================================
# Consumption / billing error classification
# =============================================================================
# Does this billing error mean "you are not allowed", as opposed to "try again"?
#
# It lives HERE rather than beside either caller because BOTH entry points need
# it and both dot-source this file:
#   - Run-AllSubscriptions.ps1 : the up-front access gate, via
#     Get-ConsumptionAccessOutcome in Functions/RunAllSubscriptions.Functions.ps1,
#     which delegates to this function so the signatures are defined once.
#   - ResourceInventory.ps1    : the per-page retry loop around Get-UsageAggregates,
#     which must ABANDON a denial immediately instead of retrying it.
#
# One owner matters here specifically: the two callers draw opposite conclusions
# from the same verdict (the gate STOPS the run, the retry loop STOPS RETRYING),
# so two copies of the pattern drifting apart would make the run's behaviour
# depend on which copy saw the error first.
#
# Returns $true only for an unambiguous AUTHORIZATION denial. Everything else -
# throttling, a token that needs refreshing, Conditional Access, a 5xx, an
# unsupported-API 404, a transient "Error while copying content to a stream" - is
# deliberately NOT a denial, because those can succeed on a retry and the
# expensive mistake is abandoning a subscription's billing data that was
# retrievable. A missed denial only costs some wasted backoff; a false denial
# costs the data.
function Test-RdaConsumptionDenial
{
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$ErrorMessage)

    if ([string]::IsNullOrWhiteSpace($ErrorMessage)) { return $false }

    # Authorization / permission denial signatures across ARM and the billing APIs.
    #
    # Every branch below is deliberately anchored, because this predicate decides
    # whether to ABANDON a subscription's billing data. Each loose form that was
    # here before had a way to fire on something retryable:
    #
    #   'authoriz'  -> also matched UNAUTHORIZED, i.e. HTTP 401. A 401 is a failed
    #                  AUTHENTICATION (missing, expired or invalid token), which is
    #                  exactly the transient class that succeeds after a refresh.
    #                  Classifying it as a denial abandoned recoverable data.
    #                  KNOWN RESIDUAL, accepted deliberately: an interaction-required
    #                  or revoked refresh token is a PERMANENT 401, and the retry loop
    #                  does not re-auth, so it now burns the full budget (~26 min for
    #                  that subscription) before failing where it used to fail at once.
    #                  That is the correct trade under this function's asymmetry - the
    #                  alternative abandons recoverable billing data on every ordinary
    #                  token expiry - but it is a cost, not a free win.
    #   'does not have'
    #               -> matched any sentence with that phrase, including benign ones
    #                  such as a scope that "does not have any usage data". Only the
    #                  ARM permission phrasing counts.
    #   '\b403\b'   -> \b treats '-' as a boundary, so an id or URL echoed back in a
    #                  billing exception ('rg-403-prod') read as a 403. The bare number
    #                  now needs HTTP-status context around it.
    #   'RBAC'      -> unbounded, so it hit the letters inside a longer token.
    #
    # The asymmetry that drives all of this: a MISSED denial costs wasted backoff before
    # failing in the same place anyway, while a FALSE denial throws away billing data that
    # was retrievable. So when in doubt, not a denial.
    #
    # One qualification on that asymmetry, because it is load-bearing and easy to
    # over-apply: it is NOT symmetric between the two callers. At the wrapper's up-front
    # gate a false denial stops the WHOLE RUN, so precision matters most there; but that
    # gate probes only the first eligible subscription, so a MISSED denial is paid as
    # ~26 minutes of pointless backoff on EVERY subscription. Neither direction is cheap
    # at scale - this reasoning must not be read as licence to loosen the pattern.
    # A hyphen is a NON-word character, so '\b' offers no protection against a resource
    # name: '\bforbidden\b' matches inside 'rg-forbidden-01' and '\bRBAC\b' matches inside
    # 'rg-rbac-prod'. Since a billing exception echoes ids and resource groups back, the
    # word-class guards below exclude hyphen on BOTH sides - (?<![\w-]) ... (?![\w-]) -
    # which still matches every real rendering ('(403) Forbidden', "'Forbidden'",
    # 'Forbidden.') while refusing the embedded-in-a-name case. All verified both ways.
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

# Recognise a FAILED AUTHENTICATION (an expired, invalid, or missing access
# token) as distinct from an authorization DENIAL and from THROTTLING. This is
# the class that a token REFRESH can fix, so the consumption retry loop uses it
# to decide when to re-establish the Azure context (via Test-DataPlaneAuthReady)
# before retrying the same page - the gap that previously let an interactive
# session's token lapse mid-subscription and then burned the whole retry budget
# against a dead token before failing (see the KNOWN RESIDUAL note in
# Test-RdaConsumptionDenial above).
#
# Kept deliberately separate from Test-RdaConsumptionDenial: a 401 / expired
# token must NOT be a denial (a denial is abandoned; this is refreshed and
# retried), and it must NOT be read as throttling (throttling backs off but does
# not re-auth). The signatures below are the authentication-failure renderings
# ARM and the Az/MSAL stack actually produce, anchored the same way the denial
# predicate is so an id or URL echoed back in an exception cannot trip them:
#   ExpiredAuthenticationToken / InvalidAuthenticationToken - ARM error codes
#   AuthenticationFailed / 'Authentication failed.'          - ARM 401 for a rejected bearer (verified against the live server)
#   'the access token ... expired' / 'token ... has expired' - MSAL / Az renderings
#   '(401)' / 'status code ... 401' / 'Unauthorized'         - the HTTP 401 status
# 403 / AuthorizationFailed are intentionally ABSENT: those are denials, owned by
# Test-RdaConsumptionDenial. A message that is BOTH (rare) is treated as a denial
# because the caller checks Test-RdaConsumptionDenial first.
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
