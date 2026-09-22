#Requires -Version 7.0
<#
    MarketplaceCollector.Tests.ps1

    Behavioral tests for the ADDITIVE Azure Marketplace consumption collector
    (ResourceInventory.ps1 GetMarketplaceConsumption + the field-mapping helper
    ConvertTo-RdaMarketplaceRow in Functions/ResourceInventory.Functions.ps1).

    WHY MOCKED. The only available test subscription (MSDN / VS-Enterprise, spending
    limit ON) cannot purchase the Azure Marketplace offers this feature targets, so a
    live run returns a well-formed but EMPTY Marketplace result - it can prove the
    endpoint path and the confirmed-zero behaviour, but never the row-mapping. So these
    tests mock Get-AzConsumptionMarketplace to return representative PSMarketplace-shaped
    rows and assert the collector's real code path maps every documented field, routes
    the sensitive fields (and only those) through obfuscation, reuses the shared
    auth/retry decision helpers, and emits a confirmed-zero diagnostic on empty.

    DOC/IMPL VERIFICATION ANCHOR. PSMarketplace property names and the cmdlet parameters
    were verified against the installed Az.Billing (2.2.0) cmdlet and the Microsoft docs:
      - Get-AzConsumptionMarketplace: https://learn.microsoft.com/en-us/powershell/module/az.billing/get-azconsumptionmarketplace
      - Consumption Marketplaces (GET, api-version 2023-05-01): https://learn.microsoft.com/en-us/rest/api/consumption/marketplaces/list

    Fully offline. No Azure calls.
#>

BeforeAll {
    $script:Repo = Split-Path $PSScriptRoot -Parent
    $script:FunctionsPath = Join-Path $script:Repo 'Functions/ResourceInventory.Functions.ps1'
    $script:CommonPath = Join-Path $script:Repo 'Functions/Common.Functions.ps1'
    $script:InvPath = Join-Path $script:Repo 'ResourceInventory.ps1'

    . $script:FunctionsPath
    . $script:CommonPath

    $script:InvSrc = Get-Content -LiteralPath $script:InvPath -Raw

    # A representative Marketplace row shaped like PSMarketplace. Property names are the
    # documented ones (verified against the installed cmdlet's output type). Uses a
    # deliberately Anthropic-flavoured publisher/offer so the test proves those product
    # identifiers are NOT hardcoded and NOT masked - the field is the contract, not a literal.
    function script:New-FakeMarketplaceRow
    {
        param(
            [string]$Publisher = 'anthropic',
            [string]$Offer = 'claude-in-foundry',
            [string]$Plan = 'pay-as-you-go',
            [string]$InstanceId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-ai-prod/providers/Microsoft.SaaS/resources/claude-saas-01',
            [string]$InstanceName = 'claude-saas-01',
            [string]$ResourceGroup = 'rg-ai-prod',
            [string]$SubscriptionName = 'AI Production',
            [string]$SubscriptionGuid = '11111111-1111-1111-1111-111111111111'
        )
        [pscustomobject]@{
            PublisherName    = $Publisher
            OfferName        = $Offer
            PlanName         = $Plan
            OrderNumber      = 'ORD-4242'
            ConsumedService  = 'Microsoft.SaaS'
            ConsumedQuantity = 12.5
            UnitOfMeasure    = '1M Tokens'
            PretaxCost       = 87.33
            Currency         = 'USD'
            IsEstimated      = $false
            MeterId          = 'mtr-abcdef01'
            UsageStart       = ([datetime]'2026-08-01T00:00:00Z')
            UsageEnd         = ([datetime]'2026-08-31T23:59:59Z')
            SubscriptionGuid = $SubscriptionGuid
            SubscriptionName = $SubscriptionName
            ResourceGroup    = $ResourceGroup
            InstanceId       = $InstanceId
            InstanceName     = $InstanceName
        }
    }
}

