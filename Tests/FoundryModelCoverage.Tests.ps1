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
            'ProbeWindowStart', 'ProbeWindowEnd', 'RunTimestampUtc', 'TokenProbeStatus'
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

Describe 'Get-RdaFoundryCoverageTokenFields: token columns come from the token phase, and a failure never reads as a zero' {
    BeforeAll {
        # One account record in the shape GetFoundryTokenConsumption keeps for the coverage phase.
        function script:New-TokenAccountResult
        {
            param([hashtable]$Metrics = @{}, [hashtable]$Totals = @{}, [bool]$NoDeployments = $false)
            @{ NoDeployments = $NoDeployments; Metrics = $Metrics; Totals = $Totals }
        }
        $script:AllCollected = @{ InputTokens = 'Collected'; OutputTokens = 'Collected'; TotalTokens = 'Collected' }
    }

    # "$()" turns a numeric 0 into '0', so a blank column cannot pass as a zero or the reverse.
    It 'says NotRun, with blank columns, when the token phase did not run' {
        $R = Get-RdaFoundryCoverageTokenFields -TokenPhaseState 'NotRun' -AccountResult (script:New-TokenAccountResult -Metrics $script:AllCollected) -DeploymentName 'phi4-prod'
        $R.TokenProbeStatus | Should -Be 'NotRun'
        $R.TokenMetricsPresent | Should -BeFalse
        foreach ($Column in 'InputTokens', 'OutputTokens', 'TotalTokens') { "$($R.$Column)" | Should -Be '' }
    }

    It 'says Failed when the token phase could not authenticate' {
        (Get-RdaFoundryCoverageTokenFields -TokenPhaseState 'Failed' -DeploymentName 'phi4-prod').TokenProbeStatus | Should -Be 'Failed'
    }

    It 'says Failed for an account the token phase never reached because its subscription failed there, and NotRun otherwise' {
        (Get-RdaFoundryCoverageTokenFields -TokenPhaseState 'Ran' -AccountResult $null -SubscriptionFailed $true -DeploymentName 'phi4-prod').TokenProbeStatus | Should -Be 'Failed'
        (Get-RdaFoundryCoverageTokenFields -TokenPhaseState 'Ran' -AccountResult $null -SubscriptionFailed $false -DeploymentName 'phi4-prod').TokenProbeStatus | Should -Be 'NotRun'
    }

    It 'says Collected with the deployment totals, and a real 0 for a deployment with no data points' {
        $Account = script:New-TokenAccountResult -Metrics $script:AllCollected -Totals @{ 'phi4-prod' = @{ InputTokens = 30.0; OutputTokens = 7.0; TotalTokens = 37.0 } }

        $Used = Get-RdaFoundryCoverageTokenFields -TokenPhaseState 'Ran' -AccountResult $Account -DeploymentName 'phi4-prod'
        $Used.TokenProbeStatus | Should -Be 'Collected'
        $Used.TokenMetricsPresent | Should -BeTrue
        "$($Used.InputTokens)" | Should -Be '30'
        "$($Used.OutputTokens)" | Should -Be '7'
        "$($Used.TotalTokens)" | Should -Be '37'

        $Idle = Get-RdaFoundryCoverageTokenFields -TokenPhaseState 'Ran' -AccountResult $Account -DeploymentName 'mini-prod'
        $Idle.TokenProbeStatus | Should -Be 'Collected'
        foreach ($Column in 'InputTokens', 'OutputTokens', 'TotalTokens') { "$($Idle.$Column)" | Should -Be '0' }
    }

    It 'matches deployment names case-insensitively, as the token phase itself does' {
        $Account = script:New-TokenAccountResult -Metrics $script:AllCollected -Totals @{ 'Phi4-Prod' = @{ InputTokens = 5.0 } }
        "$((Get-RdaFoundryCoverageTokenFields -TokenPhaseState 'Ran' -AccountResult $Account -DeploymentName 'phi4-prod').InputTokens)" | Should -Be '5'
    }

    It 'leaves a metric the account does not support blank and still says Collected' {
        $Account = script:New-TokenAccountResult -Metrics @{ InputTokens = 'Collected'; OutputTokens = 'Collected'; TotalTokens = 'NotSupported' } -Totals @{ 'phi4-prod' = @{ InputTokens = 30.0; OutputTokens = 7.0 } }
        $R = Get-RdaFoundryCoverageTokenFields -TokenPhaseState 'Ran' -AccountResult $Account -DeploymentName 'phi4-prod'
        $R.TokenProbeStatus | Should -Be 'Collected'
        "$($R.InputTokens)" | Should -Be '30'
        "$($R.TotalTokens)" | Should -Be ''
    }

    It 'says Partial when some metrics were read and others failed, blanking only the failed ones' {
        # OutputTokens ran out of retries, and the account failed before TotalTokens was queried.
        $Account = script:New-TokenAccountResult -Metrics @{ InputTokens = 'Collected'; OutputTokens = 'Failed' } -Totals @{ 'phi4-prod' = @{ InputTokens = 30.0 } }
        $R = Get-RdaFoundryCoverageTokenFields -TokenPhaseState 'Ran' -AccountResult $Account -DeploymentName 'phi4-prod'
        $R.TokenProbeStatus | Should -Be 'Partial'
        $R.TokenMetricsPresent | Should -BeTrue
        "$($R.InputTokens)" | Should -Be '30'
        "$($R.OutputTokens)" | Should -Be ''
        "$($R.TotalTokens)" | Should -Be ''
    }

    It 'says Failed, with blank columns, when every token metric was denied' {
        $Account = script:New-TokenAccountResult -Metrics @{ InputTokens = 'Denied'; OutputTokens = 'Denied'; TotalTokens = 'Denied' }
        $R = Get-RdaFoundryCoverageTokenFields -TokenPhaseState 'Ran' -AccountResult $Account -DeploymentName 'phi4-prod'
        $R.TokenProbeStatus | Should -Be 'Failed'
        $R.TokenMetricsPresent | Should -BeFalse
        foreach ($Column in 'InputTokens', 'OutputTokens', 'TotalTokens') { "$($R.$Column)" | Should -Be '' }
    }

    It 'says NoTokenMetrics when the account supports none of the token metrics' {
        $Account = script:New-TokenAccountResult -Metrics @{ InputTokens = 'NotSupported'; OutputTokens = 'NotSupported'; TotalTokens = 'NotSupported' }
        $R = Get-RdaFoundryCoverageTokenFields -TokenPhaseState 'Ran' -AccountResult $Account -DeploymentName 'phi4-prod'
        $R.TokenProbeStatus | Should -Be 'NoTokenMetrics'
        $R.TokenMetricsPresent | Should -BeFalse
    }

    It 'says Failed for an account whose deployments the token phase could not list' {
        (Get-RdaFoundryCoverageTokenFields -TokenPhaseState 'Ran' -AccountResult (script:New-TokenAccountResult) -DeploymentName 'phi4-prod').TokenProbeStatus | Should -Be 'Failed'
    }

    It 'says NotRun when the token phase found no deployments on the account' {
        (Get-RdaFoundryCoverageTokenFields -TokenPhaseState 'Ran' -AccountResult (script:New-TokenAccountResult -NoDeployments $true) -DeploymentName 'phi4-prod').TokenProbeStatus | Should -Be 'NotRun'
    }
}

