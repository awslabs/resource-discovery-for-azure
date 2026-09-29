<#
    Subscription skip lines: which ones reach the console, and what they say.

    WHAT THIS GUARDS. ResourceInventory.ps1 walks every subscription in the tenant in
    its consumption and Marketplace phases and passes over each one that is not the
    -SubscriptionID being collected. It used to print a bare "Skipping: <sub>" and
    "Skipping (Marketplace): <sub>" line to the console for each of them, so under the
    wrapper every subscription's run printed two lines for every OTHER subscription -
    a count that grows with the square of the tenant's subscription count - for
    subscriptions that were never being dropped (each is collected in its own turn).
    Those lines are now replaced by ONE debug-log line per phase that counts the
    subscriptions passed over and names only the subscription the run is limited to.
    The other subscriptions are never named: the debug log ships in a default-mode zip,
    and they are outside this run's scope (Disabled ones the wrapper leaves out, other
    shards' subscriptions, other tenants' subscriptions in Cloud Shell).

    The wrapper's state filter is the opposite case: those subscriptions really are
    left out of the run, so it names each one with its id and state instead of only
    printing a per-state count. That listing goes to the console and the local
    wrapper transcript only.

    Fully offline. Each test lifts the real statements out of the parsed source and runs
    them against synthetic subscriptions, with the real Write-Log from Common.Functions.ps1.
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:InvPath = Join-Path $script:RepoRoot 'ResourceInventory.ps1'
    $script:WrapperPath = Join-Path $script:RepoRoot 'Run-AllSubscriptions.ps1'
    . (Join-Path $script:RepoRoot 'Functions/Common.Functions.ps1')

    # The one statement in a scope whose condition is exactly $Condition and whose text
    # contains $Marker. Exactly one is required: a second copy would be a second place
    # that decides the same thing.
    function Get-SingleIfStatement
    {
        param($Scope, [string]$Condition, [string]$Marker = '')
        $Found = @($Scope.FindAll({ param($N) $N -is [System.Management.Automation.Language.IfStatementAst] -and $N.Clauses[0].Item1.Extent.Text -eq $Condition -and $N.Extent.Text.Contains($Marker) }, $true))
        if ($Found.Count -ne 1) { throw ("expected exactly one 'if ({0})' containing '{1}', found {2}" -f $Condition, $Marker, $Found.Count) }
        return $Found[0]
    }

    # Each phase is rebuilt from its own source: every statement before its subscription
    # loop that reads $SubscriptionID (whatever the phase does about the subscriptions it
    # passes over happens there), then the loop with only its first statement, the guard
    # that passes over every subscription except -SubscriptionID. The inputs arrive as
    # parameters, and $Reached records which subscriptions got past the guard.
    $script:InvAst = [System.Management.Automation.Language.Parser]::ParseFile($script:InvPath, [ref]$null, [ref]$null)
    $script:PhaseBlocks = @{}
    foreach ($FnName in 'GetResourceConsumption', 'GetMarketplaceConsumption')
    {
        $Fn = $script:InvAst.Find({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq $FnName }, $true)
        if (-not $Fn) { throw ('{0} was not found in ResourceInventory.ps1.' -f $FnName) }

        $Loops = @($Fn.Body.FindAll({ param($N) $N -is [System.Management.Automation.Language.ForEachStatementAst] -and $N.Variable.Extent.Text -eq '$sub' -and $N.Condition.Extent.Text -eq '$Global:Subscriptions' }, $true))
        if ($Loops.Count -ne 1) { throw ('expected one subscription loop in {0}, found {1}' -f $FnName, $Loops.Count) }
        $Loop = $Loops[0]
        $Guard = $Loop.Body.Statements[0]
        if ($Guard.Extent.Text -notmatch '\$SubscriptionID -ne \$sub\.Id') { throw ('the first statement of the subscription loop in {0} is not the -SubscriptionID guard' -f $FnName) }

        $Before = @($Loop.Parent.Statements | Where-Object { $_.Extent.EndOffset -le $Loop.Extent.StartOffset -and $_.Extent.Text -match '\$SubscriptionID\b' } | ForEach-Object { $_.Extent.Text })
        $BlockLines = @('param($SubscriptionID, $ResourceGroup, $Reached)') + $Before + @('foreach ($sub in $Global:Subscriptions)', '{', $Guard.Extent.Text, '$Reached.Add($sub.Id)', '}')
        $script:PhaseBlocks[$FnName] = [scriptblock]::Create($BlockLines -join [Environment]::NewLine)
    }

    # Run-AllSubscriptions.ps1 tests '$Excluded.Count -gt 0' twice: once where the filter
    # runs (the block under test) and once in the final summary, which keeps its count.
    # The block reads $Excluded from its caller's scope; a param() hands it over explicitly.
    $WrapperAst = [System.Management.Automation.Language.Parser]::ParseFile($script:WrapperPath, [ref]$null, [ref]$null)
    $script:ExcludedBlock = [scriptblock]::Create(('param($Excluded){0}{1}' -f [Environment]::NewLine, (Get-SingleIfStatement -Scope $WrapperAst -Condition '$Excluded.Count -gt 0' -Marker 'non-Enabled subscription(s) [').Extent.Text))
}

