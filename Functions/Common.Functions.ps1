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

# Single owner for the "rows arrived but none survived the filter" text.
#
# A DIFFERENT condition from the zero-record billing warning, and it must not be
# confused with it. There the billing API returned nothing and the named causes
# (partner cost visibility, Azure plan transition, an unserved offer) apply. Here
# the API returned rows and the tool excluded all of them, so those causes are
# false and must not be shown.
#
# Emitted by three surfaces (the shareable diagnostics log, the RunSummary Health
# block, the wrapper console), so it gets one owner rather than three hand copies.
# Every line is a single-quoted literal, so the text carries no identifier and is
# safe in an obfuscated bundle.
#
# -ResourceGroupScoped selects WHICH exclusions are named, and the NARROW form is
# the default deliberately. In ResourceInventory.ps1's consumption page loop the
# three exclusions sit at different nesting levels: the empty-instance-data guard
# is outside the -ResourceGroup gate and so is reachable on EVERY run, while the
# no-resource-id guard and the resource-group-mismatch filter are INSIDE that gate
# and so are reachable ONLY when -ResourceGroup was supplied. Naming all three
# unconditionally therefore told the operator that two impossible things might
# have happened, and the closing remedy told them to remove a parameter they
# never passed. Worse on the wrapper surfaces: Run-AllSubscriptions.ps1 has no
# -ResourceGroup parameter at all, so a caller that CANNOT have been given it must
# not be told to remove it. Callers that can be resource-group-scoped pass the
# switch; callers that cannot simply omit it and get the honest narrow form.
function Get-RdaConsumptionExcludedByScopeText
{
    [CmdletBinding()]
    # object[], not string[]: both exit paths build the collection with @(), which
    # produces a System.Object[] whose elements all happen to be String. Declaring
    # string[] would be inaccurate - neither path satisfies -is [string[]] - and it
    # does not silence PSUseOutputTypeCorrectly either, because that rule matches the
    # inferred collection type. Every caller iterates the result, so the element type
    # is what matters to them and the collection type is what matters here.
    [OutputType([object[]])]
    param(
        [int]$RowsFetched = 0,
        [string]$Indent = '',
        [switch]$ResourceGroupScoped
    )

    # Shared preamble. Deliberately mode-NEUTRAL and a COMPLETE sentence: it must
    # not name a scope or a filter, because the default branch's only cause is a
    # data-shape guard with neither in play, and it must not run on into the branch
    # text, because a sentence split across both branches has to be hand-copied and
    # then drifts when only one copy is reworded.
    $Lines = @(
        ('NOTE - the billing API returned {0} usage row(s), but none were written:' -f $RowsFetched)
        'every row was excluded before it could be written. This is NOT the billing'
        'API returning no data, so the partner cost-visibility, Azure-plan and'
        'unsupported-offer causes do NOT apply here.'
    )

    if ($ResourceGroupScoped)
    {
        $Lines += @(
            'The exclusions that do this are:'
            '  - the -ResourceGroup filter, when no billed resource lives in that group'
            '  - a meter with no resource id (marketplace purchases, reservations,'
            '    tenant-level charges), which cannot be attributed to a resource group'
            '  - a meter carrying no instance data at all'
            'Re-run without -ResourceGroup to see the whole subscription.'
        )
    }
    else
    {
        # Only the exclusion that is actually reachable without a resource-group
        # scope. No remedy line: there is no parameter to remove, and an
        # unattributed meter is correct filtering rather than lost data.
        $Lines += @(
            'The exclusion that does this is:'
            '  - a meter carrying no instance data at all'
        )
    }

    if ([string]::IsNullOrEmpty($Indent)) { return $Lines }
    return @($Lines | ForEach-Object { $Indent + $_ })
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

function Get-RdaCollectionAbortedMarkerPath
{
    # The one owner of the marker ResourceInventory.ps1 leaves in a report folder when the collector
    # circuit breaker aborts collection. Its inventory is PARTIAL, so the wrapper must neither fold
    # its HTML into the consolidated bundle nor list it as a normal row in MainSummary.html; this is
    # how the wrapper tells, without reparsing any log.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$Folder)

    return (Join-Path $Folder 'COLLECTION_ABORTED.txt')
}

function Test-RdaCollectionAborted
{
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$Folder)

    if ([string]::IsNullOrWhiteSpace($Folder)) { return $false }
    return (Test-Path -LiteralPath (Get-RdaCollectionAbortedMarkerPath -Folder $Folder) -PathType Leaf)
}

