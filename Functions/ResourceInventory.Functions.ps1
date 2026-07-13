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
    $versionJsonPath = "./Version.json"
    if (Test-Path $versionJsonPath)
    {
        $localVersionJson = Get-Content $versionJsonPath | ConvertFrom-Json
        return ('{0}.{1}.{2}' -f $localVersionJson.MajorVersion, $localVersionJson.MinorVersion, $localVersionJson.BuildVersion)
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
        $tfPrefix = if ($Value -match '\b(dev|test|qa|tst|development|non-prod|uat|nonprod)\b' -or $Value -match '(^|-)([dts])-') { 'nonprod_' } else { 'prod_' }
        $Global:FreeTextDictionary[$Value] = $tfPrefix + [guid]::NewGuid().ToString()
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

    $result = $Text
    if ($null -ne $ValueMap -and $ValueMap.Count -gt 0)
    {
        foreach ($real in ($ValueMap.Keys | Sort-Object -Property Length -Descending))
        {
            if (-not [string]::IsNullOrEmpty($real) -and $result.Contains($real))
            {
                $result = $result.Replace($real, $ValueMap[$real])
            }
        }
    }

    # Auth artifacts first (highest severity): a SAS signature / token value in a
    # URL or error must never ship even to the ingestion party. Mask the VALUE of
    # sig=/signature=/sas=/(access|bearer)token=... and a 'Bearer <token>' header.
    $result = [regex]::Replace($result, '(?i)\b(sig|signature|sas|accesstoken|access_token|bearertoken)=[^&\s"''<>]+', '$1=<redacted>')
    $result = [regex]::Replace($result, '(?i)\bBearer\s+[A-Za-z0-9._\-]+', 'Bearer <redacted>')

    $result = [regex]::Replace($result, '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}', '<email>')
    $result = [regex]::Replace($result, '\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b', '<ip>')
    $result = [regex]::Replace($result, '(?i)\b[a-z0-9][a-z0-9-]*\.(?:blob|file|queue|table|dfs|vault|database|servicebus|azurewebsites|documents|search|azurecr|azuredatabricks|cognitiveservices|azconfig|azurefd|azure-api)\.[a-z0-9.]+\b', '<host>')
    $result = [regex]::Replace($result, '(?i)\b[a-z0-9][a-z0-9-]*\.(?:cloudapp\.azure\.com|trafficmanager\.net|cache\.windows\.net)\b', '<host>')
    $result = [regex]::Replace($result, '(?i)/home/[a-z0-9._-]+', '/home/<user>')
    $result = [regex]::Replace($result, '(?i)C:\\Users\\[a-z0-9._-]+', 'C:\Users\<user>')
    $result = [regex]::Replace($result, '(?<!_)\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b', '<guid>')

    return $result
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

    # Capture stdout and stderr separately rather than merging with 2>&1. Some
    # az CLI versions emit non-suppressible diagnostic text on stderr (extension
    # auto-install notices, deprecation warnings) even on a successful (exit 0)
    # call. Merging streams would splice that text into the JSON payload and
    # cause ConvertFrom-Json to throw a parse error on a call that actually
    # succeeded - a false failure this rewrite must not introduce. Stdout is
    # only ever used for the JSON payload; stderr is only used in the error
    # message when the exit code is actually non-zero.
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

    if ($ExitCode -ne 0)
    {
        throw ("az graph query failed (exit code {0}): {1}`nQuery: {2}" -f $ExitCode, $StdErr, $Query)
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

