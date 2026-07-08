#Requires -Version 7.0
# =============================================================================
# RevealObfuscation.Functions.ps1
#
# Shared helper functions for Reveal-Obfuscation.ps1. Dot-sourced from the top
# of that script so they load into its scope. Definitions only - no top-level
# code. The functions reference script-scoped values ($Replacements,
# $tokenPattern, $script:fileHits) that Reveal-Obfuscation.ps1 sets before it
# ever calls them, so load order is safe.
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

