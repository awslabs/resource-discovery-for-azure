# Windows counterpart of measure.sh and sample-tree.sh: runs Step 3 designs one after another, each in a
# fresh pwsh process (Step3-WinRun.ps1) placed in its own Windows job object. Every process that run
# starts (the Start-Job stream processes included) joins the same job, so:
#   CPU      = the job's TotalUserTime + TotalKernelTime: exact, including processes that already exited
#   threads  = peak, summed over the job's live processes, sampled every second
#   memory   = peak working set summed over the job's live processes, sampled every second (as RSS on
#              macOS), plus the job's own peak committed memory
# Writes <label>.measure.json and <label>.result.json per run into $OutDir. Measurement only.
param(
    [Parameter(Mandatory)] [string]$Tree,
    [Parameter(Mandatory)] [string]$OutDir,
    [Parameter(Mandatory)] [string]$TokenFile,
    [string[]]$Runs = @('processes', 'runspaces', 'runspaces-servergc'),
    [string]$Batch = 'a',
    [int]$Streams = 3,
    [int]$ConcurrencyLimit = 6
)
$ErrorActionPreference = 'Stop'

if (-not ('RdaJobObject' -as [type]))
{
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;

public static class RdaJobObject
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool QueryInformationJobObject(IntPtr job, int infoClass, IntPtr info, int length, out int returnLength);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr handle);

    public static IntPtr Create()
    {
        IntPtr job = CreateJobObject(IntPtr.Zero, null);
        if (job == IntPtr.Zero) { throw new System.ComponentModel.Win32Exception(); }
        return job;
    }

    public static void Assign(IntPtr job, IntPtr process)
    {
        if (!AssignProcessToJobObject(job, process)) { throw new System.ComponentModel.Win32Exception(); }
    }

    public static void Close(IntPtr job) { CloseHandle(job); }

    static IntPtr Query(IntPtr job, int infoClass, int size)
    {
        IntPtr buffer = Marshal.AllocHGlobal(size);
        int written;
        if (!QueryInformationJobObject(job, infoClass, buffer, size, out written))
        {
            int error = Marshal.GetLastWin32Error();
            Marshal.FreeHGlobal(buffer);
            throw new System.ComponentModel.Win32Exception(error);
        }
        return buffer;
    }

    // JOBOBJECT_BASIC_ACCOUNTING_INFORMATION (class 1): user and kernel time in 100 ns units at offsets
    // 0 and 8, TotalProcesses at 36. Returns { cpuSeconds, totalProcesses }.
    public static double[] Accounting(IntPtr job)
    {
        IntPtr buffer = Query(job, 1, 48);
        try
        {
            long user = Marshal.ReadInt64(buffer, 0);
            long kernel = Marshal.ReadInt64(buffer, 8);
            int total = Marshal.ReadInt32(buffer, 36);
            return new double[] { (user + kernel) / 1e7, total };
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    // JOBOBJECT_EXTENDED_LIMIT_INFORMATION (class 9), 144 bytes on x64: PeakJobMemoryUsed at offset 136.
    public static double PeakCommitMB(IntPtr job)
    {
        IntPtr buffer = Query(job, 9, 144);
        try { return Marshal.ReadInt64(buffer, 136) / 1048576.0; }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    // JOBOBJECT_BASIC_PROCESS_ID_LIST (class 3): the live process ids, from offset 8.
    public static HashSet<int> ProcessIds(IntPtr job)
    {
        const int capacity = 512;
        IntPtr buffer = Query(job, 3, 8 + capacity * IntPtr.Size);
        try
        {
            int count = Marshal.ReadInt32(buffer, 4);
            HashSet<int> ids = new HashSet<int>();
            for (int i = 0; i < count; i++) { ids.Add((int)Marshal.ReadIntPtr(buffer, 8 + i * IntPtr.Size).ToInt64()); }
            return ids;
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    // One system snapshot, filtered to the job: { processes, threads, workingSetBytes }.
    public static long[] Sample(IntPtr job)
    {
        HashSet<int> ids = ProcessIds(job);
        long processes = 0, threads = 0, workingSet = 0;
        foreach (Process process in Process.GetProcesses())
        {
            try
            {
                if (ids.Contains(process.Id))
                {
                    threads += process.Threads.Count;
                    workingSet += process.WorkingSet64;
                    processes++;
                }
            }
            catch { }
            finally { process.Dispose(); }
        }
        return new long[] { processes, threads, workingSet };
    }
}
'@
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$Pwsh = (Get-Process -Id $PID).Path
$RunScript = Join-Path $Tree 'experiments/one-process-streams/Step3-WinRun.ps1'
$Index = 0
foreach ($Run in $Runs)
{
    $Index++
    $Label = '{0}{1:d2}-{2}' -f $Batch, $Index, $Run
    $Design = if ($Run -eq 'runspaces-servergc') { 'runspaces' } else { $Run }
    $ResultFile = Join-Path $OutDir ($Label + '.result.json')
    $ArgumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $RunScript, '-Tree', $Tree, '-Design', $Design, '-ResultFile', $ResultFile, '-TokenFile', $TokenFile, '-Streams', [string]$Streams, '-ConcurrencyLimit', [string]$ConcurrencyLimit)
    if ($Run -eq 'runspaces-servergc') { $env:DOTNET_gcServer = '1' } else { Remove-Item -LiteralPath Env:\DOTNET_gcServer -ErrorAction SilentlyContinue }
    $Job = [RdaJobObject]::Create()
    $PeakThreads = 0; $PeakWorkingSet = 0; $PeakProcesses = 0
    $Clock = [System.Diagnostics.Stopwatch]::StartNew()
    $Child = Start-Process -FilePath $Pwsh -ArgumentList $ArgumentList -NoNewWindow -PassThru -RedirectStandardOutput (Join-Path $OutDir ($Label + '.out.txt')) -RedirectStandardError (Join-Path $OutDir ($Label + '.err.txt'))
    [RdaJobObject]::Assign($Job, $Child.Handle)
    while (-not $Child.WaitForExit(1000))
    {
        $Sample = [RdaJobObject]::Sample($Job)
        if ($Sample[0] -gt $PeakProcesses) { $PeakProcesses = $Sample[0] }
        if ($Sample[1] -gt $PeakThreads) { $PeakThreads = $Sample[1] }
        if ($Sample[2] -gt $PeakWorkingSet) { $PeakWorkingSet = $Sample[2] }
    }
    $Clock.Stop()
    $Accounting = [RdaJobObject]::Accounting($Job)
    $PeakCommit = [RdaJobObject]::PeakCommitMB($Job)
    [RdaJobObject]::Close($Job)
    Remove-Item -LiteralPath Env:\DOTNET_gcServer -ErrorAction SilentlyContinue
    [pscustomobject]@{
        Label            = $Label
        Run              = $Run
        Design           = $Design
        ServerGC         = ($Run -eq 'runspaces-servergc')
        ExitCode         = $Child.ExitCode
        WallSeconds      = [math]::Round($Clock.Elapsed.TotalSeconds, 1)
        CpuSeconds       = [math]::Round($Accounting[0], 1)
        TotalProcesses   = [int]$Accounting[1]
        PeakProcesses    = [int]$PeakProcesses
        PeakThreads      = [int]$PeakThreads
        PeakWorkingSetMB = [math]::Round($PeakWorkingSet / 1MB)
        PeakCommitMB     = [math]::Round($PeakCommit)
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutDir ($Label + '.measure.json'))
}
