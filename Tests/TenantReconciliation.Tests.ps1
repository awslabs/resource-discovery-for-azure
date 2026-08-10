# Tenant Reconciliation Tests
# =============================================================================
# Guards against a future code change that silently DUPLICATES, MANGLES,
# MIS-ATTRIBUTES, or grossly DROPS resources, by checking a NON-OBFUSCATED
# output zip two ways:
#
#   Tier 1 - Structural integrity (drift-immune, no Azure calls):
#       Pure checks on the zip's own contents - unique IDs per one-row-per-
#       resource collector, well-formed ARM paths, single-subscription scoping,
#       and consumption scoped to the same subscription. These are 100% reliable
#       and catch the duplication / ID-mangling / cross-subscription classes of
#       regression. They run whenever the zip is non-obfuscated (offline OK).
#
#   Tier 2 - Live tenant reconciliation (requires a live Az session):
#       Confirms the inventory's real resource IDs actually resolve to resources
#       in the tenant. This is INHERENTLY subject to tenant DRIFT - resources can
#       be created/deleted between report generation and this check (an active
#       sandbox with auto-shutdown/auto-delete churns constantly) - so it is
#       deliberately DRIFT-TOLERANT: it fails only on CATASTROPHIC divergence
#       (a systemic ID-corruption / wrong-subscription bug drops the live-overlap
#       to near zero), never on ordinary churn. It is meant to run against a
#       FRESH zip (as the scenario matrix does, generating then testing seconds
#       apart), which keeps the drift window tiny.
#
# The whole suite SELF-SKIPS (never fails) when the zip is obfuscated (IDs are
# tokens, not real ARM paths), and Tier 2 additionally skips when there is no
# live Az context or it cannot see the run's subscription - so it is safe in an
# offline `Invoke-Pester ./Tests/` or CI run. All expected values are read live
# at runtime; nothing is hardcoded, so it is tenant-portable.
# =============================================================================

