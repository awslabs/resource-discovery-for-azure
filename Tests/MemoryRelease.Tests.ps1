<#
    Memory release and per-phase memory readings.

    WHAT THIS GUARDS. A run used to keep two large structures alive for its whole
    length: $Global:Resources (every raw Resource Graph row) and $Global:SmaResources
    (every collector's output). Nothing read them after the Inventory JSON and the
    optional placement CSV were written, yet they stayed in memory through the
    billing pull and into the next subscription under the wrapper, which is where a
    small host ran out of memory. ResourceInventory.ps1 now records the resource
    count once discovery finishes and releases both structures after their last
    reader; the wrappers read the count instead of the array. Five recorded memory
    readings per subscription (start, discovery, collectors, released, end) land in
    $Global:MemoryReadings and are rendered into RunSummary.log and the shareable
    Diagnostics log so a run that does run out of memory shows which phase held it.

    Fully offline. The ordering guards read the parsed source; the reading and
    rendering tests call the real functions with synthetic values.
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:InvPath = Join-Path $script:RepoRoot 'ResourceInventory.ps1'
    $script:WrapperPath = Join-Path $script:RepoRoot 'Run-AllSubscriptions.ps1'
    $script:StreamPath = Join-Path $script:RepoRoot 'Run-AllSubscriptions.Stream.ps1'
    . (Join-Path $script:RepoRoot 'Functions/Common.Functions.ps1')
    . (Join-Path $script:RepoRoot 'Functions/ResourceInventory.Functions.ps1')
    . (Join-Path $script:RepoRoot 'Functions/RunAllSubscriptions.Functions.ps1')

    $script:InvSrc = Get-Content -LiteralPath $script:InvPath -Raw
    $script:WrapperSrc = Get-Content -LiteralPath $script:WrapperPath -Raw
    $script:StreamSrc = Get-Content -LiteralPath $script:StreamPath -Raw

    # Byte offsets of the load-bearing statements, so the ordering assertions read as
    # 'A comes before B' rather than as line numbers that drift. A bare call is matched with a
    # whitespace-tolerant -Pattern, so a re-indent or a CRLF checkout does not break the anchor.
    function Get-SourceOffset
    {
        param([string]$Source, [string]$Needle, [string]$Pattern)
        if ($Pattern)
        {
            $Match = [regex]::Match($Source, $Pattern)
            if (-not $Match.Success) { throw ("not found in source: {0}" -f $Pattern) }
            return $Match.Index
        }
        $Index = $Source.IndexOf($Needle, [System.StringComparison]::Ordinal)
        if ($Index -lt 0) { throw ("not found in source: {0}" -f $Needle) }
        return $Index
    }

    function New-TestReading
    {
        param([string]$Id, [string]$Stamp, [string]$Phase, [int]$Resources, [double]$Heap, [double]$WorkingSet, [double]$Limit = 2560)
        [pscustomobject]@{ Id = $Id; Stamp = $Stamp; Phase = $Phase; Resources = $Resources; HeapMB = $Heap; WorkingSetMB = $WorkingSet; LimitMB = $Limit }
    }

    function New-TestSubscriptionReadings
    {
        param([string]$Id, [string]$Stamp, [int]$Resources, [double[]]$Heaps, [double[]]$WorkingSets)
        $Phases = @('start', 'discovery', 'collectors', 'released', 'end')
        $Rows = @()
        for ($i = 0; $i -lt $Phases.Count; $i++)
        {
            $Rows += New-TestReading -Id $Id -Stamp $Stamp -Phase $Phases[$i] -Resources $(if ($i -eq 0) { 0 } else { $Resources }) -Heap $Heaps[$i] -WorkingSet $WorkingSets[$i]
        }
        return $Rows
    }
}

AfterAll {
    Remove-Item function:global:Write-Log -ErrorAction SilentlyContinue
}

