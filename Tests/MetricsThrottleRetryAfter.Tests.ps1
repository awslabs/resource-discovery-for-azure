# Requires -Modules Pester
# Offline coverage for the metrics throttle handling in Extension/Metrics.ps1:
# a 429 wave used to exhaust the 3 generic retries in ~28s (4s+8s+16s) and record the metric as
# Throttled/failed, ignoring the server's Retry-After. Get-RdaMetricRetryPlan now gives throttled
# attempts their own budget and waits at least Retry-After (bounded). Extracted by AST like
# MetricsErrorBodyCapture.Tests.ps1 does, because the function lives inside the -Parallel block.

BeforeAll {
    $Repo = Split-Path $PSScriptRoot -Parent
    $script:MetricsSrc = Get-Content -LiteralPath (Join-Path $Repo 'Extension/Metrics.ps1') -Raw
    $Tokens = $null; $Errors = $null
    $Ast = [System.Management.Automation.Language.Parser]::ParseInput($script:MetricsSrc, [ref]$Tokens, [ref]$Errors)
    $FnAst = $Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'Get-RdaMetricRetryPlan' }, $true) | Select-Object -First 1
    if (-not $FnAst) { throw 'Get-RdaMetricRetryPlan was not found in Extension/Metrics.ps1' }
    . ([scriptblock]::Create($FnAst.Extent.Text))
    $ClsAst = $Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'Get-RdaMetricFailureClass' }, $true) | Select-Object -First 1
    if (-not $ClsAst) { throw 'Get-RdaMetricFailureClass was not found in Extension/Metrics.ps1' }
    . ([scriptblock]::Create($ClsAst.Extent.Text))

    # Production defaults, read from the source so the test tracks them.
    $script:MaxRetries = [int]([regex]::Match($script:MetricsSrc, '(?m)^\s*\$MetricMaxRetries\s*=\s*(\d+)').Groups[1].Value)
    $script:MaxThrottle = [int]([regex]::Match($script:MetricsSrc, '(?m)^\s*\$MetricMaxThrottleRetries\s*=\s*(\d+)').Groups[1].Value)
    $script:MaxRetryAfter = [double]([regex]::Match($script:MetricsSrc, '(?m)^\s*\$MetricMaxRetryAfterSeconds\s*=\s*(\d+)').Groups[1].Value)

    function Plan([hashtable]$Over)
    {
        $P = @{ Attempt = 0; Throttled = $false; ThrottledAttempts = 0; RetryAfterSeconds = 0; Permanent = $false
            MaxRetries = $script:MaxRetries; MaxThrottleRetries = $script:MaxThrottle; MaxRetryAfterSeconds = $script:MaxRetryAfter }
        foreach ($K in $Over.Keys) { $P[$K] = $Over[$K] }
        Get-RdaMetricRetryPlan @P
    }

    # The shipped Retry-After reader, exactly as the runspace receives it.
    . (Join-Path $Repo 'Functions/ResourceInventory.Functions.ps1')
    $script:RealTypesAvailable = $true
    try { Import-Module Az.Monitor -ErrorAction Stop; $null = [Microsoft.Rest.Azure.CloudException]; $null = [Microsoft.Rest.HttpResponseMessageWrapper] }
    catch { $script:RealTypesAvailable = $false }
    function New-ThrottleRecord([string]$RetryAfter)
    {
        $Msg = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::TooManyRequests)
        $null = $Msg.Headers.TryAddWithoutValidation('Retry-After', $RetryAfter)
        $Ex = [Microsoft.Rest.Azure.CloudException]::new('Operation returned an invalid status code ''TooManyRequests''')
        $Ex.Response = [Microsoft.Rest.HttpResponseMessageWrapper]::new($Msg, 'throttled')
        return [System.Management.Automation.ErrorRecord]::new($Ex, 'Throttled', 'LimitsExceeded', $null)
    }
}

Describe 'Get-RdaMetricRetryPlan - production defaults' {
    It 'reads sane defaults from the source' {
        $script:MaxRetries | Should -Be 3
        $script:MaxThrottle | Should -BeGreaterOrEqual 6
        $script:MaxRetryAfter | Should -BeGreaterOrEqual 60
    }
}

