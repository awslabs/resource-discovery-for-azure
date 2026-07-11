#Requires -Version 7.0
# =============================================================================
# RecoveryMerge.Functions.ps1
#
# Merge-RecoveryData: splice a scoped recovery run's output back into an earlier
# (incomplete) report bundle and re-package the result as a single clean bundle
# that looks like the original run completed successfully.
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
        [string[]]$Service
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
    if (@($MergeKeys).Count -eq 0)
    {
        throw ("Merge-RecoveryData: nothing to merge - the recovery inventory has no service keys{0}." -f $(if ($Service) { " matching -Service [$($Service -join ', ')]" } else { '' }))
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

    # -- Carry consumption + metrics from the gap bundle unchanged. (An inventory
    #    gap does not affect the whole-subscription consumption/metrics files; a
    #    consumption/metrics recovery is a separate whole-file replace, handled
    #    later.) If the gap has none, write a canonical empty file so the bundle
    #    is structurally complete. --------------------------------------------
    if ($GapConsumptionFile)
    {
        Copy-Item -Path $GapConsumptionFile.FullName -Destination $OutConsumptionFile -Force
    }
    else
    {
        "InstanceData,MeterCategory,MeterId,MeterName,MeterRegion,MeterSubCategory,Quantity,Unit,UsageStartTime,UsageEndTime,ResourceId,ResourceLocation,ConsumptionMeter,ReservationId,ReservationOrderId" | Out-File -FilePath $OutConsumptionFile -Encoding utf8
    }
    # Copy ALL gap Metrics_*.json verbatim. The metrics phase writes one file per
    # batch (Metrics_<base>_<idx>.json), so picking only the newest would silently
    # drop batches. They already carry the same <ReportName>_<stamp> base as this
    # rebuilt bundle. Write a canonical empty file only if the gap has none.
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
        OutputInventory   = $OutInventoryFile
        OutputHtml        = $OutHtmlFile
        OutputZip         = $OutZipFile
        OutputDictionary  = if ($DictionaryMerged) { $OutDictionaryFile } else { $null }
        BundleBase        = $BundleBase
    }
}
