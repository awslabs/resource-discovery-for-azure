#Requires -Version 7.0

function GetLocalVersion()
{
    if ([string]::IsNullOrWhiteSpace($PSScriptRoot))
    {
        Write-Host 'Cannot resolve the script location ($PSScriptRoot is empty). Run the tool from its files on disk, not an inline script block. Exiting.' -ForegroundColor Red
        exit 1
    }

    $VersionJsonPath = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Version.json'

    if (-not (Test-Path -LiteralPath $VersionJsonPath -PathType Leaf))
    {
        Write-Host ("Version.json not found at '{0}' (expected at the repo root, alongside ResourceInventory.ps1). Ensure the full repo is present. Exiting." -f $VersionJsonPath) -ForegroundColor Red
        exit 1
    }

    try
    {
        $LocalVersionJson = Get-Content -LiteralPath $VersionJsonPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch
    {
        Write-Host ("Version.json at '{0}' could not be read or parsed as JSON: {1}. Exiting." -f $VersionJsonPath, $_.Exception.Message) -ForegroundColor Red
        exit 1
    }

    return ('{0}.{1}.{2}' -f $LocalVersionJson.MajorVersion, $LocalVersionJson.MinorVersion, $LocalVersionJson.BuildVersion)
}

function Global:Protect-FreeTextValue([string]$Value)
{
    if ([string]::IsNullOrEmpty($Value)) { return $null }
    if ($null -eq $Global:FreeTextDictionary) { return $Value }
    if (-not $Global:FreeTextDictionary.ContainsKey($Value))
    {
        $TfPrefix = if ($Value -match '\b(dev|test|qa|tst|development|non-prod|uat|nonprod)\b' -or $Value -match '(^|-)([dts])-') { 'nonprod_' } else { 'prod_' }
        $Global:FreeTextDictionary[$Value] = $TfPrefix + [guid]::NewGuid().ToString()
    }
    return $Global:FreeTextDictionary[$Value]
}

function Global:ConvertTo-RdaMarketplaceRow
{
    # Maps ONE PSMarketplace-shaped row (as returned by Get-AzConsumptionMarketplace,
    # Az.Billing) to the flat object emitted into Marketplace_<ReportName>_<stamp>.csv.
    #
    # Field names are the documented PSMarketplace property names, verified from the
    # installed cmdlet's output type
    # ([Microsoft.Azure.Commands.Consumption.Models.PSMarketplace]) and the docs:
    #   https://learn.microsoft.com/en-us/powershell/module/az.billing/get-azconsumptionmarketplace
    #   https://learn.microsoft.com/en-us/rest/api/consumption/marketplaces/list  (api-version 2023-05-01)
    #
    # OBFUSCATION. When -Obfuscate is active the caller passes $Obfuscate = $true. PublisherName /
    # OfferName / PlanName are THIRD-PARTY PRODUCT identifiers (the "which ISV / which offer" -
    # e.g. Anthropic-vs-not - signal), not customer secrets, so they are left READABLE by design.
    # Every identifying field is masked:
    #   - OrderNumber is masked, unlike the three product fields above, because it identifies a
    #     specific customer PURCHASE rather than a product. See the $OrderCache param and the
    #     inline block below for why it needs a cache of its own.
    #   - InstanceId is an ARM resource id, routed through Build-ObfuscatedResourceUri (which
    #     masks the embedded subscription and resource-group segments); its leaf resource-NAME
    #     cross-references the shared run-wide ID dictionary passed as -NameDictionary (URI-keyed),
    #     exactly as the first-party consumption path does.
    #   - SubscriptionGuid and SubscriptionName both identify ONE subscription, so both resolve to
    #     the SAME token via the shared run-wide subscription dictionary ($Global:ResourceSubscriptionDictionary,
    #     passed as -SubGuidTokenMap: a guid->token view the caller derives from it once). This is
    #     the P0 fix: without it SubscriptionGuid shipped RAW in the obfuscated, externally-shareable
    #     Marketplace_*.csv (no-customer-data-in-public.md). Routing it through the SHARED dictionary
    #     (not a fresh local token) is what makes the Marketplace row cross-reference every other
    #     sheet in the bundle for the same sub.
    #   - ResourceGroup cross-references the shared run-wide resource-group dictionary
    #     ($Global:ResourceResourceGroupDictionary, passed as -RgTokenMap: an rgName->token view),
    #     so a resource group that also appears in Inventory_*/Metrics_*/Consumption_* gets the SAME
    #     token here. When a sub/RG is absent from the shared maps (e.g. a Marketplace-only sub with
    #     no first-party resource inventoried), a deterministic local token is minted so the row is
    #     still internally consistent.
    #   - InstanceName is a leaf resource name with no shared-dictionary equivalent, tokenised
    #     deterministically within the run via the local NameCache.
    # NOTE: this deliberately DIVERGES from the first-party consumption path for the sub/RG dimensions
    # (consumption passes $null shared sub/RG dictionaries and emits no bare subscription-GUID column
    # at all). The divergence is intentional: the Marketplace CSV carries explicit SubscriptionGuid /
    # SubscriptionName / ResourceGroup columns that MUST cross-reference the rest of the bundle.
    param(
        [Parameter(Mandatory = $true)]$Row,
        [bool]$Obfuscate = $false,
        # URI-keyed shared resource-ID dictionary ($Global:ResourceIdDictionary). Passed as the
        # -NameDictionary to Build-ObfuscatedResourceUri, which keys the InstanceId leaf on the FULL
        # resource URI (NOT the resource name) - so this must be the ID dictionary, not
        # $Global:ResourceNameDictionary, which is keyed differently and would break the cross-reference.
        $UriKeyedNameDictionary = $null,
        # guid -> shared-subscription-token view, derived by the caller from $Global:ResourceSubscriptionDictionary.
        $SubGuidTokenMap = $null,
        # rgName -> shared-resource-group-token view, derived by the caller from $Global:ResourceResourceGroupDictionary.
        $RgTokenMap = $null,
        [hashtable]$SubCache = $null,
        [hashtable]$RgCache = $null,
        [hashtable]$NameCache = $null,
        # OrderNumber needs its OWN cache, not $NameCache: Resolve-ObfuscationToken keys its local
        # cache by the REAL VALUE, so sharing a cache with InstanceName would make an order number
        # and an identically-spelled resource name collapse onto one token.
        [hashtable]$OrderCache = $null
    )

    $OutInstanceId = $Row.InstanceId
    $OutResourceGroup = $Row.ResourceGroup
    $OutSubscriptionName = $Row.SubscriptionName
    $OutInstanceName = $Row.InstanceName
    $OutSubscriptionGuid = $Row.SubscriptionGuid
    $OutOrderNumber = $Row.OrderNumber

    if ($Obfuscate)
    {
        if ($null -eq $SubCache) { $SubCache = @{} }
        if ($null -eq $RgCache) { $RgCache = @{} }
        if ($null -eq $NameCache) { $NameCache = @{} }
        if ($null -eq $OrderCache) { $OrderCache = @{} }

        $Prefix = if ("$($Row.InstanceId) $($Row.InstanceName) $($Row.ResourceGroup)" -match '\b(dev|test|qa|tst|development|non-prod|uat|nonprod)\b' -or "$($Row.InstanceId)" -match '(^|/|-)([dts])-') { 'nonprod_' } else { 'prod_' }

        if (-not [string]::IsNullOrEmpty($Row.InstanceId))
        {
            $OutInstanceId = Build-ObfuscatedResourceUri -RawUri $Row.InstanceId -Prefix $Prefix -SubscriptionDictionary $null -ResourceGroupDictionary $null -NameDictionary $UriKeyedNameDictionary -SubCache $SubCache -RgCache $RgCache -NameCache $NameCache
        }

        # SubscriptionGuid + SubscriptionName both identify ONE subscription. Resolve the shared
        # subscription token from the GUID (the unambiguous key) and reuse it for BOTH, so the whole
        # Marketplace row's subscription identity matches the token used elsewhere in the bundle.
        # The shared token is keyed on the raw GUID (via $SubGuidTokenMap) so it survives across rows
        # and subscriptions; $SubCache is the deterministic local fallback when the GUID is not in the
        # shared map (a Marketplace-only sub with nothing in the first-party inventory).
        $SharedSubToken = $null
        if (-not [string]::IsNullOrEmpty($Row.SubscriptionGuid))
        {
            $SharedSubToken = Resolve-ObfuscationToken -RealValue $Row.SubscriptionGuid -LookupKey $Row.SubscriptionGuid -SharedDictionary $SubGuidTokenMap -LocalCache $SubCache -TokenPrefix ($Prefix + 'sub_')
            $OutSubscriptionGuid = $SharedSubToken
        }

        if (-not [string]::IsNullOrEmpty($Row.SubscriptionName))
        {
            if ($null -ne $SharedSubToken)
            {
                $OutSubscriptionName = $SharedSubToken
            }
            else
            {
                # No GUID on the row to anchor the shared token; fall back to a deterministic local
                # token keyed by the subscription name.
                $OutSubscriptionName = Resolve-ObfuscationToken -RealValue $Row.SubscriptionName -LookupKey $Row.SubscriptionName -SharedDictionary $null -LocalCache $SubCache -TokenPrefix ($Prefix + 'sub_')
            }
        }

        if (-not [string]::IsNullOrEmpty($Row.ResourceGroup))
        {
            $RgTag = if ($Row.ResourceGroup -match '^mc_') { 'mc_' } else { '' }
            $OutResourceGroup = Resolve-ObfuscationToken -RealValue $Row.ResourceGroup -LookupKey $Row.ResourceGroup -SharedDictionary $RgTokenMap -LocalCache $RgCache -TokenPrefix ($Prefix + 'rg_' + $RgTag)
        }

        if (-not [string]::IsNullOrEmpty($Row.InstanceName))
        {
            $OutInstanceName = Resolve-ObfuscationToken -RealValue $Row.InstanceName -LookupKey $Row.InstanceName -SharedDictionary $null -LocalCache $NameCache -TokenPrefix $Prefix
        }

        # OrderNumber identifies a specific customer PURCHASE, which is why it is masked while
        # PublisherName / OfferName / PlanName stay readable - those say WHICH PRODUCT was bought
        # (the signal the report exists to carry), this says WHO bought it and under which order.
        # There is no shared dictionary for it, so it is tokenised deterministically within the run
        # from its OWN $OrderCache. It must NOT share $NameCache: Resolve-ObfuscationToken keys the
        # local cache by the REAL VALUE, so an order number and an identically-spelled instance name
        # would otherwise return whichever token was minted first and imply a relationship between
        # two unrelated dimensions.
        if (-not [string]::IsNullOrEmpty($Row.OrderNumber))
        {
            $OutOrderNumber = Resolve-ObfuscationToken -RealValue $Row.OrderNumber -LookupKey $Row.OrderNumber -SharedDictionary $null -LocalCache $OrderCache -TokenPrefix ($Prefix + 'order_')
        }
    }

    return [PSCustomObject]@{
        PublisherName    = $Row.PublisherName
        OfferName        = $Row.OfferName
        PlanName         = $Row.PlanName
        OrderNumber      = $OutOrderNumber
        ConsumedService  = $Row.ConsumedService
        ConsumedQuantity = $Row.ConsumedQuantity
        UnitOfMeasure    = $Row.UnitOfMeasure
        PretaxCost       = $Row.PretaxCost
        Currency         = $Row.Currency
        IsEstimated      = $Row.IsEstimated
        MeterId          = $Row.MeterId
        UsageStart       = $Row.UsageStart
        UsageEnd         = $Row.UsageEnd
        SubscriptionGuid = $OutSubscriptionGuid
        SubscriptionName = $OutSubscriptionName
        ResourceGroup    = $OutResourceGroup
        InstanceId       = $OutInstanceId
        InstanceName     = $OutInstanceName
    }
}

function Global:Get-RdaFoundryModelMatchTokens
{
    # Normalizes a free-form model/meter string into a lower-cased set of alphanumeric
    # tokens, used by Test-RdaRetailPriceMatch to compare a deployed model's identity
    # against a Retail Prices catalog entry WITHOUT a hardcoded model->meter table.
    #
    # WHY. There is no clean join key between a deployment's properties.model.name
    # (e.g. 'gpt-4o', 'claude-opus-5') and a Retail Prices meterName/skuName/productName
    # (e.g. 'Azure OpenAI GPT5', '5.4 opt Dz 1M Tokens') - the catalog names are
    # marketing-shaped and abbreviated (the design spec section 4.3). So we compare on normalized
    # token OVERLAP rather than an exact key. Purely mechanical, so it lives in a pure
    # helper and is unit-tested.
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return @() }

    # Lower-case, split on any non-alphanumeric run, drop empties and 1-char noise.
    $Lower = $Value.ToLowerInvariant()
    $Parts = [regex]::Split($Lower, '[^a-z0-9]+') | Where-Object { $_.Length -ge 2 }
    return @($Parts | Select-Object -Unique)
}

