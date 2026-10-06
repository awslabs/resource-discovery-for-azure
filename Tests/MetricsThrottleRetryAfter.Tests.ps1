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

    # The per-call profile chooser, the profile map and the phase-start line all live in the phase body,
    # so they are lifted by shape and run against stubs rather than re-implemented here. Lifted without
    # throwing on absence: a test asserts each one is there, so a source that has none of them fails
    # those tests alone instead of taking the whole file down with a container error.
    # Lifted by shape, not by position. Every statement of the metrics phase sits inside one
    # if ($Task -eq 'Processing'), so a match on the text alone also finds that whole-phase block; the
    # condition has to be part of the filter. Lifted without throwing on absence: a test asserts each
    # one is there, so a source that has none of them fails those tests alone instead of taking the
    # whole file down with a container error.
    function Get-PhaseBlock
    {
        param([System.Management.Automation.Language.Ast]$Root, [string]$Condition, [string[]]$Contains)
        $Found = @($Root.FindAll({
                    param($N)
                    if ($N -isnot [System.Management.Automation.Language.IfStatementAst]) { return $false }
                    if ($N.Clauses[0].Item1.Extent.Text -ne $Condition) { return $false }
                    foreach ($Needle in $Contains)
                    {
                        if ($N.Extent.Text.IndexOf($Needle, [System.StringComparison]::Ordinal) -lt 0) { return $false }
                    }
                    return $true
                }, $true))
        if ($Found.Count -ne 1) { return $null }
        return $Found[0]
    }
    $script:CallProfileFnAst = $Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'Get-RdaMetricCallProfile' }, $true) | Select-Object -First 1
    if ($script:CallProfileFnAst) { . ([scriptblock]::Create($script:CallProfileFnAst.Extent.Text)) }
    $script:SubProfileBuild = Get-PhaseBlock -Root $Ast -Condition '$MetricCount -gt 0' -Contains @('$MetricSubProfiles[', 'Get-RdaSubscriptionProfile')

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
        $script:MetricsSrc | Should -Match '(?s)elseif \(Wait-RdaMetricCall -Handle \$CallHandle -TimeoutSeconds \$CallTimeoutSeconds\).*?finally\s*\{\s*\$Call\.Dispose\(\)\s*\}\s*\}\s*else\s*\{\s*\$TimedOut = \$true\s*\$LastError = \("Timed out after \{0\}s" -f \$CallTimeoutSeconds\).*?\[void\]\$Call\.BeginStop\(\$null, \$null\)\s*\$AbandonedCalls\.Add'
    }
    It 'closes the pool after the last batch without waiting on abandoned calls' {
        $script:MetricsSrc | Should -Match '\$PoolCloseHandle = \$MetricCallPool\.BeginClose\(\$null, \$null\)'
        $script:MetricsSrc | Should -Not -Match '\$MetricCallPool\.Close\(\)' -Because 'Close waits for a call that is still blocked'
        # Dispose on an open pool also waits for a blocked call. It is allowed only after BeginClose, and
        # only once the close has finished and the pool reports Closed, i.e. every worker has ended.
        $script:MetricsSrc | Should -Match '(?s)\$PoolCloseHandle = \$MetricCallPool\.BeginClose\(\$null, \$null\).*?if \(\$PoolClosed\)\s*\{\s*\$MetricCallPool\.Dispose\(\)'
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
    It 'closes the pool in a finally that guards the whole batch loop, not just the normal exit' {
        # The wrapper catches a failed subscription and carries on in the SAME process, so a pool
        # released only where the loop falls through leaves one open pool per failed subscription -
        # precisely when memory is already short, which is the opposite of why pooling exists.
        $Close = @($script:Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $N.Member.Extent.Text -eq 'BeginClose' }, $true))
        $Close.Count | Should -Be 1 -Because 'one owner of the pool teardown'

        # Every enclosing try, not merely the nearest one: the teardown itself sits in a try/catch so a
        # teardown failure cannot replace an in-flight exception, and that puts a catch-only try in
        # between. Requiring the teardown to fall INSIDE some enclosing finally's extent, and that same
        # try to own the batch loop, is what a fall-through teardown cannot satisfy.
        $Offset = $Close[0].Extent.StartOffset
        $Ancestors = [System.Collections.Generic.List[object]]::new()
        $Node = $Close[0].Parent
        while ($null -ne $Node)
        {
            if ($Node -is [System.Management.Automation.Language.TryStatementAst]) { $Ancestors.Add($Node) }
            $Node = $Node.Parent
        }
        @($Ancestors).Count | Should -BeGreaterThan 0 -Because 'the teardown must be in a try/finally, not on the fall-through path'

        $Guard = @($Ancestors | Where-Object {
                $null -ne $_.Finally -and
                $Offset -ge $_.Finally.Extent.StartOffset -and $Offset -lt $_.Finally.Extent.EndOffset
            })
        $Guard.Count | Should -Be 1 -Because 'exactly one enclosing finally owns the teardown'
        $Guarded = @($Guard[0].Body.FindAll({ param($N) $N -is [System.Management.Automation.Language.ForStatementAst] -and $N.Condition.Extent.Text -match 'MetricCount' }, $true))
        $Guarded.Count | Should -Be 1 -Because 'the batch loop is what can throw'
        $Guard[0].Body.Extent.Text | Should -Match 'ForEach-Object -Parallel' -Because 'the parallel dispatch must be inside the guarded region'

        # The teardown is itself shielded. On the throw path an exception is already in flight, and it
        # may be the out-of-memory this pooling exists to survive: a failure while disposing a call or
        # closing a broken pool must not replace the exception the operator needs to see.
        $Shield = @($Guard[0].Finally.FindAll({ param($N) $N -is [System.Management.Automation.Language.TryStatementAst] -and $N.CatchClauses.Count -ge 1 }, $true))
        $Shield.Count | Should -Be 1 -Because 'the teardown itself must be guarded against masking an in-flight exception'
        $Offset | Should -BeGreaterOrEqual $Shield[0].Body.Extent.StartOffset -Because 'the teardown has to be inside that shield'
        $Offset | Should -BeLessThan $Shield[0].Body.Extent.EndOffset

        # Closing the pool is what releases the runspaces; the disposal walk is bookkeeping. The close
        # must come first, or a throw in the walk is what skips it, swallowed by the shield's catch.
        $Walk = @($Shield[0].Body.FindAll({ param($N) $N -is [System.Management.Automation.Language.ForEachStatementAst] -and $N.Condition.Extent.Text -eq '$MetricAbandonedCalls' }, $true))
        $Walk.Count | Should -Be 1
        $Offset | Should -BeLessThan $Walk[0].Extent.StartOffset -Because 'the pool is closed before the best-effort disposal walk'

        # Write-Verbose is discarded at the default preference, which would lose the one trace that a
        # teardown failure - and so a leaked pool - ever happened.
        # On the commands, not the text: a comment naming the rejected channel would satisfy a text match.
        $Logged = @($Shield[0].CatchClauses[0].Body.FindAll({ param($N) $N -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() })
        $Logged | Should -Contain 'Write-MetricsDiag' -Because 'the teardown failure has to reach the debug log'
        $Logged | Should -Not -Contain 'Write-Verbose' -Because 'Write-Verbose is discarded at the default preference, losing the only trace of a leaked pool'
    }

    It 'still uses BeginClose, never Close, and disposes the pool only once every worker has ended, the pool is broken and has none, or it never opened' {
        # Close waits for a call blocked in a network read, and so does Dispose on a pool still open.
        # A Broken pool cannot be closed and has no running call, so it is the one that reaches Dispose without a close.
        # A pool whose Open() threw never ran a call either, and it has to be disposed or its cleanup timer
        # keeps it, and a runspace holding the Az modules, registered for the life of the process.
        $Bad = @($script:Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $N.Expression.Extent.Text -eq '$MetricCallPool' -and $N.Member.Extent.Text -eq 'Close' }, $true))
        $Bad.Count | Should -Be 0
        $Dispose = @($script:Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $N.Expression.Extent.Text -eq '$MetricCallPool' -and $N.Member.Extent.Text -eq 'Dispose' }, $true))
        $Dispose.Count | Should -Be 2 -Because 'one place releases the pool at the end of the phase, and one disposes a pool that never served a call'

        # The open-failure disposal has to sit in the catch of the try that opens the pool, so it can only
        # ever run on a pool that never reached Opened.
        $OpenTry = @($script:Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.TryStatementAst] -and $N.Body.Extent.Text -match '\$MetricCallPool\.Open\(\)' }, $true))
        $OpenTry.Count | Should -Be 1 -Because 'a failed Open() outside a try leaves a Broken pool undisposed'
        $OnOpenFailure = @($Dispose | Where-Object { $_.Extent.StartOffset -ge $OpenTry[0].CatchClauses[0].Body.Extent.StartOffset -and $_.Extent.EndOffset -le $OpenTry[0].CatchClauses[0].Body.Extent.EndOffset })
        $OnOpenFailure.Count | Should -Be 1

        # The teardown disposal: its nearest enclosing if must test the proof, and the proof must require a
        # finished close on a pool that reports Closed, with the pool idle and no abandoned call still running.
        $Teardown = @($Dispose | Where-Object { $_.Extent.StartOffset -gt $OpenTry[0].Extent.EndOffset })
        $Teardown.Count | Should -Be 1
        $Node = $Teardown[0].Parent
        while ($null -ne $Node -and $Node -isnot [System.Management.Automation.Language.IfStatementAst]) { $Node = $Node.Parent }
        $Node | Should -Not -BeNullOrEmpty
        $Node.Clauses[0].Item1.Extent.Text | Should -Be '$PoolClosed'
        $script:MetricsSrc | Should -Match '(?s)if \(\$PoolIdle -and \$MetricAbandonedRunning -eq 0 -and \$null -ne \$PoolCloseHandle\)\s*\{\s*\$PoolClosed = \$PoolCloseHandle\.AsyncWaitHandle\.WaitOne\(\$PoolCloseRemainingMs\) -and \$MetricCallPool\.RunspacePoolStateInfo\.State -eq \[System\.Management\.Automation\.Runspaces\.RunspacePoolState\]::Closed'
        $script:MetricsSrc | Should -Match '\$PoolIdle = \(\$MetricCallPool\.GetAvailableRunspaces\(\) -eq \$MetricCallPool\.GetMaxRunspaces\(\)\)'
        $script:MetricsSrc | Should -Match 'elseif \(\$PoolBroken -and \$MetricAbandonedRunning -eq 0\)' -Because 'the broken-pool branch has to check the abandoned count its comment claims is zero'
    }

    It 'drains the abandoned calls after every batch, not only at phase end' {
        # Draining only at phase end keeps a call abandoned in an early batch, and whatever payload it
        # later received, alive for the rest of the phase.
        $Drain = @($script:Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $N.Member.Extent.Text -eq 'TryTake' }, $true))
        $Drain.Count | Should -Be 1 -Because 'the per-batch drain takes completed calls off the bag'

        $Loop = $Drain[0].Parent
        while ($null -ne $Loop -and -not ($Loop -is [System.Management.Automation.Language.LoopStatementAst])) { $Loop = $Loop.Parent }
        $Enclosing = $Loop.Parent
        while ($null -ne $Enclosing -and -not ($Enclosing -is [System.Management.Automation.Language.ForStatementAst] -and $Enclosing.Condition.Extent.Text -match 'MetricCount')) { $Enclosing = $Enclosing.Parent }
        $Enclosing | Should -Not -BeNullOrEmpty -Because 'the drain must sit inside the per-batch loop'
        $ReAdd = @($script:Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.ForEachStatementAst] -and $N.Condition.Extent.Text -eq '$StillRunning' }, $true))
        $ReAdd.Count | Should -Be 1 -Because 'a call that has not returned yet must go back on the bag'
        $ReAdd[0].Body.Extent.Text | Should -Match '\$MetricAbandonedCalls\.Add\(\$Pending\)'
    }

    It 'counts every abandoned call, not just the ones still outstanding at phase end' {
        # The per-batch drain takes a RETURNED call off the bag, so the bag's size at phase end is what
        # is still running, not how many were ever abandoned. Reading the reported total from the bag
        # alone made the diagnostic under-report, usually to zero, precisely when it was needed. This
        # runs the real drain bytes rather than mirroring them, so the accounting itself is under test.
        $DrainTry = @($script:Ast.FindAll({ param($N)
                    $N -is [System.Management.Automation.Language.TryStatementAst] -and
                    @($N.Body.Statements | Where-Object {
                            $_ -is [System.Management.Automation.Language.WhileStatementAst] -and
                            $_.Condition.Extent.Text -match 'TryTake'
                        }).Count -eq 1 }, $true))
        $DrainTry.Count | Should -Be 1 -Because 'one owner of the per-batch drain'
        $DrainTry[0].Finally | Should -Not -BeNullOrEmpty -Because 'a call taken off the bag must go back even if the loop throws'

        $Init = @($script:Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.AssignmentStatementAst] -and $N.Left.Extent.Text -in @('$StillRunning', '$Drained') }, $true))
        $Init.Count | Should -Be 2 -Because 'the drain sets up exactly its list and its out-variable'
        $Total = @($script:Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.AssignmentStatementAst] -and $N.Left.Extent.Text -eq '$MetricAbandonedCount' -and $N.Right.Extent.Text -match 'MetricAbandonedCalls' }, $true))
        $Total.Count | Should -Be 1 -Because 'one owner of the reported total'

        $Disposed = [System.Collections.Generic.List[string]]::new()
        $MetricAbandonedCalls = [System.Collections.Concurrent.ConcurrentBag[psobject]]::new()
        # Two of the completed entries are ADJACENT on purpose. A forward walk that removes as it goes
        # skips the item shifted into the vacated index, and an alternating fixture would not notice.
        foreach ($Spec in @(@('a', $true), @('b', $true), @('c', $false), @('d', $true), @('e', $false)))
        {
            $Fake = [pscustomobject]@{ Id = $Spec[0] }
            $Fake | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $Disposed.Add($this.Id) }.GetNewClosure()
            $MetricAbandonedCalls.Add([pscustomobject]@{ Handle = [pscustomobject]@{ IsCompleted = $Spec[1] }; Call = $Fake })
        }
        $MetricAbandonedDrained = 0
        $Bytes = ($Init | ForEach-Object { $_.Extent.Text }) -join [Environment]::NewLine
        . ([scriptblock]::Create(($Bytes, $DrainTry[0].Extent.Text, $Total[0].Extent.Text) -join [Environment]::NewLine))

        @($Disposed | Sort-Object) | Should -Be @('a', 'b', 'd') -Because 'only the calls that had already returned are released, every one of them'
        $MetricAbandonedDrained | Should -Be 3 -Because 'the drain has to remember what it released'
        $MetricAbandonedCalls.Count | Should -Be 2 -Because 'the two that had not returned go back on the bag'
        $MetricAbandonedCount | Should -Be 5 -Because 'the reported total is every call that was abandoned, drained ones included'
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
        # Asserted on the AST rather than source text: a '(?s).*?' reaching for $Call.Dispose() runs
        # past this catch and matches the wait branch's finally, so deleting the dispose that this test
        # exists to protect would still pass.
        $Dispatch = @($script:Ast.FindAll({ param($N)
                    $N -is [System.Management.Automation.Language.TryStatementAst] -and
                    @($N.Body.Statements | Where-Object {
                            $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                            $_.Left.Extent.Text -eq '$CallHandle' -and $_.Right.Extent.Text -match 'BeginInvoke'
                        }).Count -eq 1 }, $true))
        $Dispatch.Count | Should -Be 1 -Because 'one guarded dispatch'
        $Catch = $Dispatch[0].CatchClauses[0]
        $Catch | Should -Not -BeNullOrEmpty -Because 'the dispatch must have a catch, or the exception escapes the retry loop'
        @($Catch.Body.FindAll({ param($N) $N -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $N.Expression.Extent.Text -eq '$Call' -and $N.Member.Extent.Text -eq 'Dispose' }, $true)).Count |
            Should -Be 1 -Because 'an undispatched [powershell] must not leak'
        @($Catch.Body.FindAll({ param($N) $N -is [System.Management.Automation.Language.ThrowStatementAst] }, $true)).Count |
            Should -Be 0 -Because 'rethrowing here would skip the retry budget entirely'
        $Catch.Body.Extent.Text | Should -Match '\$Permanent = \$true' -Because 'a pool that cannot dispatch does not recover inside this phase, so retrying only spends the backoff'
        $Bucket = @($Catch.Body.FindAll({ param($N) $N -is [System.Management.Automation.Language.AssignmentStatementAst] -and $N.Left.Extent.Text -eq '$PermanentOutcome' }, $true))
        $Bucket.Count | Should -Be 1
        $Bucket[0].Right.Extent.Text | Should -Be "'Error'" -Because 'a local dispatch fault must not be bucketed by what its message happens to say, or it reads as an Azure access failure'
        $Catch.Body.Extent.Text | Should -Not -Match 'Get-RdaMetricFailureClass' -Because 'the bucket is no longer derived from the message here'

        # The guard and the wait have to be clauses of the SAME chain, guard first. Two independent
        # text pins could not tell that apart from a guard sitting on an unrelated if.
        $Chain = @($script:Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.IfStatementAst] -and $N.Clauses.Count -ge 2 -and $N.Clauses[0].Item1.Extent.Text -eq '$null -eq $CallHandle' }, $true))
        $Chain.Count | Should -Be 1 -Because 'the dispatch guard heads exactly one chain'
        @($Chain[0].Clauses[0].Item2.Statements).Count | Should -Be 0 -Because 'an undispatched call must not be waited on, and there is nothing else to do for it'
        $Chain[0].Clauses[1].Item1.Extent.Text | Should -Match '^Wait-RdaMetricCall ' -Because 'the wait is the next clause, so it is reached only when the call was dispatched'
    }

    It 'Receive-RdaMetricCall rethrows a written error as a record the classifier can read' {
        $Fn = $script:Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq 'Receive-RdaMetricCall' }, $true) | Select-Object -First 1
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

