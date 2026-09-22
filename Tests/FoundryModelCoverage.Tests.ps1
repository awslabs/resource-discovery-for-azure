#Requires -Version 7.0
<#
    FoundryModelCoverage.Tests.ps1

    Behavioral tests for the ADDITIVE Azure AI Foundry model billing-plane coverage
    collector - the pure classification/branch helpers and the row-mapping/obfuscation
    helper in Functions/ResourceInventory.Functions.ps1:
      - Get-RdaFoundryModelMatchTokens
      - Test-RdaRetailPriceMatch        (Azure-metered plane, PER-MODEL not per-vendor)
      - Test-RdaMarketplaceModelMatch   (Marketplace/CCU plane, offer-level aggregation)
      - Get-RdaFoundryCoverageStatus    (the core branch/flag decision + UNPRICED invariant)
      - ConvertTo-RdaFoundryCoverageRow (flat CSV row + obfuscation routing)

    WHY MOCKED. No live Claude / partner Marketplace deployment is available (the only
    test subscription is MSDN, which cannot purchase Marketplace offers), so these tests
    mock the two data sources - deployed-model rows shaped like the ARM /deployments
    value[] entries, and Marketplace rows shaped like PSMarketplace - and assert the
    REAL classification/branch code path. This mirrors Tests/MarketplaceCollector.Tests.ps1.

    DOC/IMPL VERIFICATION ANCHOR (see the design spec, verified live):
      - Retail Prices API: serviceName eq 'Foundry Models'; Claude/Anthropic return 0 rows
        (Marketplace-only), Cohere/Llama/Mistral are PARTIAL - proving per-model matching.
      - ARM deployments list: GET {accountId}/deployments?api-version=2024-10-01 is the
        source of truth; d.properties.model.{name,format,version}, d.sku.{name,capacity}.
      - CCU billing: Claude bills 100% via Azure Marketplace CCU, a single aggregated line.

    Fully offline. No Azure calls.
#>

BeforeAll {
    $script:Repo = Split-Path $PSScriptRoot -Parent
    $script:FunctionsPath = Join-Path $script:Repo 'Functions/ResourceInventory.Functions.ps1'
    . $script:FunctionsPath

    # A deployed-model record shaped the way GetFoundryModelCoverage builds $Model from an
    # ARM /deployments value[] entry joined with its account. Property names match what the
    # classification helpers and ConvertTo-RdaFoundryCoverageRow consume.
    function script:New-FakeModel
    {
        param(
            [string]$ModelName = 'gpt-4o',
            [string]$ModelFormat = 'OpenAI',
            [string]$ModelVersion = '2024-08-06',
            [string]$DeploymentName = 'gpt4o-prod',
            [string]$AccountName = 'aiservices-prod',
            [string]$AccountId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-ai-prod/providers/Microsoft.CognitiveServices/accounts/aiservices-prod',
            [string]$ResourceGroup = 'rg-ai-prod',
            [string]$SubscriptionGuid = '11111111-1111-1111-1111-111111111111',
            [string]$SubscriptionName = 'AI Production'
        )
        [pscustomobject]@{
            SubscriptionGuid   = $SubscriptionGuid
            SubscriptionName   = $SubscriptionName
            ResourceGroup      = $ResourceGroup
            AccountName        = $AccountName
            AccountId          = $AccountId
            AccountKind        = 'AIServices'
            DeploymentName     = $DeploymentName
            ModelName          = $ModelName
            ModelFormat        = $ModelFormat
            ModelVersion       = $ModelVersion
            DeploymentSku      = 'GlobalStandard'
            DeploymentCapacity = '50'
            Region             = 'eastus'
        }
    }

    # A Retail Prices catalog item shaped like a prices.azure.com Items[] entry.
    function script:New-FakeRetailItem
    {
        param(
            [string]$ProductName = 'Azure OpenAI GPT4o',
            [string]$MeterName = 'gpt 4o Input Global 1M Tokens',
            [string]$SkuName = 'Standard',
            [string]$ArmSkuName = ''
        )
        [pscustomobject]@{
            serviceName = 'Foundry Models'
            productName = $ProductName
            meterName   = $MeterName
            skuName     = $SkuName
            armSkuName  = $ArmSkuName
        }
    }

    # A Marketplace/CCU row shaped like PSMarketplace (see MarketplaceCollector.Tests.ps1).
    function script:New-FakeMarketplaceRow
    {
        param(
            [string]$Publisher = 'anthropic',
            [string]$Offer = 'claude-in-foundry',
            [string]$Plan = 'pay-as-you-go',
            [string]$InstanceId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-ai-prod/providers/Microsoft.SaaS/resources/claude-saas-01',
            [string]$ResourceGroup = 'rg-ai-prod',
            [double]$Quantity = 8734.0,
            [string]$Unit = 'CCU',
            [double]$Cost = 87.34
        )
        [pscustomobject]@{
            PublisherName    = $Publisher
            OfferName        = $Offer
            PlanName         = $Plan
            OrderNumber      = 'ORD-4242'
            ConsumedService  = 'Microsoft.SaaS'
            ConsumedQuantity = $Quantity
            UnitOfMeasure    = $Unit
            PretaxCost       = $Cost
            Currency         = 'USD'
            IsEstimated      = $false
            MeterId          = 'mtr-ccu-01'
            InstanceId       = $InstanceId
            InstanceName     = 'claude-saas-01'
            ResourceGroup    = $ResourceGroup
            SubscriptionGuid = '11111111-1111-1111-1111-111111111111'
            SubscriptionName = 'AI Production'
        }
    }
}

