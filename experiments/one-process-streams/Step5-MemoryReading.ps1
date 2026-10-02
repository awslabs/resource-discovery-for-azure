#!/usr/bin/env pwsh
#Requires -Version 7.0
# Step 5: does [GC]::GetGCMemoryInfo() track the memory that is really free?
# The Runspace-mode admission check reads free memory as TotalAvailableMemoryBytes - MemoryLoadBytes
# after a collection. This script reads that figure, allocates and touches -AllocMB of unmanaged memory
# (random bytes, so the macOS memory compressor cannot shrink it), reads again, frees the block and reads
# a third time, beside the operating system's own figures. After each change it polls until the reading
# moves by the allocation (or -SettleSeconds pass), records how long that took, then takes the median of
# -Samples readings. The cycle runs -Repeat times, because other processes move free memory too.
# Exit 0 when the check named by -Check holds, 1 when it does not, 2 when a figure could not be read:
#   Tracks  - the median drop of the reading after a collection of -Generation equals the allocation, within
#             one reading step (the GC reports memory load in whole percent of total memory) plus -ToleranceMB
#   Recover - the median rise once the block was freed equals the allocation, within the same band
#   MatchOs - before the allocation, the reading is within one step plus -ToleranceMB of the figure the OS
#             reports as available (Windows FreePhysicalMemory; macOS kern.memorystatus_level of hw.memsize;
#             Linux MemAvailable)
#   Refresh - with the block allocated and the OS figure already down, a gen-0 collection alone records the
#             new memory load: its reading matches the full collection that follows it, within one step,
#             and differs from the full collection taken before the allocation
#   Garbage - -AllocMB of touched managed arrays lower the reading by at least half their size, and still
#             do once unreferenced (they are large objects, collected only with generation 2); one full
#             collection of -FullMode, then a gen-0 reading, gives at least half of it back within -SettleSeconds
#             (Default is [GC]::Collect(); Aggressive is GCCollectionMode.Aggressive, which also decommits)
param(
    [int]$AllocMB = 400,
    [int]$Samples = 5,
    [int]$ToleranceMB = 150,
    [int]$SettleSeconds = 30,
    [int]$Repeat = 5,
    [ValidateSet(0, 1, 2)][int]$Generation = 0,
    [ValidateSet('Tracks', 'Recover', 'MatchOs', 'Refresh', 'Garbage')][string]$Check = 'Tracks',
    [ValidateSet('Default', 'Aggressive')][string]$FullMode = 'Default'
)

function Get-GcReading
{
    param([int]$Gen)
    $Watch = [System.Diagnostics.Stopwatch]::StartNew()
    [System.GC]::Collect($Gen)
    $Info = [System.GC]::GetGCMemoryInfo()
    $Watch.Stop()
    [pscustomobject]@{
        Index   = $Info.Index
        Gen     = $Info.Generation
        TotalMB = [double]$Info.TotalAvailableMemoryBytes / 1MB
        LoadMB  = [double]$Info.MemoryLoadBytes / 1MB
        FreeMB  = [double]($Info.TotalAvailableMemoryBytes - $Info.MemoryLoadBytes) / 1MB
        Ms      = $Watch.Elapsed.TotalMilliseconds
    }
}

function Get-OsReading
{
    # Diagnostic comparison only: the product code runs no OS command.
    # AvailableMB is the figure each OS itself reports as available to new work.
    $Os = [ordered]@{}
    if ($IsWindows)
    {
        $Win = Get-CimInstance -ClassName Win32_OperatingSystem
        $Os.AvailableMB = [double]$Win.FreePhysicalMemory / 1KB
    }
    elseif ($IsMacOS)
    {
        $Level = [double](& sysctl -n kern.memorystatus_level)
        $Total = [double](& sysctl -n hw.memsize)
        $Os.AvailableMB = $Total * $Level / 100 / 1MB
        $Stat = @(& vm_stat)
        $PageBytes = [double]([regex]::Match($Stat[0], 'page size of (\d+) bytes').Groups[1].Value)
        $Pages = @{}
        foreach ($Line in $Stat)
        {
            $Hit = [regex]::Match($Line, '^Pages (free|inactive|speculative):\s+(\d+)\.')
            if ($Hit.Success) { $Pages[$Hit.Groups[1].Value] = [double]$Hit.Groups[2].Value }
        }
        $Os.FreePagesMB = $Pages['free'] * $PageBytes / 1MB
        $Os.FreeInactiveMB = ($Pages['free'] + $Pages['inactive'] + $Pages['speculative']) * $PageBytes / 1MB
    }
    elseif ($IsLinux)
    {
        $Info = Get-Content -LiteralPath '/proc/meminfo'
        $Os.AvailableMB = [double]([regex]::Match(($Info -match '^MemAvailable:'), '(\d+)').Groups[1].Value) / 1KB
        $Os.FreePagesMB = [double]([regex]::Match(($Info -match '^MemFree:'), '(\d+)').Groups[1].Value) / 1KB
    }
    [pscustomobject]$Os
}

