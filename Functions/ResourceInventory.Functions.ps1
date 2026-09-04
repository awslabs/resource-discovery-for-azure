#Requires -Version 7.0
# =============================================================================
# ResourceInventory.Functions.ps1
#
# Shared helper functions for ResourceInventory.ps1. Dot-sourced from the top
# of that script so they load into its scope. Moved out of the main script to
# keep the orchestration flow (Variables / RunInventorySetup /
# ExecuteInventoryProcessing / FinalizeOutputs) readable. No top-level code
# lives here - definitions only.
#
# NOTE: Protect-FreeTextValue is defined Global: on purpose so it stays
# reachable from the Services/*/*.ps1 collectors, which the orchestrator
# invokes via '& $Module' (a call operator does NOT inherit the caller's
# non-Global function table). Keep the Global: scope modifier.
# =============================================================================
# Write-Log moved to Functions/Common.Functions.ps1 (defined Global: there) so a
# single logger is in scope for every entry script AND the Services/*/*.ps1
# collectors (reached via '& $Module', which only see Global functions).
# ResourceInventory.ps1 dot-sources Common.Functions.ps1 at startup, so Write-Log
# is available here exactly as before. Its default behavior is unchanged; it
# gained additive -NoConsole / -ToDebugLog switches. See that file for detail.

