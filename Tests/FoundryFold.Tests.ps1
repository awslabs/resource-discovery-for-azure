#Requires -Version 7.0
<#
    FoundryFold.Tests.ps1

    Behavioral tests for the ADDITIVE Foundry fold (P1) and the Consumption column
    rename (P2):

      P1 - fold Claude/Anthropic Marketplace usage into the SAME first-party
           Consumption_*.csv, as "Foundry Models" rows,
           so Claude usage appears there as well. Covers:
             - Test-RdaClaudeMarketplaceRow  (detection)
             - Get-RdaClaudeModelIdentity    (model identity from OfferName/PlanName)
             - ConvertTo-RdaFoldedFoundryRow  (Tier 1: CCU/cost, non-token)
           and the collector wiring (GetFoundryFoldConsumption in ResourceInventory.ps1)
           asserted against the source/AST.

      P2 - the emitted Consumption CSV column is AdditionalInfo, NOT InstanceData.

    WHY MOCKED / SOURCE-ASSERTED. Exactly like MarketplaceCollector.Tests.ps1: the only
    available test subscription cannot purchase a Claude-on-Foundry Marketplace offer and
    exposes no live Foundry per-deployment token metrics, so the row-mapping can only be
    proven with representative fakes + the real pure code paths. Fully offline. No Azure calls.

    UNVERIFIED-SPELLING CAVEAT (mirrored from the code). The exact Azure Foundry token-meter
    MeterName spellings and Unit strings are NOT yet verified against a live Claude-on-Foundry
    deployment. These tests assert the CONTRACT this tool writes (MeterCategory exact match;
    role substrings in MeterName; token Unit passed through as discovered), not a live spelling.
#>

# These three suppressions cover the AST-execution regression test in the
# 'GetFoundryFoldConsumption ... null captured row' Describe, which runs the REAL
# fold function body extracted verbatim from ResourceInventory.ps1 rather than a
# re-implementation. Inline suppression is not honored inside Pester scriptblocks,
# so they are declared at file scope. They target load-bearing test scaffolding, not
# defects: Invoke-Expression materializes the real body; Write-Log is a required fake;
# $Obfuscate is consumed inside that Invoke-Expression'd body (invisible to the analyzer).
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingInvokeExpression', '',
    Justification = 'Executes the REAL fold function body extracted verbatim from source via the AST, not a re-implementation.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '',
    Justification = 'Write-Log is a required test fake for the extracted fold function body, not an accidental override.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'Obfuscate',
    Justification = 'Consumed inside the fold function body executed via Invoke-Expression, which the analyzer cannot see statically.')]
param()

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

    It 'sets MeterCategory to the EXACT string "Foundry Models"' {
        $Out = ConvertTo-RdaFoldedFoundryRow -Row (script:New-FakeClaudeRow) -Obfuscate:$false
        $Out.MeterCategory | Should -BeExactly 'Foundry Models' -Because 'a Foundry cost row is identified by this exact string'
    }

    It 'carries the Claude model identity in MeterName so the model is named on the row' {
        $Out = ConvertTo-RdaFoldedFoundryRow -Row (script:New-FakeClaudeRow -Offer 'Claude Sonnet 4.5 offer') -Obfuscate:$false
        $Out.MeterName | Should -Be 'Claude Sonnet 4.5'
        $Out.MeterName | Should -Match '(?i)claude'
    }

    It 'carries the Azure cost (PretaxCost + Currency) inside AdditionalInfo' {
        $Out = ConvertTo-RdaFoldedFoundryRow -Row (script:New-FakeClaudeRow -PretaxCost 87.33 -Currency 'USD') -Obfuscate:$false
        $Ai = $Out.AdditionalInfo | ConvertFrom-Json
        $Ai.'Microsoft.Resources'.additionalInfo.PretaxCost | Should -Be 87.33 -Because 'this is the Azure cost of the folded Claude usage'
        $Ai.'Microsoft.Resources'.additionalInfo.Currency | Should -Be 'USD'
    }

    It 'marks the row NON-TOKEN so its cost cannot be read as a token count' {
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

    It 'the fold collector is a DIRECT child of ExecuteInventoryProcessing, so it is in scope at its call site' {
        # REGRESSION: GetFoundryFoldConsumption was once defined nested INSIDE the sibling
        # GetMarketplaceConsumption, so it parsed and FindAll(...,$true) still located it, but at
        # runtime it was out of scope where ExecuteInventoryProcessing calls it -> a terminating
        # 'not recognized' error that aborted the rest of the consumption block. The 'no dead
        # wiring' test above cannot catch this because it does not check the enclosing-function
        # chain, so assert that the collector's NEAREST enclosing function is ExecuteInventoryProcessing.
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:InvPath, [ref]$null, [ref]$null)
        $Outer = $Ast.FindAll(
            { param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'ExecuteInventoryProcessing' },
            $true) | Select-Object -First 1
        $Outer | Should -Not -BeNullOrEmpty

        $Def = $Outer.FindAll(
            { param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'GetFoundryFoldConsumption' },
            $true) | Select-Object -First 1
        $Def | Should -Not -BeNullOrEmpty -Because 'GetFoundryFoldConsumption must be defined within ExecuteInventoryProcessing'

        $Parent = $Def.Parent
        while ($null -ne $Parent -and -not ($Parent -is [System.Management.Automation.Language.FunctionDefinitionAst])) { $Parent = $Parent.Parent }
        $Parent.Name | Should -Be 'ExecuteInventoryProcessing' -Because 'GetFoundryFoldConsumption is called from the ExecuteInventoryProcessing body, so it must be a direct child there to be in scope'
    }
}

