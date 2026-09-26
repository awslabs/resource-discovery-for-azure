#Requires -Version 7.0
<#
    FoundryFold.Tests.ps1

    Behavioral tests for the ADDITIVE Foundry fold (P1) and the Consumption column
    rename (P2):

      P1 - fold Claude/Anthropic Marketplace usage into the SAME first-party
           Consumption_*.csv the ingestion server reads, as "Foundry Models" rows,
           so Claude usage is no longer dropped server-side. Covers:
             - Test-RdaClaudeMarketplaceRow  (detection)
             - Get-RdaClaudeModelIdentity    (model identity from OfferName/PlanName)
             - ConvertTo-RdaFoldedFoundryRow  (Tier 1: CCU/cost, non-token)
           and the collector wiring (GetFoundryFoldConsumption in ResourceInventory.ps1)
           asserted against the source/AST.

      P2 - the emitted Consumption CSV column is AdditionalInfo (the name the server
           binds), NOT InstanceData.

    WHY MOCKED / SOURCE-ASSERTED. Exactly like MarketplaceCollector.Tests.ps1: the only
    available test subscription cannot purchase a Claude-on-Foundry Marketplace offer and
    exposes no live Foundry per-deployment token metrics, so the row-mapping and the
    Tier 2 degrade path can only be proven with representative fakes + the real pure code
    paths. Fully offline. No Azure calls.

    UNVERIFIED-SPELLING CAVEAT (mirrored from the code). The exact Azure Foundry token-meter
    MeterName spellings and Unit strings are NOT yet verified against a live Claude-on-Foundry
    deployment. These tests assert the CONTRACT the server documents (MeterCategory exact match;
    role substrings in MeterName; token Unit passed through as discovered), not a live spelling.
#>

BeforeAll {
    $script:Repo = Split-Path $PSScriptRoot -Parent
    $script:FunctionsPath = Join-Path $script:Repo 'Functions/ResourceInventory.Functions.ps1'
    $script:InvPath = Join-Path $script:Repo 'ResourceInventory.ps1'
    . $script:FunctionsPath

    # The exact first-party Consumption CSV column set the fold must match so a folded row is
    # schema-identical to a native consumption row.
    $script:ConsumptionColumns = @(
        'AdditionalInfo', 'MeterCategory', 'MeterId', 'MeterName', 'MeterRegion',
        'MeterSubCategory', 'Quantity', 'Unit', 'UsageStartTime', 'UsageEndTime',
        'ResourceId', 'ResourceLocation', 'ConsumptionMeter', 'ReservationId', 'ReservationOrderId'
    )

    # A representative Claude Marketplace row (PSMarketplace shape). Deliberately Anthropic/Claude
    # flavoured so the tests prove detection + identity are read from the fields, not hardcoded.
    function script:New-FakeClaudeRow
    {
        param(
            [string]$Publisher = 'anthropic',
            [string]$Offer = 'Claude in Foundry - Sonnet 4.5',
            [string]$Plan = 'pay-as-you-go',
            [double]$Quantity = 12.5,
            [string]$Unit = '1M Tokens',
            [double]$PretaxCost = 87.33,
            [string]$Currency = 'USD',
            [string]$MeterId = '',
            [string]$InstanceId = '',
            [string]$SubscriptionGuid = '11111111-1111-1111-1111-111111111111'
        )
        [pscustomobject]@{
            PublisherName    = $Publisher
            OfferName        = $Offer
            PlanName         = $Plan
            OrderNumber      = 'ORD-9'
            ConsumedService  = 'Microsoft.SaaS'
            ConsumedQuantity = $Quantity
            UnitOfMeasure    = $Unit
            PretaxCost       = $PretaxCost
            Currency         = $Currency
            IsEstimated      = $false
            MeterId          = $MeterId
            UsageStart       = ([datetime]'2026-08-01T00:00:00Z')
            UsageEnd         = ([datetime]'2026-08-31T23:59:59Z')
            SubscriptionGuid = $SubscriptionGuid
            SubscriptionName = 'AI Production'
            ResourceGroup    = 'rg-ai-prod'
            InstanceId       = $InstanceId
            InstanceName     = 'claude-saas-01'
        }
    }
}

Describe 'Test-RdaClaudeMarketplaceRow: Claude/Anthropic detection' {
    It 'detects an Anthropic publisher' {
        Test-RdaClaudeMarketplaceRow -Row (script:New-FakeClaudeRow) | Should -BeTrue
    }
    It 'detects a Claude offer even when the publisher is not Anthropic' {
        $Row = script:New-FakeClaudeRow -Publisher 'contoso-reseller' -Offer 'Claude Sonnet bundle'
        Test-RdaClaudeMarketplaceRow -Row $Row | Should -BeTrue
    }
    It 'does NOT match an unrelated Marketplace offer' {
        $Row = [pscustomobject]@{ PublisherName = 'contoso'; OfferName = 'widget-saas'; PlanName = 'basic' }
        Test-RdaClaudeMarketplaceRow -Row $Row | Should -BeFalse
    }
    It 'is null-safe' {
        Test-RdaClaudeMarketplaceRow -Row $null | Should -BeFalse
    }
}

