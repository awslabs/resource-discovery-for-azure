# Metrics Phase Diagnostics Tests
#
# Runs Extension/Metrics.ps1 end to end against a stand-in Get-AzMetric and
# checks the diagnostics it writes: the per-batch verbose lines and the
# end-of-phase summary in the debug log (counts by outcome, every non-success
# call, the five slowest calls). It also checks that each batch's per-call
# diagnostics records are dropped once that batch is done.
#
# The stand-in is a small module put first on PSModulePath, so the parallel
# workers and their thread jobs load it instead of Az.Monitor. No Azure call is
# made. Every result is derived from the inputs. The disk name selects one
# behaviour for the 'Composite Disk Read Operations/sec' call of that disk:
#   -throttled   429 error on every attempt (outcome Throttled)
#   -badmetric   invalid metric name error on every attempt (outcome Error)
#   -empty       no data points (outcome Success)
#   -slow<ms>    succeeds after the given delay
# Durations are measured by the script, so the seconds are masked when lines
# are compared and the slowest-first order is checked on the parsed values.
#
# Run with: Invoke-Pester ./Tests/MetricsDiagnostics.Tests.ps1 -Output Detailed

BeforeAll {
    $script:MetricsScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'Extension/Metrics.ps1'
    if (-not (Test-Path $script:MetricsScript))
    {
        throw "Could not find $script:MetricsScript"
    }

    $script:SubId = '12345678-1234-1234-1234-123456789012'
    $script:ReadOps = 'Composite Disk Read Operations/sec'
    $script:ThrottleMessage = "Operation returned an invalid status code 'TooManyRequests' (429)"
    $script:BadMetricMessage = 'Failed to find metric configuration for provider: Microsoft.Compute, resource Type: disks, metric: {0}' -f $script:ReadOps

    $StubModuleDir = Join-Path $TestDrive 'Modules/RdaMetricStub'
    New-Item -ItemType Directory -Path $StubModuleDir -Force | Out-Null
    @'
function Get-AzMetric
{
    param($ResourceId, $MetricName, $StartTime, $EndTime, $TimeGrain, $AggregationType, $DefaultProfile)

    $DiskName = ($ResourceId -split '/')[-1]
    if ($MetricName -eq '__READOPS__')
    {
        if ($DiskName -like '*-throttled') { throw "__THROTTLE__" }
        if ($DiskName -like '*-badmetric') { throw "__BADMETRIC__" }
        if ($DiskName -like '*-empty') { return [pscustomobject]@{ Id = $ResourceId; Name = $MetricName; Data = @() } }
        if ($DiskName -match '-slow(\d+)$') { Start-Sleep -Milliseconds ([int]$Matches[1]) }
    }

    $Seed = [int]($DiskName -replace '^disk-(\d+).*$', '$1')
    $Data = foreach ($Hour in 0..2)
    {
        $Value = ($Seed % 50) + $Hour + ($MetricName.Length / 10)
        [pscustomobject]@{ TimeStamp = ([datetime]$StartTime).AddHours($Hour); Average = $Value; Maximum = $Value; Minimum = $Value; Total = $Value; Count = 1 }
    }
    [pscustomobject]@{ Id = $ResourceId; Name = $MetricName; Data = @($Data) }
}
Export-ModuleMember -Function Get-AzMetric
'@.Replace('__READOPS__', $script:ReadOps).Replace('__THROTTLE__', $script:ThrottleMessage).Replace('__BADMETRIC__', $script:BadMetricMessage) |
        Set-Content -Path (Join-Path $StubModuleDir 'RdaMetricStub.psm1') -Encoding utf8

    $script:SavedModulePath = $env:PSModulePath
    $env:PSModulePath = (Join-Path $TestDrive 'Modules') + [IO.Path]::PathSeparator + $env:PSModulePath

    # The summary is written through Write-Log to the local debug log, which is
    # read back after each run.
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'Functions/Common.Functions.ps1')
    $script:SavedDebugLogFile = $Global:DebugLogFile
    # No Azure context: the script then passes no -DefaultProfile to Get-AzMetric.
    function Get-AzContext { $null }

    function New-TestDisk([int]$Number, [string]$Behaviour)
    {
        $Name = 'disk-{0:D4}{1}' -f $Number, $Behaviour
        [pscustomobject]@{
            TYPE           = 'microsoft.compute/disks'
            subscriptionId = $script:SubId
            ResourceGroup  = 'rg-placeholder'
            Name           = $Name
            Location       = 'eastus'
            Id             = '/subscriptions/{0}/resourceGroups/rg-placeholder/providers/Microsoft.Compute/disks/{1}' -f $script:SubId, $Name
            ManagedBy      = '/subscriptions/{0}/resourceGroups/rg-placeholder/providers/Microsoft.Compute/virtualMachines/vm-{1:D4}' -f $script:SubId, $Number
        }
    }

    # Dot-sources the script in a child scope so its collections can be read
    # while each batch finishes and once the phase has finished.
    function Invoke-MetricsPhase([object[]]$Resources, [string]$Tag)
    {
        $DebugLog = Join-Path $TestDrive ('Debug_' + $Tag + '.log')
        $Params = @{
            Subscriptions    = @([pscustomobject]@{ id = $script:SubId; Name = 'Placeholder Subscription' })
            Resources        = $Resources
            Task             = 'Processing'
            ConcurrencyLimit = 16
            FilePath         = Join-Path $TestDrive ('Metrics_' + $Tag)
            Obfuscate        = $false
        }
        $Global:DebugLogFile = $DebugLog
        try
        {
            $Run = & {
                param($ScriptPath, $ScriptParams)
                $ProgressPreference = 'SilentlyContinue'
                $VerbosePreference = 'Continue'
                # The script dispatches the next batch, and ends the phase, only
                # after folding the previous batch's call records into the summary,
                # so the number of records still held at those two points is what
                # each batch left behind. The first batch has no batch before it.
                $RetainedAfterBatch = [System.Collections.Generic.List[int]]::new()
                $ShowProgress = ${function:Write-RdaProgress}
                function Write-RdaProgress
                {
                    param([string]$Activity, [string]$CurrentItem, [int]$Index, [int]$Total, [switch]$BarOnly, [switch]$Completed)
                    if ($Completed -or $CurrentItem -notlike 'batch 1 *') { $RetainedAfterBatch.Add($MetricDiagnostics.Count) }
                    & $ShowProgress @PSBoundParameters
                }
                $Records = @(. $ScriptPath @ScriptParams 4>&1)
                [pscustomobject]@{
                    Output             = @($Records | Where-Object { $_ -isnot [System.Management.Automation.VerboseRecord] })
                    Verbose            = @($Records | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] } | ForEach-Object { $_.Message } | Where-Object { $_ -like '`[Metrics`]*' })
                    RetainedAfterBatch = @($RetainedAfterBatch)
                }
            } $script:MetricsScript $Params
        }
        finally
        {
            $Global:DebugLogFile = $script:SavedDebugLogFile
        }
        # Drop the timestamp Write-Log puts in front of each line.
        $Run | Add-Member -NotePropertyName Log -NotePropertyValue @(Get-Content -Path $DebugLog | ForEach-Object { $_ -replace '^\[[^\]]*\] ', '' })
        $Run
    }

    function Hide-Seconds([string]$Line)
    {
        $Line -replace '^(\[Metrics\]   )[\d.,]+s idx=', '$1<s>s idx=' -replace ' attempts=(\d+) [\d.,]+s ', ' attempts=$1 <s>s ' -replace 'Elapsed: [\d.,]+s$', 'Elapsed: <s>s' -replace 'complete in [\d.,]+s\.', 'complete in <s>s.'
    }

    function Get-Seconds([string]$Line)
    {
        if ($Line -match '^\[Metrics\]   ([\d.,]+)s idx=' -or $Line -match ' attempts=\d+ ([\d.,]+)s ')
        {
            return [double]::Parse($Matches[1], [cultureinfo]::CurrentCulture)
        }
        throw "No call duration in: $Line"
    }
}

