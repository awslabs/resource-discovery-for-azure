#Requires -Version 7.0

function Invoke-RdaSupportLogCollection
{
    param(
        [string]$InventoryRoot,
        [datetime]$SinceTime,
        [string]$ContainerUri,
        [int]$ShardIndex = 0,
        [int]$ShardCount = 1
    )
    if (-not (Get-Command New-RdaSupportLogBundle -ErrorAction SilentlyContinue)) { return }
    try
    {
        $CollectParams = @{}
        if (-not [string]::IsNullOrWhiteSpace($InventoryRoot)) { $CollectParams['InventoryRoot'] = $InventoryRoot }
        if ($SinceTime -ne [datetime]::MinValue) { $CollectParams['SinceTime'] = $SinceTime }
        $SupportBundle = New-RdaSupportLogBundle @CollectParams
        if ($SupportBundle)
        {
            Write-Host ("Support logs collected: {0}" -f $SupportBundle) -ForegroundColor Cyan
            Write-Host "  Send this file to support over a secure/private channel (it contains real identifiers)." -ForegroundColor Cyan

            if (-not [string]::IsNullOrWhiteSpace($ContainerUri))
            {
                try
                {
                    $LogParts = Split-BlobContainerUri -Uri $ContainerUri
                    $LogAccount = $LogParts.Account
                    $LogContainer = $LogParts.Container
                    $LogPrefix = $LogParts.Prefix
                    $LogShardTag = if ($ShardCount -gt 1) { 'shard-{0}of{1}-' -f $ShardIndex, $ShardCount } else { '' }
                    $LogBlobName = '{0}{1}{2}' -f $LogPrefix, $LogShardTag, (Split-Path -Path $SupportBundle -Leaf)
                    Write-Host ("Uploading support logs to blob: {0} / {1} / {2}" -f $LogAccount, $LogContainer, $LogBlobName) -ForegroundColor Cyan
                    $LogCtx = New-AzStorageContext -StorageAccountName $LogAccount -UseConnectedAccount -ErrorAction Stop
                    $null = Set-AzStorageBlobContent -File $SupportBundle -Container $LogContainer -Blob $LogBlobName -Context $LogCtx -Force -ErrorAction Stop
                    Write-Host ("Support-log upload complete: {0}" -f $LogBlobName) -ForegroundColor Green
                }
                catch
                {
                    Write-Host ("WARNING: Support-log upload to blob failed ({0}). The bundle remains on local disk at: {1}" -f $_.Exception.Message, $SupportBundle) -ForegroundColor Yellow
                }
            }
        }
    }
    catch { Write-Verbose ("Support-log collection failed: {0}" -f $_.Exception.Message) }
}

function Write-RdaHostLinesInTranscript
{
    # Writes Text/Color records to the console with the wrapper transcript reopened (-Append), for
    # lines printed after the transcript was stopped, so they reach the transcript as well. The
    # transcript is closed again afterwards. Without a kept transcript the lines only reach the
    # console. A $null Color writes the line in the default colour.
    param(
        [object[]]$Lines,
        [switch]$TranscriptStarted,
        [string]$TranscriptFile
    )

    $Reopened = $false
    if ($TranscriptStarted -and -not [string]::IsNullOrWhiteSpace($TranscriptFile))
    {
        try
        {
            Start-Transcript -LiteralPath $TranscriptFile -Append -UseMinimalHeader | Out-Null
            $Reopened = $true
        }
        catch { Write-Verbose ("Reopening the wrapper transcript failed: {0}" -f $_.Exception.Message) }
    }

    foreach ($Line in @($Lines))
    {
        if ($null -ne $Line.Color) { Write-Host $Line.Text -ForegroundColor $Line.Color }
        else { Write-Host $Line.Text }
    }

    if ($Reopened)
    {
        try { Stop-Transcript | Out-Null }
        catch { Write-Verbose ("Stop-Transcript after writing to the reopened transcript failed: {0}" -f $_.Exception.Message) }
    }
}

function Invoke-RdaSupportLogCollectionInTranscript
{
    # Runs the support-log step after the wrapper transcript has been stopped, so the bundle copies a
    # finished, closed transcript (one that is still open can fail to copy on Windows). The step's
    # console lines are held while it runs and written afterwards with the transcript reopened
    # (-Append), so they reach the transcript as well as the console. -Outcome, when given, receives
    # Listed = $true when the step listed a support bundle on the console, so the final block can
    # say what that bundle is for.
    param(
        [switch]$TranscriptStarted,
        [string]$TranscriptFile,
        [string]$InventoryRoot,
        $SinceTime,
        [string]$ContainerUri,
        [int]$ShardIndex = 0,
        [int]$ShardCount = 1,
        [hashtable]$Outcome = $null
    )

    $Held = @(Invoke-RdaSupportLogCollection -InventoryRoot $InventoryRoot -SinceTime $SinceTime -ContainerUri $ContainerUri -ShardIndex $ShardIndex -ShardCount $ShardCount 6>&1)
    if ($null -ne $Outcome) { $Outcome['Listed'] = ($Held.Count -gt 0) }
    if ($Held.Count -eq 0)
    {
        return
    }

    $HeldLines = foreach ($Record in $Held)
    {
        $Message = if ($Record -is [System.Management.Automation.InformationRecord]) { $Record.MessageData } else { $Record }
        if ($Message -is [System.Management.Automation.HostInformationMessage])
        {
            # A Write-Host call without -ForegroundColor records the colour as -1.
            $Color = if ([int]$Message.ForegroundColor -ge 0) { $Message.ForegroundColor } else { $null }
            [pscustomobject]@{ Text = $Message.Message; Color = $Color }
        }
        else
        {
            [pscustomobject]@{ Text = [string]$Message; Color = $null }
        }
    }

    Write-RdaHostLinesInTranscript -Lines $HeldLines -TranscriptStarted:$TranscriptStarted -TranscriptFile $TranscriptFile
}

function Exit-Wrapper
{
    param([int]$Code = 0)
    # The metric worker pool is shared by every subscription of the run; release it before leaving,
    # so a run started from an interactive session does not leave it in that session.
    if (Get-Command -Name 'Close-RdaMetricWorkerPool' -CommandType Function -ErrorAction SilentlyContinue)
    {
        Write-Verbose ("Metric worker pool at wrapper exit: {0}" -f (Close-RdaMetricWorkerPool))
    }
    if ($WrapperTranscriptStarted)
    {
        try { Stop-Transcript | Out-Null }
        catch { Write-Verbose ("Stop-Transcript on Exit-Wrapper failed: {0}" -f $_.Exception.Message) }
    }

    if ($Code -ne 0 -or -not [string]::IsNullOrWhiteSpace($UploadToBlobContainerUri))
    {
        Invoke-RdaSupportLogCollectionInTranscript -TranscriptStarted:([bool]$WrapperTranscriptStarted) -TranscriptFile $WrapperTranscriptFile -InventoryRoot $InventoryRoot -SinceTime $RunStartTime -ContainerUri $UploadToBlobContainerUri -ShardIndex $ShardIndex -ShardCount $ShardCount
    }

    exit $Code
}

function Test-RdaFinalScreenClearable
{
    # Clearing the screen before the final block is safe only when a person is watching a real
    # terminal (input and output both attached), there is a report bundle to point at, and the
    # transcript on disk still holds everything the clear removes from view.
    param(
        [bool]$BundleBuilt,
        [bool]$TranscriptKept,
        [bool]$IsConsole = ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected)
    )

    return ($IsConsole -and $BundleBuilt -and $TranscriptKept)
}

function Get-RdaFinalScreenLines
{
    # The last block a run prints: a one-line outcome with the exit code, where to find the details
    # when anything went wrong, and the one file to send. Instructions are in capitals; paths and the
    # folder name keep their real case, because Linux and macOS paths are case-sensitive. Returns
    # Text/Color records for the caller to write. -SupportBundleListed says the support-log step's
    # "send this file to support" lines are still visible above this block (the screen was not
    # cleared), so the block says what that bundle is for instead of contradicting it.
    param(
        [int]$ExitCode,
        [bool]$HasWarnings,
        [string]$TranscriptFile,
        [bool]$TranscriptKept,
        [string]$BundleFile,
        [string]$InventoryFolderName,
        [int]$ShardIndex = 0,
        [int]$ShardCount = 1,
        [bool]$SupportBundleListed = $false
    )

    $Lines = [System.Collections.Generic.List[object]]::new()

    if ($ExitCode -ne 0)
    {
        $Lines.Add([pscustomobject]@{ Text = ('RUN FINISHED WITH FAILURES - EXIT CODE {0}.' -f $ExitCode); Color = 'Red' })
    }
    elseif ($HasWarnings)
    {
        $Lines.Add([pscustomobject]@{ Text = ('RUN COMPLETE WITH WARNINGS - EXIT CODE {0}.' -f $ExitCode); Color = 'Yellow' })
    }
    else
    {
        $Lines.Add([pscustomobject]@{ Text = ('RUN COMPLETE - EXIT CODE {0}.' -f $ExitCode); Color = 'Green' })
    }

    if ($ExitCode -ne 0 -or $HasWarnings)
    {
        if ($TranscriptKept)
        {
            $Lines.Add([pscustomobject]@{ Text = ('THE DETAILS ARE IN THE TRANSCRIPT: {0}' -f $TranscriptFile); Color = 'Yellow' })
        }
        else
        {
            $Lines.Add([pscustomobject]@{ Text = 'SCROLL UP FOR THE DETAILS.'; Color = 'Yellow' })
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($BundleFile))
    {
        $Lines.Add([pscustomobject]@{ Text = ('SEND THIS ONE FILE:  {0}' -f $BundleFile); Color = 'Green' })
        if ($ShardCount -gt 1)
        {
            $Lines.Add([pscustomobject]@{ Text = ('  THIS IS SHARD {0} OF {1} AND COVERS ONLY THIS NODE''S SUBSCRIPTIONS. SEND ONE SUCH FILE FROM EVERY SHARD.' -f $ShardIndex, $ShardCount); Color = 'Yellow' })
        }
        $Lines.Add([pscustomobject]@{ Text = ('  DO NOT ZIP OR SEND THE {0} FOLDER ITSELF. IT HOLDS FILES THAT MUST STAY LOCAL.' -f $InventoryFolderName); Color = 'Yellow' })
        if ($SupportBundleListed)
        {
            $Lines.Add([pscustomobject]@{ Text = '  THE SUPPORT LOG BUNDLE LISTED ABOVE IS ONLY FOR SUPPORT. SEND IT ONLY IF SUPPORT ASKS FOR IT.'; Color = 'Yellow' })
        }
    }
    elseif ($SupportBundleListed)
    {
        $Lines.Add([pscustomobject]@{ Text = 'NO REPORT BUNDLE WAS PRODUCED. SEND THE SUPPORT LOG BUNDLE LISTED ABOVE TO SUPPORT INSTEAD.'; Color = 'Red' })
    }
    else
    {
        $Lines.Add([pscustomobject]@{ Text = 'NO REPORT BUNDLE WAS PRODUCED, SO THERE IS NO FILE TO SEND.'; Color = 'Red' })
    }

    return $Lines.ToArray()
}

function Get-RecommendedParallelism
{
    param(
        [double]$StreamMemoryGB = 2,
        [int]$SubscriptionCount = 0
    )
    $VCpu = [int][Environment]::ProcessorCount
    if ($VCpu -lt 1) { $VCpu = 1 }

    $RamGB = 0.0
    try
    {
        if ($IsWindows)
        {
            $Bytes = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory
            if ($Bytes) { $RamGB = [math]::Round([double]$Bytes / 1GB, 1) }
        }
        elseif ($IsLinux)
        {
            $MemLine = Select-String -LiteralPath '/proc/meminfo' -Pattern '^MemTotal:\s+(\d+)\s+kB' -ErrorAction Stop | Select-Object -First 1
            if ($MemLine) { $RamGB = [math]::Round([double]$MemLine.Matches[0].Groups[1].Value / 1MB, 1) }
        }
        elseif ($IsMacOS)
        {
            $Bytes = [double](& sysctl -n hw.memsize 2>$null)
            if ($Bytes) { $RamGB = [math]::Round($Bytes / 1GB, 1) }
        }
    }
    catch
    {
        $RamGB = 0.0
    }

    $AvailableGB = Get-AvailableMemoryGB

    Get-ParallelismForHost -VCpu $VCpu -RamGB $RamGB -AvailableGB $AvailableGB -StreamMemoryGB $StreamMemoryGB -SubscriptionCount $SubscriptionCount
}

# Memory the OS reports as available to new work right now, in GB, or 0 when it cannot be read.
# A container memory limit (Cloud Shell, Kubernetes) caps it, because the host's free memory is
# not available to a process inside a smaller container.
function Get-AvailableMemoryGB
{
    $Bytes = 0.0
    try
    {
        if ($IsWindows)
        {
            # FreePhysicalMemory is in KB and counts memory available for reuse, as Task Manager's 'Available' does.
            $Kb = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).FreePhysicalMemory
            if ($Kb) { $Bytes = [double]$Kb * 1KB }
        }
        elseif ($IsLinux)
        {
            $MemLine = Select-String -LiteralPath '/proc/meminfo' -Pattern '^MemAvailable:\s+(\d+)\s+kB' -ErrorAction Stop | Select-Object -First 1
            if ($MemLine) { $Bytes = [double]$MemLine.Matches[0].Groups[1].Value * 1KB }
        }
        elseif ($IsMacOS)
        {
            # kern.memorystatus_level is the percentage of memory the kernel's memory-pressure system
            # counts as available. Same sysctl shell-out as the hw.memsize read above: plain
            # arguments, no shell metacharacters, and no .NET API exposes this on macOS.
            $Level = [double](& sysctl -n kern.memorystatus_level 2>$null)
            $Total = [double](& sysctl -n hw.memsize 2>$null)
            if ($Level -gt 0 -and $Total -gt 0) { $Bytes = $Total * $Level / 100.0 }
        }
    }
    catch
    {
        $Bytes = 0.0
    }

    $Limit = [double][System.GC]::GetGCMemoryInfo().TotalAvailableMemoryBytes
    if ($Bytes -gt 0 -and $Limit -gt 0 -and $Limit -lt $Bytes) { $Bytes = $Limit }

    return [math]::Round($Bytes / 1GB, 1)
}

# The sizing rules, kept free of host reads so they can be tested with any machine shape.
# Streams: half the vCPUs (1-6), capped by memory - available memory less 1 GB for the wrapper and
# the OS, divided by the memory one stream may use - and by the number of subscriptions.
# Concurrency: each stream gets 2 metric calls in flight per vCPU (6-16), as a single stream always
# has. A metric call is latency-bound (about 0.2 s of CPU for several seconds of wall time) and Azure
# Monitor throttles per subscription, so streams on different subscriptions do not compete for CPU or
# for one throttle; the per-stream figure is cut back only when streams x calls would pass
# $TotalConcurrencyCap across the host (48, the docs' "under about 50 per tenant" guidance).
function Get-ParallelismForHost
{
    param(
        [int]$VCpu = 1,
        [double]$RamGB = 0,
        [double]$AvailableGB = 0,
        [double]$StreamMemoryGB = 2,
        [int]$SubscriptionCount = 0,
        [int]$TotalConcurrencyCap = 48
    )
    if ($VCpu -lt 1) { $VCpu = 1 }
    if ($StreamMemoryGB -le 0) { $StreamMemoryGB = 2 }

    $Streams = [int][math]::Floor($VCpu / 2)
    if ($Streams -lt 1) { $Streams = 1 }
    if ($Streams -gt 6) { $Streams = 6 }
    $LimitedBy = 'vCPU'

    $MemoryBasis = 'none'
    $StreamsByMemory = 0
    if ($AvailableGB -gt 0)
    {
        $MemoryBasis = 'available'
        $StreamsByMemory = [int][math]::Min([math]::Floor(($AvailableGB - 1) / $StreamMemoryGB), 1000000.0)
    }
    elseif ($RamGB -gt 0)
    {
        $MemoryBasis = 'total'
        $StreamsByMemory = [int][math]::Min([math]::Floor(($RamGB - 2) / $StreamMemoryGB), 1000000.0)
    }
    if ($MemoryBasis -ne 'none')
    {
        if ($StreamsByMemory -lt 1) { $StreamsByMemory = 1 }
        if ($StreamsByMemory -lt $Streams)
        {
            $Streams = $StreamsByMemory
            $LimitedBy = 'memory'
        }
    }

    if ($SubscriptionCount -gt 0 -and $Streams -gt $SubscriptionCount)
    {
        $Streams = $SubscriptionCount
        $LimitedBy = 'subscriptions'
    }

    $PerStreamConcurrency = $VCpu * 2
    if ($PerStreamConcurrency -lt 6) { $PerStreamConcurrency = 6 }
    if ($PerStreamConcurrency -gt 16) { $PerStreamConcurrency = 16 }

    [pscustomobject]@{
        VCpu                 = $VCpu
        RamGB                = $RamGB
        AvailableGB          = $AvailableGB
        StreamMemoryGB       = $StreamMemoryGB
        MemoryBasis          = $MemoryBasis
        StreamsByMemory      = [int]$StreamsByMemory
        Streams              = [int]$Streams
        StreamsLimitedBy     = $LimitedBy
        PerStreamConcurrency = [int]$PerStreamConcurrency
        TotalConcurrencyCap  = [int]$TotalConcurrencyCap
        Concurrency          = [int](Get-PerStreamConcurrency -PerStreamConcurrency $PerStreamConcurrency -Streams $Streams -TotalCap $TotalConcurrencyCap)
    }
}

# A stream's metric calls in flight: the per-stream figure, cut to an equal share of the host-wide cap
# only when the streams together would pass it, and never below 2 so a stream still overlaps its
# network round-trips.
function Get-PerStreamConcurrency
{
    param(
        [int]$PerStreamConcurrency = 6,
        [int]$Streams = 1,
        [int]$TotalCap = 48
    )
    if ($Streams -lt 1) { $Streams = 1 }
    if ($PerStreamConcurrency -lt 1) { $PerStreamConcurrency = 1 }
    if ($TotalCap -lt 1) { $TotalCap = 1 }
    $Share = [int][math]::Floor($TotalCap / $Streams)
    if ($Share -lt 2) { $Share = 2 }
    return [int][math]::Min($PerStreamConcurrency, $Share)
}