function Test-RdaPermanentRequestError
{
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string]$ErrorMessage,

        # The exception itself, when the caller has it. Pass it: the STATUS is authoritative where the
        # message is not. A real 400 from the legacy Commerce usage API carries neither "400" nor
        # "BadRequest" in its text - observed live as "InvalidInput: reportedStartTime has to be before
        # reportedEndTime." - so a text-only check cannot see it and the caller would spend its whole
        # retry budget on a request that can never succeed.
        $Exception
    )

    if ($null -ne $Exception)
    {
        # Walks InnerException, bounded. Measured live that Get-UsageAggregates surfaces the
        # CloudException itself, so the top level carries .Response today - but a wrapper
        # (MethodInvocationException, AggregateException) would put .Response out of reach and make
        # this gate inert in production while every offline test still passed.
        $Node = $Exception
        for ($Depth = 0; $Depth -lt 5 -and $null -ne $Node; $Depth++)
        {
            $Status = $null
            try { $Status = $Node.Response.StatusCode } catch { $Status = $null }
            if ($null -ne $Status)
            {
                $Code = 0
                try { $Code = [int]$Status } catch { $Code = 0 }
                # Both forms: an HttpStatusCode enum (or int), and a wrapper that exposes it as text.
                if ($Code -eq 400 -or ([string]$Status) -eq 'BadRequest') { return $true }
                # A status was found and it is not a 400, so the text patterns below must not override
                # it: that is what keeps a 500 whose body quotes a 400 out of the permanent bucket.
                return $false
            }
            $Next = $null
            try { $Next = $Node.InnerException } catch { $Next = $null }
            if ($null -eq $Next -or [object]::ReferenceEquals($Next, $Node)) { break }
            $Node = $Next
        }
    }

    if ([string]::IsNullOrWhiteSpace($ErrorMessage)) { return $false }

    # A 400 ONLY, not every non-retryable status. A 404 is deliberately NOT matched here: the sibling
    # classifier in Extension/Metrics.ps1 does treat NotFound as permanent, because a metric that does
    # not exist for a resource never will, whereas a billing window can legitimately return 404 from a
    # transient routing fault. Keep that divergence in mind before reusing this on another endpoint.
    #
    # A 400 rejects the REQUEST rather than the transport, so re-sending it unchanged cannot turn it
    # into a 200. Observed live against a subscription whose offer does not serve the Marketplace
    # endpoint: 30 attempts escalating to a 60s+ wait each, roughly 25 minutes per subscription.
    #
    # Both billing loops call this. The Marketplace fetch sends a byte-identical request on every retry
    # (a fixed window, no page token). The consumption page loop advances a ContinuationToken per PAGE,
    # but a given page is re-sent unchanged within its own retry loop, which is the same argument at
    # page granularity - and it has its own evidence: the legacy Commerce usage API answers a malformed
    # window with HTTP BadRequest whose entire message is "InvalidInput: reportedStartTime has to be
    # before reportedEndTime.", reproduced live, which is why the status and not the text decides.
    #
    # Deliberately narrower than "the text contains 400": the lookarounds keep a resource name or id
    # that happens to contain the word (rg-BadRequest-01) or the digits (400123 bytes) out of it, the
    # same discipline Test-RdaConsumptionDenial uses for 403. It is case-insensitive because the
    # discriminating token's casing genuinely varies by layer ("invalid status code 'BadRequest'",
    # "(400) Bad Request", "400 (BadRequest)"), unlike Test-RdaOutOfMemory which anchors on two fixed
    # full sentences and is case-sensitive for that reason.
    #
    # Callers must let an expired-token 400 reach their auth-refresh branch instead of abandoning on
    # this alone; a token-acquisition failure can render as a 400 that also says the token expired.
    $PermanentPattern = '(?i)(' + (@(
            '(?<![\w-])BadRequest(?![\w-])'
            '\(400\)'
            '\bstatus\s?code\D{0,40}400\b'
            '\bbad request\b'
        ) -join '|') + ')'

    return [bool]($ErrorMessage -match $PermanentPattern)
}

