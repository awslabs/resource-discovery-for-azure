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
        exit 1
    }

    $VersionJsonPath = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Version.json'

    if (-not (Test-Path -LiteralPath $VersionJsonPath -PathType Leaf))
    {
        Write-Host ("Version.json not found at '{0}' (expected at the repo root, alongside ResourceInventory.ps1). Ensure the full repo is present. Exiting." -f $VersionJsonPath) -ForegroundColor Red
        exit 1
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
        exit 1
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
function Global:Protect-FreeTextValue([string]$Value)
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
function Global:Protect-DiagnosticText([string]$Text, [System.Collections.IDictionary]$ValueMap)
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
# boundary, which is why a module cmdlet is preferred over an external CLI for any
# new call on this path.
# Classify a Resource Graph failure from the exception's STRUCTURED surface rather
# than by matching its message text.
#
# This matters because the native cmdlet's .Message carries no detail at all - a
# malformed query, a denied subscription and an oversized response all surface as
# the same generic line:
#     Operation returned an invalid status code 'BadRequest'
# The actual reason lives in the typed body
# (Microsoft.Azure.Management.ResourceGraph.Models.ErrorResponse):
#     $Exception.Body.Error.Code            -> 'BadRequest'
#     $Exception.Body.Error.Details[].Code  -> 'ResponsePayloadTooLarge', 'InvalidQuery', ...
#     $Exception.Response.StatusCode        -> 400
# so keying on codes and HTTP status is both precise and stable across service
# message wording, SDK versions and locales.
#
# Text matching is kept ONLY as a last-resort fallback, for failures that carry no
# structured body at all (a socket/DNS/TLS error is a plain exception, not an
# ErrorResponseException). Never throws: a classifier that fails cannot be allowed
# to mask the failure it was asked to describe.
function Get-AzGraphErrorInfo
{
    param($Exception)

    $Info = [pscustomobject]@{
        Codes               = @()
        HttpStatus          = 0
        Message             = ''
        HasStructuredBody   = $false
        IsPayloadTooLarge   = $false
        IsThrottled         = $false
        IsPermanent         = $false
        # A CLIENT-SIDE materialization failure caused by a resource whose JSON
        # carries an object key that is the EMPTY STRING. NOT a service error and
        # NOT permanent in the "give up" sense: the caller recovers it by
        # re-fetching the same window via the raw ARM REST path and renaming empty
        # keys before parsing. Kept as its own flag so the caller can route it to
        # that fallback instead of failing the whole subscription.
        IsEmptyPropertyName = $false
    }
    if ($null -eq $Exception) { return $Info }

    try { $Info.Message = [string]$Exception.Message } catch { $Info.Message = '' }

    # Walk the exception chain: the SDK sometimes wraps the typed exception.
    $Codes = New-Object System.Collections.Generic.List[string]
    $Node = $Exception
    $Depth = 0
    while ($null -ne $Node -and $Depth -lt 5)
    {
        try
        {
            $Err = $Node.Body.Error
            if ($null -ne $Err)
            {
                $Info.HasStructuredBody = $true
                if ($Err.Code) { $Codes.Add([string]$Err.Code) }
                foreach ($Detail in @($Err.Details))
                {
                    if ($Detail -and $Detail.Code) { $Codes.Add([string]$Detail.Code) }
                }
            }
        }
        catch { }
        if ($Info.HttpStatus -eq 0)
        {
            try
            {
                if ($null -ne $Node.Response -and $null -ne $Node.Response.StatusCode)
                {
                    $Info.HttpStatus = [int]$Node.Response.StatusCode
                }
            }
            catch { }
        }
        try { $Node = $Node.InnerException } catch { $Node = $null }
        $Depth++
    }
    $Info.Codes = @($Codes | Select-Object -Unique)

    $HasCode = {
        param([string]$Name)
        foreach ($C in $Info.Codes) { if ($C -and $C.Equals($Name, [System.StringComparison]::OrdinalIgnoreCase)) { return $true } }
        return $false
    }

    # Oversized response. Checked first and independently of the 400 status it
    # arrives with, because it is the one 400 that a smaller request CAN satisfy.
    $Info.IsPayloadTooLarge = (& $HasCode 'ResponsePayloadTooLarge')

    # Throttling: HTTP 429, or the service's own code.
    $Info.IsThrottled = ($Info.HttpStatus -eq 429) -or (& $HasCode 'TooManyRequests') -or (& $HasCode 'ThrottledRequest')

    # Permanent: a 4xx that retrying cannot fix. 408 (timeout) and 429 are
    # deliberately excluded - both are worth another attempt.
    if (-not $Info.IsPayloadTooLarge -and -not $Info.IsThrottled)
    {
        $Permanent4xx = ($Info.HttpStatus -ge 400 -and $Info.HttpStatus -lt 500 -and $Info.HttpStatus -ne 408 -and $Info.HttpStatus -ne 429)
        $PermanentCode = (& $HasCode 'AuthorizationFailed') -or (& $HasCode 'Forbidden') -or (& $HasCode 'InvalidQuery') -or
        (& $HasCode 'SemanticError') -or (& $HasCode 'SyntaxError') -or (& $HasCode 'ParserFailure') -or
        (& $HasCode 'BadRequest') -or (& $HasCode 'InvalidAuthenticationToken')
        $Info.IsPermanent = ($Permanent4xx -or $PermanentCode)
    }

    # Fallback for failures with no structured body (network-level errors), and for
    # any SDK shape this does not recognise. Only consulted when the structured
    # surface yielded nothing, so normal service errors never depend on wording.
    if (-not $Info.HasStructuredBody -and $Info.HttpStatus -eq 0)
    {
        $Text = $Info.Message
        if ($Text -match 'ResponsePayloadTooLarge|Response payload size is \d+, exceeded the limit') { $Info.IsPayloadTooLarge = $true }
        elseif ($Text -match 'TooManyRequests|\b429\b|throttl') { $Info.IsThrottled = $true }
        # CLIENT-SIDE row materialization failure, not a service error, so retrying is
        # certain to fail identically - a real shard run burned all 31 attempts on one
        # before losing the whole subscription. A resource whose JSON carries an
        # object key that is the EMPTY STRING cannot become a PSObject property:
        # Search-AzGraph's conversion throws from the PSNoteProperty constructor
        # ('the value of argument "name" is not valid'), and ConvertFrom-Json refuses
        # the same payload ('property whose name is an empty string'). Deterministic
        # per resource, so fail fast and name the cause instead of backing off.
        elseif ($Text -match 'the value of argument "name" is not valid|property whose name is an empty string')
        {
            # A resource whose JSON carries an object key that is the EMPTY STRING
            # cannot become a PSObject property: Search-AzGraph's conversion throws
            # from the PSNoteProperty constructor ('the value of argument "name" is
            # not valid'), and ConvertFrom-Json refuses the same payload ('property
            # whose name is an empty string'). It is user-authored JSON (a Logic App
            # / policy / template definition is the usual holder), so it is
            # deterministic per resource and retrying the identical Search-AzGraph
            # call is futile. It is NOT marked IsPermanent: the caller recovers the
            # window via the raw ARM REST path, which returns a JSON STRING whose
            # empty keys are renamed to a sentinel BEFORE parsing, so the resource
            # is CAPTURED rather than the whole subscription being lost.
            $Info.IsEmptyPropertyName = $true
        }
        elseif ($Text -match 'AuthorizationFailed|does not have authorization|\bForbidden\b|\bBadRequest\b|SemanticError|SyntaxError|InvalidQuery|Please provide a valid') { $Info.IsPermanent = $true }
    }

    return $Info
}

# The sentinel an empty-string JSON property name is renamed to when a resource is
# recovered via the raw-REST fallback. An empty key cannot survive PowerShell
# object materialization (PSNoteProperty rejects it) or ConvertFrom-Json, so it is
# renamed rather than dropped - the value is preserved under a stable, greppable
# name. Chosen to be collision-proof: no real Azure property is named this. NOTE
# for downstream/server ingestion: this key can appear anywhere inside a resource's
# free-form 'properties' bag in Inventory_*.json; it is inert (no collector reads
# it) and marks a resource whose original JSON had an unnamed property.
$Script:RdaEmptyPropertyNameSentinel = '_rda_emptykey'

# Recover ONE window that Search-AzGraph could not materialize because a resource
# in it has a JSON object key that is the EMPTY STRING (see Get-AzGraphErrorInfo's
# IsEmptyPropertyName). Fetches the SAME query/window via the raw Resource Graph
# REST endpoint, which returns a JSON STRING; the empty keys are renamed to
# $Script:RdaEmptyPropertyNameSentinel in that string BEFORE any ConvertFrom-Json,
# so neither PSNoteProperty nor ConvertFrom-Json ever sees an empty name and the
# resource is CAPTURED intact rather than the subscription being lost.
#
# Uses Invoke-AzRestMethod (the house pattern - portable by construction, no `az`
# CLI). Throws on failure so the caller's existing failure handling still applies
# if the fallback itself cannot complete.
function Get-AzGraphRowsViaRest
{
    param(
        [Parameter(Mandatory = $true)][string]$Query,
        [string[]]$Subscription,
        [int]$First = 1000,
        [int]$Skip = 0
    )

    $Body = @{
        query   = $Query
        options = @{
            '$top'  = $First
            '$skip' = $Skip
        }
    }
    # Scope to the given subscriptions when supplied; omitting it queries the whole
    # accessible tenant, matching Search-AzGraph's -Subscription semantics.
    if ($Subscription) { $Body['subscriptions'] = @($Subscription) }

    $Payload = $Body | ConvertTo-Json -Depth 10
    $Response = Invoke-AzRestMethod -Method POST `
        -Path '/providers/Microsoft.ResourceGraph/resources?api-version=2021-03-01' `
        -Payload $Payload -ErrorAction Stop

    $Status = [int]$Response.StatusCode
    if ($Status -lt 200 -or $Status -ge 300)
    {
        # Include only a bounded slice of the response body in the thrown message.
        # The body is enough to diagnose an ARG REST rejection, but the full
        # payload is an unbounded free-text surface; cap it so the failure message
        # (which flows into the shareable diagnostics log, scrubbed) stays small.
        $Detail = [string]$Response.Content
        if ($Detail.Length -gt 500) { $Detail = $Detail.Substring(0, 500) + '...(truncated)' }
        throw ("Resource Graph REST fallback returned HTTP {0}: {1}" -f $Status, $Detail)
    }

    # Rename EMPTY-STRING JSON keys to the sentinel in the raw response TEXT, before
    # parsing. A JSON object key is a quoted string immediately followed by a colon;
    # an empty key is the literal "" in key position. Matching "" that is followed
    # by optional whitespace and a colon targets keys without touching empty string
    # VALUES (a value is preceded by a colon or a comma/bracket, never itself in key
    # position). The replace runs on the response string so the empty name is gone
    # before ConvertFrom-Json, which would otherwise reject it identically.
    $Sanitized = [regex]::Replace(
        $Response.Content,
        '(?<=[{,]\s*)""(?=\s*:)',
        ('"' + $Script:RdaEmptyPropertyNameSentinel + '"'))

    $Parsed = $Sanitized | ConvertFrom-Json
    # The ARG REST response wraps rows in a 'data' array (the SDK's .Data). Return
    # the flat row array so the caller can treat it exactly like Search-AzGraph output.
    if ($null -ne $Parsed -and $Parsed.PSObject.Properties.Name -contains 'data')
    {
        return @($Parsed.data)
    }
    return @()
}

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
    $Failure = $null
    $AttemptsMade = 0

    for ($Attempt = 0; ; $Attempt++)
    {
        $AttemptsMade = $Attempt + 1
        try
        {
            # The intermediate $Response variable is REQUIRED - do not inline this
            # back to @(Search-AzGraph @GraphParams).
            #
            # Search-AzGraph writes ONE PSResourceGraphResponse object to the
            # pipeline (it does not stream rows), so @(command) collects a 1-element
            # array WRAPPING the response instead of the rows. Assigning first and
            # then using @($variable) enumerates the response's IEnumerable, giving
            # the flat row array every caller and this function's own accumulation
            # logic assume.
            #
            # @($Response) rather than @($Response.Data) deliberately: it is correct
            # for BOTH shapes - a single enumerable response object AND N streamed
            # rows - so it survives an SDK output-shape change, and it also handles
            # the plain array the test mocks return. Live behaviour confirmed on
            # Az.ResourceGraph 1.2.1. Trade-off to know: if the response type ever
            # stops being IEnumerable, @() re-wraps SILENTLY (this same bug),
            # whereas .Data would break loudly.
            #
            # The null guard matters: @($null) is a ONE-element array CONTAINING
            # $null, so on no output at all this would inject a phantom row that
            # flows through Get-AzGraphRowWindow into $Global:Resources and inflates
            # the resource count. The old @(command) form yielded @() there.
            #
            # This is not cosmetic. With the wrapped form, a 16 MB payload split in
            # Get-AzGraphRowWindow accumulated N response objects, and the
            # -Lowercase ConvertTo-Json round-trip then produced N NESTED arrays
            # rather than one flat row set - so $Global:Resources received arrays
            # instead of resources and every resource in the split window silently
            # vanished from the report. Verified against real responses; the unit
            # tests could not see it because their mock returns a plain array.
            $Response = Search-AzGraph @GraphParams
            $Rows = if ($null -eq $Response) { @() } else { @($Response) }
            $FailureMessage = $null
            $Failure = $null
            break
        }
        catch
        {
            # Classify from the exception's structured body / HTTP status, not from
            # its message text - the native cmdlet's message is the same generic
            # line for every 400. See Get-AzGraphErrorInfo.
            $ErrorInfo = Get-AzGraphErrorInfo -Exception $_.Exception
            $Message = $ErrorInfo.Message
            $CodeText = if ($ErrorInfo.Codes.Count -gt 0) { ' [' + ($ErrorInfo.Codes -join ', ') + ']' } else { '' }

            # An oversized response is neither "give up" nor "retry the same thing":
            # a SMALLER request can satisfy it, and only the window splitter can act
            # on that. Hand it straight up, still classified.
            if ($ErrorInfo.IsPayloadTooLarge)
            {
                $Failure = $ErrorInfo
                break
            }

            # A resource in this window has an EMPTY-STRING JSON property name, which
            # Search-AzGraph cannot materialize (PSNoteProperty). Retrying the same
            # call is futile - but the data is fine on the service side, so recover
            # the SAME window via the raw REST path, which renames empty keys to a
            # sentinel before parsing. The resource is CAPTURED, not dropped, and the
            # subscription completes. If the REST fallback ITSELF fails, fall through
            # to the normal failure handling (treat as permanent) rather than looping.
            if ($ErrorInfo.IsEmptyPropertyName)
            {
                try
                {
                    $Rows = @(Get-AzGraphRowsViaRest -Query $Query -Subscription $Subscription -First $First -Skip $Skip)
                    $FailureMessage = $null
                    $Failure = $null
                    Write-Log -Message ("Recovered {0} row(s) at offset {1} via the raw Resource Graph REST path after an empty-property-name materialization error; empty JSON keys were renamed to '{2}'. The resource(s) were captured, not dropped." -f $Rows.Count, $Skip, $Script:RdaEmptyPropertyNameSentinel) -Severity 'Warning'
                    break
                }
                catch
                {
                    $RestInfo = Get-AzGraphErrorInfo -Exception $_.Exception
                    $Failure = $RestInfo
                    $FailureMessage = ("Resource Graph empty-property-name recovery via REST failed at offset {0}: {1}`nQuery: {2}" -f $Skip, $RestInfo.Message, $Query)
                    break
                }
            }

            # Clearly-permanent failures: a retry cannot help, so stop now rather
            # than burning the whole backoff budget on an error retrying cannot fix.
            if ($ErrorInfo.IsPermanent -or $Attempt -ge $GraphMaxRetries)
            {
                $Failure = $ErrorInfo
                $FailureMessage = ("Resource Graph query failed after {0} attempt(s): {1}{2}`nQuery: {3}" -f $AttemptsMade, $Message, $CodeText, $Query)
                break
            }

            # Transient: exponential backoff (2^attempt, capped) plus jitter so a
            # wave of throttled calls does not retry in lockstep. Throttled calls
            # wait a bit longer.
            $Throttled = $ErrorInfo.IsThrottled
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

    # A structured result rather than a throw, so the window splitter can read the
    # CLASSIFICATION (IsPayloadTooLarge) directly instead of re-deriving it from a
    # message.
    #
    # The property callers rely on: on SUCCESS Rows is never $null - an empty array
    # is the floor - and Rows is $null exactly when Failure is set. Success is the
    # only path that assigns Rows, and it breaks immediately, so the three failure
    # exits (payload-too-large, permanent, retry-exhausted) all leave it $null.
    return [pscustomobject]@{
        Rows           = $Rows
        Failure        = $Failure
        FailureMessage = $FailureMessage
        Attempts       = $AttemptsMade
    }
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

    # Loop control here is explicit for the SAME reason as in Invoke-AzGraphRequest:
    # a `throw` is not a reliable exit under 'SilentlyContinue'. Using one here would
    # let execution fall through into the split branch on a NON-payload failure,
    # splitting forever - which is exactly the unbounded behaviour this whole change
    # exists to remove. Every fatal path sets $FatalMessage and breaks; the throw
    # happens once, after the loop.
    $FatalMessage = $null

    while ($Pending.Count -gt 0)
    {
        $Window = $Pending.Pop()
        $Result = Invoke-AzGraphRequest -Query $Query -Subscription $Subscription -First $Window.First -Skip $Window.Skip

        if ($null -eq $Result.Failure)
        {
            $Rows += @($Result.Rows)
            continue
        }

        $Message = $Result.Failure.Message

        if (-not $Result.Failure.IsPayloadTooLarge)
        {
            # Anything else is the caller's problem, with the request helper's own
            # message (which already carries the attempt count and the codes).
            $FatalMessage = $Result.FailureMessage
            break
        }

        # Only an ordered query may be split - see the note above.
        if ($Query -notmatch 'order\s+by')
        {
            $FatalMessage = ("Resource Graph refused the response as too large and the query is not ordered, so it cannot be split safely. Add an 'order by' clause to page it.`n{0}`nQuery: {1}" -f $Message, $Query)
            break
        }

        if ($Window.First -le 1)
        {
            $FatalMessage = ("Resource Graph refused a SINGLE resource as too large (offset {0}); it exceeds the 16 MB response cap and cannot be retrieved. Exclude this resource type from the discovery query to complete the run.`n{1}" -f $Window.Skip, $Message)
            break
        }

        $LeftCount = [math]::Floor($Window.First / 2)
        $RightCount = $Window.First - $LeftCount
        $Pending.Push([pscustomobject]@{ Skip = ($Window.Skip + $LeftCount); First = $RightCount })
        $Pending.Push([pscustomobject]@{ Skip = $Window.Skip; First = $LeftCount })
        $SplitCount++
        Write-Log -Message ("Resource Graph response too large at offset {0} for {1} rows; retrying as {2} + {3}." -f $Window.Skip, $Window.First, $LeftCount, $RightCount) -Severity 'Warning'
    }

    if ($null -ne $FatalMessage) { throw $FatalMessage }

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
    # a lowercase .data member - the row array for a fetch, or the single row for
    # a 'summarize count()' probe (so $x.data.count_ keeps working). The lowercase
    # spelling deliberately mirrors the ARM REST API's own JSON key; it is NOT the
    # Az SDK's PascalCase PSResourceGraphResponse.Data.
    #
    # .data is ALWAYS a flat array of row objects, independent of -Lowercase. That
    # flattening happens once, at the boundary in Invoke-AzGraphRequest, so
    # @($x.data).Count is always the row count and -Lowercase controls ONLY casing.
    # It used to be the ConvertTo-Json round-trip below that incidentally flattened
    # the response, which meant the shape silently depended on -Lowercase and a
    # payload split corrupted the row set - see the note in Invoke-AzGraphRequest.
    #
    # Paging is
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
    #
    # ToLowerInvariant(), NOT ToLower(): ToLower() is culture-sensitive, so on a
    # tr-TR / az-AZ host it maps 'I' to the dotless 'i' and would corrupt JSON KEYS
    # as well as values - 'subscriptionId' becomes unreadable to every collector.
    # This file already uses invariant casing elsewhere for the same reason.
    if ($Lowercase -and $Rows.Count -gt 0)
    {
        # Defense in depth for the empty-property-name case: the REST fallback in
        # Get-AzGraphRowsViaRest already renamed empty JSON keys to the sentinel, so
        # rows reaching here should carry none. But ConvertFrom-Json rejects an
        # empty property name identically to Search-AzGraph, so if one ever survived
        # (an SDK shape this path did not sanitize), the round-trip below would
        # re-throw and lose the window. Rename any empty key in the serialized TEXT
        # to the sentinel before parsing - same targeted key-position match as the
        # REST helper - so this round-trip can never be the thing that drops a
        # resource. On the normal path (no empty keys) the regex matches nothing and
        # behaviour is byte-for-byte unchanged.
        $Json = ($Rows | ConvertTo-Json -Depth 100).ToLowerInvariant()
        $Json = [regex]::Replace($Json, '(?<=[{,]\s*)""(?=\s*:)', ('"' + $Script:RdaEmptyPropertyNameSentinel + '"'))
        $Rows = @($Json | ConvertFrom-Json)
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
        # Metric-query outcome for THIS run, on the same contract as the consumption
        # pair above: passed in rather than read from $Global:MetricsApiCallCount so
        # the builder stays self-contained and unit-testable offline, AND so the
        # caller can hand over a per-subscription figure instead of that global's
        # run-cumulative one. $MetricsRequested is $false when -SkipMetrics was
        # passed, which makes a zero call count expected rather than a problem.
        [int]$MetricsApiCallCount = 0,
        [bool]$MetricsRequested = $true,
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
        # InvariantCulture: Diagnostics_*.log ships in BOTH packaging branches, including
        # the obfuscated bundle, so this is the timestamp a report consumer actually reads.
        # See Functions/AllSubHtmlSummary.Functions.ps1:313-318 for why a missing provider
        # is a defect rather than a style choice.
        $DiagLines.Add(('Generated (UTC) : {0}' -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [cultureinfo]::InvariantCulture)))
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
        #
        # The n/a is gated on a ZERO count, not on the skip flag alone. Records
        # arriving from a phase that was supposed to be skipped is a contradiction,
        # and printing 'n/a' over a non-zero figure would hide exactly the anomaly
        # worth seeing - so that case falls through to the numeric form.
        #
        # Get-RunSummaryLogContent in Functions/RunAllSubscriptions.Functions.ps1
        # now receives the SAME -ConsumptionRequested boolean and applies the same
        # gate, so the two builders derive this fact identically instead of one of
        # them re-deriving it from the wrapper's bound parameters. The two lines
        # ship in the SAME bundle and must never disagree about whether data is
        # missing, so a cross-surface Pester assertion pins the shared phrase.
        $DiagLines.Add('')
        if ($ConsumptionRequested -or $ConsumptionRecordCount -ne 0)
        {
            # N0 + InvariantCulture to match the RunSummary.log Health line exactly.
            # This figure SHIPS in the bundle, and the same count rendered grouped in
            # one artifact and ungrouped in the other reads as a formatting bug in
            # whichever one the reader looked at second.
            $DiagLines.Add(('Consumption records collected: {0}' -f $ConsumptionRecordCount.ToString('N0', [cultureinfo]::InvariantCulture)))
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

        # Metric-query counterpart to the consumption count above, and it exists for the
        # same reason. A -SkipMetrics run previously left NO trace of the metrics phase
        # in this shareable log: the auth-skipped count read 0 (nothing failed - the
        # phase never ran) and the call count was not reported at all, so the log looked
        # healthy while the metric data the operator asked for was simply absent. The
        # count is a plain integer, no identifier, so it is safe in an obfuscated bundle.
        #
        # Deliberately matches the consumption block in three ways, because the two
        # figures ship in the same log and any divergence reads as a bug in whichever the
        # reader saw second: the same gate SHAPE (n/a only when the phase was not
        # requested AND the count is zero, so calls arriving from a supposedly skipped
        # phase fall through to the numeric form rather than being hidden behind 'n/a'),
        # the same N0 + InvariantCulture formatting, and a label matching the RunSummary
        # Health block's 'Metric-query API calls issued' verbatim so a reader comparing
        # the two artifacts never has to work out whether two labels mean one thing.
        #
        # Placed AFTER the consumption warning, not between it and its count. That
        # warning has no leading blank line and is two-space indented because it is a
        # hanging continuation of 'Consumption records collected'; splitting the pair
        # made a shipped log read 'Metric-query API calls issued: 34' followed by an
        # indented 'WARNING - consumption was requested but ZERO usage records...',
        # which scans as a METRICS warning.
        $DiagLines.Add('')
        if ($MetricsRequested -or ($MetricsApiCallCount -ne 0))
        {
            $DiagLines.Add(('Metric-query API calls issued: {0}' -f $MetricsApiCallCount.ToString('N0', [cultureinfo]::InvariantCulture)))
        }
        else
        {
            $DiagLines.Add('Metric-query API calls issued: n/a (-SkipMetrics was passed)')
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