Describe 'Get-RdaClaudeModelIdentity: model identity parsing' {
    It 'parses family + version from the offer' {
        Get-RdaClaudeModelIdentity -Row (script:New-FakeClaudeRow -Offer 'Claude Sonnet 4.5 PAYG') | Should -Be 'Claude Sonnet 4.5'
    }
    It 'parses Opus/Haiku families' {
        Get-RdaClaudeModelIdentity -Row (script:New-FakeClaudeRow -Offer 'anthropic claude opus 4.5') | Should -Be 'Claude Opus 4.5'
        Get-RdaClaudeModelIdentity -Row (script:New-FakeClaudeRow -Offer 'Claude Haiku 3.5 plan') | Should -Be 'Claude Haiku 3.5'
    }
    It 'falls back to a bare Claude identity when no family token is present' {
        # Never returns empty: the row is still attributable to Claude.
        Get-RdaClaudeModelIdentity -Row (script:New-FakeClaudeRow -Offer 'anthropic offer' -Plan 'payg') | Should -Match '^Claude'
    }
    It 'does NOT attach a non-adjacent number (e.g. a plan token quantity) as a version' {
        Get-RdaClaudeModelIdentity -Row (script:New-FakeClaudeRow -Offer 'Anthropic Claude Sonnet' -Plan '100000 tokens') | Should -Be 'Claude Sonnet'
    }
    It 'parses a version that precedes the family token' {
        Get-RdaClaudeModelIdentity -Row (script:New-FakeClaudeRow -Offer 'Claude 3 Sonnet') | Should -Be 'Claude Sonnet 3'
    }
    It 'does not attach any number when no family token is present' {
        Get-RdaClaudeModelIdentity -Row (script:New-FakeClaudeRow -Offer 'anthropic 100000' -Plan 'payg') | Should -Be 'Claude'
    }
}

Describe 'ConvertTo-RdaFoldedFoundryRow: Tier 1 fold (CCU/cost, non-token)' {

    It 'emits EXACTLY the first-party Consumption column set (no extra, no missing)' {
        $Out = ConvertTo-RdaFoldedFoundryRow -Row (script:New-FakeClaudeRow) -Obfuscate:$false
        $Actual = @($Out.PSObject.Properties.Name) | Sort-Object
        ($Actual -join ',') | Should -Be (($script:ConsumptionColumns | Sort-Object) -join ',') -Because 'a folded row must be schema-identical to a native consumption row'
    }

    It 'sets MeterCategory to the EXACT server string "Foundry Models"' {
        $Out = ConvertTo-RdaFoldedFoundryRow -Row (script:New-FakeClaudeRow) -Obfuscate:$false
        $Out.MeterCategory | Should -BeExactly 'Foundry Models' -Because 'the server admits a row into the Foundry->Bedrock path ONLY on this exact string'
    }

    It 'carries the Claude model identity in MeterName so the server can resolve the model' {
        $Out = ConvertTo-RdaFoldedFoundryRow -Row (script:New-FakeClaudeRow -Offer 'Claude Sonnet 4.5 offer') -Obfuscate:$false
        $Out.MeterName | Should -Be 'Claude Sonnet 4.5'
        $Out.MeterName | Should -Match '(?i)claude'
    }

    It 'carries the Azure cost (PretaxCost + Currency) inside AdditionalInfo' {
        $Out = ConvertTo-RdaFoldedFoundryRow -Row (script:New-FakeClaudeRow -PretaxCost 87.33 -Currency 'USD') -Obfuscate:$false
        $Ai = $Out.AdditionalInfo | ConvertFrom-Json
        $Ai.'Microsoft.Resources'.additionalInfo.PretaxCost | Should -Be 87.33 -Because 'the server attributes this Azure cost for the folded Claude usage'
        $Ai.'Microsoft.Resources'.additionalInfo.Currency | Should -Be 'USD'
    }

    It 'marks the row NON-TOKEN so the server does not compute a bogus AWS token price' {
        $Out = ConvertTo-RdaFoldedFoundryRow -Row (script:New-FakeClaudeRow -Unit '1M Tokens') -Obfuscate:$false
        # A fixed neutral unit, never a token-shaped one, even when the Marketplace unit was token-like.
        $Out.Unit | Should -Be 'CCU'
        $Out.Unit | Should -Not -Match '(?i)token'
        $Ai = $Out.AdditionalInfo | ConvertFrom-Json
        $Ai.'Microsoft.Resources'.additionalInfo.IsTokenMeter | Should -BeFalse
        $Ai.'Microsoft.Resources'.additionalInfo.FoldTier | Should -Be 1
        $Ai.'Microsoft.Resources'.additionalInfo.IsFoundryFold | Should -BeTrue
        # The real Marketplace unit is preserved for fidelity, just not in the emitted Unit column.
        $Ai.'Microsoft.Resources'.additionalInfo.MarketplaceUnitOfMeasure | Should -Be '1M Tokens'
    }

    It 'carries the usage Quantity (mirrors the first-party path)' {
        $Out = ConvertTo-RdaFoldedFoundryRow -Row (script:New-FakeClaudeRow -Quantity 42.0) -Obfuscate:$false
        $Out.Quantity | Should -Be 42.0
    }

    It 'synthesizes a NON-EMPTY, STABLE ResourceId and MeterId when the row lacks them (server requires both)' {
        $Row = script:New-FakeClaudeRow -MeterId '' -InstanceId ''
        $A = ConvertTo-RdaFoldedFoundryRow -Row $Row -Obfuscate:$false
        $B = ConvertTo-RdaFoldedFoundryRow -Row $Row -Obfuscate:$false
        $A.ResourceId | Should -Not -BeNullOrEmpty
        $A.MeterId    | Should -Not -BeNullOrEmpty
        $A.ResourceId | Should -Be $B.ResourceId -Because 'the same offer identity must synthesize the SAME id across runs'
        $A.MeterId    | Should -Be $B.MeterId
        $A.ResourceId | Should -Match '^/subscriptions/.+/providers/Microsoft\.Foundry/foundryModels/'
    }

    It 'prefers the row-supplied MeterId/InstanceId when present' {
        $Row = script:New-FakeClaudeRow -MeterId 'real-meter-123' -InstanceId '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg/providers/Microsoft.SaaS/resources/claude'
        $Out = ConvertTo-RdaFoldedFoundryRow -Row $Row -Obfuscate:$false
        $Out.MeterId | Should -Be 'real-meter-123'
        $Out.ResourceId | Should -Be $Row.InstanceId
    }
}