function GetLocalVersion()
{
    # Anchor on this file's OWN location, never the current working directory, so
    # the version reads correctly regardless of where the tool is launched from -
    # e.g. an Azure DevOps agent, or a background job (Start-Job) on an AKS pod,
    # whose working directory is not the repo checkout root. This Functions file
    # lives one level below the repo root (Functions/) and Version.json sits at
    # the repo root, hence the parent of $PSScriptRoot. Join-Path builds the path
    # with the correct separator on Windows and Linux/macOS alike.
    #
    # $PSScriptRoot is empty only when this file was not loaded from disk (e.g. an
    # inline Start-Job -ScriptBlock). Guard it so that case yields a clear message
    # instead of a cryptic Join-Path/Split-Path binding error.
    if ([string]::IsNullOrWhiteSpace($PSScriptRoot))
    {
        Write-Host 'Cannot resolve the script location ($PSScriptRoot is empty). Run the tool from its files on disk, not an inline script block. Exiting.' -ForegroundColor Red
        Exit 1
    }

    $VersionJsonPath = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Version.json'

    if (-not (Test-Path -LiteralPath $VersionJsonPath -PathType Leaf))
    {
        Write-Host ("Version.json not found at '{0}' (expected at the repo root, alongside ResourceInventory.ps1). Ensure the full repo is present. Exiting." -f $VersionJsonPath) -ForegroundColor Red
        Exit 1
    }

    # -Raw + explicit parse guard: a truncated or malformed Version.json (e.g. a
    # partial copy baked into a container image) fails LOUD with the offending
    # path instead of a bare ConvertFrom-Json exception.
    try
    {
        $LocalVersionJson = Get-Content -LiteralPath $VersionJsonPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch
    {
        Write-Host ("Version.json at '{0}' could not be read or parsed as JSON: {1}. Exiting." -f $VersionJsonPath, $_.Exception.Message) -ForegroundColor Red
        Exit 1
    }

    return ('{0}.{1}.{2}' -f $LocalVersionJson.MajorVersion, $LocalVersionJson.MinorVersion, $LocalVersionJson.BuildVersion)
}

# Deterministically tokenize a free-text / identity value into
# $Global:FreeTextDictionary and return the token, so collectors can replace
# free-form fields (Description, FriendlyName, CreatedBy, RoleName, container
# image, etc.) with a reversible token instead of dropping them. Same real value
# always yields the same prod_/nonprod_ token within a run. Null/empty input
# returns $null (preserving the previous "absent" shape); when obfuscation is off
# the dictionary is $null and the original value is returned unchanged. Defined
# Global so it is reachable from the collectors invoked via '& $Module'.
Function Global:Protect-FreeTextValue([string]$Value)
{
    if ([string]::IsNullOrEmpty($Value)) { return $null }
    if ($null -eq $Global:FreeTextDictionary) { return $Value }
    if (-not $Global:FreeTextDictionary.ContainsKey($Value))
    {
        $TfPrefix = if ($Value -match '\b(dev|test|qa|tst|development|non-prod|uat|nonprod)\b' -or $Value -match '(^|-)([dts])-') { 'nonprod_' } else { 'prod_' }
        $Global:FreeTextDictionary[$Value] = $TfPrefix + [guid]::NewGuid().ToString()
    }
    return $Global:FreeTextDictionary[$Value]
}

# Safe-by-construction scrub of a raw diagnostic / exception string so it is safe
# to place in the SHAREABLE (obfuscated) diagnostics log. Two passes:
#   1. Dictionary tokenization. $ValueMap is a REAL-value -> token lookup the
#      caller builds from the run's obfuscation state. NOTE the four core
#      dictionaries are keyed by the real ARM RESOURCE ID (not by name/RG/sub),
#      so the caller derives the bare resource NAME, RG name and subscription
#      GUID from those keys and adds them to $ValueMap, plus tag values and
#      free-text values. Keys are applied longest-first so a full ARM path is
#      tokenized as one unit before its shorter sub/RG/name substrings.
#   2. Structured-identifier masking. Classes a raw exception can carry that the
#      dictionaries do NOT cover are masked generically so none can ship:
#      email/UPN -> <email>, IPv4 -> <ip>, Azure data-plane FQDNs -> <host>,
#      *nix/Windows home paths -> <user>, and any REMAINING raw GUID (e.g. a
#      tenant GUID) -> <guid>. The email/home-path patterns mirror the leak
#      scans in Tests/Obfuscation.Tests.ps1 so a scrubbed message cannot trip
#      them. A prod_/nonprod_ token's GUID is always preceded by '_', so the
#      (?<!_) lookbehind + \b boundary leave real tokens intact.
#
# Intentionally over-inclusive: it may mask a substring that merely coincides
# with a real value, but it never LEAKS a known value or a structured
# identifier. Called only for the handful of error strings that go into the
# shareable diagnostics log (collector failures + per-phase auth-skip messages),
# never per log line, so the per-message cost (incl. the length sort) is off the
# hot path. When obfuscation is off the caller does not build the shareable log,
# so this is never reached in that mode. Defined Global to match
# Protect-FreeTextValue. Residual note: a bare resource name that is NOT in the
# report (never inventoried, so not in any dictionary) and is not GUID/host/
# email/path shaped could still appear in words - the caller keeps this to the
# obfuscated bundle (shared only with the ingestion party), not a public surface.
Function Global:Protect-DiagnosticText([string]$Text, [System.Collections.IDictionary]$ValueMap)
{
    if ([string]::IsNullOrEmpty($Text)) { return $Text }

    $Result = $Text
    if ($null -ne $ValueMap -and $ValueMap.Count -gt 0)
    {
        foreach ($real in ($ValueMap.Keys | Sort-Object -Property Length -Descending))
        {
            if (-not [string]::IsNullOrEmpty($real) -and $Result.Contains($real))
            {
                $Result = $Result.Replace($real, $ValueMap[$real])
            }
        }
    }

    # Auth artifacts first (highest severity): a SAS signature / token value in a
    # URL or error must never ship even to the ingestion party. Mask the VALUE of
    # sig=/signature=/sas=/(access|bearer)token=... and a 'Bearer <token>' header.
    $Result = [regex]::Replace($Result, '(?i)\b(sig|signature|sas|accesstoken|access_token|bearertoken)=[^&\s"''<>]+', '$1=<redacted>')
    $Result = [regex]::Replace($Result, '(?i)\bBearer\s+[A-Za-z0-9._\-]+', 'Bearer <redacted>')

    $Result = [regex]::Replace($Result, '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}', '<email>')
    $Result = [regex]::Replace($Result, '\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b', '<ip>')
    $Result = [regex]::Replace($Result, '(?i)\b[a-z0-9][a-z0-9-]*\.(?:blob|file|queue|table|dfs|vault|database|servicebus|azurewebsites|documents|search|azurecr|azuredatabricks|cognitiveservices|azconfig|azurefd|azure-api)\.[a-z0-9.]+\b', '<host>')
    $Result = [regex]::Replace($Result, '(?i)\b[a-z0-9][a-z0-9-]*\.(?:cloudapp\.azure\.com|trafficmanager\.net|cache\.windows\.net)\b', '<host>')
    $Result = [regex]::Replace($Result, '(?i)/home/[a-z0-9._-]+', '/home/<user>')
    $Result = [regex]::Replace($Result, '(?i)C:\\Users\\[a-z0-9._-]+', 'C:\Users\<user>')
    $Result = [regex]::Replace($Result, '(?<!_)\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b', '<guid>')

    return $Result
}

# Pure helper: given a caught exception from a throttled Azure call, return how
# many seconds to wait before retrying - honoring the SERVICE'S OWN retry
# directive when it exposed one, instead of blind exponential guessing. A 429 is
# a backoff signal, and Azure tells you how long to wait; obeying that both
# recovers faster and stops a shard hammering an already-throttled, tenant-shared
# budget (consumption/billing is the most aggressive of the three phases).
#
# Reads the throttle header off BOTH $Exception.Response.Headers and
# $Exception.InnerException.Response.Headers (the metrics Get-AzMetric path wraps
# the real ErrorResponseException one level down). Header precedence:
#   1. Retry-After                                       (integer seconds)
#   2. x-ms-ratelimit-microsoft.consumption-retry-after  (integer seconds)
#   3. x-ms-user-quota-resets-after                      (hh:mm:ss TimeSpan)
# The honored value is clamped to [1, MaxSeconds] so a pathological header can
# never wedge a shard for minutes. When no usable header is present (or it does
# not parse) the caller's exponential FallbackSeconds is returned unchanged, so
# behavior is never worse than the pre-existing backoff. No cmdlet calls, no side
# effects - deterministically unit-testable with synthetic exceptions.
function Get-RetryWaitSeconds
{
    param(
        [Parameter(Mandatory = $true)]$Exception,
        [Parameter(Mandatory = $true)][double]$FallbackSeconds,
        [double]$MaxSeconds = 120
    )

    # Pull the first value of a named header (case-insensitive) out of a header
    # container, whether it is a Dictionary[string,IEnumerable[string]] (ARG /
    # consumption / metrics ErrorResponseException) or an HttpResponseHeaders
    # (metrics getBatch). Both enumerate as KeyValuePair<string,IEnumerable[string]>.
    $ReadHeader = {
        param($Container, $Name)
        if ($null -eq $Container) { return $null }
        # Enumerate via GetEnumerator(): PowerShell's foreach does NOT iterate an
        # IDictionary (a generic Dictionary - the ARG/consumption header container
        # - or a Hashtable) entry-by-entry; it treats it as one scalar object.
        # GetEnumerator() yields KeyValuePair (Dictionary / HttpResponseHeaders,
        # the metrics getBatch container) or DictionaryEntry (Hashtable) - both
        # expose .Key / .Value - so this walks all three real container shapes.
        $Enum = $null
        try { $Enum = $Container.GetEnumerator() } catch { return $null }
        if ($null -eq $Enum) { return $null }
        while ($Enum.MoveNext())
        {
            $Pair = $Enum.Current
            if ($Pair.Key -and (([string]$Pair.Key).Trim().ToLowerInvariant() -eq $Name))
            {
                $Val = @($Pair.Value)[0]
                if ($null -ne $Val) { return [string]$Val }
            }
        }
        return $null
    }

    # Candidate header containers: the exception itself plus one level of inner.
    $Containers = @()
    foreach ($Ex in @($Exception, $Exception.InnerException))
    {
        if ($null -ne $Ex -and $null -ne $Ex.Response -and $null -ne $Ex.Response.Headers)
        {
            $Containers += $Ex.Response.Headers
        }
    }
    if ($Containers.Count -eq 0) { return $FallbackSeconds }

    # Read a named header from whichever container carries it (search order:
    # exception then inner), so header precedence below is applied GLOBALLY by
    # header type rather than per-container - i.e. Retry-After always wins over a
    # quota header no matter which of the two containers each lives on.
    $FirstHeader = {
        param($Name)
        foreach ($Container in $Containers)
        {
            $Found = & $ReadHeader $Container $Name
            if ($Found) { return $Found }
        }
        return $null
    }

    # 1. Retry-After (integer seconds - Azure throttling emits a numeric value).
    $Raw = & $FirstHeader 'retry-after'
    if ($Raw)
    {
        $Sec = 0
        if ([int]::TryParse($Raw.Trim(), [ref]$Sec) -and $Sec -gt 0)
        {
            return [math]::Min([math]::Max($Sec, 1), $MaxSeconds)
        }
    }

    # 2. Consumption/billing ratelimit header (integer seconds).
    $Raw = & $FirstHeader 'x-ms-ratelimit-microsoft.consumption-retry-after'
    if ($Raw)
    {
        $Sec = 0
        if ([int]::TryParse($Raw.Trim(), [ref]$Sec) -and $Sec -gt 0)
        {
            return [math]::Min([math]::Max($Sec, 1), $MaxSeconds)
        }
    }

    # 3. Resource Graph user-quota reset window (hh:mm:ss TimeSpan).
    $Raw = & $FirstHeader 'x-ms-user-quota-resets-after'
    if ($Raw)
    {
        $Span = [TimeSpan]::Zero
        if ([TimeSpan]::TryParse($Raw.Trim(), [ref]$Span) -and $Span.TotalSeconds -ge 1)
        {
            return [math]::Min($Span.TotalSeconds, $MaxSeconds)
        }
    }

    return $FallbackSeconds
}

# Runs an Azure Resource Graph query via the native Az.ResourceGraph cmdlet
# (Search-AzGraph) and returns an object exposing a .data member, mirroring the
# shape the call sites already consume. A failed query (expired auth, throttling,
# a malformed KQL string, a transient ARM error) throws with the real error text,
# so a Resource Graph failure surfaces as a loud, actionable subscription failure
# instead of a silent "0 resources found" (see #22) - transient failures are
# retried with backoff first. -Lowercase preserves the exact whole-payload
# `.tolower()` behavior the original data-fetching call sites relied on
# (collectors compare against lowercase type strings and self-join on lowercased
# ids). Native cmdlet = portable across Windows/Linux/macOS with no az.cmd shell
# boundary; see .kiro/steering/cross-platform-powershell.md.
# Sentinel prefix marking "Azure refused this response as too large". Matched by
# the window splitter below, which is the only caller that can do anything about
# it. Tagging the message keeps this free of a custom exception type, which would
# be more machinery than a single internal signal needs.
$script:RdaPayloadTooLargeTag = 'RDA_PAYLOAD_TOO_LARGE'

# ONE Resource Graph request, with the project's bounded retry around it.
#
# Loop control is deliberately NOT expressed with `throw`. In a normal (non-Debug)
# run ResourceInventory.ps1 sets $ErrorActionPreference = 'SilentlyContinue', and
# under that preference an UNCAUGHT throw does not terminate - execution simply
# continues at the next statement. The previous shape used `for (;;)` whose only
# exits were `break` on success and a `throw` in the failure branch, so on a
# permanent failure the throw fell through, the backoff ran, and the loop went
# round again FOREVER. The retry ceiling looked like a bound but was inert, and a
# subscription with an unfetchable page hung indefinitely instead of failing.
# Every exit here is now an explicit `break`; the throw happens after the loop,
# where it is the function's return path rather than its control flow.
function Invoke-AzGraphRequest
{
    param(
        [Parameter(Mandatory = $true)][string]$Query,
        [string[]]$Subscription,
        [int]$First = 1000,
        [int]$Skip = 0
    )

    $GraphParams = @{ Query = $Query; First = $First; ErrorAction = 'Stop' }
    if ($Subscription) { $GraphParams['Subscription'] = $Subscription }
    if ($Skip -gt 0) { $GraphParams['Skip'] = $Skip }

    # Up to 30 retries (31 attempts) with exponential backoff + jitter, longer when
    # throttled, honouring a server Retry-After directive when one is present. The
    # high ceiling lets a shard ride out SUSTAINED tenant-wide ARG throttling rather
    # than failing a whole subscription on it; per-attempt backoff is still capped
    # (30s, 60s throttled, 120s server-directed) so the worst case is long but
    # bounded. Stable internal - deliberately not a script parameter.
    $GraphMaxRetries = 30
    $Rows = $null
    $FailureMessage = $null
    $AttemptsMade = 0

    for ($Attempt = 0; ; $Attempt++)
    {
        $AttemptsMade = $Attempt + 1
        try
        {
            $Rows = @(Search-AzGraph @GraphParams)
            $FailureMessage = $null
            break
        }
        catch
        {
            $Message = $_.Exception.Message

            # Checked FIRST, because Azure returns it AS a BadRequest and the
            # permanent-failure test below would otherwise swallow it. This one is
            # not "give up" and not "retry the same thing" - it means the window is
            # too big, which only the splitter can act on, so hand it straight up.
            if ($Message -match 'ResponsePayloadTooLarge|Response payload size is \d+, exceeded the limit')
            {
                $FailureMessage = ('{0}: {1}' -f $script:RdaPayloadTooLargeTag, $Message)
                break
            }

            # Clearly-permanent failures: a retry cannot help, so stop now rather
            # than burning the whole backoff budget on an error retrying cannot fix.
            $Permanent = $Message -match 'AuthorizationFailed|does not have authorization|\bForbidden\b|\bBadRequest\b|SemanticError|SyntaxError|InvalidQuery|Please provide a valid'

            if ($Permanent -or $Attempt -ge $GraphMaxRetries)
            {
                $FailureMessage = ("Resource Graph query failed after {0} attempt(s): {1}`nQuery: {2}" -f $AttemptsMade, $Message, $Query)
                break
            }

            # Transient: exponential backoff (2^attempt, capped) plus jitter so a
            # wave of throttled calls does not retry in lockstep. Throttled calls
            # wait a bit longer.
            $Throttled = $Message -match 'TooManyRequests|\b429\b|throttl'
            $Backoff = [math]::Min([math]::Pow(2, $Attempt), 30)
            if ($Throttled) { $Backoff = [math]::Min($Backoff * 2, 60) }
            # Honor the service's own retry directive when the throttling response
            # exposed one (Retry-After / x-ms-user-quota-resets-after); otherwise
            # keep the exponential backoff just computed. Clamped to 120s so a
            # pathological header cannot wedge the shard.
            $Backoff = Get-RetryWaitSeconds -Exception $_.Exception -FallbackSeconds $Backoff -MaxSeconds 120
            $Jitter = (Get-Random -Minimum 0 -Maximum 1000) / 1000.0
            Start-Sleep -Seconds ([math]::Round($Backoff + $Jitter, 2))
        }
    }

    if ($null -ne $FailureMessage) { throw $FailureMessage }
    return $Rows
}

# Fetch the rows for ONE caller-requested window, splitting it if Azure refuses the
# response as too large.
#
# Resource Graph caps a single response at 16 MB. A full page normally sits far
# below that, but a resource type whose payload is hundreds of KB each -
# microsoft.resources/templatespecs/versions is the case that surfaced this, at up
# to ~794 KB per resource - can push one page over the cap. Because the discovery
# query is `order by id asc`, those resources are contiguous, so the oversize lands
# entirely in one page. That page can NEVER succeed: it is not transient, and
# retrying the identical request is futile.
#
# The caller's paging contract must not change - it advances its offset by the page
# size it asked for - so a smaller page here would silently skip resources. This
# therefore always returns the FULL requested window, fetched as however many
# smaller sub-windows it takes. Halving down to a floor of one row is enough for any
# realistic type; only a SINGLE resource larger than the cap is genuinely
# unfetchable, and that fails loudly rather than being dropped.
#
# Splitting is only sound because the query is ordered (`order by id asc` at every
# paged call site): sub-windows of an ordered result are disjoint and their
# concatenation is the whole window. An UNORDERED query must not be split, because
# Azure gives no stability guarantee across requests - hence the guard below.
function Get-AzGraphRowWindow
{
    param(
        [Parameter(Mandatory = $true)][string]$Query,
        [string[]]$Subscription,
        [int]$First = 1000,
        [int]$Skip = 0
    )

    # Work stack of windows still to fetch. Pushing the RIGHT half before the LEFT
    # means the left is popped first, so rows accumulate in ascending order - the
    # same order a single successful request would have returned.
    $Pending = New-Object System.Collections.Stack
    $Pending.Push([pscustomobject]@{ Skip = $Skip; First = $First })
    $Rows = @()
    $SplitCount = 0

    while ($Pending.Count -gt 0)
    {
        $Window = $Pending.Pop()
        try
        {
            $Rows += @(Invoke-AzGraphRequest -Query $Query -Subscription $Subscription -First $Window.First -Skip $Window.Skip)
        }
        catch
        {
            $Message = $_.Exception.Message
            if ($Message -notlike ('{0}*' -f $script:RdaPayloadTooLargeTag))
            {
                # Anything else is this function's caller's problem, unchanged.
                throw
            }

            # Only an ordered query may be split - see the note above.
            if ($Query -notmatch 'order\s+by')
            {
                throw ("Resource Graph refused the response as too large and the query is not ordered, so it cannot be split safely. Add an 'order by' clause to page it.`n{0}`nQuery: {1}" -f $Message, $Query)
            }

            if ($Window.First -le 1)
            {
                throw ("Resource Graph refused a SINGLE resource as too large (offset {0}); it exceeds the 16 MB response cap and cannot be retrieved. Exclude this resource type from the discovery query to complete the run.`n{1}" -f $Window.Skip, $Message)
            }

            $LeftCount = [math]::Floor($Window.First / 2)
            $RightCount = $Window.First - $LeftCount
            $Pending.Push([pscustomobject]@{ Skip = ($Window.Skip + $LeftCount); First = $RightCount })
            $Pending.Push([pscustomobject]@{ Skip = $Window.Skip; First = $LeftCount })
            $SplitCount++
            Write-Log -Message ("Resource Graph response too large at offset {0} for {1} rows; retrying as {2} + {3}." -f $Window.Skip, $Window.First, $LeftCount, $RightCount) -Severity 'Warning'
        }
    }

    if ($SplitCount -gt 0)
    {
        Write-Log -Message ("Fetched offset {0}..{1} in smaller sub-pages after {2} split(s); {3} row(s) collected. This subscription holds at least one unusually large resource type." -f $Skip, ($Skip + $First - 1), $SplitCount, $Rows.Count) -Severity 'Warning'
    }

    return $Rows
}

function Invoke-AzGraphQuerySafe
{
    param(
        [Parameter(Mandatory = $true)][string]$Query,
        [string[]]$Subscription,
        [int]$First = 1000,
        [int]$Skip = 0,
        [switch]$Lowercase
    )

    # Native Az.ResourceGraph query. Replaces the former 'az graph query' CLI
    # shell-out so the data path is portable by construction across
    # Windows/Linux/macOS with no az.cmd/cmd.exe argument-quoting boundary.
    #
    # Contract preserved for the callers (unchanged): returns an object exposing
    # a .data member - the row array for a fetch, or the single row for a
    # 'summarize count()' probe (so $x.data.'count_' keeps working). Paging is
    # caller-driven via -First (max 1000) / -Skip offset, mirroring the previous
    # --first/--skip. -Subscription scopes the query (mirrors --subscriptions);
    # omitting it queries the whole accessible tenant, as before.
    # The window fetch below builds the per-request parameter set itself, because a
    # window that Azure refuses as too large is re-fetched as smaller sub-windows
    # with different First/Skip values.

    # Bounded retry for TRANSIENT Resource Graph failures (dropped/changed
    # network mid-run, VPN switch, ARM throttling, 5xx). Without this a single
    # transient blip during discovery throws and fails the whole subscription
    # (recorded to FailedAttempts and resumable, but the entire sub restarts).
    # Up to 30 retries (31 attempts total) with exponential backoff + jitter,
    # longer backoff when throttled. The high ceiling lets a shard ride out
    # SUSTAINED Resource Graph throttling at very large scale - many shards share
    # one tenant-wide ARG budget, so a throttle storm is expected - rather than
    # failing a whole subscription on it. When the throttling response carries a
    # server retry directive (Retry-After / x-ms-user-quota-resets-after), that
    # value is honored via Get-RetryWaitSeconds instead of guessing - a 429 is a
    # backoff signal and the service tells you how long to wait, so obeying it both
    # recovers sooner and stops hammering an already-throttled shared budget.
    # Backoff PER ATTEMPT is still capped (exponential 30s / 60s throttled,
    # server-directed 120s) + jittered, so the worst case is a long-but-bounded
    # wait before a genuinely dead query finally gives up. Stable internal;
    # deliberately NOT promoted to a script param.
    # A CLEARLY-PERMANENT failure (authorization denied, malformed KQL / bad
    # request) is NOT retried - it throws immediately, matching the project's
    # fail-loud-fast stance for genuine access denial rather than burning ~30s
    # of backoff on an error a retry cannot fix. On the final failed attempt the
    # throw is identical to the pre-retry behavior, so the per-subscription
    # catch -> FailedAttempts -> -Resume path is unchanged (see #22).
    $Rows = @(Get-AzGraphRowWindow -Query $Query -Subscription $Subscription -First $First -Skip $Skip)

    # Reproduce the former whole-payload .ToLower() (keys AND values) when asked.
    # Search-AzGraph returns typed objects with ORIGINAL casing; every data-fetch
    # call site passes -Lowercase and downstream collectors/report tests depend on
    # lowercased type/location/value strings (and on both sides of intra-collector
    # self-joins being lowercased), so round-trip through JSON to lowercase both.
    if ($Lowercase -and $Rows.Count -gt 0)
    {
        $Rows = @(($Rows | ConvertTo-Json -Depth 100).ToLower() | ConvertFrom-Json)
    }

    # Preserve the historical .data accessor the call sites read.
    return [pscustomobject]@{ data = $Rows }
}



# Build + write the shareable Diagnostics_*.log that ships INSIDE the per-sub
# report zip. Extracted from ResourceInventory.ps1's packaging section so it can
# run for BOTH obfuscated and default (non-obfuscated) runs - the operator asked
# for a diagnostic log on every run, not just obfuscated ones.
#
# Every free-text field that could carry an identifier (collector/phase failure
# messages and the subscription id) is run through Protect-DiagnosticText:
# dictionary-tokenized when an obfuscation dictionary exists (obfuscated run),
# then any residual GUID/email/host/path masked by class. In a default run the
# dictionaries are empty, so only the class masking applies - the log is still
# scrubbed, but the surrounding bundle contains real identifiers, so the header
# says so. Written as a HUMAN-READABLE .log (NOT .json) so the ingestion server
# does not table-ingest it; the caller adds it to the zip Path array explicitly.
#
# Wrapped in try/catch and returns the written file path on success or $null on
# failure: the diagnostics log is a troubleshooting aid, not the report, so a
# construction/write error must never break packaging of the actual inventory.
# Reads the health globals ($Global:CollectorFailures / $Global:MetricsFailedSubs
# / $Global:ConsumptionFailedSubs) and obfuscation dictionaries directly; the
# per-run scalars (report name, timestamp, version) and the phase-timing table
# are passed in so the function is self-contained and unit-testable.
function Write-RdaShareableDiagnosticsLog
{
    param(
        [string]$DefaultPath,
        [string]$ReportName,
        [string]$RunDateTime,
        [string]$Version,
        $PhaseTimings,
        # Consumption outcome for THIS run. Passed in (rather than read from the
        # global) so the builder stays self-contained and unit-testable offline.
        # $ConsumptionRequested is $false when -SkipConsumption was passed, which
        # makes a zero record count expected rather than a problem.
        [int]$ConsumptionRecordCount = 0,
        [bool]$ConsumptionRequested = $true,
        [switch]$Obfuscated
    )

    try
    {
        # Real-value -> token scrub map for the free-text failure messages. The
        # four core dictionaries are keyed by the real ARM RESOURCE ID (value =
        # token), so derive the bare resource NAME (last path segment), RG name
        # and subscription GUID from those keys and map each to the matching
        # token - otherwise a bare name/RG/sub-GUID in an exception message would
        # NOT be tokenized (only a full ARM path would). Tag values and free-text
        # values are already real-value-keyed. Empty in a default run (no
        # dictionaries), leaving Protect-DiagnosticText's class masking to act.
        $DiagScrubMap = @{}
        if ($null -ne $Global:ResourceIdDictionary)
        {
            foreach ($realId in $Global:ResourceIdDictionary.Keys)
            {
                if ([string]::IsNullOrEmpty($realId)) { continue }
                if (-not $DiagScrubMap.ContainsKey($realId)) { $DiagScrubMap[$realId] = $Global:ResourceIdDictionary[$realId] }

                $ShortName = ($realId -split '/')[-1]
                if (-not [string]::IsNullOrEmpty($ShortName) -and $null -ne $Global:ResourceNameDictionary -and $Global:ResourceNameDictionary.ContainsKey($realId) -and -not $DiagScrubMap.ContainsKey($ShortName))
                {
                    $DiagScrubMap[$ShortName] = $Global:ResourceNameDictionary[$realId]
                }
                if ($realId -match '(?i)/resourceGroups/([^/]+)')
                {
                    $RgName = $Matches[1]
                    if (-not [string]::IsNullOrEmpty($RgName) -and $null -ne $Global:ResourceResourceGroupDictionary -and $Global:ResourceResourceGroupDictionary.ContainsKey($realId) -and -not $DiagScrubMap.ContainsKey($RgName))
                    {
                        $DiagScrubMap[$RgName] = $Global:ResourceResourceGroupDictionary[$realId]
                    }
                }
                if ($realId -match '(?i)/subscriptions/([^/]+)')
                {
                    $SubGuid = $Matches[1]
                    if (-not [string]::IsNullOrEmpty($SubGuid) -and $null -ne $Global:ResourceSubscriptionDictionary -and $Global:ResourceSubscriptionDictionary.ContainsKey($realId) -and -not $DiagScrubMap.ContainsKey($SubGuid))
                    {
                        $DiagScrubMap[$SubGuid] = $Global:ResourceSubscriptionDictionary[$realId]
                    }
                }
            }
        }
        if ($null -ne $Global:TagValueDictionary)
        {
            foreach ($tagReal in $Global:TagValueDictionary.Keys) { if (-not [string]::IsNullOrEmpty($tagReal) -and -not $DiagScrubMap.ContainsKey($tagReal)) { $DiagScrubMap[$tagReal] = $Global:TagValueDictionary[$tagReal] } }
        }
        if ($null -ne $Global:FreeTextDictionary)
        {
            foreach ($ftReal in $Global:FreeTextDictionary.Keys) { if (-not [string]::IsNullOrEmpty($ftReal) -and -not $DiagScrubMap.ContainsKey($ftReal)) { $DiagScrubMap[$ftReal] = $Global:FreeTextDictionary[$ftReal] } }
        }

        # Phase durations rendered as "Nmin SS sec" (zero-padded seconds), e.g.
        # 245.3s -> "4min 05 sec". Kept as pre-formatted strings so the emit
        # below just prints them.
        $PhaseTimingsText = [ordered]@{}
        if ($null -ne $PhaseTimings)
        {
            foreach ($PhaseName in $PhaseTimings.Keys)
            {
                $PhaseTotalSec = [int][math]::Round(([TimeSpan]$PhaseTimings[$PhaseName]).TotalSeconds)
                $PhaseTimingsText[$PhaseName] = ('{0}min {1:D2} sec' -f [int][math]::Floor($PhaseTotalSec / 60), ($PhaseTotalSec % 60))
            }
        }

        # Health globals. Where-Object { $null -ne $_ } guards the standalone-run
        # case: these are only nil-initialized by the wrapper, so in a direct
        # ResourceInventory.ps1 run they can be $null, and @($null) is a ONE-element
        # array (the single $null) that would otherwise render a phantom "failure"
        # line. Filtering nulls yields a genuine "0" when there were none.
        $CollectorFails = @(@($Global:CollectorFailures) | Where-Object { $null -ne $_ })
        $MetricsSkips = @(@($Global:MetricsFailedSubs) | Where-Object { $null -ne $_ })
        $ConsumpSkips = @(@($Global:ConsumptionFailedSubs) | Where-Object { $null -ne $_ })

        $DiagLines = [System.Collections.Generic.List[string]]::new()
        if ($Obfuscated)
        {
            $DiagLines.Add('Resource Discovery for Azure - shareable diagnostics (obfuscated run)')
            $DiagLines.Add('Safe to share: identifiers are obfuscated/masked. Human-readable')
            $DiagLines.Add('troubleshooting log - NOT report data, do not ingest into tables.')
        }
        else
        {
            $DiagLines.Add('Resource Discovery for Azure - diagnostics (default/non-obfuscated run)')
            $DiagLines.Add('NOTE: this bundle is NOT obfuscated - the report itself contains real')
            $DiagLines.Add('identifiers. This log masks GUIDs/emails but treat the whole bundle as')
            $DiagLines.Add('sensitive. Human-readable troubleshooting log - NOT report data, do not')
            $DiagLines.Add('ingest into tables.')
        }
        $DiagLines.Add(('Generated (UTC) : {0}' -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')))
        $DiagLines.Add(('Tool version    : {0}' -f [string]$Version))
        $DiagLines.Add('')
        $DiagLines.Add('Phase timings:')
        if ($PhaseTimingsText.Count -gt 0)
        {
            foreach ($PhaseName in $PhaseTimingsText.Keys) { $DiagLines.Add(('  {0}: {1}' -f $PhaseName, $PhaseTimingsText[$PhaseName])) }
        }
        else
        {
            $DiagLines.Add('  (none recorded)')
        }
        $DiagLines.Add('')
        $DiagLines.Add(('Collector failures: {0}' -f $CollectorFails.Count))
        foreach ($cfItem in $CollectorFails)
        {
            $DiagLines.Add(('  [sub {0}] {1}: {2}' -f (Protect-DiagnosticText ([string]$cfItem.Id) $DiagScrubMap), [string]$cfItem.Module, (Protect-DiagnosticText ([string]$cfItem.Message) $DiagScrubMap)))
        }
        $DiagLines.Add('')
        $DiagLines.Add(('Metrics auth-skipped subscriptions: {0}' -f $MetricsSkips.Count))
        foreach ($msItem in $MetricsSkips)
        {
            $DiagLines.Add(('  [sub {0}] {1}' -f (Protect-DiagnosticText ([string]$msItem.Id) $DiagScrubMap), (Protect-DiagnosticText ([string]$msItem.Message) $DiagScrubMap)))
        }
        $DiagLines.Add('')
        $DiagLines.Add(('Consumption failed/incomplete subscriptions: {0}' -f $ConsumpSkips.Count))
        foreach ($csItem in $ConsumpSkips)
        {
            $DiagLines.Add(('  [sub {0}] {1}' -f (Protect-DiagnosticText ([string]$csItem.Id) $DiagScrubMap), (Protect-DiagnosticText ([string]$csItem.Message) $DiagScrubMap)))
        }

        # Consumption OUTCOME, not just its failures. A header-only Consumption CSV
        # was previously invisible here: the failure count read 0 (no exception was
        # raised) and the record count was not reported at all, so the shareable
        # log looked healthy while the billing data the operator asked for was
        # missing. The record count is a plain integer - no identifier - so it is
        # safe in an obfuscated bundle, which is the bundle we normally receive.
        $DiagLines.Add('')
        if ($ConsumptionRequested)
        {
            $DiagLines.Add(('Consumption records collected: {0}' -f $ConsumptionRecordCount))
        }
        else
        {
            $DiagLines.Add('Consumption records collected: n/a (-SkipConsumption was passed)')
        }

        # The silent-failure signature: requested, no per-subscription failure
        # recorded, and yet nothing came back. The up-front access gate cannot
        # catch this - Test-ConsumptionAccess classifies the billing probe's
        # EXCEPTION text and an empty-but-successful response raises none - so
        # this is the only place the shared bundle can carry the signal.
        if ($ConsumptionRequested -and $ConsumptionRecordCount -eq 0 -and $ConsumpSkips.Count -eq 0)
        {
            $DiagLines.Add('  WARNING - consumption was requested but ZERO usage records were collected,')
            $DiagLines.Add('  and no subscription reported a billing error. The billing API answered')
            $DiagLines.Add('  successfully with no rows, so the Consumption CSV holds only its header.')
            $DiagLines.Add('  Expected ONLY if there is genuinely no usage in the queried window (the 30')
            $DiagLines.Add('  days ending at midnight yesterday, host local time). Otherwise the usual causes are:')
            $DiagLines.Add('    - CSP / Partner-managed subscription with the partner cost visibility')
            $DiagLines.Add('      policy OFF (the default). Billing scope on CSP subscriptions is not')
            $DiagLines.Add('      governed by Azure RBAC, so granting Cost Management Reader does not')
            $DiagLines.Add('      help - the partner must enable it in Partner Center.')
            $DiagLines.Add('    - Subscription not transitioned to the Azure plan.')
            $DiagLines.Add('    - A subscription offer the legacy usage API does not serve.')
        }

        $DiagnosticsFile = ($DefaultPath + "Diagnostics_" + $ReportName + "_" + $RunDateTime + ".log")
        ($DiagLines -join [Environment]::NewLine) | Out-File -FilePath $DiagnosticsFile -Encoding utf8
        Write-Log -Message ('Shareable diagnostics log written: {0}' -f (Split-Path -Path $DiagnosticsFile -Leaf)) -Severity 'Info'
        return $DiagnosticsFile
    }
    catch
    {
        Write-Log -Message ('Could not build/write shareable diagnostics log: {0}' -f $_.Exception.Message) -Severity 'Warning'
        return $null
    }
}



# Best-effort extraction of a SERVER-DIRECTED retry delay (seconds) from a failed
# Azure cmdlet's error, so a throttled caller waits EXACTLY as long as the service
# asks instead of guessing with blind exponential backoff.
#
# Azure's Cost Management / Consumption throttle emits the wait time on a 429 via
# the 'x-ms-ratelimit-microsoft.consumption-retry-after' header (and ARM generally
# via the standard 'Retry-After'). Get-UsageAggregates (alias -> Get-AzUsageAggregate,
# Az.Billing) surfaces the failure as a Microsoft.Rest.Azure.CloudException whose
# .Response.Headers is an IDictionary[string, IEnumerable[string]] (verified against
# the loaded Az.Billing module), so the header is readable straight off the thrown
# ErrorRecord. Honoring it is strictly better than blind backoff: it avoids both
# retrying too early (burning a retry, earning another 429) and waiting far longer
# than the service actually needs.
#
# Header value is per RFC 7231: delta-seconds (an integer) or an HTTP-date. The
# consumption header is delta-seconds; both forms are handled. Returns the delay in
# seconds (>= 0) when a usable header is found, otherwise 0 - the caller then falls
# back to its own backoff. NEVER throws: a diagnostics aid must not itself break the
# retry loop, so every access is guarded and any oddity degrades to 0.
function Get-RdaRetryAfterSeconds
{
    param(
        [Parameter(Mandatory = $true)]$ErrorRecord
    )

    # Priority order: the consumption/billing-specific header first (that is what
    # the Cost Management throttle emits), then the standard HTTP Retry-After.
    $HeaderNames = @('x-ms-ratelimit-microsoft.consumption-retry-after', 'Retry-After')

    try
    {
        # PowerShell may surface the CloudException directly as .Exception or nested
        # under one or more .InnerException levels; walk the chain (bounded).
        $Ex = if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { $ErrorRecord.Exception } else { $ErrorRecord }
        $Depth = 0
        while ($null -ne $Ex -and $Depth -lt 5)
        {
            $Headers = $null
            $ResponseProp = $Ex.PSObject.Properties['Response']
            if ($ResponseProp -and $null -ne $ResponseProp.Value)
            {
                $HeadersProp = $ResponseProp.Value.PSObject.Properties['Headers']
                if ($HeadersProp) { $Headers = $HeadersProp.Value }
            }

            if ($null -ne $Headers -and $Headers.Keys)
            {
                foreach ($Name in $HeaderNames)
                {
                    # Case-insensitive lookup: HTTP header names are
                    # case-insensitive, but the underlying dictionary is ordinal.
                    $Raw = $null
                    foreach ($Key in $Headers.Keys)
                    {
                        if ($Key -and $Key.Equals($Name, [System.StringComparison]::OrdinalIgnoreCase))
                        {
                            $Raw = @($Headers[$Key])[0]
                            break
                        }
                    }
                    if ([string]::IsNullOrWhiteSpace($Raw)) { continue }

                    $Raw = ([string]$Raw).Trim()

                    # delta-seconds form (what the consumption header uses).
                    $Seconds = 0
                    if ([int]::TryParse($Raw, [ref]$Seconds))
                    {
                        if ($Seconds -lt 0) { $Seconds = 0 }
                        return $Seconds
                    }

                    # HTTP-date form: wait until that instant. Parse with the
                    # invariant culture and AssumeUniversal - RFC 7231 HTTP-dates are
                    # English/GMT, so a non-English-culture host must not fail to parse
                    # them (which would silently degrade to blind backoff).
                    $When = [datetimeoffset]::MinValue
                    if ([datetimeoffset]::TryParse($Raw, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$When))
                    {
                        $Delta = [int][math]::Ceiling(($When - [datetimeoffset]::UtcNow).TotalSeconds)
                        if ($Delta -lt 0) { $Delta = 0 }
                        return $Delta
                    }
                }
            }

            $Ex = $Ex.InnerException
            $Depth++
        }
    }
    catch
    {
        # Best-effort only - fall through to 0 so the caller uses its own backoff.
    }

    return 0
}
