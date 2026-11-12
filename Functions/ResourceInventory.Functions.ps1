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

# Write the inventory object (one NoteProperty per collector) to $Path one property at a time,
# so the whole document is never built as one string. The output is byte-for-byte what
# '$InputObject | ConvertTo-Json -Depth 100 -Compress | Out-File $Path' wrote: each value sits
# one level below the root, hence -Depth 99; -InputObject keeps a one-element array as [ ... ];
# UTF-8 with no BOM and a trailing newline; a relative path resolves against the PowerShell
# location, as Out-File does. The file is written under a temporary name in the same folder and
# moved to $Path only once it is complete, so a failed write never leaves a cut-off file: on any
# failure the temporary file is closed, its removal is tried (a warning says when it cannot be
# removed), and the error is re-thrown.
function Write-InventoryJson
{
    param(
        [Parameter(Mandatory = $true)]
        $InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $FullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $Moved = $false
    # Only a temporary file this call created is removed on failure.
    $Created = $false
    $TempPath = $null
    try
    {
        # The temporary file sits beside the final one under a short ASCII name
        # of its own, 'rda-write-<32 hex>.tmp' (a new GUID for every write): it
        # never ends in .json, it is 46 characters long (so it fits as a file
        # name wherever a longer final name does), and no two writes share it. A file a killed write left stays in that run's
        # folder with the other files the run had written.
        $TempPath = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($FullPath), ('rda-write-{0}.tmp' -f [guid]::NewGuid().ToString('N')))
        # The file is this call's from the moment it exists, so a failure in
        # building the writer still closes and removes it.
        $TempStream = [System.IO.FileStream]::new($TempPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $Created = $true
        try { $Writer = [System.IO.StreamWriter]::new($TempStream, [System.Text.UTF8Encoding]::new($false)) }
        catch { $TempStream.Dispose(); throw }
        try
        {
            $Writer.Write('{')
            $FirstProperty = $true
            foreach ($Prop in $InputObject.PSObject.Properties)
            {
                if (-not $FirstProperty) { $Writer.Write(',') }
                $FirstProperty = $false
                $Writer.Write((ConvertTo-Json -InputObject $Prop.Name -Compress))
                $Writer.Write(':')
                $Writer.Write((ConvertTo-Json -InputObject $Prop.Value -Depth 99 -Compress))
            }
            $Writer.Write('}')
            $Writer.Write([Environment]::NewLine)
        }
        finally
        {
            try { $Writer.Flush() }
            finally { $Writer.Dispose() }
        }
        [System.IO.File]::Move($TempPath, $FullPath, $true)
        $Moved = $true
    }
    finally
    {
        if (-not $Moved -and $Created -and $null -ne $TempPath -and (Test-Path -LiteralPath $TempPath))
        {
            Remove-Item -LiteralPath $TempPath -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $TempPath) { Write-Warning ("Write-InventoryJson: could not remove the temporary file '{0}'; delete it by hand." -f $TempPath) }
        }
    }
}