# Splits the subscriptions between the streams so each stream gets a similar amount of work, instead
# of dealing them out round-robin by list position. A subscription's cost is estimated the way -Plan
# estimates it: a fixed 90 s plus 9.5 s per metric query with a 1.3 safety factor, from the
# per-subscription metric-query weights Get-PlanSubscriptionWeights reads from Resource Graph. A
# subscription without a weight costs the fixed part only. Largest first, each to the stream with the
# least work so far; ties go to the earlier subscription and the lower stream, so the split is
# deterministic. Each stream keeps its subscriptions in their original order.
function Get-WeightedStreamSlices
{
    param(
        [Parameter(Mandatory = $true)][object[]]$Subscriptions,
        [Parameter(Mandatory = $true)][int]$StreamCount,
        [Parameter(Mandatory = $true)][hashtable]$Weights,
        [double]$BaseSeconds = 90.0,
        [double]$SecondsPerQuery = 12.35
    )
    if ($StreamCount -lt 1) { $StreamCount = 1 }

    $Items = for ($i = 0; $i -lt $Subscriptions.Count; $i++)
    {
        $Key = [string]$Subscriptions[$i].Id
        $Queries = if ($Weights.ContainsKey($Key)) { [double]$Weights[$Key].Total } else { 0.0 }
        [pscustomobject]@{ Index = $i; Cost = $BaseSeconds + ($SecondsPerQuery * $Queries) }
    }

    $Loads = [double[]]::new($StreamCount)
    $Assigned = @(for ($Stream = 0; $Stream -lt $StreamCount; $Stream++) { , [System.Collections.Generic.List[int]]::new() })
    $Ordered = @($Items | Sort-Object -Property @{ Expression = 'Cost'; Descending = $true }, @{ Expression = 'Index'; Descending = $false })
    foreach ($Item in $Ordered)
    {
        $Target = 0
        for ($Stream = 1; $Stream -lt $StreamCount; $Stream++)
        {
            if ($Loads[$Stream] -lt $Loads[$Target]) { $Target = $Stream }
        }
        $Assigned[$Target].Add($Item.Index)
        $Loads[$Target] += $Item.Cost
    }

    $Slices = @()
    for ($Stream = 0; $Stream -lt $StreamCount; $Stream++)
    {
        $Slice = New-Object 'System.Collections.Generic.List[object]'
        foreach ($Index in ($Assigned[$Stream] | Sort-Object)) { $Slice.Add($Subscriptions[$Index]) }
        $Slices += , $Slice
    }

    [pscustomobject]@{
        Slices       = $Slices
        Loads        = $Loads
        TotalSeconds = [double]($Loads | Measure-Object -Sum).Sum
    }
}

function Get-HeadroomAdjustedConcurrency
{
    param(
        [Parameter(Mandatory = $true)][int]$Concurrency,
        [Parameter(Mandatory = $true)][int]$HeadRoomPercent
    )

    if ($HeadRoomPercent -lt 0) { $HeadRoomPercent = 0 }
    if ($HeadRoomPercent -gt 90) { $HeadRoomPercent = 90 }
    if ($Concurrency -lt 1) { $Concurrency = 1 }

    $Adjusted = [int][math]::Floor($Concurrency * (100 - $HeadRoomPercent) / 100.0)
    if ($Adjusted -lt 1) { $Adjusted = 1 }
    return $Adjusted
}

function Test-BackgroundJobSupport
{
    if (-not $IsWindows) { return $true }

    $Probe = $null
    try
    {
        $Probe = Start-Job -ScriptBlock { $true } -ErrorAction Stop
        return $true
    }
    catch
    {
        return $false
    }
    finally
    {
        if ($Probe)
        {
            try { Remove-Job -Job $Probe -Force -ErrorAction SilentlyContinue } catch { Write-Verbose ("Probe job cleanup failed: {0}" -f $_.Exception.Message) }
        }
    }
}

function Test-ThreadJobSupport
{
    # -StreamIsolation Runspace runs each stream as a thread job (Start-ThreadJob, from the ThreadJob module
    # PowerShell 7 ships with) in this process. Probed by starting one, on every platform, because a
    # session can lack the module or refuse to start one.
    if (-not (Get-Command -Name Start-ThreadJob -ErrorAction SilentlyContinue)) { return $false }

    $Probe = $null
    try
    {
        $Probe = Start-ThreadJob -ScriptBlock { $true } -ErrorAction Stop
        return [bool](Receive-Job -Job $Probe -Wait -ErrorAction Stop)
    }
    catch
    {
        return $false
    }
    finally
    {
        if ($Probe)
        {
            try { Remove-Job -Job $Probe -Force -ErrorAction SilentlyContinue } catch { Write-Verbose ("Probe thread job cleanup failed: {0}" -f $_.Exception.Message) }
        }
    }
}

function Get-GcFreeMemoryGB
{
    # Free memory in GB as the .NET garbage collector sees it, refreshed by [GC]::Collect(0). That collects at
    # least generation 0, and the runtime can choose a higher generation; it usually takes a millisecond or two.
    # The memory in use (MemoryLoadBytes) is measured against the machine's memory, or a container's limit, whose
    # size is recovered from the high-load threshold: HighMemoryLoadThresholdBytes is GCHighMemPercent percent of it.
    # TotalAvailableMemoryBytes is that same size only while the heap has no hard limit. Under one, such as the
    # default inside a memory-limited container (75% of the container's memory), it is the heap limit itself, so
    # the figure is the smaller of the memory not in use and the heap's own room under its limit. Without the
    # configuration variables (before .NET 7) it is TotalAvailableMemoryBytes less the memory in use.
    # -Full first runs an aggressive full collection, which also hands the memory it frees back to the OS, so
    # memory this process holds only as garbage counts as free: on Windows a default full collection keeps that
    # memory committed and the figure does not move. Runtimes before .NET 7 have no aggressive mode and get a
    # default one. The memory in use is kept in whole percent of the total, so the figure moves in steps of 1%.
    # No OS command is run; Step 5 of docs/experiments/one-process-streams.md compares the figure with the OS's own.
    param([switch]$Full)
    if ($Full)
    {
        $Mode = $null
        if ([System.Enum]::TryParse([System.GCCollectionMode], 'Aggressive', [ref]$Mode))
        {
            [System.GC]::Collect([System.GC]::MaxGeneration, $Mode, $true, $true)
        }
        else
        {
            [System.GC]::Collect()
        }
    }
    [System.GC]::Collect(0)
    $Info = [System.GC]::GetGCMemoryInfo()
    $FreeBytes = [double]$Info.TotalAvailableMemoryBytes - [double]$Info.MemoryLoadBytes
    $HighPercent = 0.0
    if ([System.GC].GetMethod('GetConfigurationVariables'))
    {
        $Variables = [System.GC]::GetConfigurationVariables()
        if ($Variables.ContainsKey('GCHighMemPercent')) { $HighPercent = [double]$Variables['GCHighMemPercent'] }
    }
    if ($HighPercent -gt 0 -and $Info.HighMemoryLoadThresholdBytes -gt 0)
    {
        $TotalBytes = [double]$Info.HighMemoryLoadThresholdBytes * 100 / $HighPercent
        $FreeBytes = [math]::Min($TotalBytes - [double]$Info.MemoryLoadBytes, [double]$Info.TotalAvailableMemoryBytes - [double]$Info.TotalCommittedBytes)
    }
    return $FreeBytes / 1GB
}

function New-StreamAdmissionState
{
    # The one admission state of a -StreamIsolation Runspace run, passed by reference to every stream: the
    # free-memory floor in GB (-StreamMemoryGB; 0 turns the check off), how often the stream at the head of the
    # queue reads free memory, how long a stream waits before it may be let in anyway, the tokens of the
    # subscriptions admitted and not yet released (Holders: their count is the number in progress), the tokens of
    # the waiting subscriptions in arrival order (Waiting), when a waiter was last let in anyway, when the last
    # full collection ran, and the last free-memory reading. It is read and changed only under its lock, by
    # Enter-StreamAdmission and Exit-StreamAdmission. The lock is the table's own SyncRoot, read here once, on one
    # thread, and kept under the key Lock, which the streams read with the indexer: read by two runspaces at the
    # same moment, $State.PSBase.SyncRoot came back $null in 36 of 80 reads, where the key never did.
    param(
        [double]$FloorGB = 2,
        [double]$PollSeconds = 15,
        [double]$MaxWaitSeconds = 1800
    )
    $Table = [hashtable]::Synchronized(@{
            FloorGB            = $FloorGB
            PollSeconds        = $PollSeconds
            MaxWaitSeconds     = $MaxWaitSeconds
            Holders            = [System.Collections.Generic.HashSet[string]]::new()
            Waiting            = [System.Collections.Generic.List[string]]::new()
            LastOverride       = $null
            LastFullCollection = $null
            LastFreeGB         = $null
        })
    $Table['Lock'] = $Table.PSBase.SyncRoot
    return $Table
}

function Enter-StreamAdmission
{
    # Blocks until this stream may start a subscription, then records -Holder, the token the stream made for the
    # subscription, as admitted. Exit-StreamAdmission removes it again, and the stream calls it whenever the
    # subscription ends, however it ends, so the subscriptions in progress are exactly the tokens recorded.
    # The streams of a -StreamIsolation Runspace run share one process, so one out-of-memory error ends them all.
    # Waiting streams queue in arrival order, and only the one at the head may be admitted: when no other
    # subscription is in progress (so one always runs and the streams never wait on each other forever), when free
    # memory is at least the floor, or once it has waited MaxWaitSeconds, which lets in at most one stream per
    # MaxWaitSeconds, with a warning. Only the head reads free memory, at most every PollSeconds. The first time
    # its reading is below the floor it runs one aggressive full collection (Get-GcFreeMemoryGB -Full), to give
    # back garbage any stream left in the shared heap, unless another stream ran one within PollSeconds.
    # Waiters sleep in Monitor.Wait slices of at most a second, so a stop lands quickly, and an admission or a
    # release wakes them at once. Everything is decided and recorded under the state's lock; free memory is read, and
    # the waiting line is written, without it, so a slow reading or host write holds up no stream that is releasing.
    # The check sees the memory that is free when a subscription starts, not what the subscription will need.
    # -FreeMemoryReader is called with $true for the full reading. Neither it nor -Log may use break or continue:
    # in PowerShell, loop control in a script block reaches the loops of the function that runs it. A thread that
    # already holds the state's lock is refused, because the lock is let go while free memory is read and the waiting
    # line is written.
    # Returns the reason the subscription was admitted, how long it waited, and the free memory this call read, if
    # it read any.
    param(
        [Parameter(Mandatory = $true)][hashtable]$State,
        [Parameter(Mandatory = $true)][string]$Holder,
        [string]$Subscription = '',
        [scriptblock]$FreeMemoryReader = { param([bool]$Full) Get-GcFreeMemoryGB -Full:$Full },
        [scriptblock]$Log = { param([string]$Message, [string]$Color) Write-Stream $Message $Color }
    )
    $Lock = $State['Lock']
    if ($null -eq $Lock) { throw [System.InvalidOperationException]::new('The admission state has no lock: create it with New-StreamAdmissionState.') }
    if ([System.Threading.Monitor]::IsEntered($Lock)) { throw [System.InvalidOperationException]::new('Enter-StreamAdmission must not be called while holding the admission lock.') }
    $Culture = [cultureinfo]::InvariantCulture
    $FloorGB = [double]$State['FloorGB']
    $PollSeconds = [double]$State['PollSeconds']
    $MaxWaitSeconds = [double]$State['MaxWaitSeconds']
    $SliceMs = [int][math]::Max(10, [math]::Min(1000, $PollSeconds * 1000))
    $Frequency = [double][System.Diagnostics.Stopwatch]::Frequency
    $Holders = $State['Holders']
    $Waiting = $State['Waiting']
    $Watch = [System.Diagnostics.Stopwatch]::StartNew()
    $Admission = $null
    $Logged = $false
    $LastRead = $null
    $Collected = $false
    $ShownGB = $null
    $InProgress = 0
    $ReadError = $null
    try
    {
        [System.Threading.Monitor]::Enter($Lock)
        $Waiting.Add($Holder)
        while ($null -eq $Admission)
        {
            $Reason = $null
            $FreeGB = $null
            $InProgress = $Holders.Count
            if ($FloorGB -le 0)
            {
                $Reason = 'disabled'
            }
            elseif ($Waiting.Count -gt 0 -and $Waiting[0] -eq $Holder)
            {
                $Now = [System.Diagnostics.Stopwatch]::GetTimestamp()
                if ($InProgress -eq 0)
                {
                    $Reason = 'alone'
                }
                elseif ($null -eq $LastRead -or ($Now - $LastRead) / $Frequency -ge $PollSeconds)
                {
                    $LastRead = $Now
                    $LastFull = $State['LastFullCollection']
                    $FullRan = $false
                    # The reading is done with the lock let go, so neither its own work nor a slow custom reader
                    # holds up a stream that is releasing. A blocking full collection pauses every thread while
                    # it runs, lock or no lock, so the gain is the rest of the reading, not the collection itself.
                    # Nothing else is admitted while the lock is let go, because only the head of the queue may
                    # be admitted and only its own thread removes its token. The finally block takes the lock
                    # back on every path, including a stop.
                    [System.Threading.Monitor]::Exit($Lock)
                    try
                    {
                        $FreeGB = [double](& $FreeMemoryReader $false)
                        if ($FreeGB -lt $FloorGB -and -not $Collected)
                        {
                            $Collected = $true
                            if ($null -eq $LastFull -or ($Now - $LastFull) / $Frequency -ge $PollSeconds)
                            {
                                $FreeGB = [double](& $FreeMemoryReader $true)
                                $FullRan = $true
                            }
                        }
                        if ($FreeGB -ge $FloorGB)
                        {
                            $Reason = 'memory'
                        }
                    }
                    catch
                    {
                        $ReadError = $_.Exception.Message
                        $Reason = 'unreadable'
                    }
                    finally
                    {
                        [System.Threading.Monitor]::Enter($Lock)
                    }
                    if ($FullRan)
                    {
                        $State['LastFullCollection'] = [System.Diagnostics.Stopwatch]::GetTimestamp()
                    }
                    if ($Reason -ne 'unreadable')
                    {
                        $State['LastFreeGB'] = $FreeGB
                    }
                    if (-not $Reason -and $Holders.Count -lt $InProgress)
                    {
                        # A subscription finished while the lock was let go for the reading, and its wake-up found no
                        # one asleep. Look again now, before the longest-wait decision below works from a count that
                        # is out of date, and rather than after the next slice.
                        continue
                    }
                }
                if (-not $Reason -and $Watch.Elapsed.TotalSeconds -ge $MaxWaitSeconds)
                {
                    $LastOverride = $State['LastOverride']
                    if ($null -eq $LastOverride -or ($Now - $LastOverride) / $Frequency -ge $MaxWaitSeconds)
                    {
                        $State['LastOverride'] = $Now
                        $Reason = 'max-wait'
                    }
                }
            }
            $ShownGB = if ($null -ne $FreeGB) { $FreeGB } else { $State['LastFreeGB'] }
            if ($Reason)
            {
                [void]$Waiting.Remove($Holder)
                [void]$Holders.Add($Holder)
                [System.Threading.Monitor]::PulseAll($Lock)
                $Admission = [pscustomobject]@{
                    Reason        = $Reason
                    WaitedSeconds = $Watch.Elapsed.TotalSeconds
                    FreeGB        = $FreeGB
                }
            }
            else
            {
                if (-not $Logged)
                {
                    $Logged = $true
                    $FreeText = if ($null -ne $ShownGB) { [string]::Format($Culture, '{0:0.0} GB free', $ShownGB) } else { 'free memory not read yet' }
                    $WaitingLine = [string]::Format($Culture, 'waiting for free memory before starting {0}: {1}, floor {2} GB (-StreamMemoryGB), {3} other subscription(s) in progress, {4} stream(s) ahead of it', $Subscription, $FreeText, $FloorGB, $InProgress, $Waiting.IndexOf($Holder))
                    # The line is made from what was read under the lock and written without it, so a slow host write
                    # holds up no other stream. A release while the lock is free cannot wake this stream, which is not
                    # asleep yet, so look again before the first sleep.
                    [System.Threading.Monitor]::Exit($Lock)
                    & $Log $WaitingLine 'Yellow'
                    [System.Threading.Monitor]::Enter($Lock)
                    continue
                }
                $null = [System.Threading.Monitor]::Wait($Lock, $SliceMs)
            }
        }
    }
    catch
    {
        # A failed .NET call only ends its own statement in PowerShell; rethrown, it ends the admission instead.
        throw
    }
    finally
    {
        # Asked of the lock itself, because a stop can land between letting the lock go and taking it back. A
        # caller that holds the lock is refused on entry, so a held lock here is this call's own.
        if ($null -eq $Admission)
        {
            # Stopped or failed while queued: leave the queue, and let the next stream re-check at once. A failure
            # while the waiting line was written finds the lock free, so it takes the lock back first.
            if (-not [System.Threading.Monitor]::IsEntered($Lock))
            {
                [System.Threading.Monitor]::Enter($Lock)
            }
            [void]$Waiting.Remove($Holder)
            [System.Threading.Monitor]::PulseAll($Lock)
        }
        if ([System.Threading.Monitor]::IsEntered($Lock))
        {
            [System.Threading.Monitor]::Exit($Lock)
        }
    }

    $WaitedSeconds = [math]::Round($Admission.WaitedSeconds)
    $FreeText = if ($null -ne $ShownGB) { [string]::Format($Culture, '{0:0.0} GB free', $ShownGB) } else { 'free memory not read yet' }
    if ($Admission.Reason -eq 'unreadable')
    {
        & $Log ([string]::Format($Culture, 'WARNING: could not read free memory before starting {0}: {1}. Starting it without the check.', $Subscription, $ReadError)) 'Yellow'
    }
    elseif ($Admission.Reason -eq 'max-wait')
    {
        & $Log ([string]::Format($Culture, 'WARNING: starting {0} after waiting {1} s for free memory: {2}, floor {3} GB (-StreamMemoryGB), {4} other subscription(s) in progress.', $Subscription, $WaitedSeconds, $FreeText, $FloorGB, $InProgress)) 'Yellow'
    }
    elseif ($Logged)
    {
        $Why = if ($Admission.Reason -eq 'memory') { $FreeText } else { 'no other subscription in progress' }
        & $Log ([string]::Format($Culture, 'admitted {0} after waiting {1} s: {2}', $Subscription, $WaitedSeconds, $Why)) 'DarkGray'
    }
    return $Admission
}

function Exit-StreamAdmission
{
    # Releases -Holder, the token Enter-StreamAdmission recorded as admitted, and wakes the waiting streams so the
    # next one re-checks at once. A token that is not recorded is left alone, so the stream calls this from the
    # subscription's finally block whether the subscription was admitted, failed or was stopped.
    param(
        [Parameter(Mandatory = $true)][hashtable]$State,
        [Parameter(Mandatory = $true)][string]$Holder
    )
    $Lock = $State['Lock']
    if ($null -eq $Lock) { throw [System.InvalidOperationException]::new('The admission state has no lock: create it with New-StreamAdmissionState.') }
    $LockTaken = $false
    try
    {
        [System.Threading.Monitor]::Enter($Lock, [ref]$LockTaken)
        if ($State['Holders'].Remove($Holder))
        {
            [System.Threading.Monitor]::PulseAll($Lock)
        }
    }
    catch
    {
        throw
    }
    finally
    {
        if ($LockTaken)
        {
            [System.Threading.Monitor]::Exit($Lock)
        }
    }
}

function Disable-ConsoleQuickEdit
{
    if (-not $IsWindows) { return }
    if (-not [Environment]::UserInteractive) { return }
    try { if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) { return } } catch { return }

    try
    {
        if (-not ('Rda.ConsoleMode' -as [type]))
        {
            Add-Type -Namespace 'Rda' -Name 'ConsoleMode' -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError=true)]
public static extern IntPtr GetStdHandle(int nStdHandle);
[DllImport("kernel32.dll")]
public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
[DllImport("kernel32.dll")]
public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
'@ -ErrorAction Stop
        }

        $STD_INPUT_HANDLE = -10
        $ENABLE_QUICK_EDIT = [uint32]0x0040
        $ENABLE_EXTENDED_FLAGS = [uint32]0x0080

        $Handle = [Rda.ConsoleMode]::GetStdHandle($STD_INPUT_HANDLE)
        $Mode = [uint32]0
        if ([Rda.ConsoleMode]::GetConsoleMode($Handle, [ref]$Mode))
        {
            $NewMode = ($Mode -band (-bnot $ENABLE_QUICK_EDIT)) -bor $ENABLE_EXTENDED_FLAGS
            [void][Rda.ConsoleMode]::SetConsoleMode($Handle, $NewMode)
        }
    }
    catch
    {
    }
}