Describe 'Get-RdaMetricRetryPlan - throttled attempts' {
    It 'waits at least the server-directed Retry-After when it exceeds the backoff' {
        $P = Plan @{ Throttled = $true; ThrottledAttempts = 1; RetryAfterSeconds = 45 }
        $P.Retry | Should -BeTrue
        $P.SleepSeconds | Should -Be 45
    }

    It 'keeps the throttled backoff (2x, capped) when Retry-After is shorter than it' {
        $P = Plan @{ Attempt = 3; Throttled = $true; ThrottledAttempts = 4; RetryAfterSeconds = 2 }
        $P.SleepSeconds | Should -Be 16 -Because '2^3 = 8, doubled for throttling = 16, above the 2s the server asked'
    }

    It 'bounds an absurd Retry-After to the configured maximum' {
        (Plan @{ Throttled = $true; ThrottledAttempts = 1; RetryAfterSeconds = 3600 }).SleepSeconds | Should -Be $script:MaxRetryAfter
    }

    It 'falls back to its own backoff when no Retry-After was supplied' {
        (Plan @{ Attempt = 1; Throttled = $true; ThrottledAttempts = 2; RetryAfterSeconds = 0 }).SleepSeconds | Should -Be 4
    }

    It 'does not spend the generic budget: keeps retrying past MaxRetries while throttled' {
        $P = Plan @{ Attempt = $script:MaxRetries + 2; Throttled = $true; ThrottledAttempts = $script:MaxThrottle; RetryAfterSeconds = 5 }
        $P.Retry | Should -BeTrue
    }

    It 'gives up once the throttle budget is exhausted' {
        (Plan @{ Attempt = 9; Throttled = $true; ThrottledAttempts = $script:MaxThrottle + 1 }).Retry | Should -BeFalse
    }

    It 'a sustained 429 wave now waits out the directed delay instead of failing inside 30 seconds' {
        # Old behaviour: 3 retries at 4+8+16 = 28s of waiting, then Outcome = Throttled.
        $Total = 0
        for ($i = 1; $i -le $script:MaxThrottle; $i++) { $Total += (Plan @{ Attempt = $i - 1; Throttled = $true; ThrottledAttempts = $i; RetryAfterSeconds = 20 }).SleepSeconds }
        $Total | Should -BeGreaterThan 28
    }
}

Describe 'Get-RdaMetricRetryPlan - unchanged behaviour for other failures' {
    It 'generic failures use 2^attempt capped at 30 and stop after MaxRetries' {
        (Plan @{ Attempt = 0 }).SleepSeconds | Should -Be 1
        (Plan @{ Attempt = 2 }).SleepSeconds | Should -Be 4
        (Plan @{ Attempt = 6; MaxRetries = 10 }).SleepSeconds | Should -Be 30
        (Plan @{ Attempt = $script:MaxRetries }).Retry | Should -BeFalse
    }

    It 'never retries a permanent failure, even under a Retry-After' {
        (Plan @{ Permanent = $true; Throttled = $true; ThrottledAttempts = 1; RetryAfterSeconds = 10 }).Retry | Should -BeFalse
    }
}

Describe 'Retry-After reaches the runspace' {
    It 'Get-RdaRetryAfterSeconds reads the header from a real TooManyRequests CloudException' {
        if (-not $script:RealTypesAvailable) { Set-ItResult -Skipped -Because 'Az.Monitor (Microsoft.Rest types) is not installed here' }
        Get-RdaRetryAfterSeconds -ErrorRecord (New-ThrottleRecord '17') | Should -Be 17
    }

    It 'Metrics.ps1 ships the helper definition into the -Parallel runspaces and calls the plan from the retry loop' {
        $script:MetricsSrc | Should -Match '\$MetricRetryAfterFnDef\s*=.*\$\{function:Get-RdaRetryAfterSeconds\}'
        $script:MetricsSrc | Should -Match 'Set-Item -Path function:Get-RdaRetryAfterSeconds'
        $script:MetricsSrc | Should -Match 'Get-RdaRetryAfterSeconds -ErrorRecord \$_'
        $script:MetricsSrc | Should -Match 'Get-RdaMetricRetryPlan -Attempt \$Attempt -Throttled \$Throttled'
    }

    It 'the retry loop has an explicit exit when the budget is exhausted (the while is no longer bounded by attempts)' {
        # The give-up branch (else of the retry decision) must break out of the unbounded while.
        $script:MetricsSrc | Should -Match '(?s)while \(-not \$Succeeded\)\s*\{.*?if \(\$Plan\.Retry\).*?else\s*\{\s*\$CallOutcome = .*?\n\s*break\s*\n\s*\}'
    }
}

