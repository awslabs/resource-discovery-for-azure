#Requires -Version 7.0
# Shared helper library for ResourceInventory.ps1 (dot-sourced into its scope; definitions only).
# Protect-* scrubbers and Write-Log (from Common.Functions.ps1) are Global: so collectors invoked via '& $Module' can reach them.

function GetLocalVersion()
{
    # Resolve Version.json from this file's own dir (parent of $PSScriptRoot), not the CWD,
    # so agents/background jobs with a different CWD still read it; an empty $PSScriptRoot (not loaded from disk) fails loud.
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

# Deterministically tokenize a free-text value into $Global:FreeTextDictionary (same value -> same prod_/nonprod_ token within a run).
# Global: so collectors invoked via '& $Module' reach it; null/empty -> $null, and with no dictionary (obfuscation off) the value is returned unchanged.
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

# Resolve one identifier segment to a stable obfuscated token. Order: reuse a token a prior phase minted (SharedDictionary keyed by LookupKey, READ-ONLY - never written here), else the per-run LocalCache keyed by the REAL value, else mint prefix+GUID into LocalCache.
# Read-only against SharedDictionary is load-bearing: the consumption leaf passes $Global:ResourceIdDictionary here to REUSE the inventory token, and writing consumption fragments back would pollute that map's ObfuscationDictionary contract (obfuscated full-Azure-id -> real-id).
function Global:Resolve-ObfuscationToken
{
    param(
        [string]$RealValue,
        [string]$LookupKey,
        $SharedDictionary,
        [hashtable]$LocalCache,
        [string]$TokenPrefix
    )

    if ($null -ne $SharedDictionary -and $SharedDictionary.ContainsKey($LookupKey)) { return $SharedDictionary[$LookupKey] }
    if ($LocalCache.ContainsKey($RealValue)) { return $LocalCache[$RealValue] }

    $Token = $TokenPrefix + [guid]::NewGuid().ToString()
    $LocalCache[$RealValue] = $Token
    return $Token
}

# Rebuild an ARM resourceUri segment-by-segment, masking only the identifying segments (sub id, RG name, resource NAME) and keeping structure/provider/TYPE and the mc_ AKS-managed-RG marker intact - the dashboard categorises rows by parsing provider+type+mc_, which a flat opaque token destroys (AKS/VMSS rows go invisible).
# empty -> 'obfuscated'; a non-ARM shape -> one cached prefix+GUID; canonical -> tokenise sub, then RG (preserving mc_), then walk providers: even provider-relative indices (>=2) are NAME segments to tokenise, odd are TYPE segments kept verbatim, $system left intact.
# The LEAF name (largest even index >=2) reuses the inventory token via $NameDictionary (READ-ONLY, keyed by $RawUri) so a consumption/metric row joins back to Inventory_*.json / Metrics_*.json; intermediate names (parent resources) use $NameCache only.
function Global:Build-ObfuscatedResourceUri
{
    param(
        [string]$RawUri,
        [string]$Prefix,
        $SubscriptionDictionary,
        $ResourceGroupDictionary,
        $NameDictionary,
        [hashtable]$SubCache,
        [hashtable]$RgCache,
        [hashtable]$NameCache
    )

    if ([string]::IsNullOrEmpty($RawUri))
    {
        return 'obfuscated'
    }

    if ($RawUri -notmatch '^/subscriptions/([^/]+)(/resourcegroups/([^/]+))?(/providers/(.+))?$')
    {
        # Non-ARM shape (system-namespace placeholder, marketplace/tenant-level meter): stable single token via the name cache, so the ObfuscationDictionary file only ever holds real-Azure-id mappings.
        if (-not $NameCache.ContainsKey($RawUri))
        {
            $NameCache[$RawUri] = $Prefix + [guid]::NewGuid().ToString()
        }
        return $NameCache[$RawUri]
    }

    $RealSub = $Matches[1]
    $RealRg = $Matches[3]
    $RealProv = $Matches[5]   # '<rp>/<type>/<name>[/<subtype>/<name2>...]'

    $ObfSub = Resolve-ObfuscationToken -RealValue $RealSub -LookupKey $RawUri -SharedDictionary $SubscriptionDictionary -LocalCache $SubCache -TokenPrefix ($Prefix + 'sub_')
    $RebuiltUri = '/subscriptions/' + $ObfSub

    if (-not [string]::IsNullOrEmpty($RealRg))
    {
        $RgTag = if ($RealRg -match '^mc_') { 'mc_' } else { '' }
        $ObfRg = Resolve-ObfuscationToken -RealValue $RealRg -LookupKey $RawUri -SharedDictionary $ResourceGroupDictionary -LocalCache $RgCache -TokenPrefix ($Prefix + 'rg_' + $RgTag)
        $RebuiltUri += '/resourcegroups/' + $ObfRg
    }

    if (-not [string]::IsNullOrEmpty($RealProv))
    {
        $ProvParts = $RealProv -split '/'
        # Leaf = last NAME segment (largest even index >=2); only it identifies THIS resource, so only it reuses the inventory token. Intermediate names are parent-resource identities and stay on the per-name cache.
        $LeafNameIndex = -1
        for ($Li = $ProvParts.Count - 1; $Li -ge 2; $Li--)
        {
            if ($Li % 2 -eq 0) { $LeafNameIndex = $Li; break }
        }

        $Rebuilt = @()
        for ($Pi = 0; $Pi -lt $ProvParts.Count; $Pi++)
        {
            $Part = $ProvParts[$Pi]
            $IsNameSegment = ($Pi -ge 2 -and ($Pi % 2 -eq 0))
            if ($IsNameSegment -and -not [string]::IsNullOrEmpty($Part) -and $Part -ne '$system')
            {
                # Only the leaf consults $NameDictionary (inventory, read-only); intermediate names pass $null so they only ever hit the name cache.
                $LeafShared = if ($Pi -eq $LeafNameIndex) { $NameDictionary } else { $null }
                $Rebuilt += Resolve-ObfuscationToken -RealValue $Part -LookupKey $RawUri -SharedDictionary $LeafShared -LocalCache $NameCache -TokenPrefix $Prefix
            }
            else
            {
                $Rebuilt += $Part
            }
        }
        $RebuiltUri += '/providers/' + ($Rebuilt -join '/')
    }

    return $RebuiltUri
}

# Over-inclusive scrub of a diagnostic/exception string for the shareable log: dictionary tokenization (keys applied LONGEST-FIRST) then class masking of email/IP/host/path/residual GUID.
# Must never LEAK a known value or structured identifier; the (?<!_) GUID lookbehind preserves real prod_/nonprod_ tokens. Global: to match Protect-FreeTextValue.
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

    # Auth artifacts FIRST (highest severity): mask the VALUE of sig=/sas=/*key=/*secret=/*token=/password= and 'Bearer <token>' so a SAS signature or connection-string secret never ships.
    # ';' terminates a value so a connection string's next segment survives readable.
    $Result = [regex]::Replace($Result, '(?i)\b(sig|signature|sas|accesstoken|access_token|bearertoken|accountkey|sharedaccesskey|sharedaccesssignature|password|pwd|client_secret|clientsecret|[a-z0-9_\-]*(?:key|secret|token))=[^&;\s"''<>]+', '$1=<redacted>')
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

# Pure helper: seconds to wait before retrying a throttled Azure call, honoring the SERVICE'S OWN retry directive instead of blind exponential backoff.
# Reads BOTH $Exception.Response.Headers and .InnerException.Response.Headers (metrics wraps one level down); precedence Retry-After > consumption-retry-after > user-quota-resets-after, clamped to [1,MaxSeconds]; falls back to FallbackSeconds when no usable header.
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
        # Enumerate via GetEnumerator(): PowerShell's foreach treats an IDictionary as one scalar object, not entry-by-entry,
        # so this walks all three real container shapes (Dictionary/HttpResponseHeaders -> KeyValuePair, Hashtable -> DictionaryEntry), each exposing .Key/.Value.
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

# Classify a Resource Graph failure from the exception's STRUCTURED surface (Body.Error.Code / Details[].Code / Response.StatusCode), not message text -
# the native cmdlet's .Message is the same generic 'BadRequest' line for every 400. Text matching is a last-resort fallback for bodyless network errors; never throws.
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
        # A CLIENT-SIDE materialization failure (a resource whose JSON has an EMPTY-STRING object key): not a service error and NOT permanent -
        # its own flag so the caller recovers the window via the raw ARM REST path instead of failing the whole subscription.
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
        # Empty-string JSON key = client-side materialization failure (PSNoteProperty/ConvertFrom-Json both reject it), deterministic per resource,
        # so fail fast and name the cause rather than burning the retry budget (a real run burned all 31 attempts before losing the subscription).
        elseif ($Text -match 'the value of argument "name" is not valid|property whose name is an empty string')
        {
            # Empty-string JSON key (user-authored JSON: Logic App / policy / template) that Search-AzGraph cannot materialize; retrying is futile.
            # NOT marked IsPermanent - the caller recovers the window via the raw ARM REST path, renaming empty keys to a sentinel so the resource is CAPTURED, not lost.
            $Info.IsEmptyPropertyName = $true
        }
        elseif ($Text -match 'AuthorizationFailed|does not have authorization|\bForbidden\b|\bBadRequest\b|SemanticError|SyntaxError|InvalidQuery|Please provide a valid') { $Info.IsPermanent = $true }
    }

    return $Info
}