Describe 'Az context - converted once in the main session, not per call in each worker' {
    # Get-AzMetric -DefaultProfile is typed IAzureContextContainer. Passing the raw PSAzureContext
    # made every pool worker convert it at binding, and that conversion intermittently failed
    # ('Cannot convert PSAzureContext to IAzureContextContainer') once the process had seen many Az
    # runspaces. The phase now converts once, before dispatch, and keeps the raw context on failure.
    BeforeAll {
        $script:ConvAst = $script:Ast.FindAll({
                $args[0] -is [System.Management.Automation.Language.IfStatementAst] -and
                $args[0].Clauses[0].Item1.Extent.Text -eq '$null -ne $MetricAzContext' -and
                $args[0].Extent.Text -match 'IAzureContextContainer'
            }, $true) | Select-Object -First 1
        if (Get-Module -ListAvailable -Name Az.Accounts) { Import-Module Az.Accounts -ErrorAction Stop }
        $script:ContainerType = 'Microsoft.Azure.Commands.Common.Authentication.Abstractions.Core.IAzureContextContainer'

        function Invoke-ContextConversion($Context)
        {
            $script:Diag = [System.Collections.Generic.List[string]]::new()
            function Write-MetricsDiag([string]$Message) { $script:Diag.Add($Message) }
            $MetricAzContext = $Context
            . ([scriptblock]::Create($script:ConvAst.Extent.Text))
            $MetricAzContext
        }
    }

    It 'converts the context before the batches are dispatched' {
        $script:ConvAst | Should -Not -BeNullOrEmpty
        $UseAt = $script:MetricsSrc.IndexOf('$using:MetricAzContext')
        $UseAt | Should -BeGreaterThan 0
        $script:ConvAst.Extent.StartOffset | Should -BeLessThan $UseAt
    }

    It 'hands the workers an IAzureContextContainer, which a fresh runspace binds as-is' -Skip:($null -eq (Get-Module -ListAvailable -Name Az.Accounts)) {
        $Raw = [Microsoft.Azure.Commands.Profile.Models.Core.PSAzureContext]::new()
        $Converted = Invoke-ContextConversion $Raw
        ($Converted -is ($script:ContainerType -as [type])) | Should -BeTrue
        $script:Diag.Count | Should -Be 0

        $Rs = [runspacefactory]::CreateRunspace([initialsessionstate]::CreateDefault2())
        $Rs.Open()
        try
        {
            $P = [powershell]::Create()
            $P.Runspace = $Rs
            [void]$P.AddCommand('Get-AzContext').AddParameter('DefaultProfile', $Converted).AddParameter('ErrorAction', 'Stop')
            [void]$P.Invoke()
            $P.HadErrors | Should -BeFalse
            $P.Dispose()
        }
        finally { $Rs.Dispose() }
    }

    It 'keeps the raw context and logs a WARNING when the conversion fails' -Skip:($null -eq (Get-Module -ListAvailable -Name Az.Accounts)) {
        $Unconvertible = [pscustomobject]@{ Name = 'not-a-context' }
        $Result = Invoke-ContextConversion $Unconvertible
        $Result | Should -Be $Unconvertible
        $script:Diag.Count | Should -Be 1
        $script:Diag[0] | Should -Match '^WARNING: could not convert the Az context'
    }
}

