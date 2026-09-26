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
    # 'A comes before B' rather than as line numbers that drift.
    $script:Offset = {
        param([string]$Source, [string]$Needle)
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

Describe 'ResourceInventory.ps1 releases the two large structures after their last reader' {
    It 'parses' {
        $Errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($script:InvPath, [ref]$null, [ref]$Errors)
        $Errors | Should -BeNullOrEmpty
    }

    It 'records the resource count once discovery has finished, before the collectors run' {
        $Count = & $script:Offset $script:InvSrc '$Global:ResourceCount = @($Global:Resources).Count'
        $DiscoveryCatch = & $script:Offset $script:InvSrc 'FAILED to complete resource discovery'
        $Collectors = & $script:Offset $script:InvSrc 'function CreateResourceJobs()'
        $Count | Should -BeGreaterThan $DiscoveryCatch -Because 'a discovery that threw has no count to report'
        $Count | Should -BeLessThan $Collectors
    }

    It 'resets the count at the start of every run' {
        $script:InvSrc | Should -Match '(?m)^\s+\$Global:ResourceCount = 0\s*$' -Because 'without the reset a run under the wrapper inherits the previous subscription''s count'
    }

    It 'releases both structures after the placement CSV and before the billing pull' {
        $Placement = & $script:Offset $script:InvSrc '& $PlacementScript -CsvFile $PlacementCsv'
        $ReleaseResources = & $script:Offset $script:InvSrc '$Global:Resources = $null'
        $ReleaseSma = & $script:Offset $script:InvSrc '$Global:SmaResources = $null'
        $Billing = & $script:Offset $script:InvSrc '        GetResourceConsumption'
        $ReleaseResources | Should -BeGreaterThan $Placement -Because 'the placement CSV reads both structures'
        $ReleaseSma | Should -BeGreaterThan $Placement
        $ReleaseResources | Should -BeLessThan $Billing -Because 'the billing pull is where a small host ran out of memory'
        $ReleaseSma | Should -BeLessThan $Billing
    }

    It 'has no reader of either structure after the release' {
        $Release = & $script:Offset $script:InvSrc '$Global:SmaResources = $null'
        $After = $script:InvSrc.Substring($Release + '$Global:SmaResources = $null'.Length)
        # Strip comment lines: the release is explained in a comment that names both structures.
        $Code = (($After -split "`r?`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
        $Code | Should -Not -Match 'Global:Resources\b'
        $Code | Should -Not -Match 'Global:SmaResources\b'
        $Code | Should -Not -Match '(^|[^A-Za-z:_$])\$Resources\b' -Because 'an unqualified $Resources resolves to the released global'
    }

    It 'takes each of the five recorded memory readings exactly once, at its phase boundary' {
        # Functions are defined before the main body, so file order is not execution order; each
        # reading is pinned against the statement that marks its own phase instead.
        $At = @{}
        foreach ($Phase in @('start', 'discovery', 'collectors', 'released', 'end'))
        {
            $Needle = "Write-RdaMemorySnapshot -Phase '{0}' -Compact -Record" -f $Phase
            ([regex]::Matches($script:InvSrc, [regex]::Escape($Needle))).Count | Should -Be 1 -Because "the '$Phase' reading is taken exactly once"
            $At[$Phase] = & $script:Offset $script:InvSrc $Needle
        }
        $At['start'] | Should -BeGreaterThan (& $script:Offset $script:InvSrc '    GetSubscriptionsData') -Because 'start is taken after sign-in and the subscription list, so start-to-discovery is the Resource Graph rows alone'
        $At['start'] | Should -BeLessThan (& $script:Offset $script:InvSrc '        ResourceInventoryLoop') -Because 'start is taken before the first Resource Graph page'
        $At['discovery'] | Should -BeGreaterThan (& $script:Offset $script:InvSrc 'FAILED to complete resource discovery')
        $At['discovery'] | Should -BeLessThan (& $script:Offset $script:InvSrc 'function ExecuteInventoryProcessing()')
        $At['collectors'] | Should -BeGreaterThan (& $script:Offset $script:InvSrc ('    ProcessResourceResult' + "`n"))
        $At['collectors'] | Should -BeLessThan (& $script:Offset $script:InvSrc 'if ($CapacityPlan.IsPresent)')
        $At['released'] | Should -BeGreaterThan (& $script:Offset $script:InvSrc '$Global:SmaResources = $null') -Because 'the released reading must follow the release itself'
        $At['released'] | Should -BeLessThan (& $script:Offset $script:InvSrc '        GetResourceConsumption')
        $At['end'] | Should -BeLessThan (& $script:Offset $script:InvSrc 'Write-RdaShareableDiagnosticsLog -DefaultPath') -Because 'the end reading must exist before the diagnostics log renders it'
        $At['end'] | Should -BeGreaterThan (& $script:Offset $script:InvSrc ("`nFinalizeOutputs`n")) -Because 'the end reading is taken after the HTML report'
    }

    It 'hands the readings to both diagnostics-log calls' {
        ([regex]::Matches($script:InvSrc, [regex]::Escape('Write-RdaShareableDiagnosticsLog -DefaultPath'))).Count | Should -Be 2
        ([regex]::Matches($script:InvSrc, [regex]::Escape('-MemoryReadings $Global:MemoryReadings -ConsumptionRecordCount'))).Count | Should -Be 2
    }
}

Describe 'The wrappers read the count, never the released array' {
    It '<Label> reads $Global:ResourceCount and not $Global:Resources' -ForEach @(
        @{ Label = 'Run-AllSubscriptions.ps1'; Src = { $script:WrapperSrc }; Reads = 2 }
        @{ Label = 'Run-AllSubscriptions.Stream.ps1'; Src = { $script:StreamSrc }; Reads = 1 }
    ) {
        $Text = & $Src
        $Text | Should -Not -Match '\$Global:Resources\b' -Because 'the array is null by the time the wrapper runs'
        ([regex]::Matches($Text, [regex]::Escape('if ($null -ne $Global:ResourceCount) { [int]$Global:ResourceCount } else { 0 }'))).Count | Should -Be $Reads
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
        $script:WrapperSrc | Should -Match ([regex]::Escape('-MemoryReadings $Global:MemoryReadings `'))
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
        $script:Small = New-TestSubscriptionReadings -Id 'second-subscription' -Stamp 's2' -Resources 412 -Heaps @(312, 320, 325, 314, 316) -WorkingSets @(612, 620, 625, 612, 614)
        $script:Both = @($script:Big) + @($script:Small)
    }

    It 'renders one row per subscription with every phase, then the three summary lines' {
        $Lines = @(Get-RdaMemoryReadingLines -Readings $script:Both)
        $Lines.Count | Should -Be 6
        $Lines[0] | Should -Be 'Memory (MB, managed heap after a full collection / process working set):'
        $Lines[1] | Should -Be '  [sub 12345678-1234-1234-1234-123456789012]  resources 20,000  start 310/520  discovery 525/780  collectors 640/905  released 320/610  end 335/615'
        $Lines[2] | Should -Be '  [sub second-subscription]  resources 412  start 312/612  discovery 320/620  collectors 325/625  released 314/612  end 316/614'
        $Lines[3] | Should -Be '  Highest working set sampled : 905 MB'
        $Lines[4] | Should -Be '  Memory available to runtime : 2560 MB'
        $Lines[5] | Should -Match '^  Per resource, largest sub   : raw rows ~11 KB, collector output ~6 KB, total ~17 KB \(20,000 \w+\)$'
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
        ($Lines -join "`n") | Should -Not -Match '\d,\d/'
    }
}

Describe 'The run summary and the diagnostics log carry the memory block' {
    BeforeAll {
        $script:Readings = New-TestSubscriptionReadings -Id '12345678-1234-1234-1234-123456789012' -Stamp 'run-1' -Resources 100 -Heaps @(300, 320, 340, 305, 306) -WorkingSets @(500, 520, 540, 505, 506)
        $script:Other = New-TestSubscriptionReadings -Id '12345678-1234-1234-1234-123456789012' -Stamp 'run-0' -Resources 9 -Heaps @(1, 2, 3, 4, 5) -WorkingSets @(1, 2, 3, 4, 5)
    }

    It 'Get-RunSummaryLogContent renders the block when readings exist and omits it otherwise' {
        $With = @(Get-RunSummaryLogContent -Version '0.0.0' -MemoryReadings $script:Readings) -join "`n"
        $With | Should -Match 'Memory \(MB, managed heap after a full collection / process working set\):'
        $With | Should -Match 'resources 100  start 300/500'
        $Without = @(Get-RunSummaryLogContent -Version '0.0.0') -join "`n"
        $Without | Should -Not -Match 'Memory \(MB'
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
            if ($Obfuscated) { $Text | Should -Not -Match '12345678-1234' } else { $Text | Should -Match 'sub 12345678-1234' }
        }
        finally
        {
            Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
