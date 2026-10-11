#Requires -Version 7.0
<#
    FunctionAppMetricGuard.Tests.ps1

    Guards the Function App metric enqueue condition in Extension/Metrics.ps1
    against being narrowed on the 'kind' field.

        FunctionExecutionCount
        FunctionExecutionUnits

    WHY THIS TEST EXISTS. Microsoft's monitoring reference says the two execution
    metrics are not supported on Linux Premium/Dedicated plans, and 'kind' does
    encode the OS ('functionapp' = Windows, 'functionapp,linux' = Linux). Reading
    only that, narrowing the guard to

        $app.kind -match 'functionapp' -and $app.kind -notmatch 'linux'

    looks like a free cost saving. It is not, and it was measured to be wrong.

    Three Function App shapes were created in the sandbox and queried with the
    exact data call this file sends:

        Flex Consumption   kind = functionapp,linux   reserved = true
                           plan FC1 / FlexConsumption   -> BadRequest, NO metrics
        Linux Dedicated    kind = functionapp,linux   reserved = true
                           plan B1 / Basic             -> SUCCESS, 3 buckets

    Identical 'kind'. Identical 'reserved'. OPPOSITE answers. So no rule over
    'kind' can be correct, and '-notmatch linux' specifically would have silently
    dropped the working Linux Dedicated app's real data. That is data loss
    disguised as an optimisation, which is strictly worse than the wasted calls it
    was meant to save. The measurement also contradicts Microsoft's Linux note
    directly - the B1 Linux app returned real FunctionExecutionCount values.

    The real discriminator is the hosting plan SKU (FC1 / FlexConsumption), read
    from the App Service Plan rows that already arrive in $Resources. Selecting
    metrics on plan SKU is tracked separately: it adds new metric NAMES to
    Metrics_*.json, so it is a schema change needing owner approval, and the plan
    requires live proof on a real Flex app running real executions first.

    Until then the correct behaviour is the UNNARROWED guard: ask for both legacy
    metrics on every function app. A wasted BadRequest costs calls. A wrongly
    skipped metric costs the customer's data.

    The tests are OFFLINE source assertions plus pure-logic checks of the exact
    predicate the file uses. Nothing here needs a live subscription.
#>