# Zips the report files with the same entries Compress-Archive -Path produces
# (same path resolution, entry names and order), but streams each file into a
# NEW archive. Compress-Archive opens its archive in ZipArchiveMode.Update,
# which keeps every entry's uncompressed bytes in memory until the archive is
# closed, so a large set of metrics JSON files can exhaust memory.
# ZipArchiveMode.Create with CreateEntryFromFile copies each file from disk
# into the archive in chunks.
# The archive is built under a temporary name (.rda-<guid>.partial) in the
# destination folder and moved into place only once complete, so a failure
# never leaves a partial zip at the final name. The temporary name does not end
# in .zip, so the wrapper's *.zip sweep of the output folders never picks one
# up. Like Compress-Archive without -Force, an existing destination is an error
# and is left untouched.
function Compress-RdaReportArchive
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Path,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$DestinationPath,

        [ValidateSet('Optimal', 'NoCompression', 'Fastest')]
        [string]$CompressionLevel = 'Optimal'
    )

    # Any failure must reach the caller, whatever its own error preference.
    $ErrorActionPreference = 'Stop'
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.ZipFile

    $DestinationPath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($DestinationPath)
    if (Test-Path -LiteralPath $DestinationPath -PathType Leaf)
    {
        throw [System.IO.IOException]::new(('The archive file {0} already exists.' -f $DestinationPath))
    }

    $SeenPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($Item in $Path)
    {
        if (-not $SeenPaths.Add($Item))
        {
            throw [System.IO.IOException]::new(("The input to the Path parameter contains a duplicate path '{0}'." -f $Item))
        }
    }

    # Wildcards are expanded by Resolve-Path, as in Compress-Archive, so hidden
    # files and matching directories are treated the same way.
    $SourceFiles = [System.Collections.Generic.List[string]]::new()
    $SourceDirs = [System.Collections.Generic.List[string]]::new()
    foreach ($Item in $Path)
    {
        foreach ($Resolved in @(Resolve-Path -Path $Item -ErrorAction Stop))
        {
            $FullPath = $Resolved.ProviderPath
            if (-not ([System.IO.File]::Exists($FullPath) -or [System.IO.Directory]::Exists($FullPath)))
            {
                throw [System.IO.IOException]::new(("The path '{0}' either does not exist or is not a valid file system path." -f $FullPath))
            }
            if (Test-Path -LiteralPath $FullPath -PathType Leaf) { $SourceFiles.Add($FullPath) } else { $SourceDirs.Add($FullPath) }
        }
    }

    # Directory contents come first, named relative to the directory's parent
    # exactly as Compress-Archive 1.2 names them, with empty folders as their
    # own entries; then the files, by file name.
    $Entries = [System.Collections.Generic.List[object]]::new()
    foreach ($SourceDir in $SourceDirs)
    {
        $ParentPath = ([System.IO.DirectoryInfo]::new($SourceDir)).Parent.FullName
        $Prefix = if ($ParentPath.Length -eq 3) { $ParentPath } else { $ParentPath + [System.IO.Path]::DirectorySeparatorChar }
        # -ErrorAction Stop: a folder it cannot list stops the zip, as in Compress-Archive,
        # so a zip is never made without that folder's files.
        foreach ($Child in @(Get-ChildItem -LiteralPath $SourceDir -Recurse -ErrorAction Stop))
        {
            $IsDirectory = $Child -is [System.IO.DirectoryInfo]
            if ($IsDirectory -and $Child.GetFiles().Count -ne 0) { continue }
            $ChildPath = if ($IsDirectory) { $Child.FullName + [System.IO.Path]::DirectorySeparatorChar } else { $Child.FullName }
            $Index = $ChildPath.IndexOf($Prefix, [System.StringComparison]::OrdinalIgnoreCase)
            $RelativePath = $ChildPath.Replace($ChildPath.Substring($Index, $Prefix.Length), '').Trim()
            $Entries.Add([pscustomobject]@{
                    Source      = $Child.FullName
                    Name        = $RelativePath.Replace([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
                    IsDirectory = $IsDirectory
                })
        }
    }
    foreach ($SourceFile in $SourceFiles)
    {
        $Entries.Add([pscustomobject]@{ Source = $SourceFile; Name = [System.IO.Path]::GetFileName($SourceFile); IsDirectory = $false })
    }

    $Level = [System.IO.Compression.CompressionLevel]$CompressionLevel
    # The temporary name has a fixed length (45 characters) that does not
    # depend on the destination name, so any final name the file system
    # accepts also works here.
    $TempName = '.rda-{0}.partial' -f [guid]::NewGuid().ToString('N')
    $TempPath = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($DestinationPath), $TempName)
    $ArchiveStream = $null
    $Archive = $null
    $Moved = $false
    try
    {
        $ArchiveStream = [System.IO.File]::Open($TempPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $Archive = [System.IO.Compression.ZipArchive]::new($ArchiveStream, [System.IO.Compression.ZipArchiveMode]::Create, $false)

        foreach ($Entry in $Entries)
        {
            if ($Entry.IsDirectory)
            {
                $null = $Archive.CreateEntry($Entry.Name, $Level)
            }
            else
            {
                $null = [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($Archive, $Entry.Source, $Entry.Name, $Level)
            }
        }

        # Disposing the archive writes the central directory.
        $Archive.Dispose()
        $ArchiveStream.Dispose()

        # As with Compress-Archive, an archive with no entries is not kept.
        if ($Entries.Count -gt 0)
        {
            [System.IO.File]::Move($TempPath, $DestinationPath)
            # The last step that may fail: from here on nothing may fail the call.
            $Moved = $true
        }
    }
    finally
    {
        # Closing twice is harmless after success. After a failure the partial
        # archive is deleted, so an error while closing it must not replace the
        # original error.
        foreach ($Disposable in @($Archive, $ArchiveStream))
        {
            if ($null -eq $Disposable) { continue }
            try { $Disposable.Dispose() } catch { Write-Verbose ('Closing the partial archive failed: {0}' -f $_.Exception.Message) }
        }
        # After the move there is no temporary file to remove. Before it, a failed clean-up
        # only warns, so it never replaces the original error.
        if (-not $Moved)
        {
            try
            {
                if (Test-Path -LiteralPath $TempPath)
                {
                    Remove-Item -LiteralPath $TempPath -Force -ErrorAction SilentlyContinue
                    if (Test-Path -LiteralPath $TempPath) { Write-Warning ("Compress-RdaReportArchive: could not remove the temporary file '{0}'; delete it by hand." -f $TempPath) }
                }
            }
            catch
            {
                Write-Warning ("Compress-RdaReportArchive: could not check or remove the temporary file '{0}': {1}; delete it by hand if it is there." -f $TempPath, $_.Exception.Message)
            }
        }
    }
}