function Global:Test-RdaRetailPriceMatch
{
    # Decides whether a single deployed model has a CONFIDENT match among the supplied
    # Azure Retail Prices catalog items (serviceName eq 'Foundry Models'), returning the
    # matched productName/meterName so the server team can audit the match (the design spec section 4.3).
    #
    # CONSERVATIVE + PER-MODEL (the design spec section 4.2/4.3): the match is decided at the individual
    # catalog-item granularity, never at vendor granularity - a vendor like Cohere/Llama/
    # Mistral can be PARTIALLY present (some SKUs metered, others not), so "the vendor has
    # meters" is NOT proof this SKU is metered. A match requires BOTH:
    #   1. the model's vendor discriminator (ModelFormat, e.g. 'OpenAI') to appear in the
    #      catalog item's tokens, AND
    #   2. the distinctive tokens of the model's name/version (e.g. 'gpt','4o') to be
    #      covered by the catalog item's tokens.
    # A miss is NOT proof of absence (it may be a naming mismatch) - the caller combines
    # this with the Marketplace probe before ever emitting UNPRICED (the design spec section 4.3/10).
    param(
        [Parameter(Mandatory = $true)]$Model,
        $CatalogItems
    )

    $Result = [pscustomobject]@{
        Matched      = $false
        RetailMatch  = '(no confident Retail Prices match)'
    }

    if ($null -eq $CatalogItems -or @($CatalogItems).Count -eq 0) { return $Result }

    $ModelName = "$($Model.ModelName)"
    $ModelFormat = "$($Model.ModelFormat)"

    $NameTokens = @(Get-RdaFoundryModelMatchTokens -Value $ModelName)
    $FormatTokens = @(Get-RdaFoundryModelMatchTokens -Value $ModelFormat)

    # A model with no usable name tokens cannot be confidently matched - be conservative.
    if ($NameTokens.Count -eq 0) { return $Result }

    foreach ($Item in @($CatalogItems))
    {
        if ($null -eq $Item) { continue }

        $ItemText = @(
            "$($Item.productName)"
            "$($Item.meterName)"
            "$($Item.skuName)"
            "$($Item.armSkuName)"
        ) -join ' '
        $ItemTokens = @(Get-RdaFoundryModelMatchTokens -Value $ItemText)
        if ($ItemTokens.Count -eq 0) { continue }

        # Condition 1: vendor discriminator present (when we have one to check).
        $VendorOk = $true
        if ($FormatTokens.Count -gt 0)
        {
            $VendorOk = @($FormatTokens | Where-Object { $ItemTokens -contains $_ }).Count -gt 0
        }
        if (-not $VendorOk) { continue }

        # Condition 2: the model's distinctive name tokens are covered by the item's
        # tokens. Require ALL name tokens (drift-safe: a partial coincidental token
        # overlap must not count as a confident match).
        $NameCovered = @($NameTokens | Where-Object { $ItemTokens -notcontains $_ }).Count -eq 0
        if (-not $NameCovered) { continue }

        $Result.Matched = $true
        $Result.RetailMatch = ("{0} / {1}" -f "$($Item.productName)", "$($Item.meterName)").Trim(' /')
        return $Result
    }

    return $Result
}