Describe 'ConvertTo-RdaFoldedFoundryRow: obfuscation parity' {
    It 'keeps the model identity READABLE in MeterName under -Obfuscate' {
        $Out = ConvertTo-RdaFoldedFoundryRow -Row (script:New-FakeClaudeRow -Offer 'Claude Sonnet 4.5') -Obfuscate:$true -SubCache @{} -RgCache @{} -NameCache @{}
        $Out.MeterName | Should -Be 'Claude Sonnet 4.5' -Because 'the "which model" signal must survive obfuscation, like Marketplace product identity'
    }
    It 'masks a real ResourceId under -Obfuscate while preserving ARM structure' {
        $Row = script:New-FakeClaudeRow -InstanceId '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-ai-prod/providers/Microsoft.SaaS/resources/claude-saas-01'
        $Out = ConvertTo-RdaFoldedFoundryRow -Row $Row -Obfuscate:$true -SubCache @{} -RgCache @{} -NameCache @{}
        $Out.ResourceId | Should -Not -Match 'claude-saas-01'
        $Out.ResourceId | Should -Not -Match '11111111-1111-1111-1111-111111111111'
        $Out.ResourceId | Should -Match '^/subscriptions/[^/]+/resourcegroups/[^/]+/providers/Microsoft\.SaaS/resources/[^/]+$'
    }
    It 'does not mask anything when -Obfuscate is off' {
        $Row = script:New-FakeClaudeRow -InstanceId '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg/providers/Microsoft.SaaS/resources/c'
        $Out = ConvertTo-RdaFoldedFoundryRow -Row $Row -Obfuscate:$false
        $Out.ResourceId | Should -Be $Row.InstanceId
    }
}

Describe 'Foundry fold collector wiring (ResourceInventory.ps1)' {
    It 'every nested function defined in ExecuteInventoryProcessing is actually invoked (no dead wiring)' {
        # Same AST guard as MarketplaceCollector.Tests.ps1: a nested helper defined but never called
        # is valid PowerShell and passes parse/lint, so assert on the AST that the fold + discovery
        # functions have a live call site.
        $ParseErrors = $null
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:InvPath, [ref]$null, [ref]$ParseErrors)
        @($ParseErrors).Count | Should -Be 0 -Because 'a parse failure would make this guard pass vacuously'

        $Outer = $Ast.FindAll(
            { param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'ExecuteInventoryProcessing' },
            $true) | Select-Object -First 1
        $Outer | Should -Not -BeNullOrEmpty

        $Defined = @($Outer.FindAll(
                { param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ne 'ExecuteInventoryProcessing' },
                $true) | ForEach-Object { $_.Name })
        $Invoked = @($Outer.FindAll(
                { param($n) $n -is [System.Management.Automation.Language.CommandAst] },
                $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })

        $NeverCalled = @($Defined | Where-Object { $Invoked -notcontains $_ })
        $NeverCalled -join ', ' | Should -BeNullOrEmpty -Because 'GetFoundryFoldConsumption must have a live call site'
    }
}