function Get-SubscriptionAccessState
{
    param([Parameter(Mandatory = $true)][string]$SubscriptionId)

    try
    {
        $Response = Invoke-AzRestMethod -Method GET `
            -Path ('/subscriptions/{0}/resourcegroups?api-version=2021-04-01' -f $SubscriptionId) `
            -ErrorAction Stop
    }
    catch
    {
        return 'Unknown'
    }

    $Status = [int]$Response.StatusCode
    if ($Status -ge 200 -and $Status -lt 300)
    {
        return 'Empty'
    }
    if ($Status -eq 403 -or $Status -eq 401)
    {
        return 'NoAccess'
    }
    if ($Status -eq 404)
    {
        return 'NoAccess'
    }
    return 'Unknown'
}

function Test-SubscriptionAccessAll
{
    param(
        [Parameter(Mandatory = $true)]$Subscriptions,
        [int]$UnknownRetries = 2,
        [int]$RetryDelaySeconds = 2
    )
    $Probed = @()
    foreach ($Sub in @($Subscriptions))
    {
        $State = Get-SubscriptionAccessState -SubscriptionId $Sub.Id
        $Attempt = 0
        while ($State -eq 'Unknown' -and $Attempt -lt $UnknownRetries)
        {
            Start-Sleep -Seconds $RetryDelaySeconds
            $State = Get-SubscriptionAccessState -SubscriptionId $Sub.Id
            $Attempt++
        }
        $Probed += [pscustomobject]@{ Id = $Sub.Id; Name = $Sub.Name; State = $State }
    }
    return $Probed
}

function Resolve-AccessPreflight
{
    param(
        [object]$Probed,
        [switch]$AllowPartialAccess
    )
    $Inaccessible = @(@($Probed) | Where-Object { $_ -and ($_.State -eq 'NoAccess' -or $_.State -eq 'Unknown') })
    return [pscustomobject]@{
        Inaccessible    = $Inaccessible
        InaccessibleIds = @($Inaccessible | ForEach-Object { $_.Id })
        ShouldBlock     = ($Inaccessible.Count -gt 0 -and -not $AllowPartialAccess)
    }
}

function Confirm-PartialAccessContinue
{
    # Asks the person at the console whether to go on with only the subscriptions this identity
    # can read. Returns $false WITHOUT asking when nobody can answer: a non-interactive session,
    # or a sign-in that is not a user. A service principal or managed identity is an unattended
    # run even when a console happens to be attached, so a headless run stops exactly as it did
    # before this prompt existed. -IsInteractive is the same test the wrapper's other prompts use.
    param(
        [Parameter(Mandatory = $true)][string]$Question,
        [string]$AccountType,
        [bool]$IsInteractive = ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected)
    )

    if (-not $IsInteractive -or $AccountType -ne 'User')
    {
        return $false
    }

    Write-Host ""
    $Answer = Read-Host ("{0} [y/N]" -f $Question)
    return ($Answer -match '^(y|yes)$')
}

function Read-ResumeOrFreshChoice
{
    # Asks the person at the console whether to resume an earlier run that left resume state, or to
    # start fresh. Returns 'Resume' or 'Fresh'. Returns $null WITHOUT asking when nobody can answer,
    # so the caller behaves exactly as it did before this prompt existed: a sign-in that is not a user
    # (the rule Confirm-PartialAccessContinue uses), or no person watching a real terminal. Unlike
    # Confirm-PartialAccessContinue, redirected output also counts as nobody watching (the test
    # Test-RdaFinalScreenClearable uses): this question comes up on an ordinary re-run, and one
    # written into a log file would wait for an answer nobody can see. A prompt that cannot be read
    # (pwsh -NonInteractive) also returns $null, after one line saying no answer was waited for,
    # because the question is already on the screen by then.
    # Enter, R or resume means resume; F or fresh means start fresh (any letter case, spaces
    # ignored); anything else asks again. -UncarriedCount is how many done subscriptions have no
    # report a resumed run could carry into its bundle. When it is above 0 the question says so and
    # Enter means start fresh instead, because resuming would leave those reports out.
    # -StartedAt is when the earlier run started: a [datetime] (as ConvertFrom-Json returns it) or a
    # round-trip string. When it is missing or unreadable the start time is left out.
    param(
        [Parameter(Mandatory = $true)][int]$CompletedCount,
        [int]$FailedCount = 0,
        [int]$UncarriedCount = 0,
        [object]$StartedAt = $null,
        [string]$AccountType,
        [bool]$IsInteractive = ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected)
    )

    if (-not $IsInteractive -or $AccountType -ne 'User')
    {
        return $null
    }

    $Invariant = [Globalization.CultureInfo]::InvariantCulture
    $StartedText = ''
    if ($StartedAt -is [datetime])
    {
        $StartedLocal = if ($StartedAt.Kind -eq [DateTimeKind]::Utc) { $StartedAt.ToLocalTime() } else { $StartedAt }
        $StartedText = ' (started {0})' -f $StartedLocal.ToString('yyyy-MM-dd HH:mm', $Invariant)
    }
    else
    {
        $ParsedStart = [datetimeoffset]::MinValue
        if ([datetimeoffset]::TryParse([string]$StartedAt, $Invariant, [Globalization.DateTimeStyles]::None, [ref]$ParsedStart))
        {
            $StartedText = ' (started {0})' -f $ParsedStart.LocalDateTime.ToString('yyyy-MM-dd HH:mm', $Invariant)
        }
    }

    $FreshByDefault = ($UncarriedCount -gt 0)
    $ResumeDefault = if ($FreshByDefault) { '' } else { ' (default)' }
    $FreshDefault = if ($FreshByDefault) { ' (default)' } else { '' }
    $PromptText = if ($FreshByDefault) { 'Choice [r/F]' } else { 'Choice [R/f]' }

    Write-Host ""
    Write-Host ("Found an earlier run for this tenant{0}:" -f $StartedText) -ForegroundColor Yellow
    Write-Host ("  {0} subscription(s) done, {1} failed." -f $CompletedCount, $FailedCount)
    if ($FreshByDefault)
    {
        Write-Host ("  {0} of the done subscription(s) have no report this run can carry, so resuming would leave them out of the bundle." -f $UncarriedCount) -ForegroundColor Yellow
    }
    Write-Host ("  [R] Resume - skip the {0} done subscription(s){1}" -f $CompletedCount, $ResumeDefault)
    Write-Host ("  [F] Start fresh - collect all again; the earlier state is kept as a backup{0}" -f $FreshDefault)
    while ($true)
    {
        try
        {
            $Answer = [string](Read-Host $PromptText -ErrorAction Stop)
        }
        catch
        {
            # pwsh -NonInteractive at a terminal: nobody can answer, so behave as without the prompt.
            Write-Host "  No answer can be read in this session (pwsh -NonInteractive, for example), so the run goes on as if it had not asked." -ForegroundColor Yellow
            return $null
        }
        $Answer = $Answer.Trim()
        if ($Answer -eq '')
        {
            if ($FreshByDefault) { return 'Fresh' }
            return 'Resume'
        }
        if ($Answer -match '^(r|resume)$')
        {
            return 'Resume'
        }
        if ($Answer -match '^(f|fresh)$')
        {
            return 'Fresh'
        }
        Write-Host "  Type R to resume or F to start fresh." -ForegroundColor Yellow
    }
}

function Clear-RdaResumeStateForFresh
{
    # Clears the resume state once the person at the console chose to start fresh and the backup of
    # the earlier state is written. Saves an empty state carrying this run's start listing (the file
    # and, with blob-backed state, the blob), then reads both back, because saving the state only
    # warns when it fails. It removes no per-stream copy: only Remove-RdaMergedStreamState does that,
    # once the saved state holds what the copy recorded. A copy that is still there (one the startup
    # merge kept, or one it could not read) is named instead, because a later start merges it back.
    # A blob that cannot be read back or checked is named too, as still holding the state. Returns one
    # description for each place that still holds the earlier run's records, and nothing when the
    # clear held.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string]$ResumeStateFile,
        [Parameter(Mandatory = $true)][string]$Tenant,
        $StartSnapshot = $null,
        [string[]]$StreamFilePaths = @(),
        [string[]]$StreamBlobNames = @(),
        $BlobContext = $null, [string]$BlobContainer = $null, [string]$BlobName = $null
    )

    Save-CompletedSubscriptionIds -Path $ResumeStateFile -Tenant $Tenant -Ids @() -FailedAttempts @() -Reports @() -StartSnapshot $StartSnapshot `
        -BlobContext $BlobContext -BlobContainer $BlobContainer -BlobName $BlobName

    $Held = @()
    if (Test-Path -LiteralPath $ResumeStateFile -PathType Leaf)
    {
        # A save that failed leaves the earlier file in place, so a file that cannot be read still holds it.
        $LocalState = $null
        try { $LocalState = Get-Content -LiteralPath $ResumeStateFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
        catch { Write-Verbose ("Could not read back the resume state at {0}: {1}" -f $ResumeStateFile, $_.Exception.Message) }
        if ($null -eq $LocalState -or @($LocalState.CompletedSubscriptionIds).Count -gt 0 -or @($LocalState.FailedAttempts | Where-Object { $null -ne $_ }).Count -gt 0)
        {
            $Held += 'the state file {0}' -f $ResumeStateFile
        }
    }
    # Lists the blob by its full name, which (unlike a read) does not fail for a blob that is not
    # there; a listing that fails cannot rule the blob out, so it counts as still holding the state.
    $BlobCheck = {
        param([string]$Name)
        try
        {
            $Found = @(Get-AzStorageBlob -Container $BlobContainer -Prefix $Name -Context $BlobContext -ErrorAction Stop | Where-Object { $_.Name -eq $Name })
            if ($Found.Count -gt 0) { return 'Present' }
            return 'Absent'
        }
        catch
        {
            Write-Verbose ("Could not check the state blob {0}: {1}" -f $Name, $_.Exception.Message)
            return 'Unknown'
        }
    }
    if ($BlobContext -and $BlobContainer -and $BlobName)
    {
        # The next start reads the blob before the file, so a blob the save did not replace still counts.
        $BlobState = Read-StateBlob -Context $BlobContext -Container $BlobContainer -BlobName $BlobName
        if ($null -ne $BlobState)
        {
            if (@($BlobState.CompletedSubscriptionIds).Count -gt 0 -or @($BlobState.FailedAttempts | Where-Object { $null -ne $_ }).Count -gt 0)
            {
                $Held += 'the state blob {0}' -f $BlobName
            }
        }
        else
        {
            # Nothing read back: either there is no blob, or it is there and could not be read.
            $BlobFound = & $BlobCheck $BlobName
            if ($BlobFound -eq 'Present') { $Held += 'the state blob {0} (it could not be read back, so treat it as still holding the state)' -f $BlobName }
            elseif ($BlobFound -eq 'Unknown') { $Held += 'the state blob {0} (it could not be checked, so treat it as still holding the state)' -f $BlobName }
        }
    }
    foreach ($StreamPath in @($StreamFilePaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }))
    {
        if (Test-Path -LiteralPath $StreamPath -PathType Leaf) { $Held += 'the per-stream state file {0}' -f $StreamPath }
    }
    if ($BlobContext -and $BlobContainer)
    {
        foreach ($StreamBlob in @($StreamBlobNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }))
        {
            $StreamFound = & $BlobCheck $StreamBlob
            if ($StreamFound -eq 'Present') { $Held += 'the per-stream state blob {0}' -f $StreamBlob }
            elseif ($StreamFound -eq 'Unknown') { $Held += 'the per-stream state blob {0} (it could not be checked, so treat it as still holding the state)' -f $StreamBlob }
        }
    }
    return $Held
}

function Get-RdaMgSubscriptionId
{
    param($Node)

    $Ids = @()
    if ($null -eq $Node -or $null -eq $Node.Children) { return $Ids }
    foreach ($Child in @($Node.Children))
    {
        if ("$($Child.Type)" -like '*subscriptions*')
        {
            if (-not [string]::IsNullOrWhiteSpace($Child.Name)) { $Ids += [string]$Child.Name }
        }
        else
        {
            $Ids += Get-RdaMgSubscriptionId -Node $Child
        }
    }
    return $Ids
}

function Get-TenantSubscriptionId
{
    param([Parameter(Mandatory = $true)][string]$TenantId)

    try
    {
        $RootMg = Get-AzManagementGroup -GroupName $TenantId -Expand -Recurse -ErrorAction Stop
        $Ids = @(Get-RdaMgSubscriptionId -Node $RootMg | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
        if ($Ids.Count -eq 0)
        {
            return [pscustomobject]@{ Ids = $null; Detail = 'The tenant-root management group returned zero subscriptions.' }
        }
        return [pscustomobject]@{ Ids = $Ids; Detail = $null }
    }
    catch
    {
        return [pscustomobject]@{ Ids = $null; Detail = $_.Exception.Message }
    }
}

function Get-ShardKeyForSubscription
{
    param(
        [Parameter(Mandatory = $true)][string]$SubscriptionId,
        [Parameter(Mandatory = $true)][int]$ShardCount
    )
    if ($ShardCount -le 1) { return 0 }
    $Bytes = [System.Text.Encoding]::UTF8.GetBytes($SubscriptionId.ToLowerInvariant())
    $Sha = [System.Security.Cryptography.SHA256]::Create()
    try { $Hash = $Sha.ComputeHash($Bytes) } finally { $Sha.Dispose() }
    $Value = ([uint32]$Hash[0] -shl 24) -bor ([uint32]$Hash[1] -shl 16) -bor ([uint32]$Hash[2] -shl 8) -bor [uint32]$Hash[3]
    return [int]($Value % [uint32]$ShardCount)
}

function Select-ShardSubscriptions
{
    param(
        $Subscriptions,
        [Parameter(Mandatory = $true)][int]$ShardIndex,
        [Parameter(Mandatory = $true)][int]$ShardCount
    )
    if ($ShardCount -le 1) { return @($Subscriptions) }
    return @(@($Subscriptions) | Where-Object { (Get-ShardKeyForSubscription -SubscriptionId $_.Id -ShardCount $ShardCount) -eq $ShardIndex })
}

function Get-InventoryPlan
{
    param(
        [Parameter(Mandatory = $true)][int]$SubscriptionCount,
        [Parameter(Mandatory = $true)][int]$Streams,
        [Parameter(Mandatory = $true)][double]$PerSubSeconds,
        [double]$MaxSingleMachineHours = 2
    )

    if ($Streams -lt 1) { $Streams = 1 }
    if ($PerSubSeconds -le 0) { $PerSubSeconds = 1 }
    if ($MaxSingleMachineHours -le 0) { $MaxSingleMachineHours = 2 }
    $CeilingSeconds = $MaxSingleMachineHours * 3600

    $SingleBatches = if ($SubscriptionCount -le 0) { 0 } else { [math]::Ceiling($SubscriptionCount / $Streams) }
    $SingleSeconds = $SingleBatches * $PerSubSeconds

    if ($SubscriptionCount -le 0 -or $SingleSeconds -le $CeilingSeconds)
    {
        return [pscustomobject]@{
            SubscriptionCount          = $SubscriptionCount
            Mode                       = 'Single'
            ShardCount                 = 1
            Streams                    = $Streams
            PerSubSeconds              = $PerSubSeconds
            EstimatedSeconds           = [int]$SingleSeconds
            PerMachineSubscriptions    = $SubscriptionCount
            EstimatedPerMachineSeconds = [int]$SingleSeconds
            MaxSingleMachineHours      = $MaxSingleMachineHours
        }
    }

    $MaxBatchesPerMachine = [math]::Floor($CeilingSeconds / $PerSubSeconds)
    if ($MaxBatchesPerMachine -lt 1) { $MaxBatchesPerMachine = 1 }
    $MaxSubsPerMachine = [int]($Streams * $MaxBatchesPerMachine)
    if ($MaxSubsPerMachine -lt 1) { $MaxSubsPerMachine = 1 }

    $ShardCount = [int][math]::Ceiling($SubscriptionCount / $MaxSubsPerMachine)
    if ($ShardCount -lt 2) { $ShardCount = 2 }

    $PerMachineSubs = [int][math]::Ceiling($SubscriptionCount / $ShardCount)
    $PerMachineBatches = [math]::Ceiling($PerMachineSubs / $Streams)
    $PerMachineSeconds = $PerMachineBatches * $PerSubSeconds

    return [pscustomobject]@{
        SubscriptionCount          = $SubscriptionCount
        Mode                       = 'Sharded'
        ShardCount                 = $ShardCount
        Streams                    = $Streams
        PerSubSeconds              = $PerSubSeconds
        EstimatedSeconds           = [int]$SingleSeconds
        PerMachineSubscriptions    = $PerMachineSubs
        EstimatedPerMachineSeconds = [int]$PerMachineSeconds
        MaxSingleMachineHours      = $MaxSingleMachineHours
    }
}

function Get-PlanShardDirective
{
    param(
        [Parameter(Mandatory = $true)][int]$ShardCount
    )
    $Count = if ($ShardCount -lt 1) { 1 } else { $ShardCount }
    $Lines = @()
    $Lines += ('PLAN_SHARDCOUNT={0}' -f $Count)
    if ($Count -gt 1)
    {
        $Lines += ('IMPORTANT: this is {0} shards. Run ALL of them - one per machine - with -ShardIndex 0 through {1} (i.e. 0..{1}). Each -ShardIndex is a distinct ~1/{0} slice of the tenant; any index you do NOT run is SILENTLY omitted from the combined result (the shards are disjoint and do not coordinate).' -f $Count, ($Count - 1))
    }
    return $Lines
}

function Get-MetricQueryWeightMap
{
    return @(
        [pscustomobject]@{ Type = 'microsoft.compute/virtualmachines'; Weight = 2; ExtraFilter = $null; Gate = $null; Batched = $true }
        [pscustomobject]@{ Type = 'microsoft.compute/disks'; Weight = 4; ExtraFilter = 'isnotempty(managedBy)'; Gate = 'Disk'; Batched = $true }
        [pscustomobject]@{ Type = 'microsoft.storage/storageaccounts'; Weight = 1; ExtraFilter = $null; Gate = 'Storage'; Batched = $true }
        [pscustomobject]@{ Type = 'microsoft.sql/servers/databases'; Weight = 9; ExtraFilter = "name != 'master'"; Gate = $null; Batched = $true }
        [pscustomobject]@{ Type = 'microsoft.web/sites'; Weight = 2; ExtraFilter = "kind contains 'functionapp'"; Gate = $null; Batched = $false }
        [pscustomobject]@{ Type = 'microsoft.dbformariadb/servers'; Weight = 3; ExtraFilter = $null; Gate = $null; Batched = $false }
        [pscustomobject]@{ Type = 'microsoft.dbforpostgresql/servers'; Weight = 3; ExtraFilter = $null; Gate = $null; Batched = $false }
        [pscustomobject]@{ Type = 'microsoft.dbformysql/servers'; Weight = 3; ExtraFilter = $null; Gate = $null; Batched = $false }
        [pscustomobject]@{ Type = 'microsoft.dbformysql/flexibleservers'; Weight = 3; ExtraFilter = $null; Gate = $null; Batched = $false }
        [pscustomobject]@{ Type = 'microsoft.dbforpostgresql/flexibleservers'; Weight = 3; ExtraFilter = $null; Gate = $null; Batched = $false }
        [pscustomobject]@{ Type = 'microsoft.compute/virtualmachinescalesets'; Weight = 2; ExtraFilter = $null; Gate = $null; Batched = $true }
        [pscustomobject]@{ Type = 'microsoft.documentdb/databaseaccounts'; Weight = 4; ExtraFilter = $null; Gate = $null; Batched = $true }
        [pscustomobject]@{ Type = 'microsoft.containerregistry/registries'; Weight = 1; ExtraFilter = $null; Gate = $null; Batched = $false }
    )
}

# The three function-app metric-query costs, derived from the map so the two can
# never drift apart. A function app's cost is NOT the map's single integer:
#
#   NonFlex     the legacy FunctionExecutionCount/Units pair only.
#   Flex        the five Flex-only billing names (AlwaysReady/OnDemand execution
#               Count+Units, plus AlwaysReadyUnits). Measured on a live
#               FC1/FlexConsumption app: the legacy pair is ABSENT there, so this
#               REPLACES the base rather than adding to it.
#   Unresolved  both sets, because Extension/Metrics.ps1 deliberately enqueues both
#               when the hosting plan cannot be resolved from the Resource Graph
#               snapshot (never drop a real Flex app's only execution metrics).
#
# FlexOnlyMetricCount is the one hardcoded figure; a unit test pins it against the
# metric names Extension/Metrics.ps1 actually enqueues, so adding a sixth Flex name
# there turns that test red instead of silently under-sizing a shard.
# PURE (no Azure) so it is unit-testable.
function Get-FunctionAppPlanWeight
{
    $BaseWeight = [int](Get-MetricQueryWeightMap | Where-Object { $_.Type -eq 'microsoft.web/sites' }).Weight
    $FlexOnlyMetricCount = 5
    return [pscustomobject]@{
        NonFlex    = $BaseWeight
        Flex       = $FlexOnlyMetricCount
        Unresolved = $BaseWeight + $FlexOnlyMetricCount
    }
}

function Get-PlanWeightKql
{
    param(
        [switch]$SkipDiskMetrics,
        [switch]$SkipStorageMetrics
    )
    $Cases = @()
    $BatchCases = @()
    foreach ($Entry in (Get-MetricQueryWeightMap))
    {
        if ($Entry.Gate -eq 'Disk' -and $SkipDiskMetrics) { continue }
        if ($Entry.Gate -eq 'Storage' -and $SkipStorageMetrics) { continue }
        $Pred = "type =~ '{0}'" -f $Entry.Type
        if ($Entry.ExtraFilter) { $Pred += ' and ' + $Entry.ExtraFilter }
        $Cases += ('{0}, {1}' -f $Pred, $Entry.Weight)
        if ($Entry.Batched) { $BatchCases += ('{0}, {1}' -f $Pred, $Entry.Weight) }
    }
    $CaseBody = $Cases -join ",`n    "
    $BatchCaseBody = if ($BatchCases.Count -gt 0) { $BatchCases -join ",`n    " } else { "1 == 0, 0" }
    $AppWeight = Get-FunctionAppPlanWeight
    return @"
