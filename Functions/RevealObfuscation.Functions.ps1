#Requires -Version 7.0
# =============================================================================
# RevealObfuscation.Functions.ps1
#
# Shared helper functions AND the single-report reveal engine (Invoke-RdaReveal)
# for the reveal feature. Dot-sourced by Reveal.ps1 (and by the child jobs it
# spawns for the multi-subscription path) so they load into that scope.
# Definitions only - no top-level code. Convert-RevealString references
# $Replacements / $tokenPattern / $script:fileHits which Invoke-RdaReveal (its
# caller) establishes before invoking it, so the parent-scope lookup is safe.
# =============================================================================
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

function Get-JsonEscaped
{
    # Return the input string escaped for placement INSIDE a JSON string literal
    # (ConvertTo-Json wraps + escapes; strip the surrounding quotes).
    param([string]$Text)
    $json = $Text | ConvertTo-Json -Compress
    return $json.Substring(1, $json.Length - 2)
}

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


# =============================================================================
# Invoke-RdaReveal
#
# The single-report reveal ENGINE, moved here from the former standalone
# Reveal-Obfuscation.ps1 so the whole reveal feature lives in ONE entry script
# (Reveal.ps1) that handles both a single report and a whole multi-subscription
# tree. Takes one obfuscated report zip + its dictionary, rewrites ONLY the
# selected dimensions' tokens back to real values, and re-zips with the same
# structure.
#
# Scope note: this function sets $Replacements and $tokenPattern as LOCALS and
# calls Convert-RevealString, which reads them via PowerShell's parent-scope
# (dynamic) variable lookup, and increments $script:fileHits (the dot-sourcing
# entry script's script scope). That is the same contract the old top-level
# script provided - just nested one function deep - so the helpers behave
# identically. Raises terminating errors via throw (never exit) so a caller /
# Start-Job can catch them.
# =============================================================================
function Invoke-RdaReveal
{
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

    $ErrorActionPreference = 'Stop'

    # ---- Resolve inputs ----------------------------------------------------
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
    # dictionary can reverse (overriding -Fields). NOTE this is NOT a perfect
    # undo of -Obfuscate: fields that were nulled or stamped with the lossy
    # 'obfuscated' sentinel are destroyed at obfuscation time. Everything stored
    # in the dictionary comes back.
    if ($All)
    {
        $Fields = @('ResourceGroup', 'Subscription', 'Tag', 'ResourceName', 'ResourceId', 'FreeText')
    }

    Write-Host ("Input zip   : {0}" -f $InputZip)
    Write-Host ("Dictionary  : {0}" -f $DictionaryPath)
    Write-Host ("Reveal      : {0}{1}" -f ($Fields -join ', '), $(if ($All) { ' (-All: full reveal)' } else { '' }))
    Write-Host ("Output zip  : {0}" -f $OutputZip)

    # ---- Load dictionary ---------------------------------------------------
    $Dict = Get-Content -Path $DictionaryPath -Raw | ConvertFrom-Json

    $RgMap       = ConvertTo-LookupTable $Dict.ResourceGroupMap
    $SubMap      = ConvertTo-LookupTable $Dict.SubscriptionMap
    $SubNameMap  = ConvertTo-LookupTable $Dict.SubscriptionNameMap
    $TagMap      = ConvertTo-LookupTable $Dict.TagMap
    $IdMap       = ConvertTo-LookupTable $Dict.ResourceIdMap
    $NameMap     = ConvertTo-LookupTable $Dict.ResourceNameMap
    $FreeTextMap = ConvertTo-LookupTable $Dict.FreeTextMap

    # ---- Build token -> real-value replacement map for selected fields -----
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
        # ResourceIdMap stores token -> the full real ARM resource Id. Revealing
        # this also exposes the subscription GUID and resource group name in the
        # path - inherent to revealing the Id and the caller's choice.
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

    # ---- Extract, rewrite, re-zip ------------------------------------------
    # Token shapes: plain prod_/nonprod_<guid> and type-hinted name tokens
    # (prod_aks_<guid>, etc.) - the regex matches both; the callback only
    # substitutes tokens present in $Replacements, so non-selected dimensions
    # are left masked.
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
                # Field-aware reveal: re-export through the CSV writer so a
                # revealed value containing a comma/quote is correctly quoted and
                # cannot break the column structure a raw text replace could.
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
}