function Global:Test-RdaMarketplaceModelMatch
{
    # Decides whether a deployed model is covered by the Marketplace plane, by looking for
    # a Marketplace/CCU row (PSMarketplace-shaped) whose PublisherName/OfferName corresponds
    # to the model's vendor (the design spec section 5.2). Because CCU is billed as a SINGLE AGGREGATED
    # line per subscription/offer (the design spec section 2.1/5.2), we do NOT expect one row per model:
    # any attributable Marketplace row for the model's vendor is Marketplace-plane evidence.
    #
    # Returns the matched row (for CCU quantity/cost) and whether the CCU could be tied to a
    # SPECIFIC deployment (PerModel) or only to the offer aggregate (AggregatedOffer).
    param(
        [Parameter(Mandatory = $true)]$Model,
        $MarketplaceRows
    )

    $Result = [pscustomobject]@{
        Matched        = $false
        Row            = $null
        CcuAttribution = $null
    }

    if ($null -eq $MarketplaceRows -or @($MarketplaceRows).Count -eq 0) { return $Result }

    $VendorTokens = @(Get-RdaFoundryModelMatchTokens -Value "$($Model.ModelFormat) $($Model.ModelName)")
    $AccountRg = "$($Model.ResourceGroup)"
    $AccountId = "$($Model.AccountId)"

    $BestOfferRow = $null

    foreach ($Row in @($MarketplaceRows))
    {
        if ($null -eq $Row) { continue }

        $OfferText = @("$($Row.PublisherName)", "$($Row.OfferName)", "$($Row.PlanName)") -join ' '
        $OfferTokens = @(Get-RdaFoundryModelMatchTokens -Value $OfferText)
        if ($OfferTokens.Count -eq 0) { continue }

        # Vendor alignment: any overlap between the model's vendor tokens and the offer's
        # publisher/offer tokens (e.g. 'anthropic'/'claude'). Vendor-level here is CORRECT:
        # Marketplace attribution is inherently offer-level (aggregated), unlike the
        # per-model Retail Prices match.
        $VendorAligned = @($VendorTokens | Where-Object { $OfferTokens -contains $_ }).Count -gt 0
        if (-not $VendorAligned) { continue }

        # Can we tie the CCU line to THIS specific deployment/account? Only if the row's
        # InstanceId/ResourceGroup references the model's account/RG. The common case is
        # NO (aggregation collapses per-model detail) -> AggregatedOffer.
        $InstanceId = "$($Row.InstanceId)"
        $RowRg = "$($Row.ResourceGroup)"
        $TiedToDeployment = $false
        if (-not [string]::IsNullOrEmpty($AccountId) -and -not [string]::IsNullOrEmpty($InstanceId) -and $InstanceId -like ("*" + $AccountId + "*"))
        {
            $TiedToDeployment = $true
        }
        elseif (-not [string]::IsNullOrEmpty($AccountRg) -and -not [string]::IsNullOrEmpty($RowRg) -and $RowRg -eq $AccountRg)
        {
            $TiedToDeployment = $true
        }

        if ($TiedToDeployment)
        {
            $Result.Matched = $true
            $Result.Row = $Row
            $Result.CcuAttribution = 'PerModel'
            return $Result
        }

        if ($null -eq $BestOfferRow) { $BestOfferRow = $Row }
    }

    if ($null -ne $BestOfferRow)
    {
        $Result.Matched = $true
        $Result.Row = $BestOfferRow
        $Result.CcuAttribution = 'AggregatedOffer'
    }

    return $Result
}

function Global:Get-RdaFoundryCoverageStatus
{
    # The core branch/flag decision (the design spec section 3-5, 9, 10). Given the outcome of BOTH
    # plane probes for one deployed model, returns the CoverageStatus + a human-readable
    # CoverageFlag. This is the whole point of the collector - it is what fixes "dropped
    # with no warning".
    #
    # KEY INVARIANT (no-overclaiming, the design spec section 10): UNPRICED is emitted ONLY when BOTH
    # planes were SUCCESSFULLY probed and BOTH came back negative. If either probe
    # failed/was denied/was unreachable, the status is Unknown-<reason>, NEVER UNPRICED -
    # a probe failure must never masquerade as a confirmed coverage gap.
    param(
        [bool]$AzureMetered,          # confident Retail Prices match found
        [bool]$MarketplaceCovered,    # Marketplace/CCU evidence found
        [bool]$RetailProbed = $true,  # was the Retail Prices catalog readable this run?
        [bool]$MarketplaceProbed = $true, # was the Marketplace plane successfully probed for this sub?
        [string]$MarketplaceDeniedReason = $null # set when Marketplace was denied/failed
    )

    if ($AzureMetered)
    {
        $Status = if ($MarketplaceCovered) { 'AzureMetered+Marketplace' } else { 'AzureMetered' }
        $Flag = if ($MarketplaceCovered)
        {
            'Billed on BOTH planes: an Azure meter exists (Retail Prices) AND Marketplace/CCU usage was found.'
        }
        else
        {
            'Azure-metered: a matching meter exists in the Retail Prices API. Priced by the server team via Retail Prices.'
        }
        return [pscustomobject]@{ CoverageStatus = $Status; CoverageFlag = $Flag }
    }

    if ($MarketplaceCovered)
    {
        return [pscustomobject]@{
            CoverageStatus = 'MarketplaceOnly'
            CoverageFlag   = 'Marketplace-billed, absent from Retail Prices - priced via CCU path.'
        }
    }

    # Neither plane came back positive. Decide UNPRICED vs Unknown-<reason> based on
    # whether BOTH planes were actually probed successfully.
    if (-not $MarketplaceProbed)
    {
        $Reason = if (-not [string]::IsNullOrEmpty($MarketplaceDeniedReason)) { $MarketplaceDeniedReason } else { 'MarketplaceNotProbed' }
        return [pscustomobject]@{
            CoverageStatus = ('Unknown-' + $Reason)
            CoverageFlag   = ('Coverage INDETERMINATE on the Marketplace axis ({0}); NOT declared UNPRICED because the Marketplace plane was not successfully probed. Grant Cost Management Reader (or Billing Reader on the billing scope) and re-run.' -f $Reason)
        }
    }

    if (-not $RetailProbed)
    {
        return [pscustomobject]@{
            CoverageStatus = 'Unknown-RetailCatalogUnavailable'
            CoverageFlag   = 'Coverage INDETERMINATE on the Azure-metered axis (Retail Prices catalog could not be read this run); NOT declared UNPRICED. Retry when the price catalog is reachable.'
        }
    }

    # BOTH planes probed, BOTH negative -> a genuine, confirmed coverage gap.
    return [pscustomobject]@{
        CoverageStatus = 'UNPRICED'
        CoverageFlag   = 'UNPRICED MODEL / COVERAGE GAP - deployed model found in NEITHER billing plane (no Retail Prices meter, no Marketplace/CCU usage). Do NOT silently drop; the server team must investigate.'
    }
}

