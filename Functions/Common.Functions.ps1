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

# ---- Role check -------------------------------------------------------------
# Resource Graph returns 0 rows rather than an error for a subscription the
# signed-in identity cannot read, and a list of the subscription's resource
# groups returns HTTP 200 with only the groups the identity can read (none for
# an identity that can read nothing). Neither proves read access, so both entry
# points decide it up front, per subscription, from two independent answers:
#
#   A. The identity's own role assignments: assignedTo(<object id>), which also
#      returns roles given through groups, and each role's definition.
#   B. Azure's answer for the caller's effective permissions at the target
#      scope (Microsoft.Authorization/permissions).
#
# Both are evaluated with the same rule (Get-RoleGrantsAllowing). The target is
# the subscription, or the resource group for a direct -ResourceGroup run.
# A subscription passes when A and B both find read access, or when A is not
# visible (an identity without Microsoft.Authorization read gets an empty list)
# and B finds read access. Any other combination stops the run. Read access
# means one role (one permission block) that reads every resource type: a
# role whose notActions remove reads of some resource types does not count,
# because Resource Graph would leave those resources out without an error.
#
# Usage permission (Microsoft.Commerce/UsageAggregates/read) is evaluated the
# same way, at the subscription only: the usage API is per subscription, so a
# role on a resource group never returns usage. It is information for the
# operator; the consumption data check below decides whether usage values
# come back.
#
# Used by Run-AllSubscriptions.ps1 (up-front check and the end-of-run
# 0-resource labels) and by direct runs of ResourceInventory.ps1.

# Pure: does an action pattern from a role definition match an action? '*'
# matches any run of characters, including '/'; the comparison ignores case.
function Test-RoleActionPatternMatch
{
    param([string]$Pattern, [string]$Action)
    if ([string]::IsNullOrEmpty($Pattern) -or [string]::IsNullOrEmpty($Action)) { return $false }
    $Regex = '^' + ([regex]::Escape($Pattern) -replace '\\\*', '.*') + '$'
    return [regex]::IsMatch($Action, $Regex, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
}

# Pure: one permission block (the actions and notActions of ONE role, or one
# entry of the caller-permissions answer) allows an action when one of its
# actions matches and none of its own notActions does. notActions never
# subtract from another role.
function Test-RoleActionAllowed
{
    param([object[]]$Actions, [object[]]$NotActions, [string]$Action)
    $Granted = @(@($Actions) | Where-Object { Test-RoleActionPatternMatch -Pattern ([string]$_) -Action $Action }).Count -gt 0
    if (-not $Granted) { return $false }
    return @(@($NotActions) | Where-Object { Test-RoleActionPatternMatch -Pattern ([string]$_) -Action $Action }).Count -eq 0
}

# The two actions the role check evaluates. Reading resources is tested with a
# read action of a provider that does not exist, so only a pattern that covers
# any read action (such as '*/read' or '*') grants it; Get-RoleGrantsAllowing
# also requires that no notAction of the same role removes reads of some
# resource type.
function Get-RoleCheckAction
{
    param([ValidateSet('Resources', 'Usage')][string]$Kind)
    if ($Kind -eq 'Usage') { return 'Microsoft.Commerce/UsageAggregates/read' }
    return 'Rda.AnyProvider/anyResourceType/read'
}

# Pure: the first notAction of one permission block that can remove read
# access to some resource type, or $null. With '*' read as any characters,
# '/' included (Test-RoleActionPatternMatch), a pattern counts when it can
# match an action that ends in '/read' (ignoring case): a pattern without '*'
# when it ends in '/read'; a pattern with '*' when the text after its last '*'
# is empty, is the end of '/read' ('read', 'ad', 'd', ...) or itself ends in
# '/read'. A pattern is allowed when its fixed start (the text before its
# first '*', or all of it) begins with one of the namespaces below and '/',
# because the inventory reads no resources there: Microsoft.Authorization (a
# role that cannot read role assignments is handled as 'not visible' by the
# role check) and the billing namespaces, which the consumption data check
# covers. So 'Microsoft.Authorization/*' is allowed, but 'Microsoft.Auth*',
# which can also match other namespaces, is not. Resource Graph silently
# leaves out resources the caller cannot read, so a role such as '*/read'
# minus 'Microsoft.Compute/*/read' would otherwise pass the check and produce
# an inventory without those resources.
function Get-RoleReadExclusion
{
    param([object[]]$NotActions)
    $Exempt = @('Microsoft.Authorization', 'Microsoft.Commerce', 'Microsoft.Consumption', 'Microsoft.Billing')
    $IgnoreCase = [System.StringComparison]::OrdinalIgnoreCase
    foreach ($Pattern in @($NotActions))
    {
        $Text = [string]$Pattern
        if ([string]::IsNullOrEmpty($Text)) { continue }
        $FirstStar = $Text.IndexOf('*')
        if ($FirstStar -lt 0)
        {
            $CanMatchRead = $Text.EndsWith('/read', $IgnoreCase)
            $FixedStart = $Text
        }
        else
        {
            $Tail = $Text.Substring($Text.LastIndexOf('*') + 1)
            $CanMatchRead = '/read'.EndsWith($Tail, $IgnoreCase) -or $Tail.EndsWith('/read', $IgnoreCase)
            $FixedStart = $Text.Substring(0, $FirstStar)
        }
        if (-not $CanMatchRead) { continue }
        if (@($Exempt | Where-Object { $FixedStart.StartsWith($_ + '/', $IgnoreCase) }).Count -gt 0) { continue }
        return $Text
    }
    return $null
}

# Pure: labels of the grants (objects with Label, Actions, NotActions) that
# allow $Action. For the resource read action (Get-RoleCheckAction -Kind
# Resources) a grant also needs no notAction that removes read access to some
# resource type (Get-RoleReadExclusion): each grant is one role, so Reader
# beside a narrower custom role still passes.
function Get-RoleGrantsAllowing
{
    param([object[]]$Grants, [string]$Action)
    $ReadCheck = $Action -eq (Get-RoleCheckAction -Kind Resources)
    return @(@($Grants) | Where-Object {
            $null -ne $_ -and (Test-RoleActionAllowed -Actions $_.Actions -NotActions $_.NotActions -Action $Action) -and
            (-not $ReadCheck -or $null -eq (Get-RoleReadExclusion -NotActions $_.NotActions))
        } | ForEach-Object { [string]$_.Label } | Select-Object -Unique)
}

# Pure: for grants that allow reading resources except for some resource
# types, one entry per grant: { Grant; Pattern } with the first excluding
# notAction. Used to say why the resource read check failed.
function Get-RoleReadExclusions
{
    param([object[]]$Grants)
    $Action = Get-RoleCheckAction -Kind Resources
    foreach ($Grant in @($Grants))
    {
        if ($null -eq $Grant -or -not (Test-RoleActionAllowed -Actions $Grant.Actions -NotActions $Grant.NotActions -Action $Action)) { continue }
        $Pattern = Get-RoleReadExclusion -NotActions $Grant.NotActions
        if ($null -ne $Pattern) { [pscustomobject]@{ Grant = $Grant; Pattern = $Pattern } }
    }
}

# Pure: where a role assignment's scope sits for a check on $SubscriptionId
# (and, for a -ResourceGroup run, $ResourceGroup). Returns 'tenant root',
# 'management group', 'subscription', 'target resource group' (the run's
# resource group), 'resource group' (any other resource group of the
# subscription), 'resource' (one resource) or 'other'.
function Get-RoleAssignmentScopeKind
{
    param([string]$Scope, [string]$SubscriptionId, [string]$ResourceGroup)
    $Trimmed = ([string]$Scope).TrimEnd('/')
    if ([string]::IsNullOrEmpty($Trimmed)) { return 'tenant root' }
    if ($Trimmed -match '^/providers/Microsoft\.Management/managementGroups/[^/]+$') { return 'management group' }
    $SubScope = '/subscriptions/' + $SubscriptionId
    if ($Trimmed -ieq $SubScope) { return 'subscription' }
    if (-not $Trimmed.StartsWith($SubScope + '/', [System.StringComparison]::OrdinalIgnoreCase)) { return 'other' }
    if ($Trimmed -match '^/subscriptions/[^/]+/resourceGroups/([^/]+)$')
    {
        if (-not [string]::IsNullOrEmpty($ResourceGroup) -and $Matches[1] -ieq $ResourceGroup) { return 'target resource group' }
        return 'resource group'
    }
    return 'resource'
}

# Pure: scope kinds that count. Usage is per subscription, so only grants at
# the subscription or above count for it; a -ResourceGroup run also counts its
# own resource group for reading resources.
function Get-RoleCheckCountedScopeKinds
{
    param([ValidateSet('Resources', 'Usage')][string]$Kind)
    $Above = @('tenant root', 'management group', 'subscription')
    if ($Kind -eq 'Usage') { return $Above }
    return $Above + @('target resource group')
}

# The signed-in identity's object id, from the 'oid' claim of its own Resource
# Manager token (no directory call). $null when it cannot be read.
function Get-RoleCheckCallerObjectId
{
    try
    {
        $ResourceUrl = 'https://management.azure.com/'
        $Context = Get-AzContext -ErrorAction Stop
        if ($null -ne $Context -and -not [string]::IsNullOrEmpty([string]$Context.Environment.ResourceManagerUrl))
        {
            $ResourceUrl = [string]$Context.Environment.ResourceManagerUrl
        }
        $Token = Get-AzAccessToken -ResourceUrl $ResourceUrl -WarningAction SilentlyContinue -ErrorAction Stop
        $Raw = if ($Token.Token -is [securestring]) { [System.Net.NetworkCredential]::new('', $Token.Token).Password } else { [string]$Token.Token }
        $Parts = $Raw.Split('.')
        if ($Parts.Count -lt 2) { return $null }
        $Payload = $Parts[1].Replace('-', '+').Replace('_', '/')
        while ($Payload.Length % 4) { $Payload += '=' }
        $Claims = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Payload)) | ConvertFrom-Json
        if ([string]::IsNullOrEmpty([string]$Claims.oid)) { return $null }
        return [string]$Claims.oid
    }
    catch
    {
        Write-Verbose ('Could not read the signed-in identity''s object id from its token: {0}' -f $_.Exception.Message)
        return $null
    }
}