Describe 'GetFoundryModelCoverage source: the TokenProbeStatus column and no Azure Monitor calls of its own' {
    BeforeAll {
        $InvAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Repo 'ResourceInventory.ps1'), [ref]$null, [ref]$null)
        $script:CoverageFn = $InvAst.Find({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq 'GetFoundryModelCoverage' }, $true)
        if (-not $script:CoverageFn) { throw 'GetFoundryModelCoverage was not found in ResourceInventory.ps1.' }

        # The header-only fallback the finalization writes when the phase produced no rows.
        $HeaderAst = @($InvAst.FindAll({ param($N) $N -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $N.Value.StartsWith('SubscriptionGuid,SubscriptionName,ResourceGroup,AccountName,AccountKind,') }, $true))
        if ($HeaderAst.Count -ne 1) { throw ('expected one coverage header literal, found {0}' -f $HeaderAst.Count) }
        $script:HeaderColumns = @($HeaderAst[0].Value -split ',')

        # The projection the phase writes its rows with.
        $Projection = @($script:CoverageFn.FindAll({ param($N) $N -is [System.Management.Automation.Language.CommandAst] -and $N.GetCommandName() -eq 'Select-Object' -and $N.Parent.Extent.Text -match 'FoundryCoverageFileCsv' }, $true))
        if ($Projection.Count -ne 1) { throw ('expected one coverage Select-Object projection, found {0}' -f $Projection.Count) }
        $script:ProjectionColumns = @($Projection[0].CommandElements[1].Elements | ForEach-Object { $_.Value })

        # The columns up to RunTimestampUtc, in order, as they were before TokenProbeStatus existed.
        $script:ExistingColumns = @(
            'SubscriptionGuid', 'SubscriptionName', 'ResourceGroup', 'AccountName', 'AccountKind',
            'DeploymentName', 'ModelName', 'ModelFormat', 'ModelVersion', 'DeploymentSku',
            'DeploymentCapacity', 'Region', 'DetectedPlanes', 'CoverageStatus', 'CoverageFlag',
            'RetailPriceMatch', 'MarketplacePublisher', 'MarketplaceOffer', 'CcuQuantity',
            'CcuUnitOfMeasure', 'MarketplacePretaxCost', 'MarketplaceCurrency', 'CcuAttribution',
            'TokenMetricsPresent', 'InputTokens', 'OutputTokens', 'TotalTokens',
            'ProbeWindowStart', 'ProbeWindowEnd', 'RunTimestampUtc'
        )
    }

    It 'appends TokenProbeStatus after the existing columns, in the same order in the row, the projection and the empty-file header' {
        $Record = script:New-FakeModel
        $Row = ConvertTo-RdaFoundryCoverageRow -Record $Record -Obfuscate:$false
        $RowColumns = @($Row.PSObject.Properties.Name)
        $Expected = @($script:ExistingColumns + 'TokenProbeStatus') -join ','

        ($RowColumns -join ',') | Should -Be $Expected
        ($script:ProjectionColumns -join ',') | Should -Be $Expected
        ($script:HeaderColumns -join ',') | Should -Be $Expected
    }

    It 'sets TokenProbeStatus on every coverage record it builds' {
        $Records = @($script:CoverageFn.FindAll({ param($N) $N -is [System.Management.Automation.Language.HashtableAst] -and @($N.KeyValuePairs | ForEach-Object { $_.Item1.Extent.Text }) -contains 'RunTimestampUtc' }, $true))
        $Records.Count | Should -Be 3 -Because 'a deployment row, a deployments-not-listed row and an unattributed Marketplace row'
        foreach ($R in $Records)
        {
            @($R.KeyValuePairs | ForEach-Object { $_.Item1.Extent.Text }) | Should -Contain 'TokenProbeStatus'
        }
    }

    It 'reads the token phase results instead of querying Azure Monitor itself' {
        $Commands = @($script:CoverageFn.FindAll({ param($N) $N -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() })
        foreach ($Name in 'Get-AzMetric', 'Get-AzMetricDefinition', 'Invoke-RdaFoundryTokenMetricQuery')
        {
            $Commands | Should -Not -Contain $Name
        }
        $Commands | Should -Contain 'Get-RdaFoundryCoverageTokenFields'
        Get-Command Get-RdaFoundryTokenMetrics -ErrorAction SilentlyContinue | Should -BeNullOrEmpty -Because 'the separate coverage token probe is gone'
    }
}

