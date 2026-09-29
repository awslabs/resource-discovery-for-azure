#Requires -Version 7.0
<#
    CollectorBreakerAndVisibility.Tests.ps1

    THE DEFECT THIS GUARDS. A resource type whose collector threw serialised as an empty array,
    exactly like a type the subscription genuinely does not own, and Extension/Summary.ps1 drops any
    zero-count service, so the type vanished from the HTML with no trace on the page.

    Worse, the circuit breaker meant to stop a systemic failure was INERT. With the global
    $ErrorActionPreference at SilentlyContinue - which is what ResourceInventory.ps1 sets outside
    -Debug - a `throw` from inside a catch neither halted the run nor left the enclosing foreach, so
    every remaining collector ran on and recorded @(): precisely the "incomplete report that looks
    like an empty environment" the breaker's own message promises to prevent, and the run exited 0.

    That premise is NOT asserted here on purpose. Whether a `throw` propagates turns out to depend on
    the surrounding preference state - it does propagate under Pester, and did not in a plain pwsh
    host - so a unit test of it proves nothing durable and would read as a guarantee it is not. The
    durable point is the opposite one: `break` is deterministic where `throw` is preference-dependent,
    which is why the product uses it. The evidence for the behaviour itself is the end-to-end run.

    A fourth, related fix is pinned by the last Describe: ResourceInventory.ps1 sets CurrentCulture to
    en-US inside its two billing functions and never restores it, so figures elsewhere printed a dot
    only as a side effect of that leak, and entry points that never call those functions got the host
    culture. It is here rather than in its own file because it shares the root cause with nothing else
    and shipped in the same change; look here for a culture regression in FindResource or Reveal.

    NOT pinned here, and it needs planted failing collectors so it cannot be: the OUTPUT-level
    consequence that types after an abort are ABSENT from Inventory_*.json rather than present as [].
    The end-to-end run below is the record for that; the structural assertions are not a substitute.

    Verified end to end before the fix was called done, by planting deliberately failing collectors
    in Services/: one failure now names the type in the report, and five consecutive failures stop
    collection at the fifth (the sixth is never attempted), report the subscription FAILED, exit 2,
    and remove the archive so the wrapper cannot consolidate it.
#>

BeforeAll {
    $script:Repo = Split-Path $PSScriptRoot -Parent
    $script:InvPath = Join-Path $script:Repo 'ResourceInventory.ps1'
    $script:InvSrc = Get-Content -LiteralPath $script:InvPath -Raw
    $Errors = $null
    $script:InvAst = [System.Management.Automation.Language.Parser]::ParseFile($script:InvPath, [ref]$null, [ref]$Errors)
    if ($null -ne $Errors -and $Errors.Count -gt 0) { throw ('ResourceInventory.ps1 does not parse: {0}' -f $Errors[0].Message) }

    $script:SummaryPath = Join-Path $script:Repo 'Extension/Summary.ps1'
    $script:SummarySrc = Get-Content -LiteralPath $script:SummaryPath -Raw

    $script:JobsFn = $script:InvAst.Find({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq 'CreateResourceJobs' }, $true)
    if (-not $script:JobsFn) { throw 'CreateResourceJobs was not found in ResourceInventory.ps1.' }
}