function Get-Median
{
    param([double[]]$Values)
    $Sorted = @($Values | Sort-Object)
    $Mid = [int][math]::Floor($Sorted.Count / 2)
    if ($Sorted.Count % 2 -eq 1) { return $Sorted[$Mid] }
    return ($Sorted[$Mid - 1] + $Sorted[$Mid]) / 2
}

function Wait-Reading
{
    # Polls until the reading has moved by at least the allocation less the band, in the given direction.
    param([double]$FromMB, [int]$Sign)
    $Watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($Watch.Elapsed.TotalSeconds -lt $SettleSeconds)
    {
        $Now = (Get-GcReading -Gen $Generation).FreeMB
        if ($Sign * ($Now - $FromMB) -ge ($AllocMB - $script:Band)) { break }
        Start-Sleep -Milliseconds 250
    }
    return [math]::Round($Watch.Elapsed.TotalSeconds, 1)
}

function Get-Phase
{
    param([string]$Name, [double]$SettledSeconds = 0)
    $Gc = @()
    $Os = @()
    for ($S = 0; $S -lt $Samples; $S++)
    {
        $Gc += Get-GcReading -Gen $Generation
        $Os += Get-OsReading
        Start-Sleep -Milliseconds 300
    }
    $Phase = [ordered]@{
        Phase    = $Name
        SettledS = $SettledSeconds
        GcFreeMB = [math]::Round((Get-Median -Values @($Gc | ForEach-Object { $_.FreeMB })), 0)
        GcLoadMB = [math]::Round((Get-Median -Values @($Gc | ForEach-Object { $_.LoadMB })), 0)
        GcMs     = [math]::Round((Get-Median -Values @($Gc | ForEach-Object { $_.Ms })), 2)
        GcIndex  = '{0}..{1}' -f $Gc[0].Index, $Gc[-1].Index
        GcGen    = ($Gc | ForEach-Object { $_.Gen } | Sort-Object -Unique) -join ','
    }
    foreach ($Field in $Os[0].PSObject.Properties.Name)
    {
        $Phase["Os$Field"] = [math]::Round((Get-Median -Values @($Os | ForEach-Object { $_.$Field })), 0)
    }
    [pscustomobject]$Phase
}

function New-TouchedBlock
{
    $BlockBytes = [long]$AllocMB * 1MB
    $Block = [System.Runtime.InteropServices.Marshal]::AllocHGlobal([IntPtr]$BlockBytes)
    $Chunk = [byte[]]::new(1MB)
    [System.Random]::new(17).NextBytes($Chunk)
    for ($Offset = 0L; $Offset -lt $BlockBytes; $Offset += $Chunk.Length)
    {
        # A different pattern per megabyte: identical pages could be shared or compressed by the OS.
        $Chunk[0] = [byte]($Offset % 251)
        $Chunk[$Chunk.Length - 1] = [byte](($Offset / 1MB) % 241)
        [System.Runtime.InteropServices.Marshal]::Copy($Chunk, 0, [IntPtr]($Block.ToInt64() + $Offset), $Chunk.Length)
    }
    return $Block
}

$First = Get-GcReading -Gen 2
$StepMB = $First.TotalMB / 100
$script:Band = $StepMB + $ToleranceMB
'Platform: {0}; {1}; total {2:N0} MB; reading step (1% of total) {3:N0} MB; band +/- {4:N0} MB; check {5}, gen {6}, full collection {7}' -f [System.Runtime.InteropServices.RuntimeInformation]::OSDescription, [System.Runtime.InteropServices.RuntimeInformation]::FrameworkDescription, $First.TotalMB, $StepMB, $script:Band, $Check, $Generation, $FullMode