Describe 'ResourceInventory.ps1 releases the two large structures after their last reader' {
    It 'parses' {
        $Errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($script:InvPath, [ref]$null, [ref]$Errors)
        $Errors | Should -BeNullOrEmpty
    }

    It 'records the resource count once discovery has finished, before the collectors run' {
        $Count = Get-SourceOffset $script:InvSrc '$Global:ResourceCount = @($Global:Resources).Count'
        $DiscoveryCatch = Get-SourceOffset $script:InvSrc 'FAILED to complete resource discovery'
        $Collectors = Get-SourceOffset $script:InvSrc -Pattern '(?m)^[ \t]*CreateResourceJobs[ \t]*\r?$'
        $Count | Should -BeGreaterThan $DiscoveryCatch -Because 'a discovery that threw has no count to report'
        $Count | Should -BeLessThan $Collectors
    }

    It 'resets the count at the start of every run' {
        $script:InvSrc | Should -Match '(?m)^\s+\$Global:ResourceCount = 0\s*$' -Because 'without the reset a run under the wrapper inherits the previous subscription''s count'
    }

    It 'releases both structures after the placement CSV and before the billing pull' {
        $Placement = Get-SourceOffset $script:InvSrc '& $PlacementScript -CsvFile $PlacementCsv'
        $ReleaseResources = Get-SourceOffset $script:InvSrc '$Global:Resources = $null'
        $ReleaseSma = Get-SourceOffset $script:InvSrc '$Global:SmaResources = $null'
        $ReleaseMetrics = Get-SourceOffset $script:InvSrc '$Global:AzMetrics = $null'
        $Billing = Get-SourceOffset $script:InvSrc -Pattern '(?m)^[ \t]*GetResourceConsumption[ \t]*\r?$'
        $ReleaseResources | Should -BeGreaterThan $Placement -Because 'the placement CSV reads both structures'
        $ReleaseSma | Should -BeGreaterThan $Placement
        $ReleaseResources | Should -BeLessThan $Billing -Because 'the billing pull is where a small host ran out of memory'
        $ReleaseSma | Should -BeLessThan $Billing
        $ReleaseMetrics | Should -BeGreaterThan $Placement -Because 'the metrics result has no reader after the metrics phase'
        $ReleaseMetrics | Should -BeLessThan $Billing
    }

    It 'has no reader of either structure after the release' {
        $Release = Get-SourceOffset $script:InvSrc '$Global:SmaResources = $null'
        $After = $script:InvSrc.Substring($Release + '$Global:SmaResources = $null'.Length)
        # Strip comment lines: the release is explained in a comment that names both structures.
        $Code = (($After -split "`r?`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
        $Code | Should -Not -Match 'Global:Resources\b'
        $Code | Should -Not -Match 'Global:SmaResources\b'
        $Code | Should -Not -Match '(^|[^A-Za-z:_$])\$Resources\b' -Because 'an unqualified $Resources resolves to the released global'
    }

    It 'has no reader of either structure in <Name>, which is defined before the release but runs after it' -ForEach @(
        @{ Name = 'GetResourceConsumption' }
        @{ Name = 'GetMarketplaceConsumption' }
    ) {
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:InvPath, [ref]$null, [ref]$null)
        $Fn = $Ast.Find({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq $Name }, $true)
        $Fn | Should -Not -BeNullOrEmpty -Because "$Name is the billing pull the release exists to protect"
        $Code = (($Fn.Extent.Text -split "`r?`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
        $Code | Should -Not -Match 'Global:Resources\b'
        $Code | Should -Not -Match 'Global:SmaResources\b'
        $Code | Should -Not -Match '(^|[^A-Za-z:_$])\$Resources\b'
    }

    It 'takes each of the five recorded memory readings exactly once, at its phase boundary' {
        # Functions are defined before the main body, so file order is not execution order; each
        # reading is pinned against the statement that marks its own phase instead.
        $At = @{}
        foreach ($Phase in @('start', 'discovery', 'collectors', 'released', 'end'))
        {
            $Needle = "Write-RdaMemorySnapshot -Phase '{0}' -Compact -Record" -f $Phase
            ([regex]::Matches($script:InvSrc, [regex]::Escape($Needle))).Count | Should -Be 1 -Because "the '$Phase' reading is taken exactly once"
            $At[$Phase] = Get-SourceOffset $script:InvSrc $Needle
        }
        $At['start'] | Should -BeGreaterThan (Get-SourceOffset $script:InvSrc -Pattern '(?m)^[ \t]*GetSubscriptionsData[ \t]*\r?$') -Because 'start is taken after sign-in and the subscription list, so start-to-discovery is the Resource Graph rows alone'
        $At['start'] | Should -BeLessThan (Get-SourceOffset $script:InvSrc -Pattern '(?m)^[ \t]*ResourceInventoryLoop[ \t]*\r?$') -Because 'start is taken before the first Resource Graph page'
        $At['discovery'] | Should -BeGreaterThan (Get-SourceOffset $script:InvSrc 'FAILED to complete resource discovery')
        $At['discovery'] | Should -BeLessThan (Get-SourceOffset $script:InvSrc 'function ExecuteInventoryProcessing()')
        $At['collectors'] | Should -BeGreaterThan (Get-SourceOffset $script:InvSrc -Pattern '(?m)^[ \t]*ProcessResourceResult[ \t]*\r?$')
        $At['collectors'] | Should -BeLessThan (Get-SourceOffset $script:InvSrc 'if ($CapacityPlan.IsPresent -and -not [string]::IsNullOrWhiteSpace($script:CollectorBreakerError))')
        $At['released'] | Should -BeGreaterThan (Get-SourceOffset $script:InvSrc '$Global:SmaResources = $null') -Because 'the released reading must follow the release itself'
        $At['released'] | Should -BeLessThan (Get-SourceOffset $script:InvSrc -Pattern '(?m)^[ \t]*GetResourceConsumption[ \t]*\r?$')
        $At['end'] | Should -BeLessThan (Get-SourceOffset $script:InvSrc 'Write-RdaShareableDiagnosticsLog -DefaultPath') -Because 'the end reading must exist before the diagnostics log renders it'
        $At['end'] | Should -BeGreaterThan (Get-SourceOffset $script:InvSrc -Pattern '(?m)^FinalizeOutputs[ \t]*\r?$') -Because 'the end reading is taken after the HTML report'
    }

    It 'hands the readings to both diagnostics-log calls' {
        ([regex]::Matches($script:InvSrc, [regex]::Escape('Write-RdaShareableDiagnosticsLog -DefaultPath'))).Count | Should -Be 2
        ([regex]::Matches($script:InvSrc, '-MemoryReadings \$Global:MemoryReadings\b')).Count | Should -Be 2
    }
}

Describe 'The wrappers read the count, never the released array' {
    It '<Label> reads $Global:ResourceCount and not $Global:Resources' -ForEach @(
        @{ Label = 'Run-AllSubscriptions.ps1'; Src = { $script:WrapperSrc }; Reads = 2 }
        @{ Label = 'Run-AllSubscriptions.Stream.ps1'; Src = { $script:StreamSrc }; Reads = 1 }
    ) {
        $Text = & $Src
        $Text | Should -Not -Match '\$Global:Resources\b' -Because 'the array is null by the time the wrapper runs'
        ([regex]::Matches($Text, 'if \(\$null -ne \$Global:ResourceCount\)\s*\{\s*\[int\]\$Global:ResourceCount\s*\}\s*else\s*\{\s*0\s*\}')).Count | Should -Be $Reads
    }

    It '<Label> starts every run with an empty readings list' -ForEach @(
        @{ Label = 'Run-AllSubscriptions.ps1'; Src = { $script:WrapperSrc } }
        @{ Label = 'Run-AllSubscriptions.Stream.ps1'; Src = { $script:StreamSrc } }
    ) {
        (& $Src) | Should -Match '(?m)^\$Global:MemoryReadings = @\(\)\s*$'
    }

    It 'the stream worker reports its readings and the parent folds them in' {
        $script:StreamSrc | Should -Match '(?m)^\s+MemoryReadings\s+= @\(\$MemoryReadings\)\s*$'
        $script:WrapperSrc | Should -Match ([regex]::Escape('$Global:MemoryReadings += @($StreamSummary.MemoryReadings)'))
    }

    It 'the parent passes the readings to the run summary builder' {
        $script:WrapperSrc | Should -Match '-MemoryReadings \$Global:MemoryReadings\b'
    }
}

Describe 'Write-RdaMemorySnapshot -Record' {
    BeforeAll {
        $script:PriorReadings = $Global:MemoryReadings
        $script:PriorCount = $Global:ResourceCount
        $script:PriorStamp = $Global:CurrentDateTime
        $script:PriorDebugLog = $Global:DebugLogFile
        $Global:DebugLogFile = $null
    }
    AfterAll {
        $Global:MemoryReadings = $script:PriorReadings
        $Global:ResourceCount = $script:PriorCount
        $Global:CurrentDateTime = $script:PriorStamp
        $Global:DebugLogFile = $script:PriorDebugLog
    }
    BeforeEach {
        $Global:MemoryReadings = $null
        $Global:ResourceCount = 42
        $Global:CurrentDateTime = 'stamp-1'
        Set-Variable -Name SubscriptionID -Value '12345678-1234-1234-1234-123456789012' -Scope Script
    }

    It 'appends one record carrying the subscription, stamp, phase, count and the three figures' {
        Write-RdaMemorySnapshot -Phase 'collectors' -Record
        @($Global:MemoryReadings).Count | Should -Be 1
        $R = @($Global:MemoryReadings)[0]
        $R.Id | Should -Be '12345678-1234-1234-1234-123456789012'
        $R.Stamp | Should -Be 'stamp-1'
        $R.Phase | Should -Be 'collectors'
        $R.Resources | Should -Be 42
        $R.HeapMB | Should -BeGreaterThan 0
        $R.WorkingSetMB | Should -BeGreaterThan 0
        $R.LimitMB | Should -BeGreaterThan 0
        ($R.PSObject.Properties.Name -join ',') | Should -Be 'Id,Stamp,Phase,Resources,HeapMB,WorkingSetMB,LimitMB'
    }

    It 'refuses to record a phase the summary does not render' {
        { Write-RdaMemorySnapshot -Phase 'strat' -Record } | Should -Throw -ExpectedMessage '*one of the phases the summary renders*'
        $Global:MemoryReadings | Should -BeNullOrEmpty
    }

    It 'still takes an ad-hoc reading without -Record under any phase name' {
        { Write-RdaMemorySnapshot -Phase 'Before the consumption pull' } | Should -Not -Throw
    }

    It 'records nothing without -Record' {
        Write-RdaMemorySnapshot -Phase 'start'
        $Global:MemoryReadings | Should -BeNullOrEmpty
    }

    It 'accumulates across calls, as the wrapper relies on for one row per subscription' {
        Write-RdaMemorySnapshot -Phase 'start' -Record
        Write-RdaMemorySnapshot -Phase 'discovery' -Compact -Record
        @($Global:MemoryReadings).Count | Should -Be 2
        (@($Global:MemoryReadings) | ForEach-Object { $_.Phase }) -join ',' | Should -Be 'start,discovery'
    }
}

Describe 'Get-RdaMemoryReadingLines' {
    BeforeAll {
        $script:Big = New-TestSubscriptionReadings -Id '12345678-1234-1234-1234-123456789012' -Stamp 's1' -Resources 20000 -Heaps @(310, 525, 640, 320, 335) -WorkingSets @(520, 780, 905, 610, 615)
        $script:Small = New-TestSubscriptionReadings -Id 'second-subscription' -Stamp 's2' -Resources 412 -Heaps @(312.4, 320.6, 325.6, 314.2, 316.1) -WorkingSets @(612.7, 620.3, 625.4, 612.4, 614.6)
        $script:Both = @($script:Big) + @($script:Small)
    }

    It 'renders one row per subscription with every phase, then the three summary lines' {
        $Lines = @(Get-RdaMemoryReadingLines -Readings $script:Both)
        $Lines.Count | Should -Be 6
        $Lines[0] | Should -Be 'Memory (MB, managed heap after a full collection / process working set):'
        $Lines[1] | Should -Be '  [sub 12345678-1234-1234-1234-123456789012]  resources 20,000  start 310/520  discovery 525/780  collectors 640/905  released 320/610  end 335/615'
        $Lines[2] | Should -Be '  [sub second-subscription]  resources 412  start 312/613  discovery 321/620  collectors 326/625  released 314/612  end 316/615'
        $Lines[3] | Should -Be '  Highest working set sampled : 905 MB'
        $Lines[4] | Should -Be '  Memory available to runtime : 2560 MB'
        # The count and its unit are joined at run time: the repo's pre-commit scrub reads a literal
        # '<count> resources' as an estate-size fingerprint, even for a synthetic fixture.
        $Lines[5] | Should -Be ('  Per resource, largest sub   : raw rows ~11 KB, collector output ~6 KB, total ~17 KB (20,000 ' + 'resources)')
    }

    It 'names subscriptions by position only when obfuscated' {
        $Lines = @(Get-RdaMemoryReadingLines -Readings $script:Both -Obfuscated)
        $Lines[1] | Should -Match '^\s+\[sub 1\]\s'
        $Lines[2] | Should -Match '^\s+\[sub 2\]\s'
        ($Lines -join "`n") | Should -Not -Match '12345678-1234-1234-1234-1234567890'
    }

    It 'keeps a standalone run to its own stamp' {
        $Lines = @(Get-RdaMemoryReadingLines -Readings $script:Both -Stamp 's2')
        $Lines.Count | Should -Be 5 -Because 'the header, one row, the two summary lines, and the per-resource line for the one remaining sub'
        ($Lines -join "`n") | Should -Not -Match '123456789012\]' -Because 'the other stamp''s subscription is filtered out'
        $Lines[1] | Should -Match 'resources 412'
    }

    It 'marks a phase that was never reached, as a subscription that failed mid-run leaves' {
        $Partial = @($script:Big | Where-Object { $_.Phase -in @('start', 'discovery') })
        $Lines = @(Get-RdaMemoryReadingLines -Readings $Partial)
        $Lines[1] | Should -Match 'discovery 525/780  collectors -  released -  end -'
        ($Lines -join "`n") | Should -Not -Match 'Per resource' -Because 'the per-resource split needs the collectors reading'
    }

    It 'returns nothing for no readings' {
        @(Get-RdaMemoryReadingLines -Readings @()).Count | Should -Be 0
        @(Get-RdaMemoryReadingLines -Readings $null).Count | Should -Be 0
    }

    It 'writes dot decimals under a comma-decimal culture and after a JSON round trip' {
        $Prior = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try
        {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [cultureinfo]::new('de-DE')
            $RoundTripped = $script:Both | ConvertTo-Json -Depth 4 | ConvertFrom-Json
            $Lines = @(Get-RdaMemoryReadingLines -Readings $RoundTripped)
        }
        finally
        {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = $Prior
        }
        $Lines[1] | Should -Match 'resources 20,000  start 310/520'
        # The fractional fixture is the culture probe: a culture-sensitive parse reads 312.4 as 3124.
        $Lines[2] | Should -Be '  [sub second-subscription]  resources 412  start 312/613  discovery 321/620  collectors 326/625  released 314/612  end 316/615'
        ($Lines -join "`n") | Should -Not -Match '\d,\d/'
    }

    It 'omits the per-resource line for a subscription that recorded no resources, without throwing' {
        $Empty = New-TestSubscriptionReadings -Id 'empty-subscription' -Stamp 's3' -Resources 0 -Heaps @(300, 301, 302, 300, 300) -WorkingSets @(500, 501, 502, 500, 500)
        $Lines = @(Get-RdaMemoryReadingLines -Readings $Empty)
        $Lines.Count | Should -Be 4 -Because 'the header, one row, the highest working set and the runtime limit; no per-resource split of nothing'
        $Lines[1] | Should -Match '^\s+\[sub empty-subscription\]\s+resources 0\s'
        ($Lines -join "`n") | Should -Not -Match 'Per resource'
    }

    It 'names a reading without an id by position and skips a null element' {
        $NoId = @(New-TestSubscriptionReadings -Id '' -Stamp 's4' -Resources 3 -Heaps @(1, 2, 3, 2, 2) -WorkingSets @(4, 5, 6, 5, 5))
        $Lines = @(Get-RdaMemoryReadingLines -Readings (@($null) + $NoId + @($null)))
        $Lines.Count | Should -Be 5
        $Lines[1] | Should -Match '^\s+\[sub 1\]\s+resources 3\s'
    }
}

Describe 'The run summary and the diagnostics log carry the memory block' {
    BeforeAll {
        $script:Readings = New-TestSubscriptionReadings -Id '12345678-1234-1234-1234-123456789012' -Stamp 'run-1' -Resources 100 -Heaps @(300, 320, 340, 305, 306) -WorkingSets @(500, 520, 540, 505, 506)
        $script:Other = New-TestSubscriptionReadings -Id '12345678-1234-1234-1234-123456789012' -Stamp 'run-0' -Resources 9 -Heaps @(1, 2, 3, 4, 5) -WorkingSets @(1, 2, 3, 4, 5)
    }

    It 'Get-RunSummaryLogContent renders the block when readings exist and states the empty case otherwise' {
        $With = @(Get-RunSummaryLogContent -Version '0.0.0' -MemoryReadings $script:Readings) -join "`n"
        $With | Should -Match 'Memory \(MB, managed heap after a full collection / process working set\):'
        $With | Should -Match 'resources 100  start 300/500'
        $With | Should -Not -Match 'no readings recorded'
        $Without = @(Get-RunSummaryLogContent -Version '0.0.0') -join "`n"
        $Without | Should -Not -Match 'Memory \(MB'
        $Without | Should -Match 'Memory: no readings recorded' -Because 'a summary without readings must say so, not look like a build without the block'
    }

    It 'Get-RunSummaryLogContent hides subscription ids in the block when obfuscated' {
        $Text = @(Get-RunSummaryLogContent -Version '0.0.0' -MemoryReadings $script:Readings -Obfuscated) -join "`n"
        $Text | Should -Match '\[sub 1\]'
        $Text | Should -Not -Match '12345678-1234'
    }

    It 'Write-RdaShareableDiagnosticsLog renders only this run''s readings (<Mode>)' -ForEach @(
        @{ Mode = 'default'; Obfuscated = $false }
        @{ Mode = 'obfuscated'; Obfuscated = $true }
    ) {
        $Dir = Join-Path ([System.IO.Path]::GetTempPath()) ('MemoryRelease_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        try
        {
            $File = Write-RdaShareableDiagnosticsLog -DefaultPath ($Dir + [IO.Path]::DirectorySeparatorChar) -ReportName 'R' -RunDateTime 'run-1' -Version '0.0.0' -MemoryReadings (@($script:Other) + @($script:Readings)) -Obfuscated:$Obfuscated
            $File | Should -Not -BeNullOrEmpty
            $Text = Get-Content -LiteralPath $File -Raw
            $Text | Should -Match 'Memory \(MB, managed heap after a full collection / process working set\):'
            $Text | Should -Match 'resources 100  start 300/500  discovery 320/520  collectors 340/540  released 305/505  end 306/506'
            $Text | Should -Not -Match 'resources 9\b' -Because 'the earlier run''s readings carry a different stamp'
            $Text | Should -Not -Match '12345678-1234' -Because 'the shareable log masks GUIDs in both modes, as its header says'
            if ($Obfuscated) { $Text | Should -Match '\[sub 1\]' } else { $Text | Should -Match '\[sub <guid>\]' }
        }
        finally
        {
            Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Write-RdaMemorySnapshot: one reading, to the local debug log only' {
    BeforeAll {
        $script:PriorDebugLogFile = $Global:DebugLogFile
        $script:PriorErrorLogFile = $Global:ErrorLogFile
        $script:SnapshotLog = Join-Path ([System.IO.Path]::GetTempPath()) ('MemorySnapshot_{0}.log' -f [guid]::NewGuid().ToString('N'))
        $Global:DebugLogFile = $script:SnapshotLog
        $Global:ErrorLogFile = $null
    }
    AfterAll {
        $Global:DebugLogFile = $script:PriorDebugLogFile
        $Global:ErrorLogFile = $script:PriorErrorLogFile
        Remove-Item -LiteralPath $script:SnapshotLog -Force -ErrorAction SilentlyContinue
    }
    BeforeEach {
        Remove-Item -LiteralPath $script:SnapshotLog -Force -ErrorAction SilentlyContinue
    }
    It 'writes <Label> as one debug-log line and nothing to the console' -ForEach @(
        @{ Label = 'a plain reading'; Compact = $false; Suffix = '' }
        @{ Label = 'a reading after a compacting collection'; Compact = $true; Suffix = ', after a compacting collection' }
    ) {
        $PriorCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try
        {
            # A comma-decimal culture: the figures must still be written with a dot.
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [cultureinfo]::new('de-DE')
            $Emitted = @(Write-RdaMemorySnapshot -Phase 'Unit test phase' -Compact:$Compact 6>&1)
        }
        finally
        {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = $PriorCulture
        }

        $Emitted.Count | Should -Be 0 -Because 'a memory reading goes to the local debug log, never to the console or the pipeline'
        $Lines = @(Get-Content -LiteralPath $script:SnapshotLog)
        $Lines.Count | Should -Be 1
        $Lines[0] | Should -Match ('\[Memory\] Unit test phase: managed heap \d+(\.\d)? MB, process working set \d+(\.\d)? MB, memory available to the runtime \d+ MB{0}\.$' -f [regex]::Escape($Suffix))
    }
}

Describe 'Extension/Metrics.ps1 releases its runspace pool when the phase ends' {
    BeforeAll {
        # The teardown is lifted out of the shipped finally by AST and run against a real pool, so the
        # assertions read what Metrics.ps1 does rather than a model of it.
        $MetricsAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepoRoot 'Extension/Metrics.ps1'), [ref]$null, [ref]$null)
        $Teardown = @($MetricsAst.FindAll({ param($N) $N -is [System.Management.Automation.Language.TryStatementAst] -and $null -ne $N.Finally -and $N.Finally.Extent.Text -match 'MetricCallPool\.BeginClose' }, $true))
        if ($Teardown.Count -ne 1) { throw ('Expected one finally that tears the metrics pool down; found {0}.' -f $Teardown.Count) }
        $script:PoolTeardown = [scriptblock]::Create((@(
                    'param($MetricCallPool, $MetricAbandonedCalls, $MetricPoolReleaseGraceSeconds = 10)'
                    '$MetricAbandonedDrained = 0'
                    '$MetricAbandonedRunning = 0'
                    '$TeardownDiag = [System.Collections.Generic.List[string]]::new()'
                    'function Write-MetricsDiag { param($Message) $TeardownDiag.Add([string]$Message) }'
                    ('. ' + $Teardown[0].Finally.Extent.Text)
                    '[pscustomobject]@{ Running = $MetricAbandonedRunning; Count = $MetricAbandonedCount; Released = [bool]$PoolClosed; Diag = @($TeardownDiag) }'
                ) -join [Environment]::NewLine))
        $script:InternalPoolField = [System.Management.Automation.Runspaces.RunspacePool].GetField('_internalPool', [System.Reflection.BindingFlags]'NonPublic,Instance')

        function New-OpenTestPool
        {
            $Pool = [runspacefactory]::CreateRunspacePool([initialsessionstate]::CreateDefault2())
            [void]$Pool.SetMaxRunspaces(2)
            $Pool.Open()
            return $Pool
        }
    }

    It 'leaves nothing that keeps the pool reachable once the phase has ended' {
        # Built and torn down in a child scope, so only the weak reference outlives it.
        $Weak = & {
            $Pool = New-OpenTestPool
            $Call = [powershell]::Create()
            $Call.RunspacePool = $Pool
            [void]$Call.AddScript('1').Invoke()
            $Call.Dispose()
            $Ref = [System.WeakReference]::new($script:InternalPoolField.GetValue($Pool))
            $null = & $script:PoolTeardown $Pool ([System.Collections.Concurrent.ConcurrentBag[psobject]]::new())
            $Ref
        }
        # BeginClose finishes on a worker thread, so the pool can stay reachable for a moment after the
        # teardown returns even when nothing leaks. Collect until it is gone, for up to 10 seconds: a
        # pool that is only closed stays registered and is still alive when the wait runs out.
        $Waited = [System.Diagnostics.Stopwatch]::StartNew()
        do
        {
            [System.GC]::Collect()
            [System.GC]::WaitForPendingFinalizers()
            [System.GC]::Collect()
            if (-not $Weak.IsAlive) { break }
            Start-Sleep -Milliseconds 100
        } while ($Waited.Elapsed.TotalSeconds -lt 10)
        $Weak.IsAlive | Should -BeFalse -Because 'a pool that is only closed stays registered in the process-wide timer queue, which kept one pool, a runspace and its Az modules per subscription for the life of the process'
    }

    It 'releases an idle pool at once and says so in the debug log' {
        $Pool = New-OpenTestPool
        $Call = [powershell]::Create()
        $Call.RunspacePool = $Pool
        [void]$Call.AddScript('1').Invoke()
        $Call.Dispose()

        $Timer = [System.Diagnostics.Stopwatch]::StartNew()
        $Result = & $script:PoolTeardown $Pool ([System.Collections.Concurrent.ConcurrentBag[psobject]]::new())
        $Timer.Stop()

        $Result.Released | Should -BeTrue
        $Timer.Elapsed.TotalSeconds | Should -BeLessThan 1 -Because 'an idle pool has no worker to wait for'
        $Pool.RunspacePoolStateInfo.State | Should -Be 'Closed'
        @($Result.Diag | Where-Object { $_ -like 'Metric worker pool released:*' }).Count | Should -Be 1
    }

    It 'waits for a stuck worker that finishes inside the grace window, then releases the pool' {
        $Pool = New-OpenTestPool
        $Call = [powershell]::Create()
        $Call.RunspacePool = $Pool
        # Thread.Sleep does not answer a pipeline stop, like a call blocked in a network read.
        [void]$Call.AddScript('[System.Threading.Thread]::Sleep(2000)')
        $Handle = $Call.BeginInvoke()
        try
        {
            $Started = [System.Diagnostics.Stopwatch]::StartNew()
            # The first runspace of a fresh pool can take several seconds to start on a slow host; a call
            # that never reached Running would be stopped at once and prove nothing.
            while ($Call.InvocationStateInfo.State -ne 'Running' -and $Started.Elapsed.TotalSeconds -lt 60) { Start-Sleep -Milliseconds 50 }
            $Call.InvocationStateInfo.State | Should -Be 'Running'
            [void]$Call.BeginStop($null, $null)
            $Bag = [System.Collections.Concurrent.ConcurrentBag[psobject]]::new()
            $Bag.Add([pscustomobject]@{ Call = $Call; Handle = $Handle })

            $Timer = [System.Diagnostics.Stopwatch]::StartNew()
            $Result = & $script:PoolTeardown $Pool $Bag 10
            $Timer.Stop()

            $Handle.IsCompleted | Should -BeTrue -Because 'the pool is released only after its last worker has ended'
            $Result.Released | Should -BeTrue
            $Result.Running | Should -Be 0
            $Timer.Elapsed.TotalSeconds | Should -BeLessThan 5 -Because 'the wait ends as soon as the worker does, not at the end of the grace window'
            $Pool.RunspacePoolStateInfo.State | Should -Be 'Closed'
        }
        finally
        {
            $Call.Dispose()
        }
    }

    It 'keeps the pool, does not hang, and logs a warning when a worker outlasts the grace window' {
        $Pool = New-OpenTestPool
        $Call = [powershell]::Create()
        $Call.RunspacePool = $Pool
        [void]$Call.AddScript('[System.Threading.Thread]::Sleep(4000)')
        $Handle = $Call.BeginInvoke()
        try
        {
            $Started = [System.Diagnostics.Stopwatch]::StartNew()
            # The first runspace of a fresh pool can take several seconds to start on a slow host; a call
            # that never reached Running would be stopped at once and prove nothing.
            while ($Call.InvocationStateInfo.State -ne 'Running' -and $Started.Elapsed.TotalSeconds -lt 60) { Start-Sleep -Milliseconds 50 }
            $Call.InvocationStateInfo.State | Should -Be 'Running'
            [void]$Call.BeginStop($null, $null)
            $Bag = [System.Collections.Concurrent.ConcurrentBag[psobject]]::new()
            $Bag.Add([pscustomobject]@{ Call = $Call; Handle = $Handle })

            $Timer = [System.Diagnostics.Stopwatch]::StartNew()
            $Result = & $script:PoolTeardown $Pool $Bag 1
            $Timer.Stop()

            $Timer.Elapsed.TotalSeconds | Should -BeLessThan 2.5 -Because 'the grace window bounds the wait; Close or an early Dispose would wait for the blocked call'
            $Result.Released | Should -BeFalse -Because 'a worker was still running, so it was not proven safe to release the pool'
            $Result.Running | Should -Be 1
            $Result.Count | Should -Be 1
            @($Result.Diag | Where-Object { $_ -like 'WARNING: metric worker pool NOT released*' }).Count | Should -Be 1

            # The worker still ends normally afterwards, and the closing pool follows it.
            $Waited = [System.Diagnostics.Stopwatch]::StartNew()
            while (-not $Handle.IsCompleted -and $Waited.Elapsed.TotalSeconds -lt 10) { Start-Sleep -Milliseconds 100 }
            $Handle.IsCompleted | Should -BeTrue
            while ($Pool.RunspacePoolStateInfo.State -ne 'Closed' -and $Waited.Elapsed.TotalSeconds -lt 10) { Start-Sleep -Milliseconds 100 }
            $Pool.RunspacePoolStateInfo.State | Should -Be 'Closed'
        }
        finally
        {
            $Call.Dispose()
            $Pool.Dispose()
        }
    }

    It 'does not release the pool while a worker nobody holds a handle to is still running' {
        # A stop or a throw mid-batch can leave a call in flight that never reached the abandoned bag.
        # Only the pool's own count of free runspaces can see it.
        $Pool = New-OpenTestPool
        $Call = [powershell]::Create()
        $Call.RunspacePool = $Pool
        [void]$Call.AddScript('[System.Threading.Thread]::Sleep(3000)')
        $Handle = $Call.BeginInvoke()
        try
        {
            $Started = [System.Diagnostics.Stopwatch]::StartNew()
            # The first runspace of a fresh pool can take several seconds to start on a slow host; a call
            # that never reached Running would be stopped at once and prove nothing.
            while ($Call.InvocationStateInfo.State -ne 'Running' -and $Started.Elapsed.TotalSeconds -lt 60) { Start-Sleep -Milliseconds 50 }
            $Call.InvocationStateInfo.State | Should -Be 'Running'

            $Result = & $script:PoolTeardown $Pool ([System.Collections.Concurrent.ConcurrentBag[psobject]]::new()) 1

            $Result.Released | Should -BeFalse -Because 'the pool reported a busy runspace, so not every worker had ended'
            @($Result.Diag | Where-Object { $_ -like '*idle=False*' }).Count | Should -Be 1
        }
        finally
        {
            $Waited = [System.Diagnostics.Stopwatch]::StartNew()
            while (-not $Handle.IsCompleted -and $Waited.Elapsed.TotalSeconds -lt 10) { Start-Sleep -Milliseconds 100 }
            $Call.Dispose()
            $Pool.Dispose()
        }
    }
}

Describe 'Extension/Metrics.ps1 shares one worker pool across the subscriptions of a wrapper run' {
    BeforeAll {
        # Lifted out of the shipped script by AST, as above, so the tests run what Metrics.ps1 does.
        $MetricsAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepoRoot 'Extension/Metrics.ps1'), [ref]$null, [ref]$null)
        $Create = @($MetricsAst.FindAll({ param($N) $N -is [System.Management.Automation.Language.IfStatementAst] -and $N.Clauses[0].Item1.Extent.Text -eq '$MetricCount -gt 0' -and $N.Extent.Text -match 'CreateRunspacePool' }, $true))
        if ($Create.Count -ne 1) { throw ('Expected one block that builds the metrics pool; found {0}.' -f $Create.Count) }
        $script:PoolCreate = [scriptblock]::Create((@(
                    'param($ReuseWorkerPool, $MetricCount = 1, $ConcurrencyLimit = 2, $MetricMaxRetries = 0)'
                    '$MetricCallPool = $null'
                    '$CreateDiag = [System.Collections.Generic.List[string]]::new()'
                    'function Write-MetricsDiag { param($Message) $CreateDiag.Add([string]$Message) }'
                    $Create[0].Extent.Text
                    '[pscustomobject]@{ Pool = $MetricCallPool; Diag = @($CreateDiag) }'
                ) -join [Environment]::NewLine))
        $Teardown = @($MetricsAst.FindAll({ param($N) $N -is [System.Management.Automation.Language.TryStatementAst] -and $null -ne $N.Finally -and $N.Finally.Extent.Text -match 'MetricCallPool\.BeginClose' }, $true))
        $script:PoolTeardownShared = [scriptblock]::Create((@(
                    'param($MetricCallPool, $MetricAbandonedCalls, $MetricPoolReleaseGraceSeconds = 10, $ReuseWorkerPool)'
                    '$MetricAbandonedDrained = 0'
                    '$MetricAbandonedRunning = 0'
                    '$TeardownDiag = [System.Collections.Generic.List[string]]::new()'
                    'function Write-MetricsDiag { param($Message) $TeardownDiag.Add([string]$Message) }'
                    ('. ' + $Teardown[0].Finally.Extent.Text)
                    '[pscustomobject]@{ Running = $MetricAbandonedRunning; Released = [bool]$PoolClosed; Diag = @($TeardownDiag) }'
                ) -join [Environment]::NewLine))
        $script:InvSrc = Get-Content -Raw -LiteralPath $script:InvPath
        $script:WrapperSrc = Get-Content -Raw -LiteralPath $script:WrapperPath
        $script:WrapperFnSrc = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'Functions/RunAllSubscriptions.Functions.ps1')
    }

    BeforeEach {
        $script:PriorPool = $Global:MetricCallPool
        $Global:MetricCallPool = $null
    }

    AfterEach {
        if ($null -ne $Global:MetricCallPool) { $null = Close-RdaMetricWorkerPool }
        $Global:MetricCallPool = $script:PriorPool
    }

    It 'reuses the open pool for the next subscription under the wrappers' {
        $First = & $script:PoolCreate $true
        $Second = & $script:PoolCreate $true
        [object]::ReferenceEquals($First.Pool, $Second.Pool) | Should -BeTrue -Because 'one pool serves every subscription of the run'
        [object]::ReferenceEquals($Global:MetricCallPool, $First.Pool) | Should -BeTrue
        $First.Diag.Count | Should -Be 0
        @($Second.Diag | Where-Object { $_ -like 'Metric worker pool reused*' }).Count | Should -Be 1
    }

    It 'builds a fresh pool per run, and keeps nothing in the global, outside the wrappers' {
        $First = & $script:PoolCreate $false
        $Second = & $script:PoolCreate $false
        try
        {
            [object]::ReferenceEquals($First.Pool, $Second.Pool) | Should -BeFalse
            $Global:MetricCallPool | Should -BeNullOrEmpty
        }
        finally
        {
            foreach ($P in @($First.Pool, $Second.Pool)) { [void]$P.BeginClose($null, $null).AsyncWaitHandle.WaitOne(10000); $P.Dispose() }
        }
    }

    It 'does not reuse a pool that is no longer open' {
        $First = & $script:PoolCreate $true
        [void]$First.Pool.BeginClose($null, $null).AsyncWaitHandle.WaitOne(10000)
        $First.Pool.Dispose()
        $Second = & $script:PoolCreate $true
        [object]::ReferenceEquals($First.Pool, $Second.Pool) | Should -BeFalse
        $Second.Pool.RunspacePoolStateInfo.State | Should -Be 'Opened'
        [object]::ReferenceEquals($Global:MetricCallPool, $Second.Pool) | Should -BeTrue
    }

    It 'keeps an idle pool open at phase end under the wrappers, and the wrapper releases it once at the end' {
        $Pool = (& $script:PoolCreate $true).Pool
        $Call = [powershell]::Create()
        $Call.RunspacePool = $Pool
        [void]$Call.AddScript('1').Invoke()
        $Call.Dispose()

        $Result = & $script:PoolTeardownShared $Pool ([System.Collections.Concurrent.ConcurrentBag[psobject]]::new()) 10 $true
        $Result.Released | Should -BeFalse
        $Pool.RunspacePoolStateInfo.State | Should -Be 'Opened'
        [object]::ReferenceEquals($Global:MetricCallPool, $Pool) | Should -BeTrue
        @($Result.Diag | Where-Object { $_ -like 'Metric worker pool kept open for the next subscription*' }).Count | Should -Be 1

        $ReleaseOutput = @(Close-RdaMetricWorkerPool 3>&1)
        @($ReleaseOutput | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }).Count | Should -Be 0 -Because 'a pool that was released holds nothing after the run, so there is nothing to report'
        @($ReleaseOutput | Where-Object { $_ -is [string] }) | Should -Be @('released')
        $Pool.RunspacePoolStateInfo.State | Should -Be 'Closed'
        $Global:MetricCallPool | Should -BeNullOrEmpty
        $SecondOutput = @(Close-RdaMetricWorkerPool 3>&1)
        @($SecondOutput | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }).Count | Should -Be 0
        @($SecondOutput | Where-Object { $_ -is [string] }) | Should -Be @('none')
    }

    It 'retires a pool whose worker outlasts the grace window instead of handing it to the next subscription' {
        $Pool = (& $script:PoolCreate $true).Pool
        $Call = [powershell]::Create()
        $Call.RunspacePool = $Pool
        [void]$Call.AddScript('[System.Threading.Thread]::Sleep(3000)')
        $Handle = $Call.BeginInvoke()
        try
        {
            $Started = [System.Diagnostics.Stopwatch]::StartNew()
            while ($Call.InvocationStateInfo.State -ne 'Running' -and $Started.Elapsed.TotalSeconds -lt 60) { Start-Sleep -Milliseconds 50 }
            $Call.InvocationStateInfo.State | Should -Be 'Running'

            $Result = & $script:PoolTeardownShared $Pool ([System.Collections.Concurrent.ConcurrentBag[psobject]]::new()) 1 $true

            $Result.Released | Should -BeFalse -Because 'a worker was still running'
            $Global:MetricCallPool | Should -BeNullOrEmpty -Because 'a busy pool is never reused'
            @($Result.Diag | Where-Object { $_ -like 'WARNING: metric worker pool NOT released*' }).Count | Should -Be 1
            $Next = (& $script:PoolCreate $true).Pool
            [object]::ReferenceEquals($Next, $Pool) | Should -BeFalse
        }
        finally
        {
            $Waited = [System.Diagnostics.Stopwatch]::StartNew()
            while (-not $Handle.IsCompleted -and $Waited.Elapsed.TotalSeconds -lt 10) { Start-Sleep -Milliseconds 100 }
            $Call.Dispose()
            $Pool.Dispose()
        }
    }

    It 'Close-RdaMetricWorkerPool leaves a pool with a busy worker alone' {
        $Pool = (& $script:PoolCreate $true).Pool
        $Call = [powershell]::Create()
        $Call.RunspacePool = $Pool
        [void]$Call.AddScript('[System.Threading.Thread]::Sleep(3000)')
        $Handle = $Call.BeginInvoke()
        try
        {
            $Started = [System.Diagnostics.Stopwatch]::StartNew()
            while ($Call.InvocationStateInfo.State -ne 'Running' -and $Started.Elapsed.TotalSeconds -lt 60) { Start-Sleep -Milliseconds 50 }
            $Timer = [System.Diagnostics.Stopwatch]::StartNew()
            Close-RdaMetricWorkerPool 3>$null | Should -Be 'not released: a worker is still busy'
            $Timer.Elapsed.TotalSeconds | Should -BeLessThan 1 -Because 'it never waits on a running call'
            $Pool.RunspacePoolStateInfo.State | Should -Be 'Opened'
        }
        finally
        {
            $Waited = [System.Diagnostics.Stopwatch]::StartNew()
            while (-not $Handle.IsCompleted -and $Waited.Elapsed.TotalSeconds -lt 10) { Start-Sleep -Milliseconds 100 }
            $Call.Dispose()
            [void]$Pool.BeginClose($null, $null).AsyncWaitHandle.WaitOne(10000)
            $Pool.Dispose()
        }
    }

    Context 'a pool that is not in a usable state, and a pool that cannot be released' {
        BeforeAll {
            # A real broken pool cannot be used here: one made to fail its open keeps this process from exiting.
            # The members the release code touches are stood in for, and the calls it makes are counted.
            $script:NewFakePool = {
                param([System.Management.Automation.Runspaces.RunspacePoolState]$State, [int]$Available = 2, [int]$Max = 2)
                $Pool = [pscustomobject]@{ RunspacePoolStateInfo = [pscustomobject]@{ State = $State }; DisposeCount = 0; BeginCloseCount = 0; Available = $Available; Max = $Max }
                Add-Member -InputObject $Pool -MemberType ScriptMethod -Name GetAvailableRunspaces -Value { $this.Available }
                Add-Member -InputObject $Pool -MemberType ScriptMethod -Name GetMaxRunspaces -Value { $this.Max }
                Add-Member -InputObject $Pool -MemberType ScriptMethod -Name Dispose -Value { $this.DisposeCount++ }
                Add-Member -InputObject $Pool -MemberType ScriptMethod -Name BeginClose -Value {
                    param($Callback, $AsyncState)
                    $this.BeginCloseCount++
                    $Wait = [pscustomobject]@{}
                    Add-Member -InputObject $Wait -MemberType ScriptMethod -Name WaitOne -Value { param($Milliseconds) $true }
                    [pscustomobject]@{ IsCompleted = $true; AsyncWaitHandle = $Wait }
                }
                $Pool
            }
        }

        It 'disposes a broken pool at the end of a subscription instead of leaving it registered in the process' {
            $Pool = & $script:NewFakePool ([System.Management.Automation.Runspaces.RunspacePoolState]::Broken)
            $Global:MetricCallPool = $Pool
            $null = & $script:PoolTeardownShared $Pool ([System.Collections.Concurrent.ConcurrentBag[psobject]]::new()) 1 $true
            $Pool.DisposeCount | Should -Be 1 -Because 'an opened pool registers a cleanup timer that only Dispose removes, broken or not'
            $Global:MetricCallPool | Should -BeNullOrEmpty -Because 'a broken pool must not be handed to the next subscription'
        }

        It 'does not ask a broken pool to close, and says in the debug log that it was broken' {
            $Pool = & $script:NewFakePool ([System.Management.Automation.Runspaces.RunspacePoolState]::Broken)
            $Global:MetricCallPool = $Pool
            $Result = & $script:PoolTeardownShared $Pool ([System.Collections.Concurrent.ConcurrentBag[psobject]]::new()) 1 $true
            $Pool.BeginCloseCount | Should -Be 0 -Because 'a broken pool cannot be closed, and the close is what a running call would hold up'
            @($Result.Diag | Where-Object { $_ -like 'Metric worker pool was Broken*' }).Count | Should -Be 1 -Because 'the debug log is the only place the operator can see why the pool went'
        }

        It 'does not dispose a broken pool while an abandoned call is still running' {
            $Pool = & $script:NewFakePool ([System.Management.Automation.Runspaces.RunspacePoolState]::Broken)
            $Global:MetricCallPool = $Pool
            $Bag = [System.Collections.Concurrent.ConcurrentBag[psobject]]::new()
            $Call = [pscustomobject]@{ DisposeCount = 0 }
            Add-Member -InputObject $Call -MemberType ScriptMethod -Name Dispose -Value { $this.DisposeCount++ }
            $Bag.Add([pscustomobject]@{ Handle = [pscustomobject]@{ IsCompleted = $false }; Call = $Call })
            $Result = & $script:PoolTeardownShared $Pool $Bag 1 $true
            $Result.Running | Should -Be 1
            $Result.Released | Should -BeFalse -Because 'a call that has not returned can still hold a runspace of this pool'
            $Pool.DisposeCount | Should -Be 0 -Because 'the block comment promises a pool is never disposed under a running call, so the code has to check it'
            $Call.DisposeCount | Should -Be 0
            @($Result.Diag | Where-Object { $_ -like 'WARNING: metric worker pool NOT released*' }).Count | Should -Be 1
        }

        It 'Close-RdaMetricWorkerPool disposes a broken pool, says so, and stays silent' {
            $Pool = & $script:NewFakePool ([System.Management.Automation.Runspaces.RunspacePoolState]::Broken)
            $Global:MetricCallPool = $Pool
            $Output = @(Close-RdaMetricWorkerPool 3>&1)
            @($Output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }).Count | Should -Be 0 -Because 'a broken pool that was disposed is released, so nothing lives on to report'
            ($Output | Where-Object { $_ -is [string] }) | Should -BeLike 'released*'
            $Pool.DisposeCount | Should -Be 1
            $Global:MetricCallPool | Should -BeNullOrEmpty
        }

        It 'Close-RdaMetricWorkerPool warns, and still returns its result, when it leaves a pool with a busy worker alone' {
            $Pool = & $script:NewFakePool ([System.Management.Automation.Runspaces.RunspacePoolState]::Opened) 1 2
            $Global:MetricCallPool = $Pool
            $Output = @(Close-RdaMetricWorkerPool 3>&1)
            $Warnings = @($Output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
            $Warnings.Count | Should -Be 1 -Because 'a pool that is not released lives until the process ends, which a Write-Verbose line at the end of the run would never show'
            $Warnings[0].Message | Should -Match 'not released'
            @($Output | Where-Object { $_ -is [string] }) | Should -Be @('not released: a worker is still busy')
            $Pool.DisposeCount | Should -Be 0
        }

        It 'Close-RdaMetricWorkerPool stays silent when there is no pool' {
            # The released and Broken paths are pinned where they are exercised with a pool: 'keeps an idle
            # pool open at phase end ...' and 'disposes a broken pool, says so, and stays silent'.
            $Global:MetricCallPool = $null
            $Output = @(Close-RdaMetricWorkerPool 3>&1)
            @($Output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }).Count | Should -Be 0
            $Output | Should -Be @('none')
        }

        It 'Close-RdaMetricWorkerPool decides whether to warn from a flag, not from the text of its result' {
            # The result text is what the caller logs and what three other tests pin by value. If the
            # warning followed a prefix of that text, rewording any result would silence the report.
            $CommonPath = Join-Path $script:RepoRoot 'Functions/Common.Functions.ps1'
            $Ast = [System.Management.Automation.Language.Parser]::ParseFile($CommonPath, [ref]$null, [ref]$null)
            $Fn = @($Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq 'Close-RdaMetricWorkerPool' }, $true))
            $Fn.Count | Should -Be 1
            $Warns = @($Fn[0].FindAll({ param($N) $N -is [System.Management.Automation.Language.CommandAst] -and $N.GetCommandName() -eq 'Write-Warning' }, $true))
            $Warns.Count | Should -Be 1 -Because 'one report, on one path'
            $Guard = $null
            $Node = $Warns[0].Parent
            while ($null -ne $Node -and $Node -ne $Fn[0])
            {
                if ($Node -is [System.Management.Automation.Language.IfStatementAst])
                {
                    $Guard = $Node
                    break
                }
                $Node = $Node.Parent
            }
            $Guard | Should -Not -BeNullOrEmpty -Because 'only a pool that was not released is reported'
            $Guard.Clauses[0].Item1.Extent.Text | Should -Be '-not $Released'
            $Fn[0].Extent.Text | Should -Not -Match 'not released\*' -Because 'no prefix match on the result text may decide whether to warn'
        }

        It 'Close-RdaMetricWorkerPool still returns its result when the caller has turned warnings into errors' {
            # Most callers run it from a finally block or from Exit-Wrapper ahead of Stop-Transcript, so a throw
            # out of the report would skip the rest of the cleanup. The normal end of Run-AllSubscriptions.ps1
            # calls it outside any finally, after Stop-Transcript and on the line before its exit, where a throw
            # would lose the exit code; on that path the warning reaches the console only. The pool decision is
            # already made by then and the caller still needs the result it logs.
            $Pool = & $script:NewFakePool ([System.Management.Automation.Runspaces.RunspacePoolState]::Opened) 1 2
            $Global:MetricCallPool = $Pool
            $WarningPreference = 'Stop'
            $Thrown = $null
            $StopResult = $null
            try { $StopResult = Close-RdaMetricWorkerPool 3>$null } catch { $Thrown = $_ }
            $Thrown | Should -BeNullOrEmpty -Because 'a report that cannot be delivered is dropped, not turned into a terminating error'
            $StopResult | Should -Be 'not released: a worker is still busy'
            $Pool.DisposeCount | Should -Be 0
        }

        It 'Close-RdaMetricWorkerPool says the pool stays in memory, and never doubles the period of an error it quotes' {
            # A close handle that comes back without a wait handle is the realistic way the catch ends up
            # quoting a message that already ends in a period; a throw from a stand-in method would be
            # wrapped by PowerShell and end in a quote instead.
            $Pool = & $script:NewFakePool ([System.Management.Automation.Runspaces.RunspacePoolState]::Opened)
            Add-Member -InputObject $Pool -MemberType ScriptMethod -Name BeginClose -Force -Value { param($Callback, $AsyncState) [pscustomobject]@{ IsCompleted = $true; AsyncWaitHandle = $null } }
            $Global:MetricCallPool = $Pool
            # PowerShell words this error in the language of the host, so the expected text is read from the
            # same failure here rather than written out in English.
            $NullCallMessage = $null
            try { $null.WaitOne(0) } catch { $NullCallMessage = $_.Exception.Message }
            $NullCallMessage | Should -Not -BeNullOrEmpty
            $Output = @(Close-RdaMetricWorkerPool 3>&1)
            $Warnings = @($Output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
            $Warnings.Count | Should -Be 1
            $Warnings[0].Message | Should -Be ('Metric worker pool not released: {0}. It stays in memory until this PowerShell process ends.' -f $NullCallMessage.TrimEnd('.')) -Because 'the pool may be Closed or Broken rather than open, and what the operator needs to know is that it is still held'
            $Warnings[0].Message | Should -Not -Match '\.\.' -Because 'a quoted error message that ends in a period must not produce ".."'
            @($Output | Where-Object { $_ -is [string] }) | Should -Be @(('not released: {0}' -f $NullCallMessage)) -Because 'the result the caller logs is unchanged'
            $Pool.DisposeCount | Should -Be 0 -Because 'a pool whose close never finished is not disposed'
        }

        It 'Close-RdaMetricWorkerPool warns once, and still returns its result, for a pool left in a state it cannot release' {
            # A pool that is neither open nor broken - closed, closing or still opening - is left alone, and like
            # any pool that is not released it then stays in memory until the process ends.
            $Pool = & $script:NewFakePool ([System.Management.Automation.Runspaces.RunspacePoolState]::Closed)
            $Global:MetricCallPool = $Pool
            $Output = @(Close-RdaMetricWorkerPool 3>&1)
            $Warnings = @($Output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
            $Warnings.Count | Should -Be 1 -Because 'a pool that is not released lives until the process ends, which only the warning shows'
            $Warnings[0].Message | Should -Be 'Metric worker pool not released: pool state Closed. It stays in memory until this PowerShell process ends.'
            @($Output | Where-Object { $_ -is [string] }) | Should -Be @('not released: pool state Closed')
            $Pool.DisposeCount | Should -Be 0
            $Pool.BeginCloseCount | Should -Be 0 -Because 'only an open pool is asked to close'
            $Global:MetricCallPool | Should -BeNullOrEmpty
        }
    }

    It 'releases the pool in a finally on both in-process paths, so a Ctrl+C in an interactive session does not leave it open' {
        $WrapperAst = [System.Management.Automation.Language.Parser]::ParseFile($script:WrapperPath, [ref]$null, [ref]$null)
        $Runs = @($WrapperAst.FindAll({ param($N) $N -is [System.Management.Automation.Language.CommandAst] -and $N.InvocationOperator -eq 'Ampersand' -and $N.Extent.Text -match 'ResourceInventory\.ps1' }, $true))
        $Runs.Count | Should -Be 2 -Because 'the sequential loop and the one-subscription fallback are the two in-process runs'
        foreach ($Run in $Runs)
        {
            $Node = $Run.Parent
            $Covered = $false
            while ($null -ne $Node)
            {
                if ($Node -is [System.Management.Automation.Language.TryStatementAst] -and $null -ne $Node.Finally -and $Node.Finally.Extent.Text -match 'Close-RdaMetricWorkerPool' -and $Run.Extent.StartOffset -ge $Node.Body.Extent.StartOffset -and $Run.Extent.EndOffset -le $Node.Body.Extent.EndOffset)
                {
                    $Covered = $true
                    break
                }
                $Node = $Node.Parent
            }
            $Covered | Should -BeTrue -Because ('the run at line {0} has to sit in the body of a try whose finally calls Close-RdaMetricWorkerPool' -f $Run.Extent.StartLineNumber)
        }
    }

    It 'is switched on only by the wrappers, which release the pool on every exit path' {
        $script:InvSrc | Should -Match '-ReuseWorkerPool:\$RunAllSubs\.IsPresent'
        $script:WrapperFnSrc | Should -Match '(?s)function Exit-Wrapper\s*\{.*?Close-RdaMetricWorkerPool.*?exit \$Code'
        $script:WrapperSrc | Should -Match 'Close-RdaMetricWorkerPool\)\)\s*\r?\nexit \$WrapperExitCode'
    }

    Context 'a worker pool that cannot be opened' {
        BeforeAll {
            # A real pool made to fail its open keeps this process from exiting, so the open is driven
            # against a stand-in, as the broken-pool Context above does. The block under test is lifted
            # out of the shipped script by AST so the tests run what Metrics.ps1 does.
            $OpenAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepoRoot 'Extension/Metrics.ps1'), [ref]$null, [ref]$null)
            $OpenTry = @($OpenAst.FindAll({ param($N) $N -is [System.Management.Automation.Language.TryStatementAst] -and $N.Body.Extent.Text -match '\$MetricCallPool\.Open\(\)' }, $true))
            if ($OpenTry.Count -ne 1) { throw ('Expected one try block that opens the metrics pool; found {0}. A failed Open() outside a try leaves a Broken pool undisposed.' -f $OpenTry.Count) }
            $script:PoolOpenTryAst = $OpenTry[0]
            $script:PoolOpen = [scriptblock]::Create((@(
                        'param($Pool, $ReuseWorkerPool, $MetricCount, $MetricDefs, $SubLookup)'
                        '$MetricCallPool = $Pool'
                        '$MetricPerCallPoolFailed = $false'
                        # This harness drives the LAST attempt: with no retry left the catch takes the
                        # give-up branch, which is the one every assertion below is about.
                        '$MetricPoolOpenRetriesLeft = 0'
                        '$OpenDiag = [System.Collections.Generic.List[string]]::new()'
                        '$OpenLog = [System.Collections.Generic.List[object]]::new()'
                        'function Write-MetricsDiag { param($Message) $OpenDiag.Add([string]$Message) }'
                        'function Write-Log { param($Message, $Severity, [switch]$NoConsole, [switch]$ToDebugLog) $OpenLog.Add([pscustomobject]@{ Message = [string]$Message; Severity = [string]$Severity }) }'
                        $OpenTry[0].Extent.Text
                        '[pscustomobject]@{ Pool = $MetricCallPool; Count = $MetricCount; PoolFailed = $MetricPerCallPoolFailed; Diag = @($OpenDiag); Log = @($OpenLog) }'
                    ) -join [Environment]::NewLine))
            $script:NewUnopenablePool = {
                param([string]$Message = 'Insufficient resources to start a runspace.')
                $Pool = [pscustomobject]@{ DisposeCount = 0; OpenCount = 0; OpenError = $Message }
                Add-Member -InputObject $Pool -MemberType ScriptMethod -Name Open -Value { $this.OpenCount++; throw $this.OpenError }
                Add-Member -InputObject $Pool -MemberType ScriptMethod -Name Dispose -Value { $this.DisposeCount++ }
                $Pool
            }
            $script:OpenDefs = [System.Collections.Generic.List[object]]@(
                [pscustomobject]@{ Id = '/subscriptions/AAAA-1/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1' }
                [pscustomobject]@{ Id = '/subscriptions/aaaa-1/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm2' }
                [pscustomobject]@{ Id = '/subscriptions/bbbb-2/resourceGroups/rg/providers/Microsoft.Sql/servers/s1/databases/d1' })
            $script:OpenSubLookup = @{ 'aaaa-1' = [pscustomobject]@{ id = 'aaaa-1'; Name = 'Contoso-Dev' }; 'bbbb-2' = [pscustomobject]@{ id = 'bbbb-2'; Name = 'Contoso-Prod' } }
        }

        BeforeEach {
            $script:PriorFailedSubs = $Global:MetricsFailedSubs
            $Global:MetricsFailedSubs = @()
        }

        AfterEach {
            $Global:MetricsFailedSubs = $script:PriorFailedSubs
        }

        It 'disposes the pool, keeps nothing in the global, and gives up only the per-call collection' {
            $Pool = & $script:NewUnopenablePool
            $Result = & $script:PoolOpen $Pool $true 7 $script:OpenDefs $script:OpenSubLookup
            $Pool.OpenCount | Should -Be 1
            $Pool.DisposeCount | Should -Be 1 -Because 'a pool that failed its open has already registered the cleanup timer that only Dispose removes'
            $Result.Pool | Should -BeNullOrEmpty -Because 'the teardown in the finally must not be handed a pool that is gone'
            $Global:MetricCallPool | Should -BeNullOrEmpty -Because 'a pool that cannot be opened must never serve the next subscription'
            $Result.Count | Should -Be 0 -Because 'the per-call loop cannot run without a pool, so it is skipped rather than failed one call at a time'
            $Result.PoolFailed | Should -BeTrue -Because 'without the flag the phase start says there is nothing to collect, right under the ERROR line that says the pool failed'
        }

        It 'fails loud: an Error in the run log and the reason in the debug log' {
            $Pool = & $script:NewUnopenablePool 'Insufficient resources to start a runspace.'
            $Result = & $script:PoolOpen $Pool $true 7 $script:OpenDefs $script:OpenSubLookup
            @($Result.Diag | Where-Object { $_ -like 'ERROR: Metrics: the metric worker pool could not be opened*' }).Count | Should -Be 1
            $Errors = @($Result.Log | Where-Object { $_.Severity -eq 'Error' })
            $Errors.Count | Should -Be 1 -Because 'under the default error preference a failed open was swallowed and only the workers complained, one per call'
            $Errors[0].Message | Should -BeLike '*Insufficient resources to start a runspace.*' -Because 'the operator needs the host error, not a generic failure'
            $Errors[0].Message | Should -BeLike '*7 per-call metric definition(s) were not collected*'
        }

        It 'points the operator at a re-run that collects the missing metrics, not at one that keeps the gap' {
            # A subscription whose pool could not open still finishes its inventory, so a wrapper stream marks
            # it completed and a -Resume run skips it with its metrics still missing. The tool has no way to
            # re-run the metrics phase on its own, so the advice names the two runs that do collect them.
            $Pool = & $script:NewUnopenablePool
            $Result = & $script:PoolOpen $Pool $true 7 $script:OpenDefs $script:OpenSubLookup
            $ErrorLine = @($Result.Log | Where-Object { $_.Severity -eq 'Error' })[0].Message
            $ErrorLine | Should -BeLike '*free memory on this host or use a lower -ConcurrencyLimit*'
            $ErrorLine | Should -BeLike '*re-run without -Resume, or run ResourceInventory.ps1 -SubscriptionID <id> for each subscription listed as metrics incomplete*'
            $ErrorLine | Should -BeLike '*a -Resume run skips them because their inventory completed.'
            $ErrorLine | Should -Not -BeLike '*metrics phase*' -Because 'there is no way to re-run only that phase'
            $ErrorLine | Should -Not -Match '(?i)auth' -Because 'the remedy is memory on the host, not a token'
        }

        It 'names every affected subscription in the wrapper health list, once per subscription' {
            $Pool = & $script:NewUnopenablePool
            $null = & $script:PoolOpen $Pool $true 7 $script:OpenDefs $script:OpenSubLookup
            $Entries = @($Global:MetricsFailedSubs)
            $Entries.Count | Should -Be 2 -Because 'the two casings of one subscription id are the same subscription'
            @($Entries | ForEach-Object { $_.Id } | Sort-Object) | Should -Be @('aaaa-1', 'bbbb-2')
            @($Entries | ForEach-Object { $_.Name } | Sort-Object) | Should -Be @('Contoso-Dev', 'Contoso-Prod')
            @($Entries | Where-Object { $_.Message -like '*could not be opened*' }).Count | Should -Be 2
            # Each entry carries its own count, not the phase total: this phase has 7 definitions on the
            # per-call path, of which two belong to aaaa-1 and one to bbbb-2.
            ($Entries | Where-Object { $_.Id -eq 'aaaa-1' }).Message | Should -BeLike '*2 per-call metric definition(s) of this subscription were not collected*'
            ($Entries | Where-Object { $_.Id -eq 'bbbb-2' }).Message | Should -BeLike '*1 per-call metric definition(s) of this subscription were not collected*'
            @($Entries | Where-Object { $_.Message -like '*7 per-call*' }).Count | Should -Be 0 -Because 'the phase total belongs to the one phase-wide line, not to each subscription'
        }

        It 'falls back to one unknown-subscription entry when no definition carries a subscription id' {
            $Pool = & $script:NewUnopenablePool
            $Defs = [System.Collections.Generic.List[object]]@([pscustomobject]@{ Id = 'not-an-arm-id' })
            $null = & $script:PoolOpen $Pool $true 1 $Defs $script:OpenSubLookup
            $Entries = @($Global:MetricsFailedSubs)
            $Entries.Count | Should -Be 1
            $Entries[0].Id | Should -Be '(unknown)'
            $Entries[0].Name | Should -Be '(subscription)'
        }

        It 'stores the pool for the next subscription only after the open has returned' {
            $Open = @($script:PoolOpenTryAst.Body.FindAll({ param($N) $N -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $N.Member.Extent.Text -eq 'Open' }, $true))
            $Open.Count | Should -Be 1
            $Store = @($script:PoolOpenTryAst.FindAll({ param($N) $N -is [System.Management.Automation.Language.AssignmentStatementAst] -and $N.Left.Extent.Text -eq '$Global:MetricCallPool' -and $N.Right.Extent.Text -eq '$MetricCallPool' }, $true))
            $Store.Count | Should -Be 1 -Because 'the only place the pool is kept for the next subscription is inside this try'
            $Store[0].Extent.StartOffset | Should -BeGreaterThan $Open[0].Extent.EndOffset -Because 'a pool stored before the open could be handed on in a Broken state'
            $Store[0].Extent.StartOffset | Should -BeLessThan $script:PoolOpenTryAst.Body.Extent.EndOffset
        }

        It 'tags every entry it writes with Cause pool, so the wrapper does not report an auth failure' {
            $Pool = & $script:NewUnopenablePool
            $null = & $script:PoolOpen $Pool $true 7 $script:OpenDefs $script:OpenSubLookup
            $Entries = @($Global:MetricsFailedSubs)
            $Entries.Count | Should -Be 2
            @($Entries | ForEach-Object { [string]$_.Cause }) | Should -Be @('pool', 'pool') -Because 'without the tag the wrapper counts the entry as an auth skip and tells the operator to run Connect-AzAccount'

            $Global:MetricsFailedSubs = @()
            $Pool = & $script:NewUnopenablePool
            $Unknown = [System.Collections.Generic.List[object]]@([pscustomobject]@{ Id = 'not-an-arm-id' })
            $null = & $script:PoolOpen $Pool $true 1 $Unknown $script:OpenSubLookup
            @($Global:MetricsFailedSubs | ForEach-Object { [string]$_.Cause }) | Should -Be @('pool') -Because 'the unknown-subscription fallback is the same failure'
        }
    }

    Context 'a worker pool whose first open fails' {
        BeforeAll {
            # The retry is driven over the WHOLE create-and-open block, not the open try alone, because
            # the retry is what decides whether that block runs a second time. The one runspace factory
            # call is swapped for a stand-in queue so an open can be made to fail on demand, and the
            # swap is asserted to hit exactly one site, so a second factory call cannot slip past it.
            $RetryAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepoRoot 'Extension/Metrics.ps1'), [ref]$null, [ref]$null)
            $RetryBlock = @($RetryAst.FindAll({ param($N) $N -is [System.Management.Automation.Language.IfStatementAst] -and $N.Clauses[0].Item1.Extent.Text -eq '$MetricCount -gt 0' -and $N.Extent.Text -match 'CreateRunspacePool' }, $true))
            if ($RetryBlock.Count -ne 1) { throw ('Expected one block that builds the metrics pool; found {0}.' -f $RetryBlock.Count) }
            $FactoryText = '[runspacefactory]::CreateRunspacePool([initialsessionstate]::CreateDefault2())'
            $BlockText = $RetryBlock[0].Extent.Text
            $FactoryCount = ([regex]::Matches($BlockText, [regex]::Escape($FactoryText))).Count
            if ($FactoryCount -ne 1) { throw ('Expected exactly one runspace factory call in the pool block; found {0}. A second one would build a pool the stand-in queue never sees.' -f $FactoryCount) }
            $script:PoolRetry = [scriptblock]::Create((@(
                        'param($PoolQueue, $ReuseWorkerPool, $MetricCount, $MetricDefs, $SubLookup, $MetricPoolOpenRetryDelaySeconds = 0, $ConcurrencyLimit = 2, $MetricMaxRetries = 0)'
                        '$MetricCallPool = $null'
                        '$MetricPerCallPoolFailed = $false'
                        '$RetryDiag = [System.Collections.Generic.List[string]]::new()'
                        '$RetryLog = [System.Collections.Generic.List[object]]::new()'
                        '$RetrySleeps = [System.Collections.Generic.List[object]]::new()'
                        '$RetrySnapshots = [System.Collections.Generic.List[string]]::new()'
                        '$RetryPoolHeldAtWait = [System.Collections.Generic.List[object]]::new()'
                        '$RetryFactoryCalls = [System.Collections.Generic.List[object]]::new()'
                        'function Write-MetricsDiag { param($Message) $RetryDiag.Add([string]$Message) }'
                        'function Write-Log { param($Message, $Severity, [switch]$NoConsole, [switch]$ToDebugLog) $RetryLog.Add([pscustomobject]@{ Message = [string]$Message; Severity = [string]$Severity }) }'
                        'function Write-RdaMemorySnapshot { param($Phase, [switch]$Compact, [switch]$Record) $RetrySnapshots.Add([string]$Phase); $RetryPoolHeldAtWait.Add($MetricCallPool) }'
                        'function Start-Sleep { param([int]$Seconds, [int]$Milliseconds) $RetrySleeps.Add($Seconds); $RetryPoolHeldAtWait.Add($MetricCallPool) }'
                        'function New-RdaStandInPool { if ($PoolQueue.Count -eq 0) { throw ''the pool block asked for more pools than this test queued'' }; $Next = $PoolQueue.Dequeue(); $RetryFactoryCalls.Add($Next); $Next }'
                        $BlockText.Replace($FactoryText, '(New-RdaStandInPool)')
                        '[pscustomobject]@{ Pool = $MetricCallPool; Count = $MetricCount; PoolFailed = $MetricPerCallPoolFailed; Diag = @($RetryDiag); Log = @($RetryLog); Sleeps = @($RetrySleeps); Snapshots = @($RetrySnapshots); HeldAtWait = @($RetryPoolHeldAtWait); Factory = @($RetryFactoryCalls) }'
                    ) -join [Environment]::NewLine))
            # A stand-in rather than a real pool: a real one made to fail its open keeps this process
            # from exiting. An empty OpenError means that attempt succeeds.
            $script:NewQueuedPool = {
                param([string]$Message)
                $Pool = [pscustomobject]@{ OpenCount = 0; DisposeCount = 0; OpenError = $Message; MaxRunspaces = 0 }
                Add-Member -InputObject $Pool -MemberType ScriptMethod -Name Open -Value { $this.OpenCount++; if (-not [string]::IsNullOrEmpty($this.OpenError)) { throw $this.OpenError } }
                Add-Member -InputObject $Pool -MemberType ScriptMethod -Name Dispose -Value { $this.DisposeCount++ }
                Add-Member -InputObject $Pool -MemberType ScriptMethod -Name SetMaxRunspaces -Value { param($Count) $this.MaxRunspaces = [int]$Count; $true }
                $Pool
            }
            $script:RetryDefs = [System.Collections.Generic.List[object]]@(
                [pscustomobject]@{ Id = '/subscriptions/aaaa-1/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1' }
                [pscustomobject]@{ Id = '/subscriptions/bbbb-2/resourceGroups/rg/providers/Microsoft.Sql/servers/s1/databases/d1' })
            $script:RetrySubLookup = @{ 'aaaa-1' = [pscustomobject]@{ id = 'aaaa-1'; Name = 'Contoso-Dev' }; 'bbbb-2' = [pscustomobject]@{ id = 'bbbb-2'; Name = 'Contoso-Prod' } }
        }

        BeforeEach {
            $script:PriorRetryFailedSubs = $Global:MetricsFailedSubs
            $Global:MetricsFailedSubs = @()
        }

        AfterEach {
            # A stand-in pool is not a runspace pool, so the real closer in the enclosing AfterEach
            # must never be handed one.
            $Global:MetricCallPool = $null
            $Global:MetricsFailedSubs = $script:PriorRetryFailedSubs
        }

        It 'opens on the second attempt, and the subscription keeps its per-call collection' {
            $Queue = [System.Collections.Queue]::new()
            $Queue.Enqueue((& $script:NewQueuedPool 'Insufficient resources to start a runspace.'))
            $Queue.Enqueue((& $script:NewQueuedPool ''))
            $Result = & $script:PoolRetry $Queue $true 7 $script:RetryDefs $script:RetrySubLookup

            $Result.Factory.Count | Should -Be 2 -Because 'the retry builds a fresh pool; the broken one can serve no call'
            $Result.Factory[0].DisposeCount | Should -Be 1 -Because 'the pool that failed its open has already registered the cleanup timer that only Dispose removes'
            $Result.Factory[1].DisposeCount | Should -Be 0
            $Result.Factory[1].OpenCount | Should -Be 1
            [object]::ReferenceEquals($Result.Pool, $Result.Factory[1]) | Should -BeTrue
            [object]::ReferenceEquals($Global:MetricCallPool, $Result.Factory[1]) | Should -BeTrue -Because 'the pool that did open is the one handed to the next subscription'
            $Result.Factory[1].MaxRunspaces | Should -Be $Result.Factory[0].MaxRunspaces -Because 'Open allocates runspaces on demand, so a smaller retry pool would only bring back calls that time out while queued'
            $Result.Count | Should -Be 7 -Because 'the per-call loop runs, so nothing is given up'
            $Result.PoolFailed | Should -BeFalse
            @($Global:MetricsFailedSubs).Count | Should -Be 0 -Because 'an open that succeeded on the retry left no gap to report'
            @($Result.Log | Where-Object { $_.Severity -eq 'Error' }).Count | Should -Be 0 -Because 'the first failure is a warning; only giving up is an error'
            @($Result.Log | Where-Object { $_.Severity -eq 'Warning' }).Count | Should -Be 1
            @($Result.Log | Where-Object { $_.Severity -eq 'Warning' })[0].Message | Should -BeLike '*Insufficient resources to start a runspace.*'
            @($Result.Diag | Where-Object { $_ -like 'ERROR: *' }).Count | Should -Be 0
        }

        It 'disposes the broken pool and compacts memory before it waits' {
            $Queue = [System.Collections.Queue]::new()
            $Queue.Enqueue((& $script:NewQueuedPool 'Insufficient resources to start a runspace.'))
            $Queue.Enqueue((& $script:NewQueuedPool ''))
            $Result = & $script:PoolRetry $Queue $true 7 $script:RetryDefs $script:RetrySubLookup

            $Result.Snapshots | Should -Be @('Metric worker pool open failed') -Because 'one compacting reading, so the debug log shows what the host had at the moment the open failed'
            $Result.Sleeps | Should -Be @(0) -Because 'it waits once, reading the constant the caller passes'
            $Result.HeldAtWait.Count | Should -Be 2 -Because 'the snapshot and the wait each record what the block was still holding'
            @($Result.HeldAtWait | Where-Object { $null -ne $_ }).Count | Should -Be 0 -Because 'the broken pool is disposed and dropped before the wait, so nothing holds its memory while the host is asked for more'
            $Global:MetricCallPool | Should -Not -BeNullOrEmpty
        }

        It 'gives up after the second failure with the same skip it has today, quoting the second error' {
            $Queue = [System.Collections.Queue]::new()
            $Queue.Enqueue((& $script:NewQueuedPool 'first open failed'))
            $Queue.Enqueue((& $script:NewQueuedPool 'second open failed too'))
            $Result = & $script:PoolRetry $Queue $true 7 $script:RetryDefs $script:RetrySubLookup

            $Result.Factory.Count | Should -Be 2
            @($Result.Factory | ForEach-Object { $_.DisposeCount }) | Should -Be @(1, 1) -Because 'both pools registered the cleanup timer'
            $Result.Pool | Should -BeNullOrEmpty
            $Global:MetricCallPool | Should -BeNullOrEmpty -Because 'a pool that cannot be opened must never serve the next subscription'
            $Result.Count | Should -Be 0
            $Result.PoolFailed | Should -BeTrue
            $Errors = @($Result.Log | Where-Object { $_.Severity -eq 'Error' })
            $Errors.Count | Should -Be 1
            $Errors[0].Message | Should -BeLike '*second open failed too*' -Because 'the operator needs the error the last attempt hit, not the one already superseded'
            @($Result.Log | Where-Object { $_.Severity -eq 'Warning' }).Count | Should -Be 1 -Because 'the warning belongs to the first failure only'
            $Result.Sleeps | Should -Be @(0)
            $Entries = @($Global:MetricsFailedSubs)
            $Entries.Count | Should -Be 2 -Because 'the health entry is written only after the retry has failed too'
            @($Entries | ForEach-Object { $_.Id } | Sort-Object) | Should -Be @('aaaa-1', 'bbbb-2')
            @($Entries | ForEach-Object { [string]$_.Cause }) | Should -Be @('pool', 'pool')
        }

        It 'never asks for a third pool' {
            $Queue = [System.Collections.Queue]::new()
            $Queue.Enqueue((& $script:NewQueuedPool 'first open failed'))
            $Queue.Enqueue((& $script:NewQueuedPool 'second open failed too'))
            $Queue.Enqueue((& $script:NewQueuedPool ''))
            $Result = & $script:PoolRetry $Queue $true 7 $script:RetryDefs $script:RetrySubLookup

            $Result.Factory.Count | Should -Be 2 -Because 'one retry, not a loop that keeps trying while the host stays short of memory'
            $Queue.Count | Should -Be 1 -Because 'the third pool was never requested'
            $Result.Pool | Should -BeNullOrEmpty
        }

        It 'builds no pool at all when an open one is already in the global' {
            $Open = [pscustomobject]@{ MaxRunspaces = 0; RunspacePoolStateInfo = [pscustomobject]@{ State = [System.Management.Automation.Runspaces.RunspacePoolState]::Opened } }
            Add-Member -InputObject $Open -MemberType ScriptMethod -Name SetMaxRunspaces -Value { param($Count) $this.MaxRunspaces = [int]$Count; $true }
            $Global:MetricCallPool = $Open
            $Queue = [System.Collections.Queue]::new()
            $Result = & $script:PoolRetry $Queue $true 7 $script:RetryDefs $script:RetrySubLookup

            $Result.Factory.Count | Should -Be 0 -Because 'the retry must not turn a reused pool into a rebuilt one'
            $Result.Sleeps.Count | Should -Be 0
            [object]::ReferenceEquals($Result.Pool, $Open) | Should -BeTrue
        }

        It 'says in the debug log that the pool opened on the second attempt, and stays silent on a first-attempt open' {
            $Queue = [System.Collections.Queue]::new()
            $Queue.Enqueue((& $script:NewQueuedPool 'Insufficient resources to start a runspace.'))
            $Queue.Enqueue((& $script:NewQueuedPool ''))
            $Retried = & $script:PoolRetry $Queue $true 7 $script:RetryDefs $script:RetrySubLookup
            @($Retried.Diag | Where-Object { $_ -like '*opened on the second attempt*' }).Count | Should -Be 1

            $Global:MetricCallPool = $null
            $Clean = [System.Collections.Queue]::new()
            $Clean.Enqueue((& $script:NewQueuedPool ''))
            $First = & $script:PoolRetry $Clean $true 7 $script:RetryDefs $script:RetrySubLookup
            $First.Diag.Count | Should -Be 0 -Because 'a first-time open is the ordinary case and says nothing'
            $First.Sleeps.Count | Should -Be 0
        }

        It 'keeps the retry wording free of auth and of a phase that cannot be re-run on its own' {
            $Queue = [System.Collections.Queue]::new()
            $Queue.Enqueue((& $script:NewQueuedPool 'Insufficient resources to start a runspace.'))
            $Queue.Enqueue((& $script:NewQueuedPool ''))
            $Result = & $script:PoolRetry $Queue $true 7 $script:RetryDefs $script:RetrySubLookup
            $Said = @(@($Result.Log | ForEach-Object { $_.Message }) + @($Result.Diag)) -join ' '
            $Said | Should -Not -Match '(?i)auth' -Because 'the remedy is memory on the host, not a token'
            $Said | Should -Not -Match '(?i)Connect-AzAccount'
            $Said | Should -Not -Match '(?i)metrics phase' -Because 'there is no way to re-run only that phase'
        }
    }
}