function Global:ConvertTo-RdaFoundryCoverageRow
{
    # Maps ONE classified deployed-model record to the flat object emitted into
    # FoundryModelCoverage_<ReportName>_<stamp>.csv, and applies obfuscation with the SAME
    # discipline as ConvertTo-RdaMarketplaceRow (the design spec section 9.1):
    #   - READABLE (product/plane identity, not customer secrets): AccountKind, ModelName,
    #     ModelFormat, ModelVersion, DeploymentSku, DeploymentCapacity, Region,
    #     DetectedPlanes, CoverageStatus, CoverageFlag, RetailPriceMatch,
    #     MarketplacePublisher, MarketplaceOffer, CcuAttribution, all numeric usage/cost,
    #     the probe presence flags, and the run window/timestamp.
    #   - MASKED (identifying), via the SHARED run-wide dictionaries so tokens
    #     cross-reference the rest of the bundle: SubscriptionGuid, SubscriptionName,
    #     ResourceGroup, AccountName, DeploymentName. Reuses the exact
    #     Resolve-ObfuscationToken + shared SubGuidTokenMap/RgTokenMap machinery the
    #     Marketplace collector uses; a sub/RG absent from the shared maps mints a
    #     deterministic local token so the row is still internally consistent.
    param(
        [Parameter(Mandatory = $true)]$Record,
        [bool]$Obfuscate = $false,
        $SubGuidTokenMap = $null,
        $RgTokenMap = $null,
        [hashtable]$SubCache = $null,
        [hashtable]$RgCache = $null,
        [hashtable]$NameCache = $null
    )

    $OutSubscriptionGuid = $Record.SubscriptionGuid
    $OutSubscriptionName = $Record.SubscriptionName
    $OutResourceGroup = $Record.ResourceGroup
    $OutAccountName = $Record.AccountName
    $OutDeploymentName = $Record.DeploymentName

    if ($Obfuscate)
    {
        if ($null -eq $SubCache) { $SubCache = @{} }
        if ($null -eq $RgCache) { $RgCache = @{} }
        if ($null -eq $NameCache) { $NameCache = @{} }

        $Prefix = if ("$($Record.AccountName) $($Record.DeploymentName) $($Record.ResourceGroup)" -match '\b(dev|test|qa|tst|development|non-prod|uat|nonprod)\b' -or "$($Record.AccountName) $($Record.DeploymentName)" -match '(^|/|-)([dts])-') { 'nonprod_' } else { 'prod_' }

        $SharedSubToken = $null
        if (-not [string]::IsNullOrEmpty($Record.SubscriptionGuid))
        {
            $SharedSubToken = Resolve-ObfuscationToken -RealValue $Record.SubscriptionGuid -LookupKey $Record.SubscriptionGuid -SharedDictionary $SubGuidTokenMap -LocalCache $SubCache -TokenPrefix ($Prefix + 'sub_')
            $OutSubscriptionGuid = $SharedSubToken
        }

        if (-not [string]::IsNullOrEmpty($Record.SubscriptionName))
        {
            if ($null -ne $SharedSubToken)
            {
                $OutSubscriptionName = $SharedSubToken
            }
            else
            {
                $OutSubscriptionName = Resolve-ObfuscationToken -RealValue $Record.SubscriptionName -LookupKey $Record.SubscriptionName -SharedDictionary $null -LocalCache $SubCache -TokenPrefix ($Prefix + 'sub_')
            }
        }

        if (-not [string]::IsNullOrEmpty($Record.ResourceGroup))
        {
            $RgTag = if ($Record.ResourceGroup -match '^mc_') { 'mc_' } else { '' }
            $OutResourceGroup = Resolve-ObfuscationToken -RealValue $Record.ResourceGroup -LookupKey $Record.ResourceGroup -SharedDictionary $RgTokenMap -LocalCache $RgCache -TokenPrefix ($Prefix + 'rg_' + $RgTag)
        }

        if (-not [string]::IsNullOrEmpty($Record.AccountName))
        {
            $OutAccountName = Resolve-ObfuscationToken -RealValue $Record.AccountName -LookupKey $Record.AccountName -SharedDictionary $null -LocalCache $NameCache -TokenPrefix $Prefix
        }

        if (-not [string]::IsNullOrEmpty($Record.DeploymentName))
        {
            $OutDeploymentName = Resolve-ObfuscationToken -RealValue $Record.DeploymentName -LookupKey $Record.DeploymentName -SharedDictionary $null -LocalCache $NameCache -TokenPrefix $Prefix
        }
    }

    return [PSCustomObject]@{
        SubscriptionGuid      = $OutSubscriptionGuid
        SubscriptionName      = $OutSubscriptionName
        ResourceGroup         = $OutResourceGroup
        AccountName           = $OutAccountName
        AccountKind           = $Record.AccountKind
        DeploymentName        = $OutDeploymentName
        ModelName             = $Record.ModelName
        ModelFormat           = $Record.ModelFormat
        ModelVersion          = $Record.ModelVersion
        DeploymentSku         = $Record.DeploymentSku
        DeploymentCapacity    = $Record.DeploymentCapacity
        Region                = $Record.Region
        DetectedPlanes        = $Record.DetectedPlanes
        CoverageStatus        = $Record.CoverageStatus
        CoverageFlag          = $Record.CoverageFlag
        RetailPriceMatch      = $Record.RetailPriceMatch
        MarketplacePublisher  = $Record.MarketplacePublisher
        MarketplaceOffer      = $Record.MarketplaceOffer
        CcuQuantity           = $Record.CcuQuantity
        CcuUnitOfMeasure      = $Record.CcuUnitOfMeasure
        MarketplacePretaxCost = $Record.MarketplacePretaxCost
        MarketplaceCurrency   = $Record.MarketplaceCurrency
        CcuAttribution        = $Record.CcuAttribution
        TokenMetricsPresent   = $Record.TokenMetricsPresent
        InputTokens           = $Record.InputTokens
        OutputTokens          = $Record.OutputTokens
        TotalTokens           = $Record.TotalTokens
        AppInsightsLinked     = $Record.AppInsightsLinked
        PerCallTokenSource    = $Record.PerCallTokenSource
        PerCallInputTokens    = $Record.PerCallInputTokens
        PerCallOutputTokens   = $Record.PerCallOutputTokens
        PerCallCacheTokens    = $Record.PerCallCacheTokens
        ProbeWindowStart      = $Record.ProbeWindowStart
        ProbeWindowEnd        = $Record.ProbeWindowEnd
        RunTimestampUtc       = $Record.RunTimestampUtc
    }
}

function Global:Get-RdaFoundryRetailCatalog
{
    # Pulls the Azure Retail Prices catalog for serviceName 'Foundry Models' (the design spec section 4.1).
    # The API is GLOBAL and UNAUTHENTICATED - no Azure permission, no per-tenant scoping - so
    # this is a plain paged HTTP GET, called ONCE per run and cached by the caller. It answers
    # only "does a first-party Azure meter exist for this model?" (plane membership), not usage.
    #   https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices
    param(
        [string]$ServiceName = 'Foundry Models',
        [int]$MaxPages = 200
    )

    $Base = 'https://prices.azure.com/api/retail/prices?api-version=2023-01-01-preview'
    $Filter = [uri]::EscapeDataString("serviceName eq '$ServiceName'")
    $Uri = $Base + '&$filter=' + $Filter
    $Items = [System.Collections.ArrayList]::new()
    $Page = 0

    while (-not [string]::IsNullOrEmpty($Uri) -and $Page -lt $MaxPages)
    {
        $Resp = Invoke-RestMethod -Uri $Uri -Method GET -ErrorAction Stop
        if ($null -ne $Resp.Items) { foreach ($It in $Resp.Items) { $null = $Items.Add($It) } }
        $Uri = $Resp.NextPageLink
        $Page++
    }

    return @($Items)
}

function Global:Get-RdaFoundryTokenMetrics
{
    # OPTIONAL richer usage tier (the design spec section 6): per-deployment token metrics from Azure
    # Monitor, DISCOVERED at runtime via Get-AzMetricDefinition (never hardcoded) because the
    # metric set differs by account kind and evolves. Returns presence + summed token counts,
    # or a Present=$false record. A Marketplace/partner deployment that emits nothing here is
    # EXPECTED, not an error - this NEVER throws for an absent/empty metric; it only surfaces
    # genuine call failures to the caller (which records them as absent, not failed).
    param(
        [Parameter(Mandatory = $true)][string]$AccountId,
        [Parameter(Mandatory = $true)][string]$DeploymentName,
        [Parameter(Mandatory = $true)][datetime]$StartTime,
        [Parameter(Mandatory = $true)][datetime]$EndTime
    )

    $Result = [pscustomobject]@{ Present = $false; InputTokens = ''; OutputTokens = ''; TotalTokens = '' }

    $Defs = @()
    try { $Defs = @(Get-AzMetricDefinition -ResourceId $AccountId -ErrorAction Stop) }
    catch { return $Result }  # metrics not authorized / not available -> absent, not failed

    # Discover token metrics by NAME rather than assuming a fixed set. Azure OpenAI exposes
    # ProcessedPromptTokens/GeneratedTokens; newer AIServices adds InputTokens/OutputTokens/
    # TotalTokens - all dimensioned by ModelDeploymentName (the design spec section 6.1).
    $NameOf = { param($d) if ($d.Name.Value) { $d.Name.Value } else { "$($d.Name)" } }
    $HasMetric = { param($n) @($Defs | Where-Object { (& $NameOf $_) -eq $n }).Count -gt 0 }

    $InputMetric = @('InputTokens', 'ProcessedPromptTokens') | Where-Object { & $HasMetric $_ } | Select-Object -First 1
    $OutputMetric = @('OutputTokens', 'GeneratedTokens') | Where-Object { & $HasMetric $_ } | Select-Object -First 1
    $TotalMetric = @('TotalTokens') | Where-Object { & $HasMetric $_ } | Select-Object -First 1

    if (-not $InputMetric -and -not $OutputMetric -and -not $TotalMetric) { return $Result }

    $DimFilter = ("ModelDeploymentName eq '{0}'" -f $DeploymentName)
    $Sum = {
        param($MetricName)
        if ([string]::IsNullOrEmpty($MetricName)) { return $null }
        try
        {
            $M = Get-AzMetric -ResourceId $AccountId -MetricName $MetricName -AggregationType Total -StartTime $StartTime -EndTime $EndTime -TimeGrain '1.00:00:00' -MetricFilter $DimFilter -WarningAction SilentlyContinue -ErrorAction Stop
            $Total = 0.0
            foreach ($Series in @($M.Data)) { foreach ($Pt in @($Series.Data)) { if ($null -ne $Pt.Total) { $Total += [double]$Pt.Total } } }
            return $Total
        }
        catch { return $null }
    }

    $In = & $Sum $InputMetric
    $Out = & $Sum $OutputMetric
    $Tot = & $Sum $TotalMetric

    if ($null -ne $In -or $null -ne $Out -or $null -ne $Tot)
    {
        $Result.Present = $true
        if ($null -ne $In) { $Result.InputTokens = $In }
        if ($null -ne $Out) { $Result.OutputTokens = $Out }
        if ($null -ne $Tot) { $Result.TotalTokens = $Tot }
    }

    return $Result
}