Describe 'The collector circuit breaker actually stops collection' {
    It 'the breaker records and breaks, and does NOT throw' {
        $Breaker = @($script:JobsFn.FindAll({ param($N) $N -is [System.Management.Automation.Language.AssignmentStatementAst] -and $N.Left.Extent.Text -eq '$script:CollectorBreakerError' }, $true))
        $Breaker.Count | Should -Be 1 -Because 'one owner of the breaker state'

        $Clause = $Breaker[0].Parent
        while ($null -ne $Clause -and -not ($Clause -is [System.Management.Automation.Language.IfStatementAst])) { $Clause = $Clause.Parent }
        $Clause | Should -Not -BeNullOrEmpty
        $Clause.Clauses[0].Item1.Extent.Text | Should -Match 'CollectorFailureCircuitBreakerThreshold' -Because 'it is the threshold that trips it'

        $Body = $Clause.Clauses[0].Item2
        @($Body.FindAll({ param($N) $N -is [System.Management.Automation.Language.BreakStatementAst] }, $true)).Count | Should -Be 1 -Because 'break is what actually leaves the collector loop'
        @($Body.FindAll({ param($N) $N -is [System.Management.Automation.Language.ThrowStatementAst] }, $true)).Count | Should -Be 0 -Because 'a throw here is silently swallowed outside -Debug, which is the defect'
    }

    It 'the break leaves the COLLECTOR loop, not some inner loop' {
        $Breaker = @($script:JobsFn.FindAll({ param($N) $N -is [System.Management.Automation.Language.BreakStatementAst] }, $true))
        $Breaker.Count | Should -BeGreaterThan 0
        $Target = $Breaker | Where-Object {
            $P = $_.Parent
            while ($null -ne $P -and -not ($P -is [System.Management.Automation.Language.IfStatementAst])) { $P = $P.Parent }
            $null -ne $P -and $P.Clauses[0].Item1.Extent.Text -match 'CollectorFailureCircuitBreakerThreshold'
        } | Select-Object -First 1
        $Target | Should -Not -BeNullOrEmpty

        # A switch also consumes a break but is NOT a LoopStatementAst, so walking only to the nearest
        # loop would skip past one and pass on the exact defect this test exists to catch.
        $Loop = $Target.Parent
        while ($null -ne $Loop -and -not ($Loop -is [System.Management.Automation.Language.LoopStatementAst] -or $Loop -is [System.Management.Automation.Language.SwitchStatementAst])) { $Loop = $Loop.Parent }
        $Loop | Should -BeOfType ([System.Management.Automation.Language.ForEachStatementAst])
        $Loop.Variable.Extent.Text | Should -BeExactly '$Module' -Because 'it must abandon the per-collector loop'
    }

    It 'an aborted run is reported FAILED through the existing archive gate' {
        # The gate owns "report this subscription FAILED + remove the unusable archive + exit 2", so the
        # wrapper cannot fold a partial report into the consolidated bundle.
        $script:InvSrc | Should -Match 'if \(-not \[string\]::IsNullOrWhiteSpace\(\$script:CollectorBreakerError\)\)'
        $Gate = [regex]::Match($script:InvSrc, '(?s)if \(-not \[string\]::IsNullOrWhiteSpace\(\$script:CollectorBreakerError\)\)\s*\{.*?\n\}').Value
        $Gate | Should -Not -BeNullOrEmpty
        $Gate | Should -Match '\$ZipVerified = \$false' -Because 'that is what makes the run report FAILED and drops the archive'
        $Gate | Should -Match 'ABSENT from the inventory rather than empty' -Because 'the operator has to be told the shape of what is missing'
    }
}