Describe 'Get-RdaFoundryRetailCatalog holds only what the coverage match reads' {
    BeforeAll {
        # Shaped like prices.azure.com Items[] entries. The catalog repeats a meter once per region.
        function New-TestCatalogItem
        {
            param([string]$Product, [string]$Meter, [string]$Sku, [string]$Region)
            [pscustomobject]@{
                currencyCode = 'USD'; tierMinimumUnits = 0.0; retailPrice = 0.0025; unitPrice = 0.0025; armRegionName = $Region; location = $Region
                effectiveStartDate = '2026-01-01T00:00:00Z'; meterId = [guid]::NewGuid().ToString(); meterName = $Meter; productId = 'DZH318Z0BQ4K'; skuId = 'DZH318Z0BQ4K/0001'
                productName = $Product; skuName = $Sku; serviceName = 'Foundry Models'; serviceId = 'DZH318Z0BQ4K'; serviceFamily = 'AI + Machine Learning'
                unitOfMeasure = '1K'; type = 'Consumption'; isPrimaryMeterRegion = $true; armSkuName = $Sku
            }
        }
        $script:CatalogPages = @(
            [pscustomobject]@{
                Items        = @(
                    (New-TestCatalogItem -Product 'Azure OpenAI' -Meter 'gpt 4o 0806 Inp regnl Tokens' -Sku 'gpt 4o 0806 Inp regnl' -Region 'eastus')
                    (New-TestCatalogItem -Product 'Azure OpenAI' -Meter 'gpt 4o 0806 Inp regnl Tokens' -Sku 'gpt 4o 0806 Inp regnl' -Region 'westeurope')
                    (New-TestCatalogItem -Product 'Mistral Large' -Meter 'Mistral Large Input Tokens' -Sku 'Mistral Large Input' -Region 'eastus')
                )
                NextPageLink = 'https://prices.example.invalid/api/retail/prices?page=2'
            }
            [pscustomobject]@{
                Items        = @(
                    (New-TestCatalogItem -Product 'Azure OpenAI' -Meter 'gpt 4o 0806 Inp regnl Tokens' -Sku 'gpt 4o 0806 Inp regnl' -Region 'swedencentral')
                    (New-TestCatalogItem -Product 'Phi-4' -Meter 'Phi-4 Input Tokens' -Sku 'Phi-4 Input' -Region 'eastus')
                )
                NextPageLink = $null
            }
        )
        $script:FullCatalog = @($script:CatalogPages | ForEach-Object { $_.Items })
    }
    BeforeEach {
        Mock Invoke-RestMethod { if ($Uri -like '*page=2*') { $script:CatalogPages[1] } else { $script:CatalogPages[0] } }
    }

    It 'keeps the first item of each product, meter and SKU, in catalog order, with only the four fields the match reads' {
        $Catalog = @(Get-RdaFoundryRetailCatalog)
        $Catalog.Count | Should -Be 3 -Because 'the regional copies of a meter carry the same four fields'
        ($Catalog | ForEach-Object { $_.meterName }) -join '|' | Should -Be 'gpt 4o 0806 Inp regnl Tokens|Mistral Large Input Tokens|Phi-4 Input Tokens'
        foreach ($Item in $Catalog)
        {
            ($Item.PSObject.Properties.Name -join ',') | Should -Be 'productName,meterName,skuName,armSkuName' -Because 'each full item holds some twenty properties the coverage phase never reads'
        }
    }

    It 'gives the coverage match the same answer as the full catalog for <ModelName>' -ForEach @(
        @{ ModelName = 'gpt-4o'; ModelFormat = 'OpenAI'; ShouldMatch = $true }
        @{ ModelName = 'Mistral-Large'; ModelFormat = 'Mistral AI'; ShouldMatch = $true }
        @{ ModelName = 'Phi-4'; ModelFormat = 'Microsoft'; ShouldMatch = $false }
        @{ ModelName = 'Llama-3.3-70B'; ModelFormat = 'Meta'; ShouldMatch = $false }
    ) {
        $Model = [pscustomobject]@{ ModelName = $ModelName; ModelFormat = $ModelFormat }
        $Expected = Test-RdaRetailPriceMatch -Model $Model -CatalogItems $script:FullCatalog
        $Actual = Test-RdaRetailPriceMatch -Model $Model -CatalogItems @(Get-RdaFoundryRetailCatalog)
        $Expected.Matched | Should -Be $ShouldMatch -Because 'the fixture has both a matching and a non-matching case, so the comparison is not vacuous'
        $Actual.Matched | Should -Be $Expected.Matched
        $Actual.RetailMatch | Should -Be $Expected.RetailMatch
    }
}