# One ARM GET through Invoke-AzRestMethod with the consumption check's retry
# policy (Invoke-ConsumptionCallWithRetry): throttling (429), timeouts and 5xx
# are retried with backoff; any other status is returned at once, so a 400 is
# not retried. List answers are followed through the path and query of
# nextLink, for at most $MaxPages pages; past that the answer is an error
# ('more than N pages'), as is a nextLink that is not a valid URL; either
# leaves the check inconclusive, so the subscription is not readable.
# Returns
# { Status; Items; Body; Error }: Status is the last HTTP status ($null for a
# client-side failure), Items the 'value' entries of every page, Body the last
# page.
function Invoke-RoleCheckGet
{
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$MaxRetries = 3,
        [int]$MaxPages = 1000
    )
    $Items = @()
    $Body = $null
    $Target = @{ Path = $Path }
    $Pages = 0
    while ($null -ne $Target)
    {
        if ($Pages -ge $MaxPages)
        {
            return [pscustomobject]@{ Status = $null; Items = @(); Body = $null; Error = ('more than {0} pages' -f $MaxPages) }
        }
        $Call = Invoke-ConsumptionCallWithRetry -MaxRetries $MaxRetries -Argument $Target -Operation {
            param($Request)
            $Response = Invoke-AzRestMethod -Method GET @Request -ErrorAction Stop
            $Status = [int]$Response.StatusCode
            if ($Status -eq 408 -or $Status -eq 429 -or $Status -ge 500)
            {
                throw [System.Net.Http.HttpRequestException]::new(('HTTP {0}' -f $Status), $null, [System.Net.HttpStatusCode]$Status)
            }
            $Response
        }
        if ($null -ne $Call.Error)
        {
            return [pscustomobject]@{ Status = (Get-ConsumptionErrorStatusCode -Exception $Call.Error); Items = @(); Body = $null; Error = [string]$Call.Error.Message }
        }
        $Status = [int]$Call.Value.StatusCode
        if ($Status -lt 200 -or $Status -ge 300)
        {
            return [pscustomobject]@{ Status = $Status; Items = @(); Body = $null; Error = ('HTTP {0}' -f $Status) }
        }
        try { $Body = [string]$Call.Value.Content | ConvertFrom-Json -ErrorAction Stop }
        catch { return [pscustomobject]@{ Status = $Status; Items = @(); Body = $null; Error = 'the answer was not valid JSON' } }
        $Pages++
        if ($null -ne $Body -and $Body.PSObject.Properties.Name -contains 'value')
        {
            $Items += @(@($Body.value) | Where-Object { $null -ne $_ })
        }
        # A last page has no nextLink at all; read it so Set-StrictMode allows that.
        $Next = if ($null -ne $Body -and $null -ne $Body.PSObject.Properties['nextLink']) { [string]$Body.nextLink } else { '' }
        $Target = $null
        if (-not [string]::IsNullOrEmpty($Next))
        {
            # Only the link's path and query are followed, on the context's
            # Resource Manager endpoint like every other call here, so the
            # token never goes to a host named in the answer. A link that is
            # not an absolute http(s) URL, or has no path (or one starting
            # with '//', which names a host when joined to a base URL),
            # counts as a missing answer. The link itself is not logged.
            $NextUri = $null
            if (-not [uri]::TryCreate($Next, [System.UriKind]::Absolute, [ref]$NextUri) -or $NextUri.Scheme -notin @('https', 'http') -or $NextUri.AbsolutePath -notmatch '^/[^/]')
            {
                return [pscustomobject]@{ Status = $null; Items = @(); Body = $null; Error = 'the answer''s next-page link is not a valid URL' }
            }
            $Target = @{ Path = $NextUri.PathAndQuery }
        }
    }
    return [pscustomobject]@{ Status = $Status; Items = $Items; Body = $Body; Error = $null }
}

# Answer A for one subscription: the identity's role assignments and their
# definitions. $DefinitionCache (shared across subscriptions, synchronized when
# they are checked in parallel) keeps every role definition read successfully,
# by its id, so each is read once per run. A
# definition whose read was refused (HTTP 401, 403 or 404) is kept as $null,
# so it is not read again for later subscriptions; after any other failure
# (throttling, a server error, a timeout) it is read again.
# Returns { Resources; Usage; ResourcesGrantedBy; UsageGrantedBy;
# ResourcesExcluded; VisibleRoles; Detail } with Resources and Usage each
# 'Yes', 'No', 'NotVisible' (the list is empty or refused) or 'Unknown' (the
# answer stayed inconclusive). ResourcesExcluded, filled when Resources is
# 'No', names each role that reads resources except for some resource types
# (Get-RoleReadExclusion).
function Get-RoleAssignmentAccess
{
    param(
        [Parameter(Mandatory = $true)][string]$SubscriptionId,
        [string]$ResourceGroup,
        [string]$CallerObjectId,
        [hashtable]$DefinitionCache = @{},
        [int]$MaxRetries = 3
    )
    $Result = [pscustomobject]@{
        Resources          = 'Unknown'
        Usage              = 'Unknown'
        ResourcesGrantedBy = @()
        UsageGrantedBy     = @()
        ResourcesExcluded  = @()
        VisibleRoles       = @()
        Detail             = $null
    }
    if ([string]::IsNullOrEmpty($CallerObjectId))
    {
        $Result.Detail = 'the signed-in identity''s object id could not be read from its token'
        return $Result
    }

    $List = Invoke-RoleCheckGet -MaxRetries $MaxRetries -Path ("/subscriptions/{0}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&`$filter=assignedTo('{1}')" -f $SubscriptionId, $CallerObjectId)
    if ($List.Status -in @(401, 403, 404))
    {
        $Result.Resources = 'NotVisible'
        $Result.Usage = 'NotVisible'
        $Result.Detail = ('role assignment list refused (HTTP {0})' -f $List.Status)
        return $Result
    }
    if ($null -ne $List.Error)
    {
        $Result.Detail = ('role assignment list: {0}' -f $List.Error)
        return $Result
    }
    if (@($List.Items).Count -eq 0)
    {
        $Result.Resources = 'NotVisible'
        $Result.Usage = 'NotVisible'
        $Result.Detail = 'role assignment list is empty'
        return $Result
    }

    $Grants = @()
    $Unreadable = @()
    $Visible = @()
    foreach ($Assignment in @($List.Items))
    {
        $Props = $Assignment.properties
        $Kind = Get-RoleAssignmentScopeKind -Scope ([string]$Props.scope) -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup
        $DefinitionId = [string]$Props.roleDefinitionId
        $Key = ($DefinitionId.TrimEnd('/') -split '/')[-1].ToLowerInvariant()
        if (-not $DefinitionCache.ContainsKey($Key))
        {
            # Subscriptions may be checked in parallel (Test-SubscriptionRoleAccessAll):
            # a definition not yet cached is read under the cache's lock and
            # looked up again first, so each is read once per run.
            [System.Threading.Monitor]::Enter($DefinitionCache.SyncRoot)
            try
            {
                if (-not $DefinitionCache.ContainsKey($Key))
                {
                    $Definition = Invoke-RoleCheckGet -MaxRetries $MaxRetries -Path ($DefinitionId + '?api-version=2022-04-01')
                    if ($null -eq $Definition.Error -and $null -ne $Definition.Body.properties)
                    {
                        $DefinitionCache[$Key] = $Definition.Body.properties
                    }
                    elseif ($Definition.Status -in @(401, 403, 404))
                    {
                        $DefinitionCache[$Key] = $null
                    }
                }
            }
            finally
            {
                [System.Threading.Monitor]::Exit($DefinitionCache.SyncRoot)
            }
        }
        $Role = $DefinitionCache[$Key]
        $ScopeText = switch ($Kind)
        {
            'target resource group' { "resource group '{0}'" -f $ResourceGroup }
            'resource group' { 'a resource group' }
            'resource' { 'a single resource' }
            'other' { 'another scope' }
            default { $Kind }
        }
        $Through = if ([string]$Props.principalId -ne $CallerObjectId) { ' through a group' } else { '' }
        $Where = '{0}{1}' -f $ScopeText, $Through
        if ($null -eq $Role)
        {
            $Visible += ('a role that could not be read at {0}{1}' -f $ScopeText, $Through)
            if ((Get-RoleCheckCountedScopeKinds -Kind Resources) -contains $Kind) { $Unreadable += $Kind }
            continue
        }
        $RoleText = if ([string]$Role.type -eq 'CustomRole') { '{0} (custom role)' -f $Role.roleName } else { [string]$Role.roleName }
        $Label = '{0} at {1}' -f $RoleText, $Where
        $Visible += $Label
        foreach ($Block in @($Role.permissions))
        {
            $Grants += [pscustomobject]@{ Label = $Label; RoleName = [string]$Role.roleName; Where = $Where; Kind = $Kind; Actions = @($Block.actions); NotActions = @($Block.notActions) }
        }
    }
    $Result.VisibleRoles = @($Visible | Select-Object -Unique)

    foreach ($Check in @('Resources', 'Usage'))
    {
        $Kinds = Get-RoleCheckCountedScopeKinds -Kind $Check
        $By = @(Get-RoleGrantsAllowing -Grants @($Grants | Where-Object { $Kinds -contains $_.Kind }) -Action (Get-RoleCheckAction -Kind $Check))
        $Verdict = if ($By.Count -gt 0) { 'Yes' } elseif (@($Unreadable | Where-Object { $Kinds -contains $_ }).Count -gt 0) { 'Unknown' } else { 'No' }
        if ($Check -eq 'Resources')
        {
            $Result.Resources = $Verdict
            $Result.ResourcesGrantedBy = $By
            if ($Verdict -eq 'No')
            {
                $Result.ResourcesExcluded = @(Get-RoleReadExclusions -Grants @($Grants | Where-Object { $Kinds -contains $_.Kind }) |
                        ForEach-Object { "role '{0}' at {1} excludes '{2}'" -f $_.Grant.RoleName, $_.Grant.Where, $_.Pattern } | Select-Object -Unique)
            }
        }
        else { $Result.Usage = $Verdict; $Result.UsageGrantedBy = $By }
    }
    if ($Result.Resources -eq 'Unknown' -or $Result.Usage -eq 'Unknown') { $Result.Detail = 'a role definition could not be read' }
    return $Result
}

# Answer B: Azure's effective permissions for the caller at $ScopePath.
# Returns { Resources; Usage; ResourcesExcluded; Detail } with values 'Yes',
# 'No', 'NotFound' (a -ResourceGroup target that answered 404) or 'Unknown'.
# ResourcesExcluded, filled when Resources is 'No', lists the notActions that
# keep an entry from reading every resource type (Get-RoleReadExclusion).
function Get-CallerPermissionsAccess
{
    param(
        [Parameter(Mandatory = $true)][string]$ScopePath,
        [switch]$ResourceGroupTarget,
        [int]$MaxRetries = 3
    )
    $Answer = Invoke-RoleCheckGet -MaxRetries $MaxRetries -Path ($ScopePath + '/providers/Microsoft.Authorization/permissions?api-version=2022-04-01')
    if ($Answer.Status -eq 404 -and $ResourceGroupTarget)
    {
        return [pscustomobject]@{ Resources = 'NotFound'; Usage = 'NotFound'; ResourcesExcluded = @(); Detail = 'HTTP 404' }
    }
    if ($Answer.Status -in @(401, 403, 404))
    {
        return [pscustomobject]@{ Resources = 'No'; Usage = 'No'; ResourcesExcluded = @(); Detail = ('HTTP {0}' -f $Answer.Status) }
    }
    if ($null -ne $Answer.Error)
    {
        return [pscustomobject]@{ Resources = 'Unknown'; Usage = 'Unknown'; ResourcesExcluded = @(); Detail = ('caller permissions: {0}' -f $Answer.Error) }
    }
    $Entry = 0
    $Grants = @(@($Answer.Items) | ForEach-Object { $Entry++; [pscustomobject]@{ Label = ('entry {0}' -f $Entry); Actions = @($_.actions); NotActions = @($_.notActions) } })
    $Has = { param($Kind) if (@(Get-RoleGrantsAllowing -Grants $Grants -Action (Get-RoleCheckAction -Kind $Kind)).Count -gt 0) { 'Yes' } else { 'No' } }
    $Resources = & $Has 'Resources'
    $Excluded = if ($Resources -eq 'No') { @(Get-RoleReadExclusions -Grants $Grants | ForEach-Object { $_.Pattern } | Select-Object -Unique) } else { @() }
    return [pscustomobject]@{ Resources = $Resources; Usage = (& $Has 'Usage'); ResourcesExcluded = $Excluded; Detail = $null }
}