Describe 'Foundry token phase feeding the coverage CSV (the real collector bodies, offline)' {
    BeforeAll {
        . (Join-Path $script:Repo 'Functions/Common.Functions.ps1')

        # Define the real collector functions from their source, not a re-implementation.
        $InvAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Repo 'ResourceInventory.ps1'), [ref]$null, [ref]$null)
        foreach ($FnName in 'GetFoundryTokenConsumption', 'Invoke-RdaFoundryTokenMetricQuery', 'GetFoundryModelCoverage')
        {
            $Fn = $InvAst.Find({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq $FnName }, $true)
            if (-not $Fn) { throw ('{0} was not found in ResourceInventory.ps1.' -f $FnName) }
            . ([scriptblock]::Create($Fn.Extent.Text))
        }

        # Stubs so Mock can resolve the commands on a host without the Az modules.
        # Defined only when absent, never shadowing a real cmdlet.
        if (-not (Get-Command Get-AzCognitiveServicesAccount -ErrorAction SilentlyContinue))
        {
            function Get-AzCognitiveServicesAccount { [CmdletBinding()] param() throw 'stub - should be mocked' }
        }
        if (-not (Get-Command Get-AzCognitiveServicesAccountDeployment -ErrorAction SilentlyContinue))
        {
            function Get-AzCognitiveServicesAccountDeployment { [CmdletBinding()] param([string]$ResourceGroupName, [string]$AccountName) throw 'stub - should be mocked' }
        }
        if (-not (Get-Command Get-AzMetric -ErrorAction SilentlyContinue))
        {
            function Get-AzMetric
            {
                [CmdletBinding()]
                param([string]$ResourceId, [string[]]$MetricName, [string]$AggregationType, [datetime]$StartTime, [datetime]$EndTime, [string]$MetricFilter, [Nullable[int]]$Top)
                throw 'stub - should be mocked'
            }
        }
        if (-not (Get-Command Get-AzConsumptionMarketplace -ErrorAction SilentlyContinue))
        {
            function Get-AzConsumptionMarketplace { [CmdletBinding()] param([datetime]$StartDate, [datetime]$EndDate) throw 'stub - should be mocked' }
        }
        if (-not (Get-Command Invoke-AzRestMethod -ErrorAction SilentlyContinue))
        {
            function Invoke-AzRestMethod { [CmdletBinding()] param([string]$Method, [string]$Path) throw 'stub - should be mocked' }
        }
        if (-not (Get-Command Set-AzContext -ErrorAction SilentlyContinue))
        {
            function Set-AzContext { [CmdletBinding()] param([string]$Subscription) throw 'stub - should be mocked' }
        }
        if (-not (Get-Command Get-AzContext -ErrorAction SilentlyContinue))
        {
            function Get-AzContext { [CmdletBinding()] param() throw 'stub - should be mocked' }
        }
        # A nested function of ResourceInventory.ps1, so it has no definition in this scope.
        function Test-DataPlaneAuthReady { [CmdletBinding()] param([string]$Phase) throw 'stub - should be mocked' }

        $script:E2ESubId = [guid]::NewGuid().ToString()
        $script:AcctAId = '/subscriptions/{0}/resourceGroups/rg-ai/providers/Microsoft.CognitiveServices/accounts/acct-a' -f $script:E2ESubId
        $script:AcctBId = '/subscriptions/{0}/resourceGroups/rg-ai/providers/Microsoft.CognitiveServices/accounts/acct-b' -f $script:E2ESubId

        function script:New-FakeDeployment([string]$Name, [string]$Model)
        {
            [pscustomobject]@{ Name = $Name; Properties = [pscustomobject]@{ Model = [pscustomobject]@{ Name = $Model; Format = 'Microsoft'; Version = '1' } } }
        }
        function script:New-FakeSeriesResult([hashtable]$PointsByDeployment)
        {
            [pscustomobject]@{
                Timeseries = @($PointsByDeployment.Keys | ForEach-Object {
                        [pscustomobject]@{
                            Metadatavalues = @([pscustomobject]@{ Name = [pscustomobject]@{ Value = 'ModelDeploymentName' }; Value = $_ })
                            Data           = @($PointsByDeployment[$_] | ForEach-Object { [pscustomobject]@{ Total = $_ } })
                        }
                    })
            }
        }
        function script:New-FakeArmDeployments([string[]]$Names)
        {
            $Value = @($Names | ForEach-Object { [pscustomobject]@{ name = $_; sku = [pscustomobject]@{ name = 'GlobalStandard'; capacity = 1 }; properties = [pscustomobject]@{ model = [pscustomobject]@{ name = 'Phi-4'; format = 'Microsoft'; version = '1' } } } })
            [pscustomobject]@{ StatusCode = 200; Content = ([pscustomobject]@{ value = $Value } | ConvertTo-Json -Depth 6) }
        }

        # Token phase: acct-a has usage on one of its two deployments and does not support
        # TotalTokens; every metric on acct-b is denied.
        Mock Write-Log { }
        Mock Test-DataPlaneAuthReady { $true }
        Mock Set-AzContext { }
        Mock Get-AzContext { [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = $script:E2ESubId } } }
        Mock Get-AzCognitiveServicesAccount {
            @(
                [pscustomobject]@{ Id = $script:AcctAId; AccountName = 'acct-a'; ResourceGroupName = 'rg-ai'; Location = 'eastus' }
                [pscustomobject]@{ Id = $script:AcctBId; AccountName = 'acct-b'; ResourceGroupName = 'rg-ai'; Location = 'eastus' }
            )
        }
        Mock Get-AzCognitiveServicesAccountDeployment { @((script:New-FakeDeployment 'phi4-prod' 'Phi-4'), (script:New-FakeDeployment 'mini-prod' 'Phi-4-mini')) } -ParameterFilter { $AccountName -eq 'acct-a' }
        Mock Get-AzCognitiveServicesAccountDeployment { @(script:New-FakeDeployment 'gpt-prod' 'gpt-4o') } -ParameterFilter { $AccountName -eq 'acct-b' }
        Mock Get-AzMetric { [pscustomobject]@{ Timeseries = @() } }
        Mock Get-AzMetric { script:New-FakeSeriesResult @{ 'phi4-prod' = @(10, 20) } } -ParameterFilter { $ResourceId -eq $script:AcctAId -and $MetricName -eq 'InputTokens' }
        Mock Get-AzMetric { script:New-FakeSeriesResult @{ 'phi4-prod' = @(3, 4) } } -ParameterFilter { $ResourceId -eq $script:AcctAId -and $MetricName -eq 'OutputTokens' }
        Mock Get-AzMetric { throw "Operation returned an invalid status code 'BadRequest'" } -ParameterFilter { $ResourceId -eq $script:AcctAId -and $MetricName -eq 'TotalTokens' }
        Mock Get-AzMetric { throw "The client 'x' does not have authorization to perform action 'Microsoft.Insights/metrics/read'. AuthorizationFailed" } -ParameterFilter { $ResourceId -eq $script:AcctBId }

        # Coverage phase: Resource Graph returns the same accounts with the lower-case id form it
        # commonly uses, so the lookup into the token results has to ignore case.
        Mock Get-RdaFoundryRetailCatalog { @() }
        Mock Get-AzConsumptionMarketplace { @() }
        Mock Invoke-AzGraphQuerySafe {
            $Accounts = @(
                [pscustomobject]@{ id = $script:AcctAId.ToLowerInvariant(); name = 'acct-a'; kind = 'AIServices'; sku = 'S0'; location = 'eastus'; resourceGroup = 'rg-ai'; subscriptionId = $script:E2ESubId }
                [pscustomobject]@{ id = $script:AcctBId.ToLowerInvariant(); name = 'acct-b'; kind = 'AIServices'; sku = 'S0'; location = 'eastus'; resourceGroup = 'rg-ai'; subscriptionId = $script:E2ESubId }
            )
            [pscustomobject]@{ data = $Accounts }
        }
        Mock Invoke-AzRestMethod { script:New-FakeArmDeployments @('phi4-prod', 'mini-prod') } -ParameterFilter { $Path -like '*/acct-a/deployments*' }
        Mock Invoke-AzRestMethod { script:New-FakeArmDeployments @('gpt-prod') } -ParameterFilter { $Path -like '*/acct-b/deployments*' }

        # Runs the phases the way ExecuteInventoryProcessing does: the token phase first, then
        # coverage. The inputs they read from their caller's scope arrive as parameters.
        $script:RunFoundryPhases = [scriptblock]::Create(@'
param($SubscriptionID, $Obfuscate, [bool]$WithTokenPhase)
$script:FoundryTokenResults = $null
$script:FoundryTokenFailedSubIds = $null
$script:FoundryTokenPhaseState = $null
if ($WithTokenPhase) { GetFoundryTokenConsumption }
GetFoundryModelCoverage
'@)

        $script:PriorGlobals = @{}
        foreach ($Name in 'Subscriptions', 'ConsumptionFileCsv', 'FoundryCoverageFileCsv', 'ResourceIdDictionary', 'FoundryTokenRecordCount', 'FoundryTokenFailedSubs', 'FoundryCoverageRecordCount', 'FoundryCoverageFailedSubs', 'FoundryCoverageUnpricedCount')
        {
            $script:PriorGlobals[$Name] = Get-Variable -Scope Global -Name $Name -ValueOnly -ErrorAction SilentlyContinue
        }
        $Global:Subscriptions = @([pscustomobject]@{ Id = $script:E2ESubId; Name = 'Foundry test subscription' })
        $Global:ResourceIdDictionary = @{}
    }

    AfterAll {
        foreach ($Name in $script:PriorGlobals.Keys)
        {
            Set-Variable -Scope Global -Name $Name -Value $script:PriorGlobals[$Name]
        }
    }

    BeforeEach {
        $Stamp = [guid]::NewGuid().ToString('N')
        $Global:ConsumptionFileCsv = Join-Path ([System.IO.Path]::GetTempPath()) ('Consumption_{0}.csv' -f $Stamp)
        $Global:FoundryCoverageFileCsv = Join-Path ([System.IO.Path]::GetTempPath()) ('FoundryModelCoverage_{0}.csv' -f $Stamp)
        foreach ($Name in 'FoundryTokenRecordCount', 'FoundryTokenFailedSubs', 'FoundryCoverageRecordCount', 'FoundryCoverageFailedSubs', 'FoundryCoverageUnpricedCount')
        {
            Set-Variable -Scope Global -Name $Name -Value $null
        }
    }

    AfterEach {
        foreach ($Path in $Global:ConsumptionFileCsv, $Global:FoundryCoverageFileCsv)
        {
            if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
        }
    }

    It 'fills each deployment row from the token phase, marking a denied account Failed rather than zero, with no extra metric calls' {
        & $script:RunFoundryPhases -SubscriptionID $script:E2ESubId -Obfuscate ([pscustomobject]@{ IsPresent = $false }) -WithTokenPhase $true

        $Rows = @(Import-Csv -LiteralPath $Global:FoundryCoverageFileCsv)
        $Rows.Count | Should -Be 3
        $ByDeployment = @{}
        foreach ($Row in $Rows) { $ByDeployment[$Row.DeploymentName] = $Row }

        $ByDeployment['phi4-prod'].TokenProbeStatus | Should -Be 'Collected'
        $ByDeployment['phi4-prod'].TokenMetricsPresent | Should -Be 'True'
        $ByDeployment['phi4-prod'].InputTokens | Should -Be '30'
        $ByDeployment['phi4-prod'].OutputTokens | Should -Be '7'
        $ByDeployment['phi4-prod'].TotalTokens | Should -Be '' -Because 'the account does not support TotalTokens'

        $ByDeployment['mini-prod'].TokenProbeStatus | Should -Be 'Collected'
        $ByDeployment['mini-prod'].InputTokens | Should -Be '0' -Because 'the query succeeded and returned no data for this deployment'

        $ByDeployment['gpt-prod'].TokenProbeStatus | Should -Be 'Failed'
        $ByDeployment['gpt-prod'].TokenMetricsPresent | Should -Be 'False'
        $ByDeployment['gpt-prod'].InputTokens | Should -Be '' -Because 'a denied query is not a zero'

        # 8 token metrics per account, one call each (denied and unsupported are not retried),
        # all from the token phase: coverage adds none.
        Should -Invoke Get-AzMetric -Times 16 -Exactly
    }

    It 'says NotRun on every deployment row, once in the log, and makes no metric calls when the token phase did not run' {
        & $script:RunFoundryPhases -SubscriptionID $script:E2ESubId -Obfuscate ([pscustomobject]@{ IsPresent = $false }) -WithTokenPhase $false

        $Rows = @(Import-Csv -LiteralPath $Global:FoundryCoverageFileCsv)
        $Rows.Count | Should -Be 3
        foreach ($Row in $Rows)
        {
            $Row.TokenProbeStatus | Should -Be 'NotRun'
            $Row.TokenMetricsPresent | Should -Be 'False'
            $Row.InputTokens | Should -Be ''
        }
        Should -Invoke Get-AzMetric -Times 0 -Exactly
        Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Message -match 'TokenProbeStatus NotRun' }
    }
}

