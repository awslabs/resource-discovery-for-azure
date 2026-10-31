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
#   -ToDebugLog  also append the line to the consolidated LOCAL debug log
#                ($Global:DebugLogFile) - the one file the heartbeat and metrics
#                diagnostics share. Local-only, never zipped.
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
Function Global:Write-Log([string]$Message, [string]$Severity, [switch]$NoConsole, [switch]$ToDebugLog)
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

    # Consolidated LOCAL debug log sink (opt-in via -ToDebugLog): the single file
    # the per-collector heartbeat and the metrics-phase diagnostics share
    # ($Global:DebugLogFile). Local-only, never zipped - it carries real
    # service/resource names and, for FAIL lines, raw exception text. Silent
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

# Sign-in checks used by Run-AllSubscriptions.ps1 and by a direct run of
# ResourceInventory.ps1, so both decide the same way whether an existing Az
# PowerShell sign-in can be reused. The tool signs in with Az PowerShell only.

# $true when a person can answer a prompt in this console.
function Test-RdaInteractiveSession
{
    return ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected)
}

# The subscriptions of tenant $Tenant, as the run lists them: asked from Az
# PowerShell with -TenantId, so a subscription delegated to the tenant (Azure
# Lighthouse), whose HomeTenantId is another tenant, is kept. A subscription
# returned twice is listed once (first one kept, ids compared without case).
# Every state is kept, as `az account list` listed them; the -RunAllSubs
# wrapper applies its own Enabled filter. Each entry has the properties
# callers read: id, name, tenantId (the tenant asked when Az gives none),
# homeTenantId and state.
function Get-RdaTenantSubscriptions
{
    param([Parameter(Mandatory = $true)][string]$Tenant)
    $Seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $List = [System.Collections.Generic.List[object]]::new()
    foreach ($Sub in @(Get-AzSubscription -TenantId $Tenant -WarningAction SilentlyContinue))
    {
        if ($null -eq $Sub -or [string]::IsNullOrWhiteSpace([string]$Sub.Id)) { continue }
        if (-not $Seen.Add([string]$Sub.Id)) { continue }
        $List.Add([pscustomobject][ordered]@{
                id           = [string]$Sub.Id
                name         = [string]$Sub.Name
                tenantId     = $(if ([string]::IsNullOrWhiteSpace([string]$Sub.TenantId)) { $Tenant } else { [string]$Sub.TenantId })
                homeTenantId = [string]$Sub.HomeTenantId
                state        = [string]$Sub.State
            })
    }
    return $List.ToArray()
}

function Get-AzPsSignedInTenant
{
    try
    {
        $Ctx = Get-AzContext -ErrorAction Stop
        if ($null -eq $Ctx -or $null -eq $Ctx.Account) { return $null }
        return $Ctx.Tenant.Id
    }
    catch
    {
        return $null
    }
}

# Probe whether Az PowerShell can silently acquire a token for $TenantID.
# Get-AzAccessToken in this configuration emits a non-terminating warning
# instead of throwing on token-acquisition failure, so we capture warnings
# explicitly and treat any warning as a failure signal in addition to
# catching outright exceptions. We DO NOT treat the Az.Accounts 4.x
# deprecation banner as a failure - that warning fires on every successful
# call now that the SecureString-output cmdlet is the recommended path,
# and ignoring it lets users on the new module version skip re-auth.
function Test-AzPsTokenSilent
{
    param([Parameter(Mandatory = $true)][string]$Tenant)
    $Warnings = @()
    try
    {
        $Token = Get-AzAccessToken -TenantId $Tenant -ErrorAction Stop -WarningVariable warnings -WarningAction SilentlyContinue
        if ($null -eq $Token -or [string]::IsNullOrWhiteSpace($Token.Token)) { return $false }
        # Filter out known-benign warnings before deciding the call failed.
        # Az.Accounts >= 4.x emits a deprecation banner about the plain-string
        # output every time the cmdlet returns successfully; treating that as
        # failure forces users to re-authenticate every run.
        $RealWarnings = @($Warnings | Where-Object {
                $Msg = $_.Message
                -not (
                    $Msg -match 'Get-AzAccessToken\s*:?\s*Upcoming breaking changes' -or
                    $Msg -match 'AsSecureString' -or
                    $Msg -match 'plain string token output is deprecated'
                )
            })
        if ($RealWarnings.Count -gt 0) { return $false }
        return $true
    }
    catch
    {
        return $false
    }
}

# The sign-in gate of Run-AllSubscriptions.ps1, before it starts
# ResourceInventory.ps1 for each subscription. An Az PowerShell sign-in that
# is on $TenantID and can still acquire a token silently is reused with no
# prompt (Cloud Shell, a second run). Two things have to be true: the tenant
# alone is not enough, because a context can persist on disk with the right
# tenant but an expired or revoked refresh token (typically Conditional
# Access or MFA), and every data-plane call would then quietly return
# nothing. Otherwise it signs in once (device code with -DeviceLogin) and
# checks the token again; when the token still fails it throws, so the
# wrapper stops instead of prompting a second time or collecting an empty
# inventory. A usable sign-in is never disconnected.
function Connect-RdaWrapperSession
{
    param([Parameter(Mandatory = $true)][string]$TenantID, [switch]$DeviceLogin)

    $PsTenant = Get-AzPsSignedInTenant
    if ($PsTenant -eq $TenantID -and (Test-AzPsTokenSilent -Tenant $TenantID))
    {
        Write-Host ("Existing session detected for tenant {0} (token probe ok); skipping interactive login." -f $TenantID) -ForegroundColor Green
        return
    }

    if ($null -eq $PsTenant)
    {
        Write-Host "Az PowerShell is not signed in; authenticating..." -ForegroundColor Cyan
    }
    elseif ($PsTenant -ne $TenantID)
    {
        Write-Host ("Az PowerShell is signed in to tenant {0}; switching to {1}..." -f $PsTenant, $TenantID) -ForegroundColor Cyan
    }
    else
    {
        Write-Host ("Az PowerShell session for tenant {0} cannot acquire a token silently (likely expired or CA/MFA-gated); re-authenticating..." -f $TenantID) -ForegroundColor Cyan
    }

    # As a direct run does: with no console to sign in from (a scheduled task,
    # CI, pwsh -NonInteractive), stop instead of opening a browser.
    if (-not $DeviceLogin -and -not (Test-RdaInteractiveSession))
    {
        throw ("Az PowerShell: no usable sign-in for tenant {0}, and this session has no console to sign in from (non-interactive); stopping instead of opening a browser. Run 'Connect-AzAccount -Tenant {0}' before the run, or pass -DeviceLogin." -f $TenantID)
    }
    if ($DeviceLogin) { Connect-AzAccount -Tenant $TenantID -UseDeviceAuthentication -ErrorAction Stop | Out-Null }
    else { Connect-AzAccount -Tenant $TenantID -ErrorAction Stop | Out-Null }

    if (-not (Test-AzPsTokenSilent -Tenant $TenantID))
    {
        throw ("Az PowerShell sign-in to tenant {0} did not give a usable token; stopping instead of prompting again. Run 'Connect-AzAccount -Tenant {0}' yourself, complete any MFA or Conditional Access prompt, then re-run (or pass -DeviceLogin)." -f $TenantID)
    }
}