Resources
| extend __w = case(
    $CaseBody,
    0)
| extend __bw = case(
    $BatchCaseBody,
    0)
| where __w > 0
| extend __farmId = tolower(tostring(properties.serverFarmId))
| join kind=leftouter (
    Resources
    | where type =~ 'microsoft.web/serverfarms'
    | project __planId = tolower(tostring(id)), __planSkuName = tostring(sku.name), __planSkuTier = tostring(sku.tier)
    ) on `$left.__farmId == `$right.__planId
| extend __planResolved = isnotempty(__planId) and (isnotempty(__planSkuName) or isnotempty(__planSkuTier))
| extend __isFlex = __planResolved and (__planSkuName =~ 'FC1' or __planSkuTier =~ 'FlexConsumption')
| extend __w = case(
    type !~ 'microsoft.web/sites', __w,
    __isFlex, $($AppWeight.Flex),
    not(__planResolved), $($AppWeight.Unresolved),
    $($AppWeight.NonFlex))
| summarize QueryWeight = sum(__w), BatchWeight = sum(__bw) by subscriptionId
"@
}

function Get-SubscriptionHashValue
{
    param(
        [Parameter(Mandatory = $true)][string]$SubscriptionId
    )
    $Bytes = [System.Text.Encoding]::UTF8.GetBytes($SubscriptionId.ToLowerInvariant())
    $Sha = [System.Security.Cryptography.SHA256]::Create()
    try { $Hash = $Sha.ComputeHash($Bytes) } finally { $Sha.Dispose() }
    return ([uint32]$Hash[0] -shl 24) -bor ([uint32]$Hash[1] -shl 16) -bor ([uint32]$Hash[2] -shl 8) -bor [uint32]$Hash[3]
}

function Invoke-PlanWeightQuery
{
    param([hashtable]$GraphArgs, [int]$MaxRetries)

    for ($Attempt = 0; ; $Attempt++)
    {
        try
        {
            return Search-AzGraph @GraphArgs -ErrorAction Stop
        }
        catch
        {
            if ($Attempt -ge $MaxRetries) { throw }

            $Wait = [math]::Min([math]::Pow(2, $Attempt), 8)
            Start-Sleep -Seconds ([math]::Round($Wait + ((Get-Random -Minimum 0 -Maximum 1000) / 1000.0), 2))
        }
    }
}

function Get-PlanSubscriptionWeights
{
    param(
        [Parameter(Mandatory = $true)][string[]]$SubscriptionIds,
        [switch]$SkipDiskMetrics,
        [switch]$SkipStorageMetrics
    )
    if (-not (Get-Command Search-AzGraph -ErrorAction SilentlyContinue)) { return $null }
    $Kql = Get-PlanWeightKql -SkipDiskMetrics:$SkipDiskMetrics -SkipStorageMetrics:$SkipStorageMetrics
    $Weights = @{}

    $PlanQueryMaxRetries = 4

    $PlanQueryChunkSize = 1000

    try
    {
        $Ids = @($SubscriptionIds | Where-Object { $_ })
        for ($Offset = 0; $Offset -lt $Ids.Count; $Offset += $PlanQueryChunkSize)
        {
            $Chunk = @($Ids[$Offset..([math]::Min($Offset + ($PlanQueryChunkSize - 1), $Ids.Count - 1))])
            $GraphArgs = @{ Query = $Kql; Subscription = $Chunk; First = $PlanQueryChunkSize }
            $Batch = Invoke-PlanWeightQuery -GraphArgs $GraphArgs -MaxRetries $PlanQueryMaxRetries
            while ($true)
            {
                foreach ($Row in $Batch)
                {
                    $SubId = [string]$Row.subscriptionId
                    if ($SubId)
                    {
                        $Weights[$SubId] = [pscustomobject]@{
                            Total = [double]$Row.QueryWeight
                            Batch = [double]$Row.BatchWeight
                        }
                    }
                }

                if (-not $Batch.SkipToken) { break }
                $GraphArgs['SkipToken'] = $Batch.SkipToken
                $Batch = Invoke-PlanWeightQuery -GraphArgs $GraphArgs -MaxRetries $PlanQueryMaxRetries
            }
        }
    }
    catch
    {
        Write-Warning ("Plan weight query failed, so shard sizing will use the coarse flat estimate instead of per-subscription composition: {0}" -f $_.Exception.Message)
        return $null
    }
    return $Weights
}

function Get-WeightedInventoryPlan
{
    param(
        [Parameter(Mandatory = $true)][hashtable]$SubSeconds,
        [int]$Streams = 1,
        [double]$MaxSingleMachineHours = 2,
        [int]$MaxShards = 1000
    )
    if ($Streams -lt 1) { $Streams = 1 }
    if ($MaxSingleMachineHours -le 0) { $MaxSingleMachineHours = 2 }
    if ($MaxShards -lt 1) { $MaxShards = 1 }
    $CeilingSeconds = $MaxSingleMachineHours * 3600
    $SubIds = @($SubSeconds.Keys)
    $SubCount = $SubIds.Count

    if ($SubCount -eq 0)
    {
        return [pscustomobject]@{
            Mode = 'Single'; ShardCount = 1; Streams = $Streams; SubscriptionCount = 0
            TotalSeconds = 0; BusiestShardSeconds = 0; LargestSingleSubSeconds = 0
            PerMachineSubscriptions = 0; MaxSingleMachineHours = $MaxSingleMachineHours
            CeilingUnreachable = $false; CeilingUnreachableReason = $null
        }
    }

    if ($MaxShards -gt $SubCount) { $MaxShards = $SubCount }

    $TotalSeconds = 0.0
    $LargestSingle = 0.0
    $HashVal = @{}
    foreach ($Id in $SubIds)
    {
        $Sec = [double]$SubSeconds[$Id]
        $TotalSeconds += $Sec
        if ($Sec -gt $LargestSingle) { $LargestSingle = $Sec }
        $HashVal[$Id] = Get-SubscriptionHashValue -SubscriptionId $Id
    }

    $BusiestForN = {
        param([int]$N)
        $BucketSum = @{}
        $BucketMax = @{}
        foreach ($Id in $SubIds)
        {
            $K = [int]($HashVal[$Id] % [uint32]$N)
            $Sec = [double]$SubSeconds[$Id]
            $BucketSum[$K] = ([double]$BucketSum[$K]) + $Sec
            if ($Sec -gt ([double]$BucketMax[$K])) { $BucketMax[$K] = $Sec }
        }
        $Busiest = 0.0
        foreach ($K in $BucketSum.Keys)
        {
            $Wall = [math]::Max([double]$BucketMax[$K], [math]::Ceiling(([double]$BucketSum[$K]) / $Streams))
            if ($Wall -gt $Busiest) { $Busiest = $Wall }
        }
        return $Busiest
    }

    $CeilingUnreachable = $false
    $CeilingUnreachableReason = $null
    $ChosenN = 0
    $Busiest = 0.0

    if ($LargestSingle -gt $CeilingSeconds)
    {
        $ChosenN = $MaxShards
        $Busiest = [double](& $BusiestForN $MaxShards)
        $CeilingUnreachable = $true
        $CeilingUnreachableReason = 'single-subscription-exceeds-ceiling'
    }
    else
    {
        $Lower = [long][math]::Ceiling($TotalSeconds / ($Streams * $CeilingSeconds))
        if ($Lower -lt 1) { $Lower = 1 }
        if ($Lower -gt $MaxShards) { $Lower = $MaxShards }

        for ($N = $Lower; $N -le $MaxShards; $N++)
        {
            $B = [double](& $BusiestForN $N)
            if ($B -le $CeilingSeconds) { $ChosenN = $N; $Busiest = $B; break }
        }

        if ($ChosenN -eq 0)
        {
            $ChosenN = $MaxShards
            $Busiest = [double](& $BusiestForN $MaxShards)
            $CeilingUnreachable = $true
            $CeilingUnreachableReason = 'shard-cap-or-hash-collisions'
        }
    }

    return [pscustomobject]@{
        Mode                     = if ($ChosenN -le 1) { 'Single' } else { 'Sharded' }
        ShardCount               = $ChosenN
        Streams                  = $Streams
        SubscriptionCount        = $SubCount
        TotalSeconds             = [long]$TotalSeconds
        BusiestShardSeconds      = [long]$Busiest
        LargestSingleSubSeconds  = [long]$LargestSingle
        PerMachineSubscriptions  = [int][math]::Ceiling($SubCount / $ChosenN)
        MaxSingleMachineHours    = $MaxSingleMachineHours
        CeilingUnreachable       = $CeilingUnreachable
        CeilingUnreachableReason = $CeilingUnreachableReason
    }
}