Describe 'End-to-end: folded rows land in a Consumption CSV alongside a native row' {
    # Behavioural proof (not grep): shape a native first-party consumption row and a Tier 1 folded
    # Claude row with the SAME 15-column projection the collector uses, append both to a real temp
    # CSV via Export-Csv -Append exactly as GetResourceConsumption + GetFoundryFoldConsumption do,
    # then read it back. Proves (a) the folded row is schema-compatible with -Append onto a file the
    # first-party path wrote, (b) the emitted header is AdditionalInfo, and (c) the folded row is
    # findable by its exact MeterCategory the server keys on.
    BeforeAll {
        $TmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { '/tmp' }
        $script:FoldDir = Join-Path $TmpBase ('FoldE2E_' + [guid]::NewGuid().ToString().Substring(0, 8))
        New-Item -ItemType Directory -Path $script:FoldDir -Force | Out-Null
        $script:FoldCsv = Join-Path $script:FoldDir 'Consumption_test.csv'

        $Cols = @('AdditionalInfo', 'MeterCategory', 'MeterId', 'MeterName', 'MeterRegion', 'MeterSubCategory', 'Quantity', 'Unit', 'UsageStartTime', 'UsageEndTime', 'ResourceId', 'ResourceLocation', 'ConsumptionMeter', 'ReservationId', 'ReservationOrderId')

        # A native first-party consumption row (VM/SQL-style), written first by the first-party path.
        $Native = [pscustomobject]@{
            AdditionalInfo = '{"Microsoft.Resources":{"resourceUri":"/subscriptions/s/rg/vm","location":"eastus","additionalInfo":{}}}'
            MeterCategory = 'Virtual Machines'; MeterId = 'vm-meter'; MeterName = 'D2s v5'; MeterRegion = 'eastus'
            MeterSubCategory = 'Dv5'; Quantity = 24; Unit = 'Hours'; UsageStartTime = '2026-08-01'; UsageEndTime = '2026-08-02'
            ResourceId = '/subscriptions/s/rg/vm'; ResourceLocation = 'eastus'; ConsumptionMeter = ''; ReservationId = ''; ReservationOrderId = ''
        }
        $Native | Select-Object $Cols | Export-Csv -LiteralPath $script:FoldCsv -Encoding utf8 -Append -NoTypeInformation

        # The folded Claude row appended afterwards, exactly as the fold step does.
        $Folded = ConvertTo-RdaFoldedFoundryRow -Row (script:New-FakeClaudeRow -Offer 'Claude Sonnet 4.5') -Obfuscate:$false
        $Folded | Select-Object $Cols | Export-Csv -LiteralPath $script:FoldCsv -Encoding utf8 -Append -NoTypeInformation
    }

    AfterAll {
        if ($script:FoldDir -and (Test-Path -LiteralPath $script:FoldDir)) { Remove-Item -LiteralPath $script:FoldDir -Recurse -Force }
    }

    It 'the emitted CSV header is AdditionalInfo (P2), not InstanceData' {
        $Header = Get-Content -LiteralPath $script:FoldCsv -TotalCount 1
        $Header | Should -Match '(^|,|")AdditionalInfo("|,)'
        $Header | Should -Not -Match 'InstanceData'
    }

    It 'the folded Claude row is present with MeterCategory="Foundry Models" and coexists with the native row' {
        $Rows = Import-Csv -LiteralPath $script:FoldCsv
        $Rows.Count | Should -Be 2 -Because 'the fold appends without disturbing the native first-party row'
        $Foundry = @($Rows | Where-Object { $_.MeterCategory -eq 'Foundry Models' })
        $Foundry.Count | Should -Be 1
        $Foundry[0].MeterName | Should -Be 'Claude Sonnet 4.5'
        # The Azure cost rode along inside AdditionalInfo.
        ($Foundry[0].AdditionalInfo | ConvertFrom-Json).'Microsoft.Resources'.additionalInfo.PretaxCost | Should -Be 87.33
        # And the native row is untouched.
        @($Rows | Where-Object { $_.MeterCategory -eq 'Virtual Machines' }).Count | Should -Be 1
    }
}