Describe 'A failed collector is visible in the per-subscription HTML report' {
    It 'Summary.ps1 accepts the failed-collector list and the abort flag' {
        $SumErrors = $null
        $SumAst = [System.Management.Automation.Language.Parser]::ParseFile($script:SummaryPath, [ref]$null, [ref]$SumErrors)
        if ($null -ne $SumErrors -and $SumErrors.Count -gt 0) { throw ('Extension/Summary.ps1 does not parse: {0}' -f $SumErrors[0].Message) }
        $Params = @($SumAst.ParamBlock.Parameters | ForEach-Object { $_.Name.Extent.Text })
        $Params | Should -Contain '$CollectorFailures'
        $Params | Should -Contain '$CollectorsAborted'
    }

    It 'ResourceInventory.ps1 passes the PER-INVOCATION list, not the cross-subscription global' {
        # The wrapper invokes this script once per subscription in the SAME process, so the global
        # accumulates. Passing it would make one subscription's report name another's failures.
        # A count, not a negative: the negative was green both before and after the fix, and could only
        # ever fire if a SECOND call site were added beside a correct one.
        @([regex]::Matches($script:InvSrc, '-CollectorFailures ')).Count | Should -Be 1 -Because 'exactly one call site passes the list'
        $script:InvSrc | Should -Match '-CollectorFailures \$script:CollectorFailuresThisRun' -Because 'and it must be the per-invocation list'
        $script:InvSrc | Should -Match '-CollectorsAborted:\(\[bool\]\$script:CollectorBreakerError\)'
    }

    It 'the per-invocation list is reset per invocation and appended in the failure catch' {
        $script:InvSrc | Should -Match '\$script:CollectorFailuresThisRun = @\(\)' -Because 'a stale list would carry into the next subscription'
        $Appends = @($script:JobsFn.FindAll({ param($N) $N -is [System.Management.Automation.Language.AssignmentStatementAst] -and $N.Left.Extent.Text -eq '$script:CollectorFailuresThisRun' }, $true))
        $Appends.Count | Should -Be 1 -Because 'appended in exactly one place, the collector catch'
        # FindAll cannot tell = from +=, and a plain = would keep only the LAST failure, so the banner
        # would under-report every earlier failed collector while this test stayed green.
        $Appends[0].Operator | Should -Be 'PlusEquals' -Because 'it accumulates; a plain assignment would drop every earlier failure'
    }

    It 'the renderer emits a banner naming the failed types, and marks an aborted run PARTIAL' {
        $script:SummarySrc | Should -Match '\$CollectorBanner'
        $script:SummarySrc | Should -Match 'Incomplete collection'
        $script:SummarySrc | Should -Match 'not empty because there are none'
        $script:SummarySrc | Should -Match 'PARTIAL view of the subscription'
        # Names must be escaped: a module name reaches the page as markup otherwise.
        $script:SummarySrc | Should -Match 'ConvertTo-HtmlSafe \$_'
    }

    It 'the banner is emitted into the page, not just computed' {
        # Computed and never interpolated is the classic way a banner silently does nothing.
        $Emitted = [regex]::Matches($script:SummarySrc, '(?m)^\$CollectorBanner\s*$')
        @($Emitted).Count | Should -Be 1 -Because 'it has to appear on its own line inside the page here-string'
    }
}

Describe 'A rejected billing request is permanent, whatever the message says' {
    BeforeAll { . (Join-Path $script:Repo 'Functions/Common.Functions.ps1') }

    It 'classifies on the exception STATUS when the message does not mention 400' {
        # Reproduced live from the legacy Commerce usage API: HTTP BadRequest whose entire message is
        # "InvalidInput: reportedStartTime has to be before reportedEndTime." A text-only check cannot
        # see that, so the page would spend its whole 30-attempt budget on a permanently bad request.
        $Ex = [pscustomobject]@{ Response = [pscustomobject]@{ StatusCode = [System.Net.HttpStatusCode]::BadRequest } }
        $Msg = 'InvalidInput: reportedStartTime has to be before reportedEndTime.'

        Test-RdaPermanentRequestError -ErrorMessage $Msg | Should -BeFalse -Because 'the text genuinely carries no 400, which is the whole point'
        Test-RdaPermanentRequestError -ErrorMessage $Msg -Exception $Ex | Should -BeTrue
    }

    It 'does not fire on <Label>' -ForEach @(
        @{ Label = 'a 500'; Code = [System.Net.HttpStatusCode]::InternalServerError }
        @{ Label = 'a 403'; Code = [System.Net.HttpStatusCode]::Forbidden }
        @{ Label = 'a 401'; Code = [System.Net.HttpStatusCode]::Unauthorized }
        @{ Label = 'a 429'; Code = 429 }
        @{ Label = 'a 404'; Code = [System.Net.HttpStatusCode]::NotFound }
    ) {
        $Ex = [pscustomobject]@{ Response = [pscustomobject]@{ StatusCode = $Code } }
        Test-RdaPermanentRequestError -ErrorMessage 'transient' -Exception $Ex | Should -BeFalse
    }

    It 'survives an exception with no Response, and a null exception' {
        Test-RdaPermanentRequestError -ErrorMessage 'blip' -Exception ([pscustomobject]@{ Message = 'x' }) | Should -BeFalse
        Test-RdaPermanentRequestError -ErrorMessage 'blip' -Exception $null | Should -BeFalse
        Test-RdaPermanentRequestError -ErrorMessage 'blip' | Should -BeFalse
    }

    It 'the CONSUMPTION page loop gates on it, and passes the exception' {
        $ConsFn = $script:InvAst.Find({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq 'GetResourceConsumption' }, $true)
        $ConsFn | Should -Not -BeNullOrEmpty
        $Gate = @($ConsFn.FindAll({ param($N) $N -is [System.Management.Automation.Language.CommandAst] -and $N.GetCommandName() -eq 'Test-RdaPermanentRequestError' }, $true))
        $Gate.Count | Should -Be 1 -Because 'the consumption page loop must classify a rejected request too'
        $Gate[0].Extent.Text | Should -Match '-Exception \$_\.Exception' -Because 'the status is what decides; the message does not carry it'
    }

    It 'the consumption loop gates BEFORE it consumes a retry attempt' {
        # Scoped to the NEW gate. The Marketplace ordering is owned by
        # Tests/ConsumptionDenialFastFail.Tests.ps1, which also pins its denial/OOM/auth neighbours.
        foreach ($Pair in @(
                @{ Fn = 'GetResourceConsumption'; Budget = '$ConsumptionAttempt++' }
            ))
        {
            $Fn = $script:InvAst.Find([scriptblock]::Create(('param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq ''{0}''' -f $Pair.Fn)), $true)
            $Fn | Should -Not -BeNullOrEmpty
            $Text = $Fn.Extent.Text
            $GateAt = $Text.IndexOf('Test-RdaPermanentRequestError', [System.StringComparison]::Ordinal)
            $BudgetAt = $Text.IndexOf($Pair.Budget, [System.StringComparison]::Ordinal)
            $GateAt | Should -BeGreaterThan -1 -Because ('{0} must have the gate' -f $Pair.Fn)
            $BudgetAt | Should -BeGreaterThan -1
            $GateAt | Should -BeLessThan $BudgetAt -Because ('{0} must settle a rejected request before spending an attempt' -f $Pair.Fn)
        }
    }
}

