#Requires -Version 7.0
# =============================================================================
# RecoveryMerge.Functions.ps1
#
# Merge-RecoveryData: splice a scoped recovery run's output back into an earlier
# (incomplete) report bundle and re-package the result as a single clean bundle
# that looks like the original run completed successfully.
#
# Recovers THREE independent dimensions, each from the recovery bundle:
#   - Inventory service key(s)   : always (selected by -Service; default = all).
#   - Consumption CSV            : opt-in via -RecoverConsumption (whole-file
#                                  replace; use when the gap run's consumption is
#                                  missing/incomplete/truncated).
#   - Metrics file(s)            : opt-in via -RecoverMetrics (whole-file replace,
#                                  rebased to the output bundle name).
# Consumption/metrics default to being carried forward from the gap bundle
# unchanged (byte-for-byte the prior behaviour) unless their switch is set.
#
# Context: when a collector fails (or is intentionally scoped out with -Service)
# a report bundle is produced that is MISSING one or more service types. Rather
# than re-run the whole tenant (hours), the operator re-collects only the missing
# service(s) with:
#     ResourceInventory.ps1 -Service <name> -Obfuscate -ObfuscationDictionary <gap dict>
# The -ObfuscationDictionary seed guarantees the recovery run's obfuscated tokens
# match the gap bundle's tokens exactly, so the recovered rows can be spliced in
# with no remapping. This function performs that splice + re-package.
#
# Definitions only - dot-source this file, then call Merge-RecoveryData. It has
# no dependency on ResourceInventory.ps1's globals; it only reads/writes files
# and re-invokes Extension/Summary.ps1 to regenerate the HTML report.
# =============================================================================