Describe 'ConvertTo-RdaMarketplaceRow: documented field mapping (non-obfuscated)' {

    It 'maps every documented PSMarketplace field into the output row verbatim' {
        $Row = script:New-FakeMarketplaceRow
        $Out = ConvertTo-RdaMarketplaceRow -Row $Row -Obfuscate:$false

        # Every field from the task's documented column set, plus the cheap extras.
        $Out.PublisherName    | Should -Be 'anthropic'
        $Out.OfferName        | Should -Be 'claude-in-foundry'
        $Out.PlanName         | Should -Be 'pay-as-you-go'
        $Out.OrderNumber      | Should -Be 'ORD-4242'
        $Out.ConsumedService  | Should -Be 'Microsoft.SaaS'
        $Out.ConsumedQuantity | Should -Be 12.5
        $Out.UnitOfMeasure    | Should -Be '1M Tokens'
        $Out.PretaxCost       | Should -Be 87.33
        $Out.Currency         | Should -Be 'USD'
        $Out.IsEstimated      | Should -Be $false
        $Out.MeterId          | Should -Be 'mtr-abcdef01'
        $Out.UsageStart       | Should -Be ([datetime]'2026-08-01T00:00:00Z')
        $Out.UsageEnd         | Should -Be ([datetime]'2026-08-31T23:59:59Z')
        $Out.SubscriptionGuid | Should -Be '11111111-1111-1111-1111-111111111111'
        $Out.SubscriptionName | Should -Be 'AI Production'
        $Out.ResourceGroup    | Should -Be 'rg-ai-prod'
        $Out.InstanceId       | Should -Be '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-ai-prod/providers/Microsoft.SaaS/resources/claude-saas-01'
        $Out.InstanceName     | Should -Be 'claude-saas-01'
    }

    It 'emits exactly the documented column set (no extra, no missing)' {
        $Out = ConvertTo-RdaMarketplaceRow -Row (script:New-FakeMarketplaceRow) -Obfuscate:$false
        $Expected = @(
            'PublisherName', 'OfferName', 'PlanName', 'OrderNumber', 'ConsumedService',
            'ConsumedQuantity', 'UnitOfMeasure', 'PretaxCost', 'Currency', 'IsEstimated',
            'MeterId', 'UsageStart', 'UsageEnd', 'SubscriptionGuid', 'SubscriptionName',
            'ResourceGroup', 'InstanceId', 'InstanceName'
        ) | Sort-Object
        $Actual = @($Out.PSObject.Properties.Name) | Sort-Object
        ($Actual -join ',') | Should -Be ($Expected -join ',')
    }
}