# Sentinel that an empty-string JSON property name is renamed to in the raw-REST fallback (an empty key cannot survive PSNoteProperty/ConvertFrom-Json, so it is renamed not dropped).
# Collision-proof (no real Azure property is named this) and inert downstream; it can appear anywhere in a resource's 'properties' bag in Inventory_*.json.
$Script:RdaEmptyPropertyNameSentinel = '_rda_emptykey'

# Recover ONE window Search-AzGraph could not materialize because a resource has an EMPTY-STRING JSON key (see IsEmptyPropertyName): re-fetch the same query via the raw ARG REST endpoint,
# which returns a JSON STRING whose empty keys are renamed to the sentinel BEFORE any ConvertFrom-Json, so the resource is CAPTURED intact. Uses Invoke-AzRestMethod (portable, no `az`); throws on failure.
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

    # Rename EMPTY-STRING JSON keys ("" in key position) to the sentinel in the raw response TEXT before parsing, so ConvertFrom-Json never sees an empty name.
    # The (?<=[{,]\s*)""(?=\s*:) match targets keys only, never empty string VALUES.
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

# ONE Resource Graph request with the project's bounded retry around it. Every loop exit is an explicit `break`; the throw happens after the loop.
# Rationale: under $ErrorActionPreference='SilentlyContinue' an uncaught throw does NOT terminate, so the old for(;;)+throw shape looped FOREVER on a permanent failure and the retry ceiling was inert.
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

    # Up to 30 retries (31 attempts) with exponential backoff + jitter, longer when throttled, honouring a server Retry-After directive when present.
    # High ceiling lets a shard ride out SUSTAINED tenant-wide ARG throttling; per-attempt backoff is still capped (30s / 60s throttled / 120s server-directed). Stable internal, not a script param.
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
            # $Response is REQUIRED - do NOT inline to @(Search-AzGraph @GraphParams): the cmdlet returns ONE enumerable response object, so @(command) wraps it in a 1-element array
            # and a split 16 MB payload then silently drops every row in the window. @($Response) (not .Data) enumerates it to the flat row array callers assume; the $null guard avoids @($null)'s phantom row.
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

            # Empty-string JSON key in this window: retrying Search-AzGraph is futile, so recover the SAME window via the raw REST path (which renames empty keys to a sentinel), capturing the resource.
            # If the REST fallback ITSELF fails, fall through to normal (permanent) failure handling rather than looping.
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

    # Return a structured result (not a throw) so the window splitter can read the CLASSIFICATION (IsPayloadTooLarge) directly.
    # Contract callers rely on: on success Rows is never $null (empty array is the floor); Rows is $null exactly when Failure is set.
    return [pscustomobject]@{
        Rows           = $Rows
        Failure        = $Failure
        FailureMessage = $FailureMessage
        Attempts       = $AttemptsMade
    }
}

