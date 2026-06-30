#Requires -Version 7.0
<#
.SYNOPSIS
    Produce a PARTIALLY-revealed copy of an obfuscated Resource Discovery report
    zip: selectively un-obfuscate ONLY the chosen dimensions (Resource Group and
    Subscription name by default), leave everything else masked, and re-package
    the result as a new zip with the same structure for server-side ingestion.

.DESCRIPTION
    ResourceInventory.ps1 -Obfuscate produces a shareable report zip whose
    Subscription, Resource Group, Resource Id, Resource Name and tag VALUES are
    replaced with opaque prod_/nonprod_ tokens, plus a LOCAL
    ObfuscationDictionary_*.json that maps each token back to its real value.

    This helper takes that obfuscated zip + the matching dictionary and rewrites
    ONLY the tokens for the dimensions you select back to their real values
    across every text member of the zip (Inventory/Metrics JSON, Consumption
    CSV, the HTML report). Everything you do NOT select stays masked. The result
    is re-zipped with the SAME filenames/structure the obfuscated run produced,
    so it can be ingested by the same pipeline that ingests an obfuscated zip.

    Selectable dimensions:
      - ResourceGroup : token -> real resource group name (default ON)
      - Subscription  : token -> real subscription DISPLAY NAME (default ON)
      - Tag           : token -> real tag value (OFF unless requested)

    By DEFAULT only ResourceGroup and Subscription are revealed. Resource Ids,
    Resource Names and (unless you add -Fields Tag) tag values remain masked.

    Reveal mechanism: each selected dimension's tokens are unique
    prod_/nonprod_<guid> strings, so the rewrite is a safe literal
    token-for-real-value substitution (no schema parsing needed). Replacement
    values are JSON-escaped when rewriting .json members so the output stays
    valid JSON.

    HANDLE WITH CARE. The OUTPUT zip contains the real values you chose to
    reveal. Share it only with the party that is meant to ingest it. The
    dictionary and this script stay local.

.PARAMETER InputZip
    Path to an obfuscated report zip produced by ResourceInventory.ps1 -Obfuscate
    (e.g. ResourcesReport_<stamp>.zip).

.PARAMETER DictionaryPath
    Path to the matching ObfuscationDictionary_*.json. If omitted, the newest
    match in -SearchDirectory is used.

.PARAMETER SearchDirectory
    Directory to auto-discover the dictionary in when -DictionaryPath is omitted.
    Defaults to the current directory.

.PARAMETER Fields
    Which dimensions to reveal. Valid values: ResourceGroup, Subscription, Tag.
    Defaults to ResourceGroup and Subscription. Everything else stays masked.

.PARAMETER OutputZip
    Path for the revealed output zip. Defaults to the input zip name with a
    '_revealed' suffix, in the input zip's directory.

.EXAMPLE
    # Default: reveal Resource Group + Subscription name, leave the rest masked
    ./Reveal-Obfuscation.ps1 -InputZip ./ResourcesReport_2026....zip -DictionaryPath ./ObfuscationDictionary_2026....json

.EXAMPLE
    # Also reveal tag values
    ./Reveal-Obfuscation.ps1 -InputZip ./report.zip -DictionaryPath ./dict.json -Fields ResourceGroup,Subscription,Tag

.EXAMPLE
    # Explicit output path
    ./Reveal-Obfuscation.ps1 -InputZip ./report.zip -DictionaryPath ./dict.json -OutputZip ./report_for_ingest.zip
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]   $InputZip,

    [string]   $DictionaryPath,
    [string]   $SearchDirectory = '.',

    [ValidateSet('ResourceGroup', 'Subscription', 'Tag')]
    [string[]] $Fields = @('ResourceGroup', 'Subscription'),

    [string]   $OutputZip
)

$ErrorActionPreference = 'Stop'

# ---- Resolve inputs --------------------------------------------------------
if (-not (Test-Path -Path $InputZip -PathType Leaf))
{
    throw "Input zip not found: $InputZip"
}

if ([string]::IsNullOrEmpty($DictionaryPath))
{
    $DictionaryPath = Get-ChildItem -Path $SearchDirectory -Filter 'ObfuscationDictionary_*.json' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
}
if ([string]::IsNullOrEmpty($DictionaryPath) -or -not (Test-Path -Path $DictionaryPath -PathType Leaf))
{
    throw "No ObfuscationDictionary_*.json found. Pass -DictionaryPath, or run from the folder that holds it."
}