if ($Check -eq 'Refresh')
{
    $Full0 = Get-GcReading -Gen 2
    $Os0 = (Get-OsReading).AvailableMB
    $Block = [IntPtr]::Zero
    try
    {
        $Block = New-TouchedBlock
        # Wait for the OS figure itself to show the block, so a stale gen-0 reading cannot pass by luck.
        $Watch = [System.Diagnostics.Stopwatch]::StartNew()
        while ($Watch.Elapsed.TotalSeconds -lt $SettleSeconds -and ($Os0 - (Get-OsReading).AvailableMB) -lt ($AllocMB - $script:Band))
        {
            Start-Sleep -Milliseconds 250
        }
        $OsSettled = [math]::Round($Watch.Elapsed.TotalSeconds, 1)
        $Os1 = (Get-OsReading).AvailableMB
        $Gen0 = Get-GcReading -Gen 0
        $Full1 = Get-GcReading -Gen 2
    }
    finally
    {
        if ($Block -ne [IntPtr]::Zero) { [System.Runtime.InteropServices.Marshal]::FreeHGlobal($Block) }
    }
    'Full GC before: free {0:N0} MB (index {1}); OS before {2:N0} MB' -f $Full0.FreeMB, $Full0.Index, $Os0
    'OS after the allocation: {0:N0} MB (settled in {1} s)' -f $Os1, $OsSettled
    'Gen-0 GC: free {0:N0} MB (index {1}, generation {2}, {3:N2} ms)' -f $Gen0.FreeMB, $Gen0.Index, $Gen0.Gen, $Gen0.Ms
    'Full GC after: free {0:N0} MB (index {1}, {2:N2} ms)' -f $Full1.FreeMB, $Full1.Index, $Full1.Ms
    if ($Full0.LoadMB -le 0 -or ($Os0 - $Os1) -lt ($AllocMB - $script:Band)) { 'OS figure never showed the block'; exit 2 }
    $Holds = $Gen0.Gen -eq 0 -and [math]::Abs($Gen0.FreeMB - $Full1.FreeMB) -le $script:Band -and ($Full0.FreeMB - $Gen0.FreeMB) -ge ($AllocMB - $script:Band)
    'Check Refresh: {0}' -f $(if ($Holds) { 'holds' } else { 'does not hold' })
    if ($Holds) { exit 0 }
    exit 1
}

if ($Check -eq 'Garbage')
{
    $Clean = Get-GcReading -Gen 2
    $Clean = Get-GcReading -Gen 0
    $Arrays = [System.Collections.Generic.List[byte[]]]::new()
    $Random = [System.Random]::new(23)
    for ($N = 0; $N -lt $AllocMB; $N++)
    {
        $Array = [byte[]]::new(1MB)
        $Random.NextBytes($Array)
        $Arrays.Add($Array)
    }
    $Array = $null
    $HeldSettle = Wait-Reading -FromMB $Clean.FreeMB -Sign -1
    $Held = Get-GcReading -Gen 0
    $Arrays = $null
    Start-Sleep -Seconds 2
    $Unreferenced = Get-GcReading -Gen 0
    $CommittedBefore = [double][System.GC]::GetGCMemoryInfo().TotalCommittedBytes / 1MB
    $Watch = [System.Diagnostics.Stopwatch]::StartNew()
    if ($FullMode -eq 'Aggressive')
    {
        [System.GC]::Collect([System.GC]::MaxGeneration, [System.GCCollectionMode]::Aggressive, $true, $true)
    }
    else
    {
        [System.GC]::Collect()
    }
    $FullMs = $Watch.Elapsed.TotalMilliseconds
    $FullRecord = [System.GC]::GetGCMemoryInfo()
    $AfterFull = Get-GcReading -Gen 0
    $Settle = [System.Diagnostics.Stopwatch]::StartNew()
    while ($Settle.Elapsed.TotalSeconds -lt $SettleSeconds -and ($AfterFull.FreeMB - $Unreferenced.FreeMB) -lt ($AllocMB / 2))
    {
        Start-Sleep -Milliseconds 250
        $AfterFull = Get-GcReading -Gen 0
    }
    'Gen-0 reading before the arrays: {0:N0} MB free; heap {1:N0} MB' -f $Clean.FreeMB, ([System.GC]::GetTotalMemory($false) / 1MB)
    'Arrays held: {0:N0} MB free (settled in {1} s)' -f $Held.FreeMB, $HeldSettle
    'Arrays unreferenced, gen-0 reading 2 s later: {0:N0} MB free' -f $Unreferenced.FreeMB
    'Full collection ({0}): {1:N1} ms; its own record: {2:N0} MB free (index {3}, generation {4}); GC committed {5:N0} -> {6:N0} MB' -f $FullMode, $FullMs, ([double]($FullRecord.TotalAvailableMemoryBytes - $FullRecord.MemoryLoadBytes) / 1MB), $FullRecord.Index, $FullRecord.Generation, $CommittedBefore, ([double]$FullRecord.TotalCommittedBytes / 1MB)
    'Gen-0 reading after it: {0:N0} MB free, {1:N1} s after the full collection' -f $AfterFull.FreeMB, $Settle.Elapsed.TotalSeconds
    if ($Clean.LoadMB -le 0) { exit 2 }
    $Holds = ($Clean.FreeMB - $Unreferenced.FreeMB) -ge ($AllocMB / 2) -and ($AfterFull.FreeMB - $Unreferenced.FreeMB) -ge ($AllocMB / 2)
    'Check Garbage: {0}' -f $(if ($Holds) { 'holds' } else { 'does not hold' })
    if ($Holds) { exit 0 }
    exit 1
}