AfterAll {
    Remove-Item function:global:Write-Log -ErrorAction SilentlyContinue
}

Describe 'ResourceInventory.ps1: the subscriptions a phase passes over are counted in the debug log, never named' {
    BeforeAll {
        $script:PriorDebugLogFile = $Global:DebugLogFile
        $script:PriorErrorLogFile = $Global:ErrorLogFile
        $script:SkipLog = Join-Path ([System.IO.Path]::GetTempPath()) ('SubscriptionSkip_{0}.log' -f [guid]::NewGuid().ToString('N'))
        $Global:DebugLogFile = $script:SkipLog
        $Global:ErrorLogFile = $null
        $script:PriorSubscriptions = $Global:Subscriptions
        $script:StampPattern = '^\[\d{2}-\d{2}-\d{4} \d{2}:\d{2}:\d{2}\] '
    }
    AfterAll {
        $Global:DebugLogFile = $script:PriorDebugLogFile
        $Global:ErrorLogFile = $script:PriorErrorLogFile
        $Global:Subscriptions = $script:PriorSubscriptions
        Remove-Item -LiteralPath $script:SkipLog -Force -ErrorAction SilentlyContinue
    }
    BeforeEach {
        Remove-Item -LiteralPath $script:SkipLog -Force -ErrorAction SilentlyContinue
    }

    It '<FnName>: prints nothing, logs one count line naming only the target, and still collects only the target' -ForEach @(
        @{ FnName = 'GetResourceConsumption'; Data = 'Consumption data' }
        @{ FnName = 'GetMarketplaceConsumption'; Data = 'Marketplace data' }
    ) {
        $TargetId = [guid]::NewGuid().ToString()
        $OtherA = [guid]::NewGuid().ToString()
        $OtherB = [guid]::NewGuid().ToString()
        $Global:Subscriptions = @(
            [pscustomobject]@{ Id = $OtherA; Name = 'Other subscription A' }
            [pscustomobject]@{ Id = $TargetId; Name = 'Target subscription' }
            [pscustomobject]@{ Id = $OtherB; Name = 'Other subscription B' }
        )
        $Reached = [System.Collections.Generic.List[string]]::new()

        $Emitted = @(& $script:PhaseBlocks[$FnName] -SubscriptionID $TargetId -ResourceGroup '' -Reached $Reached 6>&1)

        @($Emitted).Count | Should -Be 0 -Because 'a subscription collected in its own turn is not being dropped, so passing over it is not console news'
        @($Reached) | Should -Be @($TargetId) -Because 'only the -SubscriptionID subscription may reach the collection code'

        # Write-Log tags every line with the first 8 characters of the run's -SubscriptionID.
        $Tag = [regex]::Escape('[{0}] ' -f $TargetId.Substring(0, 8))
        $Lines = @(Get-Content -LiteralPath $script:SkipLog)
        $Lines.Count | Should -Be 1 -Because 'one line per phase, not one per subscription passed over'
        $Lines[0] | Should -Match ($script:StampPattern + $Tag + [regex]::Escape("$Data not collected for 2 other subscription(s) visible to this identity: this run is limited to subscription 'Target subscription' by -SubscriptionID.") + '$')

        $LogText = Get-Content -LiteralPath $script:SkipLog -Raw
        foreach ($OutOfScope in 'Other subscription A', 'Other subscription B', $OtherA, $OtherB)
        {
            $LogText | Should -Not -Match ([regex]::Escape($OutOfScope)) -Because 'the debug log ships in a default-mode zip, and a subscription outside the run must not be named in it'
        }
    }

    It '<FnName>: names the -SubscriptionID value itself when that subscription is not in the visible list' -ForEach @(
        @{ FnName = 'GetResourceConsumption'; Data = 'Consumption data' }
        @{ FnName = 'GetMarketplaceConsumption'; Data = 'Marketplace data' }
    ) {
        $TargetId = [guid]::NewGuid().ToString()
        $OtherA = [guid]::NewGuid().ToString()
        $Global:Subscriptions = @(
            [pscustomobject]@{ Id = $OtherA; Name = 'Other subscription A' }
        )
        $Reached = [System.Collections.Generic.List[string]]::new()

        $null = & $script:PhaseBlocks[$FnName] -SubscriptionID $TargetId -ResourceGroup '' -Reached $Reached 6>&1

        @($Reached).Count | Should -Be 0
        $Lines = @(Get-Content -LiteralPath $script:SkipLog)
        $Lines.Count | Should -Be 1
        $Lines[0] | Should -Match ($script:StampPattern + [regex]::Escape('[{0}] ' -f $TargetId.Substring(0, 8)) + [regex]::Escape("$Data not collected for 1 other subscription(s) visible to this identity: this run is limited to subscription $TargetId by -SubscriptionID.") + '$')
        $Lines[0] | Should -Not -Match ([regex]::Escape($OtherA))
    }

    It '<FnName>: logs nothing when the target is the only visible subscription' -ForEach @(
        @{ FnName = 'GetResourceConsumption' }
        @{ FnName = 'GetMarketplaceConsumption' }
    ) {
        $TargetId = [guid]::NewGuid().ToString()
        $Global:Subscriptions = @(
            [pscustomobject]@{ Id = $TargetId; Name = 'Target subscription' }
        )
        $Reached = [System.Collections.Generic.List[string]]::new()

        $Emitted = @(& $script:PhaseBlocks[$FnName] -SubscriptionID $TargetId -ResourceGroup '' -Reached $Reached 6>&1)

        @($Emitted).Count | Should -Be 0
        @($Reached) | Should -Be @($TargetId)
        Test-Path -LiteralPath $script:SkipLog | Should -BeFalse -Because 'there is nothing passed over to count'
    }

    It 'GetResourceConsumption: says once, not once per visible subscription, that -ResourceGroup cannot filter consumption' {
        $TargetId = [guid]::NewGuid().ToString()
        $Global:Subscriptions = @(
            [pscustomobject]@{ Id = [guid]::NewGuid().ToString(); Name = 'Other subscription A' }
            [pscustomobject]@{ Id = $TargetId; Name = 'Target subscription' }
            [pscustomobject]@{ Id = [guid]::NewGuid().ToString(); Name = 'Other subscription B' }
        )
        $Reached = [System.Collections.Generic.List[string]]::new()

        $Emitted = @(& $script:PhaseBlocks['GetResourceConsumption'] -SubscriptionID $TargetId -ResourceGroup 'rg-example' -Reached $Reached 6>&1 | ForEach-Object { $_.ToString() })

        @($Emitted | Where-Object { $_ -like '*Cannot filter consumption by resource group.' }).Count | Should -Be 1
        @($Reached) | Should -Be @($TargetId)
    }
}