Describe 'Initialize-RdaMetricsBatchPrereq checks the Microsoft.Insights provider on the subscription being inventoried' {
    # Get-AzResourceProvider and Register-AzResourceProvider act on a subscription. Without a profile they use the
    # process's current one, which need not be the subscription of the run (no phase moves the process context),
    # so every call passes that subscription's own profile. The registrations all start before any of them is
    # waited for, against one shared deadline.
    BeforeAll {
        $PrereqAst = $script:Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'Initialize-RdaMetricsBatchPrereq' }, $true) | Select-Object -First 1
        if (-not $PrereqAst) { throw 'Initialize-RdaMetricsBatchPrereq was not found in Extension/Metrics.ps1' }
        $script:PrereqAst = $PrereqAst
        . ([scriptblock]::Create($PrereqAst.Extent.Text))
        function Write-MetricsDiag { param($Message) $script:PrereqDiag.Add([string]$Message) }
        function Get-RdaSubscriptionProfile { param([string]$SubscriptionId) if ($SubscriptionId -eq 'broken') { throw 'no profile' } "profile-for-$SubscriptionId" }
        function Get-AzResourceProvider
        {
            param($ProviderNamespace, $DefaultProfile, $ErrorAction)
            $script:PrereqCalls.Add(('Get:{0}' -f $DefaultProfile))
            $Key = [string]$DefaultProfile
            $State = if ($script:PrereqStates.ContainsKey($Key)) { $script:PrereqStates[$Key] } else { $script:PrereqState }
            [pscustomobject]@{ RegistrationState = $State }
        }
        function Register-AzResourceProvider
        {
            param($ProviderNamespace, $DefaultProfile, $ErrorAction)
            $script:PrereqCalls.Add(('Register:{0}' -f $DefaultProfile))
            if ($script:PrereqRegisterFails -contains [string]$DefaultProfile) { throw 'the registration was refused' }
            $script:PrereqStates[[string]$DefaultProfile] = 'Registered'
        }
    }

    BeforeEach {
        $script:PrereqCalls = [System.Collections.Generic.List[string]]::new()
        $script:PrereqDiag = [System.Collections.Generic.List[string]]::new()
        $script:PrereqState = 'Registered'
        $script:PrereqStates = @{}
        $script:PrereqRegisterFails = @()
        Mock Start-Sleep { }
    }

    It 'looks the provider up through the profile of the subscription it was given' {
        Initialize-RdaMetricsBatchPrereq -SubscriptionId 'sub-a'
        @($script:PrereqCalls) | Should -Be @('Get:profile-for-sub-a')
    }

    It 'registers the provider on that subscription when it is not registered' {
        $script:PrereqState = 'NotRegistered'
        Initialize-RdaMetricsBatchPrereq -SubscriptionId 'sub-a'
        @($script:PrereqCalls | Where-Object { $_ -like 'Register:*' }) | Should -Be @('Register:profile-for-sub-a')
    }

    It 'polls and registers through the same profile, in the order look up, register, look up again' {
        $script:PrereqState = 'NotRegistered'
        Initialize-RdaMetricsBatchPrereq -SubscriptionId 'sub-a'
        @($script:PrereqCalls) | Should -Be @('Get:profile-for-sub-a', 'Register:profile-for-sub-a', 'Get:profile-for-sub-a') -Because 'a polling call without the profile would read the provider state of the process''s current subscription'
    }

    It 'checks a subscription once when its ids differ only in case, and skips an id with no subscription segment' {
        $Assign = @($script:Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.AssignmentStatementAst] -and $N.Left.Extent.Text -eq '$BatchSubscriptionIds' }, $true))
        $Assign.Count | Should -Be 1
        Set-Variable -Name BatchGroups -Value ([ordered]@{
                VirtualMachines = [System.Collections.Generic.List[object]]@(
                    [pscustomobject]@{ Id = '/subscriptions/AAAA-1/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1' },
                    [pscustomobject]@{ Id = '/subscriptions/aaaa-1/resourceGroups/rg2/providers/Microsoft.Compute/virtualMachines/vm2' })
                Sql             = [System.Collections.Generic.List[object]]@(
                    [pscustomobject]@{ Id = '/subscriptions/BBBB-2/resourceGroups/rg/providers/Microsoft.Sql/servers/s1/databases/d1' },
                    [pscustomobject]@{ Id = 'not-an-arm-id' })
            })
        $Ids = @(. ([scriptblock]::Create($Assign[0].Right.Extent.Text)))
        @($Ids | Sort-Object) | Should -Be @('aaaa-1', 'bbbb-2')
    }

    It 'makes no provider call, and says which subscription it skipped, when the profile cannot be built' {
        Initialize-RdaMetricsBatchPrereq -SubscriptionId 'broken'
        $script:PrereqCalls.Count | Should -Be 0
        @($script:PrereqDiag | Where-Object { $_ -like '*broken*' }).Count | Should -BeGreaterThan 0 -Because 'the operator has to be able to see which subscription was skipped'
    }

    It 'names the subscription in the remediation hint, because Register-AzResourceProvider has no subscription parameter' {
        Initialize-RdaMetricsBatchPrereq -SubscriptionId 'broken'
        @($script:PrereqDiag | Where-Object { $_ -like '*register the provider on subscription broken: select that subscription, then run Register-AzResourceProvider*' }).Count | Should -Be 1 -Because 'the cmdlet acts on the admin session''s current subscription, so a bare command repeats the bug this function fixes'
    }

    It 'leaves the other subscriptions alone when one of them has no profile' {
        Initialize-RdaMetricsBatchPrereq -SubscriptionId @('sub-a', 'broken', 'sub-b')
        @($script:PrereqCalls) | Should -Be @('Get:profile-for-sub-a', 'Get:profile-for-sub-b')
        @($script:PrereqDiag | Where-Object { $_ -like '*could not ensure*broken*' }).Count | Should -Be 1
    }

    It 'starts the registration of every subscription that needs it before waiting for any of them' {
        $script:PrereqState = 'NotRegistered'
        Initialize-RdaMetricsBatchPrereq -SubscriptionId @('sub-a', 'sub-b')
        $Order = @($script:PrereqCalls)
        $Order[0..3] | Should -Be @('Get:profile-for-sub-a', 'Register:profile-for-sub-a', 'Get:profile-for-sub-b', 'Register:profile-for-sub-b') -Because 'a wait between the registrations is what made N unregistered subscriptions cost N waits'
        @($Order[4..($Order.Count - 1)] | Sort-Object) | Should -Be @('Get:profile-for-sub-a', 'Get:profile-for-sub-b') -Because 'both are polled in the same round'
    }

    It 'sleeps once for several unregistered subscriptions, not once each' {
        $script:PrereqState = 'NotRegistered'
        Initialize-RdaMetricsBatchPrereq -SubscriptionId @('sub-a', 'sub-b', 'sub-c')
        Should -Invoke Start-Sleep -Times 1 -Exactly -Because 'one shared deadline and one sleep per round means three unregistered subscriptions cost one wait'
        @($script:PrereqDiag | Where-Object { $_ -like '*registration state on subscription*after wait: Registered' }).Count | Should -Be 3 -Because 'each subscription still reports its own result'
    }

    It 'reports a subscription whose registration never completes without holding up the others' {
        $script:PrereqState = 'NotRegistered'
        $script:PrereqRegisterFails = @('profile-for-sub-b')
        Initialize-RdaMetricsBatchPrereq -SubscriptionId @('sub-a', 'sub-b')
        @($script:PrereqDiag | Where-Object { $_ -like '*could not ensure*sub-b*the registration was refused*' }).Count | Should -Be 1
        @($script:PrereqDiag | Where-Object { $_ -like '*subscription sub-a after wait: Registered' }).Count | Should -Be 1 -Because 'one failing subscription never skips the others'
    }

    It 'is given every subscription that has metric definitions to batch, in one call' {
        $Calls = @($script:Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.CommandAst] -and $N.GetCommandName() -eq 'Initialize-RdaMetricsBatchPrereq' }, $true) |
                Where-Object { $_.Extent.StartOffset -lt $script:PrereqAst.Extent.StartOffset -or $_.Extent.StartOffset -gt $script:PrereqAst.Extent.EndOffset })
        $Calls.Count | Should -Be 1
        $Named = @($Calls[0].CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } | ForEach-Object { $_.ParameterName })
        $Named | Should -Contain 'SubscriptionId'
        @($Calls[0].CommandElements | ForEach-Object { $_.Extent.Text }) | Should -Contain '$BatchSubscriptionIds' -Because 'the whole de-duplicated list goes in, so the registrations start before any wait'
        $InLoop = $false
        for ($Node = $Calls[0].Parent; $null -ne $Node; $Node = $Node.Parent)
        {
            if ($Node -is [System.Management.Automation.Language.ForEachStatementAst]) { $InLoop = $true; break }
        }
        $InLoop | Should -BeFalse -Because 'a call per subscription is what serialised the waits'
    }

    It 'waits against one deadline taken before the first poll' {
        $Deadlines = @($script:PrereqAst.FindAll({ param($N) $N -is [System.Management.Automation.Language.AssignmentStatementAst] -and $N.Left.Extent.Text -eq '$Deadline' }, $true))
        $Deadlines.Count | Should -Be 1 -Because 'a deadline per subscription is a wait per subscription'
        $Sleeps = @($script:PrereqAst.FindAll({ param($N) $N -is [System.Management.Automation.Language.CommandAst] -and $N.GetCommandName() -eq 'Start-Sleep' }, $true))
        $Sleeps.Count | Should -Be 1
        $Deadlines[0].Extent.StartOffset | Should -BeLessThan $Sleeps[0].Extent.StartOffset
    }
}