BeforeAll {
    $ZipPath = if ($env:TEST_ZIP_PATH) { $env:TEST_ZIP_PATH } else
    {
        Get-ChildItem -Path $PSScriptRoot -Filter "ResourcesReport_*.zip" |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
    }

    # Tier gates and skip reasons.
    $script:StructuralOK = $true      # non-obfuscated zip with real ARM IDs present
    $script:LiveOK = $true            # StructuralOK + live session that can see the sub
    $script:StructuralSkip = $null
    $script:LiveSkip = $null

    if ([string]::IsNullOrEmpty($ZipPath) -or -not (Test-Path $ZipPath))
    {
        $script:StructuralOK = $false; $script:LiveOK = $false
        $script:StructuralSkip = 'no test zip found (set $env:TEST_ZIP_PATH)'
        $script:LiveSkip = $script:StructuralSkip
    }

    if ($script:StructuralOK)
    {
        $TmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { "/tmp" }
        $script:ExtractPath = Join-Path $TmpBase ("TenantRecon_" + [guid]::NewGuid().ToString().Substring(0, 8))
        New-Item -ItemType Directory -Path $script:ExtractPath -Force | Out-Null
        Expand-Archive -Path $ZipPath -DestinationPath $script:ExtractPath -Force

        $InvFile = Get-ChildItem -Path $script:ExtractPath -Filter "Inventory_*.json" | Select-Object -First 1
        $script:Inventory = if ($InvFile) { Get-Content $InvFile.FullName -Raw | ConvertFrom-Json } else { $null }

        $CsvFile = Get-ChildItem -Path $script:ExtractPath -Filter "Consumption_*.csv" | Select-Object -First 1
        $script:Consumption = if ($CsvFile)
        {
            $Content = Get-Content $CsvFile.FullName -ErrorAction SilentlyContinue
            if ($null -ne $Content -and $Content.Count -gt 1) { Import-Csv $CsvFile.FullName } else { @() }
        }
        else { @() }

        # Every inventory resource ID, indexed by the collector section it came from.
        $script:InvIds = @()
        $script:BySection = @{}
        if ($null -ne $script:Inventory)
        {
            foreach ($Prop in $script:Inventory.PSObject.Properties)
            {
                if ($Prop.Name -eq 'Version') { continue }
                $Ids = @($Prop.Value | Where-Object { $null -ne $_ -and ![string]::IsNullOrEmpty($_.ID) } | ForEach-Object { $_.ID })
                if ($Ids.Count -gt 0) { $script:BySection[$Prop.Name] = $Ids; $script:InvIds += $Ids }
            }
        }

        # Non-obfuscated? Real inventory IDs are /subscriptions/<guid>/... ARM paths.
        # Obfuscated tokens (prod_/nonprod_...) are not resolvable, so the whole
        # suite skips on an obfuscated (or empty) zip.
        $ArmLike = @($script:InvIds | Where-Object { $_ -match '^/subscriptions/[0-9a-fA-F-]{36}/' })
        if ($script:InvIds.Count -eq 0)
        {
            $script:StructuralOK = $false; $script:LiveOK = $false
            $script:StructuralSkip = 'inventory has no resource IDs'; $script:LiveSkip = $script:StructuralSkip
        }
        elseif ($ArmLike.Count -lt $script:InvIds.Count)
        {
            $script:StructuralOK = $false; $script:LiveOK = $false
            $script:StructuralSkip = 'zip is obfuscated (IDs are tokens, not real ARM paths)'; $script:LiveSkip = $script:StructuralSkip
        }
    }

    if ($script:StructuralOK)
    {
        $script:InvSubs = @($script:InvIds | ForEach-Object { ($_ -split '/')[2] } | Sort-Object -Unique)
        $script:TargetSub = if ($env:TEST_SUBSCRIPTION_ID) { $env:TEST_SUBSCRIPTION_ID } else { $script:InvSubs | Select-Object -First 1 }
    }
    else
    {
        # Ensure Tier-2 also reports a reason if Tier-1 already disqualified.
        $script:LiveOK = $false
        if (-not $script:LiveSkip) { $script:LiveSkip = $script:StructuralSkip }
    }

    # Tier 2 additionally needs a live session that can see the target sub.
    if ($script:LiveOK)
    {
        $Ctx = Get-AzContext -ErrorAction SilentlyContinue
        if ($null -eq $Ctx -or $null -eq $Ctx.Account)
        {
            $script:LiveOK = $false; $script:LiveSkip = 'no live Az context (Connect-AzAccount) - live reconciliation skipped'
        }
        else
        {
            $Tenant = $Ctx.Tenant.Id
            $Vis = $null
            try { $Vis = Get-AzSubscription -SubscriptionId $script:TargetSub -TenantId $Tenant -ErrorAction Stop } catch { $Vis = $null }
            if ($null -eq $Vis)
            {
                $script:LiveOK = $false; $script:LiveSkip = 'current Az context cannot see the run''s subscription - live reconciliation skipped'
            }
            else
            {
                $null = Set-AzContext -Subscription $script:TargetSub -Tenant $Tenant -ErrorAction SilentlyContinue
                $Now = Get-AzContext -ErrorAction SilentlyContinue
                if ($null -eq $Now -or $Now.Subscription.Id -ne $script:TargetSub)
                {
                    # Context did not switch to the target sub: querying the wrong
                    # sub would false-fail the reconciliation, so skip instead.
                    $script:LiveOK = $false; $script:LiveSkip = 'could not switch Az context to the run''s subscription - live reconciliation skipped'
                }
                else
                {
                    $script:Live = @(Get-AzResource -ErrorAction SilentlyContinue)
                    $script:LiveById = @{}
                    foreach ($Resource in $script:Live) { if ($Resource.ResourceId) { $script:LiveById[$Resource.ResourceId.ToLower()] = $true } }
                    if ($script:Live.Count -eq 0)
                    {
                        # No control-plane resources returned -> can't reconcile meaningfully.
                        $script:LiveOK = $false; $script:LiveSkip = 'Get-AzResource returned no resources for the subscription - live reconciliation skipped'
                    }
                }
            }
        }
    }

    if ($script:StructuralSkip) { Write-Host ("[TenantReconciliation] structural tier: {0}" -f $script:StructuralSkip) -ForegroundColor DarkGray }
    if ($script:LiveSkip) { Write-Host ("[TenantReconciliation] live tier: {0}" -f $script:LiveSkip) -ForegroundColor DarkGray }

    # Collector sections that emit EXACTLY ONE row per resource (so their IDs must
    # be unique, and their distinct count should track the tenant). Multi-row
    # collectors (AKS per node-pool, IOTHubs per location, VirtualWAN per hub,
    # AutomationAcc per runbook) are intentionally excluded from the per-section
    # uniqueness/count checks.
    $script:OneToOneTypeMap = [ordered]@{
        'VirtualMachines' = 'microsoft.compute/virtualmachines'
        'VMDisk'          = 'microsoft.compute/disks'
        'StorageAcc'      = 'microsoft.storage/storageaccounts'
        'PublicIP'        = 'microsoft.network/publicipaddresses'
        'Vault'           = 'microsoft.keyvault/vaults'
        'SQLSERVER'       = 'microsoft.sql/servers'
        'ServiceBUS'      = 'microsoft.servicebus/namespaces'
    }
}

