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
    $VersionJsonPath = "./Version.json"
    if (Test-Path $VersionJsonPath)
    {
        $LocalVersionJson = Get-Content $VersionJsonPath | ConvertFrom-Json
        return ('{0}.{1}.{2}' -f $LocalVersionJson.MajorVersion, $LocalVersionJson.MinorVersion, $LocalVersionJson.BuildVersion)
    }
    else
    {
        Write-Host "Local Version.json not found. Clone the repo and execute the script from the root. Exiting." -ForegroundColor Red
        Exit
    }
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

# Resource Graph (the inventory's data path) through Invoke-AzRestMethod, so
# the tool needs only the Az PowerShell modules it already loads: no Azure CLI
# and no Az.ResourceGraph. Invoke-AzRestMethod returns the raw response text,
# which keeps two things `az graph query` gave the callers: -Lowercase can
# lowercase the text before it is parsed (the collectors compare against
# lowercase strings), and a resource whose definition holds an empty-string
# property key ("": ..., user-authored Logic App / policy / template
# definitions) can still be returned. PowerShell 7's ConvertFrom-Json refuses
# such a key, so it is renamed to '_rda_emptykey' before parsing.

# Request one page of a Resource Graph query. Returns a result object instead
# of throwing, because the production $ErrorActionPreference of
# 'SilentlyContinue' suppresses a bare `throw`: { Ok; Content; PageSize;
# Attempts; Error }. Bounded: at most $MaxAttempts transient failures (408,
# 429, 5xx, a request that throws), waiting Retry-After (capped at
# $MaxRetryAfterSeconds) or an exponential backoff with jitter between them.
# 400/401/403/404 and any other non-2xx status fail at once. An answer too
# large for one page (ResponsePayloadTooLarge) is asked for again with half
# the page size, down to one row; the smaller size is returned so later
# pages keep it.
function Invoke-AzGraphPage
{
    param(
        [Parameter(Mandatory = $true)][string]$Query,
        [Parameter(Mandatory = $true)][string[]]$SubscriptionId,
        [int]$PageSize = 1000,
        [string]$SkipToken,
        [int]$MaxAttempts = 4,
        [int]$MaxRetryAfterSeconds = 60
    )

    $GraphPath = '/providers/Microsoft.ResourceGraph/resources?api-version=2021-03-01'
    $Transient = 0
    $Requests = 0
    $LastError = $null
    # Every transient attempt plus every halving of the page size down to one row.
    $RequestCap = $MaxAttempts + [int][math]::Ceiling([math]::Log([math]::Max($PageSize, 1), 2)) + 1

    for ($Try = 1; $Try -le $RequestCap; $Try++)
    {
        $Options = [ordered]@{ resultFormat = 'objectArray'; '$top' = $PageSize }
        if (-not [string]::IsNullOrEmpty($SkipToken)) { $Options['$skipToken'] = $SkipToken }
        $Body = [ordered]@{ subscriptions = @($SubscriptionId); query = $Query; options = $Options } | ConvertTo-Json -Depth 5 -Compress

        $Requests++
        $Response = $null
        $Thrown = $null
        try { $Response = Invoke-AzRestMethod -Method POST -Path $GraphPath -Payload $Body -ErrorAction Stop }
        catch { $Thrown = $_.Exception }

        $RetryAfter = $null
        $Throttled = $false
        if ($null -eq $Thrown -and $null -ne $Response)
        {
            $Status = [int]$Response.StatusCode
            if ($Status -ge 200 -and $Status -lt 300)
            {
                return [pscustomobject]@{ Ok = $true; Content = [string]$Response.Content; PageSize = $PageSize; Attempts = $Requests; Error = $null }
            }

            $Err = Get-AzGraphErrorInfo -Content ([string]$Response.Content)
            $Described = 'HTTP {0} {1}: {2}' -f $Status, $Err.Code, $Err.Message
            if ($Err.Codes -contains 'ResponsePayloadTooLarge')
            {
                if ($PageSize -le 1)
                {
                    return [pscustomobject]@{ Ok = $false; Content = $null; PageSize = $PageSize; Attempts = $Requests; Error = ('the answer is too large even one row per page (ResponsePayloadTooLarge) after {0} attempt(s): {1}' -f $Requests, $Described) }
                }
                $PageSize = [int][math]::Floor($PageSize / 2)
                continue
            }

            $IsTransient = $Status -eq 408 -or $Status -eq 429 -or $Status -ge 500
            if (-not $IsTransient)
            {
                return [pscustomobject]@{ Ok = $false; Content = $null; PageSize = $PageSize; Attempts = $Requests; Error = ('{0} after {1} attempt(s)' -f $Described, $Requests) }
            }
            $LastError = $Described
            $Throttled = $Status -eq 429
            $RetryAfter = Get-AzGraphRetryAfterSeconds -Headers $Response.Headers
        }
        else
        {
            $LastError = if ($null -ne $Thrown) { 'request failed: ' + $Thrown.Message } else { 'request returned no response' }
        }

        $Transient++
        if ($Transient -ge $MaxAttempts) { break }

        if ($null -ne $RetryAfter)
        {
            $Wait = [math]::Min([math]::Max([math]::Ceiling($RetryAfter), 1), $MaxRetryAfterSeconds)
        }
        else
        {
            # Exponential backoff (1, 2, 4 ...) plus jitter so a wave of
            # throttled calls does not retry in lockstep; throttled calls wait
            # twice as long.
            $Backoff = [math]::Min([math]::Pow(2, $Transient - 1), 30)
            if ($Throttled) { $Backoff = [math]::Min($Backoff * 2, $MaxRetryAfterSeconds) }
            $Wait = [math]::Round($Backoff + (Get-Random -Minimum 0 -Maximum 1000) / 1000.0, 2)
        }
        Start-Sleep -Seconds $Wait
    }

    return [pscustomobject]@{ Ok = $false; Content = $null; PageSize = $PageSize; Attempts = $Requests; Error = ('{0} after {1} attempt(s)' -f $LastError, $Requests) }
}