Describe 'Diagnostic figures outside the billing phases are culture-invariant' {
    # ResourceInventory.ps1 sets CurrentCulture to en-US inside its two billing functions and never
    # restores it, so figures rendered after them print a dot only as a side effect of that leak.
    # Entry points that never call those functions - FindResource.ps1, Reveal.ps1 - got the host
    # culture, and -f is culture-sensitive where PowerShell interpolation is not.
    It '<File> renders its seconds figure through InvariantCulture' -ForEach @(
        @{ File = 'Functions/FindResource.Functions.ps1'; Needle = "Elapsed: \{0\}s" }
        @{ File = 'Reveal.ps1'; Needle = 'timed out after \{0\} minutes' }
    ) {
        $Src = Get-Content -LiteralPath (Join-Path $script:Repo $File) -Raw
        $Line = @($Src -split "`n" | Where-Object { $_ -match $Needle })
        $Line.Count | Should -BeGreaterThan 0 -Because 'the figure must still be there for this to be worth asserting'
        foreach ($L in $Line) { $L | Should -Match 'InvariantCulture' }
    }

    It 'the billing backoff figures no longer depend on the leaked en-US' {
        foreach ($Var in @('ConsumptionBackoffSeconds', 'MpBackoffSeconds'))
        {
            # Anchored on the actual log line, so this cannot be satisfied by an invariant conversion
            # of the same variable somewhere else in the file.
            $Rx = 'Retrying in \{5\}s[^\r\n]*\$' + $Var
            $Hit = @($script:InvSrc -split "`n" | Where-Object { $_ -match $Rx })
            $Hit.Count | Should -Be 1 -Because ('{0} must still be logged on the retry line for this to be worth asserting' -f $Var)
            $Hit[0] | Should -Match 'InvariantCulture' -Because ('{0} must not depend on the en-US the billing function leaks' -f $Var)
        }
    }
}