Describe 'Invoke-RdaMetricsBatch keeps what it fetched when a group or a chunk fails' {
    # A throw in any group or chunk used to leave the function with nothing, and the call site then sent
    # every definition of the service to the per-call path: one bad region turned thousands of batched
    # definitions into thousands of Get-AzMetric calls.
    BeforeAll {
        $BatchAst = $script:Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'Invoke-RdaMetricsBatch' }, $true) | Select-Object -First 1
        if (-not $BatchAst) { throw 'Invoke-RdaMetricsBatch was not found in Extension/Metrics.ps1' }
        . ([scriptblock]::Create($BatchAst.Extent.Text))
        function Write-MetricsDiag { param($Message) $script:BatchDiag.Add([string]$Message) }
        function New-RdaMetricObject { param($Def, $MetricResult) [pscustomobject]@{ ID = $Def.Id; Metric = $Def.MetricName } }
        function Get-AzAccessToken
        {
            param($ResourceUrl, $DefaultProfile, $WarningAction)
            $script:BatchTokens.Add([string]$DefaultProfile)
            if ($script:BatchTokenFails) { throw 'the token could not be minted' }
            [pscustomobject]@{ Token = 'token'; ExpiresOn = [DateTimeOffset]::UtcNow.AddMinutes($script:BatchTokenMinutes) }
        }
        function Get-RdaSubscriptionProfile
        {
            param([string]$SubscriptionId)
            $script:BatchProfileLookups.Add([string]$SubscriptionId)
            if ($SubscriptionId -eq 'sub-broken') { throw ('subscription {0} is not visible to the signed-in identity' -f $SubscriptionId) }
            ('profile-for-{0}' -f $SubscriptionId)
        }

        function New-BatchDef
        {
            param([string]$Sub, [string]$Region, [int]$Index)
            [pscustomobject]@{
                Id = ('/subscriptions/{0}/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm{1}' -f $Sub, $Index)
                MetricName = 'Percentage CPU'; Aggregation = 'Average'; Location = $Region
                Interval = '01:00:00'; StartTime = '2026-10-01T00:00:00Z'; EndTime = '2026-10-02T00:00:00Z'
            }
        }
    }

    BeforeEach {
        $script:BatchDiag = [System.Collections.Generic.List[string]]::new()
        $script:BatchPosts = [System.Collections.Generic.List[string]]::new()
        $script:BatchFailOn = @()
        $script:BatchTokenFails = $false
        $script:BatchTokens = [System.Collections.Generic.List[string]]::new()
        $script:BatchProfileLookups = [System.Collections.Generic.List[string]]::new()
        $script:BatchTokenMinutes = 60
        $script:MetricsBatchHttpCalls = 0
        $script:MetricsBatchLastError = $null
        Mock Invoke-RestMethod {
            $script:BatchPosts.Add([string]$Uri)
            $Ids = @((ConvertFrom-Json $Body).resourceids)
            foreach ($Pattern in $script:BatchFailOn)
            {
                if ($Uri -like $Pattern -or @($Ids | Where-Object { $_ -like $Pattern }).Count -gt 0) { throw ('getBatch refused the request: {0}' -f $Pattern) }
            }
            [pscustomobject]@{ values = @($Ids | ForEach-Object { [pscustomobject]@{ resourceid = $_; value = @([pscustomobject]@{ name = [pscustomobject]@{ value = 'Percentage CPU' } }) } }) }
        }
    }

    It 'returns the records of the regions that worked when one region fails' {
        $Defs = @((New-BatchDef -Sub 'sub-a' -Region 'westeurope' -Index 1), (New-BatchDef -Sub 'sub-a' -Region 'westeurope' -Index 2), (New-BatchDef -Sub 'sub-a' -Region 'eastus' -Index 3))
        $script:BatchFailOn = @('*eastus*')
        $Records = @(Invoke-RdaMetricsBatch -Defs $Defs -MetricNamespace 'microsoft.compute/virtualMachines')
        @($Records | ForEach-Object { $_.ID }) | Should -Be @($Defs[0].Id, $Defs[1].Id) -Because 'the region that answered must not be thrown away with the one that did not'
        @($script:BatchDiag | Where-Object { $_ -like 'WARNING: metrics batch chunk skipped for subscription sub-a region eastus*' }).Count | Should -Be 1
        $script:MetricsBatchLastError | Should -BeLike '*getBatch refused the request*'
    }

    It 'returns the records of the chunks that worked when one chunk fails, and names the chunk' {
        $Defs = @(1..60 | ForEach-Object { New-BatchDef -Sub 'sub-a' -Region 'westeurope' -Index $_ })
        $script:BatchFailOn = @('*/virtualMachines/vm55')
        $Records = @(Invoke-RdaMetricsBatch -Defs $Defs -MetricNamespace 'microsoft.compute/virtualMachines')
        $script:BatchPosts.Count | Should -Be 2 -Because '60 resources are two chunks of at most 50'
        $Records.Count | Should -Be 50 -Because 'the chunk that answered keeps its records'
        @($script:BatchDiag | Where-Object { $_ -like '*resource 51-60 of 60*' }).Count | Should -Be 1 -Because 'the operator has to be able to see which resources were not batched'
    }

    It 'counts a POST that threw as an API call issued' {
        $Defs = @((New-BatchDef -Sub 'sub-a' -Region 'westeurope' -Index 1))
        $script:BatchFailOn = @('*westeurope*')
        $null = Invoke-RdaMetricsBatch -Defs $Defs -MetricNamespace 'microsoft.compute/virtualMachines'
        $script:BatchPosts.Count | Should -Be 1
        $script:MetricsBatchHttpCalls | Should -Be 1 -Because 'a request that reached the service and failed still counts against the metric-query meter'
    }

    It 'skips a group with no subscription segment and still batches the rest' {
        $Bad = New-BatchDef -Sub 'sub-a' -Region 'westeurope' -Index 9
        $Bad.Id = 'not-an-arm-id'
        $Defs = @((New-BatchDef -Sub 'sub-a' -Region 'westeurope' -Index 1), $Bad)
        $Records = @(Invoke-RdaMetricsBatch -Defs $Defs -MetricNamespace 'microsoft.compute/virtualMachines')
        @($Records | ForEach-Object { $_.ID }) | Should -Be @($Defs[0].Id)
        @($script:BatchDiag | Where-Object { $_ -like 'WARNING: metrics batch group skipped: cannot derive subscription/region*' }).Count | Should -Be 1
    }

    It 'lets a failing token for one group leave the other groups alone' {
        $Defs = @((New-BatchDef -Sub 'sub-a' -Region 'westeurope' -Index 1), (New-BatchDef -Sub 'sub-a' -Region 'eastus' -Index 2))
        $script:BatchTokenFails = $true
        $Records = @(Invoke-RdaMetricsBatch -Defs $Defs -MetricNamespace 'microsoft.compute/virtualMachines')
        $Records.Count | Should -Be 0
        @($script:BatchDiag | Where-Object { $_ -like 'WARNING: metrics batch group skipped for subscription sub-a region *(the token could not be minted)*' }).Count | Should -Be 2 -Because 'each group reports its own failure instead of one throw ending the function'
    }

    It 'mints the token through the profile of the subscription the resources live in' {
        $Defs = @((New-BatchDef -Sub 'sub-a' -Region 'westeurope' -Index 1), (New-BatchDef -Sub 'sub-b' -Region 'westeurope' -Index 2))
        $null = Invoke-RdaMetricsBatch -Defs $Defs -MetricNamespace 'microsoft.compute/virtualMachines'
        @($script:BatchTokens | Sort-Object) | Should -Be @('profile-for-sub-a', 'profile-for-sub-b') -Because 'without a profile the token is minted for the tenant the process happens to be signed in to, and the metrics data plane rejects it for a subscription homed elsewhere'
    }

    It 'builds one profile per subscription, not one per group or chunk' {
        $Defs = @(
            (New-BatchDef -Sub 'sub-a' -Region 'westeurope' -Index 1)
            (New-BatchDef -Sub 'sub-a' -Region 'eastus' -Index 2)
            (New-BatchDef -Sub 'sub-a' -Region 'northeurope' -Index 3)
            (New-BatchDef -Sub 'sub-b' -Region 'westeurope' -Index 4))
        $null = Invoke-RdaMetricsBatch -Defs $Defs -MetricNamespace 'microsoft.compute/virtualMachines'
        @($script:BatchProfileLookups | Sort-Object) | Should -Be @('sub-a', 'sub-b') -Because 'the lookup costs two Get-AzSubscription calls, and sub-a has three groups'
        $script:BatchTokens.Count | Should -Be 4 -Because 'the profile is cached, the token is still minted per group'
    }

    It 'refreshes an expiring token through the same subscription profile' {
        $Defs = @(1..60 | ForEach-Object { New-BatchDef -Sub 'sub-a' -Region 'westeurope' -Index $_ })
        $script:BatchTokenMinutes = 1
        $Records = @(Invoke-RdaMetricsBatch -Defs $Defs -MetricNamespace 'microsoft.compute/virtualMachines')
        $Records.Count | Should -Be 60
        $script:BatchTokens.Count | Should -Be 3 -Because 'the group token plus one refresh at each of the two chunks'
        @($script:BatchTokens | Select-Object -Unique) | Should -Be @('profile-for-sub-a') -Because 'a refresh without the profile would swap in a token for the process tenant halfway through'
    }

    It 'skips only the groups of a subscription whose profile cannot be built' {
        $Defs = @(
            (New-BatchDef -Sub 'sub-a' -Region 'westeurope' -Index 1)
            (New-BatchDef -Sub 'sub-broken' -Region 'westeurope' -Index 2)
            (New-BatchDef -Sub 'sub-broken' -Region 'eastus' -Index 3))
        $Records = @(Invoke-RdaMetricsBatch -Defs $Defs -MetricNamespace 'microsoft.compute/virtualMachines')
        @($Records | ForEach-Object { $_.ID }) | Should -Be @($Defs[0].Id)
        @($script:BatchDiag | Where-Object { $_ -like 'WARNING: metrics batch group skipped for subscription sub-broken*is not visible*' }).Count | Should -Be 2
        @($script:BatchTokens) | Should -Be @('profile-for-sub-a') -Because 'no token is minted for a subscription whose profile could not be built'
    }

    It 'passes the profile through the parameter the installed Az.Accounts really has' -Skip:($null -eq (Get-Module -ListAvailable -Name Az.Accounts)) {
        Import-Module Az.Accounts -ErrorAction Stop
        $Real = Get-Command Get-AzAccessToken -Module Az.Accounts
        $Real.Parameters.Keys | Should -Contain 'DefaultProfile'
        $Real.Parameters['DefaultProfile'].ParameterType.FullName | Should -Be 'Microsoft.Azure.Commands.Common.Authentication.Abstractions.Core.IAzureContextContainer' -Because 'Get-RdaSubscriptionProfile returns exactly that type, with the subscription tenant already swapped in'
        @($Real.ParameterSets | Where-Object { $_.Name -eq 'ResourceUrl' } | ForEach-Object { $_.Parameters.Name }) | Should -Contain 'DefaultProfile' -Because 'the batch path calls it with -ResourceUrl'
    }
}

