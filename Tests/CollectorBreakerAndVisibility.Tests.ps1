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

    A fourth, related fix is pinned by the 'culture-invariant' Describe: ResourceInventory.ps1 sets CurrentCulture to
    en-US inside its two billing functions and never restores it, so figures elsewhere printed a dot
    only as a side effect of that leak, and entry points that never call those functions got the host
    culture. It is here rather than in its own file because it shares the root cause with nothing else
    and shipped in the same change; look here for a culture regression in FindResource or Reveal.

    The later Describes cover what reaches the consolidated bundle once a subscription fails: the
    one selection of what may ship (Select-RdaShippableReports), MainSummary.html counting and
    listing, the VM placement parts, the wrapper's reconciliation, exit override, parallel -Resume
    filter, stranded-state recovery and banners. The last wrapper-facing Describe covers what a stream
    worker records so its parent can ship its finished reports if it dies before its summary, and the
    per-stream state that every start (not only -Resume) merges and removes once it is saved. Where the
    code can run, a block is lifted out of the wrapper by its AST and executed as written with its
    Azure calls shimmed.
    NOT pinned here, and it needs planted failing collectors so it cannot be: the OUTPUT-level
    consequence that types after an abort are ABSENT from Inventory_*.json rather than present as [].
    The end-to-end run below is the record for that; the structural assertions are not a substitute.

    Verified end to end before the fix was called done, by planting deliberately failing collectors
    in Services/: one failure now names the type in the report, and five consecutive failures stop
    collection at the fifth (the sixth is never attempted), report the subscription FAILED, exit 3,
    and remove the archive so the wrapper cannot consolidate it. Through the real wrapper, the
    subscription is then reported under its own FAILED (collection aborted) banner.
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
        # The gate owns "report this subscription FAILED + remove the unusable archive + exit 3" (2 stays
        # the archive-write code), so the wrapper cannot fold a partial report into the consolidated bundle.
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

    It 'both call sites say WHY billing did not run through closed switches, not free text' {
        $CallAsts = @($script:InvAst.FindAll({ param($N) $N -is [System.Management.Automation.Language.CommandAst] -and $N.GetCommandName() -eq 'Write-RdaShareableDiagnosticsLog' }, $true))
        $CallAsts.Count | Should -Be 2
        foreach ($Call in $CallAsts)
        {
            $Params = @($Call.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] })
            $Consumption = @($Params | Where-Object { $_.ParameterName -eq 'ConsumptionSkippedForAbort' })
            $Marketplace = @($Params | Where-Object { $_.ParameterName -eq 'MarketplaceSkippedForAbort' })
            $Consumption.Count | Should -Be 1
            $Marketplace.Count | Should -Be 1
            $Consumption[0].Argument.Extent.Text | Should -Be '([bool]$script:BillingSkippedForAbort)'
            # Marketplace was never going to run under -SkipMarketplace, so the switch is the reason then.
            $Marketplace[0].Argument.Extent.Text | Should -Be '([bool]$script:BillingSkippedForAbort -and -not $SkipMarketplace.IsPresent)'
            @($Params | Where-Object { $_.ParameterName -like '*SkipReason' }).Count | Should -Be 0
        }
    }

    It 'the builder takes those reasons as closed switches, and no free-text reason' {
        $FnPath = Join-Path $script:Repo 'Functions/ResourceInventory.Functions.ps1'
        $FnErrors = $null
        $FnAst = [System.Management.Automation.Language.Parser]::ParseFile($FnPath, [ref]$null, [ref]$FnErrors)
        @($FnErrors).Count | Should -Be 0 -Because 'a partial AST could pass the checks below vacuously'
        $Builder = $FnAst.Find({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq 'Write-RdaShareableDiagnosticsLog' }, $true)
        $Builder | Should -Not -BeNullOrEmpty
        $Declared = @{}
        foreach ($P in $Builder.Body.ParamBlock.Parameters) { $Declared[$P.Name.VariablePath.UserPath] = $P.StaticType.Name }
        $Declared['ConsumptionSkippedForAbort'] | Should -Be 'SwitchParameter'
        $Declared['MarketplaceSkippedForAbort'] | Should -Be 'SwitchParameter'
        @($Declared.Keys | Where-Object { $_ -like '*Reason*' }).Count | Should -Be 0 -Because 'a caller-supplied string would reach the shipped log unscrubbed'
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

Describe 'A partial inventory is never presented as a report' {
    # Behavioural: the helpers are called directly, and the aggregate summary is rendered for real.
    BeforeAll {
        . (Join-Path $script:Repo 'Functions/Common.Functions.ps1')
        . (Join-Path $script:Repo 'Functions/RunAllSubscriptions.Functions.ps1')
        . (Join-Path $script:Repo 'Functions/ResourceInventory.Functions.ps1')
        . (Join-Path $script:Repo 'Functions/AllSubHtmlSummary.Functions.ps1')

        # The diagnostics writer reads the run-wide failure lists from the session; isolate from them.
        $script:SavedLists = @{}
        foreach ($Name in 'ConsumptionFailedSubs', 'MetricsFailedSubs', 'MarketplaceFailedSubs', 'CollectorFailures')
        {
            $Existing = Get-Variable -Name $Name -Scope Global -ErrorAction SilentlyContinue
            $script:SavedLists[$Name] = if ($Existing) { @{ Value = $Existing.Value } } else { $null }
            Remove-Variable -Name $Name -Scope Global -ErrorAction SilentlyContinue
        }

        $script:PartialDir = Join-Path ([System.IO.Path]::GetTempPath()) ("PartialInv_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:PartialDir -Force | Out-Null

        function script:New-ReportFolder
        {
            param([string]$Name, [string]$Sub)
            $Dir = Join-Path $script:PartialDir $Name
            New-Item -ItemType Directory -Path $Dir -Force | Out-Null
            [pscustomobject]@{
                Version    = '9.9.9'
                StorageAcc = @([pscustomobject]@{ Subscription = $Sub; ResourceGroup = 'rg'; Name = 'sa'; Location = 'westeurope' })
            } | ConvertTo-Json -Depth 6 | Out-File -LiteralPath (Join-Path $Dir 'Inventory_x.json') -Encoding utf8
            return $Dir
        }
    }

    AfterAll {
        foreach ($Name in $script:SavedLists.Keys)
        {
            if ($null -ne $script:SavedLists[$Name]) { Set-Variable -Name $Name -Scope Global -Value $script:SavedLists[$Name].Value }
        }
        if ($script:PartialDir -and (Test-Path -LiteralPath $script:PartialDir)) { Remove-Item -LiteralPath $script:PartialDir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'the marker is detected, and only where it was written' {
        $Aborted = script:New-ReportFolder -Name 'ResourcesReportAborted' -Sub 'Sub Partial'
        $Complete = script:New-ReportFolder -Name 'ResourcesReportComplete' -Sub 'Sub Whole'
        Set-Content -LiteralPath (Get-RdaCollectionAbortedMarkerPath -Folder $Aborted) -Value 'x'

        Test-RdaCollectionAborted -Folder $Aborted | Should -BeTrue
        Test-RdaCollectionAborted -Folder $Complete | Should -BeFalse
        Test-RdaCollectionAborted -Folder '' | Should -BeFalse
        Test-RdaCollectionAborted -Folder (Join-Path $script:PartialDir 'does-not-exist') | Should -BeFalse
    }

    It 'MainSummary lists only the folders it is told to, so the partial one stays out' {
        $Html = Join-Path $script:PartialDir 'main.html'
        New-RdaAllSubHtmlSummary -RunOutputDirectory $script:PartialDir -HtmlFile $Html -IncludeFolders @('ResourcesReportComplete') -Version '9.9.9' | Out-Null
        $Text = Get-Content -LiteralPath $Html -Raw
        $Text | Should -Match 'Sub Whole'
        $Text | Should -Not -Match 'Sub Partial' -Because 'a partial inventory must not appear as a normal processed row'
    }

    It 'MainSummary lists every report folder when it is not told which' {
        $Html = Join-Path $script:PartialDir 'main-all.html'
        New-RdaAllSubHtmlSummary -RunOutputDirectory $script:PartialDir -HtmlFile $Html -Version '9.9.9' | Out-Null
        $Text = Get-Content -LiteralPath $Html -Raw
        $Text | Should -Match 'Sub Whole'
        $Text | Should -Match 'Sub Partial'
    }

    It 'names each inner exit code so it cannot be misread as the wrapper''s own' {
        Get-InventoryExitCodeMeaning -Code 3 | Should -Match 'aborted'
        Get-InventoryExitCodeMeaning -Code 2 | Should -Match 'archive could not be written'
        Get-InventoryExitCodeMeaning -Code 1 | Should -Match 'pre-flight'
        Get-InventoryExitCodeMeaning -Code 42 | Should -Match 'unexpected'
    }

    It 'RunSummary.log counts aborted and archive-failed subscriptions separately' {
        $Lines = @(Get-RunSummaryLogContent -Version '9.9.9' -StartTime (Get-Date) -EndTime (Get-Date) -Eligible 3 -Processed 3 `
                -FailedSubscriptions @('a', 'b', 'c') -CollectionAbortedSubs @('a (id-a)', 'b (id-b)') -ArchiveWriteFailures @('c (id-c)'))
        $Text = $Lines -join "`n"
        $Text | Should -Match 'of which collection aborted : 2'
        $Text | Should -Match 'of which archive not written: 1'
    }

    It 'RunSummary.log reports zero for both when nothing failed' {
        $Text = @(Get-RunSummaryLogContent -Version '9.9.9' -StartTime (Get-Date) -EndTime (Get-Date) -Eligible 1 -Processed 1) -join "`n"
        $Text | Should -Match 'of which collection aborted : 0'
        $Text | Should -Match 'of which archive not written: 0'
    }

    It 'the Diagnostics log names an abort as the reason billing did not run, not a -Skip switch' {
        $File = Write-RdaShareableDiagnosticsLog -DefaultPath ($script:PartialDir + [IO.Path]::DirectorySeparatorChar) -ReportName 'R' -RunDateTime 'abort1' -Version '9.9.9' -PhaseTimings $null `
            -ConsumptionRecordCount 0 -ConsumptionRequested $false -MarketplaceRecordCount 0 -MarketplaceRequested $false `
            -ConsumptionSkippedForAbort -MarketplaceSkippedForAbort
        $Text = Get-Content -LiteralPath $File -Raw
        $Text | Should -Match 'Consumption records collected: n/a \(not pulled because collection was aborted by the circuit breaker\)'
        $Text | Should -Match 'Marketplace consumption records collected: n/a \(not pulled because collection was aborted by the circuit breaker\)'
        $Text | Should -Not -Match 'SkipConsumption was passed' -Because 'the operator passed no such switch'
        $Text | Should -Not -Match 'ZERO usage records were collected' -Because 'no pull ran, so a zero-rows warning would be false'
    }

    It 'the Diagnostics log still names the -Skip switch when that was the reason' {
        $File = Write-RdaShareableDiagnosticsLog -DefaultPath ($script:PartialDir + [IO.Path]::DirectorySeparatorChar) -ReportName 'R' -RunDateTime 'skip1' -Version '9.9.9' -PhaseTimings $null `
            -ConsumptionRecordCount 0 -ConsumptionRequested $false -MarketplaceRequested $false
        (Get-Content -LiteralPath $File -Raw) | Should -Match 'Consumption records collected: n/a \(-SkipConsumption was passed\)'
    }

    It 'the Diagnostics log names the -Skip switch for Marketplace when only Consumption was aborted' {
        $File = Write-RdaShareableDiagnosticsLog -DefaultPath ($script:PartialDir + [IO.Path]::DirectorySeparatorChar) -ReportName 'R' -RunDateTime 'abort2' -Version '9.9.9' -PhaseTimings $null `
            -ConsumptionRecordCount 0 -ConsumptionRequested $false -MarketplaceRecordCount 0 -MarketplaceRequested $false -ConsumptionSkippedForAbort
        $Text = Get-Content -LiteralPath $File -Raw
        $Text | Should -Match 'Consumption records collected: n/a \(not pulled because collection was aborted by the circuit breaker\)'
        $Text | Should -Match 'Marketplace consumption records collected: n/a \(-SkipMarketplace or -SkipConsumption was passed\)'
    }
}

Describe 'MainSummary.html counts and lists what the wrapper says' {
    BeforeAll {
        . (Join-Path $script:Repo 'Functions/AllSubHtmlSummary.Functions.ps1')
        $script:MsDir = Join-Path ([System.IO.Path]::GetTempPath()) ("MainSum_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:MsDir -Force | Out-Null
        function script:New-MsFolder
        {
            param([string]$Name, [object[]]$Records = @())
            $Dir = Join-Path $script:MsDir $Name
            New-Item -ItemType Directory -Path $Dir -Force | Out-Null
            $Inv = [ordered]@{ Version = '9.9.9' }
            if ($Records.Count -gt 0) { $Inv['StorageAcc'] = $Records }
            [pscustomobject]$Inv | ConvertTo-Json -Depth 6 | Out-File -LiteralPath (Join-Path $Dir 'Inventory_x.json') -Encoding utf8
            'x' | Out-File -LiteralPath (Join-Path $Dir 'ResourcesReport_x.html') -Encoding utf8
            return $Dir
        }
        # A subscription whose only resources have no collector: discovery found 1, the inventory holds 0.
        $script:Uncovered = script:New-MsFolder -Name 'ResourcesReportUncovered'
        # A genuinely empty subscription.
        $script:Empty = script:New-MsFolder -Name 'ResourcesReportEmpty'
        # An aborted collection that recorded nothing before it stopped.
        $script:AbortedEmpty = script:New-MsFolder -Name 'ResourcesReportAbortedEmpty'
        $script:Whole = script:New-MsFolder -Name 'ResourcesReportWhole' -Records @([pscustomobject]@{ Subscription = 'Sub Whole'; Name = 'sa'; ResourceGroup = 'rg' })
        # A report whose inventory cannot be read, for a subscription discovery found empty.
        $script:Corrupt = Join-Path $script:MsDir 'ResourcesReportCorrupt'
        New-Item -ItemType Directory -Path $script:Corrupt -Force | Out-Null
        '{ not json' | Out-File -LiteralPath (Join-Path $script:Corrupt 'Inventory_x.json') -Encoding utf8
        $script:Processed = @(
            [pscustomobject]@{ Name = 'Sub Uncovered'; Id = 'id-u'; Count = 1; Zip = (Join-Path $script:Uncovered 'ResourcesReport_x.zip') }
            [pscustomobject]@{ Name = 'Sub Empty'; Id = 'id-e'; Count = 0; Zip = (Join-Path $script:Empty 'ResourcesReport_x.zip') }
            [pscustomobject]@{ Name = 'Sub Whole'; Id = 'id-w'; Count = 1; Zip = (Join-Path $script:Whole 'ResourcesReport_x.zip') }
            [pscustomobject]@{ Name = 'Sub Corrupt'; Id = 'id-c'; Count = 0; Zip = (Join-Path $script:Corrupt 'ResourcesReport_x.zip') }
        )
        $script:Listed = @('ResourcesReportUncovered', 'ResourcesReportEmpty', 'ResourcesReportWhole')
        function script:Get-EmptyCard
        {
            param([string]$Html)
            $M = [regex]::Match((Get-Content -LiteralPath $Html -Raw), '<div class="n">(\d+)</div><div class="l">Empty \(0 resources\)</div>')
            if (-not $M.Success) { throw 'the Empty card was not found' }
            return [int]$M.Groups[1].Value
        }
        function script:Get-RowCount
        {
            param([string]$Html)
            return ([regex]::Matches((Get-Content -LiteralPath $Html -Raw), '<tr><td>')).Count
        }
    }

    AfterAll {
        if ($script:MsDir -and (Test-Path -LiteralPath $script:MsDir)) { Remove-Item -LiteralPath $script:MsDir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It '"0 resources" is what discovery found, not how many records the collectors wrote' {
        $Html = Join-Path $script:MsDir 'count.html'
        New-RdaAllSubHtmlSummary -RunOutputDirectory $script:MsDir -HtmlFile $Html -ProcessedSubscriptions $script:Processed -IncludeFolders $script:Listed -Version '9.9.9' | Out-Null
        script:Get-EmptyCard -Html $Html | Should -Be 1 -Because 'only the genuinely empty subscription returned 0 resources'
        $Text = Get-Content -LiteralPath $Html -Raw
        $Text | Should -Match '<b>1 subscription\(s\) returned 0 resources\.</b>'
        # The uncovered one is neither "ok" nor "0 resources": it has resources the collectors do not cover.
        $Text | Should -Match '<tr><td>\(name unavailable\)</td><td class="num">0</td><td><span class="tag warn">none of a collected type</span>'
        $Text | Should -Match '<tr><td>\(name unavailable - 0 resources\)</td><td class="num">0</td><td><span class="tag warn">0 resources</span>'
    }

    It 'a folder it was not told to list is neither a row nor an empty subscription' {
        $Html = Join-Path $script:MsDir 'listed.html'
        New-RdaAllSubHtmlSummary -RunOutputDirectory $script:MsDir -HtmlFile $Html -ProcessedSubscriptions $script:Processed -IncludeFolders $script:Listed -Version '9.9.9' | Out-Null
        script:Get-RowCount -Html $Html | Should -Be 3
        $Text = Get-Content -LiteralPath $Html -Raw
        $Text | Should -Not -Match 'ResourcesReportAbortedEmpty'
        $Text | Should -Not -Match 'ResourcesReportCorrupt'
    }

    It 'an unreadable inventory still counts as empty when discovery found nothing' {
        $Html = Join-Path $script:MsDir 'corrupt.html'
        New-RdaAllSubHtmlSummary -RunOutputDirectory $script:MsDir -HtmlFile $Html -ProcessedSubscriptions $script:Processed -IncludeFolders ($script:Listed + 'ResourcesReportCorrupt') -Version '9.9.9' | Out-Null
        script:Get-EmptyCard -Html $Html | Should -Be 2
        (Get-Content -LiteralPath $Html -Raw) | Should -Match 'unreadable inventory: ResourcesReportCorrupt'
    }

    It 'without the wrapper''s counts it falls back to the record count' {
        # A rebuild from a zip has no discovery counts, so there an uncovered-type subscription is still
        # counted as empty; docs/design/main-html-summary.md records the limitation.
        $Html = Join-Path $script:MsDir 'fallback.html'
        New-RdaAllSubHtmlSummary -RunOutputDirectory $script:MsDir -HtmlFile $Html -IncludeFolders $script:Listed -Version '9.9.9' | Out-Null
        script:Get-EmptyCard -Html $Html | Should -Be 2
        (Get-Content -LiteralPath $Html -Raw) | Should -Match '<b>2 subscription\(s\) returned 0 resources\.</b>'
    }

    It 'a subscription whose collector failed is tagged so, not as a coverage gap' {
        $Html = Join-Path $script:MsDir 'collector.html'
        $Failures = @([pscustomobject]@{ Id = 'id-u'; Module = 'CognitiveServices'; Message = 'm' })
        New-RdaAllSubHtmlSummary -RunOutputDirectory $script:MsDir -HtmlFile $Html -ProcessedSubscriptions $script:Processed -IncludeFolders $script:Listed -CollectorFailures $Failures -Version '9.9.9' | Out-Null
        $Text = Get-Content -LiteralPath $Html -Raw
        $Text | Should -Match '<tr><td>\(name unavailable\)</td><td class="num">0</td><td><span class="tag warn">collector failed</span>'
        $Text | Should -Not -Match 'none of a collected type'
    }

    It 'a subscription whose collector failed is tagged so even when it has records' {
        $Html = Join-Path $script:MsDir 'collector-records.html'
        $Failures = @([pscustomobject]@{ Id = 'id-w'; Module = 'AKS'; Message = 'm' })
        New-RdaAllSubHtmlSummary -RunOutputDirectory $script:MsDir -HtmlFile $Html -ProcessedSubscriptions $script:Processed -IncludeFolders $script:Listed -CollectorFailures $Failures -Version '9.9.9' | Out-Null
        (Get-Content -LiteralPath $Html -Raw) | Should -Match '<tr><td>Sub Whole</td><td class="num">1</td><td><span class="tag warn">collector failed</span>' -Because 'a type is missing from that report, so it is not "ok"'
    }

    It 'warns when a folder it was told to list has no inventory' {
        $NoInv = Join-Path $script:MsDir 'ResourcesReportNoInventory'
        New-Item -ItemType Directory -Path $NoInv -Force | Out-Null
        try
        {
            $Html = Join-Path $script:MsDir 'noinv.html'
            New-RdaAllSubHtmlSummary -RunOutputDirectory $script:MsDir -HtmlFile $Html -IncludeFolders @('ResourcesReportWhole', 'ResourcesReportNoInventory') -Version '9.9.9' -WarningVariable Warned -WarningAction SilentlyContinue | Out-Null
            @($Warned).Count | Should -Be 1
            [string]$Warned[0] | Should -Match 'ResourcesReportNoInventory has no Inventory_\*\.json'
            script:Get-RowCount -Html $Html | Should -Be 1
        }
        finally { Remove-Item -LiteralPath $NoInv -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'matches a folder by name, however the caller spelled its path' {
        $Html = Join-Path $script:MsDir 'spelled.html'
        $Spelled = @(
            ($script:Uncovered + [IO.Path]::DirectorySeparatorChar)
            (Join-Path (Join-Path $script:MsDir 'elsewhere') (Join-Path '..' 'ResourcesReportEmpty'))
            'ResourcesReportWhole'
        )
        New-RdaAllSubHtmlSummary -RunOutputDirectory $script:MsDir -HtmlFile $Html -ProcessedSubscriptions $script:Processed -IncludeFolders $Spelled -Version '9.9.9' -WarningVariable Warned -WarningAction SilentlyContinue | Out-Null
        script:Get-RowCount -Html $Html | Should -Be 3
        @($Warned).Count | Should -Be 0
    }

    It 'warns when a folder it was told to list is not there' {
        $Html = Join-Path $script:MsDir 'unmatched.html'
        New-RdaAllSubHtmlSummary -RunOutputDirectory $script:MsDir -HtmlFile $Html -IncludeFolders @('ResourcesReportWhole', 'ResourcesReportGone') -Version '9.9.9' -WarningVariable Warned -WarningAction SilentlyContinue | Out-Null
        @($Warned).Count | Should -Be 1
        [string]$Warned[0] | Should -Match 'ResourcesReportGone'
        script:Get-RowCount -Html $Html | Should -Be 1
    }
}

Describe 'The bundle carries only what the completed subscriptions recorded' {
    BeforeAll {
        . (Join-Path $script:Repo 'Functions/Common.Functions.ps1')
        . (Join-Path $script:Repo 'Functions/RunAllSubscriptions.Functions.ps1')
        . (Join-Path $script:Repo 'Functions/AllSubHtmlSummary.Functions.ps1')
        $script:ShipDir = Join-Path ([System.IO.Path]::GetTempPath()) ("Ship_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:ShipDir -Force | Out-Null
        $script:Since = (Get-Date).AddMinutes(-1)
        function script:New-ShipFolder
        {
            param([string]$Name, [switch]$Zip, [switch]$Marker)
            $Dir = Join-Path $script:ShipDir $Name
            New-Item -ItemType Directory -Path $Dir -Force | Out-Null
            if ($Zip) { 'z' | Out-File -LiteralPath (Join-Path $Dir 'ResourcesReport_x.zip') -Encoding utf8 }
            [pscustomobject]@{ Version = '9.9.9'; StorageAcc = @([pscustomobject]@{ Subscription = ('Sub ' + $Name); Name = 'sa' }) } |
                ConvertTo-Json -Depth 6 | Out-File -LiteralPath (Join-Path $Dir 'Inventory_x.json') -Encoding utf8
            if ($Marker) { 'm' | Out-File -LiteralPath (Get-RdaCollectionAbortedMarkerPath -Folder $Dir) -Encoding utf8 }
            return $Dir
        }
        $script:Done = script:New-ShipFolder -Name 'ResourcesReportDone' -Zip
        $script:Marked = script:New-ShipFolder -Name 'ResourcesReportMarked' -Zip -Marker
        # Aborted, but the marker could not be written and the archive could not be removed.
        $script:Unmarked = script:New-ShipFolder -Name 'ResourcesReportUnmarked' -Zip
        # Not a report folder: the bundle never carries it.
        $script:Other = script:New-ShipFolder -Name 'SomethingElse' -Zip
        $script:DoneEntry = [pscustomobject]@{ Name = 'Done'; Id = 'id-d'; Count = 3; Zip = (Join-Path $script:Done 'ResourcesReport_x.zip') }
        function script:Get-Leaf { param($Paths) @($Paths | ForEach-Object { Split-Path -Path (Split-Path -Path $_ -Parent) -Leaf } | Sort-Object) }
    }

    AfterAll {
        if ($script:ShipDir -and (Test-Path -LiteralPath $script:ShipDir)) { Remove-Item -LiteralPath $script:ShipDir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'ships exactly the recorded archive and folder, and names every other report folder it left out' {
        $Sel = Select-RdaShippableReports -InventoryRoot $script:ShipDir -SinceTime $script:Since -ProcessedSubscriptions @($script:DoneEntry)
        @($Sel.PSObject.Properties.Name | Sort-Object) | Should -Be @('Archives', 'Folders', 'LeftOut') -Because 'the record is the only source, so there is no mode to report'
        @($Sel.Archives) | Should -Be @($script:DoneEntry.Zip)
        @($Sel.Folders | ForEach-Object { $_.Name }) | Should -Be @('ResourcesReportDone')
        $Reasons = @{}
        foreach ($L in $Sel.LeftOut) { $Reasons[$L.Name] = $L.Reason }
        $Reasons['ResourcesReportMarked'] | Should -Be 'Aborted'
        $Reasons['ResourcesReportUnmarked'] | Should -Be 'NotRecorded' -Because 'a partial folder with no marker must still stay out'
        $Reasons.Count | Should -Be 2 -Because 'SomethingElse is not a report folder, so it is neither shipped nor reported'
    }

    It 'with no completed subscription it ships nothing' {
        $Sel = Select-RdaShippableReports -InventoryRoot $script:ShipDir -SinceTime $script:Since -ProcessedSubscriptions @()
        @($Sel.Archives).Count | Should -Be 0
        @($Sel.Folders).Count | Should -Be 0
        @($Sel.LeftOut).Count | Should -Be 3
    }

    It 'an entry with no usable archive path ships nothing, says so, and no report folder is swept in its place' {
        foreach ($Unusable in @($null, '', 'ResourcesReport_x.zip'))
        {
            $NoZip = [pscustomobject]@{ Name = 'Legacy'; Id = 'id-l'; Count = 1; Zip = $Unusable }
            $Sel = Select-RdaShippableReports -InventoryRoot $script:ShipDir -SinceTime $script:Since -ProcessedSubscriptions @($script:DoneEntry, $NoZip) -WarningVariable Warned -WarningAction SilentlyContinue
            @($Sel.Archives) | Should -Be @($script:DoneEntry.Zip) -Because ('the unmarked partial folder must not ship on the back of a short record (Zip = "{0}")' -f $Unusable)
            @($Sel.Folders | ForEach-Object { $_.Name }) | Should -Be @('ResourcesReportDone')
            @($Sel.LeftOut | ForEach-Object { $_.Name } | Sort-Object) | Should -Be @('ResourcesReportMarked', 'ResourcesReportUnmarked')
            @($Warned).Count | Should -Be 1
            [string]$Warned[0] | Should -Match 'Subscription id-l completed but recorded no usable report path'
        }
        (Get-Command Select-RdaShippableReports).Parameters.ContainsKey('RecordIncomplete') | Should -BeFalse -Because 'no caller can switch the selection to a sweep'
    }
    It 'a recorded folder ships with its archive even when it predates the run' {
        $Sel = Select-RdaShippableReports -InventoryRoot $script:ShipDir -SinceTime (Get-Date).AddMinutes(5) -ProcessedSubscriptions @($script:DoneEntry)
        @($Sel.Archives) | Should -Be @($script:DoneEntry.Zip)
        @($Sel.Folders | ForEach-Object { $_.Name }) | Should -Be @('ResourcesReportDone') -Because 'archive and folder come from the same record'
        @($Sel.LeftOut).Count | Should -Be 0
    }

    It 'a recorded archive that is gone is not shipped, which is what trips the count check' {
        $Lost = Join-Path $script:ShipDir 'ResourcesReportLost'
        New-Item -ItemType Directory -Path $Lost -Force | Out-Null
        try
        {
            $LostEntry = [pscustomobject]@{ Name = 'Lost'; Id = 'id-x'; Count = 1; Zip = (Join-Path $Lost 'ResourcesReport_x.zip') }
            $Sel = Select-RdaShippableReports -InventoryRoot $script:ShipDir -SinceTime $script:Since -ProcessedSubscriptions @($LostEntry)
            @($Sel.Archives).Count | Should -Be 0
            @($Sel.Folders | ForEach-Object { $_.Name }) | Should -Be @('ResourcesReportLost')
        }
        finally { Remove-Item -LiteralPath $Lost -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'a recorded archive in a folder marked aborted is not shipped' {
        $MarkedEntry = [pscustomobject]@{ Name = 'Marked'; Id = 'id-m'; Count = 1; Zip = (Join-Path $script:Marked 'ResourcesReport_x.zip') }
        $Sel = Select-RdaShippableReports -InventoryRoot $script:ShipDir -SinceTime $script:Since -ProcessedSubscriptions @($MarkedEntry)
        @($Sel.Archives).Count | Should -Be 0
        @($Sel.Folders).Count | Should -Be 0
        @($Sel.LeftOut | Where-Object { $_.Name -eq 'ResourcesReportMarked' }).Reason | Should -Be 'Aborted'
    }

    It 'says so when the report folders cannot be listed' {
        $Missing = Join-Path $script:ShipDir 'no-such-root'
        $Sel = Select-RdaShippableReports -InventoryRoot $Missing -SinceTime $script:Since -ProcessedSubscriptions @() -WarningVariable Warned -WarningAction SilentlyContinue
        @($Warned).Count | Should -Be 1
        [string]$Warned[0] | Should -Match 'Could not list the report folders'
        [string]$Warned[0] | Should -Match 'left out of the bundle may be incomplete' -Because 'the record decides what ships, so only the left-out list is affected'
        @($Sel.Archives).Count | Should -Be 0
    }

    It 'MainSummary lists a recorded folder that predates the run, as the bundle does' {
        $Later = (Get-Date).AddMinutes(5)
        $Sel = Select-RdaShippableReports -InventoryRoot $script:ShipDir -SinceTime $Later -ProcessedSubscriptions @($script:DoneEntry)
        $Html = Join-Path $script:ShipDir 'main-late.html'
        New-RdaAllSubHtmlSummary -RunOutputDirectory $script:ShipDir -HtmlFile $Html -SinceTime $Later -ProcessedSubscriptions @($script:DoneEntry) -IncludeFolders @($Sel.Folders | ForEach-Object { $_.Name }) -Version '9.9.9' -WarningVariable Warned -WarningAction SilentlyContinue | Out-Null
        $Rows = @([regex]::Matches((Get-Content -LiteralPath $Html -Raw), '<tr><td>([^<]*)</td>') | ForEach-Object { $_.Groups[1].Value })
        $Rows | Should -Be @('Sub ResourcesReportDone')
        @($Warned).Count | Should -Be 0 -Because 'the folder is there; only its timestamp is early'
    }

    It 'MainSummary, given the selection, lists exactly the folders the bundle carries' {
        $Sel = Select-RdaShippableReports -InventoryRoot $script:ShipDir -SinceTime $script:Since -ProcessedSubscriptions @($script:DoneEntry)
        $Html = Join-Path $script:ShipDir 'main.html'
        New-RdaAllSubHtmlSummary -RunOutputDirectory $script:ShipDir -HtmlFile $Html -SinceTime $script:Since -ProcessedSubscriptions @($script:DoneEntry) -IncludeFolders @($Sel.Folders | ForEach-Object { $_.Name }) -Version '9.9.9' | Out-Null
        $Rows = @([regex]::Matches((Get-Content -LiteralPath $Html -Raw), '<tr><td>([^<]*)</td>') | ForEach-Object { $_.Groups[1].Value })
        $Rows | Should -Be @('Sub ResourcesReportDone')
    }
}

Describe 'The wrapper reports every missing report, and never exits 0 over one' {
    BeforeAll {
        $script:WrapSrc = Get-Content -LiteralPath (Join-Path $script:Repo 'Run-AllSubscriptions.ps1') -Raw
        $WrapErrors = $null
        $script:WrapAst = [System.Management.Automation.Language.Parser]::ParseInput($script:WrapSrc, [ref]$null, [ref]$WrapErrors)
        if ($null -ne $WrapErrors -and $WrapErrors.Count -gt 0) { throw ('Run-AllSubscriptions.ps1 does not parse: {0}' -f $WrapErrors[0].Message) }
    }

    It 'any failed subscription forces exit 2, including a stream worker that died' {
        $script:WrapSrc | Should -Match '(?s)if \(@\(\$FailedSubscriptionIds\)\.Count -gt 0\)\s*\{\s*\$WrapperExitCode = 2\s*\}'
        # Placed AFTER Get-WrapperExitCode, so it overrides 3-5 as the README says 2 does.
        $Derive = $script:WrapSrc.IndexOf('$WrapperExitCode = Get-WrapperExitCode', [System.StringComparison]::Ordinal)
        $Override = $script:WrapSrc.IndexOf('if (@($FailedSubscriptionIds).Count -gt 0)', $Derive, [System.StringComparison]::Ordinal)
        $Derive | Should -BeGreaterThan -1
        $Override | Should -BeGreaterThan $Derive
        # Every failure entry has its id recorded beside it, a dead stream under its stream name.
        $Adds = @([regex]::Matches($script:WrapSrc, '\$FailedSubscriptions \+= [^\r\n]+\r?\n\s*\$FailedSubscriptionIds \+= ')).Count
        $Adds | Should -Be @([regex]::Matches($script:WrapSrc, '\$FailedSubscriptions \+= ')).Count
        $Adds | Should -Be 5
    }

    It 'a subscription deleted mid-run leaves every failure list, and a real failure still forces exit 2' {
        # The reconciliation and the override, run as written, with the end-of-run listing shimmed.
        $Recon = $script:WrapAst.Find({ param($N) $N -is [System.Management.Automation.Language.IfStatementAst] -and $N.Clauses[0].Item1.Extent.Text -eq '$StartIds.Count -gt 0' }, $true)
        $Override = $script:WrapAst.Find({ param($N) $N -is [System.Management.Automation.Language.IfStatementAst] -and $N.Clauses[0].Item1.Extent.Text -eq '@($FailedSubscriptionIds).Count -gt 0' }, $true)
        $Recon | Should -Not -BeNullOrEmpty
        $Override | Should -Not -BeNullOrEmpty
        $Recon.Extent.StartOffset | Should -BeLessThan $Override.Extent.StartOffset -Because 'the override must see the reconciled lists'
        . (Join-Path $script:Repo 'Functions/RunAllSubscriptions.Functions.ps1')
        # $StartIds is set directly here; its derivation from the start snapshot is the line above the block.
        $Run = [scriptblock]::Create(@'
param($ReconText, $OverrideText, [string[]]$FailedIds, [string[]]$FailedNames, [string[]]$Aborted, [string[]]$StillThere, [string[]]$Archive = @(), [string[]]$ShippedIds = @())
function Get-AzSubscription { param($TenantId, $WarningAction) $StillThere | ForEach-Object { [pscustomobject]@{ Id = $_ } } }
function Save-CompletedSubscriptionIds { }
function Write-Host { }
$TenantID = 't'
$StartIds = @('sub-a', 'sub-gone')
$Subscriptions = @([pscustomobject]@{ Id = 'sub-a' }, [pscustomobject]@{ Id = 'sub-gone' })
$CompletedIds = @()
$FailedAttempts = @($FailedIds | ForEach-Object { [pscustomobject]@{ Id = $_ } })
$FailedSubscriptions = @($FailedNames)
$FailedSubscriptionIds = @($FailedIds)
$CollectionAbortedSubs = @($Aborted)
$ArchiveWriteFailures = @($Archive)
$ResumeStateFile = 'unused'
$StateSaveArgs = @{}
$WrapperExitCode = 0
$SubResourceCounts = @($ShippedIds | ForEach-Object { [pscustomobject]@{ Id = $_ } })
$Held = @($Global:CollectorFailures, $Global:MetricsFailedSubs, $Global:ConsumptionFailedSubs, $Global:MarketplaceFailedSubs)
# One record per list for the deleted subscription (in either case), beside records that must stay.
$Global:CollectorFailures = @([pscustomobject]@{ Id = 'sub-gone'; Module = 'VMSS'; Message = 'm' }, [pscustomobject]@{ Id = 'sub-a'; Module = 'AKS'; Message = 'm' })
$Global:MetricsFailedSubs = @([pscustomobject]@{ Name = 'Gone'; Id = 'sub-gone'; Message = 'm' }, [pscustomobject]@{ Name = '(subscription)'; Id = '(unknown)'; Message = 'm' })
$Global:ConsumptionFailedSubs = @([pscustomobject]@{ Name = 'Gone'; Id = 'SUB-GONE'; Message = 'm' }, [pscustomobject]@{ Name = '(all subscriptions)'; Id = '(auth)'; Message = 'm' })
$Global:MarketplaceFailedSubs = @([pscustomobject]@{ Name = 'Gone'; Id = 'sub-gone'; Message = 'm' })
try
{
    . ([scriptblock]::Create($ReconText))
    . ([scriptblock]::Create($OverrideText))
    $Health = [pscustomobject]@{
        Collector   = @($Global:CollectorFailures | ForEach-Object { $_.Id })
        Metrics     = @($Global:MetricsFailedSubs | ForEach-Object { $_.Id })
        Consumption = @($Global:ConsumptionFailedSubs | ForEach-Object { $_.Id })
        Marketplace = @($Global:MarketplaceFailedSubs | ForEach-Object { $_.Id })
    }
}
finally
{
    $Global:CollectorFailures, $Global:MetricsFailedSubs, $Global:ConsumptionFailedSubs, $Global:MarketplaceFailedSubs = $Held
}
[pscustomobject]@{ Exit = $WrapperExitCode; Names = @($FailedSubscriptions); Ids = @($FailedSubscriptionIds); Aborted = @($CollectionAbortedSubs); Archive = @($ArchiveWriteFailures); Retry = @($FailedAttempts | ForEach-Object { $_.Id }); Health = $Health }
'@)
        $Gone = & $Run $Recon.Extent.Text $Override.Extent.Text @('sub-gone') @('Gone') @('Gone (sub-gone)') @('sub-a') @('Gone (sub-gone)')
        $Gone.Exit | Should -Be 0 -Because 'its failure is expected: the subscription no longer exists'
        $Gone.Names.Count | Should -Be 0 -Because 'the summary must not list it as failed and advise a retry the retry list no longer holds'
        $Gone.Aborted.Count | Should -Be 0
        $Gone.Archive.Count | Should -Be 0
        $Gone.Retry.Count | Should -Be 0
        $Gone.Health.Collector | Should -Be @('sub-a') -Because 'a collector failure on a deleted subscription is expected, and must not set the collector-failure exit code'
        $Gone.Health.Metrics | Should -Be @('(unknown)')
        $Gone.Health.Consumption | Should -Be @('(auth)') -Because 'ids match whatever their case, and a row with no subscription id stays'
        $Gone.Health.Marketplace.Count | Should -Be 0
        $Kept = & $Run $Recon.Extent.Text $Override.Extent.Text @() @() @() @('sub-a', 'sub-gone')
        $Kept.Health.Collector | Should -Be @('sub-gone', 'sub-a') -Because 'nothing was deleted, so nothing is dropped'
        $Kept.Health.Consumption | Should -Be @('SUB-GONE', '(auth)')
        $Kept.Health.Marketplace | Should -Be @('sub-gone')
        $ShippedGone = & $Run $Recon.Extent.Text $Override.Extent.Text @() @() @() @('sub-a') @() @('sub-gone')
        $ShippedGone.Health.Collector | Should -Be @('sub-gone', 'sub-a') -Because 'it completed before it was deleted and its report ships, so its missing types must still be reported'
        $ShippedGone.Health.Consumption | Should -Be @('SUB-GONE', '(auth)')
        $Both = & $Run $Recon.Extent.Text $Override.Extent.Text @('sub-gone', 'sub-a') @('Gone', 'A') @() @('sub-a') @('A (sub-a)')
        $Both.Exit | Should -Be 2
        $Both.Names | Should -Be @('A')
        $Both.Ids | Should -Be @('sub-a')
        $Both.Archive | Should -Be @('A (sub-a)') -Because 'a subscription that still exists keeps its archive failure'
        $Dead = & $Run $Recon.Extent.Text $Override.Extent.Text @('stream-1') @('stream-1 (no summary)') @() @('sub-a')
        $Dead.Exit | Should -Be 2 -Because 'a dead stream is never explained by a deletion'
        $Dead.Names | Should -Be @('stream-1 (no summary)')
    }

    It 'the missing-report banners have one owner, printed at the normal end AND before the hard stop' {
        $Defs = @($script:WrapAst.FindAll({ param($N) $N -is [System.Management.Automation.Language.AssignmentStatementAst] -and $N.Left.Extent.Text -eq '$WriteMissingReportBanners' }, $true))
        $Defs.Count | Should -Be 1
        $Defs[0].Right.Extent.Text | Should -Match 'FAILED \(collection aborted\)'
        $Defs[0].Right.Extent.Text | Should -Match 'FAILED \(report archive\)'
        @([regex]::Matches($script:WrapSrc, '(?m)^\s*& \$WriteMissingReportBanners\s*$')).Count | Should -Be 2 -Because 'the verification hard stop exits first and used to drop both banners'
        # The hard-stop call sits immediately before its Exit-Wrapper -Code 2.
        $script:WrapSrc | Should -Match '(?s)& \$WriteMissingReportBanners\s*\r?\n\s*Exit-Wrapper -Code 2'
        # And the banners are not duplicated as loose text elsewhere.
        @([regex]::Matches($script:WrapSrc, '"=+ FAILED \(collection aborted\) =+"')).Count | Should -Be 1
    }

    It 'the verification, the consolidation, MainSummary, the HTML fold and the placement CSV all read one selection, made first' {
        $Select = $script:WrapSrc.IndexOf('$Shippable = Select-RdaShippableReports', [System.StringComparison]::Ordinal)
        $Select | Should -BeGreaterThan -1
        foreach ($Consumer in @(
                '$ExpectedZipCount = '
                '$ActualSubZips = @($Shippable.Archives)'
                '$SubZips = @($Shippable.Archives)'
                '-IncludeFolders @($Shippable.Folders | ForEach-Object { $_.Name })'
                'foreach ($SubDir in @($Shippable.Folders))'
                '$ShippedPartPrefixes = @($Shippable.Folders'
            ))
        {
            $At = $script:WrapSrc.IndexOf($Consumer, [System.StringComparison]::Ordinal)
            $At | Should -BeGreaterThan -1 -Because ('{0} must be present' -f $Consumer)
            $Select | Should -BeLessThan $At -Because ('{0} must come after the selection is made' -f $Consumer)
        }
        # A spelling guard, not a capability one: no listing in the wrapper filters for archives or
        # report folders by name any more. The guarantee itself rests on the pins above.
        $Listings = @($script:WrapAst.FindAll({ param($N) $N -is [System.Management.Automation.Language.CommandAst] -and $N.GetCommandName() -eq 'Get-ChildItem' }, $true))
        $Listings.Count | Should -BeGreaterThan 0
        foreach ($Listing in $Listings)
        {
            $Elements = @($Listing.CommandElements)
            for ($k = 0; $k -lt $Elements.Count; $k++)
            {
                $Element = $Elements[$k]
                if ($Element -isnot [System.Management.Automation.Language.CommandParameterAst] -or $Element.ParameterName -notin @('Filter', 'Include')) { continue }
                $Arg = if ($null -ne $Element.Argument) { $Element.Argument } elseif ($k + 1 -lt $Elements.Count) { $Elements[$k + 1] } else { $null }
                $Value = if ($Arg -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $Arg.Value } else { [string]$Arg.Extent.Text }
                $Value | Should -Not -BeIn @('*.zip', 'ResourcesReport*') -Because ('{0} sweeps the root on its own' -f $Listing.Extent.Text)
            }
        }
    }

    It 'a stream that died before reporting still ships what it finished, read back from its state file' {
        $NoSummary = $script:WrapAst.Find({ param($N) $N -is [System.Management.Automation.Language.IfStatementAst] -and $N.Clauses[0].Item1.Extent.Text -eq '-not (Test-Path -LiteralPath $S.SummaryPath -PathType Leaf)' }, $true)
        # The innermost try that reads the summary: the tries around the whole parallel block hold it too.
        $Corrupt = @($script:WrapAst.FindAll({ param($N) $N -is [System.Management.Automation.Language.TryStatementAst] -and $N.Body.Extent.Text -match [regex]::Escape('$StreamSummary = Get-Content -LiteralPath $S.SummaryPath') }, $true) |
                Sort-Object { $_.Extent.Text.Length } | Select-Object -First 1)[0]
        $Init = $script:WrapAst.Find({ param($N) $N -is [System.Management.Automation.Language.AssignmentStatementAst] -and $N.Extent.Text -eq '$UnreportedStreams = @()' }, $true)
        $Recover = $script:WrapAst.Find({ param($N) $N -is [System.Management.Automation.Language.ForEachStatementAst] -and $N.Condition.Extent.Text -eq '$UnreportedStreams' }, $true)
        $NoSummary | Should -Not -BeNullOrEmpty
        $Corrupt | Should -Not -BeNullOrEmpty
        $Init | Should -Not -BeNullOrEmpty
        $Recover | Should -Not -BeNullOrEmpty
        [object]::ReferenceEquals($NoSummary.Parent, $Corrupt.Parent) | Should -BeTrue -Because 'both branches sit in the one loop over the streams'
        $Loop = $NoSummary.Parent.Parent
        $Loop | Should -BeOfType ([System.Management.Automation.Language.ForEachStatementAst])
        $Loop.Condition.Extent.Text | Should -Be '$StreamSummaries'
        $Init.Extent.EndOffset | Should -BeLessThan $Loop.Extent.StartOffset
        $Recover.Extent.StartOffset | Should -BeGreaterThan $Loop.Extent.EndOffset
        # Recovery reads the state files before the end-of-run merge can remove them, and before the
        # selection is made from the record.
        $Merge = @($script:WrapAst.FindAll({ param($N) $N -is [System.Management.Automation.Language.CommandAst] -and $N.GetCommandName() -eq 'Remove-RdaMergedStreamState' -and $N.Extent.Text -match '-StreamFiles \$ReadStreamFiles' }, $true))
        $Lister = $script:WrapAst.Find({ param($N) $N -is [System.Management.Automation.Language.AssignmentStatementAst] -and $N.Left.Extent.Text -eq '$AllStreamFiles' }, $true)
        $Selection = $script:WrapAst.Find({ param($N) $N -is [System.Management.Automation.Language.AssignmentStatementAst] -and $N.Left.Extent.Text -eq '$Shippable' -and $N.Right.Extent.Text -match 'Select-RdaShippableReports' }, $true)
        $Merge.Count | Should -Be 1
        $Recover.Extent.EndOffset | Should -BeLessThan $Lister.Extent.StartOffset
        $Recover.Extent.EndOffset | Should -BeLessThan $Merge[0].Extent.StartOffset
        $Recover.Extent.EndOffset | Should -BeLessThan $Selection.Extent.StartOffset
        # Each stream's slice is kept on its record, so recovery can refuse ids from outside it.
        $script:WrapSrc | Should -Match '(?s)\$StreamSummaries \+= \[pscustomobject\]@\{[^}]*SliceIds\s+= \$SliceIds'
        . (Join-Path $script:Repo 'Functions/RunAllSubscriptions.Functions.ps1')
        $Root = Join-Path ([System.IO.Path]::GetTempPath()) ('Dead_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
        try
        {
            $Since = (Get-Date).AddMinutes(-1)
            $ZipA = Join-Path $Root 'ResourcesReportA/ResourcesReport_a.zip'
            New-Item -ItemType Directory -Path (Split-Path -Path $ZipA -Parent) -Force | Out-Null
            'z' | Set-Content -LiteralPath $ZipA -Encoding utf8
            # Written by the worker's own state writer, one record outside the slice. The writer reads
            # the worker's $StreamId from its caller.
            Set-Variable -Name StreamId -Value '0'
            Write-StreamState -Path (Get-StreamStateFilePath -InventoryRoot $Root -Tenant 't' -StreamId '0') -Completed @('sub-0a') `
                -Reports @([pscustomobject]@{ Name = 'A'; Id = 'sub-0a'; Count = 4; Zip = $ZipA }, [pscustomobject]@{ Name = 'Other'; Id = 'sub-other'; Count = 1; Zip = $ZipA })
            # Stream 1 recorded a report whose archive has since gone, and wrote a corrupt summary.
            Set-Variable -Name StreamId -Value '1'
            Write-StreamState -Path (Get-StreamStateFilePath -InventoryRoot $Root -Tenant 't' -StreamId '1') -Completed @('sub-1a') `
                -Reports @([pscustomobject]@{ Name = 'B'; Id = 'sub-1a'; Count = 2; Zip = (Join-Path $Root 'ResourcesReportB/ResourcesReport_b.zip') })
            'not json' | Set-Content -LiteralPath (Join-Path $Root 'corrupt.json') -Encoding utf8
            $Run = [scriptblock]::Create(@'
param($LoopText, $Root, $Since)
$Printed = New-Object System.Collections.Generic.List[string]
function Write-Host { param($Object, $ForegroundColor) $Printed.Add([string]$Object) }
$InventoryRoot = $Root
$TenantID = 't'
$RunStartTime = $Since
$FailedSubscriptions = @()
$FailedSubscriptionIds = @()
$SubResourceCounts = @()
$StreamSummaries = @(
    [pscustomobject]@{ StreamId = 0; SummaryPath = (Join-Path $Root 'absent.json'); SliceIds = @('sub-0a', 'sub-0b') }
    [pscustomobject]@{ StreamId = 1; SummaryPath = (Join-Path $Root 'corrupt.json'); SliceIds = @('sub-1a') }
)
. ([scriptblock]::Create($LoopText))
[pscustomobject]@{ Counts = @($SubResourceCounts); Failed = @($FailedSubscriptions); Printed = ($Printed -join "`n") }
'@)
            # The real loop, as written: both streams leave it at their own branch.
            $Out = & $Run ($Init.Extent.Text + "`n" + $Loop.Extent.Text + "`n" + $Recover.Extent.Text) $Root $Since
            @($Out.Counts | ForEach-Object { $_.Id }) | Should -Be @('sub-0a', 'sub-1a') -Because 'what a dead stream finished ships; an id outside its slice does not'
            @($Out.Counts | ForEach-Object { $_.Zip }) | Should -Be @($ZipA, (Join-Path $Root 'ResourcesReportB/ResourcesReport_b.zip')) -Because 'a recorded archive that is gone is kept, so the verification names it'
            $Out.Counts[0].Count | Should -Be 4
            $Out.Failed | Should -Be @('stream-0 (no summary)', 'stream-1 (corrupt summary)') -Because 'the stream is still reported as failed'
            $Out.Printed | Should -Match '\[stream-0\] recovered 1 finished subscription report\(s\) from its state file: A'
            $Out.Printed | Should -Match '\[stream-1\] recovered 1 finished subscription report\(s\) from its state file: B'
            $Out.Printed | Should -Match '\[stream-0\]   Their billing record counts and per-phase health were in the summary this stream did not write'
        }
        finally { Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'names every folder it left out, and says an unmarked abort was kept out' {
        $LeftOutBlock = $script:WrapAst.Find({ param($N) $N -is [System.Management.Automation.Language.IfStatementAst] -and $N.Clauses[0].Item1.Extent.Text -eq '$UnrecordedReportFolders.Count -gt 0' }, $true)
        $UnmarkedBlock = $script:WrapAst.Find({ param($N) $N -is [System.Management.Automation.Language.IfStatementAst] -and $N.Clauses[0].Item1.Extent.Text -eq '@($CollectionAbortedSubs).Count -gt $AbortedReportFolders.Count' }, $true)
        $LeftOutBlock | Should -Not -BeNullOrEmpty
        $UnmarkedBlock | Should -Not -BeNullOrEmpty
        $Run = [scriptblock]::Create(@'
param($Text, [string[]]$UnrecordedNames, [string[]]$Aborted, [string[]]$Marked)
$Printed = New-Object System.Collections.Generic.List[string]
function Write-Host { param($Object, $ForegroundColor) $Printed.Add(('{0}|{1}' -f $ForegroundColor, $Object)) }
$UnrecordedReportFolders = @($UnrecordedNames | ForEach-Object { [pscustomobject]@{ Name = $_ } })
$CollectionAbortedSubs = @($Aborted)
$AbortedReportFolders = @($Marked)
. ([scriptblock]::Create($Text))
$Printed -join "`n"
'@)
        $Named = & $Run $LeftOutBlock.Extent.Text @('ResourcesReportA', 'ResourcesReportB') @() @()
        $Named | Should -Match '2 report folder\(s\) written during this run are left out of the bundle'
        $Named | Should -Match '\|  - ResourcesReportA'
        $Named | Should -Match '\|  - ResourcesReportB'
        $KeptOut = & $Run $UnmarkedBlock.Extent.Text @() @('X (id-x)') @()
        $KeptOut | Should -Match '^Yellow\|WARNING: 1 aborted subscription\(s\) left no aborted-collection marker\. Their partial report folders are left out anyway'
        $script:WrapSrc | Should -Not -Match 'may be in the bundle\. Check the bundle before sending it' -Because 'the selection never sweeps, so an unmarked partial folder cannot ship'
        (& $Run $UnmarkedBlock.Extent.Text @() @('X (id-x)') @('/root/ResourcesReportX')) | Should -BeNullOrEmpty -Because 'a marked abort needs no warning'
    }

    It 'a stale stream summary is removed before any stream starts or the token cache is snapshotted' {
        $Sweep = $script:WrapSrc.IndexOf('foreach ($StaleSummaryPath in $StreamSummaryPaths)', [System.StringComparison]::Ordinal)
        $Sweep | Should -BeGreaterThan -1
        $Snapshot = $script:WrapSrc.IndexOf('Save-AzContext -Path $AzContextSnapshot', [System.StringComparison]::Ordinal)
        $Launch = $script:WrapSrc.IndexOf('$Jobs += Start-Job', [System.StringComparison]::Ordinal)
        $Snapshot | Should -BeGreaterThan -1
        $Launch | Should -BeGreaterThan -1
        $Sweep | Should -BeLessThan $Snapshot
        $Sweep | Should -BeLessThan $Launch
        # And a removal that fails stops the run rather than going on to read the stale file.
        $script:WrapSrc | Should -Match '(?s)foreach \(\$StaleSummaryPath in \$StreamSummaryPaths\)\s*\{\s*if \(Test-Path -LiteralPath \$StaleSummaryPath\)\s*\{\s*try \{ Remove-Item -LiteralPath \$StaleSummaryPath -Force -ErrorAction Stop \}\s*catch\s*\{\s*Write-Host \([^\r\n]*\) -ForegroundColor Red\s*Exit-Wrapper -Code 1\s*\}'
        # Each stream then reads the same path it was cleared at, not a second spelling of it.
        $script:WrapSrc | Should -Match '\$SummaryPath = \$StreamSummaryPaths\[\$S\]'
        @([regex]::Matches($script:WrapSrc, '\.rda-stream-\{0\}-summary\.json')).Count | Should -Be 1
    }

    It 'a -Resume run in parallel mode skips what an earlier run completed, before slicing' {
        $Filter = $script:WrapAst.Find({ param($N) $N -is [System.Management.Automation.Language.ForEachStatementAst] -and $N.Body.Extent.Text -match '\$ParallelSubscriptions \+= \$Sub' }, $true)
        $Filter | Should -Not -BeNullOrEmpty
        $Run = [scriptblock]::Create(@'
param($Text, [bool]$Resume)
function Write-Host { }
$Subscriptions = @([pscustomobject]@{ Id = 'a'; Name = 'A' }, [pscustomobject]@{ Id = 'b'; Name = 'B' }, [pscustomobject]@{ Id = 'c'; Name = 'C' })
$CompletedIds = @('a', 'c')
$SkippedCount = 0
$ParallelSubscriptions = @()
. ([scriptblock]::Create($Text))
[pscustomobject]@{ Ids = @($ParallelSubscriptions | ForEach-Object { $_.Id }); Skipped = $SkippedCount }
'@)
        $Resumed = & $Run $Filter.Extent.Text $true
        $Resumed.Ids | Should -Be @('b')
        $Resumed.Skipped | Should -Be 2
        $Fresh = & $Run $Filter.Extent.Text $false
        $Fresh.Ids | Should -Be @('a', 'b', 'c')
        $Fresh.Skipped | Should -Be 0
        # The slices, their loop bound and the one-subscription fallback read the filtered list.
        $script:WrapSrc | Should -Match 'for \(\$i = 0; \$i -lt \$ParallelSubscriptions\.Count; \$i\+\+\)\s*\{\s*\$Slices\[\$i % \$StreamCount\]\.Add\(\$ParallelSubscriptions\[\$i\]\)'
        $script:WrapSrc | Should -Match '\$Sub = \$ParallelSubscriptions\[0\]'
        $script:WrapSrc | Should -Match '\$StreamCount = \[Math\]::Min\(\$ParallelStreams, \$ParallelSubscriptions\.Count\)'
        # The parallel header is printed only when streams are really launched.
        $script:WrapSrc | Should -Match '(?s)if \(\$StreamCount -ge 2\)\s*\{\s*Write-Host \("Parallel-streams mode:'
    }

    It 'every start recovers what a killed parallel run recorded, and removes the copies only once the saved state holds them' {
        # The block runs from its first statement to the removal call. Its only gate is -Preflight,
        # which collects nothing; it is no longer gated on -Resume.
        $First = $script:WrapAst.Find({ param($N) $N -is [System.Management.Automation.Language.AssignmentStatementAst] -and $N.Extent.Text -eq '$StrandedCompleted = @()' }, $true)
        $Gate = $script:WrapAst.Find({ param($N) $N -is [System.Management.Automation.Language.IfStatementAst] -and $N.Clauses[0].Item1.Extent.Text -eq '-not $Preflight' }, $true)
        $First | Should -Not -BeNullOrEmpty
        $Gate | Should -Not -BeNullOrEmpty
        $Ifs = @()
        $Up = $First.Parent
        while ($null -ne $Up)
        {
            if ($Up -is [System.Management.Automation.Language.IfStatementAst]) { $Ifs += $Up }
            $Up = $Up.Parent
        }
        $Ifs.Count | Should -Be 1 -Because 'stranded state is merged whether or not -Resume was passed'
        [object]::ReferenceEquals($Ifs[0], $Gate) | Should -BeTrue
        # The whole if statement, so the -Preflight gate runs as written too.
        $Block = $Gate.Extent.Text
        $Block | Should -Match 'Remove-RdaMergedStreamState'
        . (Join-Path $script:Repo 'Functions/RunAllSubscriptions.Functions.ps1')
        $Run = [scriptblock]::Create(@'
param($Text, [bool]$WithBlob, $Dir, [bool]$LocalSaveLands, [bool]$BlobSaveLands, [bool]$BlobReadable = $true, [bool]$Preflight = $false)
$Printed = New-Object System.Collections.Generic.List[string]
function Write-Host { param($Object, $ForegroundColor) $Printed.Add([string]$Object) }
$Store = @{ Main = $null; Removed = @() }
function Get-StateBlobNames { param($Context, $Container, $Prefix, $Tenant, $ShardIndex, $ShardCount) @('state/stream-0.json') }
function Read-StateBlob
{
    param($Context, $Container, $BlobName)
    if ($BlobName -eq 'state/main.json') { return $Store.Main }
    if (-not $BlobReadable) { return $null }
    [pscustomobject]@{
        Completed      = @('sub-done')
        FailedAttempts = @(
            [pscustomobject]@{ Id = 'sub-failed'; Name = 'F'; Reason = 'r'; LastFailedAt = '2026-01-01T00:00:00Z' }
            [pscustomobject]@{ Id = 'sub-done'; Name = 'D'; Reason = 'r'; LastFailedAt = '2026-01-01T00:00:00Z' }
        )
    }
}
function Save-StateBlob
{
    param($Context, $Container, $BlobName, $File, [switch]$BestEffort)
    if ($BlobSaveLands) { $Store.Main = Get-Content -LiteralPath $File -Raw | ConvertFrom-Json }
}
function Remove-AzStorageBlob { param($Container, $Blob, $Context, [switch]$Force) $Store.Removed += $Blob }
# A save that does not land: the resume state file is never written.
if (-not $LocalSaveLands) { function Save-CompletedSubscriptionIds { } }
$Resume = $false
$ResumeFailedOnly = $false
# The real lister reads this folder, which also holds the main resume state it must not pick up.
$InventoryRoot = $Dir
$TenantID = 't'
$ShardIndex = 0
$ShardCount = 1
$StateBlobParts = if ($WithBlob) { [pscustomobject]@{ Container = 'c'; Prefix = '' } } else { $null }
$StateBlobCtx = 'ctx'
$StateBlobArgs = if ($WithBlob) { @{ BlobContext = 'ctx'; BlobContainer = 'c'; BlobName = 'state/main.json' } } else { @{} }
$CompletedIds = @('sub-earlier')
$FailedAttempts = @()
$ResumeStateFile = Join-Path $Dir '.resume-state-t.json'
$StateSaveArgs = @{} + $StateBlobArgs
$Warned = @(. ([scriptblock]::Create($Text)) 3>&1 | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { [string]$_ })
[pscustomobject]@{
    Completed    = @($CompletedIds | Sort-Object)
    Failed       = @($FailedAttempts | ForEach-Object { $_.Id })
    FileKept     = (Test-Path -LiteralPath (Join-Path $Dir '.resume-state-t-stream-0.json'))
    StateSaved   = (Test-Path -LiteralPath $ResumeStateFile)
    BlobsRemoved = @($Store.Removed)
    Warned       = $Warned
    Printed      = ($Printed -join "`n")
}
'@)
        $Dir = Join-Path ([System.IO.Path]::GetTempPath()) ('Stranded_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        try
        {
            $StreamFile = Join-Path $Dir '.resume-state-t-stream-0.json'
            $StateFile = Join-Path $Dir '.resume-state-t.json'
            $Reset = {
                param([string]$Content = '{ "Completed": ["sub-file"], "FailedAttempts": [] }')
                $Content | Set-Content -LiteralPath $StreamFile -Encoding utf8
                Remove-Item -LiteralPath $StateFile -Force -ErrorAction SilentlyContinue
            }

            # The file and the blob both record sub-done, as a stream's two copies do.
            & $Reset '{ "Completed": ["sub-file", "sub-done"], "FailedAttempts": [] }'
            $Blob = & $Run $Block $true $Dir $true $true
            $Blob.Completed | Should -Be @('sub-done', 'sub-earlier', 'sub-file')
            $Blob.Failed | Should -Be @('sub-failed') -Because 'a stream blob''s failures are recovered too, less any the killed run completed'
            $Blob.FileKept | Should -BeFalse -Because 'the saved state holds what the stream file recorded'
            $Blob.BlobsRemoved | Should -Be @('state/stream-0.json')
            $Blob.Warned.Count | Should -Be 0
            $Blob.Printed | Should -Match 'Recovered per-stream state from an interrupted parallel run: 2 completed, 2 failed subscription record' -Because 'subscriptions are counted once, not once per copy'
            (Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json).TenantID | Should -Be 't' -Because 'the main resume state is not taken for a stream file'

            & $Reset
            $FilesOnly = & $Run $Block $false $Dir $true $true
            $FilesOnly.Completed | Should -Be @('sub-earlier', 'sub-file') -Because 'without blob-backed state only the stream file is read'
            $FilesOnly.Failed.Count | Should -Be 0
            $FilesOnly.FileKept | Should -BeFalse
            ((Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json).CompletedSubscriptionIds -contains 'sub-file') | Should -BeTrue

            & $Reset
            $NotSaved = & $Run $Block $true $Dir $false $false
            $NotSaved.FileKept | Should -BeTrue -Because 'removing it when the save did not land would lose what that stream finished'
            $NotSaved.BlobsRemoved.Count | Should -Be 0
            $NotSaved.Warned.Count | Should -Be 2
            ($NotSaved.Warned -join "`n") | Should -Match 'so they are kept\. This run keeps their records and saves them again with its own progress'

            & $Reset
            $BlobNotSaved = & $Run $Block $true $Dir $true $false
            $BlobNotSaved.FileKept | Should -BeFalse -Because 'the local state holds it'
            $BlobNotSaved.BlobsRemoved.Count | Should -Be 0 -Because 'the state blob does not, and each copy is checked against its own store'
            $BlobNotSaved.Warned.Count | Should -Be 1

            # A copy that recorded only failures is kept when the save does not land.
            & $Reset '{ "Completed": [], "FailedAttempts": [ { "Id": "sub-x", "Name": "X", "Reason": "r", "LastFailedAt": "2026-01-01T00:00:00Z", "Attempts": 1 } ] }'
            $FailOnly = & $Run $Block $false $Dir $false $false
            $FailOnly.Failed | Should -Be @('sub-x')
            $FailOnly.FileKept | Should -BeTrue -Because 'the failure it recorded is not in any saved state'
            $FailOnly.Warned.Count | Should -Be 1

            # A copy that could not be read is never removed, whatever the others held.
            & $Reset 'not json'
            $Unreadable = & $Run $Block $true $Dir $true $true $false
            $Unreadable.FileKept | Should -BeTrue -Because 'it added nothing to what was checked, so its records are not known to be saved'
            $Unreadable.BlobsRemoved.Count | Should -Be 0 -Because 'a blob that could not be read is not removed either'
            $Unreadable.Printed | Should -Match 'WARNING: could not read the per-stream state file [^\n]*\.resume-state-t-stream-0\.json left by an interrupted run'
            $Unreadable.Completed | Should -Be @('sub-earlier')

            # Beside a copy that was read and saved, an unreadable one is still kept.
            & $Reset 'not json'
            $Mixed = & $Run $Block $true $Dir $true $true
            $Mixed.BlobsRemoved | Should -Be @('state/stream-0.json') -Because 'the blob was read and the saved state holds it'
            $Mixed.FileKept | Should -BeTrue -Because 'the file added nothing to what was checked'
            $Mixed.Completed | Should -Be @('sub-done', 'sub-earlier')

            # -Preflight changes no state.
            & $Reset
            $Pre = & $Run $Block $true $Dir $true $true $true $true
            $Pre.FileKept | Should -BeTrue
            $Pre.StateSaved | Should -BeFalse
            $Pre.BlobsRemoved.Count | Should -Be 0
            $Pre.Completed | Should -Be @('sub-earlier')
        }
        finally { Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'the end-of-run merge keeps a copy it could not read, and lets a failure in this run outrank an older completion' {
        $From = $script:WrapAst.Find({ param($N) $N -is [System.Management.Automation.Language.AssignmentStatementAst] -and $N.Left.Extent.Text -eq '$AllStreamFiles' }, $true)
        $To = @($script:WrapAst.FindAll({ param($N) $N -is [System.Management.Automation.Language.CommandAst] -and $N.GetCommandName() -eq 'Remove-RdaMergedStreamState' -and $N.Extent.Text -match '-StreamFiles \$ReadStreamFiles' }, $true))
        $From | Should -Not -BeNullOrEmpty
        $To.Count | Should -Be 1
        $Text = $script:WrapSrc.Substring($From.Extent.StartOffset, $To[0].Extent.EndOffset - $From.Extent.StartOffset)
        . (Join-Path $script:Repo 'Functions/RunAllSubscriptions.Functions.ps1')
        $Dir = Join-Path ([System.IO.Path]::GetTempPath()) ('EndMerge_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        try
        {
            $Since = (Get-Date).AddMinutes(-5)
            $Now = (Get-Date).ToUniversalTime().ToString('o')
            # Stream 0 completed sub-y and failed sub-x in this run; an earlier run had recorded sub-x as
            # completed. Stream 1's file cannot be read.
            ('{ "Completed": ["sub-y"], "FailedAttempts": [ { "Id": "sub-x", "Name": "X", "Reason": "r", "LastFailedAt": "' + $Now + '", "Attempts": 1 } ] }') |
                Set-Content -LiteralPath (Join-Path $Dir '.resume-state-t-stream-0.json') -Encoding utf8
            'not json' | Set-Content -LiteralPath (Join-Path $Dir '.resume-state-t-stream-1.json') -Encoding utf8
            $Run = [scriptblock]::Create(@'
param($Text, $Dir, $Since)
$Printed = New-Object System.Collections.Generic.List[string]
function Write-Host { param($Object, $ForegroundColor) $Printed.Add([string]$Object) }
$InventoryRoot = $Dir
$TenantID = 't'
$StateBlobParts = $null
$StateBlobArgs = @{}
$StateSaveArgs = @{}
$RunStartTime = $Since
$ResumeStateFile = Join-Path $Dir '.resume-state-t.json'
$CompletedIds = @('sub-x', 'sub-older')
$FailedAttempts = @()
$FailedSubscriptionIds = @()
$SubResourceCounts = @([pscustomobject]@{ Name = 'Y'; Id = 'sub-y'; Count = 1; Zip = 'z' })
$Warned = @(. ([scriptblock]::Create($Text)) 3>&1 | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { [string]$_ })
[pscustomobject]@{
    Completed = @($CompletedIds | Sort-Object)
    Failed    = @($FailedAttempts | ForEach-Object { $_.Id })
    Kept0     = (Test-Path -LiteralPath (Join-Path $Dir '.resume-state-t-stream-0.json'))
    Kept1     = (Test-Path -LiteralPath (Join-Path $Dir '.resume-state-t-stream-1.json'))
    Saved     = (Get-Content -LiteralPath $ResumeStateFile -Raw | ConvertFrom-Json)
    Warned    = $Warned
    Printed   = ($Printed -join "`n")
}
'@)
            $Out = & $Run $Text $Dir $Since
            $Out.Completed | Should -Be @('sub-older', 'sub-y') -Because 'sub-x failed in this run, which outranks the older completion'
            $Out.Failed | Should -Be @('sub-x') -Because '-ResumeFailedOnly must see it'
            @($Out.Saved.CompletedSubscriptionIds) -contains 'sub-x' | Should -BeFalse
            @($Out.Saved.FailedAttempts | ForEach-Object { $_.Id }) | Should -Be @('sub-x')
            $Out.Kept0 | Should -BeFalse -Because 'the saved state holds what it recorded'
            $Out.Kept1 | Should -BeTrue -Because 'what it recorded is not known'
            $Out.Printed | Should -Match 'WARNING: could not read the per-stream state file [^\n]*stream-1\.json'
            $Out.Warned.Count | Should -Be 0
        }
        finally { Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'a sequential failure takes the subscription out of the completed set before the state is saved' {
        $Catches = @($script:WrapAst.FindAll({ param($N) $N -is [System.Management.Automation.Language.CatchClauseAst] -and $N.Body.Extent.Text -match 'Add-FailedAttempt -Existing \$FailedAttempts `\s*-Id \$Sub\.Id' }, $true))
        $Catches.Count | Should -Be 2 -Because 'the one-subscription path and the sequential loop both record a failure'
        foreach ($Catch in $Catches)
        {
            $Body = $Catch.Body.Extent.Text
            $Add = $Body.IndexOf('Add-FailedAttempt', [System.StringComparison]::Ordinal)
            $Drop = $Body.IndexOf('$CompletedIds = @($CompletedIds | Where-Object { $_ -ne $Sub.Id })', [System.StringComparison]::Ordinal)
            $Save = $Body.IndexOf('Save-CompletedSubscriptionIds', [System.StringComparison]::Ordinal)
            $Drop | Should -BeGreaterThan $Add
            $Save | Should -BeGreaterThan $Drop
        }
    }

    It 'nothing else in the wrapper removes a stream state copy' {
        # A capability check over every removal the wrapper makes, not over one spelling of it.
        $StateVars = 'StreamFile|PerStreamFile|AllStreamFiles|StrandedStreamFiles|StrandedReadFiles|ReadStreamFiles|StreamBlobName|StrandedBlobName|StreamBlobNames|MergedStreamBlob'
        foreach ($Removal in @($script:WrapAst.FindAll({ param($N) $N -is [System.Management.Automation.Language.CommandAst] -and $N.GetCommandName() -in @('Remove-Item', 'Remove-AzStorageBlob') }, $true)))
        {
            $Removal.Extent.Text | Should -Not -Match ('\$({0})\b' -f $StateVars) -Because ('{0} would remove stream state without the saved-state check' -f $Removal.Extent.Text)
        }
        @($script:WrapAst.FindAll({ param($N) $N -is [System.Management.Automation.Language.CommandAst] -and $N.GetCommandName() -eq 'Remove-RdaMergedStreamState' }, $true)).Count | Should -Be 2 -Because 'the start and the end of a run'
        $script:WrapSrc | Should -Not -Match 'RecordedOnly|RecordIncomplete' -Because 'the selection has no mode left to read'
        . (Join-Path $script:Repo 'Functions/RunAllSubscriptions.Functions.ps1')
        $Params = @((Get-Command Select-RdaShippableReports).Parameters.Keys | Where-Object { $_ -notin [System.Management.Automation.PSCmdlet]::CommonParameters } | Sort-Object)
        $Params | Should -Be @('InventoryRoot', 'ProcessedSubscriptions', 'SinceTime')
    }

    It 'the VM placement CSV keeps only the parts whose report is in the bundle' {
        $Block = $script:WrapAst.Find({ param($N) $N -is [System.Management.Automation.Language.IfStatementAst] -and $N.Clauses[0].Item1.Extent.Text -eq '$CapacityPlan' -and $N.Extent.Text -match 'VMPlacementPart_' }, $true)
        $Block | Should -Not -BeNullOrEmpty
        $Root = Join-Path ([System.IO.Path]::GetTempPath()) ('Place_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
        try
        {
            $Kept = New-Item -ItemType Directory -Path (Join-Path $Root 'ResourcesReport111') -Force
            $Dropped = New-Item -ItemType Directory -Path (Join-Path $Root 'ResourcesReport222') -Force
            foreach ($Part in @(@('111_sub-a', 'vm-kept'), @('222_sub-b', 'vm-dropped'), @('333_sub-c', 'vm-other-run')))
            {
                @('"ResourceKind","Name"', ('"VirtualMachine","{0}"' -f $Part[1])) | Set-Content -LiteralPath (Join-Path $Root ('VMPlacementPart_ResourcesReport_{0}.csv' -f $Part[0])) -Encoding utf8
            }
            $Run = [scriptblock]::Create(@'
param($Text, $Root, $Kept, $Dropped)
$Printed = New-Object System.Collections.Generic.List[string]
function Write-Host { param($Object, $ForegroundColor) $Printed.Add([string]$Object) }
$CapacityPlan = $true
$InventoryRoot = $Root
$RunStartTime = (Get-Date).AddMinutes(-5)
$Shippable = [pscustomobject]@{ Folders = @($Kept); LeftOut = @([pscustomobject]@{ Name = $Dropped.Name; Path = $Dropped.FullName; Reason = 'NotRecorded' }) }
# A completed subscription whose VMSS collector failed wrote no part of its own.
$SubResourceCounts = @([pscustomobject]@{ Id = 'sub-a' }, [pscustomobject]@{ Id = 'sub-vmss-failed' })
$Saved = $Global:CollectorFailures
$Global:CollectorFailures = @([pscustomobject]@{ Id = 'sub-vmss-failed'; Module = 'VMSS'; Message = 'm' }, [pscustomobject]@{ Id = 'sub-a'; Module = 'AKS'; Message = 'm' })
$VmPlacementFile = $null
try { . ([scriptblock]::Create($Text)) }
finally { $Global:CollectorFailures = $Saved }
[pscustomobject]@{ File = $VmPlacementFile; Printed = ($Printed -join "`n") }
'@)
            $Out = & $Run $Block.Extent.Text $Root $Kept $Dropped
            $Out.File | Should -Not -BeNullOrEmpty
            @(Import-Csv -LiteralPath $Out.File | ForEach-Object { $_.Name }) | Should -Be @('vm-kept')
            $Out.Printed | Should -Match '1 part\(s\) left out because their subscription''s report is not in the bundle'
            $Out.Printed | Should -Match '1 completed subscription\(s\) are not in it because their VirtualMachines or VMSS collector failed: sub-vmss-failed' -Because 'the CSV must not read complete while a shipped subscription is missing from it'
            Test-Path -LiteralPath (Join-Path $Root 'VMPlacementPart_ResourcesReport_111_sub-a.csv') | Should -BeFalse -Because 'a merged part is removed'
            Test-Path -LiteralPath (Join-Path $Root 'VMPlacementPart_ResourcesReport_222_sub-b.csv') | Should -BeFalse -Because 'this run''s own left-out part is removed too'
            Test-Path -LiteralPath (Join-Path $Root 'VMPlacementPart_ResourcesReport_333_sub-c.csv') | Should -BeTrue -Because 'another run''s part is neither merged nor removed'
        }
        finally { Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'the hard stop names the subscriptions that failed outright' {
        $HardStop = [regex]::Match($script:WrapSrc, '(?s)Write-Host "ERROR: Per-subscription output verification failed\.".*?& \$WriteMissingReportBanners\s*\r?\n\s*Exit-Wrapper -Code 2').Value
        $HardStop | Should -Not -BeNullOrEmpty
        $HardStop | Should -Match 'foreach \(\$FailedEntry in \$FailedSubscriptions\)'
    }

    It 'the <Banner> banner says which subscriptions produced a report, one by one' -ForEach @(
        @{ Banner = 'collectors'; Condition = '@($Global:CollectorFailures).Count -gt 0' }
        @{ Banner = 'auth'; Condition = '$AuthSkippedPhases.Count -gt 0' }
    ) {
        $Block = $script:WrapAst.Find({ param($N) $N -is [System.Management.Automation.Language.IfStatementAst] -and $N.Clauses[0].Item1.Extent.Text -eq $Condition -and $N.Extent.Text -match ('FAILED \({0}\)' -f $Banner) }.GetNewClosure(), $true)
        $Block | Should -Not -BeNullOrEmpty
        $Run = [scriptblock]::Create(@'
param($Text, $Failures, $Completed, $Failed, $Aborted)
$Printed = New-Object System.Collections.Generic.List[string]
function Write-Host { param($Object, $ForegroundColor) $Printed.Add([string]$Object) }
$Saved = $Global:CollectorFailures
try
{
    $Global:CollectorFailures = $Failures
    $AuthSkippedPhases = @('Metrics')
    $SubResourceCounts = @($Completed | ForEach-Object { [pscustomobject]@{ Id = $_ } })
    $FailedSubscriptions = @($Failed)
    $CollectionAbortedSubs = @($Aborted)
    . ([scriptblock]::Create($Text))
}
finally { $Global:CollectorFailures = $Saved }
$Printed -join "`n"
'@)
        $F = @([pscustomobject]@{ Id = 'sub-ok'; Module = 'M' }, [pscustomobject]@{ Id = 'sub-stopped'; Module = 'M' })
        $Mixed = & $Run $Block.Extent.Text $F @('sub-ok') @('Stopped (stream-0: aborted)') @('Stopped (sub-stopped)')
        $Clean = & $Run $Block.Extent.Text @($F[0]) @('sub-ok') @() @()
        if ($Banner -eq 'collectors')
        {
            $Mixed | Should -Match '1 of these subscription\(s\) completed'
            $Mixed | Should -Match '1 of these subscription\(s\) did NOT complete, so their report is NOT in the bundle: sub-stopped'
            $Mixed | Should -Not -Match 'sub-ok\b.*NOT in the bundle'
            $Clean | Should -Match '1 of these subscription\(s\) completed'
            $Clean | Should -Not -Match 'NOT in the bundle'
        }
        else
        {
            $Mixed | Should -Match "NOT for the 1 under 'Subscriptions Failed'"
            $Mixed | Should -Not -Match 'The rest of the inventory completed and the report was still produced'
            $Clean | Should -Match 'The rest of the inventory completed and the report was still produced'
        }
    }

    It 'no failure line says "Script exited with code" any more' {
        foreach ($F in 'Run-AllSubscriptions.ps1', 'Run-AllSubscriptions.Stream.ps1')
        {
            $Src = Get-Content -LiteralPath (Join-Path $script:Repo $F) -Raw
            $Src | Should -Not -Match 'Script exited with code' -Because ('{0}: the inner 3 read as the wrapper''s own 3' -f $F)
            $Src | Should -Match 'ResourceInventory\.ps1 exited with code \{0\} \(\{1\}\)'
        }
    }
}

Describe 'A stream worker records each finished report, so its parent can ship it if the worker dies' {
    BeforeAll {
        . (Join-Path $script:Repo 'Functions/RunAllSubscriptions.Functions.ps1')
        $script:DeadDir = Join-Path ([System.IO.Path]::GetTempPath()) ('DeadFn_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:DeadDir -Force | Out-Null
        $script:DeadSince = (Get-Date).AddMinutes(-1)
        $script:DeadZip = Join-Path $script:DeadDir 'ResourcesReportA/ResourcesReport_a.zip'
        New-Item -ItemType Directory -Path (Split-Path -Path $script:DeadZip -Parent) -Force | Out-Null
        'z' | Set-Content -LiteralPath $script:DeadZip -Encoding utf8
        $script:StaleZip = Join-Path $script:DeadDir 'ResourcesReportOld/ResourcesReport_old.zip'
        New-Item -ItemType Directory -Path (Split-Path -Path $script:StaleZip -Parent) -Force | Out-Null
        'z' | Set-Content -LiteralPath $script:StaleZip -Encoding utf8
        (Get-Item -LiteralPath $script:StaleZip).LastWriteTime = (Get-Date).AddHours(-2)
        function script:Write-DeadState
        {
            param([string]$Name, [object[]]$Reports)
            # The writer reads the worker's $StreamId from its caller.
            Set-Variable -Name StreamId -Value '0'
            $Path = Join-Path $script:DeadDir $Name
            Write-StreamState -Path $Path -Completed @($Reports | ForEach-Object { $_.Id }) -Reports $Reports
            return $Path
        }
    }
    AfterAll {
        if ($script:DeadDir -and (Test-Path -LiteralPath $script:DeadDir)) { Remove-Item -LiteralPath $script:DeadDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'the state writer keeps each report beside the completed ids, and the reader takes them back' {
        $Path = script:Write-DeadState -Name 'rt.json' -Reports @([pscustomobject]@{ Name = 'A'; Id = 'sub-a'; Count = 7; Zip = $script:DeadZip })
        $Saved = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        @($Saved.Completed) | Should -Be @('sub-a')
        @($Saved.Reports).Count | Should -Be 1
        $Back = @(Get-RdaDeadStreamReports -StatePath $Path -SliceIds @('sub-a') -SinceTime $script:DeadSince 6>$null)
        $Back.Count | Should -Be 1
        $Back[0].Name | Should -Be 'A'
        $Back[0].Id | Should -Be 'sub-a'
        $Back[0].Count | Should -Be 7
        $Back[0].Zip | Should -Be $script:DeadZip
    }
    It 'takes only the stream''s own slice, and skips an archive older than the run' {
        $Path = script:Write-DeadState -Name 'mixed.json' -Reports @(
            [pscustomobject]@{ Name = 'A'; Id = 'sub-a'; Count = 1; Zip = $script:DeadZip }
            [pscustomobject]@{ Name = 'Foreign'; Id = 'sub-foreign'; Count = 1; Zip = $script:DeadZip }
            [pscustomobject]@{ Name = 'Old'; Id = 'sub-old'; Count = 1; Zip = $script:StaleZip }
            [pscustomobject]@{ Name = 'Gone'; Id = 'sub-gone'; Count = 1; Zip = (Join-Path $script:DeadDir 'ResourcesReportGone/ResourcesReport_g.zip') }
            [pscustomobject]@{ Name = 'NoId'; Id = ''; Count = 1; Zip = $script:DeadZip }
        )
        $Back = @(Get-RdaDeadStreamReports -StatePath $Path -SliceIds @('sub-a', 'sub-old', 'sub-gone', '') -SinceTime $script:DeadSince -StreamLabel 'stream-2' -WarningVariable Warned -WarningAction SilentlyContinue 6>$null)
        @($Back | ForEach-Object { $_.Id }) | Should -Be @('sub-a', 'sub-gone') -Because 'a gone archive is returned so the verification names it; a leftover from before the run is not this run''s report'
        @($Warned).Count | Should -Be 1 -Because 'a recorded subscription left out must be named, not dropped silently'
        [string]$Warned[0] | Should -Match '^\[stream-2\] recorded subscription sub-old with an archive written before this run started'
    }
    It 'a state file last written before the run holds nothing of this run, and says so' {
        $Path = script:Write-DeadState -Name 'old.json' -Reports @([pscustomobject]@{ Name = 'A'; Id = 'sub-a'; Count = 1; Zip = $script:DeadZip })
        (Get-Item -LiteralPath $Path -Force).LastWriteTime = (Get-Date).AddHours(-2)
        $Printed = @(Get-RdaDeadStreamReports -StatePath $Path -SliceIds @('sub-a') -SinceTime $script:DeadSince -StreamLabel 'stream-3' 6>&1)
        @($Printed | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] }).Count | Should -Be 0
        [string]($Printed | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | Select-Object -First 1) | Should -Match '^\[stream-3\] its state file records no subscription it finished in this run'
    }
    It 'a missing or unreadable state file recovers nothing and says which' {
        $Absent = @(Get-RdaDeadStreamReports -StatePath (Join-Path $script:DeadDir 'absent.json') -SliceIds @('sub-a') -SinceTime $script:DeadSince 6>&1)
        [string]$Absent[0] | Should -Match '^\[stream\] left no state file at .*absent\.json, so none of its reports is in the bundle'
        $Bad = Join-Path $script:DeadDir 'bad.json'
        'not json' | Set-Content -LiteralPath $Bad -Encoding utf8
        $Back = @(Get-RdaDeadStreamReports -StatePath $Bad -SliceIds @('sub-a') -SinceTime $script:DeadSince -StreamLabel 'stream-1' -WarningVariable Warned -WarningAction SilentlyContinue 6>$null)
        $Back.Count | Should -Be 0
        [string]$Warned[0] | Should -Match '^\[stream-1\] could not read its state file'
    }
    It 'the saved-state check holds only when every recovered record is there' {
        $State = [pscustomobject]@{ CompletedSubscriptionIds = @('a', 'b'); FailedAttempts = @([pscustomobject]@{ Id = 'f' }) }
        Test-RdaResumeStateHolds -State $State -CompletedIds @('a') -FailedIds @('f') | Should -BeTrue
        Test-RdaResumeStateHolds -State $State -CompletedIds @() -FailedIds @('b') | Should -BeTrue -Because 'a completion elsewhere supersedes a failure'
        Test-RdaResumeStateHolds -State $State -CompletedIds @('c') -FailedIds @() | Should -BeFalse
        Test-RdaResumeStateHolds -State $State -CompletedIds @() -FailedIds @('g') | Should -BeFalse
        Test-RdaResumeStateHolds -State $State -CompletedIds @('f') -FailedIds @() | Should -BeFalse -Because 'a completion recorded only as a failure is not held'
        Test-RdaResumeStateHolds -State $null -CompletedIds @('a') -FailedIds @() | Should -BeFalse -Because 'a state that could not be read holds nothing'
        Test-RdaResumeStateHolds -State $null -CompletedIds @() -FailedIds @() | Should -BeTrue -Because 'there is nothing to hold'
    }
    It 'a failure record counts as this run''s only when it was written at or after the run started' {
        $Since = [datetime]::new(2026, 3, 29, 1, 30, 0, [System.DateTimeKind]::Utc).ToLocalTime()
        $Attempts = @(
            [pscustomobject]@{ Id = 'new-string'; LastFailedAt = '2026-03-29T03:40:00.0000000+02:00' }
            [pscustomobject]@{ Id = 'new-date'; LastFailedAt = [datetime]::new(2026, 3, 29, 2, 0, 0, [System.DateTimeKind]::Utc) }
            [pscustomobject]@{ Id = 'old'; LastFailedAt = '2026-03-29T01:00:00Z' }
            [pscustomobject]@{ Id = 'unreadable'; LastFailedAt = 'yesterday-ish' }
            [pscustomobject]@{ Id = ''; LastFailedAt = '2026-03-29T05:00:00Z' }
            [pscustomobject]@{ Id = 'new-string'; LastFailedAt = '2026-03-29T04:00:00Z' }
            $null
        )
        @(Get-RdaFailedSinceIds -FailedAttempts $Attempts -SinceTime $Since) | Should -Be @('new-string', 'new-date') -Because 'times are compared as instants, whatever offset they were written with'
        @(Get-RdaFailedSinceIds -FailedAttempts @() -SinceTime $Since).Count | Should -Be 0
        # As ConvertFrom-Json hands them over from a state file.
        $FromJson = '{ "FailedAttempts": [ { "Id": "j", "LastFailedAt": "2026-03-29T03:40:00.0000000+02:00" } ] }' | ConvertFrom-Json
        @(Get-RdaFailedSinceIds -FailedAttempts $FromJson.FailedAttempts -SinceTime $Since) | Should -Be @('j')
    }
    It 'the stranded-state remover checks the saved copy as written, and names what it keeps' {
        $Dir = Join-Path $script:DeadDir ('rm_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        $Copy = Join-Path $Dir '.resume-state-t-stream-0.json'
        $State = Join-Path $Dir '.resume-state-t.json'
        '{}' | Set-Content -LiteralPath $Copy -Encoding utf8
        foreach ($Case in @(
                @{ Content = 'not json'; Why = 'an unreadable resume state holds nothing' }
                @{ Content = '{ "TenantID": "other", "CompletedSubscriptionIds": ["a"], "FailedAttempts": [] }'; Why = 'another tenant''s state holds nothing of this one' }
            ))
        {
            $Case.Content | Set-Content -LiteralPath $State -Encoding utf8
            Remove-RdaMergedStreamState -ResumeStateFile $State -Tenant 't' -CompletedIds @('a') -StreamFiles @(Get-Item -LiteralPath $Copy -Force) -KeptNote 'NOTE-X' -WarningVariable Warned -WarningAction SilentlyContinue 6>$null
            Test-Path -LiteralPath $Copy | Should -BeTrue -Because $Case.Why
            [string]$Warned[0] | Should -Match 'so they are kept\. NOTE-X$'
        }
        '{ "TenantID": "t", "CompletedSubscriptionIds": ["a"], "FailedAttempts": [] }' | Set-Content -LiteralPath $State -Encoding utf8
        Remove-RdaMergedStreamState -ResumeStateFile $State -Tenant 't' -CompletedIds @('a') -StreamFiles @(Get-Item -LiteralPath $Copy -Force) -WarningVariable Warned -WarningAction SilentlyContinue 6>$null
        Test-Path -LiteralPath $Copy | Should -BeFalse
        @($Warned).Count | Should -Be 0
    }
    It 'the worker writes its state, reports included, after every success and every failure' {
        $StreamPath = Join-Path $script:Repo 'Run-AllSubscriptions.Stream.ps1'
        $StreamErrors = $null
        $StreamAst = [System.Management.Automation.Language.Parser]::ParseFile($StreamPath, [ref]$null, [ref]$StreamErrors)
        @($StreamErrors).Count | Should -Be 0
        $Writes = @($StreamAst.FindAll({ param($N) $N -is [System.Management.Automation.Language.CommandAst] -and $N.GetCommandName() -eq 'Write-StreamState' }, $true))
        $Writes.Count | Should -Be 2
        foreach ($Write in $Writes) { $Write.Extent.Text | Should -Match '-Reports \$ResourceCounts' }
        $FirstTime = $StreamAst.Find({ param($N) $N -is [System.Management.Automation.Language.IfStatementAst] -and $N.Clauses[0].Item1.Extent.Text -eq '-not ($Completed -contains $SubId)' }, $true)
        $FirstTime | Should -Not -BeNullOrEmpty
        $FirstTime.Extent.Text | Should -Not -Match 'Write-StreamState' -Because 'a subscription already marked completed still has its new report recorded'
        $Try = $StreamAst.Find({ param($N) $N -is [System.Management.Automation.Language.TryStatementAst] -and $N.Body.Extent.Text -match 'ResourceInventory\.ps1' }, $true)
        $Try | Should -Not -BeNullOrEmpty
        $InTry = @($Writes | Where-Object { $_.Extent.StartOffset -gt $Try.Body.Extent.StartOffset -and $_.Extent.EndOffset -lt $Try.Body.Extent.EndOffset })
        $InTry.Count | Should -Be 1
        $InTry[0].Extent.StartOffset | Should -BeGreaterThan $FirstTime.Extent.EndOffset
        # Unconditional within the try: its statement sits directly in the try body.
        [object]::ReferenceEquals($InTry[0].Parent.Parent, $Try.Body) | Should -BeTrue -Because 'no condition may skip the write after a success'
        $Clear = $StreamAst.Find({ param($N) $N -is [System.Management.Automation.Language.AssignmentStatementAst] -and $N.Extent.Text -match '^\$FailedAttempts = Remove-FailedAttempt' }, $true)
        [object]::ReferenceEquals($Clear.Parent, $Try.Body) | Should -BeTrue -Because 'a success clears the failure record even for a subscription already marked completed'
        $Catch = $Try.CatchClauses[0].Body
        $InCatch = @($Writes | Where-Object { $_.Extent.StartOffset -gt $Catch.Extent.StartOffset -and $_.Extent.EndOffset -lt $Catch.Extent.EndOffset })
        $InCatch.Count | Should -Be 1 -Because 'a failure is recorded before the worker can die later in its slice'
        $AddFailure = $StreamAst.Find({ param($N) $N -is [System.Management.Automation.Language.AssignmentStatementAst] -and $N.Extent.Text -match '^\$FailedAttempts = Add-FailedAttempt' }, $true)
        $InCatch[0].Extent.StartOffset | Should -BeGreaterThan $AddFailure.Extent.EndOffset
        [object]::ReferenceEquals($InCatch[0].Parent.Parent, $Catch) | Should -BeTrue
        # The worker and the parent spell the state file the same way.
        (Get-Content -LiteralPath $StreamPath -Raw) | Should -Match '\$StreamStateFile = Get-StreamStateFilePath -InventoryRoot \$InventoryRoot -Tenant \$TenantID -StreamId \$StreamId'
        Get-StreamStateFilePath -InventoryRoot $script:DeadDir -Tenant 't' -StreamId '2' | Should -Be (Join-Path $script:DeadDir '.resume-state-t-stream-2.json')
        @(Get-StreamResumeStateFiles -InventoryRoot $script:DeadDir -Tenant 't').Count | Should -Be 0
        'x' | Set-Content -LiteralPath (Get-StreamStateFilePath -InventoryRoot $script:DeadDir -Tenant 't' -StreamId '2') -Encoding utf8
        @(Get-StreamResumeStateFiles -InventoryRoot $script:DeadDir -Tenant 't').Count | Should -Be 1 -Because 'the startup merge finds what the worker wrote'
    }
}

Describe 'The inner script marks an aborted report folder' {
    It 'writes no VM placement part for an aborted collection or a failed VM collector, and says so loudly' {
        $Assign = $script:InvAst.Find({ param($N) $N -is [System.Management.Automation.Language.AssignmentStatementAst] -and $N.Left.Extent.Text -eq '$PlacementInputFailed' }, $true)
        $Gate = $script:InvAst.Find({ param($N) $N -is [System.Management.Automation.Language.IfStatementAst] -and $N.Clauses[0].Item1.Extent.Text -eq '$CapacityPlan.IsPresent -and -not [string]::IsNullOrWhiteSpace($script:CollectorBreakerError)' }, $true)
        $Assign | Should -Not -BeNullOrEmpty
        $Gate | Should -Not -BeNullOrEmpty
        # Run as written. Join-Path and Test-Path are shimmed so the writing branch logs 'not found'
        # instead of running the placement script, which is how reaching it shows.
        $Run = [scriptblock]::Create(@'
param($AssignText, $GateText, $BreakerError, [string[]]$FailedModules)
$Logged = New-Object System.Collections.Generic.List[string]
function Write-Log { param($Message, $Severity) $Logged.Add(('{0}|{1}' -f $Severity, $Message)) }
function Test-Path { $false }
function Join-Path { param($Path, $ChildPath) '{0}/{1}' -f $Path, $ChildPath }
$CapacityPlan = [switch]$true
$RunAllSubs = [switch]$false
$script:CollectorBreakerError = $BreakerError
$script:CollectorFailuresThisRun = @($FailedModules | ForEach-Object { [pscustomobject]@{ Module = $_; Message = 'm' } })
try
{
    . ([scriptblock]::Create($AssignText))
    . ([scriptblock]::Create($GateText))
}
finally
{
    $script:CollectorBreakerError = $null
    $script:CollectorFailuresThisRun = $null
}
$Logged -join "`n"
'@)
        $Aborted = & $Run $Assign.Extent.Text $Gate.Extent.Text 'stopped' @()
        $Aborted | Should -MatchExactly 'Error\|VM placement CSV SKIPPED: collection was aborted'
        $Aborted | Should -Not -Match 'not found'
        $VmssFailed = & $Run $Assign.Extent.Text $Gate.Extent.Text $null @('VMSS')
        $VmssFailed | Should -MatchExactly 'Error\|VM placement CSV SKIPPED: the VMSS collector failed'
        $VmssFailed | Should -Not -Match 'not found'
        $BothFailed = & $Run $Assign.Extent.Text $Gate.Extent.Text $null @('VirtualMachines', 'VMSS')
        $BothFailed | Should -MatchExactly 'SKIPPED: the VirtualMachines and VMSS collectors failed'
        $OtherFailed = & $Run $Assign.Extent.Text $Gate.Extent.Text $null @('AKS')
        $OtherFailed | Should -Not -MatchExactly 'VM placement CSV SKIPPED:' -Because 'a collector the placement rows do not join does not stop them'
        $OtherFailed | Should -MatchExactly 'Error\|VM placement CSV skipped: /Extension/VMPlacement\.ps1 not found\.'
        # Placement runs after the collectors, where the breaker state and the failure list are final.
        $Collectors = [regex]::Match($script:InvSrc, '(?m)^[ \t]*CreateResourceJobs[ \t]*\r?$')
        $Collectors.Success | Should -BeTrue
        $Collectors.Index | Should -BeLessThan $Assign.Extent.StartOffset
    }

    It 'writes the marker only in the abort branch, and warns if it cannot' {
        $Branch = [regex]::Match($script:InvSrc, '(?s)if \(\$CollectionAborted\)\s*\{.*?\n    \}\s*\r?\n    else').Value
        $Branch | Should -Not -BeNullOrEmpty
        # The marker must actually be WRITTEN there, not merely computed: resolving the path and doing
        # nothing with it would leave the wrapper folding a partial report into the bundle.
        $BranchAst = [System.Management.Automation.Language.Parser]::ParseInput($Branch.Substring(0, $Branch.LastIndexOf('else')), [ref]$null, [ref]$null)
        $Writes = @($BranchAst.FindAll({ param($N)
                    $N -is [System.Management.Automation.Language.CommandAst] -and
                    $N.GetCommandName() -eq 'Set-Content' -and
                    $N.Extent.Text -match '-LiteralPath \(Get-RdaCollectionAbortedMarkerPath -Folder \$DefaultPath\)' }, $true))
        $Writes.Count | Should -Be 1 -Because 'the abort branch writes the marker into the report folder'
        $Branch | Should -Match 'could not write the aborted-collection marker'
        @([regex]::Matches($script:InvSrc, 'Get-RdaCollectionAbortedMarkerPath')).Count | Should -Be 1 -Because 'nowhere else writes it'
    }
}