Describe 'End-to-end: folded rows land in a Consumption CSV alongside a native row' {
    # Behavioural proof (not grep): shape a native first-party consumption row and a Tier 1 folded
    # Claude row with the SAME 15-column projection the collector uses, append both to a real temp
    # CSV via Export-Csv -Append exactly as GetResourceConsumption + GetFoundryFoldConsumption do,
    # then read it back. Proves (a) the folded row is schema-compatible with -Append onto a file the
    # first-party path wrote, (b) the emitted header is AdditionalInfo, and (c) the folded row is
    # findable by its exact MeterCategory.
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

Describe 'GetFoundryFoldConsumption: a null captured row must not abort the phase (regression)' {
    # REGRESSION (live). The fold captured Claude Marketplace rows and, for each, called the
    # pure helper ConvertTo-RdaFoldedFoundryRow -Row $Captured.Row. That -Row is [Parameter(Mandatory)],
    # so a null captured row threw a TERMINATING "Cannot bind argument to parameter 'Row' because it
    # is null." Under the run's default $ErrorActionPreference=SilentlyContinue that terminating error
    # aborted the whole consumption block, so the phases after the fold never ran.
    #
    # This test executes the REAL fold function body (extracted verbatim from ResourceInventory.ps1
    # via the AST, not a re-implementation) with a capture list that mixes a null Row and a valid
    # Claude row, under SilentlyContinue, and asserts observable behavior: the fold returns normally
    # (no terminating abort), a following phase flag is reached, and the valid row is still folded.

    BeforeAll {
        $ErrParse = $null
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:InvPath, [ref]$null, [ref]$ErrParse)
        $FoldDef = $Ast.FindAll(
            { param($Node) $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq 'GetFoundryFoldConsumption' },
            $true) | Select-Object -First 1
        # Materialize the real nested function at script scope so we can invoke its actual body.
        Invoke-Expression $FoldDef.Extent.Text
    }

    It 'folds a valid Claude row and skips a null captured row without a terminating abort' {
        $ErrorActionPreference = 'SilentlyContinue'

        # Minimal fakes for the globals/vars the fold body touches.
        function Write-Log { param($Message, $Severity) }
        $Global:ResourceIdDictionary = @{}
        $Global:FoundryFoldRecordCount = $null
        $script:FoundryFoldRecordsThisRun = $null
        $Obfuscate = [pscustomobject]@{ IsPresent = $false }
        $Global:ConsumptionFileCsv = Join-Path ([System.IO.Path]::GetTempPath()) ("rda_fold_regression_{0}.csv" -f ([guid]::NewGuid()))

        $ValidRow = [pscustomobject]@{
            PublisherName = 'Anthropic'; OfferName = 'Claude Sonnet 4.5 offer'; PlanName = 'payg'
            InstanceId = '/subscriptions/11111111-1111-1111-1111-111111111111/rg/foo'; MeterId = 'm1'
            ConsumedQuantity = 42.0; UnitOfMeasure = '1M Tokens'; PretaxCost = 1.0; Currency = 'USD'
            SubscriptionGuid = '11111111-1111-1111-1111-111111111111'; SubscriptionName = 'Sub'; ResourceGroup = 'rg'
        }
        $script:FoundryFoldClaudeRows = [System.Collections.ArrayList]::new()
        $null = $script:FoundryFoldClaudeRows.Add([pscustomobject]@{ SubId = 's'; SubName = 'S'; Row = $null })
        $null = $script:FoundryFoldClaudeRows.Add([pscustomobject]@{ SubId = 's2'; SubName = 'S2'; Row = $ValidRow })

        # Model the call-site sequence (the fold, then the next phase) in one block with no
        # isolation, exactly as ExecuteInventoryProcessing does: a terminating fold error would leave
        # $NextPhaseReached = $false, reproducing the abort.
        $NextPhaseReached = $false
        try
        {
            GetFoundryFoldConsumption
            $NextPhaseReached = $true
        }
        catch
        {
            $NextPhaseReached = $false
        }

        try
        {
            $NextPhaseReached | Should -BeTrue -Because 'a null captured row must not abort the phase before the next phase runs'
            $Global:FoundryFoldRecordCount | Should -Be 1 -Because 'the one VALID Claude row is still folded; only the null row is skipped'
            Test-Path -LiteralPath $Global:ConsumptionFileCsv | Should -BeTrue
            $Rows = @(Import-Csv -LiteralPath $Global:ConsumptionFileCsv)
            $Rows.Count | Should -Be 1
            $Rows[0].MeterCategory | Should -BeExactly 'Foundry Models'
        }
        finally
        {
            if (Test-Path -LiteralPath $Global:ConsumptionFileCsv) { Remove-Item -LiteralPath $Global:ConsumptionFileCsv -Force }
        }
    }

    It 'reports a confirmed zero, not one row, when the Marketplace phase captured nothing' {
        # The capture list is only created when a Claude row is seen, so a run with none leaves it $null.
        $script:FoldLog = [System.Collections.Generic.List[string]]::new()
        function Write-Log { param($Message, $Severity) $script:FoldLog.Add([string]$Message) }
        $Global:FoundryFoldRecordCount = $null
        $script:FoundryFoldRecordsThisRun = $null
        $Obfuscate = [pscustomobject]@{ IsPresent = $false }
        $script:FoundryFoldClaudeRows = $null

        GetFoundryFoldConsumption

        @($script:FoldLog | Where-Object { $_ -like 'Foundry fold: folding*' }).Count | Should -Be 0
        @($script:FoldLog | Where-Object { $_ -like '*This is a CONFIRMED ZERO*' }).Count | Should -Be 1
    }
}
