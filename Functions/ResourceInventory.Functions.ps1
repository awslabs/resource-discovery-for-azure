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
Function Write-Log([string]$Message, [string]$Severity)
{
   $DateTime = "[{0:dd-MM-yyyy} {0:HH:mm:ss}]" -f (Get-Date)

   # Tag each line with the current subscription (first 8 chars of its GUID) when
   # one is in scope. Every -RunAllSubs child is invoked with -SubscriptionID, and
   # under -ParallelStreams the separate stream processes interleave their output
   # on one console; the tag makes each line attributable to a subscription, e.g.
   # "[12345678] Verifying Azure CLI Extension...". Read via Get-Variable so it
   # resolves the script-scope $SubscriptionID up the call chain without throwing
   # when no subscription is in scope (e.g. a standalone full-tenant run) - in
   # that case no tag is added and the output is byte-for-byte unchanged.
   $SubId  = Get-Variable -Name 'SubscriptionID' -ValueOnly -ErrorAction SilentlyContinue
   $SubTag = if (-not [string]::IsNullOrEmpty($SubId)) { '[{0}] ' -f $SubId.Substring(0, [Math]::Min(8, $SubId.Length)) } else { '' }
   $Message = $SubTag + $Message

   switch ($Severity) 
   {
        "Info"    { Write-Host $Message -ForegroundColor Cyan }
        "Warning" { Write-Host $Message -ForegroundColor Yellow }
        "Error"   { Write-Host $Message -ForegroundColor Red }
        "Success"   { Write-Host $Message -ForegroundColor Green }
        default   { Write-Host $Message }
    }

    # Errors-only sink: when an error-log path has been established (set in
    # InitializeInventoryProcessing) append error-severity messages to a
    # dedicated, timestamped file.
    #
    # IMPORTANT: this log is written LOCALLY ONLY and is deliberately NOT added
    # to the obfuscated (server-bound) zip. Error-severity messages can
    # interpolate raw $_.Exception.Message text and local paths (e.g. collector
    # failures, reconnect failures, HTML-gen failures) that carry real Azure
    # identifiers the obfuscation layer never touches. Shipping this file would
    # leak them. Do NOT add $Global:ErrorLogFile to the Compress-Archive Path
    # array without first scrubbing/obfuscating its contents. It is kept on disk
    # for local troubleshooting only, at the same trust level as the transcript.
    # Purely additive: the console output above is unchanged, and nothing is
    # written until the global path exists, so callers before setup are
    # unaffected.
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
}

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
        [Parameter(Mandatory=$true)][string]$Query,
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