# The error code and message of a Resource Graph error answer
# ({ error: { code, message, details: [{ code, message }] } }), and every code
# in it (Codes), so a detail code such as ResponsePayloadTooLarge is seen.
function Get-AzGraphErrorInfo
{
    param([string]$Content)
    $Info = [pscustomobject]@{ Code = 'Unknown'; Message = ''; Codes = @() }
    if ([string]::IsNullOrWhiteSpace($Content)) { return $Info }
    try { $Parsed = ConvertFrom-Json -InputObject $Content -ErrorAction Stop }
    catch { $Info.Message = $Content; return $Info }
    $ErrorNode = $Parsed.error
    if ($null -eq $ErrorNode) { $Info.Message = $Content; return $Info }
    $Codes = [System.Collections.Generic.List[string]]::new()
    $Messages = [System.Collections.Generic.List[string]]::new()
    if ($ErrorNode.code) { $Codes.Add([string]$ErrorNode.code) }
    if ($ErrorNode.message) { $Messages.Add([string]$ErrorNode.message) }
    foreach ($Detail in @($ErrorNode.details))
    {
        if ($null -eq $Detail) { continue }
        if ($Detail.code) { $Codes.Add([string]$Detail.code) }
        if ($Detail.message) { $Messages.Add(('{0}: {1}' -f $Detail.code, $Detail.message)) }
    }
    if ($Codes.Count -gt 0) { $Info.Code = ($Codes -join '/') }
    $Info.Message = ($Messages -join ' | ')
    $Info.Codes = $Codes.ToArray()
    return $Info
}

