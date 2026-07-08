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
      - ResourceName  : token -> real resource short name (OFF unless requested)
      - ResourceId    : token -> real full ARM resource Id (OFF unless requested)
      - FreeText      : token -> real free-form value, e.g. Description,
                        FriendlyName, CreatedBy, RoleName, container image
                        (OFF unless requested)

    By DEFAULT only ResourceGroup and Subscription are revealed; everything else
    stays masked until you name it in -Fields. Note that revealing ResourceId
    un-masks the FULL ARM path, which embeds the real subscription GUID and
    resource group name for that resource.

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
    Which dimensions to reveal. Valid values: ResourceGroup, Subscription, Tag,
    ResourceName, ResourceId, FreeText. Defaults to ResourceGroup and
    Subscription. Anything not listed stays masked. Ignored when -All is supplied.

.PARAMETER All
    Reveal every dimension the dictionary can reverse (ResourceGroup,
    Subscription, Tag, ResourceName, ResourceId, FreeText) - a full
    un-obfuscate, as if the report had been produced without -Obfuscate.
    Overrides -Fields.

    This is NOT a perfect byte-for-byte undo: fields that obfuscation DESTROYS
    rather than tokenizes are not recoverable - notably any value nulled at
    obfuscation time (e.g. Description) and any cross-reference stamped with the
    lossy 'obfuscated' / 'obfuscated_<guid>' sentinel (out-of-scope or
    malformed-row targets). Everything stored in the dictionary is restored.

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

.EXAMPLE
    # Full reveal - un-obfuscate everything the dictionary can reverse
    ./Reveal-Obfuscation.ps1 -InputZip ./report.zip -DictionaryPath ./dict.json -All
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]   $InputZip,

    [string]   $DictionaryPath,
    [string]   $SearchDirectory = '.',

    [ValidateSet('ResourceGroup', 'Subscription', 'Tag', 'ResourceName', 'ResourceId', 'FreeText')]
    [string[]] $Fields = @('ResourceGroup', 'Subscription'),

    [switch]   $All,

    [string]   $OutputZip
)

# ---------------------------------------------------------------------------
# Load shared helper functions. Dot-sourced (NOT invoked via &) so they load
# into this script's scope. Fail loud if the file is missing rather than
# breaking later with a confusing "command not found".
# ---------------------------------------------------------------------------
$FunctionsFile = Join-Path $PSScriptRoot 'Functions/RevealObfuscation.Functions.ps1'
if (-not (Test-Path -Path $FunctionsFile -PathType Leaf))
{
    Write-Host "ERROR: Required functions file not found: $FunctionsFile" -ForegroundColor Red
    Write-Host "Ensure the 'Functions' folder ships alongside this script." -ForegroundColor Yellow
    exit 1
}
. $FunctionsFile

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

# -All is a convenience for a full reveal: expand to every dimension the
# dictionary can reverse (overriding -Fields). NOTE this is NOT a perfect undo
# of -Obfuscate: fields that were nulled (e.g. Description) or stamped with the
# lossy 'obfuscated' / 'obfuscated_<guid>' sentinel are destroyed at obfuscation
# time and cannot be restored. Everything stored in the dictionary comes back.
if ($All)
{
    $Fields = @('ResourceGroup', 'Subscription', 'Tag', 'ResourceName', 'ResourceId', 'FreeText')
}

Write-Host ("Input zip   : {0}" -f $InputZip)
Write-Host ("Dictionary  : {0}" -f $DictionaryPath)
Write-Host ("Reveal      : {0}{1}" -f ($Fields -join ', '), $(if ($All) { ' (-All: full reveal)' } else { '' }))
Write-Host ("Output zip  : {0}" -f $OutputZip)

# ---- Load dictionary -------------------------------------------------------
$Dict = Get-Content -Path $DictionaryPath -Raw | ConvertFrom-Json


$RgMap      = ConvertTo-LookupTable $Dict.ResourceGroupMap
$SubMap     = ConvertTo-LookupTable $Dict.SubscriptionMap
$SubNameMap = ConvertTo-LookupTable $Dict.SubscriptionNameMap
$TagMap     = ConvertTo-LookupTable $Dict.TagMap
$IdMap      = ConvertTo-LookupTable $Dict.ResourceIdMap
$NameMap    = ConvertTo-LookupTable $Dict.ResourceNameMap
$FreeTextMap = ConvertTo-LookupTable $Dict.FreeTextMap



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

if ($Fields -contains 'ResourceName')
{
    # ResourceNameMap stores token -> real resource Id; the short name is the
    # last '/'-delimited segment of that Id.
    foreach ($token in $NameMap.Keys)
    {
        $name = ($NameMap[$token] -split '/')[-1]
        if (-not [string]::IsNullOrEmpty($name)) { $Replacements[$token] = $name }
    }
}

if ($Fields -contains 'ResourceId')
{
    # ResourceIdMap stores token -> the full real ARM resource Id. Revealing this
    # also exposes the subscription GUID and resource group name embedded in the
    # path - that is inherent to revealing the Id and is the caller's choice.
    foreach ($token in $IdMap.Keys)
    {
        if (-not [string]::IsNullOrEmpty($IdMap[$token])) { $Replacements[$token] = $IdMap[$token] }
    }
}

if ($Fields -contains 'FreeText')
{
    # FreeTextMap stores token -> the real free-form value (Description,
    # FriendlyName, CreatedBy, RoleName, container image, etc.).
    foreach ($token in $FreeTextMap.Keys)
    {
        if (-not [string]::IsNullOrEmpty($FreeTextMap[$token])) { $Replacements[$token] = $FreeTextMap[$token] }
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


$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("Reveal_" + [guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null

try
{
    Expand-Archive -Path $InputZip -DestinationPath $tmpRoot -Force


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
    if ($All)
    {
        Write-Host "Full reveal: all dictionary-backed dimensions restored. Fields nulled at obfuscation time (e.g. Description) or marked 'obfuscated' are lossy and remain so." -ForegroundColor Yellow
    }
    Write-Host "This zip contains the real values you chose to reveal - share only with the intended ingestion party."
}
finally
{
    if (Test-Path -Path $tmpRoot) { Remove-Item -Path $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
