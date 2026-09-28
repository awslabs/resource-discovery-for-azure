# Requires -Modules Pester
# Offline coverage for the metrics throttle handling in Extension/Metrics.ps1:
# a 429 wave used to exhaust the 3 generic retries in ~28s (4s+8s+16s) and record the metric as
# Throttled/failed, ignoring the server's Retry-After. Get-RdaMetricRetryPlan now gives throttled
# attempts their own budget and waits at least Retry-After (bounded). Extracted by AST like
# MetricsErrorBodyCapture.Tests.ps1 does, because the function lives inside the -Parallel block.
# The last Describe covers the per-attempt timeout: each attempt runs on a shared runspace pool
# and a timed-out attempt is stopped without waiting for it.

BeforeAll {
    $Repo = Split-Path $PSScriptRoot -Parent
    $script:MetricsSrc = Get-Content -LiteralPath (Join-Path $Repo 'Extension/Metrics.ps1') -Raw
    $Tokens = $null; $Errors = $null
    $Ast = [System.Management.Automation.Language.Parser]::ParseInput($script:MetricsSrc, [ref]$Tokens, [ref]$Errors)
    if (@($Errors).Count -gt 0) { throw ('Extension/Metrics.ps1 does not parse: {0}' -f $Errors[0].Message) }
    $script:Ast = $Ast
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
        $P = @{
            Attempt = 0; Throttled = $false; ThrottledAttempts = 0; RetryAfterSeconds = 0; Permanent = $false
            MaxRetries = $script:MaxRetries; MaxThrottleRetries = $script:MaxThrottle; MaxRetryAfterSeconds = $script:MaxRetryAfter
        }
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

Describe 'Per-attempt timeout - pooled call, not a ThreadJob per attempt' {
    BeforeAll {
        foreach ($Name in 'Wait-RdaMetricCall', 'Receive-RdaMetricCall')
        {
            $Fn = $script:Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq $Name }, $true) | Select-Object -First 1
            if (-not $Fn) { throw ('{0} was not found in Extension/Metrics.ps1' -f $Name) }
            . ([scriptblock]::Create($Fn.Extent.Text))
        }
        $script:Pool = [runspacefactory]::CreateRunspacePool([initialsessionstate]::CreateDefault2())
        [void]$script:Pool.SetMaxRunspaces(4)
        $script:Pool.Open()
        $script:Stuck = [System.Collections.Generic.List[object]]::new()

        function Start-PoolCall([scriptblock]$Body, [object[]]$ArgumentList = @())
        {
            $Call = [powershell]::Create()
            $Call.RunspacePool = $script:Pool
            [void]$Call.AddScript($Body)
            foreach ($A in $ArgumentList) { [void]$Call.AddArgument($A) }
            [pscustomobject]@{ Call = $Call; Handle = $Call.BeginInvoke() }
        }
    }
    AfterAll {
        # Let any deliberately stuck call finish so the pool closes cleanly.
        foreach ($S in @($script:Stuck)) { [void]$S.Handle.AsyncWaitHandle.WaitOne(10000); $S.Call.Dispose() }
        if ($script:Pool)
        {
            $script:Pool.Close()
            $script:Pool.Dispose()
        }
    }

    It 'issues no job cmdlet at all: no Start-ThreadJob, Wait-Job, Receive-Job, Stop-Job or Remove-Job' {
        # Start-ThreadJob runs at most 5 jobs at a time process-wide and builds a new runspace,
        # with a fresh Az module load, for every attempt.
        $JobCmds = @($script:Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] -and $args[0].GetCommandName() -in @('Start-ThreadJob', 'Start-Job', 'Wait-Job', 'Receive-Job', 'Stop-Job', 'Remove-Job') }, $true))
        $JobCmds.Count | Should -Be 0 -Because ('a per-attempt job must not come back: {0}' -f (($JobCmds | ForEach-Object { $_.Extent.Text }) -join ' | '))
    }
    It 'runs every attempt on one pool built from CreateDefault2 and sized above ConcurrencyLimit' {
        $script:MetricsSrc | Should -Match ([regex]::Escape('[runspacefactory]::CreateRunspacePool([initialsessionstate]::CreateDefault2())'))
        # Each of the ConcurrencyLimit parallel slots can abandon one call per attempt, so the
        # ceiling is (MaxRetries + 1) per slot. A flat doubling saturates after two timed-out rounds,
        # and once the pool is full BeginInvoke queues while the per-call clock is already running -
        # so a call that never reached Azure gets recorded as a timeout and counted as an API call.
        $script:MetricsSrc | Should -Match 'SetMaxRunspaces\(\[math\]::Max\(1, \[int\]\$ConcurrencyLimit\) \* \(\[math\]::Max\(1, \[int\]\$MetricMaxRetries\) \+ 1\)\)' -Because 'the headroom has to cover every attempt each slot can abandon, not a flat doubling'
        $script:MetricsSrc | Should -Match '\$CallPool = \$using:MetricCallPool'
        # Without the assignment each [powershell] gets a private runspace and reloads Az on every
        # attempt. Asserted over the AST rather than as adjacent text, because the dispatch guard now
        # sits between the construction and the assignment - the invariant is that the ONE construction
        # is bound to the SHARED pool, not that the two statements are neighbours.
        $Creates = @($script:Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $N.Expression.Extent.Text -eq '[powershell]' -and $N.Member.Extent.Text -eq 'Create' }, $true))
        $Creates.Count | Should -Be 1 -Because 'every attempt must go through the one pooled construction'
        $PoolBinds = @($script:Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.AssignmentStatementAst] -and $N.Left.Extent.Text -eq '$Call.RunspacePool' }, $true))
        $PoolBinds.Count | Should -Be 1 -Because 'one binding, so no attempt can silently get a private runspace'
        $PoolBinds[0].Right.Extent.Text | Should -Be '$CallPool' -Because 'it must bind to the pool shared through $using:, not a new one'
        $PoolBinds[0].Extent.StartOffset | Should -BeGreaterThan $Creates[0].Extent.StartOffset -Because 'the call is constructed first, then bound'
        $script:MetricsSrc | Should -Match "AddCommand\('Get-AzMetric'\)\.AddParameters\(\`$MetricArgs\)"
    }
    It 'stops a timed-out attempt without waiting and keeps it out of the classifier' {
        $script:MetricsSrc | Should -Not -Match '\$Call\.(Stop|EndStop)\(' -Because 'a synchronous stop waits for a call blocked in a network read'
        # 'elseif', not 'if': an undispatched call is short-circuited first, so it is never waited on
        # and never lands on the abandoned bag. Anchored on 'elseif' deliberately - 'if \(Wait-' would
        # also match inside 'elseif \(Wait-' and would pass whether the guard is there or not.
        $script:MetricsSrc | Should -Match 'if \(\$null -eq \$CallHandle\) \{ \}' -Because 'the dispatch guard has to come first'
        $script:MetricsSrc | Should -Match '(?s)elseif \(Wait-RdaMetricCall -Handle \$CallHandle -TimeoutSeconds \$CallTimeoutSeconds\).*?finally\s*\{\s*\$Call\.Dispose\(\)\s*\}\s*\}\s*else\s*\{\s*\$TimedOut = \$true\s*\$LastError = \("Timed out after \{0\}s" -f \$CallTimeoutSeconds\).*?\[void\]\$Call\.BeginStop\(\$null, \$null\)\s*\$AbandonedCalls\.Add'
    }
    It 'closes the pool after the last batch without waiting on abandoned calls' {
        $script:MetricsSrc | Should -Match '\[void\]\$MetricCallPool\.BeginClose\(\$null, \$null\)'
        $script:MetricsSrc | Should -Not -Match '\$MetricCallPool\.(Close|Dispose)\(\)' -Because 'both wait for a call that is still blocked'
    }

    It 'Wait-RdaMetricCall returns true as soon as a quick call completes' {
        $P = Start-PoolCall { 'done' }
        try
        {
            $Sw = [System.Diagnostics.Stopwatch]::StartNew()
            Wait-RdaMetricCall -Handle $P.Handle -TimeoutSeconds 30 | Should -BeTrue
            $Sw.Elapsed.TotalSeconds | Should -BeLessThan 10
        }
        finally { $P.Call.Dispose() }
    }
    It 'Wait-RdaMetricCall gives up at the timeout on a call blocked in .NET, and BeginStop does not wait for it' {
        # Thread.Sleep stands in for a network read: a pipeline stop cannot interrupt it.
        $P = Start-PoolCall { [System.Threading.Thread]::Sleep(6000); 'late' }
        $script:Stuck.Add($P)
        $Sw = [System.Diagnostics.Stopwatch]::StartNew()
        Wait-RdaMetricCall -Handle $P.Handle -TimeoutSeconds 1 | Should -BeFalse
        $Waited = $Sw.Elapsed.TotalSeconds
        $Waited | Should -BeGreaterOrEqual 0.9
        $Waited | Should -BeLessThan 3
        $Sw.Restart()
        [void]$P.Call.BeginStop($null, $null)
        $Sw.Elapsed.TotalSeconds | Should -BeLessThan 1 -Because 'a synchronous stop would hold the caller until the blocked call returned'
        $P.Handle.IsCompleted | Should -BeFalse -Because 'the call really was still blocked, so the timeout path was exercised'
    }
    It 'Receive-RdaMetricCall returns one result as the object itself, like assigning Receive-Job output' {
        $P = Start-PoolCall { [pscustomobject]@{ Data = @(1, 2, 3) } }
        try
        {
            $null = Wait-RdaMetricCall -Handle $P.Handle -TimeoutSeconds 30
            $R = Receive-RdaMetricCall -Call $P.Call -Handle $P.Handle
            # Test the variable itself: piping it into Should would unroll a one-item wrapper.
            ($R -is [System.Collections.ICollection]) | Should -BeFalse -Because 'the aggregation reads $MetricQuery.Data off one metric object'
            ($R -is [System.Management.Automation.PSCustomObject]) | Should -BeTrue
            @($R.Data).Count | Should -Be 3
        }
        finally { $P.Call.Dispose() }
    }
    It 'Receive-RdaMetricCall returns $null for no output and an array for several' {
        $P = Start-PoolCall { }
        try
        {
            $null = Wait-RdaMetricCall -Handle $P.Handle -TimeoutSeconds 30
            $R = Receive-RdaMetricCall -Call $P.Call -Handle $P.Handle
            $null -eq $R | Should -BeTrue
        }
        finally { $P.Call.Dispose() }
        $P = Start-PoolCall { 1; 2 }
        try
        {
            $null = Wait-RdaMetricCall -Handle $P.Handle -TimeoutSeconds 30
            $R = Receive-RdaMetricCall -Call $P.Call -Handle $P.Handle
            ($R -is [object[]]) | Should -BeTrue
            $R.Count | Should -Be 2
        }
        finally { $P.Call.Dispose() }
    }
    It 'BeginStop on a call still queued behind a blocked one completes it and frees the slot' {
        # The degraded case: every runspace is held by an abandoned call, so the next attempt queues.
        $Tight = [runspacefactory]::CreateRunspacePool([initialsessionstate]::CreateDefault2())
        [void]$Tight.SetMaxRunspaces(1)
        $Tight.Open()
        $Calls = @()
        try
        {
            $Bodies = @(
                { [System.Threading.Thread]::Sleep(4000); 'blocker' }
                { 'queued' }
                { 'next' }
            )
            foreach ($Body in $Bodies)
            {
                $C = [powershell]::Create()
                $C.RunspacePool = $Tight
                [void]$C.AddScript($Body)
                $Calls += [pscustomobject]@{ Call = $C; Handle = $null }
            }
            $Calls[0].Handle = $Calls[0].Call.BeginInvoke()
            Start-Sleep -Milliseconds 300
            $Calls[1].Handle = $Calls[1].Call.BeginInvoke()
            Wait-RdaMetricCall -Handle $Calls[1].Handle -TimeoutSeconds 1 | Should -BeFalse -Because 'it is queued behind the blocked call'
            [void]$Calls[1].Call.BeginStop($null, $null)
            $Calls[1].Handle.AsyncWaitHandle.WaitOne(2000) | Should -BeTrue -Because 'a queued call that is stopped completes at once'
            $Calls[2].Handle = $Calls[2].Call.BeginInvoke()
            Wait-RdaMetricCall -Handle $Calls[2].Handle -TimeoutSeconds 15 | Should -BeTrue
            (Receive-RdaMetricCall -Call $Calls[2].Call -Handle $Calls[2].Handle) | Should -Be 'next' -Because 'the stopped queued call did not keep the slot'
        }
        finally
        {
            foreach ($Entry in $Calls) { if ($Entry.Handle) { [void]$Entry.Handle.AsyncWaitHandle.WaitOne(10000) }; $Entry.Call.Dispose() }
            $Tight.Close()
            $Tight.Dispose()
        }
    }
    It 'Receive-RdaMetricCall rethrows the error the call raised, not the EndInvoke wrapper' {
        # A cmdlet that writes an error under -ErrorAction Stop, as Get-AzMetric does.
        $Rec = [System.Management.Automation.ErrorRecord]::new([System.InvalidOperationException]::new("Operation returned an invalid status code 'NotFound'"), 'RdaProbe.NotFound', 'ObjectNotFound', $null)
        $P = Start-PoolCall { param($R) function Write-Probe { [CmdletBinding()] param($E) $PSCmdlet.WriteError($E) }; Write-Probe -E $R -ErrorAction Stop } -ArgumentList $Rec
        $null = Wait-RdaMetricCall -Handle $P.Handle -TimeoutSeconds 30
        $Caught = $null
        try { $null = Receive-RdaMetricCall -Call $P.Call -Handle $P.Handle } catch { $Caught = $_ } finally { $P.Call.Dispose() }
        $Caught | Should -Not -BeNullOrEmpty
        $Caught.FullyQualifiedErrorId | Should -Be 'RdaProbe.NotFound,Write-Probe' -Because 'the record keeps the id and command that raised it'
        $Caught.Exception | Should -BeOfType [System.InvalidOperationException]
        $Caught.Exception.Message | Should -Not -Match 'Exception calling "EndInvoke"'
        (Get-RdaMetricFailureClass -Message $Caught.Exception.Message).Outcome | Should -Be 'NotFound'
    }
    It 'keeps the Retry-After header readable through the pool' {
        if (-not $script:RealTypesAvailable) { Set-ItResult -Skipped -Because 'Az.Monitor (Microsoft.Rest types) is not installed here' }
        $Rec = New-ThrottleRecord '17'
        $P = Start-PoolCall { param($R) function Write-Probe { [CmdletBinding()] param($E) $PSCmdlet.WriteError($E) }; Write-Probe -E $R -ErrorAction Stop } -ArgumentList $Rec
        $null = Wait-RdaMetricCall -Handle $P.Handle -TimeoutSeconds 30
        $Caught = $null
        try { $null = Receive-RdaMetricCall -Call $P.Call -Handle $P.Handle } catch { $Caught = $_ } finally { $P.Call.Dispose() }
        $Caught | Should -Not -BeNullOrEmpty
        Get-RdaRetryAfterSeconds -ErrorRecord $Caught | Should -Be 17
        (Get-RdaMetricFailureClass -Message $Caught.Exception.Message).Throttled | Should -BeTrue
    }
}