function Close-RdaMetricWorkerPool
{
    # Releases the metric worker pool that Extension/Metrics.ps1 keeps open across subscriptions under
    # the wrappers ($Global:MetricCallPool), once, at the end of the run. The phase end hands a pool on
    # only when every worker has finished, so nothing should still be running here; the same proof is
    # still required before Dispose. BeginClose, never Close, and Dispose only once the close has
    # finished on a pool that reports Closed. A pool that fails that proof is left alone rather than
    # torn down under a running call. A pool in state Broken has no running call to protect and cannot be
    # closed, so it is disposed without a close, which is also what removes its cleanup timer. Returns what
    # happened, for the caller to log; a pool that is not released is also reported as a warning, because it
    # then lives in memory until the process ends and a verbose line at the end of the run would never show it.
    param([int]$GraceSeconds = 10)

    $Pool = $Global:MetricCallPool
    $Global:MetricCallPool = $null
    if ($null -eq $Pool)
    {
        return 'none'
    }

    $Result = $null
    $Released = $false
    try
    {
        if ($Pool.RunspacePoolStateInfo.State -eq [System.Management.Automation.Runspaces.RunspacePoolState]::Broken)
        {
            $Pool.Dispose()
            $Released = $true
            $Result = 'released: pool state Broken, disposed without a close'
        }
        elseif ($Pool.RunspacePoolStateInfo.State -ne [System.Management.Automation.Runspaces.RunspacePoolState]::Opened)
        {
            $Result = ('not released: pool state {0}' -f $Pool.RunspacePoolStateInfo.State)
        }
        elseif ($Pool.GetAvailableRunspaces() -ne $Pool.GetMaxRunspaces())
        {
            $Result = 'not released: a worker is still busy'
        }
        else
        {
            $CloseHandle = $Pool.BeginClose($null, $null)
            if ($CloseHandle.AsyncWaitHandle.WaitOne([math]::Max(0, $GraceSeconds) * 1000) -and $Pool.RunspacePoolStateInfo.State -eq [System.Management.Automation.Runspaces.RunspacePoolState]::Closed)
            {
                $Pool.Dispose()
                $Released = $true
                $Result = 'released'
            }
            else
            {
                $Result = ('not released: close did not finish within {0}s' -f $GraceSeconds)
            }
        }
    }
    catch
    {
        $Released = $false
        $Result = ('not released: {0}' -f $_.Exception.Message)
    }

    if (-not $Released)
    {
        # Whether to warn follows the flag each branch set, not a prefix match on the result text, so
        # rewording a result cannot silence the warning. The result can already end in a period (an
        # exception message), so the trailing one is trimmed rather than printed as "..".
        # Write-Warning itself is guarded: with a caller $WarningPreference of Stop (or Inquire with no
        # console) it throws. Most callers run this from a finally block or from Exit-Wrapper ahead of
        # Stop-Transcript, where a throw would skip the rest of the cleanup. The normal end of
        # Run-AllSubscriptions.ps1 calls it outside any finally, after Stop-Transcript and on the line
        # before its exit, where a throw would lose the exit code; on that path the warning reaches the
        # console only, not the transcript. The pool decision is already made and the caller still gets
        # its result, so a report that cannot be delivered is dropped rather than turned into a
        # terminating error.
        try
        {
            Write-Warning ('Metric worker pool {0}. It stays in memory until this PowerShell process ends.' -f ([string]$Result).TrimEnd('.'))
        }
        catch { }
    }
    return $Result
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
    # log can show how much memory each phase of each subscription held. A recorded reading is
    # always taken after the compacting collection, which is what the rendered block's header
    # states, and its phase must be one of the five the renderer lays out; a misspelled phase would
    # otherwise render as a silent gap. The figures carry no identifier, so the same rows are safe
    # in an obfuscated bundle.
    if ($Record)
    {
        $RecordedPhases = @('start', 'discovery', 'collectors', 'released', 'end')
        if ($Phase -notin $RecordedPhases)
        {
            throw [System.ArgumentException]::new(("A recorded memory reading must use one of the phases the summary renders ({0}); got '{1}'." -f ($RecordedPhases -join ', '), $Phase), 'Phase')
        }
    }
    try
    {
        if ($Compact -or $Record)
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

# A context container scoped to ONE subscription, built from the signed-in context, for use as
# -DefaultProfile or through $PSDefaultParameterValues['*:DefaultProfile']. Set-AzContext moves the
# process's current context, which every runspace in the process shares, and with context autosave
# it also rewrites the saved default subscription the operator's next session starts on. This changes
# neither: it copies the current context and swaps only its subscription (and its tenant, when the
# subscription belongs to another tenant than the signed-in context). Throws when the subscription
# cannot be read with the signed-in identity, as Set-AzContext did, so callers keep their skip path.
function Get-RdaSubscriptionProfile
{
    param([Parameter(Mandatory = $true)][string]$SubscriptionId)

    $ContextType = 'Microsoft.Azure.Commands.Profile.Models.Core.PSAzureContext' -as [type]
    $AbstractContextType = 'Microsoft.Azure.Commands.Common.Authentication.Abstractions.IAzureContext' -as [type]
    $ContainerType = 'Microsoft.Azure.Commands.Common.Authentication.Abstractions.Core.IAzureContextContainer' -as [type]
    $TenantType = 'Microsoft.Azure.Commands.Profile.Models.PSAzureTenant' -as [type]
    if ($null -eq $ContextType -or $null -eq $AbstractContextType -or $null -eq $ContainerType -or $null -eq $TenantType)
    {
        throw 'the Az.Accounts context types are not loaded, so the Azure calls cannot be scoped to one subscription'
    }

    # -DefaultProfile $null on both reads: the callers pin a scoped profile in $PSDefaultParameterValues, and after
    # a reconnect replaced the process context that pin still points at the profile built BEFORE it. Both cmdlets
    # honour the pin, so without the opt-out this helper would copy the pre-reconnect context, and the caller's
    # check that the context matches the subscription would be true by construction.
    $Current = Get-AzContext -DefaultProfile $null -ErrorAction Stop
    if ($null -eq $Current -or $null -eq $Current.Account)
    {
        throw 'there is no signed-in Azure context to scope from'
    }

    # The signed-in tenant first, which is the common case and does not reach into other tenants. A subscription
    # that lives in another tenant the identity can read is not found there, so it is looked up again without a
    # tenant. A failure of that second lookup is the real answer and is what the caller sees, in its own words,
    # with the original exception kept as its inner one.
    $Subscription = $null
    $TenantLookupError = $null
    try
    {
        $Subscription = Get-AzSubscription -SubscriptionId $SubscriptionId -TenantId $Current.Tenant.Id -DefaultProfile $null -ErrorAction Stop -WarningAction SilentlyContinue
    }
    catch
    {
        # Kept for the debug log. A lookup without a tenant reports what that lookup found, which can be
        # a bare "not found" even when the signed-in tenant failed on a token instead; per-tenant token
        # failures come out of that lookup as warnings, which -WarningAction SilentlyContinue hides.
        $TenantLookupError = [string]$_.Exception.Message
        $Subscription = $null
    }
    if ($null -eq $Subscription)
    {
        try
        {
            $Subscription = Get-AzSubscription -SubscriptionId $SubscriptionId -DefaultProfile $null -ErrorAction Stop -WarningAction SilentlyContinue
        }
        catch
        {
            if ([string]::IsNullOrWhiteSpace($TenantLookupError))
            {
                throw
            }
            # The first failure's text, and the tenant it was looked up in, go to the debug log only (which stays
            # local in an -Obfuscate run and ships in a default bundle, beside the real identifiers that bundle
            # already holds). That text can name the tenant, its domain or a local path, and callers copy this
            # message into the skip entries that ship in Diagnostics_*.log. The message keeps the second
            # lookup's own words, as before, and says where the first failure went - but only when a debug log
            # is being written: the wrappers clear its path at the start of a run, and their billing probe runs
            # before the first inner run opens one.
            Write-Log -Message ('[Profile] The lookup of subscription {0} in the signed-in tenant {1} failed first, with: {2}' -f $SubscriptionId, $Current.Tenant.Id, $TenantLookupError) -Severity 'Info' -NoConsole -ToDebugLog
            $DebugLogNote = if ([string]::IsNullOrEmpty($Global:DebugLogFile)) { '' } else { '; its error is in the debug log' }
            throw [System.Exception]::new(('{0} (the lookup in the signed-in tenant had also failed{1})' -f $_.Exception.Message, $DebugLogNote), $_.Exception)
        }
    }
    if ($null -eq $Subscription)
    {
        throw ('subscription {0} is not visible to the signed-in identity' -f $SubscriptionId)
    }
    # A subscription reachable through more than one tenant (delegated access as well as guest access) can come
    # back once per tenant from the lookup without a tenant. The copy in the signed-in tenant is taken when there
    # is one, so a first lookup that failed only for a moment does not move the profile to another tenant, whose
    # access rights can differ from those of the tenant the run names.
    $SubscriptionCopies = @($Subscription | Where-Object { $null -ne $_ })
    $Subscription = @($SubscriptionCopies | Where-Object { [string]$_.TenantId -eq [string]$Current.Tenant.Id })[0]
    if ($null -eq $Subscription) { $Subscription = $SubscriptionCopies[0] }

    $Scoped = $ContextType::new([System.Management.Automation.LanguagePrimitives]::ConvertTo($Current, $AbstractContextType))
    $Scoped.Subscription = $Subscription
    $SubscriptionTenantId = [string]$Subscription.TenantId
    if (-not [string]::IsNullOrEmpty($SubscriptionTenantId) -and $SubscriptionTenantId -ne [string]$Current.Tenant.Id)
    {
        # A new tenant object rather than a change to the copied one, so the signed-in context is never touched.
        $ScopedTenant = $TenantType::new()
        $ScopedTenant.Id = $SubscriptionTenantId
        $Scoped.Tenant = $ScopedTenant
    }
    return [System.Management.Automation.LanguagePrimitives]::ConvertTo($Scoped, $ContainerType)
}