# Pure: combine answer A (role assignments) and answer B (caller permissions)
# into one verdict:
#   Yes                A and B both find the permission
#   YesPermissionsOnly A is not visible to this identity, B finds it
#   No                 neither finds it
#   NoNotVisible       A is not visible, B does not find it
#   NotFound           B says the target resource group does not exist
#   Disagree           A and B give opposite answers
#   Unknown            either answer stayed inconclusive
# Only Yes and YesPermissionsOnly let a run read resources.
function Resolve-RoleCheckVerdict
{
    param([string]$Assignments, [string]$Permissions)
    if ($Assignments -eq 'Unknown' -or $Permissions -eq 'Unknown') { return 'Unknown' }
    if ($Permissions -eq 'NotFound') { return 'NotFound' }
    if ($Assignments -eq 'Yes' -and $Permissions -eq 'Yes') { return 'Yes' }
    if ($Assignments -eq 'NotVisible' -and $Permissions -eq 'Yes') { return 'YesPermissionsOnly' }
    if ($Assignments -eq 'No' -and $Permissions -eq 'No') { return 'No' }
    if ($Assignments -eq 'NotVisible' -and $Permissions -eq 'No') { return 'NoNotVisible' }
    return 'Disagree'
}

# Pure: the text printed for a resource verdict.
function Format-RoleCheckReason
{
    param([string]$Verdict, $Assignments, $Permissions, [string]$ResourceGroup)
    $Target = if ([string]::IsNullOrEmpty($ResourceGroup)) { '' } else { " to resource group '{0}'" -f $ResourceGroup }
    $Visible = @($Assignments.VisibleRoles)
    $RolesExcluding = @($Assignments.ResourcesExcluded | Where-Object { -not [string]::IsNullOrEmpty([string]$_) })
    $AzureExcludes = @($Permissions.ResourcesExcluded | Where-Object { -not [string]::IsNullOrEmpty([string]$_) } | ForEach-Object { "'{0}'" -f $_ })
    $Miss = 'the inventory would miss those resources'
    switch ($Verdict)
    {
        'Yes' { return ('Read access: {0}' -f (@($Assignments.ResourcesGrantedBy) -join '; ')) }
        'YesPermissionsOnly' { return 'role assignments are not visible to this identity; Azure reports read access' }
        'No'
        {
            if ($RolesExcluding.Count -gt 0) { return ('{0}; {1}' -f ($RolesExcluding -join '; '), $Miss) }
            if ($AzureExcludes.Count -gt 0) { return ('Azure reports read access{0} that excludes {1}; {2}' -f $Target, ($AzureExcludes -join ', '), $Miss) }
            $Seen = if ($Visible.Count -gt 0) { $Visible -join '; ' } else { 'none' }
            return ('no role grants read access{0} (roles visible: {1})' -f $Target, $Seen)
        }
        'NoNotVisible'
        {
            if ($AzureExcludes.Count -gt 0) { return ('Azure reports read access{0} that excludes {1} (role assignments not visible to this identity); {2}' -f $Target, ($AzureExcludes -join ', '), $Miss) }
            return ('no read access{0} (role assignments not visible to this identity)' -f $Target)
        }
        'NotFound' { return ("resource group '{0}' not found or not readable" -f $ResourceGroup) }
        'Disagree'
        {
            $AText = switch ($Assignments.Resources)
            {
                'Yes' { 'read access ({0})' -f (@($Assignments.ResourcesGrantedBy) -join '; ') }
                'NotVisible' { 'not visible' }
                default
                {
                    if ($RolesExcluding.Count -gt 0) { 'no read access to every resource type ({0})' -f ($RolesExcluding -join '; ') }
                    else { 'no read access (roles visible: {0})' -f $(if ($Visible.Count -gt 0) { $Visible -join '; ' } else { 'none' }) }
                }
            }
            $BText = if ($Permissions.Resources -eq 'Yes') { 'read access' } elseif ($AzureExcludes.Count -gt 0) { 'read access that excludes {0}' -f ($AzureExcludes -join ', ') } else { 'no read access' }
            return ('role assignments show {0}, but Azure reports {1}{2}; if roles changed in the last few minutes, wait 5 minutes and re-run' -f $AText, $BText, $Target)
        }
        default
        {
            $Details = @(@($Assignments.Detail, $Permissions.Detail) | Where-Object { -not [string]::IsNullOrEmpty($_) })
            return ('role check inconclusive after retries ({0})' -f $(if ($Details.Count -gt 0) { $Details -join '; ' } else { 'no answer' }))
        }
    }
}

# Pure: the text printed for the usage verdict (information only).
function Format-UsageRoleText
{
    param([string]$Verdict, $Assignments, $Permissions)
    switch ($Verdict)
    {
        'Yes' { return ('yes - {0}' -f (@($Assignments.UsageGrantedBy) -join '; ')) }
        'YesPermissionsOnly' { return 'yes - Azure reports it (role assignments are not visible to this identity)' }
        'No' { return 'no - the roles on this subscription do not include it' }
        'NoNotVisible' { return 'no - Azure does not report it (role assignments are not visible to this identity)' }
        'Disagree'
        {
            return ('unclear - role assignments say {0}, Azure says {1}' -f $(if ($Assignments.Usage -eq 'Yes') { 'yes' } else { 'no' }), $(if ($Permissions.Usage -eq 'Yes') { 'yes' } else { 'no' }))
        }
        default { return 'unknown - the role check was inconclusive' }
    }
}

# Runs '& $Command -Item <item> @Arguments' for every item of $Items, at most
# $ThrottleLimit at a time (ForEach-Object -Parallel), and passes each result
# to $OnResult in the order of $Items, as soon as it and every earlier result
# are in, so the output reads the same as a one-after-another run. $Command
# must be a function of this file: runspaces do not inherit the caller's
# functions, so each one dot-sources this file once. $Arguments is shared by
# all runspaces, so it may only hold values that are safe to share between
# threads. An exception in one item becomes that item's result,
# { Failed = $true; Item; Message }, so no item is ever left without one. With
# $ThrottleLimit 1, or one item, it runs in the caller's runspace.
function Invoke-SubscriptionCheckInOrder
{
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Items,
        [Parameter(Mandatory = $true)][string]$Command,
        [hashtable]$Arguments = @{},
        [int]$ThrottleLimit = 8,
        [Parameter(Mandatory = $true)][scriptblock]$OnResult
    )
    if ($ThrottleLimit -le 1 -or $Items.Count -le 1)
    {
        foreach ($Item in $Items)
        {
            $Value = try { & $Command -Item $Item @Arguments }
            catch { [pscustomobject]@{ Failed = $true; Item = $Item; Message = $_.Exception.Message } }
            & $OnResult $Value
        }
        return
    }

    $FunctionsFile = $PSCommandPath
    $Indexed = for ($Index = 0; $Index -lt $Items.Count; $Index++) { [pscustomobject]@{ Index = $Index; Item = $Items[$Index] } }
    $Pending = @{}
    $NextIndex = 0
    $Indexed | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
        $Entry = $_
        $Name = $using:Command
        try
        {
            if (-not (Get-Command -Name $Name -CommandType Function -ErrorAction Ignore)) { . $using:FunctionsFile }
            $Splat = $using:Arguments
            $Value = & $Name -Item $Entry.Item @Splat
        }
        catch
        {
            $Value = [pscustomobject]@{ Failed = $true; Item = $Entry.Item; Message = $_.Exception.Message }
        }
        [pscustomobject]@{ Index = $Entry.Index; Value = $Value }
    } | ForEach-Object {
        $Pending[$_.Index] = $_.Value
        while ($Pending.ContainsKey($NextIndex))
        {
            & $OnResult $Pending[$NextIndex]
            $Pending.Remove($NextIndex)
            $NextIndex++
        }
    }
}

# The role check for one subscription ($Item: an object with Id and Name).
# Every Azure call names the subscription in its path, so nothing here reads
# or changes the Azure context and several subscriptions can be checked at the
# same time. Returns the record described at Test-SubscriptionRoleAccessAll.
function Get-SubscriptionRoleAccess
{
    param(
        [Parameter(Mandatory = $true)]$Item,
        [string]$ResourceGroup,
        [switch]$IncludeUsage,
        [string]$CallerObjectId,
        [hashtable]$DefinitionCache = @{},
        [int]$MaxRetries = 3
    )
    $ForResourceGroup = -not [string]::IsNullOrEmpty($ResourceGroup)
    $Id = [string]$Item.Id
    $Name = if ([string]::IsNullOrWhiteSpace([string]$Item.Name)) { $Id } else { [string]$Item.Name }
    $Timer = [System.Diagnostics.Stopwatch]::StartNew()
    $SubPath = '/subscriptions/{0}' -f $Id
    $Assignments = Get-RoleAssignmentAccess -SubscriptionId $Id -ResourceGroup $ResourceGroup -CallerObjectId $CallerObjectId -DefinitionCache $DefinitionCache -MaxRetries $MaxRetries
    $TargetPath = if ($ForResourceGroup) { '{0}/resourceGroups/{1}' -f $SubPath, $ResourceGroup } else { $SubPath }
    $Permissions = Get-CallerPermissionsAccess -ScopePath $TargetPath -ResourceGroupTarget:$ForResourceGroup -MaxRetries $MaxRetries
    $Verdict = Resolve-RoleCheckVerdict -Assignments $Assignments.Resources -Permissions $Permissions.Resources

    $UsageVerdict = $null
    $UsageText = $null
    if ($IncludeUsage)
    {
        $UsagePermissions = if ($ForResourceGroup) { Get-CallerPermissionsAccess -ScopePath $SubPath -MaxRetries $MaxRetries } else { $Permissions }
        $UsageVerdict = Resolve-RoleCheckVerdict -Assignments $Assignments.Usage -Permissions $UsagePermissions.Usage
        $UsageText = Format-UsageRoleText -Verdict $UsageVerdict -Assignments $Assignments -Permissions $UsagePermissions
    }
    $Timer.Stop()

    $State = switch ($Verdict)
    {
        'Yes' { 'Readable' }
        'YesPermissionsOnly' { 'Readable' }
        'Disagree' { 'Disagree' }
        'Unknown' { 'Unknown' }
        default { 'NoAccess' }
    }
    return [pscustomobject]@{
        Id           = $Id
        Name         = $Name
        State        = $State
        Verdict      = $Verdict
        Reason       = (Format-RoleCheckReason -Verdict $Verdict -Assignments $Assignments -Permissions $Permissions -ResourceGroup $ResourceGroup)
        UsageVerdict = $UsageVerdict
        UsageText    = $UsageText
        Assignments  = $Assignments
        Permissions  = $Permissions
        Seconds      = [math]::Round($Timer.Elapsed.TotalSeconds, 1)
    }
}