Describe 'The metrics batch call site sends only the definitions the batch did not satisfy to the per-call path' {
    BeforeAll {
        # The per-service loop is lifted out of the shipped script by AST so the test runs what Metrics.ps1 does.
        $Loop = @($script:Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.ForEachStatementAst] -and $N.Condition.Extent.Text -eq '$BatchGroups.Keys' }, $true))
        if ($Loop.Count -ne 1) { throw ('Expected one per-service batch loop; found {0}.' -f $Loop.Count) }
        $script:BatchCallSite = [scriptblock]::Create((@(
                    'param($BatchGroups, $BatchNamespaceMap, $Returned, $ThrowMessage)'
                    '$RemainingDefs = [System.Collections.Generic.List[object]]::new()'
                    '$Tmp = [pscustomobject]@{ Metrics = [System.Collections.Generic.List[object]]::new() }'
                    '$CallDiag = [System.Collections.Generic.List[string]]::new()'
                    'function Write-MetricsDiag { param($Message) $CallDiag.Add([string]$Message) }'
                    'function Invoke-RdaMetricsBatch { param($Defs, $MetricNamespace) if ($ThrowMessage) { throw $ThrowMessage } @($Returned) }'
                    $Loop[0].Extent.Text
                    '[pscustomobject]@{ Remaining = @($RemainingDefs); Kept = @($Tmp.Metrics); Diag = @($CallDiag) }'
                ) -join [Environment]::NewLine))
        $script:CallSiteDefs = [System.Collections.Generic.List[object]]@(
            [pscustomobject]@{ Id = '/subscriptions/sub-a/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1'; MetricName = 'Percentage CPU' }
            [pscustomobject]@{ Id = '/subscriptions/sub-a/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm2'; MetricName = 'Percentage CPU' }
            [pscustomobject]@{ Id = '/subscriptions/sub-a/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm3'; MetricName = 'Percentage CPU' })
        $script:CallSiteGroups = [ordered]@{ 'Virtual Machines' = $script:CallSiteDefs }
        $script:CallSiteMap = [ordered]@{ 'Virtual Machines' = 'microsoft.compute/virtualMachines' }
    }

    BeforeEach { $script:MetricsBatchLastError = $null }

    It 'keeps the batched records and sends on only the definitions that were not covered' {
        $Returned = @([pscustomobject]@{ ID = $script:CallSiteDefs[0].Id; Metric = 'Percentage CPU' }, [pscustomobject]@{ ID = $script:CallSiteDefs[1].Id; Metric = 'Percentage CPU' })
        $Result = & $script:BatchCallSite $script:CallSiteGroups $script:CallSiteMap $Returned $null
        $Result.Kept.Count | Should -Be 2
        @($Result.Remaining | ForEach-Object { $_.Id }) | Should -Be @($script:CallSiteDefs[2].Id) -Because 'a partial batch must cost the per-call path only what it did not cover'
        @($Result.Diag | Where-Object { $_ -like 'WARNING: metrics batch fast-path failed for 1 of 3 Virtual Machines metric def(s)*' }).Count | Should -Be 1
    }

    It 'falls the whole service back, with the batch error and the hint, when the function throws' {
        $Result = & $script:BatchCallSite $script:CallSiteGroups $script:CallSiteMap @() 'AuthorizationFailed: the client does not have authorization'
        $Result.Kept.Count | Should -Be 0
        $Result.Remaining.Count | Should -Be 3
        @($Result.Diag | Where-Object { $_ -like '*3 of 3 Virtual Machines metric def(s)*' -and $_ -like '*AuthorizationFailed*' -and $_ -like '*Monitoring Reader*' }).Count | Should -Be 1 -Because 'a 403 keeps its own remediation hint, and the line says how many definitions it cost'
    }

    It 'reports the service error the batch recorded when the batch itself did not throw' {
        $script:MetricsBatchLastError = 'getBatch refused the request: BadRequest'
        $Result = & $script:BatchCallSite $script:CallSiteGroups $script:CallSiteMap @() $null
        $Result.Remaining.Count | Should -Be 3
        @($Result.Diag | Where-Object { $_ -like '*getBatch refused the request: BadRequest*' }).Count | Should -Be 1 -Because 'the skipped group or chunk is the only thing that knows why the records are missing'
    }

    It 'says nothing about a fallback, and logs the fetch, when every definition was batched' {
        $Returned = @($script:CallSiteDefs | ForEach-Object { [pscustomobject]@{ ID = $_.Id; Metric = 'Percentage CPU' } })
        $Result = & $script:BatchCallSite $script:CallSiteGroups $script:CallSiteMap $Returned $null
        $Result.Remaining.Count | Should -Be 0
        @($Result.Diag | Where-Object { $_ -like 'WARNING:*' }).Count | Should -Be 0
        @($Result.Diag | Where-Object { $_ -like 'Metrics batch fast-path: fetched 3 Virtual Machines metric record(s)*' }).Count | Should -Be 1
    }
}

