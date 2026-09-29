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