function Global:Resolve-ObfuscationToken
{
    param(
        [string]$RealValue,
        [string]$LookupKey,
        $SharedDictionary,
        [hashtable]$LocalCache,
        [string]$TokenPrefix
    )

    if ($null -ne $SharedDictionary -and $SharedDictionary.ContainsKey($LookupKey)) { return $SharedDictionary[$LookupKey] }
    if ($LocalCache.ContainsKey($RealValue)) { return $LocalCache[$RealValue] }

    $Token = $TokenPrefix + [guid]::NewGuid().ToString()
    $LocalCache[$RealValue] = $Token
    return $Token
}

function Global:Build-ObfuscatedResourceUri
{
    param(
        [string]$RawUri,
        [string]$Prefix,
        $SubscriptionDictionary,
        $ResourceGroupDictionary,
        $NameDictionary,
        [hashtable]$SubCache,
        [hashtable]$RgCache,
        [hashtable]$NameCache
    )

    if ([string]::IsNullOrEmpty($RawUri))
    {
        return 'obfuscated'
    }

    if ($RawUri -notmatch '^/subscriptions/([^/]+)(/resourcegroups/([^/]+))?(/providers/(.+))?$')
    {
        if (-not $NameCache.ContainsKey($RawUri))
        {
            $NameCache[$RawUri] = $Prefix + [guid]::NewGuid().ToString()
        }
        return $NameCache[$RawUri]
    }

    $RealSub = $Matches[1]
    $RealRg = $Matches[3]
    $RealProv = $Matches[5]

    $ObfSub = Resolve-ObfuscationToken -RealValue $RealSub -LookupKey $RawUri -SharedDictionary $SubscriptionDictionary -LocalCache $SubCache -TokenPrefix ($Prefix + 'sub_')
    $RebuiltUri = '/subscriptions/' + $ObfSub

    if (-not [string]::IsNullOrEmpty($RealRg))
    {
        $RgTag = if ($RealRg -match '^mc_') { 'mc_' } else { '' }
        $ObfRg = Resolve-ObfuscationToken -RealValue $RealRg -LookupKey $RawUri -SharedDictionary $ResourceGroupDictionary -LocalCache $RgCache -TokenPrefix ($Prefix + 'rg_' + $RgTag)
        $RebuiltUri += '/resourcegroups/' + $ObfRg
    }

    if (-not [string]::IsNullOrEmpty($RealProv))
    {
        $ProvParts = $RealProv -split '/'
        $LeafNameIndex = -1
        for ($Li = $ProvParts.Count - 1; $Li -ge 2; $Li--)
        {
            if ($Li % 2 -eq 0) { $LeafNameIndex = $Li; break }
        }

        $Rebuilt = @()
        for ($Pi = 0; $Pi -lt $ProvParts.Count; $Pi++)
        {
            $Part = $ProvParts[$Pi]
            $IsNameSegment = ($Pi -ge 2 -and ($Pi % 2 -eq 0))
            if ($IsNameSegment -and -not [string]::IsNullOrEmpty($Part) -and $Part -ne '$system')
            {
                $LeafShared = if ($Pi -eq $LeafNameIndex) { $NameDictionary } else { $null }
                $Rebuilt += Resolve-ObfuscationToken -RealValue $Part -LookupKey $RawUri -SharedDictionary $LeafShared -LocalCache $NameCache -TokenPrefix $Prefix
            }
            else
            {
                $Rebuilt += $Part
            }
        }
        $RebuiltUri += '/providers/' + ($Rebuilt -join '/')
    }

    return $RebuiltUri
}

function Global:Protect-DiagnosticText([string]$Text, [System.Collections.IDictionary]$ValueMap)
{
    if ([string]::IsNullOrEmpty($Text)) { return $Text }

    $Result = $Text
    if ($null -ne $ValueMap -and $ValueMap.Count -gt 0)
    {
        foreach ($real in ($ValueMap.Keys | Sort-Object -Property Length -Descending))
        {
            if (-not [string]::IsNullOrEmpty($real) -and $Result.Contains($real))
            {
                $Result = $Result.Replace($real, $ValueMap[$real])
            }
        }
    }

    $Result = [regex]::Replace($Result, '(?i)\b(sig|signature|sas|accesstoken|access_token|bearertoken|accountkey|sharedaccesskey|sharedaccesssignature|password|pwd|client_secret|clientsecret|[a-z0-9_\-]*(?:key|secret|token))=[^&;\s"''<>]+', '$1=<redacted>')
    $Result = [regex]::Replace($Result, '(?i)\bBearer\s+[A-Za-z0-9._\-]+', 'Bearer <redacted>')

    $Result = [regex]::Replace($Result, '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}', '<email>')
    $Result = [regex]::Replace($Result, '\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b', '<ip>')
    $Result = [regex]::Replace($Result, '(?i)\b[a-z0-9][a-z0-9-]*\.(?:blob|file|queue|table|dfs|vault|database|servicebus|azurewebsites|documents|search|azurecr|azuredatabricks|cognitiveservices|azconfig|azurefd|azure-api)\.[a-z0-9.]+\b', '<host>')
    $Result = [regex]::Replace($Result, '(?i)\b[a-z0-9][a-z0-9-]*\.(?:cloudapp\.azure\.com|trafficmanager\.net|cache\.windows\.net)\b', '<host>')
    $Result = [regex]::Replace($Result, '(?i)/home/[a-z0-9._-]+', '/home/<user>')
    $Result = [regex]::Replace($Result, '(?i)C:\\Users\\[a-z0-9._-]+', 'C:\Users\<user>')
    $Result = [regex]::Replace($Result, '(?<!_)\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b', '<guid>')

    return $Result
}

function Get-RetryWaitSeconds
{
    param(
        [Parameter(Mandatory = $true)]$Exception,
        [Parameter(Mandatory = $true)][double]$FallbackSeconds,
        [double]$MaxSeconds = 120
    )

    $ReadHeader = {
        param($Container, $Name)
        if ($null -eq $Container) { return $null }
        $Enum = $null
        try { $Enum = $Container.GetEnumerator() } catch { return $null }
        if ($null -eq $Enum) { return $null }
        while ($Enum.MoveNext())
        {
            $Pair = $Enum.Current
            if ($Pair.Key -and (([string]$Pair.Key).Trim().ToLowerInvariant() -eq $Name))
            {
                $Val = @($Pair.Value)[0]
                if ($null -ne $Val) { return [string]$Val }
            }
        }
        return $null
    }

    $Containers = @()
    foreach ($Ex in @($Exception, $Exception.InnerException))
    {
        if ($null -ne $Ex -and $null -ne $Ex.Response -and $null -ne $Ex.Response.Headers)
        {
            $Containers += $Ex.Response.Headers
        }
    }
    if ($Containers.Count -eq 0) { return $FallbackSeconds }

    $FirstHeader = {
        param($Name)
        foreach ($Container in $Containers)
        {
            $Found = & $ReadHeader $Container $Name
            if ($Found) { return $Found }
        }
        return $null
    }

    $Raw = & $FirstHeader 'retry-after'
    if ($Raw)
    {
        $Sec = 0
        if ([int]::TryParse($Raw.Trim(), [ref]$Sec) -and $Sec -gt 0)
        {
            return [math]::Min([math]::Max($Sec, 1), $MaxSeconds)
        }
    }

    $Raw = & $FirstHeader 'x-ms-ratelimit-microsoft.consumption-retry-after'
    if ($Raw)
    {
        $Sec = 0
        if ([int]::TryParse($Raw.Trim(), [ref]$Sec) -and $Sec -gt 0)
        {
            return [math]::Min([math]::Max($Sec, 1), $MaxSeconds)
        }
    }

    $Raw = & $FirstHeader 'x-ms-user-quota-resets-after'
    if ($Raw)
    {
        $Span = [TimeSpan]::Zero
        if ([TimeSpan]::TryParse($Raw.Trim(), [System.Globalization.CultureInfo]::InvariantCulture, [ref]$Span) -and $Span.TotalSeconds -ge 1)
        {
            return [math]::Min($Span.TotalSeconds, $MaxSeconds)
        }
    }

    return $FallbackSeconds
}