BeforeAll {
    $script:MetricsPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Extension/Metrics.ps1'
    $script:MetricsSrc = Get-Content -LiteralPath $script:MetricsPath -Raw

    # Extract the guard condition FROM THE SOURCE and evaluate that, rather than
    # retyping the predicate here. This is the difference between a test that
    # documents the intent and one that enforces it: a hardcoded copy keeps passing
    # after the real guard is changed, so every case below would go green against
    # broken code and only the source assertion would fire.
    $script:GuardCandidates = @($script:MetricsSrc -split "`r?`n" | Where-Object { $_ -match '\$app\.kind -match ''functionapp''' })
    $script:GuardLine = $script:GuardCandidates | Select-Object -First 1

    if ([string]::IsNullOrWhiteSpace($script:GuardLine))
    {
        throw 'Could not locate the Function App guard line in Extension/Metrics.ps1; this test cannot verify what it cannot find.'
    }

    # Exactly ONE guard site. Taking -First 1 without checking the count would leave a
    # second, differently-worded guard completely untested while this file still passed.
    if ($script:GuardCandidates.Count -ne 1)
    {
        throw ('Expected exactly 1 Function App guard line in Extension/Metrics.ps1, found {0}. A second site would bypass every assertion here.' -f $script:GuardCandidates.Count)
    }

    # Scope the "must not be narrowed" assertions to the App Service definition block
    # rather than the whole file. File-wide, an unrelated future metric block that
    # legitimately needed a Linux or reserved test would trip them - a false failure that
    # teaches people to weaken the test.
    $script:AppServiceBlock = [regex]::Match(
        $script:MetricsSrc,
        '(?s)#\s*Define App Service Metrics.*?#\s*Define MariaDB Metrics').Value
    if ([string]::IsNullOrWhiteSpace($script:AppServiceBlock))
    {
        throw 'Could not isolate the App Service metric-definition block in Extension/Metrics.ps1.'
    }
    if ($script:AppServiceBlock -notmatch [regex]::Escape($script:GuardLine.Trim()))
    {
        throw 'The isolated App Service block does not contain the guard line, so the scoping anchors have drifted.'
    }

    # Turn `if ($app.kind -match '...')` into a scriptblock over $Kind.
    $script:GuardExpression = ([regex]::Match($script:GuardLine, '^\s*if\s*\((?<Expr>.+)\)\s*$').Groups['Expr'].Value) -replace '\$app\.kind', '$Kind'
    if ([string]::IsNullOrWhiteSpace($script:GuardExpression))
    {
        throw ('Could not parse the guard condition out of: {0}' -f $script:GuardLine)
    }
    $script:GuardBlock = [scriptblock]::Create('param($Kind) ' + $script:GuardExpression)

    function script:Test-ShouldEnqueueFunctionMetrics
    {
        param($Kind)
        return [bool](& $script:GuardBlock $Kind)
    }

    # The -Plan weight helpers, so the agreement assertions read the REAL planner
    # instead of a retyped copy of its numbers.
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'Functions/RunAllSubscriptions.Functions.ps1')

    # Partition EVERY MetricName enqueued in the App Service block into the legacy
    # pair and the Flex-only set. Discovering the sets this way (rather than with a
    # narrow per-name regex) is what stops a newly added Flex metric being invisible
    # to the agreement assertions - the failure mode the previous version had.
    $script:AllAppMetricNames = @([regex]::Matches($script:AppServiceBlock, "MetricName = '(?<N>[^']+)'") | ForEach-Object { $_.Groups['N'].Value })
    $script:LegacyNames = @($script:AllAppMetricNames | Where-Object { $_ -cmatch '^FunctionExecution(?:Count|Units)$' })
    $script:FlexNames = @($script:AllAppMetricNames | Where-Object { $_ -cnotmatch '^FunctionExecution(?:Count|Units)$' })

    # Fail LOUD if either partition is empty. An empty set silently satisfies a
    # count comparison, which is exactly how the old assertion stayed green at the
    # wrong number.
    if ($script:LegacyNames.Count -eq 0 -or $script:FlexNames.Count -eq 0)
    {
        throw ('Expected both a legacy and a Flex metric set in the App Service block; found legacy={0} flex={1}. A test that compares against an empty set proves nothing.' -f $script:LegacyNames.Count, $script:FlexNames.Count)
    }

}

Describe 'The Function App guard is not narrowed on kind' {

    It 'does NOT exclude Linux function apps by kind' {
        # The single most important assertion in this file. A Linux Dedicated app
        # on a B1 plan returns real data, so excluding on kind loses it.
        $script:AppServiceBlock |
            Should -Not -Match '-notmatch\s+''linux''' -Because 'a Flex app and a working Linux Dedicated app share kind = functionapp,linux, so -notmatch linux drops real measured data'
    }

    It 'does not exclude on the reserved flag either' {
        # 'reserved' is the other OS-ish field, and it was measured identical
        # ('true') across the failing Flex app and the working Dedicated app.
        $script:AppServiceBlock |
            Should -Not -Match '\$app\.reserved' -Because 'reserved was measured identical on the failing and the working app, so it discriminates nothing'
    }

    It 'keeps the guard as the plain functionapp test' {
        $script:GuardExpression.Trim() | Should -Be "`$Kind -match 'functionapp'"
    }

    It 'records WHY kind must not be used, so the next reader does not re-add it' {
        # A bare predicate invites the same "obvious" optimisation again. The
        # measured contradiction has to live next to the code.
        $script:MetricsSrc | Should -Match '(?s)Do NOT narrow this on ''kind''.*FlexConsumption|(?s)Do NOT narrow this on ''kind''.*FC1'
    }

    It 'still enqueues both Function App metrics' {
        $script:MetricsSrc | Should -Match "MetricName = 'FunctionExecutionCount'"
        $script:MetricsSrc | Should -Match "MetricName = 'FunctionExecutionUnits'"
    }

    It 'has exactly one enqueue site per metric, so there is no divergent second path' {
        @([regex]::Matches($script:MetricsSrc, "MetricName = 'FunctionExecutionCount'")).Count | Should -Be 1
        @([regex]::Matches($script:MetricsSrc, "MetricName = 'FunctionExecutionUnits'")).Count | Should -Be 1
    }
}