Describe 'The metrics auth skip in ResourceInventory.ps1 says why the metrics are missing' {
    # CreateMetricsJob records a subscription whose metrics it skipped for want of a usable token. Its entries
    # share $Global:MetricsFailedSubs with the pool failure in Extension/Metrics.ps1, so each writer tags its
    # own cause; the wrapper picks the banner and the remedy from that tag. The skip branch is lifted by AST and
    # run against stubs, so the test runs what the script does.
    BeforeAll {
        $InvAst = [System.Management.Automation.Language.Parser]::ParseFile($script:InvPath, [ref]$null, [ref]$null)
        $script:AuthSkipBranch = $InvAst.Find({ param($N) $N -is [System.Management.Automation.Language.IfStatementAst] -and $N.Clauses[0].Item1.Extent.Text -eq "-not (Test-DataPlaneAuthReady -Phase 'Metrics')" }, $true)
        $script:RunAuthSkip = {
            param($Subscriptions, [string]$SubscriptionID)
            $Runner = [scriptblock]::Create(((@(
                            'param($Subscriptions, $SubscriptionID)'
                            'function Test-DataPlaneAuthReady { param($Phase) $false }'
                            'function Write-Log { param($Message, $Severity) }'
                            '$Saved = @($Global:MetricsFailedSubs, $Global:Subscriptions, $Global:AzMetrics)'
                            'try'
                            '{'
                            '$Global:MetricsFailedSubs = @()'
                            '$Global:Subscriptions = $Subscriptions'
                            '& { ' + $script:AuthSkipBranch.Extent.Text + ' }'
                            '@($Global:MetricsFailedSubs)'
                            '}'
                            'finally { $Global:MetricsFailedSubs = $Saved[0]; $Global:Subscriptions = $Saved[1]; $Global:AzMetrics = $Saved[2] }'
                        ) -join [Environment]::NewLine)))
            & $Runner $Subscriptions $SubscriptionID
        }
    }

    It 'tags every entry it writes with Cause auth, including the unknown-subscription fallback' {
        $script:AuthSkipBranch | Should -Not -BeNullOrEmpty
        $Subs = @([pscustomobject]@{ id = 'aaaa-1'; Name = 'Contoso-Dev' }, [pscustomobject]@{ id = 'bbbb-2'; Name = 'Contoso-Prod' })
        $All = @(& $script:RunAuthSkip $Subs '')
        $All.Count | Should -Be 2
        @($All | ForEach-Object { [string]$_.Cause }) | Should -Be @('auth', 'auth') -Because 'the wrapper reports an auth skip from this tag'
        $One = @(& $script:RunAuthSkip $Subs 'bbbb-2')
        @($One | ForEach-Object { '{0}={1}' -f $_.Id, $_.Cause }) | Should -Be @('bbbb-2=auth')
        $None = @(& $script:RunAuthSkip @() 'zzzz-9')
        @($None | ForEach-Object { '{0}={1}' -f $_.Id, $_.Cause }) | Should -Be @('zzzz-9=auth') -Because 'the fallback entry is the same skip'
    }
}
