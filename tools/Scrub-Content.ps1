# tools/Scrub-Content.ps1
#
# Content-safety scrub library. Implements the contract documented in
# docs/CONTENT_SAFETY_SPEC.md. Every change to this file must be matched by a
# change to the spec and the Pester tests, or the drift-detection tests in
# Tests/ScrubContent.Tests.ps1 will fail.
#
# Usage:
#   . ./tools/Scrub-Content.ps1
#   $hits = Test-ContentForLeaks -Content $someText
#   $hits = Test-CommitMessage   -Message $someMessage
#
# The library is also runnable as a script:
#   pwsh ./tools/Scrub-Content.ps1 -Path some-file.txt
#   git diff --cached | pwsh ./tools/Scrub-Content.ps1 -FromStdin

[CmdletBinding(DefaultParameterSetName = 'Library')]
param(
    [Parameter(ParameterSetName = 'File', Mandatory = $true)]
    [string]$Path,

    [Parameter(ParameterSetName = 'Stdin')]
    [switch]$FromStdin,

    [Parameter(ParameterSetName = 'File')]
    [Parameter(ParameterSetName = 'Stdin')]
    [switch]$AsCommitMessage
)

# === Allow-list (must match docs/CONTENT_SAFETY_SPEC.md Section 3) ============
# Drift-detection in CI verifies these strings appear verbatim here.

$script:AllowListLiterals = @(
    '12345678-1234-1234-1234-123456789012',
    '00000000-0000-0000-0000-000000000000',
    '123456789012',
    '1ffec608-964c-4aaa-8f1e-125baacd6ed2'   # test fixture; only allowed in Tests/ScrubContent.Tests.ps1
)

# === Forbidden-pattern regexes (must match SPEC Section 1) ====================

# 1.1 Real GUIDs (8-4-4-4-12 hex, case-insensitive — matched with IgnoreCase
# option in [regex]::Matches calls below)
$script:GuidRegex = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'

# 1.2 AWS 12-digit account IDs. Use lookarounds so digits-adjacent-to-letters
# (e.g. "987654321098abc") still trigger; only adjacent additional digits
# (timestamps) suppress.
$script:AwsAccountRegex = '(?<![0-9])[0-9]{12}(?![0-9])'

# 1.3 Internal Amazon service / tooling names (case-insensitive). The
# `[-_ ]?` allowance between letters catches obfuscation attempts like
# `cloud-rays`, `cloud_rays`, and `aws crm`.
$script:InternalNameRegex = 'cloud[-_ ]?rays|sen[-_ ]?tral|aws[-_ ]?crm|mid[-_ ]?way|aea\b|acme\b|amazon[-_ ]?corp|amazon\.dev|amazon\.work|a2z|phone[-_ ]?tool|quip[-_ ]?amazon'

# 1.3 (cont.) Internal hostnames
$script:InternalHostRegex = '\.amazon-corp\.com|\.aws\.dev|\.a2z\.com|\.amazon\.work'

# 1.4 Customer scale fingerprints (thousand-separator tolerant)
$script:ScaleSubsRegex      = '\d{2,}(?:,\d{3})*\s+subscriptions'
$script:ScaleResourcesRegex = '(?:\d{1,3}(?:,\d{3})+|\d{4,})\s+resources'
$script:ScaleDollarsRegex   = '\$\s?(?:\d{1,3}(?:,\d{3})+|\d{5,})'

# 1.5 Auth artefacts. The JWT regex needs Singleline so a token split across
# newlines is still detected.
$script:JwtRegex    = 'eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}'
$script:SasRegex    = 'sv=\d{4}-\d{2}-\d{2}.*&sig=[A-Za-z0-9%]{20,}'
$script:BearerRegex = 'Bearer\s+[A-Za-z0-9._-]{40,}'

# 1.6 Review-process language (commit-message only)
$script:ReviewProcessRegex = 'reviewer said|reviewer asked|reviewer flagged|addressed review|address review feedback|deferred to|out of scope for this|low UX|negligible, pre-existing|per the reviewer'

# === Helper: is this match allow-listed? ======================================

function Test-IsAllowListed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $Match,
        [Parameter(Mandatory = $true)] [string] $Type
    )

    # Literal allow-list (Section 3 verbatim entries). GUID comparisons are
    # case-insensitive because the GUID regex is case-insensitive too — we
    # don't want a mixed-case allowed GUID to slip through detection.
    foreach ($literal in $script:AllowListLiterals) {
        if ($Type -eq 'guid') {
            if ($Match.ToLowerInvariant() -ceq $literal.ToLowerInvariant()) { return $true }
        } else {
            if ($Match -ceq $literal) { return $true }
        }
    }

    # AWS-account special case: 14+ digit "AWS account" matches are timestamps,
    # not account IDs (yyyyMMddHHmmssfff). With the new lookaround pattern this
    # path can still be reached if the regex implementation changes; keep the
    # belt-and-braces guard.
    if ($Type -eq 'aws-account' -and $Match.Length -gt 12) { return $true }

    return $false
}

# === Public: Test-ContentForLeaks =============================================

