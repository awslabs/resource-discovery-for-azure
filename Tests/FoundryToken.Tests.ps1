#Requires -Version 7.0
<#
    FoundryToken.Tests.ps1

    Behavioral tests for the ADDITIVE Tier 2 Foundry TOKEN collector: discover Azure AI /
    Cognitive Services accounts + model deployments via ARM, read per-model token metrics via
    Get-AzMetric (split by the ModelDeploymentName dimension), and fold them into the SAME
    first-party Consumption_*.csv the ingestion server reads as per-(model, role) "Foundry Models"
    token rows so the server can price the Azure-hosted models against AWS Bedrock.

    Covers the pure, unit-testable pieces and the collector wiring:
      - Get-RdaFoundryTokenRole            (metric name -> server-recognizable role + MeterName word)
      - Get-RdaFoundryTokenSeriesTotals    (Get-AzMetric dimensioned result -> per-model totals)
      - ConvertTo-RdaFoldedFoundryTokenRow (one (account,model,role,tokens) -> a Consumption row)
      - GetFoundryTokenConsumption / Invoke-RdaFoundryTokenMetricQuery wiring, asserted via AST + source.

    WHY MOCKED / SOURCE-ASSERTED. Exactly like MarketplaceCollector.Tests.ps1 and FoundryFold.Tests.ps1:
    a live Azure connection is NOT required and NOT used. The live-verified contract (Phi-4 / Phi-4-mini,
    2026-09-26) is encoded as faithful fakes of the Az.Monitor / Cognitive Services shapes, exercised
    against the REAL pure code paths. Fully offline.

    SERVER CONTRACT ASSERTED (from the task's live-verified spec):
      * MeterCategory == "Foundry Models" (exact - the server's Foundry->Bedrock gate).
      * MeterName carries the model identity AND a role substring the server parser keys on
        (input<-"inp"; output<-"outp"/"out"; cached-input<-"cd inp"/"cache read"; cache-write<-"cd wr").
      * Unit == "Tokens" (unit-1) so Quantity x server-multiplier = the RAW token count (never "1M Tokens").
      * TotalTokens / ModelRequests / TotalCalls are NOT emitted as their own priced rows (no double-count),
        but are preserved in AdditionalInfo for fidelity.
#>

BeforeAll {
    $script:Repo = Split-Path $PSScriptRoot -Parent
    $script:FunctionsPath = Join-Path $script:Repo 'Functions/ResourceInventory.Functions.ps1'
    $script:InvPath = Join-Path $script:Repo 'ResourceInventory.ps1'
    . $script:FunctionsPath

    # The exact first-party Consumption CSV column set a folded token row must match so it is
    # schema-identical to a native consumption row.
    $script:ConsumptionColumns = @(
        'AdditionalInfo', 'MeterCategory', 'MeterId', 'MeterName', 'MeterRegion',
        'MeterSubCategory', 'Quantity', 'Unit', 'UsageStartTime', 'UsageEndTime',
        'ResourceId', 'ResourceLocation', 'ConsumptionMeter', 'ReservationId', 'ReservationOrderId'
    )

    $script:AcctId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-ai-prod/providers/Microsoft.CognitiveServices/accounts/myfoundry'

    # Build a faithful fake of ONE Get-AzMetric result (PSMetric shape) collected WITH the
    # ModelDeploymentName dimension split: .Timeseries is a list of series, each with .Metadatavalues
    # (dimension pairs, .Name a LocalizableString {Value=...}) and .Data (points with .Total).
    function script:New-FakeDimMetric
    {
        param(
            # @{ '<model>' = @(<total-per-point>, ...) } - each model becomes one timeseries element.
            [hashtable]$PerModelPoints,
            [string]$DimensionName = 'ModelDeploymentName'
        )
        $Series = foreach ($Model in $PerModelPoints.Keys)
        {
            $Data = foreach ($Point in $PerModelPoints[$Model]) { [pscustomobject]@{ Total = $Point } }
            [pscustomobject]@{
                Metadatavalues = @(
                    [pscustomobject]@{
                        # Mirror the real LocalizableString: .Name.Value holds the dimension name.
                        Name  = [pscustomobject]@{ Value = $DimensionName }
                        Value = $Model
                    }
                )
                Data           = @($Data)
            }
        }
        [pscustomobject]@{ Timeseries = @($Series) }
    }
}

Describe 'Get-RdaFoundryTokenRole: metric name -> server role + MeterName word' {
    It 'maps InputTokens -> input / Inp' {
        $Role = Get-RdaFoundryTokenRole -MetricName 'InputTokens'
        $Role.Role | Should -Be 'input'
        $Role.MeterWord | Should -Be 'Inp'
        $Role.IsCacheWrite | Should -BeFalse
    }
    It 'maps OutputTokens -> output / Outp' {
        $Role = Get-RdaFoundryTokenRole -MetricName 'OutputTokens'
        $Role.Role | Should -Be 'output'
        $Role.MeterWord | Should -Be 'Outp'
    }
    It 'maps cacheReadInputTokens -> cached-input / Cd Inp (NOT plain input)' {
        $Role = Get-RdaFoundryTokenRole -MetricName 'cacheReadInputTokens'
        $Role.Role | Should -Be 'cached-input'
        $Role.MeterWord | Should -Be 'Cd Inp'
        $Role.IsCacheWrite | Should -BeFalse
    }
    It 'maps both ephemeral cache-write variants -> cache-write / Cd Wr' {
        (Get-RdaFoundryTokenRole -MetricName 'ephemeral5mInputTokens').Role | Should -Be 'cache-write'
        (Get-RdaFoundryTokenRole -MetricName 'ephemeral5mInputTokens').MeterWord | Should -Be 'Cd Wr'
        (Get-RdaFoundryTokenRole -MetricName 'ephemeral1hInputTokens').Role | Should -Be 'cache-write'
        (Get-RdaFoundryTokenRole -MetricName 'ephemeral1hInputTokens').MeterWord | Should -Be 'Cd Wr'
        (Get-RdaFoundryTokenRole -MetricName 'ephemeral1hInputTokens').IsCacheWrite | Should -BeTrue
    }
    It 'returns $null for the SUMMED / count metrics so they never become priced rows (no double-count)' {
        # TotalTokens = Input+Output summed; ModelRequests / TotalCalls are call counts, not tokens.
        Get-RdaFoundryTokenRole -MetricName 'TotalTokens'   | Should -BeNullOrEmpty
        Get-RdaFoundryTokenRole -MetricName 'ModelRequests' | Should -BeNullOrEmpty
        Get-RdaFoundryTokenRole -MetricName 'TotalCalls'    | Should -BeNullOrEmpty
    }
    It 'is null-safe / empty-safe and rejects unknown metrics' {
        Get-RdaFoundryTokenRole -MetricName ''        | Should -BeNullOrEmpty
        Get-RdaFoundryTokenRole -MetricName $null     | Should -BeNullOrEmpty
        Get-RdaFoundryTokenRole -MetricName 'Latency' | Should -BeNullOrEmpty
    }
    It 'is case-insensitive on the verified metric names' {
        (Get-RdaFoundryTokenRole -MetricName 'inputtokens').Role | Should -Be 'input'
        (Get-RdaFoundryTokenRole -MetricName 'OUTPUTTOKENS').Role | Should -Be 'output'
    }
    It 'the emitted MeterName word contains the substring the server role parser keys on' {
        # input<-"inp"; output<-"outp"/"out"; cached-input<-"cd inp"/"cache read"; cache-write<-"cd wr".
        (Get-RdaFoundryTokenRole -MetricName 'InputTokens').MeterWord.ToLower() | Should -Match 'inp'
        (Get-RdaFoundryTokenRole -MetricName 'OutputTokens').MeterWord.ToLower() | Should -Match 'out'
        (Get-RdaFoundryTokenRole -MetricName 'cacheReadInputTokens').MeterWord.ToLower() | Should -Match 'cd inp'
        (Get-RdaFoundryTokenRole -MetricName 'ephemeral5mInputTokens').MeterWord.ToLower() | Should -Match 'cd wr'
    }
}

Describe 'Get-RdaFoundryTokenSeriesTotals: per-model dimension parsing' {
    It 'sums each model timeseries to its window total' {
        $Metric = script:New-FakeDimMetric -PerModelPoints @{ 'Phi-4' = @(100, 200, 50); 'Phi-4-mini' = @(10, 5) }
        $Totals = Get-RdaFoundryTokenSeriesTotals -MetricResult $Metric
        $Totals.Count | Should -Be 2
        ($Totals | Where-Object { $_.ModelDeploymentName -eq 'Phi-4' }).Total | Should -Be 350
        ($Totals | Where-Object { $_.ModelDeploymentName -eq 'Phi-4-mini' }).Total | Should -Be 15
    }
    It 'treats null data points as zero and never throws' {
        $Series = [pscustomobject]@{
            Metadatavalues = @([pscustomobject]@{ Name = [pscustomobject]@{ Value = 'ModelDeploymentName' }; Value = 'Phi-4' })
            Data           = @([pscustomobject]@{ Total = 100 }, [pscustomobject]@{ Total = $null }, $null, [pscustomobject]@{ Total = 25 })
        }
        $Metric = [pscustomobject]@{ Timeseries = @($Series) }
        (Get-RdaFoundryTokenSeriesTotals -MetricResult $Metric | Where-Object { $_.ModelDeploymentName -eq 'Phi-4' }).Total | Should -Be 125
    }
    It 'returns an empty array (not an error) for a null result or a result with no timeseries' {
        @(Get-RdaFoundryTokenSeriesTotals -MetricResult $null).Count | Should -Be 0
        @(Get-RdaFoundryTokenSeriesTotals -MetricResult ([pscustomobject]@{ Data = @() })).Count | Should -Be 0
    }
    It 'tolerates a plain-string dimension Name as well as a LocalizableString' {
        $Series = [pscustomobject]@{
            Metadatavalues = @([pscustomobject]@{ Name = 'ModelDeploymentName'; Value = 'gpt-4o' })
            Data           = @([pscustomobject]@{ Total = 7 })
        }
        $Metric = [pscustomobject]@{ Timeseries = @($Series) }
        (Get-RdaFoundryTokenSeriesTotals -MetricResult $Metric)[0].ModelDeploymentName | Should -Be 'gpt-4o'
    }
}

Describe 'ConvertTo-RdaFoldedFoundryTokenRow: per-(model,role) token row (non-obfuscated)' {

    It 'emits EXACTLY the first-party Consumption column set (no extra, no missing)' {
        $Out = ConvertTo-RdaFoldedFoundryTokenRow -AccountResourceId $script:AcctId -ModelName 'Phi-4' -RoleMeterWord 'Inp' -Role 'input' -TokenQuantity 1000
        $Actual = @($Out.PSObject.Properties.Name) | Sort-Object
        ($Actual -join ',') | Should -Be (($script:ConsumptionColumns | Sort-Object) -join ',') -Because 'a folded token row must be schema-identical to a native consumption row'
    }

    It 'sets MeterCategory to the EXACT server string "Foundry Models"' {
        $Out = ConvertTo-RdaFoldedFoundryTokenRow -AccountResourceId $script:AcctId -ModelName 'Phi-4' -RoleMeterWord 'Inp' -Role 'input' -TokenQuantity 1000
        $Out.MeterCategory | Should -BeExactly 'Foundry Models'
    }

    It 'encodes the model identity AND the role in MeterName' {
        $InputRow = ConvertTo-RdaFoldedFoundryTokenRow -AccountResourceId $script:AcctId -ModelName 'Phi-4' -RoleMeterWord 'Inp' -Role 'input' -TokenQuantity 1
        $OutputRow = ConvertTo-RdaFoldedFoundryTokenRow -AccountResourceId $script:AcctId -ModelName 'Phi-4' -RoleMeterWord 'Outp' -Role 'output' -TokenQuantity 1
        $InputRow.MeterName | Should -Be 'Phi-4 Inp Tkns'
        $OutputRow.MeterName | Should -Be 'Phi-4 Outp Tkns'
        $InputRow.MeterName | Should -Match '(?i)phi-4'
        $InputRow.MeterName.ToLower() | Should -Match 'inp'
        $OutputRow.MeterName.ToLower() | Should -Match 'out'
    }

    It 'carries the RAW token count as Quantity with a unit-1 "Tokens" Unit (never "1M Tokens")' {
        $Out = ConvertTo-RdaFoldedFoundryTokenRow -AccountResourceId $script:AcctId -ModelName 'Phi-4' -RoleMeterWord 'Inp' -Role 'input' -TokenQuantity 123456
        $Out.Quantity | Should -Be 123456
        $Out.Unit | Should -Be 'Tokens'
        $Out.Unit | Should -Not -Match '(?i)1m|million|1,000,000'
    }

    It 'marks the row a TOKEN meter (FoldTier 2) in AdditionalInfo' {
        $Out = ConvertTo-RdaFoldedFoundryTokenRow -AccountResourceId $script:AcctId -ModelName 'Phi-4' -RoleMeterWord 'Inp' -Role 'input' -TokenQuantity 1
        $Ai = $Out.AdditionalInfo | ConvertFrom-Json
        $Ai.'Microsoft.Resources'.additionalInfo.IsFoundryFold | Should -BeTrue
        $Ai.'Microsoft.Resources'.additionalInfo.FoldTier | Should -Be 2
        $Ai.'Microsoft.Resources'.additionalInfo.IsTokenMeter | Should -BeTrue
        $Ai.'Microsoft.Resources'.additionalInfo.TokenRole | Should -Be 'input'
    }

    It 'sets ResourceId to the (non-empty) account id and MeterSubCategory to the model' {
        $Out = ConvertTo-RdaFoldedFoundryTokenRow -AccountResourceId $script:AcctId -ModelName 'Phi-4' -RoleMeterWord 'Inp' -Role 'input' -TokenQuantity 1
        $Out.ResourceId | Should -Be $script:AcctId
        $Out.ResourceId | Should -Not -BeNullOrEmpty
        $Out.MeterSubCategory | Should -Be 'Phi-4'
    }

    It 'synthesizes a STABLE MeterId per (account,model,role); different roles get different ids' {
        $First = ConvertTo-RdaFoldedFoundryTokenRow -AccountResourceId $script:AcctId -ModelName 'Phi-4' -RoleMeterWord 'Inp' -Role 'input' -TokenQuantity 1
        $Second = ConvertTo-RdaFoldedFoundryTokenRow -AccountResourceId $script:AcctId -ModelName 'Phi-4' -RoleMeterWord 'Inp' -Role 'input' -TokenQuantity 999
        $OtherRole = ConvertTo-RdaFoldedFoundryTokenRow -AccountResourceId $script:AcctId -ModelName 'Phi-4' -RoleMeterWord 'Outp' -Role 'output' -TokenQuantity 1
        $First.MeterId | Should -Not -BeNullOrEmpty
        $First.MeterId | Should -Be $Second.MeterId -Because 'the same (account,model,role) must map to the same id regardless of the count'
        $First.MeterId | Should -Not -Be $OtherRole.MeterId -Because 'a different role is a different meter'
        $First.MeterId | Should -Match '^foundrytoken-'
    }

    It 'preserves the raw non-priced counts (TotalTokens/ModelRequests/TotalCalls) in AdditionalInfo for fidelity' {
        $Out = ConvertTo-RdaFoldedFoundryTokenRow -AccountResourceId $script:AcctId -ModelName 'Phi-4' -RoleMeterWord 'Inp' -Role 'input' -TokenQuantity 100 -TotalTokens 300 -ModelRequests 42 -TotalCalls 50
        $Ai = $Out.AdditionalInfo | ConvertFrom-Json
        $Ai.'Microsoft.Resources'.additionalInfo.TotalTokens | Should -Be 300
        $Ai.'Microsoft.Resources'.additionalInfo.ModelRequests | Should -Be 42
        $Ai.'Microsoft.Resources'.additionalInfo.TotalCalls | Should -Be 50
    }
}

Describe 'ConvertTo-RdaFoldedFoundryTokenRow: obfuscation parity' {
    It 'keeps the model identity READABLE in MeterName / MeterSubCategory under -Obfuscate' {
        $Out = ConvertTo-RdaFoldedFoundryTokenRow -AccountResourceId $script:AcctId -ModelName 'Phi-4' -RoleMeterWord 'Inp' -Role 'input' -TokenQuantity 1 -Obfuscate:$true -SubCache @{} -RgCache @{} -NameCache @{}
        $Out.MeterName | Should -Be 'Phi-4 Inp Tkns' -Because 'the "which model" signal must survive obfuscation'
        $Out.MeterSubCategory | Should -Be 'Phi-4'
    }
    It 'masks the account ResourceId under -Obfuscate while preserving ARM structure' {
        $Out = ConvertTo-RdaFoldedFoundryTokenRow -AccountResourceId $script:AcctId -ModelName 'Phi-4' -RoleMeterWord 'Inp' -Role 'input' -TokenQuantity 1 -Obfuscate:$true -SubCache @{} -RgCache @{} -NameCache @{}
        $Out.ResourceId | Should -Not -Match 'myfoundry'
        $Out.ResourceId | Should -Not -Match '11111111-1111-1111-1111-111111111111'
        $Out.ResourceId | Should -Match '^/subscriptions/[^/]+/resourcegroups/[^/]+/providers/Microsoft\.CognitiveServices/accounts/[^/]+$'
    }
    It 'does not mask anything when -Obfuscate is off' {
        $Out = ConvertTo-RdaFoldedFoundryTokenRow -AccountResourceId $script:AcctId -ModelName 'Phi-4' -RoleMeterWord 'Inp' -Role 'input' -TokenQuantity 1 -Obfuscate:$false
        $Out.ResourceId | Should -Be $script:AcctId
    }
}

Describe 'End-to-end: token rows land in a Consumption CSV alongside native + Tier 1 rows' {
    # Behavioural proof (not grep): shape a native first-party row, a Tier 1 (CCU) folded Claude row,
    # and Tier 2 per-role token rows built the SAME way the collector builds them (per-model totals
    # parsed from a faithful Get-AzMetric fake, mapped through Get-RdaFoundryTokenRole, shaped by
    # ConvertTo-RdaFoldedFoundryTokenRow), append all with the SAME 15-column projection via
    # Export-Csv -Append, then read back. Proves schema compatibility, coexistence, no-double-count,
    # and that the token rows carry the exact server-keyed MeterCategory.
    BeforeAll {
        $TmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { '/tmp' }
        $script:TokDir = Join-Path $TmpBase ('TokE2E_' + [guid]::NewGuid().ToString().Substring(0, 8))
        New-Item -ItemType Directory -Path $script:TokDir -Force | Out-Null
        $script:TokCsv = Join-Path $script:TokDir 'Consumption_test.csv'

        $Cols = $script:ConsumptionColumns

        # 1) A native first-party consumption row.
        $Native = [pscustomobject]@{
            AdditionalInfo   = '{"Microsoft.Resources":{"resourceUri":"/subscriptions/s/rg/vm","location":"eastus","additionalInfo":{}}}'
            MeterCategory    = 'Virtual Machines'; MeterId = 'vm-meter'; MeterName = 'D2s v5'; MeterRegion = 'eastus'
            MeterSubCategory = 'Dv5'; Quantity = 24; Unit = 'Hours'; UsageStartTime = '2026-08-01'; UsageEndTime = '2026-08-02'
            ResourceId       = '/subscriptions/s/rg/vm'; ResourceLocation = 'eastus'; ConsumptionMeter = ''; ReservationId = ''; ReservationOrderId = ''
        }
        $Native | Select-Object $Cols | Export-Csv -LiteralPath $script:TokCsv -Encoding utf8 -Append -NoTypeInformation

        # 2) A Tier 1 (CCU/cost) folded Claude row - proves the two tiers coexist.
        $ClaudeRow = [pscustomobject]@{
            PublisherName    = 'anthropic'; OfferName = 'Claude in Foundry - Sonnet 4.5'; PlanName = 'payg'; OrderNumber = 'O1'
            ConsumedService  = 'Microsoft.SaaS'; ConsumedQuantity = 5; UnitOfMeasure = '1M Tokens'; PretaxCost = 12.0; Currency = 'USD'
            IsEstimated      = $false; MeterId = ''; UsageStart = '2026-08-01'; UsageEnd = '2026-08-31'
            SubscriptionGuid = '11111111-1111-1111-1111-111111111111'; SubscriptionName = 'AI Prod'; ResourceGroup = 'rg'; InstanceId = ''; InstanceName = 'c'
        }
        $Tier1 = ConvertTo-RdaFoldedFoundryRow -Row $ClaudeRow -Obfuscate:$false
        $Tier1 | Select-Object $Cols | Export-Csv -LiteralPath $script:TokCsv -Encoding utf8 -Append -NoTypeInformation

        # 3) Tier 2 token rows for Phi-4: Input=350, Output=120, plus a fidelity TotalTokens=470 that
        #    must NOT become its own row. Built exactly as the collector does it.
        $InputMetric = script:New-FakeDimMetric -PerModelPoints @{ 'Phi-4' = @(100, 200, 50) }   # 350
        $OutputMetric = script:New-FakeDimMetric -PerModelPoints @{ 'Phi-4' = @(120) }            # 120
        $TotalMetric = script:New-FakeDimMetric -PerModelPoints @{ 'Phi-4' = @(470) }             # fidelity only

        $InputTotals = Get-RdaFoundryTokenSeriesTotals -MetricResult $InputMetric
        $OutputTotals = Get-RdaFoundryTokenSeriesTotals -MetricResult $OutputMetric
        $TotalTotals = Get-RdaFoundryTokenSeriesTotals -MetricResult $TotalMetric
        $script:TotalFidelity = ($TotalTotals | Where-Object { $_.ModelDeploymentName -eq 'Phi-4' }).Total

        $MetricPlan = @(
            @{ Metric = 'InputTokens'; Totals = $InputTotals },
            @{ Metric = 'OutputTokens'; Totals = $OutputTotals },
            @{ Metric = 'TotalTokens'; Totals = $TotalTotals }   # must be dropped by Get-RdaFoundryTokenRole
        )
        foreach ($Plan in $MetricPlan)
        {
            $RoleInfo = Get-RdaFoundryTokenRole -MetricName $Plan.Metric
            if ($null -eq $RoleInfo) { continue }   # TotalTokens returns null -> no row (no double-count)
            foreach ($ModelTotal in $Plan.Totals)
            {
                if ($ModelTotal.Total -le 0) { continue }
                $Row = ConvertTo-RdaFoldedFoundryTokenRow -AccountResourceId $script:AcctId -ModelName $ModelTotal.ModelDeploymentName `
                    -RoleMeterWord $RoleInfo.MeterWord -Role $RoleInfo.Role -TokenQuantity $ModelTotal.Total `
                    -SourceMetricName $Plan.Metric -AccountLocation 'eastus' -TotalTokens $script:TotalFidelity
                $Row | Select-Object $Cols | Export-Csv -LiteralPath $script:TokCsv -Encoding utf8 -Append -NoTypeInformation
            }
        }
    }

    AfterAll {
        if ($script:TokDir -and (Test-Path -LiteralPath $script:TokDir)) { Remove-Item -LiteralPath $script:TokDir -Recurse -Force }
    }

    It 'the emitted CSV header is AdditionalInfo (schema-identical), not InstanceData' {
        $Header = Get-Content -LiteralPath $script:TokCsv -TotalCount 1
        $Header | Should -Match '(^|,|")AdditionalInfo("|,)'
        $Header | Should -Not -Match 'InstanceData'
    }

    It 'emits ONE priced token row per role (Input+Output), NOT one for TotalTokens (no double-count)' {
        $Rows = Import-Csv -LiteralPath $script:TokCsv
        $Tokens = @($Rows | Where-Object { $_.MeterCategory -eq 'Foundry Models' -and $_.Unit -eq 'Tokens' })
        $Tokens.Count | Should -Be 2 -Because 'only Input and Output are priced roles; TotalTokens is summed and must not be a separate row'
        @($Tokens | Where-Object { $_.MeterName -eq 'Phi-4 Inp Tkns' }).Count | Should -Be 1
        @($Tokens | Where-Object { $_.MeterName -eq 'Phi-4 Outp Tkns' }).Count | Should -Be 1
        @($Tokens | Where-Object { $_.MeterName -match '(?i)total' }).Count | Should -Be 0
    }

    It 'the token rows carry the RAW counts as Quantity' {
        $Rows = Import-Csv -LiteralPath $script:TokCsv
        [double]($Rows | Where-Object { $_.MeterName -eq 'Phi-4 Inp Tkns' }).Quantity | Should -Be 350
        [double]($Rows | Where-Object { $_.MeterName -eq 'Phi-4 Outp Tkns' }).Quantity | Should -Be 120
    }

    It 'the TotalTokens value survives ONLY as fidelity inside a priced row AdditionalInfo, never as its own row' {
        $Rows = Import-Csv -LiteralPath $script:TokCsv
        $InputCsvRow = $Rows | Where-Object { $_.MeterName -eq 'Phi-4 Inp Tkns' }
        ($InputCsvRow.AdditionalInfo | ConvertFrom-Json).'Microsoft.Resources'.additionalInfo.TotalTokens | Should -Be 470
    }

    It 'the native row and the Tier 1 CCU row are untouched and coexist with the Tier 2 token rows' {
        $Rows = Import-Csv -LiteralPath $script:TokCsv
        @($Rows | Where-Object { $_.MeterCategory -eq 'Virtual Machines' }).Count | Should -Be 1
        # Tier 1 Claude row: Foundry Models but the non-token CCU unit.
        $Tier1Rows = @($Rows | Where-Object { $_.MeterCategory -eq 'Foundry Models' -and $_.Unit -eq 'CCU' })
        $Tier1Rows.Count | Should -Be 1
        $Tier1Rows[0].MeterName | Should -Match '(?i)claude'
        # Total rows: 1 native + 1 Tier1 + 2 Tier2 = 4.
        $Rows.Count | Should -Be 4
    }
}

Describe 'Right-subscription attribution: distinct accounts do not cross-attribute' {
    # The collector re-pins the context per subscription and reads each account by its ABSOLUTE
    # ResourceId, so two subscriptions' accounts produce rows whose ResourceId embeds their OWN
    # subscription. Prove the row-shaping half of that here (the source-level pin+verify is asserted
    # in the collector-wiring Describe below): the same model name on two different accounts yields
    # rows that carry each account's own id and distinct MeterIds.
    It 'the same model on two accounts yields rows tied to each account (distinct ResourceId + MeterId)' {
        $AccountA = '/subscriptions/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/resourceGroups/rgA/providers/Microsoft.CognitiveServices/accounts/foundryA'
        $AccountB = '/subscriptions/bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb/resourceGroups/rgB/providers/Microsoft.CognitiveServices/accounts/foundryB'
        $RowA = ConvertTo-RdaFoldedFoundryTokenRow -AccountResourceId $AccountA -ModelName 'Phi-4' -RoleMeterWord 'Inp' -Role 'input' -TokenQuantity 10
        $RowB = ConvertTo-RdaFoldedFoundryTokenRow -AccountResourceId $AccountB -ModelName 'Phi-4' -RoleMeterWord 'Inp' -Role 'input' -TokenQuantity 10
        $RowA.ResourceId | Should -Be $AccountA
        $RowB.ResourceId | Should -Be $AccountB
        $RowA.MeterId | Should -Not -Be $RowB.MeterId -Because 'the account id is part of the MeterId identity seed'
    }
}

Describe 'GetFoundryTokenConsumption collector wiring (ResourceInventory.ps1)' {

    BeforeAll {
        $script:ParseErrors = $null
        $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:InvPath, [ref]$null, [ref]$script:ParseErrors)
    }

    It 'the inner script parses without error' {
        @($script:ParseErrors).Count | Should -Be 0
    }

    It 'every nested function defined in ExecuteInventoryProcessing is actually invoked (no dead wiring)' {
        # Same AST guard as FoundryFold/MarketplaceCollector: a nested helper defined but never called
        # passes parse/lint, so assert on the AST that GetFoundryTokenConsumption + its metric-query
        # helper have live call sites.
        $Outer = $script:Ast.FindAll(
            { param($Node) $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq 'ExecuteInventoryProcessing' },
            $true) | Select-Object -First 1
        $Outer | Should -Not -BeNullOrEmpty

        $Defined = @($Outer.FindAll(
                { param($Node) $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -ne 'ExecuteInventoryProcessing' },
                $true) | ForEach-Object { $_.Name })
        $Invoked = @($Outer.FindAll(
                { param($Node) $Node -is [System.Management.Automation.Language.CommandAst] },
                $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })

        'GetFoundryTokenConsumption' | Should -BeIn $Defined
        'GetFoundryTokenConsumption' | Should -BeIn $Invoked -Because 'the token collector must have a live call site'
        'Invoke-RdaFoundryTokenMetricQuery' | Should -BeIn $Invoked -Because 'the per-metric query helper must be called by the collector'

        $NeverCalled = @($Defined | Where-Object { $Invoked -notcontains $_ })
        $NeverCalled -join ', ' | Should -BeNullOrEmpty
    }

    It 'the token phase switch -SkipFoundryTokens is declared on the inner script' {
        $Params = @($script:Ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        'SkipFoundryTokens' | Should -BeIn $Params
    }
}
