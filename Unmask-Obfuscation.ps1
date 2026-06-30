#Requires -Version 7.0
<#
.SYNOPSIS
    Reverse-lookup (unmask) helper for the Azure Resource Discovery -Obfuscate
    feature. Resolves obfuscated Subscription and Resource Group values (and
    optionally Resource Id / Resource Name) back to their real values using a
    local ObfuscationDictionary_*.json file.

.DESCRIPTION
    When ResourceInventory.ps1 runs with -Obfuscate it writes a local
    ObfuscationDictionary_*.json. Its four core maps resolve an obfuscated value
    to the REAL Azure RESOURCE ID it came from (an ARM path), NOT to a bare name:

        ResourceIdMap     obfuscatedId   -> real resource Id
        ResourceNameMap   obfuscatedName -> real resource Id
        SubscriptionMap   obfuscatedSub  -> real resource Id
        ResourceGroupMap  obfuscatedRg   -> real resource Id

    Newer dictionaries also include a fifth map that stores the friendly name
    directly, so the subscription name resolves fully offline:

        SubscriptionNameMap  obfuscatedSub -> real subscription display name

    Therefore:
      - Resource Group NAME is parsed from '/resourceGroups/<name>' in the Id
        (exact, offline).
      - Subscription NAME is read from SubscriptionNameMap when present (offline).
        For older dictionaries that lack it, the subscription resolves only to
        the GUID parsed from '/subscriptions/<guid>'; pass -ResolveSubscriptionName
        to look the name up online via Get-AzSubscription (requires the Az module
        and an authenticated session).

    LOCAL USE ONLY. This script and the dictionary it reads must stay with the
    customer. Never share the dictionary or this script's output externally.

.PARAMETER DictionaryPath
    Path to an ObfuscationDictionary_*.json file. If omitted, the newest match
    in -SearchDirectory is used.

.PARAMETER SearchDirectory
    Directory to auto-discover the dictionary in when -DictionaryPath is omitted.
    Defaults to the current directory.

.PARAMETER Value
    One or more obfuscated values to unmask (e.g. 'prod_1a2b3c...'). Accepts
    pipeline input.

.PARAMETER Field
    Restrict unmasking to one or more field types. Valid values:
    Subscription, ResourceGroup, ResourceId, ResourceName, Tag. If omitted, ALL
    field types are considered. When a specific -Value is also a key in more
    than one map (rare; obfuscated tokens are unique), only the selected
    field types are searched, in the order ResourceGroup, Subscription,
    ResourceId, ResourceName, Tag. With -All, only the selected field types are dumped.

.PARAMETER All
    Dump every mapping for the selected -Field types (defaults to Subscription
    and ResourceGroup when -Field is omitted) instead of specific values.

.PARAMETER ResolveSubscriptionName
    For Subscription matches, call Get-AzSubscription to turn the GUID into its
    friendly name. Only needed for OLDER dictionaries that lack SubscriptionNameMap;
    when that map is present the friendly name is resolved offline and this switch
    is ignored. Requires the Az module and an authenticated session.

.EXAMPLE
    ./Unmask-Obfuscation.ps1 -DictionaryPath ./ObfuscationDictionary_Contoso_2026...json -Value 'prod_8f...'

.EXAMPLE
    # Only resolve Resource Group values, ignore everything else
    'prod_8f...','nonprod_2a...' | ./Unmask-Obfuscation.ps1 -Field ResourceGroup

.EXAMPLE
    # Dump only Subscription mappings
    ./Unmask-Obfuscation.ps1 -All -Field Subscription -ResolveSubscriptionName | Format-Table -AutoSize

.EXAMPLE
    # Dump both Subscription and Resource Group mappings (default -All scope)
    ./Unmask-Obfuscation.ps1 -All | Format-Table -AutoSize
#>
[CmdletBinding()]
param(
    [string]   $DictionaryPath,
    [string]   $SearchDirectory = '.',

    [Parameter(ValueFromPipeline = $true)]
    [string[]] $Value,

    [ValidateSet('Subscription', 'ResourceGroup', 'ResourceId', 'ResourceName', 'Tag')]
    [string[]] $Field,

    [switch]   $All,
    [switch]   $ResolveSubscriptionName
)