Describe 'Guard predicate: every function app shape still collects' {

    # Each of these was either measured in the sandbox or is a shape the tool
    # demonstrably meets in the field. All of them must enqueue, because the only
    # thing that reliably tells them apart is the plan SKU, which this guard does
    # not consult.
    It 'enqueues for <Label>' -ForEach @(
        @{ Label = 'a Windows function app'; Kind = 'functionapp' }
        @{ Label = 'a Linux function app (Dedicated B1 returns real data)'; Kind = 'functionapp,linux' }
        @{ Label = 'a Flex Consumption app (same kind, no data - SKU is the real test)'; Kind = 'functionapp,linux' }
        @{ Label = 'a Logic Apps Standard host'; Kind = 'functionapp,workflowapp' }
        @{ Label = 'a Linux container function app'; Kind = 'functionapp,linux,container' }
        @{ Label = 'a differently cased Linux kind'; Kind = 'functionapp,Linux' }
    ) {
        script:Test-ShouldEnqueueFunctionMetrics -Kind $Kind | Should -BeTrue
    }
}

Describe 'Guard predicate: non-function resources stay excluded' {

    # A null/empty kind is real - the sandbox holds a microsoft.web/sites row with
    # an empty kind - so it is covered explicitly rather than assumed.
    It 'excludes <Label>' -ForEach @(
        @{ Label = 'a null kind'; Kind = $null }
        @{ Label = 'an empty kind'; Kind = '' }
        @{ Label = 'a plain web app'; Kind = 'app' }
        @{ Label = 'a Linux web app'; Kind = 'app,linux' }
    ) {
        script:Test-ShouldEnqueueFunctionMetrics -Kind $Kind | Should -BeFalse
    }
}