# Runs the role check for every subscription in $Subscriptions (objects with Id
# and Name), at most $ThrottleLimit subscriptions at a time, and prints one
# line per subscription in the order given. With -ResourceGroup the resource
# verdict is for that resource group in each subscription. With -IncludeUsage
# (consumption requested) the usage verdict is added. The caller's object id
# is read once, and each role definition once (a shared cache), for the whole
# run. Returns one record per subscription, in the order given:
#   { Id; Name; State; Verdict; Reason; UsageVerdict; UsageText; Assignments;
#     Permissions; Seconds }
# State is 'Readable' (the run may read it), 'NoAccess', 'Disagree' or
# 'Unknown'; Resolve-AccessPreflight treats anything but 'Readable' as not
# readable. A subscription whose check failed unexpectedly is 'Unknown'.
function Test-SubscriptionRoleAccessAll
{
    param(
        [Parameter(Mandatory = $true)]$Subscriptions,
        [string]$ResourceGroup,
        [switch]$IncludeUsage,
        [int]$MaxRetries = 3,
        [int]$ThrottleLimit = 8
    )
    $CallerObjectId = Get-RoleCheckCallerObjectId
    $Subs = @($Subscriptions | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_.Id) })
    $Arguments = @{
        ResourceGroup   = $ResourceGroup
        IncludeUsage    = [bool]$IncludeUsage
        CallerObjectId  = $CallerObjectId
        DefinitionCache = [hashtable]::Synchronized(@{})
        MaxRetries      = $MaxRetries
    }
    $RoleRecords = [System.Collections.Generic.List[object]]::new()
    Invoke-SubscriptionCheckInOrder -Items $Subs -Command 'Get-SubscriptionRoleAccess' -Arguments $Arguments -ThrottleLimit $ThrottleLimit -OnResult {
        param($RoleRecord)
        # Only a check that threw carries Failed (Invoke-SubscriptionCheckInOrder);
        # read it so Set-StrictMode allows a result without it.
        if ($null -ne $RoleRecord.PSObject.Properties['Failed'] -and $RoleRecord.Failed)
        {
            $FailedId = [string]$RoleRecord.Item.Id
            $RoleRecord = [pscustomobject]@{
                Id           = $FailedId
                Name         = $(if ([string]::IsNullOrWhiteSpace([string]$RoleRecord.Item.Name)) { $FailedId } else { [string]$RoleRecord.Item.Name })
                State        = 'Unknown'
                Verdict      = 'Unknown'
                Reason       = ('role check inconclusive ({0})' -f $RoleRecord.Message)
                UsageVerdict = $(if ($IncludeUsage) { 'Unknown' } else { $null })
                UsageText    = $(if ($IncludeUsage) { Format-UsageRoleText -Verdict 'Unknown' } else { $null })
                Assignments  = $null
                Permissions  = $null
                Seconds      = 0
            }
        }
        $RoleRecords.Add($RoleRecord)
        $Tag = if ($RoleRecord.State -eq 'Readable') { 'Pass' } else { $RoleRecord.State }
        Write-Host ('  [{0}] {1} - {2} ({3:N1}s)' -f $Tag, $RoleRecord.Name, $RoleRecord.Reason, $RoleRecord.Seconds) -ForegroundColor $(if ($RoleRecord.State -eq 'Readable') { 'Green' } else { 'Red' })
        if ($IncludeUsage)
        {
            Write-Host ('      usage permission (Microsoft.Commerce/UsageAggregates/read): {0}' -f $RoleRecord.UsageText) -ForegroundColor DarkGray
        }
    }
    return $RoleRecords.ToArray()
}

# Decide, from the up-front role check records, which subscriptions the run
# skips and whether it may proceed. Pure (no Azure calls) so the policy is
# unit-testable. A subscription is not readable unless its State is
# 'Readable', so a record that is not understood is skipped too.
# -CompletedCount is the number of in-scope subscriptions that a -Resume run
# skips because the resume state records them as completed (they are not
# checked again; an earlier run wrote their reports). Returns:
#   Inaccessible    - the records the identity cannot (or may not) read; the
#                     run skips them
#   InaccessibleIds - their ids, to drop from scope
#   ReadableCount   - how many checked subscriptions are readable
#   CompletedCount  - -CompletedCount as passed
#   ShouldBlock     - $true when subscriptions were checked, none is readable
#                     and none was completed earlier: the caller must STOP
#                     with exit code 1. With completed subscriptions in scope
#                     the run skips the unreadable ones and finishes.
function Resolve-AccessPreflight
{
    param([object]$Probed, [int]$CompletedCount = 0)
    $Checked = @(@($Probed) | Where-Object { $_ })
    $Inaccessible = @($Checked | Where-Object { $_.State -ne 'Readable' })
    return [pscustomobject]@{
        Inaccessible    = $Inaccessible
        InaccessibleIds = @($Inaccessible | ForEach-Object { $_.Id })
        ReadableCount   = $Checked.Count - $Inaccessible.Count
        CompletedCount  = $CompletedCount
        ShouldBlock     = ($Inaccessible.Count -gt 0 -and $Inaccessible.Count -eq $Checked.Count -and $CompletedCount -le 0)
    }
}

# Print the fix for each reason the up-front role check found subscriptions
# not readable ($Inaccessible records, by State): a missing role (NoAccess,
# including NotFound for a resource group run, and any state not listed
# here), a check that could not finish (Unknown), or the two answers
# disagreeing (Disagree). Each fix ends in $ReRun. With one cause the fix
# follows $Lead on its line; with several, $Lead is a line of its own and each
# cause gets a line naming its subscriptions. Returns the causes found, in the
# order printed. Shared by Write-AccessPreflightReport and
# Write-PendingRetrySkippedSummary so the fixes read the same.
function Write-AccessRemedyLines
{
    param(
        [object[]]$Inaccessible,
        [Parameter(Mandatory = $true)][string]$Lead,
        [string]$ReRun = 're-run',
        [string]$Colour = 'Yellow',
        [switch]$ForResourceGroup
    )
    $NoAccessText = if ($ForResourceGroup) { 'Check the resource group name, or grant the identity Reader on the resource group or its subscription, then {0}.' -f $ReRun } else { 'Grant the identity Reader on these subscriptions, then {0}.' -f $ReRun }
    $Remedies = [ordered]@{
        NoAccess = $NoAccessText
        Unknown  = 'The role check could not finish (the reason above says why); {0}.' -f $ReRun
        Disagree = 'The role assignments and Azure disagree, which usually means roles changed in the last few minutes; wait 5 minutes, then {0}.' -f $ReRun
    }
    $ByCause = [ordered]@{}
    foreach ($NA in @($Inaccessible | Where-Object { $null -ne $_ }))
    {
        $Cause = if ($Remedies.Contains([string]$NA.State)) { [string]$NA.State } else { 'NoAccess' }
        if (-not $ByCause.Contains($Cause)) { $ByCause[$Cause] = @() }
        $ByCause[$Cause] += [string]$NA.Name
    }
    $Causes = @($Remedies.Keys | Where-Object { $ByCause.Contains($_) })
    if ($Causes.Count -eq 1)
    {
        Write-Host ('{0} {1}' -f $Lead, $Remedies[$Causes[0]]) -ForegroundColor $Colour
    }
    else
    {
        Write-Host $Lead -ForegroundColor $Colour
        foreach ($Cause in $Causes)
        {
            Write-Host ('    {0}: {1}' -f ($ByCause[$Cause] -join ', '), $Remedies[$Cause]) -ForegroundColor $Colour
        }
    }
    return $Causes
}

# Print the result of the up-front role check. Shared by Run-AllSubscriptions.ps1
# and direct runs of ResourceInventory.ps1 so the wording is the same in both.
# Lists every subscription that is not readable with its reason and the fix
# for each cause; then says they are skipped, or, when none is readable
# ($Decision.ShouldBlock), that the run stops. Prints only: the caller skips
# them or exits with code 1. -ResourceGroup words the lines for that resource
# group. -Resume words a stop of a -Resume run: the fix ends in running
# -Resume again, and a last line says a run without -Resume checks the same
# subscriptions (a -Resume run stops only when no subscription is recorded as
# completed) and, when every cause is a missing role, that it stops too.
function Write-AccessPreflightReport
{
    param(
        [Parameter(Mandatory = $true)]$Decision,
        [Parameter(Mandatory = $true)][int]$ScopeCount,
        [string]$ResourceGroup,
        [switch]$Resume
    )
    $ForResourceGroup = -not [string]::IsNullOrEmpty($ResourceGroup)
    $Inaccessible = @($Decision.Inaccessible)
    if ($Inaccessible.Count -eq 0)
    {
        if ($ForResourceGroup)
        {
            Write-Host ("  Access verified: resource group '{0}' is readable in {1} subscription(s)." -f $ResourceGroup, $ScopeCount) -ForegroundColor Green
        }
        else
        {
            Write-Host ("  Access verified: all {0} in-scope subscription(s) are readable." -f $ScopeCount) -ForegroundColor Green
        }
        return
    }

    if ($ForResourceGroup)
    {
        Write-Host ("  Resource group '{0}' is NOT readable by the signed-in identity in {1} subscription(s):" -f $ResourceGroup, $Inaccessible.Count) -ForegroundColor Red
    }
    else
    {
        Write-Host ("  {0} subscription(s) are NOT readable by the signed-in identity:" -f $Inaccessible.Count) -ForegroundColor Red
    }
    foreach ($NA in $Inaccessible)
    {
        $Label = if (-not [string]::IsNullOrEmpty([string]$NA.Reason)) { [string]$NA.Reason } else { 'not readable' }
        Write-Host ("    - {0} ({1}) - {2}" -f $NA.Name, $NA.Id, $Label) -ForegroundColor Red
    }

    # The fix depends on why each subscription failed (Write-AccessRemedyLines).
    $Stopping = [bool]$Decision.ShouldBlock
    $ReRun = if ($Resume -and $Stopping) { 'run -Resume again' } else { 're-run' }
    if ($Stopping)
    {
        $Lead = '  No subscription is readable. Stopping before any work.'
        $Colour = 'Red'
    }
    elseif ($Decision.ReadableCount -eq 0 -and $Decision.CompletedCount -gt 0)
    {
        # -Resume with every subscription left to check unreadable: the
        # subscriptions an earlier run completed are skipped as done.
        $Lead = '  Skipping them and finishing the run: the other {0} subscription(s) were completed by an earlier run, so nothing is left to collect. To include them:' -f $Decision.CompletedCount
        $Colour = 'Yellow'
    }
    else
    {
        $Lead = '  Skipping them and continuing with the {0} readable subscription(s). To include them:' -f $Decision.ReadableCount
        $Colour = 'Yellow'
    }
    $Causes = @(Write-AccessRemedyLines -Inaccessible $Inaccessible -Lead $Lead -ReRun $ReRun -Colour $Colour -ForResourceGroup:$ForResourceGroup)
    if ($Resume -and $Stopping)
    {
        # With nothing recorded as completed a run without -Resume checks the
        # same subscriptions. Only a missing role is sure to stop it again: a
        # check that could not finish, or answers that disagree after a role
        # change, can pass on the next run.
        if ($Causes.Count -eq 1 -and $Causes[0] -eq 'NoAccess')
        {
            Write-Host '  A run without -Resume checks the same subscriptions, so it stops here too.' -ForegroundColor $Colour
        }
        else
        {
            Write-Host '  A run without -Resume checks the same subscriptions.' -ForegroundColor $Colour
        }
    }
}

