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

# Runs `az graph query` and returns the parsed JSON result. Azure CLI
# failures (expired auth, throttling, a malformed KQL string, a transient
# ARM error) print to stderr and exit non-zero, but the previous call sites
# piped stdout straight into ConvertFrom-Json and read a count field off
# whatever came out - a failed call and a genuinely empty subscription both
# produced $null/0 with zero indication anything went wrong (see #22). This
# wrapper checks the actual exit code and throws with the real Azure CLI
# error text, so a Resource Graph failure surfaces as a loud, actionable
# subscription failure instead of a silent "0 resources found". -Lowercase
# preserves the exact `.tolower()` behavior the original data-fetching call
# sites relied on (collectors compare against lowercase type strings).
function Invoke-AzGraphQuerySafe
{
    param(
        [Parameter(Mandatory = $true)][string]$Query,
        [object[]]$ExtraArgs = @(),
        [switch]$Lowercase
    )

    $AzArgs = @('graph', 'query', '-q', $Query, '--output', 'json', '--only-show-errors') + $ExtraArgs

    # Bounded retry for TRANSIENT Resource Graph failures (dropped/changed
    # network mid-run, VPN switch, ARM throttling, 5xx). Without this a single
    # transient blip during discovery throws and fails the whole subscription
    # (recorded to FailedAttempts and resumable, but the entire sub restarts).
    # Mirrors the Get-AzMetric wrapper in Extension/Metrics.ps1: up to 3 retries
    # (4 attempts total) with exponential backoff + jitter, longer backoff when
    # throttled. Stable internals, deliberately NOT promoted to script params.
    # A CLEARLY-PERMANENT failure (authorization denied, malformed KQL / bad
    # request) is NOT retried - it throws immediately, matching the project's
    # fail-loud-fast stance for genuine access denial rather than burning ~30s
    # of backoff on an error a retry cannot fix. On the final failed attempt the
    # throw is identical to the pre-retry behavior, so the per-subscription
    # catch -> FailedAttempts -> -Resume path is unchanged (see #22).
    $GraphMaxRetries = 3
    $StdOut = $null
    $ExitCode = 0
    $StdErr = $null

    for ($Attempt = 0; ; $Attempt++)
    {
        # Capture stdout and stderr separately rather than merging with 2>&1.
        # Some az CLI versions emit non-suppressible diagnostic text on stderr
        # (extension auto-install notices, deprecation warnings) even on a
        # successful (exit 0) call. Merging streams would splice that text into
        # the JSON payload and cause ConvertFrom-Json to throw a parse error on
        # a call that actually succeeded - a false failure this must not
        # introduce. Stdout is only ever used for the JSON payload; stderr is
        # only used in the error message when the exit code is actually non-zero.
        $StdErrFile = [System.IO.Path]::GetTempFileName()
        try
        {
            $StdOut = & az @AzArgs 2>$StdErrFile
            $ExitCode = $LASTEXITCODE
            $StdErr = Get-Content -Path $StdErrFile -Raw -ErrorAction SilentlyContinue
        }
        finally
        {
            Remove-Item -Path $StdErrFile -Force -ErrorAction SilentlyContinue
        }

        if ($ExitCode -eq 0) { break }

        # Clearly-permanent failures: a retry cannot help, so surface immediately.
        $Permanent = $StdErr -match 'AuthorizationFailed|does not have authorization|\bForbidden\b|\bBadRequest\b|SemanticError|SyntaxError|InvalidQuery|Please provide a valid'

        if ($Permanent -or $Attempt -ge $GraphMaxRetries)
        {
            throw ("az graph query failed (exit code {0}) after {1} attempt(s): {2}`nQuery: {3}" -f $ExitCode, ($Attempt + 1), $StdErr, $Query)
        }

        # Transient: exponential backoff (2^attempt, capped) plus jitter so a
        # wave of throttled calls does not retry in lockstep. Throttled calls
        # wait a bit longer.
        $Throttled = $StdErr -match 'TooManyRequests|\b429\b|throttl'
        $Backoff = [math]::Min([math]::Pow(2, $Attempt), 30)
        if ($Throttled) { $Backoff = [math]::Min($Backoff * 2, 60) }
        $Jitter = (Get-Random -Minimum 0 -Maximum 1000) / 1000.0
        Start-Sleep -Seconds ([math]::Round($Backoff + $Jitter, 2))
    }

    $Text = $StdOut -join "`n"
    if ($Lowercase) { $Text = $Text.ToLower() }

    try
    {
        return ($Text | ConvertFrom-Json -ErrorAction Stop)
    }
    catch
    {
        throw ("az graph query returned output that could not be parsed as JSON: {0}`nRaw output: {1}" -f $_.Exception.Message, $Text)
    }
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