# Fetch the rows for ONE caller-requested window, splitting it into smaller sub-windows if Azure refuses the response as too large (16 MB cap; e.g. templatespecs/versions at ~794 KB each).
# Always returns the FULL requested window (the caller's paging contract must not change), and only splits an ORDERED query (`order by id asc`) since sub-windows of an ordered result are disjoint and concatenate to the whole.
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

    # Loop control is explicit (every fatal path sets $FatalMessage and breaks; the throw happens once, after the loop) for the SAME reason as Invoke-AzGraphRequest:
    # under 'SilentlyContinue' a `throw` is not a reliable exit and would let a non-payload failure fall into the split branch and split forever.
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

    # Native Az.ResourceGraph query - replaces the former 'az graph query' CLI shell-out (portable, no az.cmd/cmd.exe quoting boundary).
    # Caller contract preserved: returns an object with a lowercase .data member ($x.data / $x.data.count_); .data is ALWAYS a flat row array (flattened once in Invoke-AzGraphRequest) and -Lowercase controls ONLY casing.

    # Bounded retry for TRANSIENT Resource Graph failures (network blip, VPN switch, ARM throttling, 5xx): up to 30 retries with backoff + jitter, honoring a server retry directive via Get-RetryWaitSeconds.
    # CLEARLY-PERMANENT failures (authorization denied, malformed KQL) throw immediately; the final throw matches pre-retry behavior so the per-sub catch -> FailedAttempts -> -Resume path is unchanged (#22).
    $Rows = @(Get-AzGraphRowWindow -Query $Query -Subscription $Subscription -First $First -Skip $Skip)

    # Reproduce the former whole-payload .ToLower() (keys AND values) via a JSON round-trip when -Lowercase, since downstream collectors/tests depend on lowercased strings and self-joins.
    # ToLowerInvariant(), NOT ToLower(): culture-sensitive ToLower() on a tr-TR/az-AZ host maps 'I' to the dotless 'i' and would corrupt JSON KEYS like 'subscriptionId'.
    if ($Lowercase -and $Rows.Count -gt 0)
    {
        # Defense in depth: rename any empty JSON key in the serialized TEXT to the sentinel before this round-trip's ConvertFrom-Json (which rejects an empty name identically to Search-AzGraph),
        # so the -Lowercase round-trip can never drop a resource. On the normal path (no empty keys) the regex matches nothing and behaviour is byte-for-byte unchanged.
        $Json = ($Rows | ConvertTo-Json -Depth 100).ToLowerInvariant()
        $Json = [regex]::Replace($Json, '(?<=[{,]\s*)""(?=\s*:)', ('"' + $Script:RdaEmptyPropertyNameSentinel + '"'))
        $Rows = @($Json | ConvertFrom-Json)
    }

    # Preserve the historical .data accessor the call sites read.
    return [pscustomobject]@{ data = $Rows }
}