Describe 'The per-call metric path queries each subscription through its own tenant profile' {
    # The phase captures one Az context for the whole run. For a subscription homed in another tenant
    # every Get-AzMetric of that subscription then carried a token for the wrong tenant - the same defect
    # the getBatch token had, on the path the batch falls back to. Reachable in a standalone
    # ResourceInventory.ps1 run without -TenantID, where the subscription list can span tenants.

    BeforeAll {
        # The map build is a plain statement block in the phase body, so it is run as the source has it,
        # with the stubs composed in front of it. Built on invocation, not here, so a source that does
        # not have the block fails the test that looks for it rather than this BeforeAll.
        $script:RunSubProfileBuild = {
            param($Defs, [scriptblock]$ProfileStub)
            $Lookups = [System.Collections.Generic.List[string]]::new()
            $Diag = [System.Collections.Generic.List[string]]::new()
            $Runner = [scriptblock]::Create(((@(
                            'param($Defs, $ProfileStub, $Lookups, $Diag)'
                            'function Write-MetricsDiag { param($Message) $Diag.Add([string]$Message) }'
                            'function Get-RdaSubscriptionProfile { param([string]$SubscriptionId) $Lookups.Add($SubscriptionId); & $ProfileStub $SubscriptionId }'
                            '$MetricDefs = $Defs'
                            '$MetricCount = @($Defs).Count'
                            '$MetricSubProfiles = @{}'
                            $script:SubProfileBuild.Extent.Text
                            '[pscustomobject]@{ Profiles = $MetricSubProfiles; Lookups = @($Lookups); Diag = @($Diag) }'
                        ) -join [Environment]::NewLine)))
            & $Runner $Defs $ProfileStub $Lookups $Diag
        }
    }

    It 'gives a query the profile built for the subscription its own resource lives in' {
        $script:CallProfileFnAst | Should -Not -BeNullOrEmpty -Because 'the profile a call is given is chosen per definition, not once for the phase'
        $Profiles = @{ 'sub-a' = 'profile-a'; 'sub-b' = 'profile-b' }
        Get-RdaMetricCallProfile -ResourceId '/subscriptions/sub-a/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1' -SubProfiles $Profiles -PhaseProfile 'phase' | Should -Be 'profile-a'
        Get-RdaMetricCallProfile -ResourceId '/subscriptions/SUB-B/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/sa1' -SubProfiles $Profiles -PhaseProfile 'phase' | Should -Be 'profile-b' -Because 'a resource id carries the subscription in whatever case Azure returned it'
    }

    It 'falls back to the phase context when the map has no profile for the subscription' {
        $script:CallProfileFnAst | Should -Not -BeNullOrEmpty
        Get-RdaMetricCallProfile -ResourceId '/subscriptions/sub-z/resourceGroups/rg/providers/x/y/z' -SubProfiles @{ 'sub-a' = 'profile-a' } -PhaseProfile 'phase' | Should -Be 'phase' -Because 'that is what every per-call query used before, so a failed lookup costs nothing'
        Get-RdaMetricCallProfile -ResourceId 'not-a-resource-id' -SubProfiles @{ 'sub-a' = 'profile-a' } -PhaseProfile 'phase' | Should -Be 'phase'
        Get-RdaMetricCallProfile -ResourceId '/subscriptions/sub-a/x' -SubProfiles $null -PhaseProfile 'phase' | Should -Be 'phase'
    }

    It 'builds one profile per distinct subscription, not one per metric definition' {
        $script:SubProfileBuild | Should -Not -BeNullOrEmpty -Because 'the phase builds the map once, before the worker loop'
        $Defs = @(
            [pscustomobject]@{ Id = '/subscriptions/SUB-A/resourceGroups/rg/providers/x/y/a' }
            [pscustomobject]@{ Id = '/subscriptions/sub-a/resourceGroups/rg/providers/x/y/b' }
            [pscustomobject]@{ Id = '/subscriptions/sub-b/resourceGroups/rg/providers/x/y/c' }
            [pscustomobject]@{ Id = 'no-subscription-segment' }
        )
        $Built = & $script:RunSubProfileBuild $Defs { param($Id) "profile-for-$Id" }
        @($Built.Lookups | Sort-Object) | Should -Be @('sub-a', 'sub-b') -Because 'four definitions over two subscriptions cost two lookups, and an id with no subscription segment costs none'
        $Built.Profiles.Count | Should -Be 2
        $Built.Profiles['sub-a'] | Should -Be 'profile-for-sub-a'
        $Built.Profiles['sub-b'] | Should -Be 'profile-for-sub-b'
        @($Built.Diag) | Should -BeNullOrEmpty
    }

    It 'names the subscription it could not scope and leaves the others with their own profile' {
        $script:SubProfileBuild | Should -Not -BeNullOrEmpty
        $Defs = @(
            [pscustomobject]@{ Id = '/subscriptions/sub-bad/resourceGroups/rg/providers/x/y/a' }
            [pscustomobject]@{ Id = '/subscriptions/sub-ok/resourceGroups/rg/providers/x/y/b' }
        )
        $Built = & $script:RunSubProfileBuild $Defs {
            param($Id)
            if ($Id -eq 'sub-bad') { throw 'the subscription is not visible to the signed-in identity' }
            "profile-for-$Id"
        }
        $Built.Profiles.ContainsKey('sub-bad') | Should -BeFalse -Because 'a lookup that threw stored nothing'
        $Built.Profiles['sub-ok'] | Should -Be 'profile-for-sub-ok' -Because 'one subscription that cannot be scoped never costs the others their own profile'
        @($Built.Diag | Where-Object { $_ -like '*sub-bad*' }).Count | Should -Be 1
        @($Built.Diag | Where-Object { $_ -like '*not visible to the signed-in identity*' }).Count | Should -Be 1 -Because 'the helper''s own message is the only thing that says why'
        Get-RdaMetricCallProfile -ResourceId '/subscriptions/sub-bad/resourceGroups/rg/providers/x/y/a' -SubProfiles $Built.Profiles -PhaseProfile 'phase' | Should -Be 'phase'
    }

    It 'hands the worker the map, and every call the profile of its own definition' {
        $script:MetricsSrc.IndexOf("`$SubProfiles = `$using:MetricSubProfiles") | Should -BeGreaterThan -1 -Because 'the map has to reach the worker runspaces'
        $script:MetricsSrc.IndexOf("`$CallProfile = Get-RdaMetricCallProfile -ResourceId `$_.Id -SubProfiles `$SubProfiles -PhaseProfile `$AzContext") | Should -BeGreaterThan -1 -Because 'the subscription comes from the definition being queried, not from the phase'
        $script:MetricsSrc.IndexOf("`$MetricArgs['DefaultProfile'] = `$CallProfile") | Should -BeGreaterThan -1
        $script:MetricsSrc.IndexOf("`$MetricArgs['DefaultProfile'] = `$AzContext") | Should -Be -1 -Because 'the phase context is now only the fallback, never the profile every call is given'
    }
}