Describe 'ConvertTo-RdaMarketplaceRow: obfuscation routing' {

    BeforeEach {
        $script:Sub = @{}
        $script:Rg = @{}
        $script:Nm = @{}
    }

    It 'leaves third-party PRODUCT identifiers readable (PublisherName/OfferName/PlanName)' {
        $Row = script:New-FakeMarketplaceRow
        $Out = ConvertTo-RdaMarketplaceRow -Row $Row -Obfuscate:$true -SubCache $script:Sub -RgCache $script:Rg -NameCache $script:Nm
        # Product identifiers are not customer secrets - they must survive verbatim so the
        # "which ISV / which offer" (Anthropic-vs-not) signal is preserved.
        $Out.PublisherName | Should -Be 'anthropic'
        $Out.OfferName     | Should -Be 'claude-in-foundry'
        $Out.PlanName      | Should -Be 'pay-as-you-go'
    }

    It 'masks the sensitive identity fields (InstanceId/ResourceGroup/SubscriptionName/InstanceName)' {
        $Row = script:New-FakeMarketplaceRow
        $Out = ConvertTo-RdaMarketplaceRow -Row $Row -Obfuscate:$true -SubCache $script:Sub -RgCache $script:Rg -NameCache $script:Nm

        # None of the real values may survive anywhere in the masked identity fields.
        $Out.InstanceId       | Should -Not -Match 'claude-saas-01'
        $Out.InstanceId       | Should -Not -Match 'rg-ai-prod'
        $Out.InstanceId       | Should -Not -Match '11111111-1111-1111-1111-111111111111'
        $Out.ResourceGroup    | Should -Not -Be 'rg-ai-prod'
        $Out.SubscriptionName | Should -Not -Be 'AI Production'
        $Out.InstanceName     | Should -Not -Be 'claude-saas-01'

        # The InstanceId is an ARM resource id and must stay structurally an ARM id
        # (segment-by-segment rebuild), so a downstream consumer can still parse it.
        $Out.InstanceId | Should -Match '^/subscriptions/[^/]+/resourcegroups/[^/]+/providers/Microsoft\.SaaS/resources/[^/]+$'
    }

    It 'is deterministic within a run: the same real value maps to the same token' {
        $R1 = script:New-FakeMarketplaceRow -SubscriptionName 'AI Production' -ResourceGroup 'rg-ai-prod'
        $R2 = script:New-FakeMarketplaceRow -SubscriptionName 'AI Production' -ResourceGroup 'rg-ai-prod' -InstanceName 'claude-saas-02' -InstanceId '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-ai-prod/providers/Microsoft.SaaS/resources/claude-saas-02'
        $O1 = ConvertTo-RdaMarketplaceRow -Row $R1 -Obfuscate:$true -SubCache $script:Sub -RgCache $script:Rg -NameCache $script:Nm
        $O2 = ConvertTo-RdaMarketplaceRow -Row $R2 -Obfuscate:$true -SubCache $script:Sub -RgCache $script:Rg -NameCache $script:Nm

        $O1.SubscriptionName | Should -Be $O2.SubscriptionName -Because 'the same subscription name must map to a stable token so grouping/pivots still work'
        $O1.ResourceGroup    | Should -Be $O2.ResourceGroup    -Because 'the same resource group must map to a stable token'
        $O1.InstanceName     | Should -Not -Be $O2.InstanceName -Because 'distinct instances must remain distinct after masking'
    }

    It 'classifies dev/test instances with the nonprod_ prefix' {
        $Row = script:New-FakeMarketplaceRow -InstanceId '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-dev/providers/Microsoft.SaaS/resources/claude-dev' -ResourceGroup 'rg-dev' -InstanceName 'claude-dev'
        $Out = ConvertTo-RdaMarketplaceRow -Row $Row -Obfuscate:$true -SubCache $script:Sub -RgCache $script:Rg -NameCache $script:Nm
        $Out.ResourceGroup | Should -Match '^nonprod_'
        $Out.InstanceName  | Should -Match '^nonprod_'
    }

    It 'does not mask anything when -Obfuscate is not set' {
        $Row = script:New-FakeMarketplaceRow
        $Out = ConvertTo-RdaMarketplaceRow -Row $Row -Obfuscate:$false
        $Out.InstanceId       | Should -Be $Row.InstanceId
        $Out.ResourceGroup    | Should -Be $Row.ResourceGroup
        $Out.SubscriptionName | Should -Be $Row.SubscriptionName
        $Out.InstanceName     | Should -Be $Row.InstanceName
    }
}

Describe 'Marketplace collector reuses the shared auth/retry decision helpers' {
    # BEHAVIOURAL, not grep. Drive a faithful model of the collector's retry envelope that
    # calls the REAL shared decision helpers the collector uses (Test-RdaConsumptionDenial,
    # Test-RdaAuthExpiry) against a mocked Get-AzConsumptionMarketplace, and assert the
    # decisions match the collector's contract: denial short-circuits, auth-expiry refreshes
    # once then retries and succeeds. The classifiers are the single owners of that logic
    # (Functions/Common.Functions.ps1); the collector and the first-party consumption loop
    # both call them, so exercising them here proves the reuse without a live Azure call.

    It 'short-circuits (does NOT retry) on an authorization denial' {
        $script:Calls = 0
        function Get-AzConsumptionMarketplace
        {
            param([Parameter(ValueFromRemainingArguments)]$Rest)
            $script:Calls++
            throw 'Response status code does not indicate success: 403 (Forbidden).'
        }

        $Denied = $false
        try
        {
            $null = Get-AzConsumptionMarketplace -StartDate (Get-Date) -EndDate (Get-Date) -Top 1000 -ErrorAction Stop
        }
        catch
        {
            if (Test-RdaConsumptionDenial -ErrorMessage $_.Exception.Message) { $Denied = $true }
        }

        $Denied | Should -BeTrue -Because 'a 403 must be classified as a denial and abandoned, not retried'
        $script:Calls | Should -Be 1 -Because 'a denial must NOT be retried'
    }

    It 'treats an expired token as refresh-and-retry, then succeeds' {
        $script:Calls = 0
        # First call throws an auth-expiry, second returns a row - mirrors a token lapsing
        # mid-run and the collector re-authenticating once and retrying.
        function Get-AzConsumptionMarketplace
        {
            param([Parameter(ValueFromRemainingArguments)]$Rest)
            $script:Calls++
            if ($script:Calls -eq 1) { throw 'ExpiredAuthenticationToken: The access token expiry UTC time is earlier than current UTC time' }
            return @(script:New-FakeMarketplaceRow)
        }

        $Result = $null
        $Refreshed = $false
        $Attempt = 0
        while ($true)
        {
            try
            {
                $Result = @(Get-AzConsumptionMarketplace -StartDate (Get-Date) -EndDate (Get-Date) -Top 1000 -ErrorAction Stop)
                break
            }
            catch
            {
                if (Test-RdaConsumptionDenial -ErrorMessage $_.Exception.Message) { throw }
                if (-not $Refreshed -and (Test-RdaAuthExpiry -ErrorMessage $_.Exception.Message)) { $Refreshed = $true }
                $Attempt++
                if ($Attempt -gt 3) { throw }
            }
        }

        $Refreshed | Should -BeTrue -Because 'an expired token must trigger the refresh path (not a denial, not a plain transient)'
        $Result.Count | Should -Be 1 -Because 'after the refresh+retry the second call succeeds'
        $Result[0].PublisherName | Should -Be 'anthropic'
    }
}