function Get-AzGraphErrorInfo
{
    param($Exception)

    $Info = [pscustomobject]@{
        Codes               = @()
        HttpStatus          = 0
        Message             = ''
        HasStructuredBody   = $false
        IsPayloadTooLarge   = $false
        IsThrottled         = $false
        IsPermanent         = $false
        IsEmptyPropertyName = $false
    }
    if ($null -eq $Exception) { return $Info }

    try { $Info.Message = [string]$Exception.Message } catch { $Info.Message = '' }

    $Codes = New-Object System.Collections.Generic.List[string]
    $Node = $Exception
    $Depth = 0
    while ($null -ne $Node -and $Depth -lt 5)
    {
        try
        {
            $Err = $Node.Body.Error
            if ($null -ne $Err)
            {
                $Info.HasStructuredBody = $true
                if ($Err.Code) { $Codes.Add([string]$Err.Code) }
                foreach ($Detail in @($Err.Details))
                {
                    if ($Detail -and $Detail.Code) { $Codes.Add([string]$Detail.Code) }
                }
            }
        }
        catch { }
        if ($Info.HttpStatus -eq 0)
        {
            try
            {
                if ($null -ne $Node.Response -and $null -ne $Node.Response.StatusCode)
                {
                    $Info.HttpStatus = [int]$Node.Response.StatusCode
                }
            }
            catch { }
        }
        try { $Node = $Node.InnerException } catch { $Node = $null }
        $Depth++
    }
    $Info.Codes = @($Codes | Select-Object -Unique)

    $HasCode = {
        param([string]$Name)
        foreach ($C in $Info.Codes) { if ($C -and $C.Equals($Name, [System.StringComparison]::OrdinalIgnoreCase)) { return $true } }
        return $false
    }

    $Info.IsPayloadTooLarge = (& $HasCode 'ResponsePayloadTooLarge')

    $Info.IsThrottled = ($Info.HttpStatus -eq 429) -or (& $HasCode 'TooManyRequests') -or (& $HasCode 'ThrottledRequest')

    if (-not $Info.IsPayloadTooLarge -and -not $Info.IsThrottled)
    {
        $Permanent4xx = ($Info.HttpStatus -ge 400 -and $Info.HttpStatus -lt 500 -and $Info.HttpStatus -ne 408 -and $Info.HttpStatus -ne 429)
        $PermanentCode = (& $HasCode 'AuthorizationFailed') -or (& $HasCode 'Forbidden') -or (& $HasCode 'InvalidQuery') -or
        (& $HasCode 'SemanticError') -or (& $HasCode 'SyntaxError') -or (& $HasCode 'ParserFailure') -or
        (& $HasCode 'BadRequest') -or (& $HasCode 'InvalidAuthenticationToken')
        $Info.IsPermanent = ($Permanent4xx -or $PermanentCode)
    }

    if (-not $Info.HasStructuredBody -and $Info.HttpStatus -eq 0)
    {
        $Text = $Info.Message
        if ($Text -match 'ResponsePayloadTooLarge|Response payload size is \d+, exceeded the limit') { $Info.IsPayloadTooLarge = $true }
        elseif ($Text -match 'TooManyRequests|\b429\b|throttl') { $Info.IsThrottled = $true }
        elseif ($Text -match 'the value of argument "name" is not valid|property whose name is an empty string')
        {
            $Info.IsEmptyPropertyName = $true
        }
        elseif ($Text -match 'AuthorizationFailed|does not have authorization|\bForbidden\b|\bBadRequest\b|SemanticError|SyntaxError|InvalidQuery|Please provide a valid') { $Info.IsPermanent = $true }
    }

    return $Info
}

$Script:RdaEmptyPropertyNameSentinel = '_rda_emptykey'

function Get-AzGraphRowsViaRest
{
    param(
        [Parameter(Mandatory = $true)][string]$Query,
        [string[]]$Subscription,
        [int]$First = 1000,
        [int]$Skip = 0
    )

    $Body = @{
        query   = $Query
        options = @{
            '$top'  = $First
            '$skip' = $Skip
        }
    }
    if ($Subscription) { $Body['subscriptions'] = @($Subscription) }

    $Payload = $Body | ConvertTo-Json -Depth 10
    $Response = Invoke-AzRestMethod -Method POST `
        -Path '/providers/Microsoft.ResourceGraph/resources?api-version=2021-03-01' `
        -Payload $Payload -ErrorAction Stop

    $Status = [int]$Response.StatusCode
    if ($Status -lt 200 -or $Status -ge 300)
    {
        $Detail = [string]$Response.Content
        if ($Detail.Length -gt 500) { $Detail = $Detail.Substring(0, 500) + '...(truncated)' }
        throw ("Resource Graph REST fallback returned HTTP {0}: {1}" -f $Status, $Detail)
    }

    $Sanitized = [regex]::Replace(
        $Response.Content,
        '(?<=[{,]\s*)""(?=\s*:)',
        ('"' + $Script:RdaEmptyPropertyNameSentinel + '"'))

    $Parsed = $Sanitized | ConvertFrom-Json
    if ($null -ne $Parsed -and $Parsed.PSObject.Properties.Name -contains 'data')
    {
        return @($Parsed.data)
    }
    return @()
}

function Invoke-AzGraphRequest
{
    param(
        [Parameter(Mandatory = $true)][string]$Query,
        [string[]]$Subscription,
        [int]$First = 1000,
        [int]$Skip = 0
    )

    $GraphParams = @{ Query = $Query; First = $First; ErrorAction = 'Stop' }
    if ($Subscription) { $GraphParams['Subscription'] = $Subscription }
    if ($Skip -gt 0) { $GraphParams['Skip'] = $Skip }

    $GraphMaxRetries = 30
    $Rows = $null
    $FailureMessage = $null
    $Failure = $null
    $AttemptsMade = 0

    for ($Attempt = 0; ; $Attempt++)
    {
        $AttemptsMade = $Attempt + 1
        try
        {
            $Response = Search-AzGraph @GraphParams
            $Rows = if ($null -eq $Response) { @() } else { @($Response) }
            $FailureMessage = $null
            $Failure = $null
            break
        }
        catch
        {
            $ErrorInfo = Get-AzGraphErrorInfo -Exception $_.Exception
            $Message = $ErrorInfo.Message
            $CodeText = if ($ErrorInfo.Codes.Count -gt 0) { ' [' + ($ErrorInfo.Codes -join ', ') + ']' } else { '' }

            if ($ErrorInfo.IsPayloadTooLarge)
            {
                $Failure = $ErrorInfo
                break
            }

            if ($ErrorInfo.IsEmptyPropertyName)
            {
                try
                {
                    $Rows = @(Get-AzGraphRowsViaRest -Query $Query -Subscription $Subscription -First $First -Skip $Skip)
                    $FailureMessage = $null
                    $Failure = $null
                    Write-Log -Message ("Recovered {0} row(s) at offset {1} via the raw Resource Graph REST path after an empty-property-name materialization error; empty JSON keys were renamed to '{2}'. The resource(s) were captured, not dropped." -f $Rows.Count, $Skip, $Script:RdaEmptyPropertyNameSentinel) -Severity 'Warning'
                    break
                }
                catch
                {
                    $RestInfo = Get-AzGraphErrorInfo -Exception $_.Exception
                    $Failure = $RestInfo
                    $FailureMessage = ("Resource Graph empty-property-name recovery via REST failed at offset {0}: {1}`nQuery: {2}" -f $Skip, $RestInfo.Message, $Query)
                    break
                }
            }

            if ($ErrorInfo.IsPermanent -or $Attempt -ge $GraphMaxRetries)
            {
                $Failure = $ErrorInfo
                $FailureMessage = ("Resource Graph query failed after {0} attempt(s): {1}{2}`nQuery: {3}" -f $AttemptsMade, $Message, $CodeText, $Query)
                break
            }

            $Throttled = $ErrorInfo.IsThrottled
            $Backoff = [math]::Min([math]::Pow(2, $Attempt), 30)
            if ($Throttled) { $Backoff = [math]::Min($Backoff * 2, 60) }
            $Backoff = Get-RetryWaitSeconds -Exception $_.Exception -FallbackSeconds $Backoff -MaxSeconds 120
            $Jitter = (Get-Random -Minimum 0 -Maximum 1000) / 1000.0
            Start-Sleep -Seconds ([math]::Round($Backoff + $Jitter, 2))
        }
    }

    return [pscustomobject]@{
        Rows           = $Rows
        Failure        = $Failure
        FailureMessage = $FailureMessage
        Attempts       = $AttemptsMade
    }
}