# === Pre-flight checks ===
function Invoke-PreFlightChecks
{
    param(
        [Parameter(Mandatory = $true)] [string] $InventoryRoot
    )

    Write-Host "Running pre-flight checks..." -ForegroundColor Cyan

    if (Get-Command Get-CloudDrive -ErrorAction SilentlyContinue)
    {
        $CheckCloudDrive = Get-CloudDrive 3>$null 2>$null
        if ($null -eq $CheckCloudDrive)
        {
            Write-Host ""
            Write-Host "WARNING: Cloud Shell detected, but no storage account is mounted." -ForegroundColor Yellow
            Write-Host "  Outputs in $InventoryRoot will be lost when this Cloud Shell session ends." -ForegroundColor Yellow
            Write-Host "  This includes the resume-state file, so -Resume on a future session won't help recover." -ForegroundColor Yellow
            Write-Host "  To persist outputs across sessions, attach a storage account via the Cloud Shell" -ForegroundColor Yellow
            Write-Host "  settings menu (gear icon) > Reset User Settings > Mount storage account." -ForegroundColor Yellow
            Write-Host "  Continuing in ephemeral mode - download the report ZIP from $InventoryRoot before closing the shell." -ForegroundColor Yellow
            Write-Host ""
        }
        else
        {
            Write-Host ("Cloud Shell drive mounted: {0}" -f $CheckCloudDrive.Name) -ForegroundColor Green
        }
    }

    try
    {
        $RootItem = Get-Item -LiteralPath $InventoryRoot -ErrorAction Stop
        $Drive = $RootItem.PSDrive
        if ($null -ne $Drive -and $null -ne $Drive.Free)
        {
            $FreeMB = [math]::Round($Drive.Free / 1MB, 0)

            # Render the figure ONCE, for all three branches below, so none of
            # them can drift back into an ambiguous form.
            #
            # Do NOT reintroduce a bare "{0:N0} MB" here. N0 uses the HOST
            # culture's NumberGroupSeparator, and on a culture where that
            # separator is '.' (en-NL, de-DE, ...) 69969 prints as "69.969 MB",
            # which an operator reads as 69 MB - so a perfectly healthy 68 GB
            # free looks like an imminent out-of-disk failure.
            #
            # Two properties keep it unambiguous on every host: the MB value is
            # formatted with NO grouping at all (bare digits cannot be misread
            # as a decimal), and both values use InvariantCulture so the decimal
            # point is always '.'. MB alone is also the wrong unit at this
            # magnitude, so a GB value leads once there is more than 1 GB.
            #
            # Keep in sync with the inline pre-flight block in
            # ResourceInventory.ps1 - both copies must produce identical text
            # for the same input.
            $InvariantCulture = [System.Globalization.CultureInfo]::InvariantCulture
            $FreeSpaceDisplay = if ($FreeMB -ge 1024)
            {
                '{0} GB ({1} MB)' -f ($FreeMB / 1024).ToString('0.0', $InvariantCulture), $FreeMB.ToString('0', $InvariantCulture)
            }
            else
            {
                '{0} MB' -f $FreeMB.ToString('0', $InvariantCulture)
            }

            if ($FreeMB -lt 100)
            {
                Write-Host ("ERROR: Free disk space at {0} is {1}; the script needs at least 100 MB to start. Free space and re-run." -f $InventoryRoot, $FreeSpaceDisplay) -ForegroundColor Red
                Exit-Wrapper -Code 1
            }
            elseif ($FreeMB -lt 500)
            {
                Write-Host ("WARNING: Free disk space at {0} is {1}. A large multi-subscription run can exceed this. Consider freeing space before running." -f $InventoryRoot, $FreeSpaceDisplay) -ForegroundColor Yellow
            }
            else
            {
                Write-Host ("Free disk space: {0} at {1}" -f $FreeSpaceDisplay, $InventoryRoot) -ForegroundColor Green
            }
        }
    }
    catch
    {
        Write-Host ("WARNING: Could not determine free disk space at {0}: {1}" -f $InventoryRoot, $_.Exception.Message) -ForegroundColor Yellow
    }

    $ProbePath = Join-Path $InventoryRoot (".write-probe-{0}.tmp" -f ([guid]::NewGuid()))
    try
    {
        Set-Content -LiteralPath $ProbePath -Value 'preflight write probe' -Encoding utf8 -ErrorAction Stop
        $ProbeRead = Get-Content -LiteralPath $ProbePath -Raw -ErrorAction Stop
        if ($ProbeRead -notmatch 'preflight write probe')
        {
            throw "Write probe content mismatch (read back '$ProbeRead')"
        }
        Remove-Item -LiteralPath $ProbePath -Force -ErrorAction Stop
        Write-Host ("Write probe: OK ({0})" -f $InventoryRoot) -ForegroundColor Green
    }
    catch
    {
        Write-Host ("ERROR: Cannot write to {0}: {1}" -f $InventoryRoot, $_.Exception.Message) -ForegroundColor Red
        Write-Host "  This usually means: readonly directory, denied permissions, antivirus or DLP product blocking writes, or a stale handle." -ForegroundColor Red
        Write-Host "  Verify the directory is writable and re-run." -ForegroundColor Red
        try { if (Test-Path -LiteralPath $ProbePath) { Remove-Item -LiteralPath $ProbePath -Force -ErrorAction SilentlyContinue } }
        catch { Write-Verbose ("Probe cleanup failed at {0}: {1}" -f $ProbePath, $_.Exception.Message) }
        Exit-Wrapper -Code 1
    }

    # A parallel run writes an Az context snapshot (a token cache) here and removes it itself. One that
    # is still present before this run has written its own was left by a run that did not reach its
    # cleanup, or belongs to another wrapper running against this folder right now. Report it; never
    # delete it from here, because the second case would break that other run. Only the wrapper writes
    # snapshots, so ResourceInventory.ps1's own pre-flight has no counterpart to this check.
    $StaleSnapshots = @(Get-StaleAzContextSnapshot -InventoryRoot $InventoryRoot)
    if ($StaleSnapshots.Count -gt 0)
    {
        Write-Host ""
        Write-Host ("WARNING: {0} Az context snapshot(s) from another parallel-streams run found in {1}." -f $StaleSnapshots.Count, $InventoryRoot) -ForegroundColor Yellow
        foreach ($Snapshot in $StaleSnapshots)
        {
            # UTC on both sides, so a DST change cannot shift the age; a timestamp in the future counts as 0.
            $Age = [datetime]::UtcNow - $Snapshot.LastWriteTimeUtc
            if ($Age -lt [timespan]::Zero) { $Age = [timespan]::Zero }
            $AgeText = if ($Age.TotalHours -lt 1) { '{0} min' -f [math]::Floor($Age.TotalMinutes) } else { '{0} h' -f $Age.TotalHours.ToString('0.0', [cultureinfo]::InvariantCulture) }
            Write-Host ("  {0}  ({1} KB, written {2} ago)" -f $Snapshot.Name, [math]::Round($Snapshot.Length / 1KB), $AgeText) -ForegroundColor Yellow
        }
        Write-Host "  Each one holds an Azure token cache. If no other wrapper is running against this folder, delete them:" -ForegroundColor Yellow
        foreach ($Snapshot in $StaleSnapshots)
        {
            # Escapes every quote character PowerShell treats as closing a single-quoted string, curly ones included.
            Write-Host ("  Remove-Item -LiteralPath '{0}' -Force" -f [System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($Snapshot.FullName)) -ForegroundColor Yellow
        }
        Write-Host ""
    }

    Write-Host "Pre-flight checks passed." -ForegroundColor Green
    Write-Host ""
}

function Resolve-TenantId
{
    param([Parameter(Mandatory = $true)][string]$Value)

    $GuidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    if ($Value -match $GuidPattern) { return $Value }

    # An email / UPN (user@domain) is not a valid tenant path for OIDC discovery -
    # login.microsoftonline.com rejects it with 400. Take the domain after the '@',
    # which IS a valid tenant identifier when it is a verified domain on the tenant.
    $Lookup = $Value
    if ($Value -match '^[^@]+@(.+)$')
    {
        $Lookup = $Matches[1]
        Write-Host ("Interpreting '{0}' as an email; using its domain '{1}' as the tenant." -f $Value, $Lookup) -ForegroundColor Cyan
    }

    $Url = "https://login.microsoftonline.com/$Lookup/v2.0/.well-known/openid-configuration"
    Write-Host ("Resolving tenant '{0}' via OIDC discovery..." -f $Lookup) -ForegroundColor Cyan
    try
    {
        $Config = Invoke-RestMethod -Uri $Url -Method Get -ErrorAction Stop
    }
    catch
    {
        throw "Could not resolve tenant '$Value' to a GUID. Check that it is a valid Azure AD domain or pass the tenant GUID directly. Underlying error: $($_.Exception.Message)"
    }

    if ($null -eq $Config -or [string]::IsNullOrWhiteSpace($Config.issuer))
    {
        throw "OIDC discovery for tenant '$Value' returned an unexpected response (no issuer)."
    }

    $Segments = $Config.issuer -split '/'
    $Resolved = $Segments | Where-Object { $_ -match $GuidPattern } | Select-Object -First 1
    if (-not $Resolved)
    {
        throw "OIDC discovery for tenant '$Value' did not contain a recognizable tenant GUID. issuer='$($Config.issuer)'"
    }

    Write-Host ("Resolved tenant '{0}' -> {1}" -f $Value, $Resolved) -ForegroundColor Green
    return $Resolved
}

function Get-ResumeStateObject
{
    param([string]$Path, [string]$Tenant, $BlobContext = $null, [string]$BlobContainer = $null, [string]$BlobName = $null)

    if ($BlobContext -and $BlobContainer -and $BlobName)
    {
        $BlobState = Read-StateBlob -Context $BlobContext -Container $BlobContainer -BlobName $BlobName
        if ($null -ne $BlobState)
        {
            if ($BlobState.TenantID -ne $Tenant)
            {
                Write-Host ("Resume state blob is for a different tenant ({0}); ignoring." -f $BlobState.TenantID) -ForegroundColor Yellow
                return $null
            }
            return $BlobState
        }
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try
    {
        $State = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        if ($State.TenantID -ne $Tenant)
        {
            Write-Host ("Resume state file is for a different tenant ({0}); ignoring." -f $State.TenantID) -ForegroundColor Yellow
            return $null
        }
        return $State
    }
    catch
    {
        Write-Host ("Could not read resume state file ({0}); starting fresh. {1}" -f $Path, $_) -ForegroundColor Yellow
        return $null
    }
}

function Resolve-ResumeState
{
    param(
        [string]$Path,
        [string]$Tenant,
        $BlobContext = $null,
        [string]$BlobContainer = $null,
        [string]$BlobName = $null,
        $State = $null,
        [switch]$StateSupplied
    )

    if (-not $StateSupplied)
    {
        return Get-ResumeStateObject -Path $Path -Tenant $Tenant -BlobContext $BlobContext -BlobContainer $BlobContainer -BlobName $BlobName
    }

    if ($null -eq $State) { return $null }

    if ($State.TenantID -ne $Tenant)
    {
        Write-Host ("Supplied resume state is for a different tenant ({0}); ignoring." -f $State.TenantID) -ForegroundColor Yellow
        return $null
    }

    return $State
}

function Get-CompletedSubscriptionIds
{
    param([string]$Path, [string]$Tenant, $BlobContext = $null, [string]$BlobContainer = $null, [string]$BlobName = $null,
        $State = $null)

    $State = Resolve-ResumeState -Path $Path -Tenant $Tenant -BlobContext $BlobContext -BlobContainer $BlobContainer -BlobName $BlobName `
        -State $State -StateSupplied:$PSBoundParameters.ContainsKey('State')

    if ($null -eq $State -or $null -eq $State.CompletedSubscriptionIds) { return @() }
    return @($State.CompletedSubscriptionIds)
}

function Get-FailedAttempts
{
    param([string]$Path, [string]$Tenant, $BlobContext = $null, [string]$BlobContainer = $null, [string]$BlobName = $null,
        $State = $null)

    $State = Resolve-ResumeState -Path $Path -Tenant $Tenant -BlobContext $BlobContext -BlobContainer $BlobContainer -BlobName $BlobName `
        -State $State -StateSupplied:$PSBoundParameters.ContainsKey('State')

    if ($null -eq $State -or $null -eq $State.FailedAttempts) { return @() }
    return @($State.FailedAttempts | Where-Object { $null -ne $_ })
}

function Get-StartSnapshot
{
    param([string]$Path, [string]$Tenant, $BlobContext = $null, [string]$BlobContainer = $null, [string]$BlobName = $null,
        $State = $null)

    $State = Resolve-ResumeState -Path $Path -Tenant $Tenant -BlobContext $BlobContext -BlobContainer $BlobContainer -BlobName $BlobName `
        -State $State -StateSupplied:$PSBoundParameters.ContainsKey('State')

    if ($null -eq $State) { return $null }
    return $State.EnumeratedAtStart
}

function Save-CompletedSubscriptionIds
{
    # -Reports is the report each completed subscription recorded, as { Name, Id, Count, Zip }. A
    # -Resume run skips those subscriptions and ships these archives in their place, so the state keeps
    # one per completed id (the last one given wins) and none for an id that is no longer completed.
    # Omitted, the state carries no Reports at all.
    param([string]$Path, [string]$Tenant, [string[]]$Ids, $FailedAttempts = @(),
        $StartSnapshot = $null,
        $Reports = $null,
        $BlobContext = $null, [string]$BlobContainer = $null, [string]$BlobName = $null)

    $StateMap = [ordered]@{
        TenantID                 = $Tenant
        CompletedSubscriptionIds = @($Ids)
        FailedAttempts           = @($FailedAttempts | Where-Object { $null -ne $_ })
        LastUpdated              = (Get-Date).ToString('o')
    }
    if ($null -ne $StartSnapshot) { $StateMap['EnumeratedAtStart'] = $StartSnapshot }
    if ($null -ne $Reports)
    {
        $LatestReport = @{}
        foreach ($Report in @($Reports | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_.Id) }))
        {
            # Read only once a Count property is confirmed: without one PowerShell reports its intrinsic count of 1.
            $ReportCount = if ($null -ne $Report.PSObject.Properties['Count']) { [int]$Report.Count } else { 0 }
            $LatestReport[[string]$Report.Id] = [pscustomobject]@{ Name = [string]$Report.Name; Id = [string]$Report.Id; Count = $ReportCount; Zip = [string]$Report.Zip }
        }
        $StateMap['Reports'] = @(foreach ($Id in @($Ids)) { if ($LatestReport.ContainsKey([string]$Id)) { $LatestReport[[string]$Id] } })
    }
    $State = [pscustomobject]$StateMap
    try
    {
        $TmpPath = "$Path.tmp"
        $State | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $TmpPath -Encoding utf8
        [System.IO.File]::Move($TmpPath, $Path, $true)
    }
    catch
    {
        Write-Host ("WARNING: Failed to persist resume state to {0}: {1}" -f $Path, $_) -ForegroundColor Yellow
        Remove-Item -LiteralPath "$Path.tmp" -Force -ErrorAction SilentlyContinue
        return
    }
    if ($BlobContext -and $BlobContainer -and $BlobName)
    {
        $null = Save-StateBlob -Context $BlobContext -Container $BlobContainer -BlobName $BlobName -File $Path -BestEffort
    }
}

function Get-RdaMetricsRetryReason
{
    # The reason to put a subscription in the retry list when its inventory completed but its metrics
    # did not. -Entries is $Global:MetricsFailedSubs and -Before is how many entries that list held
    # immediately BEFORE ResourceInventory.ps1 was called for this subscription, so an entry is
    # attributed to the call that wrote it and never by its Id: the metrics phase writes '(unknown)'
    # when no metric definition named a subscription, a standalone phase can cover several, and under
    # Runspace isolation each stream reads its own list. Returns $null when that call appended nothing,
    # which is the ordinary case and leaves every caller on its existing path.
    [CmdletBinding()]
    [OutputType([string])]
    param([object]$Entries, [int]$Before = 0)
    $List = @($Entries | Where-Object { $null -ne $_ })
    $From = if ($Before -gt 0) { $Before } else { 0 }
    if ($List.Count -le $From) { return $null }
    $Messages = @($List | Select-Object -Skip $From | ForEach-Object { [string]$_.Message } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    if ($Messages.Count -eq 0) { $Messages = @('the metrics phase reported no detail.') }
    return ('Metrics incomplete: {0}' -f ($Messages -join ' '))
}

function Get-RdaInventoryRerunCommand
{
    # One pasteable line that re-runs ResourceInventory.ps1 for ONE subscription, for an operator whose
    # metrics were left incomplete. It is built from the SAME passthrough table the wrapper hands the
    # inner script, never from $PSBoundParameters or $MyInvocation.Line: those carry whatever was typed,
    # which on a standalone run can include a secret, and the wrapper's own switches are not the inner
    # script's. -RunAllSubs is never added: the line is a single-subscription run on its own.
    # Returns $null rather than a line it cannot build correctly: an unparseable subscription id, or a
    # value that would print a credential.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$ScriptPath,
        [string]$TenantId,
        [string]$SubscriptionId,
        [object]$Passthrough,
        [string]$DictionaryPath
    )
    if ([string]::IsNullOrWhiteSpace($ScriptPath) -or [string]::IsNullOrWhiteSpace($TenantId)) { return $null }
    $ParsedId = [guid]::Empty
    if (-not [guid]::TryParse([string]$SubscriptionId, [ref]$ParsedId)) { return $null }
    # TryParse also takes the braced, parenthesised and undashed spellings, but ResourceInventory.ps1
    # validates -SubscriptionID against the dashed pattern, so the PARSED value is emitted rather than
    # whatever was handed in: otherwise a line could print that dies at parameter binding. 'D' is the
    # dashed lower-case form.
    $SubscriptionId = $ParsedId.ToString('D')
    # Single quotes, with any quote in the value doubled: a path with a space, an apostrophe, a $ or a
    # backtick then survives being pasted into a new session unchanged.
    $Quote = { param($Value) "'" + ([string]$Value -replace "'", "''") + "'" }
    $Parts = @(
        ('& {0}' -f (& $Quote $ScriptPath))
        ('-TenantID {0}' -f (& $Quote $TenantId))
        ('-SubscriptionID {0}' -f (& $Quote $SubscriptionId)))
    $Table = if ($Passthrough -is [System.Collections.IDictionary]) { $Passthrough } else { @{} }
    foreach ($Key in @($Table.Keys | ForEach-Object { [string]$_ } | Sort-Object))
    {
        if ($Key -eq 'RunAllSubs' -or $Key -eq 'ObfuscationDictionary') { continue }
        $Value = $Table[$Key]
        # By name as well as by type: no passthrough carries a credential today, and the wrapper has no
        # -Appid or -Secret of its own, but whoever adds one next will not necessarily make it a
        # SecureString, and a plain string would otherwise be printed verbatim. 'token' and 'key' count only
        # as a whole name or a credential-shaped ending: as bare substrings they also caught the real switch
        # -SkipFoundryTokens, and every run with it printed no re-run line at all.
        if ($Key -match '(?i)secret|password|credential|appid|^token$|(access|refresh|bearer|auth|id|sas)token$|key$') { return $null }
        if ($Value -is [System.Security.SecureString] -or $Value -is [System.Management.Automation.PSCredential]) { return $null }
        if ($Value -is [bool] -or $Value -is [System.Management.Automation.SwitchParameter])
        {
            # A switch is written bare when it is on and left out when it is off, so -Debug:$false and
            # the like never appear on a line an operator is told to paste.
            if ([bool]$Value) { $Parts += ('-{0}' -f $Key) }
            continue
        }
        if ($Value -is [int] -or $Value -is [long] -or $Value -is [double])
        {
            $Parts += ('-{0} {1}' -f $Key, ([string]$Value))
            continue
        }
        if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string])
        {
            $Items = @($Value | Where-Object { $null -ne $_ } | ForEach-Object { & $Quote $_ })
            if ($Items.Count -eq 0) { continue }
            $Parts += ('-{0} {1}' -f $Key, ($Items -join ','))
            continue
        }
        if ([string]::IsNullOrEmpty([string]$Value)) { continue }
        $Parts += ('-{0} {1}' -f $Key, (& $Quote $Value))
    }
    if ($Table['Obfuscate'])
    {
        # Only an obfuscated run needs it, and only it can use it: without the dictionary of the original
        # run the re-run mints its own tokens and the two reports cannot be lined up. A real path is a
        # quoted literal; the placeholder is deliberately NOT quoted, because '<' is reserved in
        # PowerShell, so pasting the line unchanged is a parse error rather than a run against a path
        # that is not there, which the operator would only notice from the inner script's own complaint.
        if ([string]::IsNullOrWhiteSpace($DictionaryPath))
        {
            $Parts += '-ObfuscationDictionary <the ObfuscationDictionary_*.json this run wrote for that subscription>'
        }
        else
        {
            $Parts += ('-ObfuscationDictionary {0}' -f (& $Quote $DictionaryPath))
        }
    }
    return ($Parts -join ' ')
}

function Add-FailedAttempt
{
    param(
        [object]$Existing,
        [string]$Id,
        [string]$Name,
        [string]$Reason
    )
    $List = @($Existing | Where-Object { $_ })
    $ExistingEntry = $List | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if ($null -ne $ExistingEntry)
    {
        $List = @($List | Where-Object { $_.Id -ne $Id })
        $Attempts = if ($ExistingEntry.Attempts) { [int]$ExistingEntry.Attempts + 1 } else { 2 }
    }
    else
    {
        $Attempts = 1
    }
    $List += [pscustomobject]@{
        Id           = $Id
        Name         = $Name
        LastFailedAt = (Get-Date).ToString('o')
        Reason       = $Reason
        Attempts     = $Attempts
    }
    return $List
}

function Remove-FailedAttempt
{
    param(
        [object]$Existing,
        [string]$Id
    )
    return @($Existing | Where-Object { $_ -and $_.Id -ne $Id })
}

function Get-StreamStateFilePath
{
    # The one spelling of a stream worker's local state file. Get-StreamResumeStateFiles lists the
    # same names by pattern.
    param(
        [Parameter(Mandatory = $true)][string]$InventoryRoot,
        [Parameter(Mandatory = $true)][string]$Tenant,
        [Parameter(Mandatory = $true)][string]$StreamId
    )
    return (Join-Path $InventoryRoot (".resume-state-{0}-stream-{1}.json" -f $Tenant, $StreamId))
}

function Get-StreamResumeStateFiles
{
    param(
        [Parameter(Mandatory = $true)][string]$InventoryRoot,
        [Parameter(Mandatory = $true)][string]$Tenant
    )
    return @(Get-ChildItem -LiteralPath $InventoryRoot -Filter (".resume-state-{0}-stream-*.json" -f $Tenant) -File -Force -ErrorAction SilentlyContinue)
}

function Get-StreamImportMarkerPath
{
    # The file a stream worker creates once Import-AzContext has succeeded, next to the snapshot it
    # imported. The parent removes the snapshot as soon as every stream has left a marker or ended, so
    # the token cache inside the snapshot is on disk only for the seconds the workers need it.
    param(
        [Parameter(Mandatory = $true)][string]$AzContextPath,
        [Parameter(Mandatory = $true)][string]$StreamId
    )
    return ('{0}.imported-{1}' -f $AzContextPath, $StreamId)
}

function Get-StaleAzContextSnapshot
{
    # Az context snapshots in the inventory root. Called before this run writes its own, so anything
    # found belongs to an earlier run that did not reach its cleanup, or to another wrapper running
    # against the same folder right now. The caller only reports them; it never deletes them.
    param(
        [Parameter(Mandatory = $true)][string]$InventoryRoot
    )
    return @(Get-ChildItem -LiteralPath $InventoryRoot -Filter '.rda-stream-azcontext-*.json' -File -Force -ErrorAction SilentlyContinue)
}

function Test-AzContextSnapshotReleasable
{
    # True once no stream can still need the snapshot: each stream has either imported it (its marker
    # exists) or its job has already ended, so it will never import. A stream that is still running
    # without a marker keeps the snapshot in place. The two arrays are indexed by stream.
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][bool[]]$MarkerPresent,
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()][AllowEmptyString()][string[]]$JobState
    )
    # A missing or blank job state keeps the snapshot, like any other state that is not final.
    if ($null -eq $JobState) { return $false }
    if ($MarkerPresent.Count -eq 0) { return $false }
    # The two arrays describe the same streams; a mismatch means a stream is unaccounted for.
    if ($JobState.Count -ne $MarkerPresent.Count) { return $false }
    $EndedStates = @('Completed', 'Failed', 'Stopped')
    for ($i = 0; $i -lt $MarkerPresent.Count; $i++)
    {
        if ($MarkerPresent[$i]) { continue }
        if ([string]$JobState[$i] -notin $EndedStates) { return $false }
    }
    return $true
}

function Merge-FailedAttempts
{
    param(
        [object]$ExistingFailedAttempts,
        [object]$StreamFailedAttempts,
        [object]$CompletedIds
    )
    $CompletedIds = @($CompletedIds)
    if (@($StreamFailedAttempts).Count -eq 0)
    {
        return @($ExistingFailedAttempts | Where-Object { $_ -and -not ($CompletedIds -contains $_.Id) })
    }
    $Merged = @($ExistingFailedAttempts) + @($StreamFailedAttempts)
    $ById = $Merged | Where-Object { $_ } | Group-Object -Property Id
    $Reconciled = @()
    foreach ($g in $ById)
    {
        if ($CompletedIds -contains $g.Name) { continue }
        $Best = $g.Group | Sort-Object -Property @{Expression = { [datetime]($_.LastFailedAt) } } -Descending | Select-Object -First 1
        $Reconciled += $Best
    }
    return $Reconciled
}

function Get-AzPsSignedInTenant
{
    try
    {
        $Ctx = Get-AzContext -ErrorAction Stop
        if ($null -eq $Ctx -or $null -eq $Ctx.Account) { return $null }
        return $Ctx.Tenant.Id
    }
    catch
    {
        return $null
    }
}

function Test-AzPsTokenSilent
{
    param([Parameter(Mandatory = $true)][string]$Tenant)
    $Warnings = @()
    try
    {
        $Token = Get-AzAccessToken -TenantId $Tenant -ErrorAction Stop -WarningVariable warnings -WarningAction SilentlyContinue
        if ($null -eq $Token -or [string]::IsNullOrWhiteSpace($Token.Token)) { return $false }
        $RealWarnings = @($Warnings | Where-Object {
                $Msg = $_.Message
                -not (
                    $Msg -match 'Get-AzAccessToken\s*:?\s*Upcoming breaking changes' -or
                    $Msg -match 'AsSecureString' -or
                    $Msg -match 'plain string token output is deprecated'
                )
            })
        if ($RealWarnings.Count -gt 0) { return $false }
        return $true
    }
    catch
    {
        return $false
    }
}

function Get-WrapperExitCode
{
    param(
        [bool]$AuthSkipped,
        [bool]$CollectorsFailed
    )
    if ($AuthSkipped -and $CollectorsFailed) { return 5 }
    if ($AuthSkipped) { return 3 }
    if ($CollectorsFailed) { return 4 }
    return 0
}

function Write-Stream
{
    param([string]$Message, [string]$Color = 'Gray')
    Write-Host ("{0} {1}" -f $Tag, $Message) -ForegroundColor $Color
}

function Read-StreamState
{
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @{ Completed = @(); Failed = @() } }
    try
    {
        $Obj = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        return @{
            Completed = if ($null -eq $Obj.Completed) { @() } else { @($Obj.Completed) }
            Failed    = if ($null -eq $Obj.FailedAttempts) { @() } else { @($Obj.FailedAttempts | Where-Object { $null -ne $_ }) }
        }
    }
    catch
    {
        Write-Stream ("WARNING: could not read stream state at {0}: {1}" -f $Path, $_.Exception.Message) 'Yellow'
        return @{ Completed = @(); Failed = @() }
    }
}

function Write-StreamState
{
    # -Reports is this run's finished subscriptions as { Name, Id, Count, Zip }: written with each
    # completion, so a parent whose worker died before its summary can still ship what it finished.
    param([string]$Path, [string[]]$Completed, $FailedAttempts = @(), $Reports = @(),
        $BlobContext = $null, [string]$BlobContainer = $null, [string]$BlobName = $null)
    $Tmp = "$Path.tmp"
    try
    {
        $Json = @{
            Tenant         = $TenantID
            StreamId       = $StreamId
            Completed      = $Completed
            FailedAttempts = @($FailedAttempts | Where-Object { $null -ne $_ })
            Reports        = @($Reports | Where-Object { $null -ne $_ })
        } | ConvertTo-Json -Depth 4
        Set-Content -LiteralPath $Tmp -Value $Json -Encoding utf8 -ErrorAction Stop
        [System.IO.File]::Move($Tmp, $Path, $true)
    }
    catch
    {
        Remove-Item -LiteralPath $Tmp -Force -ErrorAction SilentlyContinue
        Write-Stream ("WARNING: failed to persist stream state to {0}: {1}" -f $Path, $_.Exception.Message) 'Yellow'
        return
    }
    if ($BlobContext -and $BlobContainer -and $BlobName)
    {
        $null = Save-StateBlob -Context $BlobContext -Container $BlobContainer -BlobName $BlobName -File $Path -BestEffort
    }
}

function Expand-ServiceFilter
{
    param([string[]]$Service)
    if (-not $Service) { return @() }
    return @(
        $Service |
            ForEach-Object { $_ -split ',' } |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ } |
            Select-Object -Unique
    )
}

function Get-ConsumptionAccessOutcome
{
    param([string]$ErrorMessage)
    if ([string]::IsNullOrWhiteSpace($ErrorMessage)) { return 'Ok' }
    if (Test-RdaConsumptionDenial -ErrorMessage $ErrorMessage)
    {
        return 'Denied'
    }
    return 'Unavailable'
}

function Test-ConsumptionAccess
{
    # Get-UsageAggregates: see the suppression note at the top of ResourceInventory.ps1.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingCmdletAliases', 'Get-UsageAggregates', Justification = 'Only name that exists on Az.Billing before and after 2.1.0')]
    param([Parameter(Mandatory = $true)][string]$SubscriptionId)

    # Scoped to the probe subscription for this function only (Get-RdaSubscriptionProfile), so the
    # probe moves neither the process's current context nor the operator's saved default subscription.
    $PSDefaultParameterValues = [System.Management.Automation.DefaultParameterDictionary]::new($PSDefaultParameterValues)
    try
    {
        $PSDefaultParameterValues['*:DefaultProfile'] = Get-RdaSubscriptionProfile -SubscriptionId $SubscriptionId
    }
    catch
    {
        return [pscustomobject]@{
            Outcome = 'Unavailable'
            Detail  = ('could not scope the Az calls to the probe subscription: {0}' -f $_.Exception.Message)
        }
    }

    $ProbeEnd = [DateTime]::UtcNow.Date
    $ProbeStart = $ProbeEnd.AddDays(-1)
    try
    {
        $null = Get-UsageAggregates -ReportedStartTime $ProbeStart -ReportedEndTime $ProbeEnd -AggregationGranularity 'Daily' -ErrorAction Stop
        return [pscustomobject]@{ Outcome = 'Ok'; Detail = $null }
    }
    catch
    {
        return [pscustomobject]@{
            Outcome = (Get-ConsumptionAccessOutcome -ErrorMessage $_.Exception.Message)
            Detail  = $_.Exception.Message
        }
    }
}

function Test-MetricsAccess
{
    param([Parameter(Mandatory = $true)][string]$SubscriptionId)

    $Query = "resources | where subscriptionId =~ '{0}' and type in~ ('microsoft.compute/virtualmachines','microsoft.storage/storageaccounts','microsoft.sql/servers/databases','microsoft.web/sites','microsoft.network/publicipaddresses') | project id | take 1" -f $SubscriptionId
    try
    {
        $ProbeResponse = Search-AzGraph -Query $Query -Subscription $SubscriptionId -First 1 -ErrorAction Stop
        $Probe = if ($null -eq $ProbeResponse) { @() } else { @($ProbeResponse) }
    }
    catch
    {
        return [pscustomobject]@{ Outcome = 'Unavailable'; Detail = ('could not locate a metric-eligible resource: {0}' -f $_.Exception.Message) }
    }
    if ($Probe.Count -eq 0 -or [string]::IsNullOrWhiteSpace([string]$Probe[0].id))
    {
        return [pscustomobject]@{ Outcome = 'NoResource'; Detail = 'no VM, storage account, SQL database, web app or public IP to probe' }
    }
    $ResourceId = [string]$Probe[0].id
    try
    {
        $null = Get-AzMetricDefinition -ResourceId $ResourceId -ErrorAction Stop -WarningAction SilentlyContinue | Select-Object -First 1
        return [pscustomobject]@{ Outcome = 'Ok'; Detail = $null }
    }
    catch
    {
        $Outcome = if (Test-RdaConsumptionDenial -ErrorMessage $_.Exception.Message) { 'Denied' } else { 'Unavailable' }
        return [pscustomobject]@{ Outcome = $Outcome; Detail = ('{0} (probed {1})' -f $_.Exception.Message, $ResourceId) }
    }
}

function Format-PreflightMatrix
{
    param([Parameter(Mandatory = $true)]$Rows)

    $Rows = @($Rows)
    $Lines = [System.Collections.Generic.List[string]]::new()
    $Lines.Add('Permission matrix (per subscription):')
    $Lines.Add(('  {0,-40} {1,-13} {2,-16} {3,-13}' -f 'Subscription', 'Reader', 'Cost Mgmt', 'Monitoring'))
    $Lines.Add('  ' + ('-' * 86))
    $Blocking = $false
    $Hints = [System.Collections.Generic.List[string]]::new()
    foreach ($R in $Rows)
    {
        $Name = [string]$R.Name
        if ($Name.Length -gt 40) { $Name = $Name.Substring(0, 37) + '...' }
        $Lines.Add(('  {0,-40} {1,-13} {2,-16} {3,-13}' -f $Name, $R.Reader, $R.CostManagement, $R.Monitoring))
        if ($R.Reader -eq 'Denied') { $Blocking = $true; $Hints.Add(('Grant Reader on {0} ({1}) - or Reader at the tenant-root management group, which inherits to every subscription.' -f $R.Name, $R.Id)) }
        if ($R.Reader -eq 'Unavailable') { $Blocking = $true; $Hints.Add(('Reader on {0} ({1}) could not be verified; the real run stops on this unless -AllowPartialAccess is passed. Re-check the sign-in/token and re-run.' -f $R.Name, $R.Id)) }
        if ($R.CostManagement -eq 'Denied') { $Blocking = $true; $Hints.Add(('Grant Cost Management Reader on {0} ({1}) (or Billing Reader on the billing scope), or run with -SkipConsumption.' -f $R.Name, $R.Id)) }
        if ($R.Monitoring -eq 'Denied') { $Blocking = $true; $Hints.Add(('Grant Monitoring Reader on {0} ({1}), or run with -SkipMetrics.' -f $R.Name, $R.Id)) }
    }
    $Lines.Add('')
    $Lines.Add('  Ok = verified   Denied = RBAC denial (blocks the run)   Unavailable = could not verify (token/transient): Cost Mgmt / Monitoring retry per subscription in a real run, an unverifiable Reader stops it')
    $Lines.Add('  NoResource = nothing metric-eligible to probe   Skipped = phase not requested (-SkipMetrics / -SkipConsumption)')
    if ($Hints.Count -gt 0)
    {
        $Lines.Add('')
        $Lines.Add('To fix before running:')
        foreach ($H in ($Hints | Select-Object -Unique)) { $Lines.Add('  - ' + $H) }
    }
    return [pscustomobject]@{ Lines = @($Lines); Blocking = $Blocking }
}

function Get-InventoryExitCodeMeaning
{
    # ResourceInventory.ps1's own exit codes, named, so a failure line cannot be misread as one of the
    # WRAPPER's codes (its 3 means a requested data phase was skipped for auth or left incomplete because
    # the metric worker pool could not open; the inner 3 means an aborted collection).
    [CmdletBinding()]
    [OutputType([string])]
    param([int]$Code)

    switch ($Code)
    {
        1 { return 'a hard pre-flight or setup failure' }
        2 { return 'collection finished but the report archive could not be written' }
        3 { return 'collection was aborted by the collector circuit breaker; the inventory is partial' }
        default { return 'an unexpected failure' }
    }
}

function Get-RdaDeadStreamReports
{
    # What a stream worker that died before writing its summary had finished, read from the reports
    # it recorded in its state file with each completion. A worker starts its list empty, so a state
    # file written during this run holds only this run's reports; one last written before the run
    # started is a leftover and holds none. Only the stream's own slice counts, and an archive written
    # before the run started is not this run's report. A recorded archive that is gone is still
    # returned: the verification step then names it as missing instead of the bundle going without it.
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)][string]$StatePath,
        [string[]]$SliceIds = @(),
        [Parameter(Mandatory = $true)][datetime]$SinceTime,
        [string]$StreamLabel = 'stream'
    )
    $NoneText = "[{0}] its state file records no subscription it finished in this run, so none of its reports is in the bundle." -f $StreamLabel
    # Compared in UTC, so a run that spans a clock change does not take this run's files for older ones.
    $SinceUtc = $SinceTime.ToUniversalTime()
    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf))
    {
        Write-Host ("[{0}] left no state file at {1}, so none of its reports is in the bundle." -f $StreamLabel, $StatePath) -ForegroundColor Yellow
        return @()
    }
    # -Force: the state file is a dotfile, which Get-Item does not see without it on Linux and macOS.
    if ((Get-Item -LiteralPath $StatePath -Force).LastWriteTimeUtc -lt $SinceUtc)
    {
        Write-Host $NoneText -ForegroundColor Yellow
        return @()
    }
    try
    {
        $State = Get-Content -LiteralPath $StatePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch
    {
        Write-Warning ("[{0}] could not read its state file {1}: {2}. Whatever that stream finished is not in the bundle." -f $StreamLabel, $StatePath, $_.Exception.Message)
        return @()
    }
    $Recovered = @()
    foreach ($Report in @($State.Reports | Where-Object { $null -ne $_ }))
    {
        $ReportId = [string]$Report.Id
        if ([string]::IsNullOrWhiteSpace($ReportId) -or $SliceIds -notcontains $ReportId) { continue }
        $ReportZip = [string]$Report.Zip
        if (-not [string]::IsNullOrWhiteSpace($ReportZip) -and (Test-Path -LiteralPath $ReportZip -PathType Leaf))
        {
            if ((Get-Item -LiteralPath $ReportZip).LastWriteTimeUtc -lt $SinceUtc)
            {
                Write-Warning ("[{0}] recorded subscription {1} with an archive written before this run started ({2}), so it is not taken as this run's report and is not in the bundle." -f $StreamLabel, $ReportId, $ReportZip)
                continue
            }
        }
        $Recovered += [pscustomobject]@{ Name = [string]$Report.Name; Id = $ReportId; Count = [int]$Report.Count; Zip = $ReportZip }
    }
    if ($Recovered.Count -eq 0) { Write-Host $NoneText -ForegroundColor Yellow }
    else
    {
        Write-Host ("[{0}] recovered {1} finished subscription report(s) from its state file: {2}" -f $StreamLabel, $Recovered.Count, (@($Recovered | ForEach-Object { $_.Name }) -join ', ')) -ForegroundColor Yellow
        Write-Host ("[{0}]   Their billing record counts and per-phase health were in the summary this stream did not write, so the run totals and health below leave them out." -f $StreamLabel) -ForegroundColor Yellow
    }
    return $Recovered
}

function Get-RdaFailedSinceIds
{
    # The ids of failure records written at or after -SinceTime, that is, failures from this run. A
    # failure in this run outranks an older completion of the same subscription, which this run
    # collected again. A record whose time cannot be read is not counted.
    [CmdletBinding()]
    [OutputType([object[]])]
    param([object[]]$FailedAttempts = @(), [Parameter(Mandatory = $true)][datetime]$SinceTime)
    $SinceUtc = $SinceTime.ToUniversalTime()
    $Ids = @()
    foreach ($Attempt in @($FailedAttempts | Where-Object { $null -ne $_ }))
    {
        $At = [datetimeoffset]::MinValue
        $Raw = $Attempt.LastFailedAt
        $Parsed = if ($Raw -is [datetime]) { $At = [datetimeoffset]$Raw.ToUniversalTime(); $true }
        else { [datetimeoffset]::TryParse([string]$Raw, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$At) }
        if ($Parsed -and $At.UtcDateTime -ge $SinceUtc -and -not [string]::IsNullOrWhiteSpace([string]$Attempt.Id)) { $Ids += [string]$Attempt.Id }
    }
    return @($Ids | Select-Object -Unique)
}

function Test-RdaResumeStateHolds
{
    # Whether a saved resume state carries every record recovered from stranded stream state: each
    # completed id as completed, and each failed id as failed or completed (a completion elsewhere
    # supersedes a failure). The stranded copies are removed only when this holds.
    [CmdletBinding()]
    [OutputType([bool])]
    param($State, [string[]]$CompletedIds = @(), [string[]]$FailedIds = @())
    $SavedCompleted = if ($null -ne $State) { @($State.CompletedSubscriptionIds | ForEach-Object { [string]$_ }) } else { @() }
    $SavedFailed = if ($null -ne $State) { @($State.FailedAttempts | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_.Id }) } else { @() }
    foreach ($Id in @($CompletedIds)) { if ($SavedCompleted -notcontains $Id) { return $false } }
    foreach ($Id in @($FailedIds)) { if ($SavedCompleted -notcontains $Id -and $SavedFailed -notcontains $Id) { return $false } }
    return $true
}

function Remove-RdaMergedStreamState
{
    # Removes per-stream state copies, local files and blobs, once the saved resume state is confirmed
    # to hold what was read from them. Pass only the copies that were read: one that could not be read
    # added nothing to the ids checked here, so removing it would lose what it recorded. Saving the
    # resume state only warns when it fails, which is why the saved copy is read back rather than
    # trusted. The blob is checked on its own because its mirror can fail after the local file saved.
    # -KeptNote finishes the warning printed when copies are kept, since what happens to them next
    # differs between the start and the end of a run.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ResumeStateFile,
        [Parameter(Mandatory = $true)][string]$Tenant,
        [string[]]$CompletedIds = @(),
        [string[]]$FailedIds = @(),
        [object[]]$StreamFiles = @(),
        [string[]]$StreamBlobNames = @(),
        [string]$KeptNote = 'They are merged again on the next start.',
        $BlobContext = $null, [string]$BlobContainer = $null, [string]$BlobName = $null
    )
    $Files = @($StreamFiles | Where-Object { $null -ne $_ })
    if ($Files.Count -gt 0)
    {
        # Read directly: Get-ResumeStateObject would report an unreadable file as "starting fresh".
        $LocalState = $null
        try
        {
            $LocalState = Get-Content -LiteralPath $ResumeStateFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($LocalState.TenantID -ne $Tenant) { $LocalState = $null }
        }
        catch { Write-Verbose ("Could not read back the resume state at {0}: {1}" -f $ResumeStateFile, $_.Exception.Message) }
        if (Test-RdaResumeStateHolds -State $LocalState -CompletedIds $CompletedIds -FailedIds $FailedIds)
        {
            foreach ($File in $Files)
            {
                try { Remove-Item -LiteralPath $File.FullName -Force -ErrorAction Stop }
                catch { Write-Verbose ("Could not remove stream resume file {0}: {1}" -f $File.FullName, $_.Exception.Message) }
            }
        }
        else
        {
            Write-Warning ("The resume state at {0} does not hold everything {1} per-stream state file(s) recorded, so they are kept. {2}" -f $ResumeStateFile, $Files.Count, $KeptNote)
        }
    }
    $Blobs = @($StreamBlobNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($Blobs.Count -gt 0 -and $BlobContext -and $BlobContainer -and $BlobName)
    {
        $BlobState = Read-StateBlob -Context $BlobContext -Container $BlobContainer -BlobName $BlobName
        if (Test-RdaResumeStateHolds -State $BlobState -CompletedIds $CompletedIds -FailedIds $FailedIds)
        {
            foreach ($Blob in $Blobs)
            {
                try { Remove-AzStorageBlob -Container $BlobContainer -Blob $Blob -Context $BlobContext -Force -ErrorAction Stop }
                catch { Write-Verbose ("Could not remove per-stream state blob {0}: {1}" -f $Blob, $_.Exception.Message) }
            }
        }
        else
        {
            Write-Warning ("The resume state blob {0} does not hold everything {1} per-stream state blob(s) recorded, so they are kept. {2}" -f $BlobName, $Blobs.Count, $KeptNote)
        }
    }
}

function Select-RdaStrandedReports
{
    # The reports a per-stream state copy left by an interrupted run may contribute to the resume
    # state: only those for ids that same copy lists as completed. A copy can carry a report for a
    # subscription it had NOT finished - one whose metrics are still owed is recorded with its report
    # but kept out of Completed - and folding that in would let a partial report replace a complete
    # one an earlier run recorded.
    [CmdletBinding()]
    [OutputType([object[]])]
    param($Copy)
    if ($null -eq $Copy) { return @() }
    $CopyCompleted = @($Copy.Completed | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
    return @($Copy.Reports | Where-Object { $null -ne $_ -and $CopyCompleted -contains [string]$_.Id })
}

function Select-RdaShippableReports
{
    # What a run may put in its consolidated bundle: exactly the archives the completed subscriptions
    # recorded, and their report folders, both taken from the record so neither can ship without the
    # other. Every other report folder the run left under the inventory root stays out and is named:
    # a partial inventory whose aborted marker could not be written or whose archive could not be
    # removed, a subscription that failed, or another run's output. A stream worker that dies before
    # its summary has recorded each report it finished in its state file, which the wrapper reads
    # back; a report whose record never landed stays out and its folder is named. An entry with no
    # usable path ships nothing; one whose archive is gone keeps its folder here, and the wrapper's
    # verification stops the run naming it. Test-RdaCollectionAborted comes from
    # Functions/Common.Functions.ps1.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InventoryRoot,
        [Parameter(Mandatory = $true)][datetime]$SinceTime,
        [object[]]$ProcessedSubscriptions = @()
    )

    $Processed = @(@($ProcessedSubscriptions) | Where-Object { $null -ne $_ })

    $ListErrors = $null
    $RunFolders = @(Get-ChildItem -LiteralPath $InventoryRoot -Directory -Filter 'ResourcesReport*' -ErrorAction SilentlyContinue -ErrorVariable ListErrors |
            Where-Object { $_.LastWriteTime -ge $SinceTime })
    if (@($ListErrors).Count -gt 0)
    {
        Write-Warning ("Could not list the report folders under {0}: {1}. The list of report folders left out of the bundle may be incomplete." -f $InventoryRoot, $ListErrors[0].Exception.Message)
    }

    $Folders = @()
    $Archives = @()
    $LeftOut = @()
    $RecordedNames = @{}
    foreach ($Entry in $Processed)
    {
        $Dir = [System.IO.Path]::GetDirectoryName([string]$Entry.Zip)
        $Name = [System.IO.Path]::GetFileName($Dir)
        if ([string]::IsNullOrWhiteSpace($Name))
        {
            Write-Warning ("Subscription {0} completed but recorded no usable report path ('{1}'), so its report is not in the bundle." -f $Entry.Id, $Entry.Zip)
            continue
        }
        $FirstForFolder = -not $RecordedNames.ContainsKey($Name)
        $RecordedNames[$Name] = $true
        if (Test-RdaCollectionAborted -Folder $Dir)
        {
            if ($FirstForFolder) { $LeftOut += [pscustomobject]@{ Path = $Dir; Name = $Name; Reason = 'Aborted' } }
            continue
        }
        if ($FirstForFolder -and (Test-Path -LiteralPath $Dir -PathType Container)) { $Folders += Get-Item -LiteralPath $Dir }
        if (Test-Path -LiteralPath ([string]$Entry.Zip) -PathType Leaf) { $Archives += [string]$Entry.Zip }
    }
    foreach ($Folder in $RunFolders)
    {
        if ($RecordedNames.ContainsKey($Folder.Name)) { continue }
        $Reason = if (Test-RdaCollectionAborted -Folder $Folder.FullName) { 'Aborted' } else { 'NotRecorded' }
        $LeftOut += [pscustomobject]@{ Path = $Folder.FullName; Name = $Folder.Name; Reason = $Reason }
    }

    return [pscustomobject]@{
        Archives = $Archives
        Folders  = $Folders
        LeftOut  = $LeftOut
    }
}

function Get-RdaReportArchiveMode
{
    # Whether a per-subscription report archive is obfuscated, read from the first line of the
    # Diagnostics_*.log inside it, which Write-RdaShareableDiagnosticsLog
    # (Functions/ResourceInventory.Functions.ps1) writes as the header for its mode. Returns
    # 'Obfuscated' or 'Default', or $null when the archive cannot be read or holds no header this
    # recognises, so the caller refuses rather than guesses.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    $Header = $null
    try
    {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $Archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
        try
        {
            # Top level only: the report writes its diagnostics log beside the inventory, not in a folder.
            $DiagEntries = @($Archive.Entries | Where-Object { $_.FullName -notmatch '[\\/]' -and $_.Name -like 'Diagnostics_*.log' })
            if ($DiagEntries.Count -ne 1) { return $null }
            $Reader = [System.IO.StreamReader]::new($DiagEntries[0].Open())
            try { $Header = $Reader.ReadLine() }
            finally { $Reader.Dispose() }
        }
        finally
        {
            $Archive.Dispose()
        }
    }
    catch
    {
        Write-Verbose ("Could not read the diagnostics header of {0}: {1}" -f $Path, $_.Exception.Message)
        return $null
    }

    $Header = ([string]$Header).Trim()
    if ($Header -ceq 'Resource Discovery for Azure - shareable diagnostics (obfuscated run)') { return 'Obfuscated' }
    if ($Header -ceq 'Resource Discovery for Azure - diagnostics (default/non-obfuscated run)') { return 'Default' }
    return $null
}

function Get-RdaResumeCarriedReports
{
    # What a -Resume run ships for the subscriptions it skipped because an earlier run completed them:
    # the archive that run recorded for each one in the resume state (Save-CompletedSubscriptionIds
    # -Reports). Only the skipped subscriptions are looked up, so a subscription outside this run's
    # scope never ships, and only the one archive recorded per subscription, so an older copy never
    # does. An archive is carried only when it is usable, its report folder has no aborted-collection
    # marker, and its diagnostics header shows the same privacy mode as this run. Anything else is
    # returned under Missing with the reason, so the caller can say which reports the bundle lacks
    # instead of shipping a mixed or silently incomplete bundle. Test-ReportArchiveUsable and
    # Test-RdaCollectionAborted come from Functions/Common.Functions.ps1.
    [CmdletBinding()]
    param(
        [object[]]$SkippedSubscriptions = @(),
        [object[]]$Reports = @(),
        [bool]$Obfuscated = $false
    )

    $LatestReport = @{}
    foreach ($Report in @($Reports | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_.Id) }))
    {
        $LatestReport[[string]$Report.Id] = $Report
    }
    $WantedMode = if ($Obfuscated) { 'Obfuscated' } else { 'Default' }
    $ModeText = @{ Obfuscated = 'obfuscated'; Default = 'not obfuscated' }

    $Carried = @()
    $Missing = @()
    foreach ($Sub in @($SkippedSubscriptions | Where-Object { $null -ne $_ }))
    {
        $Id = [string]$Sub.Id
        $Report = if ($LatestReport.ContainsKey($Id)) { $LatestReport[$Id] } else { $null }
        $Zip = if ($null -ne $Report) { [string]$Report.Zip } else { '' }
        $Reason = $null
        if ([string]::IsNullOrWhiteSpace($Zip))
        {
            $Reason = 'the resume state records no report archive for it (state written by an older version of this tool)'
        }
        elseif (-not (Test-ReportArchiveUsable -Path $Zip))
        {
            $Reason = 'the archive recorded for it is missing or empty: {0}' -f $Zip
        }
        elseif (Test-RdaCollectionAborted -Folder ([System.IO.Path]::GetDirectoryName($Zip)))
        {
            $Reason = 'its report folder holds an aborted-collection marker: {0}' -f [System.IO.Path]::GetDirectoryName($Zip)
        }
        else
        {
            $Mode = Get-RdaReportArchiveMode -Path $Zip
            if ($null -eq $Mode)
            {
                $Reason = 'its archive does not show whether it is obfuscated, so it cannot be matched to this run: {0}' -f $Zip
            }
            elseif ($Mode -ne $WantedMode)
            {
                $Reason = 'its archive is {0} and this run is {1}, and one bundle never mixes the two: {2}' -f $ModeText[$Mode], $ModeText[$WantedMode], $Zip
            }
        }

        if ($null -eq $Reason)
        {
            $ReportCount = if ($null -ne $Report.PSObject.Properties['Count']) { [int]$Report.Count } else { 0 }
            $Carried += [pscustomobject]@{ Name = [string]$Sub.Name; Id = $Id; Count = $ReportCount; Zip = $Zip }
        }
        else
        {
            $Missing += [pscustomobject]@{ Name = [string]$Sub.Name; Id = $Id; Reason = $Reason }
        }
    }

    return [pscustomobject]@{
        Carried = $Carried
        Missing = $Missing
    }
}

function Get-RunSummaryLogContent
{
    param(
        [System.Collections.IDictionary]$InvocationParameters = @{},
        [string]$Version,
        [datetime]$StartTime,
        [datetime]$EndTime,
        [int]$Visible,
        [int]$Excluded,
        [int]$Eligible,
        [int]$Processed,
        [int]$Skipped,
        $EmptyNoAccess = @(),
        $EmptyGenuinelyEmpty = @(),
        $EmptyUndetermined = @(),
        $FailedSubscriptions = @(),
        # Why a report is missing, by class. Counts only, so they are safe in an obfuscated bundle; the
        # names are already in the failed-subscription detail of a non-obfuscated one.
        $CollectionAbortedSubs = @(),
        $ArchiveWriteFailures = @(),
        $CollectorFailures = @(),
        $MetricsFailedSubs = @(),
        $ConsumptionFailedSubs = @(),
        $MarketplaceFailedSubs = @(),
        $MemoryReadings = @(),
        [int]$ConsumptionRecordCount = 0,
        [int]$MarketplaceRecordCount = 0,
        # Rows FETCHED from the billing API. -1 = not supplied.
        [int]$ConsumptionRowsFetchedCount = -1,
        [int]$MetricsApiCallCount = 0,
        # Parallel streams that ended without a summary: their record counts and health are not in
        # the totals, so a zero-record total proves nothing.
        [int]$UnreportedStreamCount = 0,
        [bool]$ConsumptionRequested = $true,
        [bool]$MarketplaceRequested = $true,
        [bool]$MetricsRequested = $true,
        [int]$HostVCpu = 0,
        [double]$HostRamGB = 0,
        [int]$Streams = 0,
        [string]$StreamsSource,
        [int]$Concurrency = 0,
        [string]$ConcurrencySource,
        [switch]$Obfuscated
    )

    $ExcludedParamNames = @('TenantID', 'SubscriptionID', 'InventoryRoot')

    $SafeValueParamNames = @('ParallelStreams', 'ConcurrencyLimit', 'MetricsIntervalMinutes', 'MetricsLookbackDays')

    $NoAccess = @(@($EmptyNoAccess) | Where-Object { $null -ne $_ })
    $Empty = @(@($EmptyGenuinelyEmpty) | Where-Object { $null -ne $_ })
    $Undetermined = @(@($EmptyUndetermined) | Where-Object { $null -ne $_ })
    $Failed = @(@($FailedSubscriptions) | Where-Object { $null -ne $_ })
    $Collector = @(@($CollectorFailures) | Where-Object { $null -ne $_ })
    $Metrics = @(@($MetricsFailedSubs) | Where-Object { $null -ne $_ })
    # The two writers of this list record different problems, so they are counted and listed apart: an auth
    # skip needs a token, metrics left incomplete by a worker pool that would not open need memory. An entry
    # with no Cause was written before the field existed, when every entry was an auth skip, so it is one.
    $MetricsAuth = @($Metrics | Where-Object { [string]$_.Cause -ne 'pool' })
    $MetricsPool = @($Metrics | Where-Object { [string]$_.Cause -eq 'pool' })
    $Consumption = @(@($ConsumptionFailedSubs) | Where-Object { $null -ne $_ })
    $Marketplace = @(@($MarketplaceFailedSubs) | Where-Object { $null -ne $_ })

    $Lines = [System.Collections.Generic.List[string]]::new()
    $Lines.Add('Resource Discovery for Azure - run summary')
    if ($Obfuscated)
    {
        $Lines.Add('Obfuscated run: subscription names/ids and raw error text are omitted')
        $Lines.Add('(counts only) so this log is safe to share.')
    }
    else
    {
        $Lines.Add('Non-obfuscated run: contains real subscription names/ids.')
    }
    $Lines.Add(('Generated (UTC) : {0}' -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [cultureinfo]::InvariantCulture)))
    $Lines.Add(('Tool version    : {0}' -f [string]$Version))
    if ($StartTime -is [datetime] -and $StartTime -ne [datetime]::MinValue)
    {
        $Lines.Add(('Run started     : {0}' -f $StartTime.ToString('yyyy-MM-dd HH:mm:ss', [cultureinfo]::InvariantCulture)))
    }
    if ($EndTime -is [datetime] -and $EndTime -ne [datetime]::MinValue)
    {
        $Lines.Add(('Run finished    : {0}' -f $EndTime.ToString('yyyy-MM-dd HH:mm:ss', [cultureinfo]::InvariantCulture)))
    }
    if (($StartTime -is [datetime]) -and ($EndTime -is [datetime]) -and ($EndTime -ge $StartTime) -and ($StartTime -ne [datetime]::MinValue))
    {
        $TotalSec = [int][math]::Round((($EndTime - $StartTime).TotalSeconds))
        $DurText = if ($TotalSec -ge 3600)
        {
            '{0}h {1:D2}m {2:D2}s' -f [int][math]::Floor($TotalSec / 3600), [int][math]::Floor(($TotalSec % 3600) / 60), ($TotalSec % 60)
        }
        else
        {
            '{0}m {1:D2}s' -f [int][math]::Floor($TotalSec / 60), ($TotalSec % 60)
        }
        $Lines.Add(('Total duration  : {0}' -f $DurText))
    }

    $Lines.Add('')
    $Lines.Add('Parameters:')
    $ParamNames = @()
    if ($null -ne $InvocationParameters) { $ParamNames = @($InvocationParameters.Keys | Sort-Object) }
    $Emitted = 0
    foreach ($Name in $ParamNames)
    {
        if ($ExcludedParamNames -contains $Name) { continue }
        $Value = $InvocationParameters[$Name]
        if ($Value -is [switch])
        {
            if ($Value.IsPresent) { $Lines.Add(('  -{0}' -f $Name)); $Emitted++ }
            continue
        }
        if ($Value -is [bool])
        {
            if ($Value) { $Lines.Add(('  -{0}' -f $Name)); $Emitted++ }
            continue
        }
        if (($SafeValueParamNames -contains $Name) -or (-not $Obfuscated))
        {
            $Lines.Add(('  -{0} {1}' -f $Name, [string]$Value))
        }
        else
        {
            $Lines.Add(('  -{0} <value omitted>' -f $Name))
        }
        $Emitted++
    }
    if ($Emitted -eq 0) { $Lines.Add('  (defaults - no switches or values passed)') }

    $HostLines = [System.Collections.Generic.List[string]]::new()
    if ($HostVCpu -gt 0) { $HostLines.Add(('  Host vCPU         : {0}' -f $HostVCpu)) }
    if ($HostRamGB -gt 0) { $HostLines.Add(('  Host RAM (GB)     : {0}' -f $HostRamGB.ToString([cultureinfo]::InvariantCulture))) }
    if ($Streams -gt 0)
    {
        $StreamsSrcText = if (-not [string]::IsNullOrEmpty($StreamsSource)) { ' ({0})' -f $StreamsSource } else { '' }
        $HostLines.Add(('  Parallel streams  : {0}{1}' -f $Streams, $StreamsSrcText))
    }
    if ($Concurrency -gt 0)
    {
        $ConcurrencySrcText = if (-not [string]::IsNullOrEmpty($ConcurrencySource)) { ' ({0})' -f $ConcurrencySource } else { '' }
        $HostLines.Add(('  Concurrency limit : {0}{1}' -f $Concurrency, $ConcurrencySrcText))
    }
    if ($HostLines.Count -gt 0)
    {
        $Lines.Add('')
        $Lines.Add('Host / parallelism:')
        foreach ($HostLine in $HostLines) { $Lines.Add($HostLine) }
    }

    $Lines.Add('')
    $Lines.Add('Subscriptions:')
    $Lines.Add(('  Visible   : {0}' -f $Visible))
    $Lines.Add(('  Excluded  : {0} (non-Enabled)' -f $Excluded))
    $Lines.Add(('  Eligible  : {0}' -f $Eligible))
    $Lines.Add(('  Skipped   : {0} (already completed / resume)' -f $Skipped))
    $Lines.Add(('  Processed : {0}' -f $Processed))
    $Lines.Add(('  Failed    : {0}' -f $Failed.Count))
    $Lines.Add(('  0 resources - no access   : {0}' -f $NoAccess.Count))
    $Lines.Add(('  0 resources - empty       : {0}' -f $Empty.Count))
    $Lines.Add(('  0 resources - undetermined: {0}' -f $Undetermined.Count))

    $Lines.Add('')
    $Lines.Add('Health:')
    # -1 sentinel: see the same parameter on Write-RdaShareableDiagnosticsLog.
    $RowsFetched = if ($ConsumptionRowsFetchedCount -lt 0) { $ConsumptionRecordCount } else { $ConsumptionRowsFetchedCount }
    if ((-not $ConsumptionRequested) -and ($ConsumptionRecordCount -eq 0))
    {
        $Lines.Add('  Consumption records collected : n/a (-SkipConsumption was passed)')
    }
    else
    {
        $Lines.Add(('  Consumption records collected : {0}' -f $ConsumptionRecordCount.ToString('N0', [cultureinfo]::InvariantCulture)))
        $Lines.Add(('  Consumption rows fetched      : {0}' -f $RowsFetched.ToString('N0', [cultureinfo]::InvariantCulture)))
    }
    if ((-not $MarketplaceRequested) -and ($MarketplaceRecordCount -eq 0))
    {
        $Lines.Add('  Marketplace records collected : n/a (-SkipConsumption/-SkipMarketplace was passed)')
    }
    else
    {
        $Lines.Add(('  Marketplace records collected : {0}' -f $MarketplaceRecordCount.ToString('N0', [cultureinfo]::InvariantCulture)))
    }
    if ((-not $MetricsRequested) -and ($MetricsApiCallCount -eq 0))
    {
        $Lines.Add('  Metric-query API calls issued : n/a (-SkipMetrics was passed)')
    }
    else
    {
        $Lines.Add(('  Metric-query API calls issued : {0}' -f $MetricsApiCallCount.ToString('N0', [cultureinfo]::InvariantCulture)))
    }
    $Lines.Add(('  Failed subscriptions          : {0}' -f $Failed.Count))
    $Lines.Add(('    of which collection aborted : {0}' -f @(@($CollectionAbortedSubs) | Where-Object { $null -ne $_ }).Count))
    $Lines.Add(('    of which archive not written: {0}' -f @(@($ArchiveWriteFailures) | Where-Object { $null -ne $_ }).Count))
    $Lines.Add(('  Collector failures            : {0}' -f $Collector.Count))
    $Lines.Add(('  Metrics auth-skipped subs     : {0}' -f $MetricsAuth.Count))
    $Lines.Add(('  Metrics incomplete subs       : {0}' -f $MetricsPool.Count))
    $Lines.Add(('  Consumption failed subs       : {0}' -f $Consumption.Count))
    $Lines.Add(('  Marketplace failed subs       : {0}' -f $Marketplace.Count))
    if ($UnreportedStreamCount -gt 0)
    {
        $Lines.Add(('  Streams that did not report   : {0} (their record counts and health are not in the figures above)' -f $UnreportedStreamCount))
    }

    if ($ConsumptionRequested -and ($RowsFetched -eq 0) -and ($Consumption.Count -eq 0) -and ($Processed -gt 0) -and (($Processed - $Failed.Count) -gt 0) -and ($UnreportedStreamCount -eq 0))
    {
        $Lines.Add('')
        $Lines.Add('  WARNING - consumption was requested but ZERO usage records were collected,')
        $Lines.Add('  and no subscription reported a billing error. The billing API answered')
        $Lines.Add('  successfully with no rows, so the Consumption CSV holds only its header.')
        $Lines.Add('  Expected ONLY if there is genuinely no usage in the queried window (the 30')
        $Lines.Add('  days ending at midnight yesterday, host local time). Otherwise the usual causes are:')
        $Lines.Add('    - CSP / Partner-managed subscription with the partner cost visibility')
        $Lines.Add('      policy OFF (the default). Billing scope on CSP subscriptions is not')
        $Lines.Add('      governed by Azure RBAC, so granting Cost Management Reader does not')
        $Lines.Add('      help - the partner must enable it in Partner Center.')
        $Lines.Add('    - Subscription not transitioned to the Azure plan.')
        $Lines.Add('    - A subscription offer the legacy usage API does not serve.')
    }
    # The other half of that signature, and the half nothing reported at all
    # before: the billing API DID return rows, and the tool excluded every one of
    # them. The causes named above are all false here - the API answered with data -
    # so this branch is mutually exclusive with the one above and carries the
    # scope/filter explanation instead. It repeats that block's remaining guards so
    # neither fires on a run that already reported a per-subscription billing error.
    #
    # Inert by design when -ConsumptionRowsFetchedCount is omitted: the -1 sentinel
    # collapses $RowsFetched to $ConsumptionRecordCount, so the two tests below
    # cannot both hold. That is right - with no fetched figure nothing is KNOWN to
    # have been excluded, so staying silent beats guessing. This is load-bearing:
    # do not "simplify" the sentinel without re-checking this branch.
    elseif ($ConsumptionRequested -and ($RowsFetched -gt 0) -and ($ConsumptionRecordCount -eq 0) -and ($Consumption.Count -eq 0) -and ($Processed -gt 0) -and (($Processed - $Failed.Count) -gt 0) -and ($UnreportedStreamCount -eq 0))
    {
        $Lines.Add('')
        # -ResourceGroupScoped is deliberately NOT passed, so this surface gets the
        # narrow form. Run-AllSubscriptions.ps1 - whose RunSummary.log this block
        # ships in - has no -ResourceGroup parameter, so the exclusions that need
        # one cannot apply here. Full rationale lives with the helper in
        # Functions/Common.Functions.ps1. Do NOT add the switch.
        foreach ($Line in (Get-RdaConsumptionExcludedByScopeText -RowsFetched $RowsFetched -Indent '  ')) { $Lines.Add($Line) }
    }

    # Per-subscription memory readings from the inner script: counts and megabytes, labelled by
    # subscription id, or by position when obfuscated. They show how much the host was holding at
    # each phase and whether it grew from one subscription to the next, which is what a run that
    # ran out of memory needs.
    # An explicit empty state, so a summary with no readings (every subscription failed before its
    # first reading, or a stream worker died before writing its summary) is not mistaken for one
    # produced by a build without the block.
    $MemoryLines = @(Get-RdaMemoryReadingLines -Readings $MemoryReadings -Obfuscated:$Obfuscated)
    $Lines.Add('')
    if ($MemoryLines.Count -gt 0)
    {
        foreach ($MemoryLine in $MemoryLines) { $Lines.Add($MemoryLine) }
    }
    else
    {
        $Lines.Add('Memory: no readings recorded (no subscription reached its first reading)')
    }

    if (-not $Obfuscated)
    {
        if ($Failed.Count -gt 0)
        {
            $Lines.Add('')
            $Lines.Add('Failed subscriptions (detail):')
            foreach ($FailedSub in $Failed)
            {
                if ($FailedSub -is [string])
                {
                    $FailedName = $FailedSub
                    $FailedId = ''
                }
                else
                {
                    $FailedName = [string]$FailedSub.Name
                    $FailedId = [string]$FailedSub.Id
                    if ([string]::IsNullOrWhiteSpace($FailedName)) { $FailedName = [string]$FailedSub }
                }

                if ([string]::IsNullOrWhiteSpace($FailedId)) { $Lines.Add(('  - {0}' -f $FailedName)) }
                else { $Lines.Add(('  - {0} ({1})' -f $FailedName, $FailedId)) }
            }
        }
        if ($NoAccess.Count -gt 0)
        {
            $Lines.Add('')
            $Lines.Add('0-resource subscriptions with NO ACCESS (grant Reader, re-run -Resume):')
            foreach ($NoAccessSub in $NoAccess) { $Lines.Add(('  - {0} ({1})' -f [string]$NoAccessSub.Name, [string]$NoAccessSub.Id)) }
        }
        if ($Collector.Count -gt 0)
        {
            $Lines.Add('')
            $Lines.Add('Collector failures (detail):')
            foreach ($CollectorFail in $Collector) { $Lines.Add(('  - [sub {0}] {1}: {2}' -f [string]$CollectorFail.Id, [string]$CollectorFail.Module, [string]$CollectorFail.Message)) }
        }
        if ($MetricsAuth.Count -gt 0)
        {
            $Lines.Add('')
            $Lines.Add('Metrics auth-skipped subscriptions (detail):')
            foreach ($MetricSub in $MetricsAuth) { $Lines.Add(('  - {0} ({1}): {2}' -f [string]$MetricSub.Name, [string]$MetricSub.Id, [string]$MetricSub.Message)) }
        }
        if ($MetricsPool.Count -gt 0)
        {
            $Lines.Add('')
            $Lines.Add('Metrics incomplete subscriptions (detail):')
            foreach ($MetricPoolSub in $MetricsPool) { $Lines.Add(('  - {0} ({1}): {2}' -f [string]$MetricPoolSub.Name, [string]$MetricPoolSub.Id, [string]$MetricPoolSub.Message)) }
        }
        if ($Consumption.Count -gt 0)
        {
            $Lines.Add('')
            $Lines.Add('Consumption failed subscriptions (detail):')
            foreach ($ConsumpSub in $Consumption) { $Lines.Add(('  - {0} ({1}): {2}' -f [string]$ConsumpSub.Name, [string]$ConsumpSub.Id, [string]$ConsumpSub.Message)) }
        }
        if ($Marketplace.Count -gt 0)
        {
            $Lines.Add('')
            $Lines.Add('Marketplace failed subscriptions (detail):')
            foreach ($MarketSub in $Marketplace) { $Lines.Add(('  - {0} ({1}): {2}' -f [string]$MarketSub.Name, [string]$MarketSub.Id, [string]$MarketSub.Message)) }
        }
    }

    return $Lines.ToArray()
}

function Test-ZipArchiveEntry
{
    param(
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][string]$EntryName
    )

    if ([string]::IsNullOrWhiteSpace($ZipPath) -or -not (Test-Path -LiteralPath $ZipPath))
    {
        return $false
    }

    $Archive = $null
    try
    {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $Archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
        foreach ($Entry in $Archive.Entries)
        {
            if ($Entry.Name -ieq $EntryName -or $Entry.FullName -ieq $EntryName)
            {
                return $true
            }
        }
        return $false
    }
    catch
    {
        return $false
    }
    finally
    {
        if ($null -ne $Archive) { $Archive.Dispose() }
    }
}

function New-RdaSupportLogBundle
{
    param(
        [string]$InventoryRoot,
        [string]$DestinationPath,
        [datetime]$SinceTime,
        [switch]$IncludeMainSummary
    )

    if ([string]::IsNullOrWhiteSpace($InventoryRoot))
    {
        $InventoryRoot = if ($PSVersionTable.Platform -eq 'Unix') { "$HOME/InventoryReports" } else { "C:\InventoryReports" }
    }
    if (-not (Test-Path -LiteralPath $InventoryRoot -PathType Container))
    {
        Write-Warning ("Support-log collection: inventory root not found at '{0}'; nothing to collect." -f $InventoryRoot)
        return $null
    }
    if ([string]::IsNullOrWhiteSpace($DestinationPath))
    {
        $DestinationPath = Join-Path $InventoryRoot ('RdaSupportLogs_{0}.zip' -f (Get-Date).ToString('yyyy-MM-dd_HH-mm-ss', [cultureinfo]::InvariantCulture))
    }

    $ExcludedNamePatterns = @('ObfuscationDictionary_*', 'Full_*')
    $IsExcluded = {
        param($Name)
        foreach ($Pat in $ExcludedNamePatterns) { if ($Name -like $Pat) { return $true } }
        return $false
    }
    $PassesSince = {
        param($File)
        if ($SinceTime -ne [datetime]::MinValue)
        {
            return ($File.LastWriteTime -ge $SinceTime)
        }
        return $true
    }

    $WrapperPatterns = @(
        'RunAllSubscriptions_transcript_*.txt',
        'RunAllSubscriptions_failures_*.log',
        'RunAllSubscriptions_diagnostics_*.log',
        'RunSummary_*.log'
    )
    if ($IncludeMainSummary) { $WrapperPatterns += 'MainSummary_*.html' }

    $PerSubPatterns = @(
        'Diagnostics_*.log',
        'DebugLog_*.log',
        'ErrorLog_*.log',
        'Transcript_Log_*.txt'
    )

    $Stage = Join-Path $InventoryRoot ('.rda-supportlogs-{0}' -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
    $Collected = 0
    try
    {
        New-Item -ItemType Directory -Path $Stage -Force | Out-Null

        foreach ($Pattern in $WrapperPatterns)
        {
            foreach ($File in @(Get-ChildItem -LiteralPath $InventoryRoot -File -Filter $Pattern -ErrorAction SilentlyContinue))
            {
                if ((& $IsExcluded $File.Name) -or -not (& $PassesSince $File)) { continue }
                try { Copy-Item -LiteralPath $File.FullName -Destination (Join-Path $Stage $File.Name) -Force; $Collected++ }
                catch { Write-Verbose ("Support-log collection: skipped '{0}': {1}" -f $File.FullName, $_.Exception.Message) }
            }
        }

        foreach ($SubDir in @(Get-ChildItem -LiteralPath $InventoryRoot -Directory -Filter 'ResourcesReport*' -ErrorAction SilentlyContinue))
        {
            $DestSubDir = Join-Path $Stage $SubDir.Name
            foreach ($Pattern in $PerSubPatterns)
            {
                foreach ($File in @(Get-ChildItem -LiteralPath $SubDir.FullName -File -Filter $Pattern -ErrorAction SilentlyContinue))
                {
                    if ((& $IsExcluded $File.Name) -or -not (& $PassesSince $File)) { continue }
                    if (-not (Test-Path -LiteralPath $DestSubDir -PathType Container)) { New-Item -ItemType Directory -Path $DestSubDir -Force | Out-Null }
                    try { Copy-Item -LiteralPath $File.FullName -Destination (Join-Path $DestSubDir $File.Name) -Force; $Collected++ }
                    catch { Write-Verbose ("Support-log collection: skipped '{0}': {1}" -f $File.FullName, $_.Exception.Message) }
                }
            }
        }

        if ($Collected -eq 0)
        {
            Write-Warning ("Support-log collection: no matching log files found under '{0}'{1}." -f $InventoryRoot, $(if ($PSBoundParameters.ContainsKey('SinceTime')) { ' for the requested time window' } else { '' }))
            return $null
        }

        $Manifest = [System.Collections.Generic.List[string]]::new()
        $Manifest.Add('Resource Discovery for Azure - support log bundle')
        $Manifest.Add(('Generated (UTC) : {0}' -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [cultureinfo]::InvariantCulture)))
        $Manifest.Add(('Inventory root  : {0}' -f $InventoryRoot))
        if ($PSBoundParameters.ContainsKey('SinceTime')) { $Manifest.Add(('Scoped to files at/after : {0}' -f $SinceTime.ToString('yyyy-MM-dd HH:mm:ss', [cultureinfo]::InvariantCulture))) }
        $Manifest.Add(('Files collected : {0}' -f $Collected))
        $Manifest.Add('')
        $Manifest.Add('*** PRIVATE - contains real identifiers ***')
        $Manifest.Add('This bundle includes the wrapper transcript and per-subscription debug/error')
        $Manifest.Add('logs, which carry the signed-in account (UPN), tenant/subscription IDs,')
        $Manifest.Add('resource names, and raw error text. Send it to support over a SECURE/PRIVATE')
        $Manifest.Add('channel only. Do NOT attach it to a public issue, PR, or forum post.')
        $Manifest.Add('The obfuscation dictionary (the de-obfuscation reveal key) is deliberately')
        $Manifest.Add('NOT included in this bundle.')
        $Manifest.Add('')
        $Manifest.Add('Contents:')
        $Manifest.Add('  RunAllSubscriptions_transcript_*.txt  - full wrapper console transcript (start-to-exit; present even when the run hard-failed before producing a report).')
        $Manifest.Add('  RunAllSubscriptions_failures_*.log    - wrapper failure diagnostics (per subscription / per stream).')
        $Manifest.Add('  RunAllSubscriptions_diagnostics_*.log - 0-resource access verdict (no-access / empty / undetermined).')
        $Manifest.Add('  RunSummary_*.log                      - run parameters, subscription tally, per-phase failure counts (per-sub detail only for non-obfuscated runs).')
        if ($IncludeMainSummary) { $Manifest.Add('  MainSummary_*.html                    - aggregate run summary (context).') }
        $Manifest.Add('  <ResourcesReport*>/Diagnostics_*.log  - per-subscription SHAREABLE (identifier-scrubbed) phase/health diagnostics.')
        $Manifest.Add('  <ResourcesReport*>/DebugLog_*.log     - per-subscription collector heartbeat (START/DONE/FAIL) + metrics diagnostics (LOCAL; real names).')
        $Manifest.Add('  <ResourcesReport*>/ErrorLog_*.log     - per-subscription error log (LOCAL; real names).')
        $Manifest.Add('  <ResourcesReport*>/Transcript_Log_*.txt - per-subscription PowerShell transcript (LOCAL; real names).')
        $Manifest.ToArray() | Out-File -LiteralPath (Join-Path $Stage 'MANIFEST.txt') -Encoding utf8

        $StageItems = @(Get-ChildItem -LiteralPath $Stage -Force -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
        Compress-Archive -LiteralPath $StageItems -DestinationPath ([WildcardPattern]::Escape($DestinationPath)) -Force
        return $DestinationPath
    }
    catch
    {
        Write-Warning ("Support-log collection failed: {0}" -f $_.Exception.Message)
        return $null
    }
    finally
    {
        if (Test-Path -LiteralPath $Stage) { Remove-Item -LiteralPath $Stage -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# =============================================================================
# =============================================================================

function Split-BlobContainerUri
{
    param([Parameter(Mandatory = $true)][string]$Uri)

    $Parsed = [System.Uri]$Uri
    $Account = $Parsed.Host.Split('.')[0]
    $PathParts = $Parsed.AbsolutePath.Trim('/').Split('/', 2)
    $Container = $PathParts[0]
    $Prefix = if ($PathParts.Count -gt 1 -and $PathParts[1]) { $PathParts[1].Trim('/') + '/' } else { '' }
    return [pscustomobject]@{
        Account   = $Account
        Container = $Container
        Prefix    = $Prefix
    }
}

function Get-StateBlobShardSegment
{
    param(
        [int]$ShardIndex = 0,
        [int]$ShardCount = 1
    )
    if ($ShardCount -gt 1) { return ('shard-{0}of{1}/' -f $ShardIndex, $ShardCount) }
    return ''
}

function Get-StateBlobStreamPrefix
{
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Prefix,
        [Parameter(Mandatory = $true)][string]$Tenant,
        [int]$ShardIndex = 0,
        [int]$ShardCount = 1
    )
    $ShardSeg = Get-StateBlobShardSegment -ShardIndex $ShardIndex -ShardCount $ShardCount
    return ('{0}_state/{1}.resume-state-{2}-stream-' -f $Prefix, $ShardSeg, $Tenant)
}

function Get-StateBlobName
{
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Prefix,
        [Parameter(Mandatory = $true)][string]$Tenant,
        [int]$ShardIndex = 0,
        [int]$ShardCount = 1,
        [int]$StreamId = -1
    )
    if ($StreamId -ge 0)
    {
        $StreamPrefix = Get-StateBlobStreamPrefix -Prefix $Prefix -Tenant $Tenant -ShardIndex $ShardIndex -ShardCount $ShardCount
        return ('{0}{1}.json' -f $StreamPrefix, $StreamId)
    }

    $ShardSeg = Get-StateBlobShardSegment -ShardIndex $ShardIndex -ShardCount $ShardCount
    return ('{0}_state/{1}.resume-state-{2}.json' -f $Prefix, $ShardSeg, $Tenant)
}

function Get-SubscriptionDelta
{
    param(
        [string[]]$StartIds = @(),
        [string[]]$EndIds = @(),
        [string[]]$CompletedIds = @()
    )
    $Start = @{}
    foreach ($x in $StartIds) { if ($x) { $Start[([string]$x).ToLowerInvariant()] = $x } }
    $End = @{}
    foreach ($x in $EndIds) { if ($x) { $End[([string]$x).ToLowerInvariant()] = $x } }
    $Done = @{}
    foreach ($x in $CompletedIds) { if ($x) { $Done[([string]$x).ToLowerInvariant()] = $true } }

    $Vanished = @()
    foreach ($k in $Start.Keys) { if (-not $End.ContainsKey($k)) { $Vanished += $Start[$k] } }
    $New = @()
    foreach ($k in $End.Keys) { if (-not $Start.ContainsKey($k)) { $New += $End[$k] } }
    $Incomplete = @()
    foreach ($k in $End.Keys) { if ($Start.ContainsKey($k) -and -not $Done.ContainsKey($k)) { $Incomplete += $End[$k] } }

    return [pscustomobject]@{
        Vanished   = @($Vanished)
        New        = @($New)
        Incomplete = @($Incomplete)
    }
}

function New-StateBlobContext
{
    param([Parameter(Mandatory = $true)][string]$Account)
    return New-AzStorageContext -StorageAccountName $Account -UseConnectedAccount -ErrorAction Stop
}

function Save-StateBlob
{
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Container,
        [Parameter(Mandatory = $true)][string]$BlobName,
        [Parameter(Mandatory = $true)][string]$File,
        [switch]$BestEffort
    )
    try
    {
        $null = Set-AzStorageBlobContent -File $File -Container $Container -Blob $BlobName -Context $Context -Force -ErrorAction Stop
        return $true
    }
    catch
    {
        if ($BestEffort)
        {
            Write-Host ("WARNING: could not mirror resume state to blob {0}/{1}: {2}" -f $Container, $BlobName, $_.Exception.Message) -ForegroundColor Yellow
            return $false
        }
        throw
    }
}

function Read-StateBlob
{
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Container,
        [Parameter(Mandatory = $true)][string]$BlobName,
        [int]$MaxAttempts = 3
    )

    $LastError = $null
    for ($Attempt = 1; $Attempt -le $MaxAttempts; $Attempt++)
    {
        $Tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('rda-state-dl-{0}.json' -f ([guid]::NewGuid().ToString('N')))
        try
        {
            $null = Get-AzStorageBlobContent -Container $Container -Blob $BlobName -Destination $Tmp -Context $Context -Force -ErrorAction Stop
            return (Get-Content -LiteralPath $Tmp -Raw | ConvertFrom-Json)
        }
        catch
        {
            $LastError = $_.Exception.Message
            if ($Attempt -lt $MaxAttempts) { Start-Sleep -Seconds $Attempt }
        }
        finally
        {
            Remove-Item -LiteralPath $Tmp -Force -ErrorAction SilentlyContinue
        }
    }

    $Exists = $false
    try
    {
        $Probe = Get-AzStorageBlob -Container $Container -Blob $BlobName -Context $Context -ErrorAction Stop
        $Exists = ($null -ne $Probe)
    }
    catch
    {
        $Exists = $false
        Write-Verbose ("Read-StateBlob: existence probe for {0} also failed: {1}" -f $BlobName, $_.Exception.Message)
    }

    if ($Exists)
    {
        Write-Host ("WARNING: resume state blob '{0}' EXISTS but could not be read after {1} attempt(s): {2}" -f $BlobName, $MaxAttempts, $LastError) -ForegroundColor Yellow
        Write-Host "  This is NOT the same as having no resume state. Treating it as absent means this run may RE-PROCESS subscriptions an earlier attempt already completed." -ForegroundColor Yellow
        Write-Host "  If that matters, stop now and re-run once the storage account is reachable, rather than paying for the whole estate again." -ForegroundColor Yellow
    }
    else
    {
        Write-Verbose ("Read-StateBlob: no usable state blob '{0}' ({1}); starting fresh." -f $BlobName, $LastError)
    }

    return $null
}

function Get-StateBlobNames
{
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Container,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Prefix,
        [Parameter(Mandatory = $true)][string]$Tenant,
        [int]$ShardIndex = 0,
        [int]$ShardCount = 1
    )
    $ListPrefix = Get-StateBlobStreamPrefix -Prefix $Prefix -Tenant $Tenant -ShardIndex $ShardIndex -ShardCount $ShardCount
    try
    {
        $Blobs = Get-AzStorageBlob -Container $Container -Prefix $ListPrefix -Context $Context -ErrorAction Stop
        return @($Blobs | Select-Object -ExpandProperty Name)
    }
    catch
    {
        # An empty answer reads as "no stream state", so a listing that failed must say so: otherwise
        # recovery skips what a killed run completed and the merge forgets a stream's results.
        Write-Host ("WARNING: could not list the per-stream state blobs under {0}/{1}: {2}" -f $Container, $ListPrefix, $_.Exception.Message) -ForegroundColor Yellow
        return @()
    }
}