# End-of-run list of the subscriptions the up-front role check skipped
# because the identity cannot read them, so a report without them is not
# taken for a complete one. Shared by Run-AllSubscriptions.ps1 and direct
# runs of ResourceInventory.ps1. Prints nothing when none was skipped.
function Write-SkippedSubscriptionSummary
{
    param($Decision)
    $Skipped = @(if ($null -ne $Decision) { @($Decision.Inaccessible) | Where-Object { $null -ne $_ } })
    if ($Skipped.Count -eq 0) { return }
    Write-Host ''
    Write-Host ('Subscriptions skipped (not readable by the signed-in identity): {0} - they are not in this report:' -f $Skipped.Count) -ForegroundColor Yellow
    foreach ($Sub in $Skipped)
    {
        $Label = if (-not [string]::IsNullOrEmpty([string]$Sub.Reason)) { [string]$Sub.Reason } else { 'not readable' }
        Write-Host ('  - {0} ({1}) - {2}' -f $Sub.Name, $Sub.Id, $Label) -ForegroundColor Yellow
    }
    Write-Host '  To include them, fix the access as the start of the run says, then re-run.' -ForegroundColor Yellow
}

# Under the end-of-run "Pending Retries" line: the subscriptions on the retry
# list that this run's role check skipped as not readable, each with its
# reason, and the fix for each cause (Write-AccessRemedyLines).
# -ResumeFailedOnly runs the same check before it retries, so it skips them
# until the cause is fixed. Prints nothing when none of them was skipped.
function Write-PendingRetrySkippedSummary
{
    param($FailedAttempts, $Decision)
    $RetryIds = @(@($FailedAttempts) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_.Id })
    $Skipped = @(if ($null -ne $Decision) { @($Decision.Inaccessible) | Where-Object { $null -ne $_ -and $RetryIds -contains [string]$_.Id } })
    if ($Skipped.Count -eq 0) { return }
    Write-Host ('  {0} of them were skipped by this run''s role check:' -f $Skipped.Count) -ForegroundColor Yellow
    foreach ($Sub in $Skipped)
    {
        $Label = if (-not [string]::IsNullOrEmpty([string]$Sub.Reason)) { [string]$Sub.Reason } else { 'not readable' }
        Write-Host ('    - {0} ({1}) - {2}' -f $Sub.Name, $Sub.Id, $Label) -ForegroundColor Yellow
    }
    $null = Write-AccessRemedyLines -Inaccessible $Skipped -Lead '  To retry them:' -ReRun 'run -ResumeFailedOnly' -Colour Yellow
}

# After a consumption data check refusal, say per failing subscription what the
# role check found about the usage permission, with the fix when the roles do
# not include it. Prints nothing when the check passed or when no role check
# records are available.
function Write-UsageRoleReport
{
    param($ConsumptionResult, [object[]]$RoleCheck)
    $Records = @(@($RoleCheck) | Where-Object { $null -ne $_ -and -not [string]::IsNullOrEmpty([string]$_.UsageVerdict) })
    if ($null -eq $ConsumptionResult -or -not $ConsumptionResult.ShouldBlock -or $Records.Count -eq 0) { return }
    Write-Host 'Usage permission found by the role check:' -ForegroundColor Yellow
    foreach ($Fail in @($ConsumptionResult.Failed))
    {
        $Record = @($Records | Where-Object { [string]$_.Id -eq [string]$Fail.Id })[0]
        if ($null -eq $Record) { continue }
        $Advice = switch ($Record.UsageVerdict)
        {
            'Yes' { 'the roles include Microsoft.Commerce/UsageAggregates/read, so the missing values are not a role problem (see 2. above)' }
            'YesPermissionsOnly' { 'Azure reports Microsoft.Commerce/UsageAggregates/read for this identity, so the missing values are not a role problem (see 2. above)' }
            'No' { 'the roles on this subscription do not include Microsoft.Commerce/UsageAggregates/read: add Reader or Billing Reader at the subscription' }
            'NoNotVisible' { 'Azure does not report Microsoft.Commerce/UsageAggregates/read for this identity: add Reader or Billing Reader at the subscription' }
            default { 'the usage permission could not be confirmed ({0})' -f $Record.UsageText }
        }
        Write-Host ('  - {0}: {1}' -f $Record.Name, $Advice) -ForegroundColor Yellow
    }
}

# Pure: split the subscriptions that returned 0 resources by this run's role
# check. Those it found readable are genuinely empty; any it did not cover are
# undetermined.
function Split-EmptySubscriptionsByRoleCheck
{
    param([object[]]$EmptySubscriptions, [object[]]$RoleCheck)
    $ReadableIds = @(@($RoleCheck) | Where-Object { $null -ne $_ -and $_.State -eq 'Readable' } | ForEach-Object { [string]$_.Id })
    $All = @(@($EmptySubscriptions) | Where-Object { $null -ne $_ })
    return [pscustomobject]@{
        Empty        = @($All | Where-Object { $ReadableIds -contains [string]$_.Id })
        Undetermined = @($All | Where-Object { $ReadableIds -notcontains [string]$_.Id })
    }
}

# ---- Consumption data check -------------------------------------------------
# Consumption (usage) rows are what price a business case: they show whether a
# machine ran 4 hours or 400. A run without them is not useful, so when
# consumption is requested (no -SkipConsumption) both entry points refuse to
# start unless every in-scope subscription returns at least one usage row with
# a quantity above zero for the same window the billing phase collects.
#
# Get-UsageAggregates returns NO error and zero rows when the identity lacks
# Microsoft.Commerce/UsageAggregates/read, so "no error" and "some rows" are
# not proof of access; only a positive quantity is.

# The window the billing phase queries: midnight 31 days ago to midnight
# yesterday, by the date of $Now, which is the UTC clock by default so every
# host gets the same days for the same moment (usage days are UTC days). Both
# have Kind=Unspecified. Unspecified is what the phase's earlier '.DateTime'
# strings converted to, and it serialises without a
# UTC offset, which the Daily-granularity API accepts on any host time zone
# (a Kind=Local midnight carries the host offset and is rejected outside UTC).
# Returning DateTime values instead of culture-formatted strings keeps the
# conversion independent of the host culture.
function Get-ConsumptionWindow
{
    param([datetime]$Now = [datetime]::UtcNow)
    return [pscustomobject]@{
        Start = [datetime]::SpecifyKind($Now.AddDays(-31).Date, [System.DateTimeKind]::Unspecified)
        End   = [datetime]::SpecifyKind($Now.AddDays(-1).Date, [System.DateTimeKind]::Unspecified)
    }
}

function Format-ConsumptionWindow
{
    param([Parameter(Mandatory = $true)]$Window)
    $Invariant = [System.Globalization.CultureInfo]::InvariantCulture
    return ('{0} to {1}' -f $Window.Start.ToString('yyyy-MM-dd', $Invariant), $Window.End.ToString('yyyy-MM-dd', $Invariant))
}

# The window as the two 'yyyy-MM-dd' strings Run-AllSubscriptions.ps1 passes to
# each ResourceInventory.ps1 it runs (-ConsumptionWindowStart and
# -ConsumptionWindowEnd), so the check and every collection use one window
# even when a subscription is collected after midnight. Plain invariant
# strings survive a background job's serialisation and do not depend on the
# host culture.
function ConvertTo-ConsumptionWindowArgument
{
    param([Parameter(Mandatory = $true)]$Window)
    $Invariant = [System.Globalization.CultureInfo]::InvariantCulture
    return @{
        ConsumptionWindowStart = $Window.Start.ToString('yyyy-MM-dd', $Invariant)
        ConsumptionWindowEnd   = $Window.End.ToString('yyyy-MM-dd', $Invariant)
    }
}

# Pure: the window from those two strings, as Get-ConsumptionWindow returns it
# (midnights, Kind=Unspecified), or $null when either is missing, is not a
# 'yyyy-MM-dd' date, or the start is after the end.
function ConvertFrom-ConsumptionWindowArgument
{
    param([string]$Start, [string]$End)
    $Invariant = [System.Globalization.CultureInfo]::InvariantCulture
    $Dates = @()
    foreach ($Text in @($Start, $End))
    {
        $Value = [datetime]::MinValue
        if ([string]::IsNullOrWhiteSpace($Text) -or -not [datetime]::TryParseExact($Text, 'yyyy-MM-dd', $Invariant, [System.Globalization.DateTimeStyles]::None, [ref]$Value)) { return $null }
        $Dates += [datetime]::SpecifyKind($Value, [System.DateTimeKind]::Unspecified)
    }
    if ($Dates[0] -gt $Dates[1]) { return $null }
    return [pscustomobject]@{ Start = $Dates[0]; End = $Dates[1] }
}

# Pure: $true when at least one row carries a Quantity that is a number > 0.
# Strings are parsed with the invariant culture; anything non-numeric is ignored.
function Test-ConsumptionRowsHavePositiveQuantity
{
    param([object[]]$Rows)
    $NumericTypes = @([decimal], [double], [single], [int16], [int32], [int64], [uint16], [uint32], [uint64], [byte], [sbyte])
    foreach ($Row in @($Rows))
    {
        if ($null -eq $Row) { continue }
        $Quantity = $Row.Quantity
        if ($null -eq $Quantity) { continue }
        $Value = [double]0
        if ($Quantity -is [string])
        {
            if (-not [double]::TryParse($Quantity, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$Value)) { continue }
        }
        elseif ($NumericTypes -contains $Quantity.GetType())
        {
            $Value = [double]$Quantity
        }
        else
        {
            continue
        }
        if ($Value -gt 0) { return $true }
    }
    return $false
}

# Pure: the HTTP status carried by an exception or any inner exception
# (Hyak/Rest exceptions expose .Response.StatusCode, HttpRequestException
# exposes .StatusCode). Returns an [int] or $null when none is present.
function Get-ConsumptionErrorStatusCode
{
    param([object]$Exception)
    $Current = $Exception
    $Depth = 0
    while ($null -ne $Current -and $Depth -lt 6)
    {
        foreach ($Candidate in @($Current.Response.StatusCode, $Current.StatusCode))
        {
            if ($null -eq $Candidate) { continue }
            try
            {
                if ($Candidate -is [string]) { return [int][System.Net.HttpStatusCode]$Candidate }
                return [int]$Candidate
            }
            catch
            {
                Write-Verbose ('Unrecognised status code value: {0}' -f $Candidate)
            }
        }
        $Current = $Current.InnerException
        $Depth++
    }
    return $null
}

# Pure: 'Transient' for throttling, timeouts and server-side errors (worth a
# bounded retry); 'Permanent' for everything else, including 400 (malformed
# request) and 401/403 (no permission), which a retry cannot change.
function Get-ConsumptionErrorKind
{
    param([object]$Exception)
    $Status = Get-ConsumptionErrorStatusCode -Exception $Exception
    if ($null -ne $Status)
    {
        if ($Status -eq 408 -or $Status -eq 429 -or $Status -ge 500) { return 'Transient' }
        return 'Permanent'
    }
    $Message = [string]$Exception.Message
    if ($Message -match '(?i)timed? ?out|timeout|throttl|too many requests|\b429\b|\b50[0-4]\b|temporar|service unavailable|task was cancel|connection (was )?(reset|closed|refused)|name could not be resolved|name or service not known')
    {
        return 'Transient'
    }
    return 'Permanent'
}