if ([string]::IsNullOrEmpty($OutputZip))
{
    $inDir  = Split-Path -Path $InputZip -Parent
    $inBase = [System.IO.Path]::GetFileNameWithoutExtension($InputZip)
    $OutputZip = Join-Path $inDir ($inBase + '_revealed.zip')
}

Write-Host ("Input zip   : {0}" -f $InputZip)
Write-Host ("Dictionary  : {0}" -f $DictionaryPath)
Write-Host ("Reveal      : {0}" -f ($Fields -join ', '))
Write-Host ("Output zip  : {0}" -f $OutputZip)

# ---- Load dictionary -------------------------------------------------------
$Dict = Get-Content -Path $DictionaryPath -Raw | ConvertFrom-Json

function ConvertTo-LookupTable
{
    param($MapObject)
    $Table = @{}
    if ($null -ne $MapObject)
    {
        foreach ($Property in $MapObject.PSObject.Properties)
        {
            $Table[$Property.Name] = $Property.Value
        }
    }
    return $Table
}

$RgMap      = ConvertTo-LookupTable $Dict.ResourceGroupMap
$SubMap     = ConvertTo-LookupTable $Dict.SubscriptionMap
$SubNameMap = ConvertTo-LookupTable $Dict.SubscriptionNameMap
$TagMap     = ConvertTo-LookupTable $Dict.TagMap

function Get-RgNameFromResourceId
{
    param([string]$ResourceId)
    if ($ResourceId -match '(?i)/resourceGroups/([^/]+)') { return $Matches[1] }
    return $null
}

function Get-SubGuidFromResourceId
{
    param([string]$ResourceId)
    if ($ResourceId -match '(?i)/subscriptions/([^/]+)') { return $Matches[1] }
    return $null
}

# ---- Build the token -> real-value replacement map for the selected fields -
# Tokens are unique prod_/nonprod_<guid> strings, so a single flat map keyed by
# token is unambiguous across dimensions.
$Replacements = @{}
$skipped = @{}

if ($Fields -contains 'ResourceGroup')
{
    foreach ($token in $RgMap.Keys)
    {
        $rgName = Get-RgNameFromResourceId $RgMap[$token]
        if (-not [string]::IsNullOrEmpty($rgName)) { $Replacements[$token] = $rgName }
    }
}

if ($Fields -contains 'Subscription')
{
    foreach ($token in $SubMap.Keys)
    {
        # Prefer the friendly name persisted by newer dictionaries; fall back to
        # the subscription GUID (with a warning) for older dictionaries so the
        # revealed output still carries a real subscription identifier.
        $real = $null
        if ($SubNameMap.ContainsKey($token) -and -not [string]::IsNullOrEmpty($SubNameMap[$token]))
        {
            $real = $SubNameMap[$token]
        }
        else
        {
            $real = Get-SubGuidFromResourceId $SubMap[$token]
            if (-not [string]::IsNullOrEmpty($real)) { $skipped['SubscriptionName'] = $true }
        }
        if (-not [string]::IsNullOrEmpty($real)) { $Replacements[$token] = $real }
    }
}

if ($Fields -contains 'Tag')
{
    if ($TagMap.Count -eq 0)
    {
        Write-Warning "Tag reveal requested but the dictionary has no TagMap (tags were not obfuscated in this run). Skipping Tag."
    }
    foreach ($token in $TagMap.Keys)
    {
        if (-not [string]::IsNullOrEmpty($TagMap[$token])) { $Replacements[$token] = $TagMap[$token] }
    }
}

if ($skipped.ContainsKey('SubscriptionName'))
{
    Write-Warning "One or more subscriptions had no friendly name in the dictionary (older -Obfuscate run); revealed the subscription GUID instead. Re-run the inventory with a current version to capture SubscriptionNameMap."
}

if ($Replacements.Count -eq 0)
{
    throw "Nothing to reveal: the selected field(s) [$($Fields -join ', ')] produced no token mappings from this dictionary."
}

Write-Host ("Tokens to reveal: {0}" -f $Replacements.Count)

# ---- Extract, rewrite, re-zip ----------------------------------------------
# Token shapes: plain prod_/nonprod_<guid> (Subscription/ResourceGroup/Tag) and
# type-hinted name tokens (prod_aks_<guid>, etc.) - the regex matches both; the
# callback only substitutes tokens present in $Replacements, so non-selected
# dimensions (Resource Id/Name) are left masked.
$tokenPattern = '(?:prod|nonprod)_(?:[a-z0-9]+_)?[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'