Describe 'Test-RdaRetailPriceMatch: per-model (not per-vendor) Azure-metered detection' {

    It 'confidently matches an OpenAI model to its OpenAI Retail Prices meter' {
        $Model = script:New-FakeModel -ModelName 'gpt-4o' -ModelFormat 'OpenAI'
        $Catalog = @(script:New-FakeRetailItem -ProductName 'Azure OpenAI GPT4o' -MeterName 'gpt 4o Input Global 1M Tokens')
        $Res = Test-RdaRetailPriceMatch -Model $Model -CatalogItems $Catalog
        $Res.Matched | Should -BeTrue
        $Res.RetailMatch | Should -Match 'GPT4o'
    }

    It 'returns NO match for Claude even when the catalog is non-empty (Marketplace-only)' {
        $Model = script:New-FakeModel -ModelName 'claude-opus-4' -ModelFormat 'Anthropic'
        $Catalog = @(
            script:New-FakeRetailItem -ProductName 'Azure OpenAI GPT4o' -MeterName 'gpt 4o 1M Tokens'
            script:New-FakeRetailItem -ProductName 'Cohere Models' -MeterName 'embed v3 1M Tokens'
        )
        $Res = Test-RdaRetailPriceMatch -Model $Model -CatalogItems $Catalog
        $Res.Matched | Should -BeFalse
        $Res.RetailMatch | Should -Be '(no confident Retail Prices match)'
    }

    It 'does NOT mark a Marketplace-only SKU covered just because the vendor is partially present' {
        # The partly-invisible trap (the design spec section 4.2): a Cohere meter EXISTS for embed v3, but
        # a DIFFERENT Cohere SKU (a made-up rerank v9) is absent. A vendor-level check would
        # wrongly call it covered; the per-model matcher must not.
        $Present = script:New-FakeModel -ModelName 'embed-v3' -ModelFormat 'Cohere' -DeploymentName 'cohere-embed'
        $Absent = script:New-FakeModel -ModelName 'rerank-v9-ultra' -ModelFormat 'Cohere' -DeploymentName 'cohere-rerank'
        $Catalog = @(script:New-FakeRetailItem -ProductName 'Cohere Models' -MeterName 'embed v3 Global 1M Tokens')

        (Test-RdaRetailPriceMatch -Model $Present -CatalogItems $Catalog).Matched | Should -BeTrue
        (Test-RdaRetailPriceMatch -Model $Absent -CatalogItems $Catalog).Matched | Should -BeFalse
    }

    It 'returns NO match against an empty/absent catalog (does not throw)' {
        $Model = script:New-FakeModel
        (Test-RdaRetailPriceMatch -Model $Model -CatalogItems @()).Matched | Should -BeFalse
        (Test-RdaRetailPriceMatch -Model $Model -CatalogItems $null).Matched | Should -BeFalse
    }
}