# Runs $Operation (a scriptblock taking one argument) and retries it with
# exponential backoff (2, 4, 8 s) while the failure is transient. Returns
# { Value; Error; Attempts }; Error is the last exception, or $null on success.
function Invoke-ConsumptionCallWithRetry
{
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Operation,
        $Argument,
        [int]$MaxRetries = 3
    )
    $Attempt = 0
    while ($true)
    {
        $Attempt++
        try
        {
            $Value = & $Operation $Argument
            return [pscustomobject]@{ Value = $Value; Error = $null; Attempts = $Attempt }
        }
        catch
        {
            $LastError = $_.Exception
            if ($Attempt -gt $MaxRetries -or (Get-ConsumptionErrorKind -Exception $LastError) -ne 'Transient')
            {
                return [pscustomobject]@{ Value = $null; Error = $LastError; Attempts = $Attempt }
            }
            Start-Sleep -Seconds ([int][math]::Pow(2, $Attempt))
        }
    }
}

# Resource counts per subscription from Resource Graph, used to exempt
# subscriptions that hold no resources (nothing to price). With
# -ResourceGroup only that resource group's resources are counted, matched the
# way the inventory's own query matches it (lower-cased name, '=='). Resource
# Graph returns no row for a subscription with zero resources, so every id in
# a batch that answered successfully gets a count (0 when absent). Ids in a
# batch that failed after retries are left out, so the caller checks their
# consumption instead of exempting them; so is every id when -ResourceGroup is
# not a valid resource group name.
function Get-SubscriptionResourceCounts
{
    param(
        [Parameter(Mandatory = $true)][string[]]$SubscriptionIds,
        [string]$ResourceGroup,
        [int]$BatchSize = 1000
    )
    $Counts = @{}
    $Query = 'resources | summarize ResourceCount = count() by subscriptionId'
    if (-not [string]::IsNullOrEmpty($ResourceGroup))
    {
        # Same pattern ResourceInventory.ps1 validates -ResourceGroup with; it
        # also keeps the name safe inside the query's quotes.
        if ($ResourceGroup -notmatch '^[A-Za-z0-9._()-]{1,90}$')
        {
            Write-Verbose 'Resource count query skipped: the resource group name is not valid.'
            return $Counts
        }
        $Query = "resources | where resourceGroup == '{0}' | summarize ResourceCount = count() by subscriptionId" -f $ResourceGroup.ToLowerInvariant()
    }
    $Ids = @($SubscriptionIds | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    for ($Offset = 0; $Offset -lt $Ids.Count; $Offset += $BatchSize)
    {
        $Batch = @($Ids[$Offset..([math]::Min($Offset + $BatchSize, $Ids.Count) - 1)])
        $Payload = @{
            subscriptions = $Batch
            query         = $Query
            options       = @{ resultFormat = 'objectArray'; '$top' = 1000 }
        } | ConvertTo-Json -Depth 4 -Compress
        $Call = Invoke-ConsumptionCallWithRetry -Argument $Payload -Operation {
            param($Body)
            $Response = Invoke-AzRestMethod -Method POST -Path '/providers/Microsoft.ResourceGraph/resources?api-version=2021-03-01' -Payload $Body -ErrorAction Stop
            $Status = [int]$Response.StatusCode
            if ($Status -lt 200 -or $Status -ge 300)
            {
                throw [System.Net.Http.HttpRequestException]::new(('Resource Graph returned HTTP {0}' -f $Status), $null, [System.Net.HttpStatusCode]$Status)
            }
            $Response.Content | ConvertFrom-Json
        }
        if ($null -ne $Call.Error)
        {
            Write-Verbose ('Resource count query failed for {0} subscription(s): {1}' -f $Batch.Count, $Call.Error.Message)
            continue
        }
        foreach ($Id in $Batch) { $Counts[$Id] = 0 }
        foreach ($Row in @($Call.Value.data))
        {
            if ($null -eq $Row -or [string]::IsNullOrEmpty([string]$Row.subscriptionId)) { continue }
            $Counts[[string]$Row.subscriptionId] = [int]$Row.ResourceCount
        }
    }
    return $Counts
}

# Pure: does a usage row's resource URI belong to resource group
# $ResourceGroup? The URI must start with
# '/subscriptions/<id>/resourceGroups/<name>' and <name> must equal
# $ResourceGroup, compared without case. A resource or provider name equal to
# the resource group's name elsewhere in the URI does not count. The
# consumption phase (GetResorceConsumption in ResourceInventory.ps1) keeps a
# row for a -ResourceGroup run by this same test, and the consumption data
# check counts a row by it, so the check and the sheet agree.
function Test-ConsumptionResourceUriInResourceGroup
{
    param([string]$ResourceUri, [string]$ResourceGroup)
    if ([string]::IsNullOrEmpty($ResourceUri) -or [string]::IsNullOrEmpty($ResourceGroup)) { return $false }
    if ($ResourceUri -match '^/subscriptions/[^/]+/resourceGroups/([^/]+)(/|$)') { return $Matches[1] -ieq $ResourceGroup }
    return $false
}

# Pure: the resource URI ('Microsoft.Resources'.resourceUri) in a usage row's
# InstanceData JSON, or $null when the InstanceData is missing, is not valid
# JSON or has no URI.
function Get-ConsumptionRowResourceUri
{
    param($InstanceData)
    if ([string]::IsNullOrWhiteSpace([string]$InstanceData)) { return $null }
    try { $Info = [string]$InstanceData | ConvertFrom-Json -ErrorAction Stop }
    catch { return $null }
    $Uri = $Info.'Microsoft.Resources'.resourceUri
    if ($Uri -isnot [string]) { return $null }
    return $Uri
}

# One page of one subscription's usage from the API that Get-UsageAggregates
# wraps (GET /subscriptions/<id>/providers/Microsoft.Commerce/UsageAggregates,
# api-version 2015-06-01-preview), with the cmdlet's parameters. The
# subscription is named in the request path, so no Azure context is switched
# and several subscriptions can be read at the same time: the cmdlet reads the
# subscription of the current context, and Az has no supported way to make a
# context for another subscription without selecting it for the whole
# process. The window's midnights (Kind=Unspecified) are sent as UTC midnights,
# which is how the API reads the cmdlet's. Returns the page shaped like the
# cmdlet's answer: { UsageAggregations (each with Properties);
# ContinuationToken }, the token read from the answer's nextLink. Throws on an
# answer outside 2xx (an HttpRequestException carrying the HTTP status, so the
# retry policy and the Denied verdict treat it as they treat the cmdlet's
# errors), on an answer that is not JSON, and on a nextLink that has no
# continuationToken.
function Get-UsageAggregatesPage
{
    param(
        [Parameter(Mandatory = $true)][string]$SubscriptionId,
        [Parameter(Mandatory = $true)][datetime]$ReportedStartTime,
        [Parameter(Mandatory = $true)][datetime]$ReportedEndTime,
        [string]$AggregationGranularity = 'Daily',
        [switch]$ShowDetails,
        [string]$ContinuationToken
    )
    $Invariant = [System.Globalization.CultureInfo]::InvariantCulture
    $Start = [uri]::EscapeDataString($ReportedStartTime.ToString("yyyy-MM-dd'T'HH:mm:ss", $Invariant) + 'Z')
    $End = [uri]::EscapeDataString($ReportedEndTime.ToString("yyyy-MM-dd'T'HH:mm:ss", $Invariant) + 'Z')
    $Path = '/subscriptions/{0}/providers/Microsoft.Commerce/UsageAggregates?api-version=2015-06-01-preview&reportedStartTime={1}&reportedEndTime={2}&aggregationGranularity={3}&showDetails={4}' -f $SubscriptionId, $Start, $End, $AggregationGranularity, $(if ($ShowDetails) { 'true' } else { 'false' })
    if (-not [string]::IsNullOrEmpty($ContinuationToken)) { $Path += '&continuationToken=' + [uri]::EscapeDataString($ContinuationToken) }

    $Response = Invoke-AzRestMethod -Method GET -Path $Path -ErrorAction Stop
    $Status = [int]$Response.StatusCode
    if ($Status -lt 200 -or $Status -ge 300)
    {
        $Reason = 'the usage API answered HTTP {0}' -f $Status
        try
        {
            $AzureError = ([string]$Response.Content | ConvertFrom-Json -ErrorAction Stop).error
            if ($null -ne $AzureError -and -not [string]::IsNullOrEmpty([string]$AzureError.message)) { $Reason = '{0}: {1}' -f $AzureError.code, $AzureError.message }
        }
        catch
        {
            Write-Verbose 'The usage API error answer was not JSON.'
        }
        throw [System.Net.Http.HttpRequestException]::new($Reason, $null, [System.Net.HttpStatusCode]$Status)
    }
    $Body = [string]$Response.Content | ConvertFrom-Json -ErrorAction Stop

    # The next page is asked for with the token alone, as the cmdlet does, so
    # the request never goes to a host named in the answer.
    $Token = $null
    # A last page has no nextLink (and an empty one may have no value); read
    # both so Set-StrictMode allows that.
    $NextLink = if ($null -ne $Body -and $null -ne $Body.PSObject.Properties['nextLink']) { [string]$Body.nextLink } else { '' }
    if (-not [string]::IsNullOrEmpty($NextLink))
    {
        $NextUri = $null
        if ([uri]::TryCreate($NextLink, [System.UriKind]::Absolute, [ref]$NextUri)) { $Token = [System.Web.HttpUtility]::ParseQueryString($NextUri.Query)['continuationToken'] }
        if ([string]::IsNullOrEmpty($Token)) { throw 'The usage answer''s nextLink has no continuationToken, so the next page cannot be read.' }
    }
    return [pscustomobject]@{
        UsageAggregations = @(@(if ($null -ne $Body -and $null -ne $Body.PSObject.Properties['value']) { $Body.value }) | Where-Object { $null -ne $_ } | ForEach-Object { [pscustomobject]@{ Properties = $_.properties } })
        ContinuationToken = $Token
    }
}

# Queries one subscription's usage with the billing phase's window and options
# (Get-UsageAggregatesPage: the API the billing phase's cmdlet wraps),
# following ContinuationToken until a row with a positive quantity is found,
# the pages run out, or $MaxPages pages have been read (PageCapReached: more
# pages were offered but not read). With -ResourceGroup only rows whose
# resource URI belongs to that resource group count
# (Test-ConsumptionResourceUriInResourceGroup), as in the consumption phase;
# RowsSeen counts only those. The Azure context is neither read nor changed.
# Returns { PositiveFound; RowsSeen; PagesRead; PageCapReached; Attempts; Error }.
function Invoke-ConsumptionValueProbe
{
    param(
        [Parameter(Mandatory = $true)][string]$SubscriptionId,
        [Parameter(Mandatory = $true)]$Window,
        [string]$ResourceGroup,
        [int]$MaxRetries = 3,
        [int]$MaxPages = 50
    )
    $Probe = [pscustomobject]@{ PositiveFound = $false; RowsSeen = 0; PagesRead = 0; PageCapReached = $false; Attempts = 0; Error = $null }

    $Token = $null
    do
    {
        $Params = @{
            SubscriptionId         = $SubscriptionId
            ReportedStartTime      = $Window.Start
            ReportedEndTime        = $Window.End
            AggregationGranularity = 'Daily'
            ShowDetails            = $true
        }
        if (-not [string]::IsNullOrEmpty($Token)) { $Params.ContinuationToken = $Token }

        $Page = Invoke-ConsumptionCallWithRetry -MaxRetries $MaxRetries -Argument $Params -Operation {
            param($QueryParams)
            Get-UsageAggregatesPage @QueryParams -ErrorAction Stop
        }
        $Probe.Attempts += $Page.Attempts
        if ($null -ne $Page.Error)
        {
            $Probe.Error = $Page.Error
            return $Probe
        }

        $Probe.PagesRead++
        $Rows = @(@($Page.Value.UsageAggregations) | Where-Object { $null -ne $_ } | ForEach-Object { $_.Properties } | Where-Object { $null -ne $_ })
        if (-not [string]::IsNullOrEmpty($ResourceGroup))
        {
            $Rows = @($Rows | Where-Object { Test-ConsumptionResourceUriInResourceGroup -ResourceUri (Get-ConsumptionRowResourceUri -InstanceData $_.InstanceData) -ResourceGroup $ResourceGroup })
        }
        $Probe.RowsSeen += $Rows.Count
        if (Test-ConsumptionRowsHavePositiveQuantity -Rows $Rows)
        {
            $Probe.PositiveFound = $true
            return $Probe
        }
        $Token = [string]$Page.Value.ContinuationToken
        if (-not [string]::IsNullOrEmpty($Token) -and $Probe.PagesRead -ge $MaxPages)
        {
            $Probe.PageCapReached = $true
            return $Probe
        }
    } while (-not [string]::IsNullOrEmpty($Token))

    return $Probe
}

# Pure verdict for one subscription. Passed is $true for 'Pass' (a positive
# quantity came back), 'Exempt' (Resource Graph reports zero resources, so it
# was not queried) and 'NoUsage' (below). Every other outcome refuses the run:
#   'NoRows'             - the query succeeded but returned no rows
#   'NoPositiveQuantity' - rows came back but none had a quantity above zero,
#                          or the page cap was reached before one did
#   'Denied'             - the query was refused for lack of permission
#   'Error'              - any other failure that persisted after retries
# 'NoUsage' replaces NoRows and NoPositiveQuantity when $UsageRole (this
# subscription's record from Test-SubscriptionRoleAccessAll) has UsageVerdict
# 'Yes': its role assignments AND Azure's caller permissions both grant
# Microsoft.Commerce/UsageAggregates/read at the subscription or above. The
# empty answer then reflects no billed usage in the window (a new
# subscription, only free resources, paused resources) rather than a missing
# permission. Any other usage verdict, or no record, keeps the refusal.
# With -ResourceGroup the counts and rows are that resource group's, and the
# text says so.
function Get-ConsumptionCheckVerdict
{
    param(
        $Probe,
        $ResourceCount,
        $UsageRole,
        [string]$ResourceGroup
    )
    $ForRg = if ([string]::IsNullOrEmpty($ResourceGroup)) { '' } else { " for resource group '{0}'" -f $ResourceGroup }
    $InRg = if ([string]::IsNullOrEmpty($ResourceGroup)) { '' } else { " in resource group '{0}'" -f $ResourceGroup }
    if ($null -ne $ResourceCount -and [int]$ResourceCount -eq 0)
    {
        return [pscustomobject]@{ Outcome = 'Exempt'; Passed = $true; Detail = ('no resources{0} in Resource Graph; not checked (nothing to price)' -f $InRg) }
    }
    if ($null -eq $Probe)
    {
        return [pscustomobject]@{ Outcome = 'Error'; Passed = $false; Detail = 'consumption was not queried' }
    }
    if ($Probe.PositiveFound)
    {
        return [pscustomobject]@{ Outcome = 'Pass'; Passed = $true; Detail = ('usage values found{0} ({1} row(s) read over {2} page(s))' -f $ForRg, $Probe.RowsSeen, $Probe.PagesRead) }
    }
    if ($null -ne $Probe.Error)
    {
        $Status = Get-ConsumptionErrorStatusCode -Exception $Probe.Error
        $Message = [string]$Probe.Error.Message
        $IsDenied = ($Status -eq 401 -or $Status -eq 403 -or $Message -match '(?i)authoriz|forbidden|\b403\b|does not have|not authorized|insufficient privileg|access is denied')
        $Outcome = if ($IsDenied) { 'Denied' } else { 'Error' }
        $StatusText = if ($null -ne $Status) { ('HTTP {0}, ' -f $Status) } else { '' }
        return [pscustomobject]@{ Outcome = $Outcome; Passed = $false; Detail = ('query failed ({0}{1} attempt(s)): {2}' -f $StatusText, $Probe.Attempts, $Message) }
    }
    $Empty = if ($Probe.PageCapReached)
    {
        [pscustomobject]@{ Outcome = 'NoPositiveQuantity'; Passed = $false; Detail = ('{0} usage row(s){1} came back, none with a quantity above zero; only the first {2} page(s) were read' -f $Probe.RowsSeen, $ForRg, $Probe.PagesRead) }
    }
    elseif ([int]$Probe.RowsSeen -eq 0)
    {
        [pscustomobject]@{ Outcome = 'NoRows'; Passed = $false; Detail = ('the query succeeded but returned no usage rows{0}' -f $ForRg) }
    }
    else
    {
        [pscustomobject]@{ Outcome = 'NoPositiveQuantity'; Passed = $false; Detail = ('{0} usage row(s){1} came back, none with a quantity above zero' -f $Probe.RowsSeen, $ForRg) }
    }
    if ($null -ne $UsageRole -and [string]$UsageRole.UsageVerdict -eq 'Yes')
    {
        $GrantedBy = @(@($UsageRole.Assignments.UsageGrantedBy) | Where-Object { -not [string]::IsNullOrEmpty([string]$_) })
        $GrantedText = if ($GrantedBy.Count -gt 0) { $GrantedBy -join '; ' } else { 'role not named' }
        return [pscustomobject]@{ Outcome = 'NoUsage'; Passed = $true; Detail = ('{0}; the usage permission is confirmed by the role assignments and by Azure ({1})' -f $Empty.Detail, $GrantedText) }
    }
    return $Empty
}

# Pure: combine per-subscription results into the run decision.
function Resolve-ConsumptionDataCheck
{
    param(
        [object[]]$Results,
        $Window,
        [string]$ResourceGroup
    )
    $All = @(@($Results) | Where-Object { $null -ne $_ })
    $Failed = @($All | Where-Object { -not $_.Passed })
    return [pscustomobject]@{
        Window        = $Window
        ResourceGroup = $ResourceGroup
        Results       = $All
        Failed        = $Failed
        Exempt        = @($All | Where-Object { $_.Outcome -eq 'Exempt' })
        NoUsage       = @($All | Where-Object { $_.Outcome -eq 'NoUsage' })
        ShouldBlock   = ($Failed.Count -gt 0)
    }
}

# Pure: ' for resource group '<name>'' for a resource group check, else ''.
function Format-ConsumptionCheckTarget
{
    param([string]$ResourceGroup)
    if ([string]::IsNullOrEmpty($ResourceGroup)) { return '' }
    return (" for resource group '{0}'" -f $ResourceGroup)
}

# The consumption data check for one subscription. $Item carries Id, Name,
# ResourceCount (from Resource Graph, $null when unknown) and UsageRole (this
# subscription's role check record, or $null). A subscription with zero
# resources is not queried. Returns the per-subscription result described at
# Invoke-ConsumptionDataCheck. The Azure context is neither read nor changed,
# so several subscriptions can be checked at the same time.
function Get-SubscriptionConsumptionCheck
{
    param(
        [Parameter(Mandatory = $true)]$Item,
        [Parameter(Mandatory = $true)]$Window,
        [string]$ResourceGroup,
        [int]$MaxRetries = 3
    )
    $Timer = [System.Diagnostics.Stopwatch]::StartNew()
    $Probe = $null
    if ($null -eq $Item.ResourceCount -or [int]$Item.ResourceCount -gt 0)
    {
        $Probe = Invoke-ConsumptionValueProbe -SubscriptionId ([string]$Item.Id) -Window $Window -ResourceGroup $ResourceGroup -MaxRetries $MaxRetries
    }
    $Timer.Stop()
    $Verdict = Get-ConsumptionCheckVerdict -Probe $Probe -ResourceCount $Item.ResourceCount -UsageRole $Item.UsageRole -ResourceGroup $ResourceGroup
    return [pscustomobject]@{
        Id             = [string]$Item.Id
        Name           = [string]$Item.Name
        ResourceCount  = $Item.ResourceCount
        Outcome        = $Verdict.Outcome
        Passed         = $Verdict.Passed
        Detail         = $Verdict.Detail
        PageCapReached = ($null -ne $Probe -and [bool]$Probe.PageCapReached)
        PagesRead      = $(if ($null -ne $Probe) { [int]$Probe.PagesRead } else { 0 })
        Seconds        = [math]::Round($Timer.Elapsed.TotalSeconds, 1)
    }
}

# Checks every subscription in $Subscriptions (objects with Id and Name), at
# most $ThrottleLimit subscriptions at a time, prints one line per
# subscription in the order given, and returns the Resolve-ConsumptionDataCheck
# decision. Every subscription is checked, so a refusal lists all failing ones
# at once. Resource counts come from one Resource Graph query per 1,000
# subscriptions. $RoleCheck is the record list from
# Test-SubscriptionRoleAccessAll for this run; a subscription's record
# decides whether an empty answer is 'NoUsage' (Get-ConsumptionCheckVerdict).
# $Window is the run's window: the caller computes it once and the
# consumption phase collects the same one. -ResourceGroup (a direct
# -ResourceGroup run) checks only that resource group's usage rows and
# resources, the rows the consumption phase keeps for such a run. A
# subscription whose check failed unexpectedly is an 'Error' (it stops the
# run). The Azure context is neither read nor changed.
function Invoke-ConsumptionDataCheck
{
    param(
        [Parameter(Mandatory = $true)][object[]]$Subscriptions,
        $Window = (Get-ConsumptionWindow),
        [object[]]$RoleCheck = @(),
        [string]$ResourceGroup,
        [int]$MaxRetries = 3,
        [int]$ThrottleLimit = 8
    )
    $Subs = @($Subscriptions | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_.Id) })
    $WindowText = Format-ConsumptionWindow -Window $Window
    $ForRg = Format-ConsumptionCheckTarget -ResourceGroup $ResourceGroup
    if ([string]::IsNullOrEmpty($ResourceGroup))
    {
        Write-Host ('Verifying consumption data (usage values for {0}) for {1} subscription(s)...' -f $WindowText, $Subs.Count) -ForegroundColor Cyan
    }
    else
    {
        Write-Host ("Verifying consumption data (usage values for {0}) for resource group '{1}' in {2} subscription(s)..." -f $WindowText, $ResourceGroup, $Subs.Count) -ForegroundColor Cyan
    }

    $Counts = Get-SubscriptionResourceCounts -SubscriptionIds @($Subs | ForEach-Object { [string]$_.Id }) -ResourceGroup $ResourceGroup
    # The first role check record per subscription id.
    $RoleById = @{}
    foreach ($Record in @($RoleCheck))
    {
        if ($null -ne $Record -and -not $RoleById.ContainsKey([string]$Record.Id)) { $RoleById[[string]$Record.Id] = $Record }
    }
    $Items = @(foreach ($Sub in $Subs)
        {
            $Id = [string]$Sub.Id
            [pscustomobject]@{
                Id            = $Id
                Name          = $(if ([string]::IsNullOrWhiteSpace([string]$Sub.Name)) { $Id } else { [string]$Sub.Name })
                ResourceCount = $(if ($Counts.ContainsKey($Id)) { [int]$Counts[$Id] } else { $null })
                UsageRole     = $RoleById[$Id]
            }
        })

    $CheckResults = [System.Collections.Generic.List[object]]::new()
    $Arguments = @{ Window = $Window; ResourceGroup = $ResourceGroup; MaxRetries = $MaxRetries }
    Invoke-SubscriptionCheckInOrder -Items $Items -Command 'Get-SubscriptionConsumptionCheck' -Arguments $Arguments -ThrottleLimit $ThrottleLimit -OnResult {
        param($CheckResult)
        # Only a check that threw carries Failed (Invoke-SubscriptionCheckInOrder);
        # read it so Set-StrictMode allows a result without it.
        if ($null -ne $CheckResult.PSObject.Properties['Failed'] -and $CheckResult.Failed)
        {
            $CheckResult = [pscustomobject]@{
                Id             = [string]$CheckResult.Item.Id
                Name           = [string]$CheckResult.Item.Name
                ResourceCount  = $CheckResult.Item.ResourceCount
                Outcome        = 'Error'
                Passed         = $false
                Detail         = ('the check failed: {0}' -f $CheckResult.Message)
                PageCapReached = $false
                PagesRead      = 0
                Seconds        = 0
            }
        }
        $CheckResults.Add($CheckResult)
        $Colour = switch ($CheckResult.Outcome) { 'Pass' { 'Green' } 'NoUsage' { 'Yellow' } default { if ($CheckResult.Passed) { 'DarkGray' } else { 'Red' } } }
        Write-Host ('  [{0}] {1} - {2} ({3:N1}s)' -f $CheckResult.Outcome, $CheckResult.Name, $CheckResult.Detail, $CheckResult.Seconds) -ForegroundColor $Colour
        if ($CheckResult.Outcome -eq 'NoUsage' -and $CheckResult.PageCapReached)
        {
            # Only the first pages were read, so nothing is known about the
            # rest; the consumption phase reads every page.
            Write-Host ('      WARNING: no usage above zero{0} in the first {1} page(s) read for {2}; later pages were not checked. The run continues and the consumption phase reads every page.' -f $ForRg, $CheckResult.PagesRead, $WindowText) -ForegroundColor Yellow
        }
        elseif ($CheckResult.Outcome -eq 'NoUsage' -and -not [string]::IsNullOrEmpty($ResourceGroup))
        {
            Write-Host ("      WARNING: no usage above zero in resource group '{0}' for {1}. Typical causes: new resources, only free resources, or paused resources. The run continues; the consumption sheet for resource group '{0}' will be empty." -f $ResourceGroup, $WindowText) -ForegroundColor Yellow
        }
        elseif ($CheckResult.Outcome -eq 'NoUsage')
        {
            Write-Host ('      WARNING: no usage above zero for {0}. Typical causes: a new subscription, only free resources, or paused resources. The run continues; this subscription''s consumption sheet will be empty.' -f $WindowText) -ForegroundColor Yellow
        }
    }
    return (Resolve-ConsumptionDataCheck -Results $CheckResults.ToArray() -Window $Window -ResourceGroup $ResourceGroup)
}