function Get-JsonEscaped
{
    # Return the input string escaped for placement INSIDE a JSON string literal
    # (ConvertTo-Json wraps + escapes; strip the surrounding quotes).
    param([string]$Text)
    $json = $Text | ConvertTo-Json -Compress
    return $json.Substring(1, $json.Length - 2)
}

$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("Reveal_" + [guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null

try
{
    Expand-Archive -Path $InputZip -DestinationPath $tmpRoot -Force

    # Reveal selected tokens inside a single string. The replacement value is
    # escaped to match the destination format so a revealed value containing
    # special characters (e.g. a subscription display name with '&', or a
    # free-text tag value) stays valid in that file:
    #   Json -> escaped for a JSON string literal
    #   Html -> HTML-entity encoded (the report encodes every rendered value)
    #   None -> raw (CSV field values are re-quoted by Export-Csv instead)
    # Tokens not in $Replacements are returned unchanged, so unselected
    # dimensions stay masked. Increments $script:fileHits per substituted token.
    function Convert-RevealString
    {
        param([string]$Text, [string]$EscapeMode = 'None')
        return [regex]::Replace($Text, $tokenPattern, {
                param($m)
                $tok = $m.Value
                if ($Replacements.ContainsKey($tok))
                {
                    $script:fileHits++
                    $val = $Replacements[$tok]
                    switch ($EscapeMode)
                    {
                        'Json' { return (Get-JsonEscaped $val) }
                        'Html' { return [System.Net.WebUtility]::HtmlEncode($val) }
                        default { return $val }
                    }
                }
                return $tok
            })
    }

    $totalHits = 0
    $files = Get-ChildItem -Path $tmpRoot -Recurse -File
    foreach ($file in $files)
    {
        $script:fileHits = 0
        $ext = $file.Extension.ToLowerInvariant()

        if ($ext -eq '.csv')
        {
            # Field-aware reveal: re-export through the CSV writer so a revealed
            # value that contains a comma/quote (e.g. a subscription display name
            # like "Contoso, Inc." or a free-text tag value) is correctly quoted
            # and cannot break the column structure the way a raw text replace
            # could.
            $rows = @(Import-Csv -Path $file.FullName)
            if ($rows.Count -gt 0)
            {
                foreach ($row in $rows)
                {
                    foreach ($prop in $row.PSObject.Properties)
                    {
                        if ($null -ne $prop.Value -and $prop.Value -is [string] -and $prop.Value.Length -gt 0)
                        {
                            $prop.Value = Convert-RevealString -Text $prop.Value -EscapeMode 'None'
                        }
                    }
                }
                if ($script:fileHits -gt 0)
                {
                    $rows | Export-Csv -Path $file.FullName -NoTypeInformation -Encoding utf8
                }
            }
        }
        else
        {
            $content = Get-Content -Path $file.FullName -Raw
            if ([string]::IsNullOrEmpty($content)) { continue }

            $escapeMode = switch ($ext)
            {
                '.json' { 'Json' }
                '.html' { 'Html' }
                '.htm'  { 'Html' }
                default { 'None' }
            }
            $newContent = Convert-RevealString -Text $content -EscapeMode $escapeMode

            if ($script:fileHits -gt 0)
            {
                Set-Content -Path $file.FullName -Value $newContent -Encoding utf8 -NoNewline
            }
        }

        if ($script:fileHits -gt 0)
        {
            $totalHits += $script:fileHits
            Write-Host ("  {0}: revealed {1} token occurrence(s)" -f $file.Name, $script:fileHits)
        }
    }

    if (Test-Path -Path $OutputZip) { Remove-Item -Path $OutputZip -Force }
    Compress-Archive -Path (Join-Path $tmpRoot '*') -DestinationPath $OutputZip -Force

    Write-Host ""
    Write-Host ("Done. Revealed {0} token occurrence(s) across {1} member file(s)." -f $totalHits, @($files).Count) -ForegroundColor Green
    Write-Host ("Output: {0}" -f $OutputZip) -ForegroundColor Green
    Write-Host "This zip contains the real values you chose to reveal - share only with the intended ingestion party."
}
finally
{
    if (Test-Path -Path $tmpRoot) { Remove-Item -Path $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