# Seconds Azure asks to wait before a retry, from Retry-After (seconds or an
# HTTP date) or Resource Graph's x-ms-user-quota-resets-after (hh:mm:ss);
# $null when neither is present. Accepts the HttpResponseHeaders of an
# Invoke-AzRestMethod answer or a dictionary.
function Get-AzGraphRetryAfterSeconds
{
    param($Headers)
    if ($null -eq $Headers) { return $null }
    if ($Headers -is [System.Net.Http.Headers.HttpResponseHeaders] -and $null -ne $Headers.RetryAfter)
    {
        if ($null -ne $Headers.RetryAfter.Delta) { return $Headers.RetryAfter.Delta.TotalSeconds }
        if ($null -ne $Headers.RetryAfter.Date) { return [math]::Max(0, ($Headers.RetryAfter.Date - [DateTimeOffset]::UtcNow).TotalSeconds) }
    }
    foreach ($Name in 'Retry-After', 'x-ms-user-quota-resets-after')
    {
        $Value = $null
        if ($Headers -is [System.Collections.IDictionary])
        {
            foreach ($Key in $Headers.Keys) { if ([string]$Key -ieq $Name) { $Value = @($Headers[$Key])[0] } }
        }
        elseif ($Headers -is [System.Net.Http.Headers.HttpHeaders])
        {
            $Values = $null
            if ($Headers.TryGetValues($Name, [ref]$Values)) { $Value = @($Values)[0] }
        }
        if ([string]::IsNullOrWhiteSpace([string]$Value)) { continue }
        $Text = ([string]$Value).Trim()
        $Seconds = 0.0
        if ([double]::TryParse($Text, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$Seconds)) { return $Seconds }
        $Span = [timespan]::Zero
        if ([timespan]::TryParse($Text, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$Span)) { return $Span.TotalSeconds }
        $When = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParse($Text, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$When)) { return [math]::Max(0, ($When - [DateTimeOffset]::UtcNow).TotalSeconds) }
    }
    return $null
}

# Rename every empty-string property KEY ("": ...) in JSON text to
# "_rda_emptykey". JSON strings are matched whole (escapes included), so an
# empty string value, or a "": inside a string, is left alone. When the text
# already holds that name (in any case, since -Lowercase lowercases the text
# afterwards), a numeric suffix is added until the name is unused, so the
# renamed key never collides with a real one and no value is dropped.
function Protect-AzGraphEmptyKey
{
    param([string]$Json)
    if ($Json -notmatch '""\s*:') { return $Json }
    $Sentinel = '_rda_emptykey'
    for ($Suffix = 1; $Json.IndexOf($Sentinel, [System.StringComparison]::OrdinalIgnoreCase) -ge 0; $Suffix++) { $Sentinel = '_rda_emptykey' + $Suffix }
    $Replacement = '"' + $Sentinel + '"'
    return [regex]::Replace($Json, '"(?:[^"\\]|\\.)*"(?=\s*:)', {
            param($Match)
            if ($Match.Value -eq '""') { return $Replacement }
            return $Match.Value
        })
}

# Parse a JSON array of rows (raw text) into PSCustomObjects, rows in order.
function ConvertFrom-AzGraphRowText
{
    param([string]$Json)
    return @(ConvertFrom-Json -InputObject $Json -NoEnumerate -Depth 1024 -ErrorAction Stop)
}

# Parse one Resource Graph answer: { Rows; SkipToken; Truncated }. The skip
# token is read from the untouched text (it is case-sensitive). -Lowercase
# lowercases the rows' text with invariant-culture rules before parsing, as
# the az CLI path did to its output; a row whose lowercased text does not
# parse is kept as returned.
function ConvertFrom-AzGraphPage
{
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content, [switch]$Lowercase)

    # Same nesting limit as ConvertFrom-Json (the JsonDocument default is 64).
    $DocumentOptions = [System.Text.Json.JsonDocumentOptions]::new()
    $DocumentOptions.MaxDepth = 1024
    $Document = [System.Text.Json.JsonDocument]::Parse($Content, $DocumentOptions)
    try
    {
        $Root = $Document.RootElement
        if ($Root.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) { throw 'the answer is not a JSON object' }
        $Element = [System.Text.Json.JsonElement]::new()
        $SkipToken = $null
        if ($Root.TryGetProperty('$skipToken', [ref]$Element) -and $Element.ValueKind -eq [System.Text.Json.JsonValueKind]::String) { $SkipToken = $Element.GetString() }
        $Truncated = $false
        if ($Root.TryGetProperty('resultTruncated', [ref]$Element))
        {
            $Truncated = ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::True) -or ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::String -and $Element.GetString() -ieq 'true')
        }
        if (-not $Root.TryGetProperty('data', [ref]$Element) -or $Element.ValueKind -ne [System.Text.Json.JsonValueKind]::Array) { throw 'the answer has no data array' }
        $RowTexts = @(foreach ($Row in $Element.EnumerateArray()) { $Row.GetRawText() })
    }
    finally
    {
        $Document.Dispose()
    }

    $Rows = $null
    $DataText = Protect-AzGraphEmptyKey -Json ('[' + ($RowTexts -join ',') + ']')
    if ($Lowercase)
    {
        try { $Rows = ConvertFrom-AzGraphRowText -Json $DataText.ToLowerInvariant() }
        catch
        {
            $Rows = @(foreach ($RowText in $RowTexts)
                {
                    $Safe = Protect-AzGraphEmptyKey -Json $RowText
                    try { ConvertFrom-Json -InputObject $Safe.ToLowerInvariant() -NoEnumerate -Depth 1024 -ErrorAction Stop }
                    catch { ConvertFrom-Json -InputObject $Safe -NoEnumerate -Depth 1024 -ErrorAction Stop }
                })
        }
    }
    else
    {
        $Rows = ConvertFrom-AzGraphRowText -Json $DataText
    }

    return [pscustomobject]@{ Rows = $Rows; SkipToken = $SkipToken; Truncated = $Truncated }
}