$Cycles = @()
for ($Cycle = 1; $Cycle -le $Repeat; $Cycle++)
{
    $Before = Get-Phase -Name ('{0}: before' -f $Cycle)
    $Block = [IntPtr]::Zero
    $Allocated = $null
    try
    {
        $Block = New-TouchedBlock
        $Settled = Wait-Reading -FromMB $Before.GcFreeMB -Sign -1
        $Allocated = Get-Phase -Name ('{0}: allocated {1} MB' -f $Cycle, $AllocMB) -SettledSeconds $Settled
    }
    finally
    {
        if ($Block -ne [IntPtr]::Zero) { [System.Runtime.InteropServices.Marshal]::FreeHGlobal($Block) }
    }
    $Settled = Wait-Reading -FromMB $Allocated.GcFreeMB -Sign 1
    $Freed = Get-Phase -Name ('{0}: freed' -f $Cycle) -SettledSeconds $Settled
    $Cycles += [pscustomobject]@{
        Before    = $Before
        Allocated = $Allocated
        Freed     = $Freed
        GcDrop    = $Before.GcFreeMB - $Allocated.GcFreeMB
        GcRise    = $Freed.GcFreeMB - $Allocated.GcFreeMB
        OsDrop    = $Before.OsAvailableMB - $Allocated.OsAvailableMB
        GcMinusOs = $Before.GcFreeMB - $Before.OsAvailableMB
    }
}

@($Cycles | ForEach-Object { $_.Before, $_.Allocated, $_.Freed }) | Format-Table -AutoSize | Out-String -Width 240
foreach ($Row in $Cycles)
{
    'cycle: GC dropped {0:N0} MB, rose {1:N0} MB; OS available dropped {2:N0} MB; GC minus OS before {3:N0} MB' -f $Row.GcDrop, $Row.GcRise, $Row.OsDrop, $Row.GcMinusOs
}
$GcDrop = Get-Median -Values @($Cycles | ForEach-Object { $_.GcDrop })
$GcRise = Get-Median -Values @($Cycles | ForEach-Object { $_.GcRise })
$GcMinusOs = Get-Median -Values @($Cycles | ForEach-Object { $_.GcMinusOs })
'Median over {0} cycles of {1} MB: GC dropped {2:N0} MB, rose {3:N0} MB; GC minus OS before {4:N0} MB' -f $Repeat, $AllocMB, $GcDrop, $GcRise, $GcMinusOs

if (@($Cycles | Where-Object { $null -eq $_.Allocated -or $_.Before.GcLoadMB -le 0 }).Count -gt 0) { exit 2 }
$Holds = switch ($Check)
{
    'Tracks' { [math]::Abs($GcDrop - $AllocMB) -le $script:Band }
    'Recover' { [math]::Abs($GcRise - $AllocMB) -le $script:Band }
    'MatchOs' { [math]::Abs($GcMinusOs) -le $script:Band }
}
'Check {0}: {1}' -f $Check, $(if ($Holds) { 'holds' } else { 'does not hold' })
if ($Holds) { exit 0 }
exit 1