# Prints the outcome of Invoke-ConsumptionDataCheck. On a refusal it lists
# every failing subscription with its outcome and the window queried, then the
# fix. The caller exits with code 1 when $Result.ShouldBlock is $true. A
# subscription whose check stopped at the page cap is described by the pages
# read only: its consumption sheet may still have values.
function Write-ConsumptionDataCheckReport
{
    param([Parameter(Mandatory = $true)]$Result)
    $WindowText = Format-ConsumptionWindow -Window $Result.Window
    $ForRg = Format-ConsumptionCheckTarget -ResourceGroup $Result.ResourceGroup
    $InRg = if ([string]::IsNullOrEmpty($Result.ResourceGroup)) { '' } else { " in resource group '{0}'" -f $Result.ResourceGroup }
    $Checked = @($Result.Results | Where-Object { $_.Outcome -ne 'Exempt' })
    $NoUsage = @($Result.NoUsage)
    $NoUsageCapped = @($NoUsage | Where-Object { $_.PageCapReached })
    $NoUsageEmpty = @($NoUsage | Where-Object { -not $_.PageCapReached })
    if ($Result.Exempt.Count -gt 0)
    {
        Write-Host ('  {0} subscription(s) have no resources{1} in Resource Graph and were not checked (nothing to price).' -f $Result.Exempt.Count, $InRg) -ForegroundColor DarkGray
    }
    if (-not $Result.ShouldBlock)
    {
        $WithValues = $Checked.Count - $NoUsage.Count
        if ($WithValues -gt 0 -or $NoUsage.Count -eq 0)
        {
            Write-Host ('Consumption data confirmed: {0} subscription(s) returned usage values{1} for {2}.' -f $WithValues, $ForRg, $WindowText) -ForegroundColor Green
        }
        if ($NoUsageEmpty.Count -gt 0)
        {
            Write-Host ('{0} subscription(s) returned no usage values{1} for {2} and continue with an empty consumption sheet, because the role check confirmed the usage permission (see the warnings above).' -f $NoUsageEmpty.Count, $ForRg, $WindowText) -ForegroundColor Yellow
        }
        if ($NoUsageCapped.Count -gt 0)
        {
            Write-Host ('{0} subscription(s) showed no usage above zero{1} in the first {2} page(s) read for {3} and continue, because the role check confirmed the usage permission; the consumption phase reads every page (see the warnings above).' -f $NoUsageCapped.Count, $ForRg, $NoUsageCapped[0].PagesRead, $WindowText) -ForegroundColor Yellow
        }
        return
    }
    $FailedCapped = @($Result.Failed | Where-Object { $_.PageCapReached })
    $CappedText = if ($FailedCapped.Count -gt 0) { ' ({0} of them: none above zero in the first {1} page(s) read; later pages were not checked)' -f $FailedCapped.Count, $FailedCapped[0].PagesRead } else { '' }
    Write-Host ''
    Write-Host ('ERROR: Consumption data was requested (no -SkipConsumption), but {0} of {1} checked subscription(s) returned no usage values{2} for {3}{4}.' -f $Result.Failed.Count, $Checked.Count, $ForRg, $WindowText, $CappedText) -ForegroundColor Red
    Write-Host 'Without consumption the business case cannot be priced, so the run stops before any inventory or metrics work.' -ForegroundColor Red
    foreach ($Fail in $Result.Failed)
    {
        Write-Host ('  - {0} ({1}): {2} - {3}; window {4}' -f $Fail.Name, $Fail.Id, $Fail.Outcome, $Fail.Detail, $WindowText) -ForegroundColor Red
    }
    if ($NoUsageEmpty.Count -gt 0)
    {
        Write-Host ('  ({0} other subscription(s) returned no usage values too, but passed because the role check confirmed the usage permission.)' -f $NoUsageEmpty.Count) -ForegroundColor Yellow
    }
    if ($NoUsageCapped.Count -gt 0)
    {
        Write-Host ('  ({0} other subscription(s) showed no usage above zero in the first {1} page(s) read, but passed because the role check confirmed the usage permission.)' -f $NoUsageCapped.Count, $NoUsageCapped[0].PagesRead) -ForegroundColor Yellow
    }
    Write-Host 'To fix:' -ForegroundColor Yellow
    Write-Host '  1. Give the signed-in identity Microsoft.Commerce/UsageAggregates/read on each subscription above. The built-in Reader and Billing Reader roles include it; Cost Management Reader does NOT.' -ForegroundColor Yellow
    Write-Host '  2. If the identity already has it: the subscription may be partner-managed (CSP) without cost visibility for this identity, or on an offer the legacy usage API (Get-UsageAggregates) does not serve.' -ForegroundColor Yellow
    Write-Host '  3. Or re-run with -SkipConsumption to inventory without consumption data.' -ForegroundColor Yellow
}