Describe 'Pool lifecycle - released on every exit, drained per batch, errors surfaced' {
    BeforeAll {
        $script:LifecycleAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $PSScriptRoot -Parent) 'Extension/Metrics.ps1'), [ref]$null, [ref]$null)
    }

    It 'closes the pool in a finally that guards the whole batch loop, not just the normal exit' {
        # The wrapper catches a failed subscription and carries on in the SAME process, so a pool
        # released only where the loop falls through leaves one open pool per failed subscription -
        # precisely when memory is already short, which is the opposite of why pooling exists.
        $Close = @($script:LifecycleAst.FindAll({ param($N) $N -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $N.Member.Extent.Text -eq 'BeginClose' }, $true))
        $Close.Count | Should -Be 1 -Because 'one owner of the pool teardown'

        $Try = $Close[0].Parent
        while ($null -ne $Try -and -not ($Try -is [System.Management.Automation.Language.TryStatementAst])) { $Try = $Try.Parent }
        $Try | Should -Not -BeNullOrEmpty -Because 'the teardown must be in a try/finally, not on the fall-through path'
        $Try.Finally | Should -Not -BeNullOrEmpty
        $Close[0].Extent.StartOffset | Should -BeGreaterOrEqual $Try.Finally.Extent.StartOffset -Because 'it has to be in the finally, not the body'

        $Guarded = @($Try.Body.FindAll({ param($N) $N -is [System.Management.Automation.Language.ForStatementAst] -and $N.Condition.Extent.Text -match 'MetricCount' }, $true))
        $Guarded.Count | Should -Be 1 -Because 'the batch loop is what can throw'
        $Try.Body.Extent.Text | Should -Match 'ForEach-Object -Parallel' -Because 'the parallel dispatch must be inside the guarded region'
    }

    It 'still uses BeginClose, never Close or Dispose, on the pool' {
        # Both wait for a call blocked in a network read.
        $Bad = @($script:LifecycleAst.FindAll({ param($N) $N -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $N.Expression.Extent.Text -eq '$MetricCallPool' -and $N.Member.Extent.Text -in @('Close', 'Dispose') }, $true))
        $Bad.Count | Should -Be 0
    }

    It 'drains the abandoned calls after every batch, not only at phase end' {
        # Draining only at phase end keeps a call abandoned in an early batch, and whatever payload it
        # later received, alive for the rest of the phase.
        $Drain = @($script:LifecycleAst.FindAll({ param($N) $N -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $N.Member.Extent.Text -eq 'TryTake' }, $true))
        $Drain.Count | Should -Be 1 -Because 'the per-batch drain takes completed calls off the bag'

        $Loop = $Drain[0].Parent
        while ($null -ne $Loop -and -not ($Loop -is [System.Management.Automation.Language.LoopStatementAst])) { $Loop = $Loop.Parent }
        $Enclosing = $Loop.Parent
        while ($null -ne $Enclosing -and -not ($Enclosing -is [System.Management.Automation.Language.ForStatementAst] -and $Enclosing.Condition.Extent.Text -match 'MetricCount')) { $Enclosing = $Enclosing.Parent }
        $Enclosing | Should -Not -BeNullOrEmpty -Because 'the drain must sit inside the per-batch loop'
        $script:MetricsSrc | Should -Match 'foreach \(\$Pending in \$StillRunning\) \{ \$MetricAbandonedCalls\.Add\(\$Pending\) \}' -Because 'a call that has not returned yet must go back on the bag'
    }

    It 'surfaces an error left in the call error stream instead of reporting an empty success' {
        # EndInvoke only throws when the call itself terminated. A cmdlet that WROTE an error and
        # produced nothing would otherwise be recorded as a success with a metric value of 0.
        $script:MetricsSrc | Should -Match '\$Call\.HadErrors -and @\(\$Output\)\.Count -eq 0 -and \$Call\.Streams\.Error\.Count -gt 0'
        $script:MetricsSrc | Should -Match 'throw \$Call\.Streams\.Error\[0\]'
    }

    It 'disposes the call and keeps the retry budget when the dispatch itself fails' {
        # A broken or closed pool fails at BeginInvoke, before the call is dispatched: without this the
        # [powershell] leaks and the exception escapes the retry loop, skipping the budget entirely.
        $script:MetricsSrc | Should -Match '(?s)\$CallHandle = \$null\s*\r?\n\s*try\s*\{.*?\$CallHandle = \$Call\.BeginInvoke\(\).*?\}\s*\r?\n\s*catch\s*\{.*?\$Call\.Dispose\(\)'
        $script:MetricsSrc | Should -Match 'if \(\$null -eq \$CallHandle\) \{ \}' -Because 'an undispatched call must not be waited on'
    }

    It 'Receive-RdaMetricCall rethrows a written error as a record the classifier can read' {
        $Fn = $script:LifecycleAst.FindAll({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq 'Receive-RdaMetricCall' }, $true) | Select-Object -First 1
        . ([scriptblock]::Create($Fn.Extent.Text))
        $Pool = [runspacefactory]::CreateRunspacePool([initialsessionstate]::CreateDefault2())
        [void]$Pool.SetMaxRunspaces(2); $Pool.Open()
        try
        {
            $Call = [powershell]::Create(); $Call.RunspacePool = $Pool
            # Writes a non-terminating error and emits nothing: EndInvoke returns empty and does NOT throw.
            [void]$Call.AddScript({ Write-Error "Operation returned an invalid status code 'NotFound'"; })
            $H = $Call.BeginInvoke(); [void]$H.AsyncWaitHandle.WaitOne(30000)
            $Caught = $null
            try { $null = Receive-RdaMetricCall -Call $Call -Handle $H } catch { $Caught = $_ }
            $Caught | Should -Not -BeNullOrEmpty -Because 'an error-stream-only failure must not read as a success'
            (Get-RdaMetricFailureClass -Message $Caught.Exception.Message).Outcome | Should -Be 'NotFound' -Because 'the classifier still has to be able to read it'
            $Call.Dispose()
        }
        finally { $Pool.Close(); $Pool.Dispose() }
    }
}