Describe 'Invoke-RdaFoundryTokenMetricQuery: series cap and outcome reporting' {
    BeforeAll {
        . (Join-Path $script:Repo 'Functions/Common.Functions.ps1')
        $InvAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Repo 'ResourceInventory.ps1'), [ref]$null, [ref]$null)
        $Fn = $InvAst.Find({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq 'Invoke-RdaFoundryTokenMetricQuery' }, $true)
        if (-not $Fn) { throw 'Invoke-RdaFoundryTokenMetricQuery was not found in ResourceInventory.ps1.' }
        . ([scriptblock]::Create($Fn.Extent.Text))

        if (-not (Get-Command Get-AzMetric -ErrorAction SilentlyContinue))
        {
            function Get-AzMetric
            {
                [CmdletBinding()]
                param([string]$ResourceId, [string[]]$MetricName, [string]$AggregationType, [datetime]$StartTime, [datetime]$EndTime, [string]$MetricFilter, [Nullable[int]]$Top)
                throw 'stub - should be mocked'
            }
        }

        $script:QueryArgs = @{
            AccountResourceId = '/subscriptions/{0}/resourceGroups/rg-ai/providers/Microsoft.CognitiveServices/accounts/acct-a' -f [guid]::NewGuid()
            MetricName        = 'InputTokens'
            StartTime         = (Get-Date).AddDays(-31).Date
            EndTime           = (Get-Date).AddDays(-1).Date
        }
    }

    BeforeEach {
        Mock Write-Log { }
        Mock Get-AzMetric { [pscustomobject]@{ Timeseries = @() } }
    }

    It 'asks for one series per deployment above the default cap of 10, and sends no -Top at or below it' {
        $null = Invoke-RdaFoundryTokenMetricQuery @script:QueryArgs -Top 12
        Should -Invoke Get-AzMetric -Times 1 -Exactly -ParameterFilter { $Top -eq 12 }

        $null = Invoke-RdaFoundryTokenMetricQuery @script:QueryArgs -Top 10
        $null = Invoke-RdaFoundryTokenMetricQuery @script:QueryArgs
        Should -Invoke Get-AzMetric -Times 2 -Exactly -ParameterFilter { $null -eq $Top }
    }

    It 'reports Collected, Denied and NotSupported to the caller' {
        $Outcome = @{}
        $null = Invoke-RdaFoundryTokenMetricQuery @script:QueryArgs -Outcome $Outcome
        $Outcome['Status'] | Should -Be 'Collected'

        Mock Get-AzMetric { throw "The client 'x' does not have authorization to perform action 'Microsoft.Insights/metrics/read'. AuthorizationFailed" }
        $Outcome = @{}
        Invoke-RdaFoundryTokenMetricQuery @script:QueryArgs -Outcome $Outcome | Should -BeNullOrEmpty
        $Outcome['Status'] | Should -Be 'Denied'

        Mock Get-AzMetric { throw "Operation returned an invalid status code 'BadRequest'" }
        $Outcome = @{}
        Invoke-RdaFoundryTokenMetricQuery @script:QueryArgs -Outcome $Outcome | Should -BeNullOrEmpty
        $Outcome['Status'] | Should -Be 'NotSupported'
    }
}