Describe 'Test-RdaMarketplaceModelMatch: Marketplace/CCU plane detection + attribution' {

    It 'matches a Claude model to an Anthropic/Claude Marketplace offer' {
        $Model = script:New-FakeModel -ModelName 'claude-opus-4' -ModelFormat 'Anthropic'
        $Rows = @(script:New-FakeMarketplaceRow -Publisher 'anthropic' -Offer 'claude-in-foundry')
        $Res = Test-RdaMarketplaceModelMatch -Model $Model -MarketplaceRows $Rows
        $Res.Matched | Should -BeTrue
        $Res.Row.PublisherName | Should -Be 'anthropic'
    }

    It 'ties the CCU line to the deployment (PerModel) when the row references the account resource group' {
        $Model = script:New-FakeModel -ModelName 'claude-opus-4' -ModelFormat 'Anthropic' -ResourceGroup 'rg-ai-prod'
        $Rows = @(script:New-FakeMarketplaceRow -Publisher 'anthropic' -Offer 'claude-in-foundry' -ResourceGroup 'rg-ai-prod' -InstanceId '/subscriptions/x/resourceGroups/rg-ai-prod/providers/Microsoft.SaaS/resources/claude-saas-01')
        $Res = Test-RdaMarketplaceModelMatch -Model $Model -MarketplaceRows $Rows
        $Res.Matched | Should -BeTrue
        $Res.CcuAttribution | Should -Be 'PerModel'
    }

    It 'falls back to AggregatedOffer when the CCU line cannot be tied to the deployment' {
        $Model = script:New-FakeModel -ModelName 'claude-opus-4' -ModelFormat 'Anthropic' -ResourceGroup 'rg-ai-prod'
        $Rows = @(script:New-FakeMarketplaceRow -Publisher 'anthropic' -Offer 'claude-in-foundry' -ResourceGroup 'rg-somewhere-else' -InstanceId '/subscriptions/x/resourceGroups/rg-somewhere-else/providers/Microsoft.SaaS/resources/other')
        $Res = Test-RdaMarketplaceModelMatch -Model $Model -MarketplaceRows $Rows
        $Res.Matched | Should -BeTrue
        $Res.CcuAttribution | Should -Be 'AggregatedOffer'
    }

    It 'does NOT match an OpenAI model to an Anthropic Marketplace offer' {
        $Model = script:New-FakeModel -ModelName 'gpt-4o' -ModelFormat 'OpenAI'
        $Rows = @(script:New-FakeMarketplaceRow -Publisher 'anthropic' -Offer 'claude-in-foundry')
        (Test-RdaMarketplaceModelMatch -Model $Model -MarketplaceRows $Rows).Matched | Should -BeFalse
    }

    It 'returns NO match against empty/absent Marketplace rows (does not throw)' {
        $Model = script:New-FakeModel
        (Test-RdaMarketplaceModelMatch -Model $Model -MarketplaceRows @()).Matched | Should -BeFalse
        (Test-RdaMarketplaceModelMatch -Model $Model -MarketplaceRows $null).Matched | Should -BeFalse
    }
}

Describe 'Get-RdaFoundryCoverageStatus: the core branch/flag decision + UNPRICED invariant' {

    It 'classifies an Azure-metered model as AzureMetered (server team prices via Retail Prices)' {
        $C = Get-RdaFoundryCoverageStatus -AzureMetered $true -MarketplaceCovered $false
        $C.CoverageStatus | Should -Be 'AzureMetered'
        $C.CoverageFlag | Should -Match 'Retail Prices'
    }

    It 'classifies a Claude-style model as MarketplaceOnly with the explicit CCU flag' {
        $C = Get-RdaFoundryCoverageStatus -AzureMetered $false -MarketplaceCovered $true
        $C.CoverageStatus | Should -Be 'MarketplaceOnly'
        $C.CoverageFlag | Should -Be 'Marketplace-billed, absent from Retail Prices - priced via CCU path.'
    }

    It 'classifies a model on BOTH planes as AzureMetered+Marketplace' {
        (Get-RdaFoundryCoverageStatus -AzureMetered $true -MarketplaceCovered $true).CoverageStatus |
            Should -Be 'AzureMetered+Marketplace'
    }

    It 'emits UNPRICED ONLY when BOTH planes were probed and BOTH came back negative' {
        $C = Get-RdaFoundryCoverageStatus -AzureMetered $false -MarketplaceCovered $false -RetailProbed $true -MarketplaceProbed $true
        $C.CoverageStatus | Should -Be 'UNPRICED'
        $C.CoverageFlag | Should -Match 'COVERAGE GAP'
    }

    It 'does NOT emit UNPRICED when the Marketplace plane was denied (Unknown-MarketplaceDenied)' {
        $C = Get-RdaFoundryCoverageStatus -AzureMetered $false -MarketplaceCovered $false -RetailProbed $true -MarketplaceProbed $false -MarketplaceDeniedReason 'MarketplaceDenied'
        $C.CoverageStatus | Should -Be 'Unknown-MarketplaceDenied'
        $C.CoverageStatus | Should -Not -Be 'UNPRICED'
    }

    It 'does NOT emit UNPRICED when the Retail Prices catalog could not be read' {
        $C = Get-RdaFoundryCoverageStatus -AzureMetered $false -MarketplaceCovered $false -RetailProbed $false -MarketplaceProbed $true
        $C.CoverageStatus | Should -Be 'Unknown-RetailCatalogUnavailable'
        $C.CoverageStatus | Should -Not -Be 'UNPRICED'
    }
}