Describe 'The banner as the renderer actually emits it' {
    # Source-text matches on Summary.ps1 pass whatever the banner renders. These run the real script
    # and read the HTML, the way Tests/VmBillingGap.Tests.ps1 does.
    BeforeAll {
        $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ("CollectorBanner_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:WorkDir -Force | Out-Null

        function script:Render
        {
            param([array]$Failures, [switch]$Aborted)
            $Json = Join-Path $script:WorkDir ("inv_" + [guid]::NewGuid().ToString('N') + '.json')
            [pscustomobject]@{
                Version    = '9.9.9'
                StorageAcc = @([pscustomobject]@{ Subscription = 'Sub A'; ResourceGroup = 'rg'; Name = 'sa'; Location = 'westeurope' })
            } | ConvertTo-Json -Depth 6 | Out-File -LiteralPath $Json -Encoding utf8
            $Html = Join-Path $script:WorkDir ("rep_" + [guid]::NewGuid().ToString('N') + '.html')
            $SummaryArgs = @{ JsonFile = $Json; HtmlFile = $Html; Version = '9.9.9' }
            if ($null -ne $Failures) { $SummaryArgs['CollectorFailures'] = $Failures }
            if ($Aborted) { $SummaryArgs['CollectorsAborted'] = $true }
            & (Join-Path $script:Repo 'Extension/Summary.ps1') @SummaryArgs | Out-Null
            return (Get-Content -LiteralPath $Html -Raw)
        }
    }

    AfterAll {
        if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir)) { Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'says nothing when nothing failed' {
        $Html = script:Render -Failures @()
        $Html | Should -Not -Match 'Incomplete collection'
        $Html | Should -Not -Match 'collection incomplete, see below'
    }

    It 'names the failed type, and qualifies the Service Types header' {
        $Html = script:Render -Failures @([pscustomobject]@{ Module = 'VirtualMachines'; Message = 'boom' })
        $Html | Should -Match 'Incomplete collection'
        $Html | Should -Match '<code>VirtualMachines</code>'
        $Html | Should -Match '1 resource type\(s\) could not be collected'
        $Html | Should -Match 'collection incomplete, see below' -Because 'the header count must not read as complete while the banner says otherwise'
    }

    It 'never puts the exception MESSAGE on the page' {
        # Summary.ps1 has no scrub map, so an exception string could carry real resource ids into an
        # obfuscated report. The page points at the Diagnostics log instead.
        $Html = script:Render -Failures @([pscustomobject]@{ Module = 'VirtualMachines'; Message = 'secret-vm-name-12345 blew up' })
        $Html | Should -Not -Match 'secret-vm-name-12345'
        $Html | Should -Match 'See the Diagnostics log'
    }

    It 'escapes a module name that contains markup' {
        $Html = script:Render -Failures @([pscustomobject]@{ Module = '<img src=x onerror=alert(1)>'; Message = 'x' })
        $Html | Should -Not -Match '<img src=x'
        $Html | Should -Match '&lt;img src=x'
    }

    It 'renders a record with no Module as an unnamed collector rather than dropping the banner' {
        $Html = script:Render -Failures @([pscustomobject]@{ Message = 'no module recorded' })
        $Html | Should -Match 'Incomplete collection' -Because 'a malformed record must not delete the only signal on the page'
        $Html | Should -Match '\(unnamed collector\)'
    }

    It 'marks an aborted run PARTIAL and styles it as an error' {
        $Html = script:Render -Failures @([pscustomobject]@{ Module = 'VirtualMachines'; Message = 'x' }) -Aborted
        $Html | Should -Match 'PARTIAL view of the subscription'
        $Html | Should -Match 'class="coverage-banner collector-abort"'
        $Html | Should -Match '\.collector-abort' -Because 'the style it references has to exist in the inlined CSS'
    }

    It 'does not contradict itself when an abort recorded no individual failures' {
        $Html = script:Render -Failures @() -Aborted
        $Html | Should -Match 'Incomplete collection'
        $Html | Should -Not -Match '0 resource type\(s\)' -Because 'that read as a bug to the operator'
        $Html | Should -Match 'Collection did not complete'
        $Html | Should -Match 'PARTIAL view of the subscription'
    }

    It 'accepts a single object as well as an array' {
        $Html = script:Render -Failures @([pscustomobject]@{ Module = 'AppServices'; Message = 'x' })
        $Html | Should -Match '<code>AppServices</code>'
    }
}

Describe 'An aborted collection is reported as what it is, not as an archive failure' {
    It 'the inner script exits 3 for an abort and keeps 2 for an archive write failure' {
        # 2 made the wrapper say "completed collection but could NOT write a report archive" and advise
        # zipping the folder by hand, both false for a partial inventory.
        $script:InvSrc | Should -Match '\$CollectionAborted = -not \[string\]::IsNullOrWhiteSpace\(\$script:CollectorBreakerError\)'
        $script:InvSrc | Should -Match 'if \(\$CollectionAborted\) \{ exit 3 \}\s*\r?\n\s*exit 2'
    }

    It 'the abort wording says the files are PARTIAL and must not be zipped by hand' {
        $script:InvSrc | Should -Match 'PARTIAL inventory, kept for inspection only - do not zip and ship them'
    }

    It '<Wrapper> collects inner exit 3 separately from inner exit 2' -ForEach @(
        @{ Wrapper = 'Run-AllSubscriptions.ps1'; Sites = 2 }
        @{ Wrapper = 'Run-AllSubscriptions.Stream.ps1'; Sites = 1 }
    ) {
        $Src = Get-Content -LiteralPath (Join-Path $script:Repo $Wrapper) -Raw
        @([regex]::Matches($Src, 'elseif \(\$LASTEXITCODE -eq 3\) \{ \$CollectionAbortedSubs \+=')).Count | Should -Be $Sites -Because 'every place that reads an inner exit code must classify an abort'
        @([regex]::Matches($Src, 'if \(\$LASTEXITCODE -eq 2\) \{ \$ArchiveWriteFailures \+=')).Count | Should -Be $Sites -Because 'the archive-write path is unchanged'
    }

    It 'the stream worker reports its aborted subscriptions, and the parent aggregates them' {
        $Stream = Get-Content -LiteralPath (Join-Path $script:Repo 'Run-AllSubscriptions.Stream.ps1') -Raw
        $Parent = Get-Content -LiteralPath (Join-Path $script:Repo 'Run-AllSubscriptions.ps1') -Raw
        $Stream | Should -Match 'CollectionAbortedSubs\s+=\s+@\(\$CollectionAbortedSubs\)' -Because 'without it a parallel run silently drops the abort'
        $Parent | Should -Match '\$CollectionAbortedSubs \+= @\(\$StreamSummary\.CollectionAbortedSubs\)'
    }

    It 'the wrapper has its own banner for an abort, and still exits 2 because the report is absent' {
        $Parent = Get-Content -LiteralPath (Join-Path $script:Repo 'Run-AllSubscriptions.ps1') -Raw
        $Parent | Should -Match 'FAILED \(collection aborted\)'
        $Parent | Should -Match '(?s)if \(@\(\$CollectionAbortedSubs\)\.Count -gt 0\)\s*\{\s*\$WrapperExitCode = 2\s*\}' -Because 'an aborted report is absent from the bundle, which is exactly what exit 2 documents'
        # The archive banner must not be what an abort reaches.
        # From the title to the banner's own closing rule: the title line itself contains a run of '=',
        # so the capture has to skip past it before looking for the terminator.
        $Banner = [regex]::Match($Parent, '(?s)FAILED \(collection aborted\) =+".*?"={30,}"').Value
        $Banner | Should -Not -BeNullOrEmpty
        $Banner | Should -Not -Match 'could NOT write a report archive'
        $Banner | Should -Match 'Do not zip their report folders by hand'
    }
}

Describe 'Billing is not pulled for a subscription whose collection was aborted' {
    It 'the billing phase is gated on the breaker state' {
        $Gate = [regex]::Match($script:InvSrc, '(?s)if \(-not \[string\]::IsNullOrWhiteSpace\(\$script:CollectorBreakerError\) -and -not \$SkipConsumption\.IsPresent\)\s*\{.*?\}\s*elseif \(!\$SkipConsumption\.IsPresent\)').Value
        $Gate | Should -Not -BeNullOrEmpty -Because 'an aborted subscription must not spend the billing retry budget'
        $Gate | Should -Match '\$script:BillingSkippedForAbort = \$true'
        $Gate | Should -Match "Severity 'Error'" -Because 'skipping a requested phase must be loud, never silent'
        $Gate | Should -Not -Match 'GetResourceConsumption' -Because 'the gated branch must not call the billing pull'
    }

    It 'the skip flag is reset per invocation' {
        $script:InvSrc | Should -Match '\$script:BillingSkippedForAbort = \$false'
    }

    It 'the Diagnostics log is not told billing was requested for a pull that never ran' {
        # Otherwise it reports "requested but zero rows collected", a false negative.
        $Calls = @([regex]::Matches($script:InvSrc, 'Write-RdaShareableDiagnosticsLog [^\r\n]+'))
        $Calls.Count | Should -Be 2
        foreach ($C in $Calls)
        {
            $C.Value | Should -Match '-ConsumptionRequested:\(\(-not \$SkipConsumption\.IsPresent\) -and -not \$script:BillingSkippedForAbort\)'
            $C.Value | Should -Match '-MarketplaceRequested:\([^\r\n]*-and -not \$script:BillingSkippedForAbort\)'
        }
    }
}

Describe 'The console summary does not read clean over an incomplete report' {
    BeforeAll {
        $script:ConsoleDir = Join-Path ([System.IO.Path]::GetTempPath()) ("CollectorConsole_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:ConsoleDir -Force | Out-Null
        $script:ConsoleJson = Join-Path $script:ConsoleDir 'inv.json'
        [pscustomobject]@{
            Version    = '9.9.9'
            StorageAcc = @([pscustomobject]@{ Subscription = 'Sub A'; ResourceGroup = 'rg'; Name = 'sa'; Location = 'westeurope' })
        } | ConvertTo-Json -Depth 6 | Out-File -LiteralPath $script:ConsoleJson -Encoding utf8

        function script:Get-ConsoleLines
        {
            param([array]$Failures, [switch]$Aborted)
            $HtmlPath = Join-Path $script:ConsoleDir ("rep_" + [guid]::NewGuid().ToString('N') + '.html')
            $SummaryArgs = @{ JsonFile = $script:ConsoleJson; HtmlFile = $HtmlPath; Version = '9.9.9'; CollectorFailures = $Failures }
            if ($Aborted) { $SummaryArgs['CollectorsAborted'] = $true }
            # Write-Host goes to the information stream; 6>&1 captures it.
            return @(& (Join-Path $script:Repo 'Extension/Summary.ps1') @SummaryArgs 6>&1 | ForEach-Object { [string]$_ })
        }
    }

    AfterAll {
        if ($script:ConsoleDir -and (Test-Path -LiteralPath $script:ConsoleDir)) { Remove-Item -LiteralPath $script:ConsoleDir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'prints nothing extra when nothing failed' {
        $Lines = script:Get-ConsoleLines -Failures @()
        @($Lines | Where-Object { $_ -match 'Collection (ABORTED|INCOMPLETE)' }).Count | Should -Be 0
    }

    It 'ends with an INCOMPLETE line naming the failed type' {
        $Lines = script:Get-ConsoleLines -Failures @([pscustomobject]@{ Module = 'VirtualMachines'; Message = 'x' })
        $Lines[-1] | Should -Match 'Collection INCOMPLETE: 1 resource type\(s\) missing because the collector errored: VirtualMachines' -Because 'it has to be the LAST line, so the operator cannot read the run as clean'
    }

    It 'ends with an ABORTED line for a breaker trip' {
        $Lines = script:Get-ConsoleLines -Failures @([pscustomobject]@{ Module = 'VirtualMachines'; Message = 'x' }) -Aborted
        $Lines[-1] | Should -Match 'Collection ABORTED: this is a PARTIAL report'
    }

    It 'never prints the exception message to the console either' {
        $Lines = script:Get-ConsoleLines -Failures @([pscustomobject]@{ Module = 'VirtualMachines'; Message = 'secret-vm-name-12345 blew up' })
        ($Lines -join "`n") | Should -Not -Match 'secret-vm-name-12345'
    }
}