Describe 'Run-AllSubscriptions.ps1: every subscription the state filter leaves out is named' {
    It 'keeps the count line and then lists each excluded subscription with its id and state, grouped by state' {
        $IdZeta = [guid]::NewGuid().ToString()
        $IdAlpha = [guid]::NewGuid().ToString()
        $IdBeta = [guid]::NewGuid().ToString()
        $Excluded = @(
            [pscustomobject]@{ Name = 'Zeta legacy'; Id = $IdZeta; State = 'Disabled' }
            [pscustomobject]@{ Name = 'Alpha trial'; Id = $IdAlpha; State = 'Warned' }
            [pscustomobject]@{ Name = 'Beta old'; Id = $IdBeta; State = 'Disabled' }
        )

        $Lines = @(& $script:ExcludedBlock -Excluded $Excluded 6>&1 | ForEach-Object { $_.ToString() })

        $Lines.Count | Should -Be 4
        $Lines[0] | Should -Match '^Excluded 3 non-Enabled subscription\(s\) \[(Disabled: 2, Warned: 1|Warned: 1, Disabled: 2)\]\. Use -IncludeDisabled to inventory them anyway\.$' -Because 'the existing count line is unchanged'
        $Lines[1] | Should -Be "  - Beta old ($IdBeta): Disabled"
        $Lines[2] | Should -Be "  - Zeta legacy ($IdZeta): Disabled"
        $Lines[3] | Should -Be "  - Alpha trial ($IdAlpha): Warned"
    }

    It 'prints nothing when no subscription was excluded' {
        @(& $script:ExcludedBlock -Excluded @() 6>&1).Count | Should -Be 0
    }
}