Describe 'ConvertTo-RdaFoundryCoverageRow: column contract + obfuscation routing' {

    It 'emits exactly the documented column set (no extra, no missing)' {
        $Record = script:New-FakeModel
        $Record | Add-Member -NotePropertyName DetectedPlanes -NotePropertyValue 'AzureMetered' -Force
        $Record | Add-Member -NotePropertyName CoverageStatus -NotePropertyValue 'AzureMetered' -Force
        $Record | Add-Member -NotePropertyName CoverageFlag -NotePropertyValue 'x' -Force
        $Record | Add-Member -NotePropertyName RetailPriceMatch -NotePropertyValue 'y' -Force
        foreach ($p in 'MarketplacePublisher', 'MarketplaceOffer', 'CcuQuantity', 'CcuUnitOfMeasure', 'MarketplacePretaxCost', 'MarketplaceCurrency', 'CcuAttribution', 'TokenMetricsPresent', 'InputTokens', 'OutputTokens', 'TotalTokens', 'ProbeWindowStart', 'ProbeWindowEnd', 'RunTimestampUtc')
        {
            $Record | Add-Member -NotePropertyName $p -NotePropertyValue '' -Force
        }
        $Out = ConvertTo-RdaFoundryCoverageRow -Record $Record -Obfuscate:$false
        $Expected = @(
            'SubscriptionGuid', 'SubscriptionName', 'ResourceGroup', 'AccountName', 'AccountKind',
            'DeploymentName', 'ModelName', 'ModelFormat', 'ModelVersion', 'DeploymentSku',
            'DeploymentCapacity', 'Region', 'DetectedPlanes', 'CoverageStatus', 'CoverageFlag',
            'RetailPriceMatch', 'MarketplacePublisher', 'MarketplaceOffer', 'CcuQuantity',
            'CcuUnitOfMeasure', 'MarketplacePretaxCost', 'MarketplaceCurrency', 'CcuAttribution',
            'TokenMetricsPresent', 'InputTokens', 'OutputTokens', 'TotalTokens',
            'ProbeWindowStart', 'ProbeWindowEnd', 'RunTimestampUtc'
        ) | Sort-Object
        $Actual = @($Out.PSObject.Properties.Name) | Sort-Object
        ($Actual -join ',') | Should -Be ($Expected -join ',')
    }

    It 'leaves product/plane identity readable (ModelName/ModelFormat/CoverageStatus/MarketplacePublisher)' {
        $Record = script:New-FakeModel -ModelName 'claude-opus-4' -ModelFormat 'Anthropic'
        $Record | Add-Member -NotePropertyName DetectedPlanes -NotePropertyValue 'Marketplace' -Force
        $Record | Add-Member -NotePropertyName CoverageStatus -NotePropertyValue 'MarketplaceOnly' -Force
        $Record | Add-Member -NotePropertyName CoverageFlag -NotePropertyValue 'flag' -Force
        $Record | Add-Member -NotePropertyName RetailPriceMatch -NotePropertyValue 'none' -Force
        $Record | Add-Member -NotePropertyName MarketplacePublisher -NotePropertyValue 'anthropic' -Force
        foreach ($p in 'MarketplaceOffer', 'CcuQuantity', 'CcuUnitOfMeasure', 'MarketplacePretaxCost', 'MarketplaceCurrency', 'CcuAttribution', 'TokenMetricsPresent', 'InputTokens', 'OutputTokens', 'TotalTokens', 'ProbeWindowStart', 'ProbeWindowEnd', 'RunTimestampUtc')
        {
            $Record | Add-Member -NotePropertyName $p -NotePropertyValue '' -Force
        }
        $Out = ConvertTo-RdaFoundryCoverageRow -Record $Record -Obfuscate:$true -SubGuidTokenMap @{} -RgTokenMap @{}
        # Product/plane identity stays readable even under obfuscation.
        $Out.ModelName | Should -Be 'claude-opus-4'
        $Out.ModelFormat | Should -Be 'Anthropic'
        $Out.CoverageStatus | Should -Be 'MarketplaceOnly'
        $Out.MarketplacePublisher | Should -Be 'anthropic'
        $Out.AccountKind | Should -Be 'AIServices'
    }

    It 'masks identifying fields to the SAME shared tokens used elsewhere in the bundle' {
        $SharedSubToken = 'prod_sub_aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        $SharedRgToken = 'prod_rg_bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
        $SubGuidTokenMap = @{ '11111111-1111-1111-1111-111111111111' = $SharedSubToken }
        $RgTokenMap = @{ 'rg-ai-prod' = $SharedRgToken }

        $Record = script:New-FakeModel
        foreach ($p in 'DetectedPlanes', 'CoverageStatus', 'CoverageFlag', 'RetailPriceMatch', 'MarketplacePublisher', 'MarketplaceOffer', 'CcuQuantity', 'CcuUnitOfMeasure', 'MarketplacePretaxCost', 'MarketplaceCurrency', 'CcuAttribution', 'TokenMetricsPresent', 'InputTokens', 'OutputTokens', 'TotalTokens', 'ProbeWindowStart', 'ProbeWindowEnd', 'RunTimestampUtc')
        {
            $Record | Add-Member -NotePropertyName $p -NotePropertyValue '' -Force
        }

        $Out = ConvertTo-RdaFoundryCoverageRow -Record $Record -Obfuscate:$true -SubGuidTokenMap $SubGuidTokenMap -RgTokenMap $RgTokenMap

        # Both SubscriptionGuid and SubscriptionName resolve to the SAME shared sub token.
        $Out.SubscriptionGuid | Should -Be $SharedSubToken
        $Out.SubscriptionName | Should -Be $SharedSubToken
        $Out.ResourceGroup | Should -Be $SharedRgToken
        # Leaf names are masked (not left raw).
        $Out.AccountName | Should -Not -Be 'aiservices-prod'
        $Out.DeploymentName | Should -Not -Be 'gpt4o-prod'
        $Out.AccountName | Should -Match '^(prod|nonprod)_'
    }

    It 'mints deterministic local tokens when a sub/RG is absent from the shared maps' {
        $Record = script:New-FakeModel
        foreach ($p in 'DetectedPlanes', 'CoverageStatus', 'CoverageFlag', 'RetailPriceMatch', 'MarketplacePublisher', 'MarketplaceOffer', 'CcuQuantity', 'CcuUnitOfMeasure', 'MarketplacePretaxCost', 'MarketplaceCurrency', 'CcuAttribution', 'TokenMetricsPresent', 'InputTokens', 'OutputTokens', 'TotalTokens', 'ProbeWindowStart', 'ProbeWindowEnd', 'RunTimestampUtc')
        {
            $Record | Add-Member -NotePropertyName $p -NotePropertyValue '' -Force
        }
        $SubCache = @{}; $RgCache = @{}; $NameCache = @{}
        $A = ConvertTo-RdaFoundryCoverageRow -Record $Record -Obfuscate:$true -SubGuidTokenMap @{} -RgTokenMap @{} -SubCache $SubCache -RgCache $RgCache -NameCache $NameCache
        $B = ConvertTo-RdaFoundryCoverageRow -Record $Record -Obfuscate:$true -SubGuidTokenMap @{} -RgTokenMap @{} -SubCache $SubCache -RgCache $RgCache -NameCache $NameCache
        # Deterministic within a run: the same real value maps to the same token across rows.
        $A.SubscriptionGuid | Should -Be $B.SubscriptionGuid
        $A.AccountName | Should -Be $B.AccountName
        $A.SubscriptionGuid | Should -Not -Be '11111111-1111-1111-1111-111111111111'
    }
}