AfterAll {
    if ($script:ExtractPath -and (Test-Path $script:ExtractPath)) { Remove-Item -Path $script:ExtractPath -Recurse -Force }
}

# =============================================================================
# Tier 1 - Structural integrity (drift-immune; no Azure calls)
# =============================================================================
Describe "Inventory structural integrity" {

    It "Every inventory resource ID is a well-formed ARM path" {
        if (-not $script:StructuralOK) { Set-ItResult -Skipped -Because $script:StructuralSkip; return }
        $Malformed = @($script:InvIds | Where-Object { $_ -notmatch '^/subscriptions/[0-9a-fA-F-]{36}/(resourceGroups|providers)/' })
        $Malformed.Count | Should -Be 0 -Because "every inventory ID must be a valid ARM resource path (mangled IDs indicate a collector regression)"
    }

    It "All inventory resource IDs belong to a single subscription" {
        if (-not $script:StructuralOK) { Set-ItResult -Skipped -Because $script:StructuralSkip; return }
        # Assert the INVENTORY references exactly one subscription - this is the
        # env-independent, drift-immune invariant. (Comparing against an
        # externally-supplied TEST_SUBSCRIPTION_ID would false-fail on a harness
        # mis-configuration rather than a real code bug.)
        $script:InvSubs.Count | Should -Be 1 -Because "a single-subscription run must reference exactly one subscription across all resource IDs (cross-subscription contamination). Found: $($script:InvSubs.Count)"
    }

    It "One-row-per-resource collectors emit no duplicate resource IDs" {
        if (-not $script:StructuralOK) { Set-ItResult -Skipped -Because $script:StructuralSkip; return }
        $Checked = 0
        foreach ($Section in $script:OneToOneTypeMap.Keys)
        {
            if (-not $script:BySection.ContainsKey($Section)) { continue }
            $Ids = @($script:BySection[$Section])
            if ($Ids.Count -eq 0) { continue }
            $Checked++
            $Distinct = @($Ids | Sort-Object -Unique).Count
            $Distinct | Should -Be $Ids.Count -Because "'$Section' emits one row per resource, so its IDs must be unique (rows=$($Ids.Count), distinct=$Distinct)"
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "none of the one-row-per-resource sections were populated in this fixture" }
    }

    It "Every consumption ResourceId belongs to the run's subscription" {
        if (-not $script:StructuralOK) { Set-ItResult -Skipped -Because $script:StructuralSkip; return }
        if ($script:Consumption.Count -eq 0) { Set-ItResult -Skipped -Because "no consumption rows in this fixture"; return }
        $Foreign = @($script:Consumption |
                Where-Object { ![string]::IsNullOrEmpty($_.ResourceId) -and $_.ResourceId -match '^/subscriptions/([0-9a-fA-F-]{36})/' } |
                Where-Object { ($_.ResourceId -split '/')[2] -ne $script:TargetSub })
        $Foreign.Count | Should -Be 0 -Because "consumption must not attribute cost from another subscription (cross-attribution)"
    }
}