# Build + write the shareable Diagnostics_*.log that ships inside the per-sub report zip, for BOTH obfuscated and default runs; every free-text field is scrubbed through Protect-DiagnosticText.
# Written as a HUMAN-READABLE .log (NOT .json, so the ingestion server does not table-ingest it) and wrapped in try/catch returning path or $null - a diagnostics-log error must NEVER break packaging of the actual inventory.
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
        # Metric-query outcome for THIS run, passed in (not read from the global) so the builder stays self-contained/unit-testable and can take a per-subscription figure;
        # $MetricsRequested is $false when -SkipMetrics was passed, making a zero call count expected rather than a problem.
        [int]$MetricsApiCallCount = 0,
        [bool]$MetricsRequested = $true,
        [switch]$Obfuscated
    )

    try
    {
        # Real-value -> token scrub map for the failure messages: derive bare NAME/RG/sub-GUID from the resource-ID-keyed dictionaries (else a bare name/RG/sub-GUID in an exception would NOT be tokenized), plus tag/free-text values.
        # Empty in a default run (no dictionaries), leaving Protect-DiagnosticText's class masking to act.
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

        # Report the consumption record count (a plain integer, safe in an obfuscated bundle), not just failures - a header-only CSV was previously invisible here (failure count 0, count unreported).
        # n/a is gated on a ZERO count AND -SkipConsumption (records from a supposedly skipped phase fall through to the numeric form); Get-RunSummaryLogContent applies the SAME gate so the two artifacts never disagree.
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

        # Metric-query call count: the counterpart to the consumption count above and for the same reason (a -SkipMetrics run previously left no trace of the phase); a plain integer, safe in an obfuscated bundle.
        # Deliberately matches the consumption block's gate shape, N0+InvariantCulture formatting, and RunSummary label verbatim, and is placed AFTER the consumption warning so that warning is not split from its count.
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
        ($DiagLines -join [Environment]::NewLine) | Out-File -LiteralPath $DiagnosticsFile -Encoding utf8
        Write-Log -Message ('Shareable diagnostics log written: {0}' -f (Split-Path -Path $DiagnosticsFile -Leaf)) -Severity 'Info'
        return $DiagnosticsFile
    }
    catch
    {
        Write-Log -Message ('Could not build/write shareable diagnostics log: {0}' -f $_.Exception.Message) -Severity 'Warning'
        return $null
    }
}



# Best-effort extraction of a SERVER-DIRECTED retry delay (seconds) from a failed Azure cmdlet's error (consumption-retry-after header, else the standard Retry-After) so a throttled caller waits exactly as long as the service asks.
# Handles both RFC 7231 forms (delta-seconds and HTTP-date, parsed invariant/AssumeUniversal); returns >= 0, else 0 so the caller uses its own backoff. NEVER throws - a diagnostics aid must not break the retry loop.
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