Describe 'Get-RdaMetricFailureClass - one failed attempt, classified from its message' {
    BeforeAll {
        # Exact text Azure Monitor produced for an invalid bearer in a live simulation (Get-AzMetric, Az.Monitor).
        $script:Live401 = 'The running command stopped because the preference variable "ErrorActionPreference" or common parameter is set to Stop: Exception type: ErrorResponseException, Message: Microsoft.Azure.Management.Monitor.Models.ErrorResponseException: Operation returned an invalid status code ''Unauthorized'''
    }

    It 'treats 401 Unauthorized as permanent (no retries) with its own outcome' {
        $C = Get-RdaMetricFailureClass -Message $script:Live401
        $C.Permanent | Should -BeTrue; $C.Outcome | Should -Be 'Unauthorized'; $C.Throttled | Should -BeFalse
    }
    It 'recognises the ARM token error codes as Unauthorized' {
        (Get-RdaMetricFailureClass -Message 'ExpiredAuthenticationToken: The access token expiry UTC time is earlier than current UTC time').Outcome | Should -Be 'Unauthorized'
        (Get-RdaMetricFailureClass -Message 'InvalidAuthenticationToken: The received access token is not valid').Outcome | Should -Be 'Unauthorized'
    }
    It 'treats 403 Forbidden / AuthorizationFailed as permanent Forbidden' {
        (Get-RdaMetricFailureClass -Message ($script:Live401 -replace 'Unauthorized', 'Forbidden')).Outcome | Should -Be 'Forbidden'
        (Get-RdaMetricFailureClass -Message 'AuthorizationFailed: The client does not have authorization to perform action').Outcome | Should -Be 'Forbidden'
    }
    It 'keeps NotFound and BadRequest permanent, as before' {
        (Get-RdaMetricFailureClass -Message ($script:Live401 -replace 'Unauthorized', 'NotFound')).Outcome | Should -Be 'NotFound'
        (Get-RdaMetricFailureClass -Message ($script:Live401 -replace 'Unauthorized', 'BadRequest')).Outcome | Should -Be 'BadRequest'
    }
    It 'classifies a 429 as throttled and retryable' {
        $C = Get-RdaMetricFailureClass -Message ($script:Live401 -replace 'Unauthorized', 'TooManyRequests')
        $C.Throttled | Should -BeTrue; $C.Permanent | Should -BeFalse; $C.Outcome | Should -Be 'Throttled'
    }
    It 'does not read a GUID containing 429 as throttling (permanent check first, anchored status)' {
        $Msg = "Operation returned an invalid status code 'NotFound' for /subscriptions/12345678-1234-1234-1234-123456789012/resourceGroups/rg-429-prod/providers/x"
        (Get-RdaMetricFailureClass -Message $Msg).Outcome | Should -Be 'NotFound'
    }
    It 'is not fooled by a bare 401/403 inside a resource id: a throttled call stays throttled' {
        $Msg = "Operation returned an invalid status code 'TooManyRequests' for /subscriptions/12345678-1234-1234-1234-123456789012/resourceGroups/rg-403/providers/x"
        $C = Get-RdaMetricFailureClass -Message $Msg
        $C.Throttled | Should -BeTrue; $C.Permanent | Should -BeFalse
        (Get-RdaMetricFailureClass -Message 'Timed out after 120s for /resourceGroups/rg-401-prod').Outcome | Should -Be 'Error'
    }
    It 'falls back to a retryable generic Error' {
        $C = Get-RdaMetricFailureClass -Message 'Timed out after 120s'
        $C.Permanent | Should -BeFalse; $C.Throttled | Should -BeFalse; $C.Outcome | Should -Be 'Error'
    }
    It 'the phase summary counts and explains access failures' {
        $script:MetricsSrc | Should -Match 'Unauthorized: \{8\} \| Forbidden: \{9\}'
        $script:MetricsSrc | Should -Match 'ACCESS FAILURE: '
        $script:MetricsSrc | Should -Match 'Re-authenticate \(Connect-AzAccount\)'
    }
}