# =============================================================================
# Tier 2 - Live tenant reconciliation (requires live session; drift-tolerant)
# =============================================================================
Describe "Live tenant reconciliation" {

    It "Inventory resource IDs overwhelmingly resolve to live tenant resources (catastrophic-corruption guard)" {
        if (-not $script:LiveOK) { Set-ItResult -Skipped -Because $script:LiveSkip; return }
        $Total = $script:InvIds.Count
        $Present = @($script:InvIds | Where-Object { $script:LiveById.ContainsKey($_.ToLower()) }).Count
        $Missing = $Total - $Present
        # Drift-tolerant: a resource deleted between generation and this check is
        # legitimately absent, so a few misses are fine. But if MOST inventory IDs
        # are absent, the collector is emitting IDs that never existed (corruption)
        # or targeted the wrong subscription - that is a real regression. Threshold
        # is intentionally generous (>=50% must resolve) so normal churn never
        # fails; a fresh zip (as the matrix produces) resolves ~100%.
        $Ratio = if ($Total -gt 0) { $Present / $Total } else { 1 }
        Write-Host ("    [recon] inventory IDs live: {0}/{1} ({2:P0}); {3} absent (drift or deleted-since)" -f $Present, $Total, $Ratio, $Missing) -ForegroundColor DarkGray
        $Ratio | Should -BeGreaterOrEqual 0.5 -Because "at least half of the inventory must resolve to real tenant resources; a near-zero overlap means IDs are corrupted or the wrong subscription was collected (present=$Present of $Total)"
    }

    It "<Section> distinct count tracks the tenant (drift-tolerant)" -ForEach @(
        @{ Section = 'VirtualMachines'; Type = 'microsoft.compute/virtualmachines' }
        @{ Section = 'VMDisk'; Type = 'microsoft.compute/disks' }
        @{ Section = 'StorageAcc'; Type = 'microsoft.storage/storageaccounts' }
        @{ Section = 'PublicIP'; Type = 'microsoft.network/publicipaddresses' }
        @{ Section = 'Vault'; Type = 'microsoft.keyvault/vaults' }
        @{ Section = 'SQLSERVER'; Type = 'microsoft.sql/servers' }
        @{ Section = 'ServiceBUS'; Type = 'microsoft.servicebus/namespaces' }
    ) {
        param($Section, $Type)
        if (-not $script:LiveOK) { Set-ItResult -Skipped -Because $script:LiveSkip; return }
        $InvDistinct = if ($script:BySection.ContainsKey($Section)) { @($script:BySection[$Section] | Sort-Object -Unique).Count } else { 0 }
        $LiveCount = @($script:Live | Where-Object { $_.ResourceType -ieq $Type }).Count
        if ($InvDistinct -eq 0 -and $LiveCount -eq 0) { Set-ItResult -Skipped -Because "no '$Section' resources in this subscription"; return }
        # Compare inventory distinct count to the LIVE count of that type, read at
        # runtime (not hardcoded). Drift-tolerant: allow the greater of 2 resources
        # or 25% of the live count to differ (churn between generation and check).
        # A gross drop or duplication (a collector regression) exceeds that and fails.
        $Allowed = [math]::Max(2, [math]::Ceiling($LiveCount * 0.25))
        $Delta = [math]::Abs($InvDistinct - $LiveCount)
        Write-Host ("    [recon] {0}: inventory={1} tenant={2} (allowed drift {3})" -f $Section, $InvDistinct, $LiveCount, $Allowed) -ForegroundColor DarkGray
        $Delta | Should -BeLessOrEqual $Allowed -Because "'$Section' distinct count should track the tenant within a small drift allowance (inventory=$InvDistinct, tenant=$LiveCount, allowed=$Allowed)"
    }

    It "SQLDB user-database count tracks the tenant (system 'master' excluded, drift-tolerant)" {
        if (-not $script:LiveOK) { Set-ItResult -Skipped -Because $script:LiveSkip; return }
        $InvDistinct = if ($script:BySection.ContainsKey('SQLDB')) { @($script:BySection['SQLDB'] | Sort-Object -Unique).Count } else { 0 }
        $LiveUserDbs = @($script:Live | Where-Object { $_.ResourceType -ieq 'microsoft.sql/servers/databases' -and (($_.Name -split '/')[-1] -ine 'master') }).Count
        if ($InvDistinct -eq 0 -and $LiveUserDbs -eq 0) { Set-ItResult -Skipped -Because "no SQL databases in this subscription"; return }
        $Allowed = [math]::Max(2, [math]::Ceiling($LiveUserDbs * 0.25))
        $Delta = [math]::Abs($InvDistinct - $LiveUserDbs)
        $Delta | Should -BeLessOrEqual $Allowed -Because "SQLDB should track the tenant's USER databases (system 'master' excluded by design; inventory=$InvDistinct, tenant-user-dbs=$LiveUserDbs, allowed=$Allowed)"
    }
}
