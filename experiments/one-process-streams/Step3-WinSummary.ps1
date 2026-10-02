# Summarises the Windows Step 3 runs that Step3-Windows.ps1 left in $OutDir: per design, the median and
# range of wall time, CPU, peak threads, peak working set and peak commit; and whether every run
# collected every subscription and wrote the same consumption rows. Writes summary.json and summary.txt.
param([Parameter(Mandatory)] [string]$OutDir)
$ErrorActionPreference = 'Stop'

function Get-Median([double[]]$Values)
{
    $Sorted = @($Values | Sort-Object)
    if ($Sorted.Count -eq 0) { return $null }
    $Mid = [int][math]::Floor($Sorted.Count / 2)
    if ($Sorted.Count % 2 -eq 1) { return $Sorted[$Mid] }
    return ($Sorted[$Mid - 1] + $Sorted[$Mid]) / 2
}

$Runs = foreach ($MeasureFile in @(Get-ChildItem -LiteralPath $OutDir -Filter '*.measure.json' | Sort-Object Name))
{
    $Measure = Get-Content -Raw -LiteralPath $MeasureFile.FullName | ConvertFrom-Json
    $ResultPath = Join-Path $OutDir ($Measure.Label + '.result.json')
    $Result = if (Test-Path -LiteralPath $ResultPath) { Get-Content -Raw -LiteralPath $ResultPath | ConvertFrom-Json } else { $null }
    $Subs = if ($Result) { @($Result.Subscriptions) } else { @() }
    [pscustomobject]@{
        Label            = $Measure.Label
        Run              = $Measure.Run
        ExitCode         = $Measure.ExitCode
        WallSeconds      = [double]$Measure.WallSeconds
        CpuSeconds       = [double]$Measure.CpuSeconds
        PeakThreads      = [double]$Measure.PeakThreads
        PeakWorkingSetMB = [double]$Measure.PeakWorkingSetMB
        PeakCommitMB     = [double]$Measure.PeakCommitMB
        PeakProcesses    = [double]$Measure.PeakProcesses
        SubsOk           = (@($Subs).Count -gt 0 -and @($Subs | Where-Object { -not $_.Ok }).Count -eq 0)
        Rows             = (@($Subs | Sort-Object Sub | ForEach-Object { '{0}={1}' -f $_.Sub, $_.ConsumptionRows }) -join '; ')
        ContextAfter     = if ($Result) { [string]$Result.ProcessContextAfter } else { '' }
        Errors           = (@($Subs | Where-Object { $_.Error } | ForEach-Object { '{0}: {1}' -f $_.Sub, $_.Error }) -join ' | ')
    }
}
$Runs = @($Runs)
# A run that did not collect every subscription is not a comparable measurement: it is listed, not averaged.
$Valid = @($Runs | Where-Object { $_.ExitCode -eq 0 -and $_.SubsOk })
$Invalid = @($Runs | Where-Object { $_ -notin $Valid })

$Designs = foreach ($Group in @($Valid | Group-Object Run))
{
    $Row = [ordered]@{ Run = $Group.Name; Count = $Group.Count }
    foreach ($Metric in 'WallSeconds', 'CpuSeconds', 'PeakThreads', 'PeakWorkingSetMB', 'PeakCommitMB', 'PeakProcesses')
    {
        $Values = [double[]]@($Group.Group | ForEach-Object { $_.$Metric })
        $Row[$Metric] = Get-Median $Values
        $Row[$Metric + 'Range'] = '{0}-{1}' -f ($Values | Measure-Object -Minimum).Minimum, ($Values | Measure-Object -Maximum).Maximum
    }
    [pscustomobject]$Row
}

$Summary = [pscustomobject]@{
    Host         = [pscustomobject]@{ VCpu = [Environment]::ProcessorCount; RamGB = $(if ($IsWindows) { [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1) } else { $null }); Pwsh = $PSVersionTable.PSVersion.ToString(); AzAccounts = [string](Get-Module Az.Accounts -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1).Version }
    AllOk        = ($Invalid.Count -eq 0)
    ValidRuns    = $Valid.Count
    InvalidRuns  = @($Invalid | ForEach-Object { $_.Label })
    SameRows     = ($Valid.Count -gt 0 -and @($Valid | Select-Object -ExpandProperty Rows -Unique).Count -eq 1)
    SameContext  = ($Valid.Count -gt 0 -and @($Valid | Select-Object -ExpandProperty ContextAfter -Unique).Count -eq 1)
    Designs      = @($Designs)
    Runs         = $Runs
}
$Summary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutDir 'summary.json')
@(
    ('Host: {0} vCPU, {1} GB RAM, pwsh {2}, Az.Accounts {3}' -f $Summary.Host.VCpu, $Summary.Host.RamGB, $Summary.Host.Pwsh, $Summary.Host.AzAccounts)
    ('Valid runs (every subscription collected): {0} of {1}; excluded: {2}' -f $Summary.ValidRuns, $Runs.Count, ($(if ($Invalid.Count) { $Summary.InvalidRuns -join ', ' } else { 'none' })))
    ('Same consumption rows in every valid run: {0}; same process context after every valid run: {1}' -f $Summary.SameRows, $Summary.SameContext)
    ''
    ($Designs | Format-Table Run, Count, WallSeconds, WallSecondsRange, CpuSeconds, CpuSecondsRange, PeakThreads, PeakThreadsRange, PeakWorkingSetMB, PeakWorkingSetMBRange, PeakCommitMB, PeakProcesses -AutoSize | Out-String -Width 400)
    ($Runs | Format-Table Label, ExitCode, WallSeconds, CpuSeconds, PeakThreads, PeakWorkingSetMB, PeakCommitMB, PeakProcesses, SubsOk, Rows -AutoSize | Out-String -Width 400)
    ($Runs | Where-Object { $_.Errors } | ForEach-Object { 'ERRORS {0}: {1}' -f $_.Label, $_.Errors })
) | Set-Content -LiteralPath (Join-Path $OutDir 'summary.txt')