Describe 'The -Plan estimator agrees with the metrics phase about which apps count' {

    # Guard that Get-MetricQueryWeightMap's ExtraFilter for microsoft.web/sites selects the SAME apps this
    # file enqueues metrics for: the KQL filter and the PowerShell -match can drift silently and missize -Plan shards.

    BeforeAll {
        $script:WrapperFnPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Functions/RunAllSubscriptions.Functions.ps1'
        $script:WrapperSrc = Get-Content -LiteralPath $script:WrapperFnPath -Raw
        $script:WebSitesRow = @($script:WrapperSrc -split "`r?`n" | Where-Object { $_ -match "Type = 'microsoft\.web/sites'" }) | Select-Object -First 1
    }

    It 'has exactly one microsoft.web/sites row in the weight map' {
        $script:WebSitesRow | Should -Not -BeNullOrEmpty
        @($script:WrapperSrc -split "`r?`n" | Where-Object { $_ -match "Type = 'microsoft\.web/sites'" }).Count | Should -Be 1
    }

    It 'filters on kind containing functionapp, and nothing narrower' {
        $Filter = [regex]::Match($script:WebSitesRow, "ExtraFilter\s*=\s*(?<Q>[""'])(?<F>.*?)\k<Q>").Groups['F'].Value
        $Filter | Should -Not -BeNullOrEmpty -Because 'the row must carry an ExtraFilter or -Plan counts every web app'
        $Filter.Trim() | Should -Be "kind contains 'functionapp'"
    }

    It 'does not exclude Linux, so it cannot drift from the metrics guard' {
        $script:WebSitesRow | Should -Not -Match '(?i)linux' -Because 'the estimator and the metrics phase must select the same population'
    }

    It 'found a non-empty legacy set and a non-empty Flex set to compare against' {
        # The anti-vacuity guard, asserted rather than only thrown, so the reason a
        # comparison below is trustworthy is itself visible in the results.
        $script:LegacyNames.Count | Should -BeGreaterThan 0
        $script:FlexNames.Count   | Should -BeGreaterThan 0
        $script:LegacyNames | Should -Contain 'FunctionExecutionCount'
        $script:FlexNames   | Should -Contain 'AlwaysReadyUnits' -Because 'the fifth Flex billing name must be enqueued'
    }

    It 'weights microsoft.web/sites at the NON-Flex metrics actually enqueued' {
        # The map's integer is the NON-Flex base: the legacy pair only. The Flex and
        # unresolved-plan cases are conditional and live in the KQL, asserted below.
        $Weight = [int][regex]::Match($script:WebSitesRow, 'Weight\s*=\s*(?<W>\d+)').Groups['W'].Value
        $Weight | Should -Be $script:LegacyNames.Count -Because 'the map weight must equal the legacy definitions the phase enqueues for a non-Flex app'
    }

    It 'agrees with the metrics phase on all three function-app cases' {
        # THIS IS THE ASSERTION THAT USED TO BE VACUOUS. Its predecessor counted only
        # "MetricName = 'FunctionExecution(Count|Units)'", a regex the prefixed Flex
        # names cannot match, so it sat green at 2 while a Flex app really cost 5.
        #
        # Two things make it non-vacuous now. First, the name sets are discovered by
        # partitioning EVERY MetricName in the App Service block, so a new Flex name
        # lands in $script:FlexNames automatically instead of being invisible to a
        # narrow regex. Second, the anti-vacuity guards in BeforeAll fail the run if
        # either set comes back empty - an empty set is what let the old version pass
        # by matching nothing.
        $AppWeight = Get-FunctionAppPlanWeight
        $AppWeight.NonFlex    | Should -Be $script:LegacyNames.Count -Because 'a non-Flex app is charged the legacy pair'
        $AppWeight.Flex       | Should -Be $script:FlexNames.Count   -Because 'a Flex app is charged the Flex-only names, which REPLACE the legacy pair'
        $AppWeight.Unresolved | Should -Be ($script:LegacyNames.Count + $script:FlexNames.Count) -Because 'an unresolved plan makes the phase enqueue BOTH sets'
    }

    It 'emits those same three numbers into the -Plan KQL' {
        # Closes the loop: the helper could agree with Metrics.ps1 and still not be
        # what the query charges. These assert the generated KQL text itself.
        $AppWeight = Get-FunctionAppPlanWeight
        $Kql = Get-PlanWeightKql
        $Kql | Should -Match ('__isFlex,\s*{0},' -f $AppWeight.Flex) -Because 'a Flex app must be charged its Flex-only count'
        $Kql | Should -Match ('not\(__planResolved\),\s*{0},' -f $AppWeight.Unresolved) -Because 'an unresolved plan must be charged both sets'
        $Kql | Should -Match ('not\(__planResolved\),\s*\d+,\s*{0}\)' -f $AppWeight.NonFlex) -Because 'the case() fallback is the non-Flex base'
        $Kql | Should -Match "join kind=leftouter" -Because 'the conditional weight needs the plan SKU, which comes from the serverfarms join'
        $Kql | Should -Match "type =~ 'microsoft\.web/serverfarms'" -Because 'the join must read the App Service Plan rows'
    }

    It 'mirrors the metrics phase in treating a SKU-less plan as unresolved, not as non-Flex' {
        # The KQL predicate must match $PlanResolved in Extension/Metrics.ps1: a plan
        # row found with an empty sku is UNRESOLVED (charge both sets), never
        # "definitely not Flex". Getting this backwards would under-charge the exact
        # case the metrics phase deliberately over-collects.
        $Kql = Get-PlanWeightKql
        $Kql | Should -Match 'isnotempty\(__planId\)\s+and\s+\(isnotempty\(__planSkuName\)\s+or\s+isnotempty\(__planSkuTier\)\)'
        $script:AppServiceBlock | Should -Match '\$PlanResolved\s*=\s*\$null -ne \$PlanSku -and \(!\[string\]::IsNullOrEmpty\(\$PlanSku\.name\) -or !\[string\]::IsNullOrEmpty\(\$PlanSku\.tier\)\)'
    }
}