function Merge-RecoveryData
{
    [CmdletBinding()]
    param(
        # Folder of the incomplete run (the "gap" bundle). Must contain an
        # Inventory_*.json; may also contain Consumption_*.csv, Metrics_*.json,
        # and the local ObfuscationDictionary_*.json.
        [Parameter(Mandatory)][string]$GapBundlePath,

        # Folder of the scoped recovery run (produced with -Service + the gap
        # bundle's dictionary as -ObfuscationDictionary). Must contain an
        # Inventory_*.json holding the recovered service key(s).
        [Parameter(Mandatory)][string]$RecoveryBundlePath,

        # Folder to write the rebuilt bundle into (created if absent).
        [Parameter(Mandatory)][string]$OutputPath,

        # Optional: which collector key(s) to take from the recovery inventory.
        # Defaults to every service key present in the recovery inventory (i.e.
        # exactly what the scoped recovery run collected), excluding 'Version'.
        [string[]]$Service,

        # Whole-file replace the CONSUMPTION CSV with the recovery bundle's copy
        # instead of carrying the gap bundle's forward. Use when the gap run's
        # consumption is missing/incomplete (e.g. truncated by a transient
        # "copying content to a stream" error). Consumption is a per-subscription
        # whole file, so this is a clean replace, not a row-merge. The recovery
        # bundle MUST contain a Consumption_*.csv or the function fails loud.
        [switch]$RecoverConsumption,

        # Whole-file replace the METRICS file(s) with the recovery bundle's copy
        # instead of carrying the gap bundle's forward. Use when the gap run's
        # metrics are missing/incomplete. The recovery bundle MUST contain at
        # least one Metrics_*.json or the function fails loud. Recovered metrics
        # files are rebased to the output bundle name so they stay consistent
        # with the rest of the rebuilt bundle.
        [switch]$RecoverMetrics
    )

    $ErrorActionPreference = 'Stop'

    # Non-fatal advisories. Each is emitted via Write-Warning for the operator AND
    # collected here so it is returned in the result's .Warnings property (lets
    # callers/tests assert them). These guards catch operator-discipline traps
    # that would otherwise produce a bundle that LOOKS complete but is subtly
    # wrong (mismatched obfuscation tokens, a shifted billing window, a silent
    # record downgrade). They never block the merge - they surface the risk.
    $MergeWarnings = [System.Collections.Generic.List[string]]::new()
    function Add-MergeWarning([string]$Message)
    {
        Write-Warning ('Merge-RecoveryData: ' + $Message)
        $MergeWarnings.Add($Message)
    }

    # -- Summarise a consumption CSV (row count + billing window endpoints) so
    #    the -RecoverConsumption path can flag a shrunk row set or a shifted
    #    billing period. Endpoints are compared as strings only (same tool, same
    #    format on both sides), so equality/inequality is a reliable drift signal
    #    without needing culture-aware date parsing. -----------------------------
    function Get-ConsumptionCsvStats([string]$Path)
    {
        $Rows = @(Import-Csv -Path $Path -ErrorAction Stop)
        $Starts = @($Rows | ForEach-Object { $_.UsageStartTime } | Where-Object { $_ } | Sort-Object -Unique)
        $Ends = @($Rows | ForEach-Object { $_.UsageEndTime } | Where-Object { $_ } | Sort-Object -Unique)
        [PSCustomObject]@{
            RowCount = @($Rows).Count
            MinStart = ($Starts | Select-Object -First 1)
            MaxEnd   = ($Ends | Select-Object -Last 1)
        }
    }

    # -- Verify an ObfuscationDictionary actually BELONGS to a given inventory.
    #    An obfuscated inventory stores per-resource tokens (prod_/nonprod_<guid>)
    #    in its ID/Name/cross-ref fields; those exact tokens are the KEYS of the
    #    dictionary's maps (ResourceIdMap/ResourceNameMap/... are token -> real).
    #    So the dictionary that goes with an inventory must contain (almost) all of
    #    that inventory's tokens as keys. If someone points at the WRONG dictionary
    #    (a different run/subscription), the inventory's tokens are absent and
    #    coverage collapses to ~0. Returns matched/total counts plus a few sample
    #    unmatched tokens. Tokens are already obfuscated, so they are safe to
    #    surface in diagnostics; the dictionary VALUES (real IDs) are never touched.
    function Test-DictionaryMatchesInventory
    {
        param([string]$DictionaryPath, [string]$InventoryPath)

        $DictKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $Dict = Get-Content -Path $DictionaryPath -Raw | ConvertFrom-Json
        foreach ($MapProp in $Dict.PSObject.Properties)
        {
            # Only object-valued properties are token maps; skip scalar metadata
            # such as GeneratedAt.
            if ($MapProp.Value -is [System.Management.Automation.PSCustomObject])
            {
                foreach ($TokenKey in $MapProp.Value.PSObject.Properties.Name) { [void]$DictKeys.Add($TokenKey) }
            }
        }

        # Collect the DISTINCT obfuscation tokens present in the inventory text.
        # The pattern matches only flat per-resource tokens (prod_/nonprod_<guid>),
        # which are what the inventory ID/Name fields carry and what the dictionary
        # maps key on. Consumption-style tokens (prod_sub_/prod_rg_...) live in the
        # CSV, not the inventory JSON, so they never enter this scan.
        $InventoryText = Get-Content -Path $InventoryPath -Raw
        $InventoryTokens = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($TokenMatch in [regex]::Matches($InventoryText, '(?i)\b(?:prod|nonprod)_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b'))
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

    # -- Locate the newest file matching a filter in a bundle folder ----------
    function Get-BundleFile
    {
        param([string]$Directory, [string]$Filter, [switch]$Optional)
        $MatchingFiles = @(Get-ChildItem -Path $Directory -Filter $Filter -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending)
        if (@($MatchingFiles).Count -gt 1)
        {
            # More than one match means the folder is probably NOT a single
            # per-subscription bundle (e.g. -GapBundlePath was pointed at the
            # InventoryRoot that holds many sub folders/runs). Newest-wins is a
            # silent guess, so make it loud.
            Add-MergeWarning ("{0} files match '{1}' in '{2}'; using the newest ('{3}'). If this is not a single per-subscription bundle folder, point the path at one subscription's folder instead. Matches: [{4}]" -f @($MatchingFiles).Count, $Filter, $Directory, $MatchingFiles[0].Name, (($MatchingFiles | ForEach-Object { $_.Name }) -join ', '))
        }
        $Found = $MatchingFiles | Select-Object -First 1
        if (-not $Found -and -not $Optional)
        {
            throw ("Merge-RecoveryData: required file '{0}' not found in '{1}'." -f $Filter, $Directory)
        }
        return $Found
    }

    if (-not (Test-Path -Path $GapBundlePath -PathType Container)) { throw ("Merge-RecoveryData: GapBundlePath not found: {0}" -f $GapBundlePath) }
    if (-not (Test-Path -Path $RecoveryBundlePath -PathType Container)) { throw ("Merge-RecoveryData: RecoveryBundlePath not found: {0}" -f $RecoveryBundlePath) }

    $GapInventoryFile = Get-BundleFile -Directory $GapBundlePath      -Filter 'Inventory_*.json'
    $RecoveryInventoryFile = Get-BundleFile -Directory $RecoveryBundlePath -Filter 'Inventory_*.json'
    $GapConsumptionFile = Get-BundleFile -Directory $GapBundlePath      -Filter 'Consumption_*.csv'  -Optional
    $GapDictionaryFile = Get-BundleFile -Directory $GapBundlePath      -Filter 'ObfuscationDictionary_*.json' -Optional
    $RecoveryDictionaryFile = Get-BundleFile -Directory $RecoveryBundlePath -Filter 'ObfuscationDictionary_*.json' -Optional

    # -- Guard: obfuscation-dictionary compatibility --------------------------
    # The whole "recovered rows splice in cleanly" guarantee rests on the recovery
    # run having been SEEDED with the gap bundle's dictionary
    # (-ObfuscationDictionary <gap dict>), so identical real values map to identical
    # tokens. If the operator forgets that seed, the recovery run mints fresh random
    # tokens and the recovered service's cross-references to OTHER services'
    # resources will not join - silent referential corruption in a bundle that
    # otherwise looks complete. We cannot repair that here, but we CAN detect the
    # tell-tale: a seeded recovery's ResourceIdMap shares (almost) all of the gap's
    # tokens, whereas an unseeded one shares none. Warn loudly on zero overlap.
    if ($GapDictionaryFile -and $RecoveryDictionaryFile)
    {
        try
        {
            $GapDictCheck = Get-Content -Path $GapDictionaryFile.FullName -Raw | ConvertFrom-Json
            $RecoveryDictCheck = Get-Content -Path $RecoveryDictionaryFile.FullName -Raw | ConvertFrom-Json
            $GapIdKeys = @($GapDictCheck.ResourceIdMap.PSObject.Properties.Name)
            $RecoveryIdKeys = @($RecoveryDictCheck.ResourceIdMap.PSObject.Properties.Name)
            if (@($GapIdKeys).Count -gt 0 -and @($RecoveryIdKeys).Count -gt 0)
            {
                $SharedIdKeys = @($RecoveryIdKeys | Where-Object { $_ -in $GapIdKeys })
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

    # -- Guard: dictionary-belongs-to-its-inventory (HARD FAIL) ---------------
    # Distinct from the seed-overlap check above. That one asks "was the recovery
    # seeded from the gap?"; this one asks "does the dictionary sitting in each
    # folder actually belong to THAT folder's inventory?". A wrong dictionary
    # (operator pointed at a different run's / subscription's folder, or passed the
    # wrong -ObfuscationDictionary) would be carried forward silently and make the
    # merged bundle impossible to Reveal - the tokens in the report would map to
    # nothing. We detect it by coverage: (almost) every obfuscated token in an
    # inventory must exist as a key in the dictionary beside it. Zero coverage over
    # a meaningful sample is unambiguous (right dict ~= 100%, wrong dict = 0%), so
    # we HARD FAIL with a diagnostic naming the files, the counts, sample tokens,
    # and the fix. Partial coverage is only suspicious, so it warns.
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
        # No tokens = non-obfuscated inventory (or empty); nothing to verify.
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

    # -- Load inventories -----------------------------------------------------
    $GapInventory = Get-Content -Path $GapInventoryFile.FullName -Raw | ConvertFrom-Json
    $RecoveryInventory = Get-Content -Path $RecoveryInventoryFile.FullName -Raw | ConvertFrom-Json

    # Determine which service keys to splice in. Default = every collector key the
    # recovery run produced (excluding the 'Version' marker); -Service narrows it.
    $RecoveryKeys = @($RecoveryInventory.PSObject.Properties.Name | Where-Object { $_ -ne 'Version' })
    if ($Service -and @($Service).Count -gt 0)
    {
        $MergeKeys = @($RecoveryKeys | Where-Object { $_ -in $Service })
    }
    else
    {
        $MergeKeys = $RecoveryKeys
    }
    # Guard the inventory splice. Fail-loud rules:
    #   - If -Service was EXPLICITLY named, EVERY requested name must be present
    #     in the recovery inventory. Throw on ANY unmatched name - a TOTAL miss
    #     (none matched) OR a PARTIAL miss (e.g. -Service A,B where A exists but B
    #     does not). Silently splicing only the subset that happened to be there
    #     would drop a dimension the caller explicitly asked for (a typo or the
    #     wrong/incomplete recovery bundle), even if a recover switch is set.
    #   - With no explicit -Service, MergeKeys defaults to "all recovery keys".
    #     Only an empty recovery inventory reaches the error below; that is an
    #     error unless the caller asked to rebuild consumption/metrics only
    #     (leaving the already-complete gap inventory untouched).
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

    # Splice each recovered service key into the gap inventory (add if missing,
    # replace if already present). -Force overwrites any existing property.
    foreach ($Key in $MergeKeys)
    {
        # Guard: whole-key replace can silently DOWNGRADE. If the recovery run
        # came back thinner than the gap bundle for this key (its own throttling,
        # a partial collection), replacing wholesale drops the extra gap records
        # with no trace. Compare counts and warn; do not block (the operator may
        # know the gap key was itself corrupt and the smaller recovery set is the
        # correct one).
        $GapKeyCount = if ($GapInventory.PSObject.Properties.Name -contains $Key) { @($GapInventory.$Key).Count } else { 0 }
        $RecoveryKeyCount = @($RecoveryInventory.$Key).Count
        if ($GapKeyCount -gt 0 -and $RecoveryKeyCount -lt $GapKeyCount)
        {
            Add-MergeWarning ("service '{0}' is being REPLACED with FEWER records than the gap bundle held ({1} from recovery vs {2} in gap). Whole-key replace will drop the extra gap records. Confirm the recovery run for '{0}' completed fully (no throttling / partial collection) before shipping the merged bundle." -f $Key, $RecoveryKeyCount, $GapKeyCount)
        }
        $GapInventory | Add-Member -NotePropertyName $Key -NotePropertyValue $RecoveryInventory.$Key -Force
    }

    # -- Compute output naming (mirror ResourceInventory.ps1's bundle names) ---
    # Gap inventory file is "Inventory_<ReportName>_<stamp>.json"; reuse that
    # "<ReportName>_<stamp>" base so the rebuilt bundle keeps the run's identity.
    $BundleBase = $GapInventoryFile.BaseName -replace '^Inventory_', ''

    if (-not (Test-Path -Path $OutputPath -PathType Container))
    {
        New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
    }

    $OutInventoryFile = Join-Path $OutputPath ("Inventory_{0}.json" -f $BundleBase)
    $OutConsumptionFile = Join-Path $OutputPath ("Consumption_{0}.csv" -f $BundleBase)
    $OutMetricsFile = Join-Path $OutputPath ("Metrics_{0}.json" -f $BundleBase)
    $OutHtmlFile = Join-Path $OutputPath ("{0}.html" -f $BundleBase)
    $OutZipFile = Join-Path $OutputPath ("{0}.zip" -f $BundleBase)
    $OutDictionaryFile = Join-Path $OutputPath ("ObfuscationDictionary_{0}.json" -f $BundleBase)

    # -- Write the merged inventory (depth 100 + compressed, matching the
    #    original serialization in ResourceInventory.ps1) ----------------------
    $GapInventory | ConvertTo-Json -Depth 100 -Compress | Out-File -FilePath $OutInventoryFile

    # -- Consumption source. By default carry the gap bundle's CSV forward: an
    #    inventory gap does not affect the whole-subscription consumption file.
    #    With -RecoverConsumption, whole-file REPLACE it with the recovery
    #    bundle's CSV instead (used when the gap run's consumption is missing or
    #    incomplete - e.g. truncated by a transient "copying content to a stream"
    #    error). Consumption ResourceUris are obfuscated with a per-run scheme
    #    that is independent of the inventory dictionary (it preserves the ARM
    #    path structure for categorisation but mints its own sub/rg/name tokens),
    #    so a replaced consumption file is internally consistent and categorises
    #    correctly even though its tokens differ from the gap run's. If the chosen
    #    source has none, write a canonical empty file so the bundle is
    #    structurally complete. --------------------------------------------------
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

        # Guard: consumption row-shrink and billing-window drift. The recovery run
        # pulls a NOW-relative billing window, so a recovery done later than the
        # original run covers a DIFFERENT period; a whole-file replace then swaps
        # in that different window silently. Also flag a smaller row set (a
        # partial recovery pull). Both are warnings only - the replace is still
        # the right call for a truncated gap CSV.
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
        Copy-Item -Path $ConsumptionSourceFile.FullName -Destination $OutConsumptionFile -Force
    }
    else
    {
        "InstanceData,MeterCategory,MeterId,MeterName,MeterRegion,MeterSubCategory,Quantity,Unit,UsageStartTime,UsageEndTime,ResourceId,ResourceLocation,ConsumptionMeter,ReservationId,ReservationOrderId" | Out-File -FilePath $OutConsumptionFile -Encoding utf8
    }
    # -- Metrics source. By default carry ALL gap Metrics_*.json forward verbatim.
    #    The metrics phase writes one file per batch (Metrics_<base>__<idx>.json),
    #    so picking only the newest would silently drop batches; the gap files
    #    already carry this rebuilt bundle's <ReportName>_<stamp> base. With
    #    -RecoverMetrics, whole-file REPLACE them with the recovery bundle's
    #    metrics instead, REBASED to the output bundle name so the batch files
    #    stay consistent with the rest of the bundle. Metrics IDs are obfuscated
    #    via the seeded ResourceIdMap, so a recovery run seeded with the gap
    #    dictionary yields metrics tokens that match the merged inventory. Write a
    #    canonical empty file only if the chosen source has none.
    if ($RecoverMetrics)
    {
        $RecoveryMetricsFiles = @(Get-ChildItem -Path $RecoveryBundlePath -Filter 'Metrics_*.json' -File -ErrorAction SilentlyContinue)
        if ($RecoveryMetricsFiles.Count -eq 0)
        {
            throw ("Merge-RecoveryData: -RecoverMetrics was requested but the recovery bundle '{0}' has no Metrics_*.json. Re-run the recovery WITHOUT -SkipMetrics." -f $RecoveryBundlePath)
        }
        # Recovery metrics carry the recovery run's base; rebase to $BundleBase.
        $RecoveryBase = $RecoveryInventoryFile.BaseName -replace '^Inventory_', ''
        foreach ($MetricsFile in $RecoveryMetricsFiles)
        {
            $Suffix = $MetricsFile.BaseName -replace ('^Metrics_' + [regex]::Escape($RecoveryBase)), ''
            $RebasedName = 'Metrics_' + $BundleBase + $Suffix + '.json'
            Copy-Item -Path $MetricsFile.FullName -Destination (Join-Path $OutputPath $RebasedName) -Force
        }
        $MetricsSource = 'recovery'
        # Advisory: the regenerated HTML does not render metrics (Summary.ps1
        # consumes inventory + consumption only), so recovering metrics updates
        # the zipped Metrics_*.json but leaves the HTML visually unchanged. Set
        # the operator's expectation so a "the report still looks the same"
        # observation is not mistaken for the recovery having failed.
        Add-MergeWarning ('recovered metrics were written to the bundle''s Metrics_*.json, but the regenerated HTML report does not render metrics (it uses inventory + consumption only). The zipped metrics JSON is updated; the HTML will look unchanged for metrics.')
    }
    else
    {
        $GapMetricsFiles = @(Get-ChildItem -Path $GapBundlePath -Filter 'Metrics_*.json' -File -ErrorAction SilentlyContinue)
        if ($GapMetricsFiles.Count -gt 0)
        {
            foreach ($MetricsFile in $GapMetricsFiles)
            {
                Copy-Item -Path $MetricsFile.FullName -Destination (Join-Path $OutputPath $MetricsFile.Name) -Force
            }
        }
        else
        {
            @{ Metrics = @() } | ConvertTo-Json -Depth 5 -Compress | Out-File -FilePath $OutMetricsFile -Encoding utf8
        }
        $MetricsSource = 'gap'
    }

    # -- Merge the obfuscation dictionaries (LOCAL only, never zipped). Both runs
    #    share identical tokens (the recovery was seeded from the gap dict), so
    #    this is a union: start from the gap dictionary (a superset - the gap run
    #    extracted every resource) and add any map entries the recovery holds that
    #    the gap does not. Only meaningful for obfuscated bundles. ------------
    $DictionaryMerged = $false
    if ($GapDictionaryFile)
    {
        $MergedDictionary = Get-Content -Path $GapDictionaryFile.FullName -Raw | ConvertFrom-Json
        if ($RecoveryDictionaryFile)
        {
            $RecoveryDictionary = Get-Content -Path $RecoveryDictionaryFile.FullName -Raw | ConvertFrom-Json
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
        $MergedDictionary | ConvertTo-Json -Depth 5 | Out-File -FilePath $OutDictionaryFile -Encoding utf8
        $DictionaryMerged = $true
    }

    # -- Regenerate the HTML report from the merged inventory via Summary.ps1.
    #    Located relative to this functions file (Functions/ -> ../Extension). --
    $SummaryScript = Join-Path (Split-Path -Path $PSScriptRoot -Parent) 'Extension/Summary.ps1'
    if (-not (Test-Path -Path $SummaryScript -PathType Leaf))
    {
        throw ("Merge-RecoveryData: report generator not found at '{0}'." -f $SummaryScript)
    }
    $ReportVersion = if ($GapInventory.PSObject.Properties.Name -contains 'Version') { $GapInventory.Version } else { $null }
    & $SummaryScript -JsonFile $OutInventoryFile -HtmlFile $OutHtmlFile -Title 'Azure Resource Inventory' -Version $ReportVersion -ConsumptionFile $OutConsumptionFile | Out-Null

    # -- Re-zip, mirroring ResourceInventory.ps1's packaging filter: HTML +
    #    Consumption CSV + every *.json EXCEPT the local-only dictionary/Full/
    #    Heartbeat/ErrorLog files. The dictionary is deliberately NOT zipped. ---
    $ZipJsonFiles = Get-ChildItem -Path $OutputPath -Filter '*.json' |
        Where-Object { $_.Name -notlike 'ObfuscationDictionary_*' -and $_.Name -notlike 'Full_*' -and $_.Name -notlike 'Heartbeat_*' -and $_.Name -notlike 'ErrorLog_*' } |
        Select-Object -ExpandProperty FullName
    $ZipPaths = @($OutHtmlFile, $OutConsumptionFile) + $ZipJsonFiles
    if (Test-Path -Path $OutZipFile) { Remove-Item -Path $OutZipFile -Force }
    Compress-Archive -Path $ZipPaths -CompressionLevel Fastest -DestinationPath $OutZipFile

    # -- Report what was done -------------------------------------------------
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