function Test-ContentForLeaks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $Content
    )

    if ([string]::IsNullOrEmpty($Content)) { return }

    $hits = @()

    # 1.1 GUIDs (case-insensitive — Azure portal URLs and ARM resource IDs use uppercase)
    foreach ($m in [regex]::Matches($Content, $script:GuidRegex, 'IgnoreCase')) {
        if (-not (Test-IsAllowListed -Match $m.Value -Type 'guid')) {
            $hits += [PSCustomObject]@{ Type = 'guid'; Value = $m.Value; Position = $m.Index }
        }
    }

    # 1.2 AWS account IDs
    foreach ($m in [regex]::Matches($Content, $script:AwsAccountRegex)) {
        if (-not (Test-IsAllowListed -Match $m.Value -Type 'aws-account')) {
            $hits += [PSCustomObject]@{ Type = 'aws-account'; Value = $m.Value; Position = $m.Index }
        }
    }

    # 1.3 Internal names + hostnames (case-insensitive)
    foreach ($m in [regex]::Matches($Content, $script:InternalNameRegex, 'IgnoreCase')) {
        $hits += [PSCustomObject]@{ Type = 'internal-service'; Value = $m.Value; Position = $m.Index }
    }
    foreach ($m in [regex]::Matches($Content, $script:InternalHostRegex, 'IgnoreCase')) {
        $hits += [PSCustomObject]@{ Type = 'internal-service'; Value = $m.Value; Position = $m.Index }
    }

    # 1.4 Scale fingerprints (case-insensitive on phrasing)
    foreach ($m in [regex]::Matches($Content, $script:ScaleSubsRegex, 'IgnoreCase')) {
        $hits += [PSCustomObject]@{ Type = 'scale-fingerprint'; Value = $m.Value; Position = $m.Index }
    }
    foreach ($m in [regex]::Matches($Content, $script:ScaleResourcesRegex, 'IgnoreCase')) {
        $hits += [PSCustomObject]@{ Type = 'scale-fingerprint'; Value = $m.Value; Position = $m.Index }
    }
    foreach ($m in [regex]::Matches($Content, $script:ScaleDollarsRegex)) {
        $hits += [PSCustomObject]@{ Type = 'scale-fingerprint'; Value = $m.Value; Position = $m.Index }
    }

    # 1.5 Auth artefacts. Scan both the raw content AND a whitespace-collapsed
    # version so tokens that have been line-wrapped by PR-description editors,
    # diff context lines, or comment-block-formatters still match. The
    # whitespace-collapsed version uses the position from the original via a
    # back-mapping, but for simplicity we report the position as -1 to indicate
    # "match found in normalized form" so reviewers know to look in line-wrapped
    # context.
    foreach ($m in [regex]::Matches($Content, $script:JwtRegex, 'Singleline')) {
        $hits += [PSCustomObject]@{ Type = 'auth-token'; Value = $m.Value; Position = $m.Index }
    }
    $normalised = ($Content -replace '\s+', '')
    if ($normalised -ne $Content) {
        foreach ($m in [regex]::Matches($normalised, $script:JwtRegex)) {
            # Avoid double-flagging a token already caught in raw form.
            $alreadyFlagged = $false
            foreach ($h in $hits) {
                if ($h.Type -eq 'auth-token' -and $h.Value.Replace("`n","").Replace("`r","").Replace(' ','') -eq $m.Value) {
                    $alreadyFlagged = $true; break
                }
            }
            if (-not $alreadyFlagged) {
                $hits += [PSCustomObject]@{ Type = 'auth-token'; Value = $m.Value; Position = -1 }
            }
        }
    }
    foreach ($m in [regex]::Matches($Content, $script:SasRegex, ([System.Text.RegularExpressions.RegexOptions]'IgnoreCase, Singleline'))) {
        $hits += [PSCustomObject]@{ Type = 'auth-token'; Value = $m.Value; Position = $m.Index }
    }
    foreach ($m in [regex]::Matches($Content, $script:BearerRegex)) {
        $hits += [PSCustomObject]@{ Type = 'auth-token'; Value = $m.Value; Position = $m.Index }
    }

    # Sort by position so output is deterministic regardless of regex order above.
    # Idiomatic PowerShell: emit each hit to the pipeline. Callers wrap with
    # @() to materialize an array. An empty result naturally produces $null
    # when not wrapped, which is the standard PowerShell contract.
    $hits | Sort-Object Position
}

# === Public: Test-CommitMessage ==============================================

function Test-CommitMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $Message
    )

    if ([string]::IsNullOrEmpty($Message)) { return }

    $hits = @(Test-ContentForLeaks -Content $Message)

    foreach ($m in [regex]::Matches($Message, $script:ReviewProcessRegex, 'IgnoreCase')) {
        $hits += [PSCustomObject]@{ Type = 'review-process'; Value = $m.Value; Position = $m.Index }
    }

    $hits | Sort-Object Position
}

# === Script-mode entry point =================================================

if ($PSCmdlet.ParameterSetName -ne 'Library') {
    $content = if ($FromStdin) { [Console]::In.ReadToEnd() } else { Get-Content -Path $Path -Raw }

    $hits = if ($AsCommitMessage) { Test-CommitMessage -Message $content } else { Test-ContentForLeaks -Content $content }

    if ($hits.Count -eq 0) {
        Write-Host 'scrub: clean (0 leak patterns found)' -ForegroundColor Green
        exit 0
    }

    Write-Host ('scrub: {0} leak pattern(s) found' -f $hits.Count) -ForegroundColor Red
    foreach ($h in $hits) {
        Write-Host ('  [{0}] {1} at offset {2}' -f $h.Type, $h.Value, $h.Position) -ForegroundColor Yellow
    }
    exit 1
}
