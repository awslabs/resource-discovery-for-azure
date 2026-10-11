#Requires -Version 7.0

function Merge-RecoveryData
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$GapBundlePath,

        [Parameter(Mandatory)][string]$RecoveryBundlePath,

        [Parameter(Mandatory)][string]$OutputPath,

        [string[]]$Service,

        [switch]$RecoverConsumption,

        [switch]$RecoverMetrics
    )

    $ErrorActionPreference = 'Stop'

    $MergeWarnings = [System.Collections.Generic.List[string]]::new()
    function Add-MergeWarning([string]$Message)
    {
        Write-Warning ('Merge-RecoveryData: ' + $Message)
        $MergeWarnings.Add($Message)
    }

    function Get-ConsumptionCsvStats([string]$Path)
    {
        $Rows = @(Import-Csv -LiteralPath $Path -ErrorAction Stop)
        $Starts = @($Rows | ForEach-Object { $_.UsageStartTime } | Where-Object { $_ } | Sort-Object -Unique)
        $Ends = @($Rows | ForEach-Object { $_.UsageEndTime } | Where-Object { $_ } | Sort-Object -Unique)
        [PSCustomObject]@{
            RowCount = @($Rows).Count
            MinStart = ($Starts | Select-Object -First 1)
            MaxEnd   = ($Ends | Select-Object -Last 1)
        }
    }

    function Test-DictionaryMatchesInventory
    {
        param([string]$DictionaryPath, [string]$InventoryPath)

        $DictKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $Dict = Get-Content -LiteralPath $DictionaryPath -Raw | ConvertFrom-Json
        foreach ($MapProp in $Dict.PSObject.Properties)
        {
            if ($MapProp.Value -is [System.Management.Automation.PSCustomObject])
            {
                foreach ($TokenKey in $MapProp.Value.PSObject.Properties.Name) { [void]$DictKeys.Add($TokenKey) }
            }
        }

        $InventoryText = Get-Content -LiteralPath $InventoryPath -Raw
        $InventoryTokens = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($TokenMatch in [regex]::Matches($InventoryText, '(?i)\b(?:prod|nonprod)_(?:databricks_|aks_|vmss_)?[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b'))
        {
            [void]$InventoryTokens.Add($TokenMatch.Value)
        }

        $Unmatched = @($InventoryTokens | Where-Object { -not $DictKeys.Contains($_) })
        [PSCustomObject]@{
            TokenCount   = $InventoryTokens.Count
            MatchedCount = ($InventoryTokens.Count - @($Unmatched).Count)
            Unmatched    = $Unmatched
        }
    }

    function Get-BundleFile
    {
        param([string]$Directory, [string]$Filter, [switch]$Optional)
        $MatchingFiles = @(Get-ChildItem -LiteralPath $Directory -Filter $Filter -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending)
        if (@($MatchingFiles).Count -gt 1)
        {
            Add-MergeWarning ("{0} files match '{1}' in '{2}'; using the newest ('{3}'). If this is not a single per-subscription bundle folder, point the path at one subscription's folder instead. Matches: [{4}]" -f @($MatchingFiles).Count, $Filter, $Directory, $MatchingFiles[0].Name, (($MatchingFiles | ForEach-Object { $_.Name }) -join ', '))
        }
        $Found = $MatchingFiles | Select-Object -First 1
        if (-not $Found -and -not $Optional)
        {
            throw ("Merge-RecoveryData: required file '{0}' not found in '{1}'." -f $Filter, $Directory)
        }
        return $Found
    }

    if (-not (Test-Path -LiteralPath $GapBundlePath -PathType Container)) { throw ("Merge-RecoveryData: GapBundlePath not found: {0}" -f $GapBundlePath) }
    if (-not (Test-Path -LiteralPath $RecoveryBundlePath -PathType Container)) { throw ("Merge-RecoveryData: RecoveryBundlePath not found: {0}" -f $RecoveryBundlePath) }

    $GapInventoryFile = Get-BundleFile -Directory $GapBundlePath      -Filter 'Inventory_*.json'
    $RecoveryInventoryFile = Get-BundleFile -Directory $RecoveryBundlePath -Filter 'Inventory_*.json'
    $GapConsumptionFile = Get-BundleFile -Directory $GapBundlePath      -Filter 'Consumption_*.csv'  -Optional
    $GapDictionaryFile = Get-BundleFile -Directory $GapBundlePath      -Filter 'ObfuscationDictionary_*.json' -Optional
    $RecoveryDictionaryFile = Get-BundleFile -Directory $RecoveryBundlePath -Filter 'ObfuscationDictionary_*.json' -Optional

    if ($GapDictionaryFile -and $RecoveryDictionaryFile)
    {
        try
        {
            $GapDictCheck = Get-Content -LiteralPath $GapDictionaryFile.FullName -Raw | ConvertFrom-Json
            $RecoveryDictCheck = Get-Content -LiteralPath $RecoveryDictionaryFile.FullName -Raw | ConvertFrom-Json
            $GapIdKeys = @($GapDictCheck.ResourceIdMap.PSObject.Properties.Name)
            $RecoveryIdKeys = @($RecoveryDictCheck.ResourceIdMap.PSObject.Properties.Name)
            if (@($GapIdKeys).Count -gt 0 -and @($RecoveryIdKeys).Count -gt 0)
            {
                # Case-insensitive HashSet membership makes the overlap check
                # linear instead of the O(n*m) array scan '$_ -in $GapIdKeys'
                # would incur on a large tenant's dictionary, matching the
                # HashSet approach Test-DictionaryMatchesInventory already uses.
                $GapIdKeySet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                foreach ($GapKey in $GapIdKeys) { [void]$GapIdKeySet.Add($GapKey) }
                $SharedIdKeys = @($RecoveryIdKeys | Where-Object { $GapIdKeySet.Contains($_) })
                if (@($SharedIdKeys).Count -eq 0)
                {
                    Add-MergeWarning ('the recovery and gap obfuscation dictionaries share NO ResourceIdMap tokens. This almost always means the recovery run was NOT seeded with the gap bundle''s dictionary (-ObfuscationDictionary <gap dict>). Cross-references in the recovered service(s) will carry mismatched tokens and will not join, so the merged bundle''s referential integrity is likely broken. Re-run the recovery seeded with the gap dictionary, or confirm the two bundles belong together.')
                }
            }
        }
        catch
        {
            Add-MergeWarning ('could not compare the gap/recovery obfuscation dictionaries for compatibility (seed check skipped): {0}' -f $_.Exception.Message)
        }
    }
    elseif (($null -ne $GapDictionaryFile) -ne ($null -ne $RecoveryDictionaryFile))
    {
        Add-MergeWarning ('only one of the gap/recovery bundles has an ObfuscationDictionary. Mixed obfuscation state suggests the two bundles were produced with different -Obfuscate settings; confirm they belong together before shipping the merged bundle.')
    }

    foreach ($DictPair in @(
            @{ Label = 'gap'; Dict = $GapDictionaryFile; Inv = $GapInventoryFile; ParamName = '-GapBundlePath' },
            @{ Label = 'recovery'; Dict = $RecoveryDictionaryFile; Inv = $RecoveryInventoryFile; ParamName = '-RecoveryBundlePath' }
        ))
    {
        if (-not $DictPair.Dict) { continue }
        try
        {
            $DictMatch = Test-DictionaryMatchesInventory -DictionaryPath $DictPair.Dict.FullName -InventoryPath $DictPair.Inv.FullName
        }
        catch
        {
            Add-MergeWarning ("could not verify the {0} bundle's dictionary matches its inventory (check skipped): {1}" -f $DictPair.Label, $_.Exception.Message)
            continue
        }
        if ($DictMatch.TokenCount -eq 0) { continue }

        $SampleUnmatched = (@($DictMatch.Unmatched | Select-Object -First 3) -join ', ')
        if ($DictMatch.TokenCount -ge 3 -and $DictMatch.MatchedCount -eq 0)
        {
            throw ("Merge-RecoveryData: the {0} bundle's ObfuscationDictionary does NOT match its inventory - 0 of {1} obfuscated token(s) in '{2}' were found as keys in '{3}'. That dictionary is almost certainly from a DIFFERENT run or subscription; carrying it forward would make the merged bundle impossible to reveal (its tokens would map to nothing). Point {4} at the folder whose ObfuscationDictionary matches its Inventory, or supply the correct dictionary. Example unmatched tokens: [{5}]." -f $DictPair.Label, $DictMatch.TokenCount, $DictPair.Inv.Name, $DictPair.Dict.Name, $DictPair.ParamName, $SampleUnmatched)
        }
        elseif ($DictMatch.MatchedCount -lt $DictMatch.TokenCount -and ($DictMatch.MatchedCount / $DictMatch.TokenCount) -lt 0.5)
        {
            Add-MergeWarning ("the {0} bundle's dictionary covers only {1} of {2} obfuscated inventory token(s). It may be a partial or slightly-mismatched dictionary; a later reveal will leave the uncovered tokens unresolved. Confirm the dictionary belongs to this inventory. Example unmatched tokens: [{3}]." -f $DictPair.Label, $DictMatch.MatchedCount, $DictMatch.TokenCount, $SampleUnmatched)
        }
    }

    $GapInventory = Get-Content -LiteralPath $GapInventoryFile.FullName -Raw | ConvertFrom-Json
    $RecoveryInventory = Get-Content -LiteralPath $RecoveryInventoryFile.FullName -Raw | ConvertFrom-Json

    $RecoveryKeys = @($RecoveryInventory.PSObject.Properties.Name | Where-Object { $_ -ne 'Version' })
    if ($Service -and @($Service).Count -gt 0)
    {
        $MergeKeys = @($RecoveryKeys | Where-Object { $_ -in $Service })
    }
    else
    {
        $MergeKeys = $RecoveryKeys
    }
    $ServiceExplicit = ($Service -and @($Service).Count -gt 0)
    if ($ServiceExplicit)
    {
        $UnmatchedServices = @($Service | Where-Object { $_ -notin $RecoveryKeys })
        if (@($UnmatchedServices).Count -gt 0)
        {
            throw ("Merge-RecoveryData: -Service name(s) not found in the recovery inventory: [{0}]. Present keys: [{1}]. Check the names or point at the correct recovery bundle." -f ($UnmatchedServices -join ', '), ($RecoveryKeys -join ', '))
        }
    }
    elseif (@($MergeKeys).Count -eq 0 -and -not ($RecoverConsumption -or $RecoverMetrics))
    {
        throw "Merge-RecoveryData: nothing to merge - the recovery inventory has no service keys."
    }

    foreach ($Key in $MergeKeys)
    {
        $GapKeyCount = if ($GapInventory.PSObject.Properties.Name -contains $Key) { @($GapInventory.$Key).Count } else { 0 }
        $RecoveryKeyCount = @($RecoveryInventory.$Key).Count
        if ($GapKeyCount -gt 0 -and $RecoveryKeyCount -lt $GapKeyCount)
        {
            Add-MergeWarning ("service '{0}' is being REPLACED with FEWER records than the gap bundle held ({1} from recovery vs {2} in gap). Whole-key replace will drop the extra gap records. Confirm the recovery run for '{0}' completed fully (no throttling / partial collection) before shipping the merged bundle." -f $Key, $RecoveryKeyCount, $GapKeyCount)
        }
        $GapInventory | Add-Member -NotePropertyName $Key -NotePropertyValue $RecoveryInventory.$Key -Force
    }

    $BundleBase = $GapInventoryFile.BaseName -replace '^Inventory_', ''

    if (-not (Test-Path -LiteralPath $OutputPath -PathType Container))
    {
        New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
    }

    $OutInventoryFile = Join-Path $OutputPath ("Inventory_{0}.json" -f $BundleBase)
    $OutConsumptionFile = Join-Path $OutputPath ("Consumption_{0}.csv" -f $BundleBase)
    $OutMetricsFile = Join-Path $OutputPath ("Metrics_{0}.json" -f $BundleBase)
    $OutHtmlFile = Join-Path $OutputPath ("{0}.html" -f $BundleBase)
    $OutZipFile = Join-Path $OutputPath ("{0}.zip" -f $BundleBase)
    $OutDictionaryFile = Join-Path $OutputPath ("ObfuscationDictionary_{0}.json" -f $BundleBase)

    $GapInventory | ConvertTo-Json -Depth 100 -Compress | Out-File -LiteralPath $OutInventoryFile

    $ConsumptionSource = 'gap'
    $ConsumptionSourceFile = $GapConsumptionFile
    if ($RecoverConsumption)
    {
        $RecoveryConsumptionFile = Get-BundleFile -Directory $RecoveryBundlePath -Filter 'Consumption_*.csv' -Optional
        if (-not $RecoveryConsumptionFile)
        {
            throw ("Merge-RecoveryData: -RecoverConsumption was requested but the recovery bundle '{0}' has no Consumption_*.csv. Re-run the recovery WITHOUT -SkipConsumption." -f $RecoveryBundlePath)
        }
        $ConsumptionSource = 'recovery'
        $ConsumptionSourceFile = $RecoveryConsumptionFile

        if ($GapConsumptionFile)
        {
            try
            {
                $GapConsumptionStats = Get-ConsumptionCsvStats -Path $GapConsumptionFile.FullName
                $RecoveryConsumptionStats = Get-ConsumptionCsvStats -Path $RecoveryConsumptionFile.FullName
                if ($GapConsumptionStats.RowCount -gt 0 -and $RecoveryConsumptionStats.RowCount -lt $GapConsumptionStats.RowCount)
                {
                    Add-MergeWarning ('the recovery consumption CSV has FEWER rows than the gap CSV ({0} vs {1}). -RecoverConsumption whole-file-replaces, so the extra gap rows will be dropped. Confirm the recovery consumption pull completed fully before shipping.' -f $RecoveryConsumptionStats.RowCount, $GapConsumptionStats.RowCount)
                }
                if ($GapConsumptionStats.RowCount -gt 0 -and $RecoveryConsumptionStats.RowCount -gt 0 -and ($GapConsumptionStats.MinStart -ne $RecoveryConsumptionStats.MinStart -or $GapConsumptionStats.MaxEnd -ne $RecoveryConsumptionStats.MaxEnd))
                {
                    Add-MergeWarning ('the recovery consumption billing window differs from the gap bundle''s (gap: {0}..{1}; recovery: {2}..{3}). The recovery run pulls a NOW-relative window, so the merged bundle''s consumption will reflect the recovery date, not the original run''s. Re-run recovery close to the original run date if the billing period must match.' -f $GapConsumptionStats.MinStart, $GapConsumptionStats.MaxEnd, $RecoveryConsumptionStats.MinStart, $RecoveryConsumptionStats.MaxEnd)
                }
            }
            catch
            {
                Add-MergeWarning ('could not compare the gap/recovery consumption CSVs (row-count/window check skipped): {0}' -f $_.Exception.Message)
            }
        }
    }
    if ($ConsumptionSourceFile)
    {
        Copy-Item -LiteralPath $ConsumptionSourceFile.FullName -Destination $OutConsumptionFile -Force
    }
    else
    {
        "AdditionalInfo,MeterCategory,MeterId,MeterName,MeterRegion,MeterSubCategory,Quantity,Unit,UsageStartTime,UsageEndTime,ResourceId,ResourceLocation,ConsumptionMeter,ReservationId,ReservationOrderId" | Out-File -LiteralPath $OutConsumptionFile -Encoding utf8
    }
    $WrittenMetricsFiles = [System.Collections.Generic.List[string]]::new()
    if ($RecoverMetrics)
    {
        $RecoveryMetricsFiles = @(Get-ChildItem -LiteralPath $RecoveryBundlePath -Filter 'Metrics_*.json' -File -ErrorAction SilentlyContinue)
        if ($RecoveryMetricsFiles.Count -eq 0)
        {
            throw ("Merge-RecoveryData: -RecoverMetrics was requested but the recovery bundle '{0}' has no Metrics_*.json. Re-run the recovery WITHOUT -SkipMetrics." -f $RecoveryBundlePath)
        }
        $RecoveryBase = $RecoveryInventoryFile.BaseName -replace '^Inventory_', ''
        foreach ($MetricsFile in $RecoveryMetricsFiles)
        {
            $Suffix = $MetricsFile.BaseName -replace ('^Metrics_' + [regex]::Escape($RecoveryBase)), ''
            $RebasedName = 'Metrics_' + $BundleBase + $Suffix + '.json'
            $RebasedPath = Join-Path $OutputPath $RebasedName
            Copy-Item -LiteralPath $MetricsFile.FullName -Destination $RebasedPath -Force
            $WrittenMetricsFiles.Add($RebasedPath)
        }
        $MetricsSource = 'recovery'
        Add-MergeWarning ('recovered metrics were written to the bundle''s Metrics_*.json, but the regenerated HTML report does not render metrics (it uses inventory + consumption only). The zipped metrics JSON is updated; the HTML will look unchanged for metrics.')
    }
    else
    {
        $GapMetricsFiles = @(Get-ChildItem -LiteralPath $GapBundlePath -Filter 'Metrics_*.json' -File -ErrorAction SilentlyContinue)
        if ($GapMetricsFiles.Count -gt 0)
        {
            foreach ($MetricsFile in $GapMetricsFiles)
            {
                $CopiedPath = Join-Path $OutputPath $MetricsFile.Name
                Copy-Item -LiteralPath $MetricsFile.FullName -Destination $CopiedPath -Force
                $WrittenMetricsFiles.Add($CopiedPath)
            }
        }
        else
        {
            @{ Metrics = @() } | ConvertTo-Json -Depth 5 -Compress | Out-File -LiteralPath $OutMetricsFile -Encoding utf8
            $WrittenMetricsFiles.Add($OutMetricsFile)
        }
        $MetricsSource = 'gap'
    }

    $DictionaryMerged = $false
    if ($GapDictionaryFile)
    {
        $MergedDictionary = Get-Content -LiteralPath $GapDictionaryFile.FullName -Raw | ConvertFrom-Json
        if ($RecoveryDictionaryFile)
        {
            $RecoveryDictionary = Get-Content -LiteralPath $RecoveryDictionaryFile.FullName -Raw | ConvertFrom-Json
            foreach ($MapProp in $RecoveryDictionary.PSObject.Properties)
            {
                $MapName = $MapProp.Name
                if ($MapName -eq 'GeneratedAt') { continue }
                if ($null -eq $MergedDictionary.$MapName)
                {
                    $MergedDictionary | Add-Member -NotePropertyName $MapName -NotePropertyValue $MapProp.Value -Force
                    continue
                }
                foreach ($Entry in $MapProp.Value.PSObject.Properties)
                {
                    if ($null -eq $MergedDictionary.$MapName.$($Entry.Name))
                    {
                        $MergedDictionary.$MapName | Add-Member -NotePropertyName $Entry.Name -NotePropertyValue $Entry.Value -Force
                    }
                }
            }
        }
        $MergedDictionary | ConvertTo-Json -Depth 5 | Out-File -LiteralPath $OutDictionaryFile -Encoding utf8
        $DictionaryMerged = $true
    }

    $SummaryScript = Join-Path (Split-Path -Path $PSScriptRoot -Parent) 'Extension/Summary.ps1'
    if (-not (Test-Path -LiteralPath $SummaryScript -PathType Leaf))
    {
        throw ("Merge-RecoveryData: report generator not found at '{0}'." -f $SummaryScript)
    }
    $ReportVersion = if ($GapInventory.PSObject.Properties.Name -contains 'Version') { $GapInventory.Version } else { $null }
    & $SummaryScript -JsonFile $OutInventoryFile -HtmlFile $OutHtmlFile -Title 'Azure Resource Inventory' -Version $ReportVersion -ConsumptionFile $OutConsumptionFile | Out-Null

    $ZipPaths = @($OutHtmlFile, $OutConsumptionFile, $OutInventoryFile) + @($WrittenMetricsFiles)
    if (Test-Path -LiteralPath $OutZipFile) { Remove-Item -LiteralPath $OutZipFile -Force }
    Compress-Archive -LiteralPath $ZipPaths -CompressionLevel Fastest -DestinationPath ([WildcardPattern]::Escape($OutZipFile))

    return [PSCustomObject]@{
        MergedServiceKeys = $MergeKeys
        ConsumptionSource = $ConsumptionSource
        MetricsSource     = $MetricsSource
        OutputInventory   = $OutInventoryFile
        OutputHtml        = $OutHtmlFile
        OutputZip         = $OutZipFile
        OutputDictionary  = if ($DictionaryMerged) { $OutDictionaryFile } else { $null }
        BundleBase        = $BundleBase
        Warnings          = @($MergeWarnings)
    }
}