# Runs a Resource Graph query over the given subscriptions and returns every
# row, in the shape the inventory read from `az graph query`:
# { count; data; skip_token; total_records }, .data holding one PSCustomObject
# per row (none for an empty answer). The subscriptions are always named,
# in batches of at most 1000 (Resource Graph's limit per request); each batch
# is read page by page with the skip token, so the rows come back in the
# query's order within a batch and in batch order across batches. A
# subscription listed twice is queried once; with no subscription no request
# is made. A failure (see Invoke-AzGraphPage) or an answer that cannot be
# parsed throws with the status, the error code and message and the query, so
# the subscription fails loudly (see #22) and never continues with a partial
# or empty page; the throw stops the script even under the production
# 'SilentlyContinue' preference. -Lowercase lowercases each row's text before
# parsing, culture-invariantly (collectors compare against lowercase strings).
# A parse error quotes at most the first 500 characters of the page, and none
# of it with -HideRawOutput (the inventory passes it under -Obfuscate).
function Invoke-AzGraphQuerySafe
{
    param(
        [Parameter(Mandatory = $true)][string]$Query,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]]$SubscriptionId,
        [switch]$Lowercase,
        [switch]$HideRawOutput,
        [ValidateRange(1, 1000)][int]$PageSize = 1000,
        [ValidateRange(1, 1000)][int]$BatchSize = 1000
    )

    # A throw here must not be suppressed by the caller's preference.
    $ErrorActionPreference = 'Stop'
    # How much of an unparseable page a parse error quotes.
    $RawOutputLimit = 500

    $Seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $Ids = @($SubscriptionId | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $Seen.Add($_) })

    $All = [System.Collections.Generic.List[object]]::new()
    # Far above any real answer (10 million rows at 1000 a page); stops a
    # service that never stops handing out skip tokens.
    $MaxPages = 10000
    for ($Offset = 0; $Offset -lt $Ids.Count; $Offset += $BatchSize)
    {
        $Batch = @($Ids[$Offset..([math]::Min($Offset + $BatchSize, $Ids.Count) - 1)])
        $Size = $PageSize
        $Token = $null
        $UsedTokens = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        for ($PageNumber = 1; $PageNumber -le $MaxPages; $PageNumber++)
        {
            $Page = Invoke-AzGraphPage -Query $Query -SubscriptionId $Batch -PageSize $Size -SkipToken $Token
            if (-not $Page.Ok)
            {
                throw ("Resource Graph query failed: {0}`nQuery: {1}" -f $Page.Error, $Query)
            }
            $Size = $Page.PageSize

            try { $Parsed = ConvertFrom-AzGraphPage -Content $Page.Content -Lowercase:$Lowercase }
            catch
            {
                # The page goes to the log: only its start, and none of it
                # with -HideRawOutput, since it holds resource names and ids.
                # The JSON parser quotes the text it failed on, so its
                # message is shortened (or replaced by the position) too.
                $Raw = [string]$Page.Content
                $Cause = $_.Exception
                while ($null -ne $Cause.InnerException) { $Cause = $Cause.InnerException }
                if ($HideRawOutput)
                {
                    $Reason = if ($Cause -is [System.Text.Json.JsonException]) { 'invalid JSON at line {0}, byte {1}' -f $Cause.LineNumber, $Cause.BytePositionInLine }
                    elseif ($Cause.Message -like 'the answer *') { $Cause.Message }
                    else { $Cause.GetType().FullName }
                    $RawNote = '(not shown: obfuscated run)'
                }
                else
                {
                    $Reason = [string]$Cause.Message
                    if ($Reason.Length -gt $RawOutputLimit) { $Reason = $Reason.Substring(0, $RawOutputLimit) + '...' }
                    $RawNote = if ($Raw.Length -gt $RawOutputLimit) { '{0}... (first {1} of {2} characters)' -f $Raw.Substring(0, $RawOutputLimit), $RawOutputLimit, $Raw.Length } else { $Raw }
                }
                throw ("Resource Graph returned output that could not be parsed as JSON: {0}`nQuery: {1}`nRaw output: {2}" -f $Reason, $Query, $RawNote)
            }
            foreach ($Row in $Parsed.Rows) { $All.Add($Row) }

            if ([string]::IsNullOrEmpty($Parsed.SkipToken))
            {
                if ($Parsed.Truncated) { throw ("Resource Graph truncated the answer and gave no skip token to read the rest; refusing a partial result.`nQuery: {0}" -f $Query) }
                break
            }
            if (-not $UsedTokens.Add($Parsed.SkipToken)) { throw ("Resource Graph handed back a skip token it had already given; stopping instead of reading the same page forever.`nQuery: {0}" -f $Query) }
            $Token = $Parsed.SkipToken
            if ($PageNumber -eq $MaxPages) { throw ("Resource Graph answer is longer than {0} pages; stopping.`nQuery: {1}" -f $MaxPages, $Query) }
        }
    }

    return [pscustomobject]@{ count = $All.Count; data = $All.ToArray(); skip_token = $null; total_records = $All.Count }
}

