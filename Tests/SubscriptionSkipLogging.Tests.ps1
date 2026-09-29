<#
    Subscription skip lines: which ones reach the console, and what they say.

    WHAT THIS GUARDS. ResourceInventory.ps1 walks every subscription in the tenant in
    its consumption and Marketplace phases and passes over each one that is not the
    -SubscriptionID being collected. It used to print a bare "Skipping: <sub>" and
    "Skipping (Marketplace): <sub>" line to the console for each of them, so under the
    wrapper every subscription's run printed two lines for every OTHER subscription -
    a count that grows with the square of the tenant's subscription count - for
    subscriptions that were never being dropped (each is collected in its own turn).
    Those lines now go to the local debug log only, and each one says what was not
    collected, for which subscription, and why.

    The wrapper's state filter is the opposite case: those subscriptions really are
    left out of the run, so it names each one with its id and state instead of only
    printing a per-state count.

    Fully offline. Each test lifts the real statement out of the parsed source and runs
    it against synthetic subscriptions, with the real Write-Log from Common.Functions.ps1.
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

    $script:InvAst = [System.Management.Automation.Language.Parser]::ParseFile($script:InvPath, [ref]$null, [ref]$null)
    $script:SkipBlocks = @{}
    $script:TargetLabelBlocks = @{}
    foreach ($FnName in 'GetResourceConsumption', 'GetMarketplaceConsumption')
    {
        $Fn = $script:InvAst.Find({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq $FnName }, $true)
        if (-not $Fn) { throw ('{0} was not found in ResourceInventory.ps1.' -f $FnName) }
        $script:SkipBlocks[$FnName] = [scriptblock]::Create((Get-SingleIfStatement -Scope $Fn -Condition '$SubscriptionID -ne $sub.Id').Extent.Text)

        # The skip line names the subscription the run is limited to. That label is worked
        # out once, before the subscription loop, by exactly two assignments.
        $Assignments = @($Fn.FindAll({ param($N) $N -is [System.Management.Automation.Language.AssignmentStatementAst] -and $N.Left.Extent.Text -match '^\$(Mp)?TargetSub(Label)?$' }, $true))
        if ($Assignments.Count -ne 2) { throw ('expected the two target-subscription assignments in {0}, found {1}' -f $FnName, $Assignments.Count) }
        $script:TargetLabelBlocks[$FnName] = [scriptblock]::Create((@($Assignments | ForEach-Object { $_.Extent.Text }) -join [Environment]::NewLine))
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

Describe 'ResourceInventory.ps1: passing over another subscription is written to the debug log only' {
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

    It '<FnName>: prints nothing, logs what was not collected and why for each other subscription, and still collects only the target' -ForEach @(
        @{ FnName = 'GetResourceConsumption'; Data = 'Consumption data' }
        @{ FnName = 'GetMarketplaceConsumption'; Data = 'Marketplace data' }
    ) {
        $SubscriptionID = [guid]::NewGuid().ToString()
        $OtherA = [guid]::NewGuid().ToString()
        $OtherB = [guid]::NewGuid().ToString()
        $Global:Subscriptions = @(
            [pscustomobject]@{ Id = $OtherA; Name = 'Other subscription A' }
            [pscustomobject]@{ Id = $SubscriptionID; Name = 'Target subscription' }
            [pscustomobject]@{ Id = $OtherB; Name = 'Other subscription B' }
        )
        $TargetLabelBlock = $script:TargetLabelBlocks[$FnName]
        $SkipBlock = $script:SkipBlocks[$FnName]
        $Reached = [System.Collections.Generic.List[string]]::new()

        # The lifted block ends in 'continue', which PowerShell resolves against this loop,
        # exactly as it does against the function's own loop.
        $Emitted = @(& {
                . $TargetLabelBlock
                foreach ($sub in $Global:Subscriptions)
                {
                    . $SkipBlock
                    $Reached.Add($sub.Id)
                }
            } 6>&1)

        @($Emitted).Count | Should -Be 0 -Because 'a subscription collected in its own turn is not being dropped, so passing over it is not console news'
        @($Reached) | Should -Be @($SubscriptionID) -Because 'only the -SubscriptionID subscription may reach the collection code'

        # The reason has to hold for a standalone -SubscriptionID run as well as under the
        # wrapper, so it names the scoping rather than claiming the subscription runs later.
        # Write-Log tags every line with the first 8 characters of the run's -SubscriptionID.
        $Tag = [regex]::Escape('[{0}] ' -f $SubscriptionID.Substring(0, 8))
        $Lines = @(Get-Content -LiteralPath $script:SkipLog)
        $Lines.Count | Should -Be 2
        $Lines[0] | Should -Match ($script:StampPattern + $Tag + [regex]::Escape("$Data not collected for 'Other subscription A' ($OtherA): this run is limited to subscription 'Target subscription' by -SubscriptionID.") + '$')
        $Lines[1] | Should -Match ($script:StampPattern + $Tag + [regex]::Escape("$Data not collected for 'Other subscription B' ($OtherB): this run is limited to subscription 'Target subscription' by -SubscriptionID.") + '$')
    }

    It '<FnName>: names the -SubscriptionID value itself when that subscription is not in the visible list' -ForEach @(
        @{ FnName = 'GetResourceConsumption'; Data = 'Consumption data' }
        @{ FnName = 'GetMarketplaceConsumption'; Data = 'Marketplace data' }
    ) {
        $SubscriptionID = [guid]::NewGuid().ToString()
        $OtherA = [guid]::NewGuid().ToString()
        $Global:Subscriptions = @(
            [pscustomobject]@{ Id = $OtherA; Name = 'Other subscription A' }
        )
        $TargetLabelBlock = $script:TargetLabelBlocks[$FnName]
        $SkipBlock = $script:SkipBlocks[$FnName]

        $null = & {
            . $TargetLabelBlock
            foreach ($sub in $Global:Subscriptions)
            {
                . $SkipBlock
            }
        } 6>&1

        $Lines = @(Get-Content -LiteralPath $script:SkipLog)
        $Lines.Count | Should -Be 1
        $Lines[0] | Should -Match ($script:StampPattern + [regex]::Escape('[{0}] ' -f $SubscriptionID.Substring(0, 8)) + [regex]::Escape("$Data not collected for 'Other subscription A' ($OtherA): this run is limited to subscription $SubscriptionID by -SubscriptionID.") + '$')
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