function Get-AzGraphRowWindow
{
    param(
        [Parameter(Mandatory = $true)][string]$Query,
        [string[]]$Subscription,
        [int]$First = 1000,
        [int]$Skip = 0
    )

    $Pending = New-Object System.Collections.Stack
    $Pending.Push([pscustomobject]@{ Skip = $Skip; First = $First })
    $Rows = @()
    $SplitCount = 0

    $FatalMessage = $null

    while ($Pending.Count -gt 0)
    {
        $Window = $Pending.Pop()
        $Result = Invoke-AzGraphRequest -Query $Query -Subscription $Subscription -First $Window.First -Skip $Window.Skip

        if ($null -eq $Result.Failure)
        {
            $Rows += @($Result.Rows)
            continue
        }

        $Message = $Result.Failure.Message

        if (-not $Result.Failure.IsPayloadTooLarge)
        {
            $FatalMessage = $Result.FailureMessage
            break
        }

        if ($Query -notmatch 'order\s+by')
        {
            $FatalMessage = ("Resource Graph refused the response as too large and the query is not ordered, so it cannot be split safely. Add an 'order by' clause to page it.`n{0}`nQuery: {1}" -f $Message, $Query)
            break
        }

        if ($Window.First -le 1)
        {
            $FatalMessage = ("Resource Graph refused a SINGLE resource as too large (offset {0}); it exceeds the 16 MB response cap and cannot be retrieved. Exclude this resource type from the discovery query to complete the run.`n{1}" -f $Window.Skip, $Message)
            break
        }

        $LeftCount = [math]::Floor($Window.First / 2)
        $RightCount = $Window.First - $LeftCount
        $Pending.Push([pscustomobject]@{ Skip = ($Window.Skip + $LeftCount); First = $RightCount })
        $Pending.Push([pscustomobject]@{ Skip = $Window.Skip; First = $LeftCount })
        $SplitCount++
        Write-Log -Message ("Resource Graph response too large at offset {0} for {1} rows; retrying as {2} + {3}." -f $Window.Skip, $Window.First, $LeftCount, $RightCount) -Severity 'Warning'
    }

    if ($null -ne $FatalMessage) { throw $FatalMessage }

    if ($SplitCount -gt 0)
    {
        Write-Log -Message ("Fetched offset {0}..{1} in smaller sub-pages after {2} split(s); {3} row(s) collected. This subscription holds at least one unusually large resource type." -f $Skip, ($Skip + $First - 1), $SplitCount, $Rows.Count) -Severity 'Warning'
    }

    return $Rows
}

function Invoke-AzGraphQuerySafe
{
    param(
        [Parameter(Mandatory = $true)][string]$Query,
        [string[]]$Subscription,
        [int]$First = 1000,
        [int]$Skip = 0,
        [switch]$Lowercase
    )

    $Rows = @(Get-AzGraphRowWindow -Query $Query -Subscription $Subscription -First $First -Skip $Skip)

    if ($Lowercase -and $Rows.Count -gt 0)
    {
        $Json = ($Rows | ConvertTo-Json -Depth 100).ToLowerInvariant()
        $Json = [regex]::Replace($Json, '(?<=[{,]\s*)""(?=\s*:)', ('"' + $Script:RdaEmptyPropertyNameSentinel + '"'))
        $Rows = @($Json | ConvertFrom-Json)
    }

    return [pscustomobject]@{ data = $Rows }
}