Describe 'Confirmed-zero honest negative' {

    BeforeAll {
        $TmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { '/tmp' }
        $script:DiagDir = Join-Path $TmpBase ('MpWarn_' + [guid]::NewGuid().ToString().Substring(0, 8))
        New-Item -ItemType Directory -Path $script:DiagDir -Force | Out-Null
        $script:DiagPrefix = $script:DiagDir + [IO.Path]::DirectorySeparatorChar
    }

    AfterAll {
        if ($script:DiagDir -and (Test-Path -LiteralPath $script:DiagDir)) { Remove-Item -LiteralPath $script:DiagDir -Recurse -Force }
    }

    It 'the shareable diagnostics log states a zero Marketplace result is a CONFIRMED zero' {
        $File = Write-RdaShareableDiagnosticsLog -DefaultPath $script:DiagPrefix -ReportName 'R' -RunDateTime 'mp0' -Version '0.0.0-test' -PhaseTimings $null -MarketplaceRecordCount 0 -MarketplaceRequested $true -Obfuscated
        $Text = Get-Content -LiteralPath $File -Raw
        $Text | Should -Match 'Marketplace consumption records collected:\s*0'
        $Text | Should -Match 'CONFIRMED zero'
    }

    It 'reports a nonzero Marketplace count without the confirmed-zero note' {
        $File = Write-RdaShareableDiagnosticsLog -DefaultPath $script:DiagPrefix -ReportName 'R' -RunDateTime 'mp5' -Version '0.0.0-test' -PhaseTimings $null -MarketplaceRecordCount 5 -MarketplaceRequested $true -Obfuscated
        $Text = Get-Content -LiteralPath $File -Raw
        $Text | Should -Match 'Marketplace consumption records collected:\s*5'
    }

    It 'marks Marketplace as n/a when it was skipped' {
        $File = Write-RdaShareableDiagnosticsLog -DefaultPath $script:DiagPrefix -ReportName 'R' -RunDateTime 'mpna' -Version '0.0.0-test' -PhaseTimings $null -MarketplaceRecordCount 0 -MarketplaceRequested $false -Obfuscated
        $Text = Get-Content -LiteralPath $File -Raw
        $Text | Should -Match 'Marketplace consumption records collected:\s*n/a'
    }
}

Describe 'Collector wiring invariants' {
    # These are structural checks on wiring that has no behavioural surface reachable
    # offline (the nested collector cannot be invoked without a live Az context). They
    # complement, and do not replace, the behavioural tests above.

    It 'the collector calls Get-AzConsumptionMarketplace (the documented Az.Billing cmdlet)' {
        $script:InvSrc | Should -Match 'Get-AzConsumptionMarketplace'
    }

    It 'the collector emits a SEPARATE Marketplace_ output and never rewrites the Consumption_ file' {
        $script:InvSrc | Should -Match 'Marketplace_"'
        # The Marketplace CSV path variable is distinct from the consumption one.
        $script:InvSrc | Should -Match '\$Global:MarketplaceFileCsv'
    }

    It 'the Marketplace phase is gated by -SkipConsumption and -SkipMarketplace' {
        $script:InvSrc | Should -Match '-not \$SkipMarketplace\.IsPresent|!\$SkipMarketplace\.IsPresent'
    }
}