Describe 'Flex Consumption is selected on the hosting plan SKU' {

    # The def-building loop is top-level script body inside `if ($Task -eq
    # 'Processing')` in Extension/Metrics.ps1, so there is NO seam to invoke it
    # through - dot-sourcing the file would run the whole metrics phase. Same
    # limitation as Tests/ConsumptionResourceGroupFilter.Tests.ps1.
    #
    # So, as in the kind-guard block above, the decision expressions are EXTRACTED
    # FROM SOURCE and evaluated. That is the important difference from a retyped
    # copy: a hardcoded duplicate keeps passing after the real predicate changes,
    # whereas this fails the moment the source stops parsing into the same decision.
    #
    # Measured live against a real Flex app and a real Consumption app in the
    # sandbox (Get-AzMetricDefinition plus the exact Get-AzMetric call this file
    # issues), which is what these expectations encode:
    #   FC1 / FlexConsumption : legacy pair ABSENT  -> BadRequest x2
    #                           AlwaysReady*/OnDemand* -> 30 buckets each
    #   Y1  / Dynamic         : legacy pair -> 30 buckets each
    #                           AlwaysReady*/OnDemand* -> BadRequest x4
    # The sets are mutually exclusive, so sending the wrong one is a guaranteed
    # failed call, not a harmless extra.

    BeforeAll {
        $script:BlockLines = $script:AppServiceBlock -split "`r?`n"

        $PlanResolvedLine = @($script:BlockLines | Where-Object { $_ -match '^\s*\$PlanResolved\s*=' }) | Select-Object -First 1
        $IsFlexLine = @($script:BlockLines | Where-Object { $_ -match '^\s*\$IsFlexConsumption\s*=' }) | Select-Object -First 1

        if ([string]::IsNullOrWhiteSpace($PlanResolvedLine) -or [string]::IsNullOrWhiteSpace($IsFlexLine))
        {
            throw 'Could not locate the $PlanResolved / $IsFlexConsumption assignments in the App Service block; this test cannot verify what it cannot find.'
        }

        # Exactly one assignment each, for the same reason the kind guard insists on
        # one site: a second, differently-worded assignment would go untested.
        if (@($script:BlockLines | Where-Object { $_ -match '^\s*\$PlanResolved\s*=' }).Count -ne 1 -or
            @($script:BlockLines | Where-Object { $_ -match '^\s*\$IsFlexConsumption\s*=' }).Count -ne 1)
        {
            throw 'Expected exactly one $PlanResolved and one $IsFlexConsumption assignment in the App Service block.'
        }

        $script:DecisionBlock = [scriptblock]::Create(
            'param($PlanSku)' + [Environment]::NewLine +
            $PlanResolvedLine + [Environment]::NewLine +
            $IsFlexLine + [Environment]::NewLine +
            '[pscustomobject]@{ PlanResolved = [bool]$PlanResolved; IsFlex = [bool]$IsFlexConsumption }')

        function script:Get-FlexDecision
        {
            param($PlanSku)
            return (& $script:DecisionBlock $PlanSku)
        }
    }

    It 'treats <Label> as Flex=<ExpectFlex> Resolved=<ExpectResolved>' -ForEach @(
        # Values arrive LOWERCASED because every data call passes -Lowercase; the
        # source compares with -eq, which is case-insensitive, so both cases must work.
        @{ Label = 'a Flex plan by sku.name (lowercased, as the pipeline delivers it)'; PlanSku = @{ name = 'fc1'; tier = 'flexconsumption' }; ExpectFlex = $true; ExpectResolved = $true }
        @{ Label = 'a Flex plan in portal casing'; PlanSku = @{ name = 'FC1'; tier = 'FlexConsumption' }; ExpectFlex = $true; ExpectResolved = $true }
        @{ Label = 'a Flex plan identified by tier alone'; PlanSku = @{ name = ''; tier = 'flexconsumption' }; ExpectFlex = $true; ExpectResolved = $true }
        @{ Label = 'a Flex plan identified by name alone'; PlanSku = @{ name = 'fc1'; tier = '' }; ExpectFlex = $true; ExpectResolved = $true }
        # Non-Flex shapes: these publish the legacy pair and must keep getting it.
        @{ Label = 'a Consumption Y1 plan'; PlanSku = @{ name = 'y1'; tier = 'dynamic' }; ExpectFlex = $false; ExpectResolved = $true }
        @{ Label = 'a Basic B1 plan (the Linux Dedicated app that returns real data)'; PlanSku = @{ name = 'b1'; tier = 'basic' }; ExpectFlex = $false; ExpectResolved = $true }
        @{ Label = 'an Elastic Premium EP1 plan'; PlanSku = @{ name = 'ep1'; tier = 'elasticpremium' }; ExpectFlex = $false; ExpectResolved = $true }
        @{ Label = 'a Logic Apps WS1 plan'; PlanSku = @{ name = 'ws1'; tier = 'workflowstandard' }; ExpectFlex = $false; ExpectResolved = $true }
        # Unresolvable shapes: NOT Flex, and NOT resolved - which is what routes them
        # to the both-sets fallback rather than to a silent guess.
        @{ Label = 'no plan row at all (stale Resource Graph snapshot)'; PlanSku = $null; ExpectFlex = $false; ExpectResolved = $false }
        @{ Label = 'a plan row whose sku carries neither name nor tier'; PlanSku = @{ name = ''; tier = '' }; ExpectFlex = $false; ExpectResolved = $false }
        @{ Label = 'a plan row whose sku fields are null'; PlanSku = @{ name = $null; tier = $null }; ExpectFlex = $false; ExpectResolved = $false }
    ) {
        $Decision = script:Get-FlexDecision -PlanSku $(if ($null -eq $PlanSku) { $null } else { [pscustomobject]$PlanSku })
        $Decision.IsFlex | Should -Be $ExpectFlex
        $Decision.PlanResolved | Should -Be $ExpectResolved
    }

    It 'never reports Flex without also reporting the plan resolved' {
        # Guards the ordering invariant: IsFlex is only ever true off a real SKU
        # marker, so an unresolved plan can never be mistaken FOR Flex.
        foreach ($Sku in @($null, [pscustomobject]@{ name = ''; tier = '' }, [pscustomobject]@{ name = 'fc1'; tier = '' }))
        {
            $Decision = script:Get-FlexDecision -PlanSku $Sku
            if ($Decision.IsFlex) { $Decision.PlanResolved | Should -BeTrue }
        }
    }

    It 'builds the plan lookup from serverfarms rows already in $Resources' {
        $script:AppServiceBlock | Should -Match 'microsoft\.web/serverfarms' -Because 'the SKU must come from rows already downloaded, not a new query'
        $script:AppServiceBlock | Should -Match '\$PlanSkuLookup\[' -Because 'the per-app decision must be an O(1) hashtable hit, like $SubLookup'
    }

    It 'adds NO Azure call to the definition-building loop' {
        # The whole point of using the plan SKU is that it is free. A Get-Az* here
        # would reintroduce a per-app round trip and defeat the fix.
        #
        # Comment lines are stripped FIRST, deliberately. The block's comments cite
        # the cmdlets used to gather the live evidence (Get-AzMetricDefinition,
        # Get-AzMetric), so matching the raw text would fail on the prose that
        # documents the fix rather than on any real call. The assertion is about
        # executable code, so it must look only at executable code.
        $CodeOnly = (@($script:BlockLines | Where-Object { $_ -notmatch '^\s*#' }) -join [Environment]::NewLine)
        $CodeOnly | Should -Not -Match 'Get-Az' -Because 'the discriminator must cost no extra Azure call'
        $CodeOnly | Should -Not -Match 'Invoke-Az' -Because 'the discriminator must cost no extra Azure call'
        $CodeOnly | Should -Not -Match 'Search-AzGraph' -Because 'the SKU must come from rows already in $Resources'
        # Prove the strip did not simply empty the haystack, which would make the
        # three assertions above vacuously true.
        $CodeOnly | Should -Match '\$PlanSkuLookup\['
    }

    It 'resolves the plan from the site''s serverFarmId' {
        $script:AppServiceBlock | Should -Match '\$app\.properties\.serverFarmId'
    }

    It 'gates the legacy pair on NOT being Flex' {
        $script:AppServiceBlock | Should -Match 'if\s*\(\s*-not\s+\$IsFlexConsumption\s*\)' -Because 'a Flex app must stop receiving the two metrics it cannot answer'
    }

    It 'still asks a Flex app for all five Flex billing metrics' {
        # AlwaysReadyUnits is the fifth: it measures the always-ready baseline an app
        # is charged for while idle, which the four execution names do not capture.
        # Verified live on an FC1/FlexConsumption app (Total/Count, 30 buckets) and
        # confirmed ABSENT on Y1/Dynamic.
        foreach ($Name in @('AlwaysReadyFunctionExecutionCount', 'OnDemandFunctionExecutionCount', 'AlwaysReadyFunctionExecutionUnits', 'OnDemandFunctionExecutionUnits', 'AlwaysReadyUnits'))
        {
            $script:MetricsSrc | Should -Match ("MetricName = '{0}'" -f $Name)
            @([regex]::Matches($script:MetricsSrc, ("MetricName = '{0}'" -f $Name))).Count |
                Should -Be 1 -Because 'a second enqueue site would double-collect and bypass these assertions'
        }
    }

    It 'falls back to BOTH sets when the plan cannot be resolved' {
        # The fallback is the anti-data-loss decision and the easiest thing for a
        # later "simplification" to drop, so it is asserted directly: the Flex set
        # must also fire when $PlanResolved is false.
        $script:AppServiceBlock |
            Should -Match 'if\s*\(\s*\$IsFlexConsumption\s+-or\s+-not\s+\$PlanResolved\s*\)' -Because 'a stale snapshot must never silently cost a Flex app its only execution metrics'
    }

    It 'keeps the Flex defs on the same Total/Sum shape as the legacy pair' {
        # All five measured primaryAggregationType = Total, unit = Count, with Total
        # supported - so they are the same kind of figure and stay comparable.
        $FlexDefLines = @($script:BlockLines | Where-Object { $_ -match "MetricName = '(?:(?:AlwaysReady|OnDemand)FunctionExecution|AlwaysReadyUnits)" })
        @($FlexDefLines).Count | Should -Be 5
        foreach ($Line in $FlexDefLines)
        {
            $Line | Should -Match "Aggregation = 'Total'"
            $Line | Should -Match "Measure = 'Sum'"
            $Line | Should -Match "Service = 'Functions'"
            $Line | Should -Match "Series = 'false'"
            $Line | Should -Match 'MetricIndex = \$MetricCountId\+\+'
        }
    }

    It 'records that the SKU discriminator is implemented, not just intended' {
        $script:MetricsSrc | Should -Match '(?s)SKU discriminator is now IMPLEMENTED'
    }
}