function Write-RdaShareableDiagnosticsLog
{
    param(
        [string]$DefaultPath,
        [string]$ReportName,
        [string]$RunDateTime,
        [string]$Version,
        $PhaseTimings,
        [int]$ConsumptionRecordCount = 0,
        [bool]$ConsumptionRequested = $true,
        [int]$MarketplaceRecordCount = 0,
        [bool]$MarketplaceRequested = $true,
        [int]$MetricsApiCallCount = 0,
        [bool]$MetricsRequested = $true,
        [switch]$Obfuscated
    )

    try
    {
        $DiagScrubMap = @{}
        if ($null -ne $Global:ResourceIdDictionary)
        {
            foreach ($realId in $Global:ResourceIdDictionary.Keys)
            {
                if ([string]::IsNullOrEmpty($realId)) { continue }
                if (-not $DiagScrubMap.ContainsKey($realId)) { $DiagScrubMap[$realId] = $Global:ResourceIdDictionary[$realId] }

                $ShortName = ($realId -split '/')[-1]
                if (-not [string]::IsNullOrEmpty($ShortName) -and $null -ne $Global:ResourceNameDictionary -and $Global:ResourceNameDictionary.ContainsKey($realId) -and -not $DiagScrubMap.ContainsKey($ShortName))
                {
                    $DiagScrubMap[$ShortName] = $Global:ResourceNameDictionary[$realId]
                }
                if ($realId -match '(?i)/resourceGroups/([^/]+)')
                {
                    $RgName = $Matches[1]
                    if (-not [string]::IsNullOrEmpty($RgName) -and $null -ne $Global:ResourceResourceGroupDictionary -and $Global:ResourceResourceGroupDictionary.ContainsKey($realId) -and -not $DiagScrubMap.ContainsKey($RgName))
                    {
                        $DiagScrubMap[$RgName] = $Global:ResourceResourceGroupDictionary[$realId]
                    }
                }
                if ($realId -match '(?i)/subscriptions/([^/]+)')
                {
                    $SubGuid = $Matches[1]
                    if (-not [string]::IsNullOrEmpty($SubGuid) -and $null -ne $Global:ResourceSubscriptionDictionary -and $Global:ResourceSubscriptionDictionary.ContainsKey($realId) -and -not $DiagScrubMap.ContainsKey($SubGuid))
                    {
                        $DiagScrubMap[$SubGuid] = $Global:ResourceSubscriptionDictionary[$realId]
                    }
                }
            }
        }
        if ($null -ne $Global:TagValueDictionary)
        {
            foreach ($tagReal in $Global:TagValueDictionary.Keys) { if (-not [string]::IsNullOrEmpty($tagReal) -and -not $DiagScrubMap.ContainsKey($tagReal)) { $DiagScrubMap[$tagReal] = $Global:TagValueDictionary[$tagReal] } }
        }
        if ($null -ne $Global:FreeTextDictionary)
        {
            foreach ($ftReal in $Global:FreeTextDictionary.Keys) { if (-not [string]::IsNullOrEmpty($ftReal) -and -not $DiagScrubMap.ContainsKey($ftReal)) { $DiagScrubMap[$ftReal] = $Global:FreeTextDictionary[$ftReal] } }
        }

        $PhaseTimingsText = [ordered]@{}
        if ($null -ne $PhaseTimings)
        {
            foreach ($PhaseName in $PhaseTimings.Keys)
            {
                $PhaseTotalSec = [int][math]::Round(([TimeSpan]$PhaseTimings[$PhaseName]).TotalSeconds)
                $PhaseTimingsText[$PhaseName] = ('{0}min {1:D2} sec' -f [int][math]::Floor($PhaseTotalSec / 60), ($PhaseTotalSec % 60))
            }
        }

        $CollectorFails = @(@($Global:CollectorFailures) | Where-Object { $null -ne $_ })
        $MetricsSkips = @(@($Global:MetricsFailedSubs) | Where-Object { $null -ne $_ })
        $ConsumpSkips = @(@($Global:ConsumptionFailedSubs) | Where-Object { $null -ne $_ })
        $MarketplaceSkips = @(@($Global:MarketplaceFailedSubs) | Where-Object { $null -ne $_ })

        $DiagLines = [System.Collections.Generic.List[string]]::new()
        if ($Obfuscated)
        {
            $DiagLines.Add('Resource Discovery for Azure - shareable diagnostics (obfuscated run)')
            $DiagLines.Add('Safe to share: identifiers are obfuscated/masked. Human-readable')
            $DiagLines.Add('troubleshooting log - NOT report data, do not ingest into tables.')
        }
        else
        {
            $DiagLines.Add('Resource Discovery for Azure - diagnostics (default/non-obfuscated run)')
            $DiagLines.Add('NOTE: this bundle is NOT obfuscated - the report itself contains real')
            $DiagLines.Add('identifiers. This log masks GUIDs/emails but treat the whole bundle as')
            $DiagLines.Add('sensitive. Human-readable troubleshooting log - NOT report data, do not')
            $DiagLines.Add('ingest into tables.')
        }
        $DiagLines.Add(('Generated (UTC) : {0}' -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [cultureinfo]::InvariantCulture)))
        $DiagLines.Add(('Tool version    : {0}' -f [string]$Version))
        $DiagLines.Add('')
        $DiagLines.Add('Phase timings:')
        if ($PhaseTimingsText.Count -gt 0)
        {
            foreach ($PhaseName in $PhaseTimingsText.Keys) { $DiagLines.Add(('  {0}: {1}' -f $PhaseName, $PhaseTimingsText[$PhaseName])) }
        }
        else
        {
            $DiagLines.Add('  (none recorded)')
        }
        $DiagLines.Add('')
        $DiagLines.Add(('Collector failures: {0}' -f $CollectorFails.Count))
        foreach ($cfItem in $CollectorFails)
        {
            $DiagLines.Add(('  [sub {0}] {1}: {2}' -f (Protect-DiagnosticText ([string]$cfItem.Id) $DiagScrubMap), [string]$cfItem.Module, (Protect-DiagnosticText ([string]$cfItem.Message) $DiagScrubMap)))
        }
        $DiagLines.Add('')
        $DiagLines.Add(('Metrics auth-skipped subscriptions: {0}' -f $MetricsSkips.Count))
        foreach ($msItem in $MetricsSkips)
        {
            $DiagLines.Add(('  [sub {0}] {1}' -f (Protect-DiagnosticText ([string]$msItem.Id) $DiagScrubMap), (Protect-DiagnosticText ([string]$msItem.Message) $DiagScrubMap)))
        }
        $DiagLines.Add('')
        $DiagLines.Add(('Consumption failed/incomplete subscriptions: {0}' -f $ConsumpSkips.Count))
        foreach ($csItem in $ConsumpSkips)
        {
            $DiagLines.Add(('  [sub {0}] {1}' -f (Protect-DiagnosticText ([string]$csItem.Id) $DiagScrubMap), (Protect-DiagnosticText ([string]$csItem.Message) $DiagScrubMap)))
        }

        $DiagLines.Add('')
        if ($ConsumptionRequested -or $ConsumptionRecordCount -ne 0)
        {
            $DiagLines.Add(('Consumption records collected: {0}' -f $ConsumptionRecordCount.ToString('N0', [cultureinfo]::InvariantCulture)))
        }
        else
        {
            $DiagLines.Add('Consumption records collected: n/a (-SkipConsumption was passed)')
        }

        if ($ConsumptionRequested -and $ConsumptionRecordCount -eq 0 -and $ConsumpSkips.Count -eq 0)
        {
            # LIMITATION (accepted): $ConsumpSkips reads $Global:ConsumptionFailedSubs,
            # which is run-CUMULATIVE, not per-subscription, under the wrapper - the
            # inner ResourceInventory.ps1 nil-initializes it once and '+=' per
            # subscription within the same process (only Run-AllSubscriptions.Stream.ps1
            # resets it, per stream). So in a multi-sub run one earlier subscription's
            # billing failure suppresses this zero-records warning for every LATER
            # subscription, even where those rows were genuinely all excluded by scope.
            # This is bounded: the fetched/written counts and the full failure list are
            # still printed above, so the operator is not left without the reason.
            # Scoping the guard to the current subscription would require threading a
            # current-subscription id parameter into this function - out of scope for
            # this diagnostics writer, and the sibling guard at the 'records collected'
            # line already behaves this way.
            $DiagLines.Add('  WARNING - consumption was requested but ZERO usage records were collected,')
            $DiagLines.Add('  and no subscription reported a billing error. The billing API answered')
            $DiagLines.Add('  successfully with no rows, so the Consumption CSV holds only its header.')
            $DiagLines.Add('  Expected ONLY if there is genuinely no usage in the queried window (the 30')
            $DiagLines.Add('  days ending at midnight yesterday, host local time). Otherwise the usual causes are:')
            $DiagLines.Add('    - CSP / Partner-managed subscription with the partner cost visibility')
            $DiagLines.Add('      policy OFF (the default). Billing scope on CSP subscriptions is not')
            $DiagLines.Add('      governed by Azure RBAC, so granting Cost Management Reader does not')
            $DiagLines.Add('      help - the partner must enable it in Partner Center.')
            $DiagLines.Add('    - Subscription not transitioned to the Azure plan.')
            $DiagLines.Add('    - A subscription offer the legacy usage API does not serve.')
        }

        $DiagLines.Add('')
        $DiagLines.Add(('Marketplace failed/incomplete subscriptions: {0}' -f $MarketplaceSkips.Count))
        foreach ($mkItem in $MarketplaceSkips)
        {
            $DiagLines.Add(('  [sub {0}] {1}' -f (Protect-DiagnosticText ([string]$mkItem.Id) $DiagScrubMap), (Protect-DiagnosticText ([string]$mkItem.Message) $DiagScrubMap)))
        }
        $DiagLines.Add('')
        if ($MarketplaceRequested -or ($MarketplaceRecordCount -ne 0))
        {
            $DiagLines.Add(('Marketplace consumption records collected: {0}' -f $MarketplaceRecordCount.ToString('N0', [cultureinfo]::InvariantCulture)))
        }
        else
        {
            $DiagLines.Add('Marketplace consumption records collected: n/a (-SkipMarketplace or -SkipConsumption was passed)')
        }

        if ($MarketplaceRequested -and $MarketplaceRecordCount -eq 0 -and $MarketplaceSkips.Count -eq 0)
        {
            # HONEST NEGATIVE (mirrors the consumption zero-records note above). The
            # Microsoft.Consumption/marketplaces endpoint returns ONLY Marketplace-publisher
            # rows, so a successful call with zero rows is a CONFIRMED absence of Azure
            # Marketplace / third-party SaaS charges (e.g. an Anthropic/Claude Marketplace
            # offer) in the window - not a missing or failed section. The Marketplace CSV
            # holds only its header in that case.
            $DiagLines.Add('  Note: ZERO Marketplace rows is a CONFIRMED zero (endpoint reached, no third-party/Marketplace charges billed), not a skipped section.')
        }

        $DiagLines.Add('')
        if ($MetricsRequested -or ($MetricsApiCallCount -ne 0))
        {
            $DiagLines.Add(('Metric-query API calls issued: {0}' -f $MetricsApiCallCount.ToString('N0', [cultureinfo]::InvariantCulture)))
        }
        else
        {
            $DiagLines.Add('Metric-query API calls issued: n/a (-SkipMetrics was passed)')
        }

        $DiagnosticsFile = ($DefaultPath + "Diagnostics_" + $ReportName + "_" + $RunDateTime + ".log")
        ($DiagLines -join [Environment]::NewLine) | Out-File -LiteralPath $DiagnosticsFile -Encoding utf8
        Write-Log -Message ('Shareable diagnostics log written: {0}' -f (Split-Path -Path $DiagnosticsFile -Leaf)) -Severity 'Info'
        return $DiagnosticsFile
    }
    catch
    {
        Write-Log -Message ('Could not build/write shareable diagnostics log: {0}' -f $_.Exception.Message) -Severity 'Warning'
        return $null
    }
}

function Get-RdaRetryAfterSeconds
{
    param(
        [Parameter(Mandatory = $true)]$ErrorRecord
    )

    $HeaderNames = @('x-ms-ratelimit-microsoft.consumption-retry-after', 'Retry-After')

    try
    {
        $Ex = if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { $ErrorRecord.Exception } else { $ErrorRecord }
        $Depth = 0
        while ($null -ne $Ex -and $Depth -lt 5)
        {
            $Headers = $null
            $ResponseProp = $Ex.PSObject.Properties['Response']
            if ($ResponseProp -and $null -ne $ResponseProp.Value)
            {
                $HeadersProp = $ResponseProp.Value.PSObject.Properties['Headers']
                if ($HeadersProp) { $Headers = $HeadersProp.Value }
            }

            if ($null -ne $Headers -and $Headers.Keys)
            {
                foreach ($Name in $HeaderNames)
                {
                    $Raw = $null
                    foreach ($Key in $Headers.Keys)
                    {
                        if ($Key -and $Key.Equals($Name, [System.StringComparison]::OrdinalIgnoreCase))
                        {
                            $Raw = @($Headers[$Key])[0]
                            break
                        }
                    }
                    if ([string]::IsNullOrWhiteSpace($Raw)) { continue }

                    $Raw = ([string]$Raw).Trim()

                    $Seconds = 0
                    if ([int]::TryParse($Raw, [ref]$Seconds))
                    {
                        if ($Seconds -lt 0) { $Seconds = 0 }
                        return $Seconds
                    }

                    $When = [datetimeoffset]::MinValue
                    if ([datetimeoffset]::TryParse($Raw, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$When))
                    {
                        $Delta = [int][math]::Ceiling(($When - [datetimeoffset]::UtcNow).TotalSeconds)
                        if ($Delta -lt 0) { $Delta = 0 }
                        return $Delta
                    }
                }
            }

            $Ex = $Ex.InnerException
            $Depth++
        }
    }
    catch
    {
    }

    return 0
}

