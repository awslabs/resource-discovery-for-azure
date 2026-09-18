#Requires -Version 7.0
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
    param([string]$Text)
    $Json = $Text | ConvertTo-Json -Compress
    return $Json.Substring(1, $Json.Length - 2)
}

function Convert-RevealString
{
    param([string]$Text, [string]$EscapeMode = 'None')
    if (-not ($Text.Contains('prod_') -or $Text.Contains('nonprod_')))
    {
        return $Text
    }
    return [regex]::Replace($Text, $TokenPattern, {
            param($m)
            $Tok = $m.Value
            if ($Replacements.ContainsKey($Tok))
            {
                $script:FileHits++
                $Val = $Replacements[$Tok]
                switch ($EscapeMode)
                {
                    'Json' { return (Get-JsonEscaped $Val) }
                    'Html' { return [System.Net.WebUtility]::HtmlEncode($Val) }
                    default { return $Val }
                }
            }
            return $Tok
        })
}

function Invoke-RdaReveal
{
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'TokenPattern',
        Justification = 'Read cross-scope by Convert-RevealString via parent-scope dynamic lookup.')]
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

    if (-not (Test-Path -LiteralPath $InputZip -PathType Leaf))
    {
        throw "Input zip not found: $InputZip"
    }

    if ([string]::IsNullOrEmpty($DictionaryPath))
    {
        $DictionaryPath = Get-ChildItem -LiteralPath $SearchDirectory -Filter 'ObfuscationDictionary_*.json' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
    if ([string]::IsNullOrEmpty($DictionaryPath) -or -not (Test-Path -LiteralPath $DictionaryPath -PathType Leaf))
    {
        throw "No ObfuscationDictionary_*.json found. Pass -DictionaryPath, or run from the folder that holds it."
    }

    if ([string]::IsNullOrEmpty($OutputZip))
    {
        $InDir = Split-Path -Path $InputZip -Parent
        $InBase = [System.IO.Path]::GetFileNameWithoutExtension($InputZip)
        $OutputZip = Join-Path $InDir ($InBase + '_revealed.zip')
    }

    if ($All)
    {
        $Fields = @('ResourceGroup', 'Subscription', 'Tag', 'ResourceName', 'ResourceId', 'FreeText')
    }

    Write-Host ("Input zip   : {0}" -f $InputZip)
    Write-Host ("Dictionary  : {0}" -f $DictionaryPath)
    Write-Host ("Reveal      : {0}{1}" -f ($Fields -join ', '), $(if ($All) { ' (-All: full reveal)' } else { '' }))
    Write-Host ("Output zip  : {0}" -f $OutputZip)

    $Dict = Get-Content -LiteralPath $DictionaryPath -Raw | ConvertFrom-Json

    $RgMap = ConvertTo-LookupTable $Dict.ResourceGroupMap
    $SubMap = ConvertTo-LookupTable $Dict.SubscriptionMap
    $SubNameMap = ConvertTo-LookupTable $Dict.SubscriptionNameMap
    $TagMap = ConvertTo-LookupTable $Dict.TagMap
    $IdMap = ConvertTo-LookupTable $Dict.ResourceIdMap
    $NameMap = ConvertTo-LookupTable $Dict.ResourceNameMap
    $FreeTextMap = ConvertTo-LookupTable $Dict.FreeTextMap

    $Replacements = @{}
    $Skipped = @{}

    if ($Fields -contains 'ResourceGroup')
    {
        foreach ($token in $RgMap.Keys)
        {
            $RgName = Get-RgNameFromResourceId $RgMap[$token]
            if (-not [string]::IsNullOrEmpty($RgName)) { $Replacements[$token] = $RgName }
        }
    }

    if ($Fields -contains 'Subscription')
    {
        foreach ($token in $SubMap.Keys)
        {
            $Real = $null
            if ($SubNameMap.ContainsKey($token) -and -not [string]::IsNullOrEmpty($SubNameMap[$token]))
            {
                $Real = $SubNameMap[$token]
            }
            else
            {
                $Real = Get-SubGuidFromResourceId $SubMap[$token]
                if (-not [string]::IsNullOrEmpty($Real)) { $Skipped['SubscriptionName'] = $true }
            }
            if (-not [string]::IsNullOrEmpty($Real)) { $Replacements[$token] = $Real }
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
        foreach ($token in $NameMap.Keys)
        {
            $Name = ($NameMap[$token] -split '/')[-1]
            if (-not [string]::IsNullOrEmpty($Name)) { $Replacements[$token] = $Name }
        }
    }

    if ($Fields -contains 'ResourceId')
    {
        foreach ($token in $IdMap.Keys)
        {
            if (-not [string]::IsNullOrEmpty($IdMap[$token])) { $Replacements[$token] = $IdMap[$token] }
        }
    }

    if ($Fields -contains 'FreeText')
    {
        foreach ($token in $FreeTextMap.Keys)
        {
            if (-not [string]::IsNullOrEmpty($FreeTextMap[$token])) { $Replacements[$token] = $FreeTextMap[$token] }
        }
    }

    if ($Skipped.ContainsKey('SubscriptionName'))
    {
        Write-Warning "One or more subscriptions had no friendly name in the dictionary (older -Obfuscate run); revealed the subscription GUID instead. Re-run the inventory with a current version to capture SubscriptionNameMap."
    }

    if ($Replacements.Count -eq 0)
    {
        throw "Nothing to reveal: the selected field(s) [$($Fields -join ', ')] produced no token mappings from this dictionary."
    }

    Write-Host ("Tokens to reveal: {0}" -f $Replacements.Count)

    $TokenPattern = '(?:prod|nonprod)_(?:[a-z0-9]+_)?[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'

    $TmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("Reveal_" + [guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Path $TmpRoot -Force | Out-Null

    try
    {
        $EmitProgress = [bool](Get-Command -Name Write-RdaProgress -ErrorAction SilentlyContinue)
        if ($EmitProgress) { Write-RdaProgress -Activity 'Revealing report' -CurrentItem 'Expanding archive' -Index 1 -Total 3 }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($InputZip, $TmpRoot)

        $TotalHits = 0
        $Files = Get-ChildItem -LiteralPath $TmpRoot -Recurse -File
        if ($EmitProgress) { Write-RdaProgress -Activity 'Revealing report' -CurrentItem ('Scanning {0} member file(s)' -f @($Files).Count) -Index 2 -Total 3 }
        foreach ($file in $Files)
        {
            $script:FileHits = 0
            $Ext = $file.Extension.ToLowerInvariant()

            if ($Ext -eq '.csv')
            {
                $Rows = @(Import-Csv -LiteralPath $file.FullName)
                if ($Rows.Count -gt 0)
                {
                    foreach ($row in $Rows)
                    {
                        foreach ($prop in $row.PSObject.Properties)
                        {
                            if ($null -ne $prop.Value -and $prop.Value -is [string] -and $prop.Value.Length -gt 0)
                            {
                                $prop.Value = Convert-RevealString -Text $prop.Value -EscapeMode 'None'
                            }
                        }
                    }
                    if ($script:FileHits -gt 0)
                    {
                        $Rows | Export-Csv -LiteralPath $file.FullName -NoTypeInformation -Encoding utf8
                    }
                }
            }
            else
            {
                $Content = Get-Content -LiteralPath $file.FullName -Raw
                if ([string]::IsNullOrEmpty($Content)) { continue }

                $EscapeMode = switch ($Ext)
                {
                    '.json' { 'Json' }
                    '.html' { 'Html' }
                    '.htm' { 'Html' }
                    default { 'None' }
                }
                $NewContent = Convert-RevealString -Text $Content -EscapeMode $EscapeMode

                if ($script:FileHits -gt 0)
                {
                    Set-Content -LiteralPath $file.FullName -Value $NewContent -Encoding utf8 -NoNewline
                }
            }

            if ($script:FileHits -gt 0)
            {
                $TotalHits += $script:FileHits
                Write-Host ("  {0}: revealed {1} token occurrence(s)" -f $file.Name, $script:FileHits)
            }
        }

        if ($EmitProgress) { Write-RdaProgress -Activity 'Revealing report' -CurrentItem 'Compressing output' -Index 3 -Total 3 }
        $OutputZipPartial = ($OutputZip -replace '\.zip$', '') + '.partial.zip'
        if (Test-Path -LiteralPath $OutputZipPartial) { Remove-Item -LiteralPath $OutputZipPartial -Force }
        [System.IO.Compression.ZipFile]::CreateFromDirectory($TmpRoot, $OutputZipPartial, [System.IO.Compression.CompressionLevel]::Optimal, $false)
        [System.IO.File]::Move($OutputZipPartial, $OutputZip, $true)
        if ($EmitProgress) { Write-RdaProgress -Activity 'Revealing report' -Completed }

        Write-Host ""
        Write-Host ("Done. Revealed {0} token occurrence(s) across {1} member file(s)." -f $TotalHits, @($Files).Count) -ForegroundColor Green
        Write-Host ("Output: {0}" -f $OutputZip) -ForegroundColor Green
        if ($All)
        {
            Write-Host "Full reveal: all dictionary-backed dimensions restored. Fields nulled at obfuscation time (e.g. Description) or marked 'obfuscated' are lossy and remain so." -ForegroundColor Yellow
        }
        Write-Host "This zip contains the real values you chose to reveal - share only with the intended ingestion party."
    }
    finally
    {
        if (Test-Path -LiteralPath $TmpRoot) { Remove-Item -LiteralPath $TmpRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