begin
{
    # ---- Resolve and load the dictionary -----------------------------------
    if ([string]::IsNullOrEmpty($DictionaryPath))
    {
        $DictionaryPath = Get-ChildItem -Path $SearchDirectory -Filter 'ObfuscationDictionary_*.json' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
    if ([string]::IsNullOrEmpty($DictionaryPath) -or -not (Test-Path -Path $DictionaryPath -PathType Leaf))
    {
        throw "No ObfuscationDictionary_*.json found. Pass -DictionaryPath, or run from the folder that holds it."
    }

    Write-Verbose ("Using dictionary: {0}" -f $DictionaryPath)
    $Dict = Get-Content -Path $DictionaryPath -Raw | ConvertFrom-Json

    foreach ($MapName in 'SubscriptionMap', 'ResourceGroupMap', 'ResourceIdMap', 'ResourceNameMap')
    {
        if ($Dict.PSObject.Properties.Name -notcontains $MapName)
        {
            throw "Dictionary is missing '$MapName'. Is this a valid ObfuscationDictionary file?"
        }
    }

    # Which field types are in scope. Empty/absent -Field means all of them.
    $SelectedFields = if ($null -eq $Field -or $Field.Count -eq 0)
    {
        @('ResourceGroup', 'Subscription', 'ResourceId', 'ResourceName', 'Tag')
    }
    else
    {
        # De-dupe while preserving the canonical search precedence.
        @('ResourceGroup', 'Subscription', 'ResourceId', 'ResourceName', 'Tag') | Where-Object { $Field -contains $_ }
    }
    Write-Verbose ("Field types in scope: {0}" -f ($SelectedFields -join ', '))

    # Flatten the JSON maps into hashtables once for O(1), variable-safe lookups
    # (obfuscated values are prod_/nonprod_<guid>, but a hashtable avoids any
    # dynamic-property-name edge cases).
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

    $RgMap   = ConvertTo-LookupTable $Dict.ResourceGroupMap
    $SubMap  = ConvertTo-LookupTable $Dict.SubscriptionMap
    $IdMap   = ConvertTo-LookupTable $Dict.ResourceIdMap
    $NameMap = ConvertTo-LookupTable $Dict.ResourceNameMap
    # Optional: friendly subscription names persisted by newer -Obfuscate runs.
    # Absent from dictionaries written by older versions (which is why it is NOT
    # in the required-map check above), so this is backward-compatible: an old
    # dictionary simply yields an empty table and the GUID/-ResolveSubscriptionName
    # behaviour below is unchanged.
    $SubNameMap = ConvertTo-LookupTable $Dict.SubscriptionNameMap
    # Optional: maps an obfuscated tag-value token back to the real tag value.
    # Present in dictionaries from runs where tag obfuscation was active; absent
    # otherwise, so it is not in the required-map check above.
    $TagMap = ConvertTo-LookupTable $Dict.TagMap

    # Map a field-type label to its lookup table, so -Field selection and the
    # search loop share one source of truth.
    $MapForField = @{
        ResourceGroup = $RgMap
        Subscription  = $SubMap
        ResourceId    = $IdMap
        ResourceName  = $NameMap
        Tag           = $TagMap
    }

    $SubNameCache = @{}

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

    function Resolve-SubName
    {
        param([string]$SubGuid)
        if ([string]::IsNullOrEmpty($SubGuid)) { return $null }
        if ($SubNameCache.ContainsKey($SubGuid)) { return $SubNameCache[$SubGuid] }

        $Name = $null
        try
        {
            $Sub  = Get-AzSubscription -SubscriptionId $SubGuid -ErrorAction Stop
            $Name = $Sub.Name
        }
        catch
        {
            Write-Warning ("Could not resolve subscription {0} to a name (need Az module + sign-in): {1}" -f $SubGuid, $_.Exception.Message)
        }
        $SubNameCache[$SubGuid] = $Name
        return $Name
    }

    # Build the result object for a single field-type hit. Centralised so the
    # derivation rules (RG name, sub GUID, resource name) live in one place.
    function New-UnmaskResult
    {
        param([string]$Obf, [string]$Type, [string]$ResourceId)

        switch ($Type)
        {
            'ResourceGroup'
            {
                return [pscustomobject]@{
                    ObfuscatedValue = $Obf
                    Type            = 'ResourceGroup'
                    RealValue       = (Get-RgNameFromResourceId $ResourceId)
                    RealResourceId  = $ResourceId
                    Note            = $null
                }
            }
            'Subscription'
            {
                $SubGuid = Get-SubGuidFromResourceId $ResourceId
                $Real    = $SubGuid
                $Note    = "Dictionary yields the subscription GUID. Use -ResolveSubscriptionName for the friendly name."
                if ($null -ne $SubNameMap -and $SubNameMap.ContainsKey($Obf) -and -not [string]::IsNullOrEmpty($SubNameMap[$Obf]))
                {
                    # Newer dictionaries persist the friendly name, so resolve it
                    # fully offline (no Azure call) - this is the preferred path.
                    $Real = $SubNameMap[$Obf]
                    $Note = ("Subscription GUID: {0} (name resolved offline from dictionary)" -f $SubGuid)
                }
                elseif ($ResolveSubscriptionName)
                {
                    $ResolvedName = Resolve-SubName $SubGuid
                    if (-not [string]::IsNullOrEmpty($ResolvedName))
                    {
                        $Real = $ResolvedName
                        $Note = ("Subscription GUID: {0}" -f $SubGuid)
                    }
                }
                return [pscustomobject]@{
                    ObfuscatedValue = $Obf
                    Type            = 'Subscription'
                    RealValue       = $Real
                    RealResourceId  = $ResourceId
                    Note            = $Note
                }
            }
            'ResourceId'
            {
                return [pscustomobject]@{
                    ObfuscatedValue = $Obf
                    Type            = 'ResourceId'
                    RealValue       = $ResourceId
                    RealResourceId  = $ResourceId
                    Note            = $null
                }
            }
            'ResourceName'
            {
                return [pscustomobject]@{
                    ObfuscatedValue = $Obf
                    Type            = 'ResourceName'
                    RealValue       = ($ResourceId -split '/')[-1]
                    RealResourceId  = $ResourceId
                    Note            = $null
                }
            }
            'Tag'
            {
                # TagMap stores token -> real tag VALUE directly (not a resource Id),
                # so the value passed in is already the real tag value.
                return [pscustomobject]@{
                    ObfuscatedValue = $Obf
                    Type            = 'Tag'
                    RealValue       = $ResourceId
                    RealResourceId  = $null
                    Note            = 'Tag value (key is preserved verbatim in the report).'
                }
            }
        }
    }

    function Resolve-Value
    {
        param([string]$Obf)

        if ([string]::IsNullOrEmpty($Obf)) { return }

        # Lossy-by-design markers are intentionally NOT in the dictionary:
        #   'obfuscated'        -> literal sentinel stamped on cross-ref fields
        #   'obfuscated_<guid>' -> malformed/null-Id row fallback
        # Reported regardless of -Field so the caller always learns why a value
        # is unrecoverable.
        if ($Obf -eq 'obfuscated' -or $Obf -like 'obfuscated_*')
        {
            return [pscustomobject]@{
                ObfuscatedValue = $Obf
                Type            = 'Lossy'
                RealValue       = $null
                RealResourceId  = $null
                Note            = "Lossy field (literal 'obfuscated' or malformed-id fallback); not recoverable by design."
            }
        }

        # Search only the selected field maps, in canonical precedence.
        foreach ($FieldType in $SelectedFields)
        {
            $Table = $MapForField[$FieldType]
            if ($Table.ContainsKey($Obf))
            {
                return (New-UnmaskResult -Obf $Obf -Type $FieldType -ResourceId $Table[$Obf])
            }
        }

        $ScopeNote = if ($SelectedFields.Count -lt $MapForField.Count)
        {
            ("Not found in selected field(s): {0}. It may belong to a field type you did not select." -f ($SelectedFields -join ', '))
        }
        else
        {
            "Not present in any map. Check the value, or it may be a preserved (never-obfuscated) field."
        }

        return [pscustomobject]@{
            ObfuscatedValue = $Obf
            Type            = 'NotFound'
            RealValue       = $null
            RealResourceId  = $null
            Note            = $ScopeNote
        }
    }
}

process
{
    if ($All) { return }
    foreach ($Item in $Value) { Resolve-Value $Item }
}

end
{
    if (-not $All) { return }

    # -All dumps the selected field maps. When -Field is omitted, default the
    # dump to the two identity fields customers care about most (Subscription
    # and Resource Group) rather than every resource Id/Name in the estate.
    $DumpFields = if ($null -eq $Field -or $Field.Count -eq 0)
    {
        @('ResourceGroup', 'Subscription')
    }
    else
    {
        $SelectedFields
    }

    foreach ($FieldType in $DumpFields)
    {
        $Table = $MapForField[$FieldType]
        foreach ($Key in $Table.Keys) { Resolve-Value $Key }
    }
}