# End-of-run list of the subscriptions the consumption data check passed with
# outcome 'NoUsage', so their empty consumption sheet is not read as a
# collection failure. Those whose check stopped at the page cap are listed
# apart: only the pages read are known to hold no usage above zero. Shared by
# Run-AllSubscriptions.ps1 and direct runs of ResourceInventory.ps1. Prints
# nothing when there are none.
function Write-NoUsageSummary
{
    param($ConsumptionResult)
    if ($null -eq $ConsumptionResult -or $null -eq $ConsumptionResult.Window) { return }
    $NoUsage = @(@($ConsumptionResult.Results) | Where-Object { $null -ne $_ -and $_.Outcome -eq 'NoUsage' })
    if ($NoUsage.Count -eq 0) { return }
    $WindowText = Format-ConsumptionWindow -Window $ConsumptionResult.Window
    $ForRg = Format-ConsumptionCheckTarget -ResourceGroup $ConsumptionResult.ResourceGroup
    $Empty = @($NoUsage | Where-Object { -not $_.PageCapReached })
    $Capped = @($NoUsage | Where-Object { $_.PageCapReached })
    Write-Host ''
    if ($Empty.Count -gt 0)
    {
        Write-Host ('Subscriptions with no usage values{0}: {1} - the usage permission was confirmed, but no usage above zero came back for {2}, so their consumption sheet is empty:' -f $ForRg, $Empty.Count, $WindowText) -ForegroundColor Yellow
        foreach ($Sub in $Empty)
        {
            Write-Host ('  - {0} ({1})' -f $Sub.Name, $Sub.Id) -ForegroundColor Yellow
        }
        $Causes = if ([string]::IsNullOrEmpty($ConsumptionResult.ResourceGroup)) { 'a new subscription, only free resources, or paused resources' } else { 'new resources, only free resources, or paused resources' }
        Write-Host ('  Typical causes: {0}. If usage was expected, the subscription may be partner-managed (CSP) without cost visibility for this identity.' -f $Causes) -ForegroundColor Yellow
    }
    if ($Capped.Count -gt 0)
    {
        Write-Host ('Subscriptions with no usage above zero{0} in the first {1} page(s) the check read: {2} - the usage permission was confirmed; later pages were not checked, and the consumption phase reads every page:' -f $ForRg, $Capped[0].PagesRead, $Capped.Count) -ForegroundColor Yellow
        foreach ($Sub in $Capped)
        {
            Write-Host ('  - {0} ({1})' -f $Sub.Name, $Sub.Id) -ForegroundColor Yellow
        }
    }
}
