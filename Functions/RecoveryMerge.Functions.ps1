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

    # -- Locate the newest file matching a filter in a bundle folder ----------
    function Get-BundleFile
    {
        param([string]$Directory, [string]$Filter, [switch]$Optional)
        $Found = Get-ChildItem -Path $Directory -Filter $Filter -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $Found -and -not $Optional)
        {
            throw ("Merge-RecoveryData: required file '{0}' not found in '{1}'." -f $Filter, $Directory)
        }
        return $Found
    }

    if (-not (Test-Path -Path $GapBundlePath -PathType Container))      { throw ("Merge-RecoveryData: GapBundlePath not found: {0}" -f $GapBundlePath) }
    if (-not (Test-Path -Path $RecoveryBundlePath -PathType Container)) { throw ("Merge-RecoveryData: RecoveryBundlePath not found: {0}" -f $RecoveryBundlePath) }

    $GapInventoryFile      = Get-BundleFile -Directory $GapBundlePath      -Filter 'Inventory_*.json'
    $RecoveryInventoryFile = Get-BundleFile -Directory $RecoveryBundlePath -Filter 'Inventory_*.json'
    $GapConsumptionFile    = Get-BundleFile -Directory $GapBundlePath      -Filter 'Consumption_*.csv'  -Optional
    $GapDictionaryFile     = Get-BundleFile -Directory $GapBundlePath      -Filter 'ObfuscationDictionary_*.json' -Optional
    $RecoveryDictionaryFile = Get-BundleFile -Directory $RecoveryBundlePath -Filter 'ObfuscationDictionary_*.json' -Optional

    # -- Load inventories -----------------------------------------------------
    $GapInventory      = Get-Content -Path $GapInventoryFile.FullName -Raw | ConvertFrom-Json
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

    $OutInventoryFile   = Join-Path $OutputPath ("Inventory_{0}.json"   -f $BundleBase)
    $OutConsumptionFile = Join-Path $OutputPath ("Consumption_{0}.csv"  -f $BundleBase)
    $OutMetricsFile     = Join-Path $OutputPath ("Metrics_{0}.json"     -f $BundleBase)
    $OutHtmlFile        = Join-Path $OutputPath ("{0}.html"             -f $BundleBase)
    $OutZipFile         = Join-Path $OutputPath ("{0}.zip"              -f $BundleBase)
    $OutDictionaryFile  = Join-Path $OutputPath ("ObfuscationDictionary_{0}.json" -f $BundleBase)

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
    $ConsumptionSource     = 'gap'
    $ConsumptionSourceFile = $GapConsumptionFile
    if ($RecoverConsumption)
    {
        $RecoveryConsumptionFile = Get-BundleFile -Directory $RecoveryBundlePath -Filter 'Consumption_*.csv' -Optional
        if (-not $RecoveryConsumptionFile)
        {
            throw ("Merge-RecoveryData: -RecoverConsumption was requested but the recovery bundle '{0}' has no Consumption_*.csv. Re-run the recovery WITHOUT -SkipConsumption." -f $RecoveryBundlePath)
        }
        $ConsumptionSource     = 'recovery'
        $ConsumptionSourceFile = $RecoveryConsumptionFile
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
            $Suffix      = $MetricsFile.BaseName -replace ('^Metrics_' + [regex]::Escape($RecoveryBase)), ''
            $RebasedName = 'Metrics_' + $BundleBase + $Suffix + '.json'
            Copy-Item -Path $MetricsFile.FullName -Destination (Join-Path $OutputPath $RebasedName) -Force
        }
        $MetricsSource = 'recovery'
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
    }
}