# The total of a count probe (`... | summarize count()`) across every row of an
# Invoke-AzGraphQuerySafe result: one row per subscription batch. 0 for none.
# A row that is null, or whose count_ is missing, null or not a whole number of
# 0 or more, ends the function with an error, as a failure in
# Invoke-AzGraphQuerySafe does, instead of being read as 0 (or skipped, which
# counts too few), rounded or added as a negative number. An answer with no
# rows at all is still 0. 'Stop' here for the same reason as there: the
# inventory's SilentlyContinue would otherwise let the function go on past the
# throw.
function Get-AzGraphCount
{
    param([Parameter(Mandatory = $true)]$Result)
    $ErrorActionPreference = 'Stop'
    $Total = [long]0
    # Not `$Rows = if ...`: a statement's output is unrolled, so a lone null
    # row would come out as no rows at all.
    $Rows = @()
    if ($null -ne $Result.data) { $Rows = @($Result.data) }
    foreach ($Row in $Rows)
    {
        if ($null -eq $Row) { throw 'Resource Graph returned a count row that is null.' }
        $HasCount = if ($Row -is [System.Collections.IDictionary]) { $Row.Contains('count_') } else { $null -ne $Row.PSObject.Properties['count_'] }
        $Value = [long]0
        if (-not $HasCount -or $null -eq $Row.count_ -or -not [long]::TryParse([string]$Row.count_, [System.Globalization.NumberStyles]::Integer, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$Value) -or $Value -lt 0)
        {
            # Only the kind of value goes in the message, never the value.
            $Kind = if (-not $HasCount) { 'missing' } elseif ($null -eq $Row.count_) { 'null' } else { 'a {0}' -f $Row.count_.GetType().Name }
            throw ("Resource Graph returned a count (count_, {0}) that is not a whole number of 0 or more." -f $Kind)
        }
        $Total += $Value
    }
    return $Total
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
