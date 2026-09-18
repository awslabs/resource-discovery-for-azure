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

    It 'weights microsoft.web/sites at the two metrics actually enqueued' {
        # Two metric definitions are enqueued per function app, so the projected
        # query weight must be 2. If a future change adds the five Flex metrics, this
        # number has to move with it - which is the point of asserting it.
        $Weight = [int][regex]::Match($script:WebSitesRow, 'Weight\s*=\s*(?<W>\d+)').Groups['W'].Value
        $EnqueuedPerApp = @([regex]::Matches($script:MetricsSrc, "MetricName = 'FunctionExecution(?:Count|Units)'")).Count
        $Weight | Should -Be $EnqueuedPerApp -Because 'the -Plan weight must equal the number of metric definitions the phase enqueues per app'
    }
}