AfterAll {
    if ($null -ne $script:SavedModulePath)
    {
        $env:PSModulePath = $script:SavedModulePath
    }
}

Describe 'Metrics phase diagnostics across several batches' {

    BeforeAll {
        # 200 attached disks x 4 metrics = 800 calls = batches of 250, 250, 250, 50.
        # A disk's read-operations call has MetricIndex 4 * disk + 1.
        # A failed call takes at least 7 s of retry backoff (14 s when throttled),
        # so the five slowest are the three failures and the 6 s and 7 s calls,
        # several seconds clear of the 1 s call and of every other call.
        $Special = @{
            10  = '-throttled'   # idx 41, batch 1: the only Throttled call
            20  = '-badmetric'   # idx 81, batch 1
            30  = '-slow1000'    # idx 121, batch 1: pushed out of the slowest five by later batches
            100 = '-empty'       # idx 401, batch 2
            150 = '-badmetric'   # idx 601, batch 3
            160 = '-slow7000'    # idx 641, batch 3
            195 = '-slow6000'    # idx 781, batch 4
        }
        $Disks = foreach ($n in 0..199) { New-TestDisk -Number $n -Behaviour ([string]$Special[$n]) }
        $script:Run = Invoke-MetricsPhase -Resources $Disks -Tag 'batches'

        $CallPrefix = 'idx={0} Managed Disk/{1}/' + $script:ReadOps + ' interval=1:00:00'
        $script:Throttled = $CallPrefix -f 41, 'disk-0010-throttled'
        $script:BadMetricA = $CallPrefix -f 81, 'disk-0020-badmetric'
        $script:BadMetricB = $CallPrefix -f 601, 'disk-0150-badmetric'
        $script:Slow7000 = $CallPrefix -f 641, 'disk-0160-slow7000'
        $script:Slow6000 = $CallPrefix -f 781, 'disk-0195-slow6000'
    }

    It 'writes every result to one file per batch' {
        $Files = @(Get-ChildItem -Path $TestDrive -Filter 'Metrics_batches_*.json')
        $Files.Count | Should -Be 4
        $Results = @($Files | ForEach-Object { (Get-Content -Raw -Path $_.FullName | ConvertFrom-Json).Metrics })
        $Results.Count | Should -Be 800
    }

    It 'returns nothing to the pipeline' {
        $script:Run.Output.Count | Should -Be 0
    }

    It 'writes the per-batch verbose lines, with the cumulative call count' {
        @($script:Run.Verbose | ForEach-Object { Hide-Seconds $_ }) | Should -Be @(
            '[Metrics] Batch 1: dispatching 250 metric call(s) (processed 250/800).'
            '[Metrics] Batch 1 complete in <s>s. Cumulative diagnostics: 250 call record(s) so far.'
            '[Metrics] Batch 2: dispatching 250 metric call(s) (processed 500/800).'
            '[Metrics] Batch 2 complete in <s>s. Cumulative diagnostics: 500 call record(s) so far.'
            '[Metrics] Batch 3: dispatching 250 metric call(s) (processed 750/800).'
            '[Metrics] Batch 3 complete in <s>s. Cumulative diagnostics: 750 call record(s) so far.'
            '[Metrics] Batch 4: dispatching 50 metric call(s) (processed 800/800).'
            '[Metrics] Batch 4 complete in <s>s. Cumulative diagnostics: 800 call record(s) so far.'
        )
    }

    It 'writes the summary sections in order' {
        $Log = $script:Run.Log
        $Log.Count | Should -Be 13
        $Log[0] | Should -Be '[Metrics] Starting metrics collection: 800 metric definition(s), ThrottleLimit=16, per-call timeout=120s, max retries=3, lookback=31 day(s).'
        $Log[1] | Should -Be '[Metrics] ===== Metrics phase summary ====='
        $Log[3] | Should -Be '[Metrics] Non-success calls (where it got stuck):'
        $Log[7] | Should -Be '[Metrics] Slowest 5 calls:'
    }

    It 'counts every call by outcome, including a status seen only in the first batch' {
        Hide-Seconds $script:Run.Log[2] | Should -Be '[Metrics] Total calls: 800 | Success: 797 | Timeout: 0 | Throttled: 1 | Error: 2 | Elapsed: <s>s'
    }

    It 'lists every non-success call from every batch, slowest first' {
        $Lines = $script:Run.Log[4..6]
        $Expected = @(
            ('[Metrics]   Throttled {0} attempts=4 <s>s Get-AzMetric failed after 4 attempt(s): {1}' -f $script:Throttled, $script:ThrottleMessage)
            ('[Metrics]   Error {0} attempts=4 <s>s Get-AzMetric failed after 4 attempt(s): {1}' -f $script:BadMetricA, $script:BadMetricMessage)
            ('[Metrics]   Error {0} attempts=4 <s>s Get-AzMetric failed after 4 attempt(s): {1}' -f $script:BadMetricB, $script:BadMetricMessage)
        )
        @($Lines | ForEach-Object { Hide-Seconds $_ } | Sort-Object) | Should -Be @($Expected | Sort-Object)
        $Seconds = @($Lines | ForEach-Object { Get-Seconds $_ })
        $Seconds | Should -Be @($Seconds | Sort-Object -Descending)
    }

    It 'lists the five slowest calls across all batches, slowest first' {
        $Lines = $script:Run.Log[8..12]
        $Expected = @(
            ('[Metrics]   <s>s {0} (Throttled)' -f $script:Throttled)
            ('[Metrics]   <s>s {0} (Error)' -f $script:BadMetricA)
            ('[Metrics]   <s>s {0} (Error)' -f $script:BadMetricB)
            ('[Metrics]   <s>s {0} (Success)' -f $script:Slow7000)
            ('[Metrics]   <s>s {0} (Success)' -f $script:Slow6000)
        )
        @($Lines | ForEach-Object { Hide-Seconds $_ } | Sort-Object) | Should -Be @($Expected | Sort-Object)
        $Seconds = @($Lines | ForEach-Object { Get-Seconds $_ })
        $Seconds | Should -Be @($Seconds | Sort-Object -Descending)
    }

    It 'gives each failed call the same duration in both lists' {
        foreach ($Prefix in @($script:Throttled, $script:BadMetricA, $script:BadMetricB))
        {
            $InNonSuccess = @($script:Run.Log[4..6] | Where-Object { $_.Contains(' ' + $Prefix + ' attempts=') })
            $InSlowest = @($script:Run.Log[8..12] | Where-Object { $_.Contains('s ' + $Prefix + ' (') })
            $InNonSuccess.Count | Should -Be 1
            $InSlowest.Count | Should -Be 1
            Get-Seconds $InSlowest[0] | Should -Be (Get-Seconds $InNonSuccess[0])
        }
    }

    It 'does not keep every call record until the end of the phase' {
        # One value per batch: the records still held when that batch is done.
        ($script:Run.RetainedAfterBatch -join ',') | Should -Be '0,0,0,0' -Because 'each batch''s call records are folded into the summary and dropped before the next batch starts'
    }
}

Describe 'Metrics phase diagnostics with no metric definitions' {

    It 'reports zero calls for every outcome' {
        $NoMetrics = [pscustomobject]@{ TYPE = 'microsoft.storage/storageaccounts'; subscriptionId = $script:SubId; Name = 'stplaceholder'; Id = 'placeholder' }
        $Run = Invoke-MetricsPhase -Resources @($NoMetrics) -Tag 'none'
        $Run.Output.Count | Should -Be 0
        $Run.Verbose.Count | Should -Be 0
        @($Run.Log | ForEach-Object { Hide-Seconds $_ }) | Should -Be @(
            '[Metrics] Starting metrics collection: 0 metric definition(s), ThrottleLimit=16, per-call timeout=120s, max retries=3, lookback=31 day(s).'
            '[Metrics] ===== Metrics phase summary ====='
            '[Metrics] Total calls: 0 | Success: 0 | Timeout: 0 | Throttled: 0 | Error: 0 | Elapsed: <s>s'
        )
    }
}
