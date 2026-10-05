# Experiment: one `pwsh` process for all parallel streams

Branch `exp/one-process-streams`.
Nothing here is on `main`.
The scripts that produced every number below are in `experiments/one-process-streams/`.

## Summary

- Each parallel stream is a separate `pwsh` process today because the inventory script selected subscriptions with `Set-AzContext`, and that context is shared by every runspace in a process.
- `Set-AzContext` also rewrote the operator's saved default subscription in three places: a standalone run with consumption on, a sequential wrapper run, and the wrapper's up-front consumption probe.
- Step 2 replaces every `Set-AzContext` call with a per-subscription profile passed through a function-local `$PSDefaultParameterValues['*:DefaultProfile']`.
  The outputs are unchanged, and neither the process context nor the saved default moves any more.
- With that in place, three subscriptions ran concurrently in ONE process, and each subscription's consumption count came out right.
  Against today's one-process-per-stream design it used about half the threads and 16-38% less memory.
  With .NET Server GC it also finished about 6% sooner at the same CPU; with the default GC it used 16% less CPU but took about 10% longer.
- That prototype checked the in-memory counts, not the report folders, and the folders could collide: the report stamp's tail was the PID alone, so two streams of one process that started a subscription in the same millisecond wrote into one folder.
  On the Windows box it happened in 5 of 8 in-process runs, each time losing a subscription's report.
  Step 4 fixes the stamp.
- Step 4 puts the one-process design into the real wrapper behind `-StreamIsolation Runspace`, with `Process` (separate `pwsh` processes) staying the default.
  On macOS, 3 runs of each mode produced identical bundles; the runspace mode used 65% fewer threads, 32% less peak memory and 14% less CPU, for a median wall time 6% longer.
- On the 2-vCPU Windows test box, with the stamp fix, the one-process prototype was better on every measure (at least 20% faster, 20-30% less CPU, at least 40% less peak memory), and the real wrapper produced the same bundle contents in both modes.
- Step 5 adds a free-memory admission check under `Runspace`: before each subscription a stream waits until `-StreamMemoryGB` (default 2) GB is free, unless no other subscription is in progress, and waiting streams are admitted in arrival order.
  The reading comes from the .NET garbage collector, with no OS command, and matched the OS's own figure on macOS and Windows; on Windows only an aggressive collection hands a dropped heap back.

## Step 1: what `Set-AzContext` does to the saved default

Context autosave on this host is `CurrentUser`, so Az persists the current context to `AzureRmContext.json`, and a new session starts on whatever subscription was last selected.
Each check below reads the saved default from a NEW `pwsh` process, which is what an operator's next session sees (`Step1-SavedDefault.ps1`).

| Check | Saved default seen by the next session |
|---|---|
| A1. `Set-AzContext -Subscription <other> -Scope Process` | unchanged |
| A2. `Set-AzContext -Subscription <other>`, no `-Scope` | moved to `<other>` |
| A3. `Disable-AzContextAutosave -Scope Process`, then `Set-AzContext <other>` (what each parallel stream does) | unchanged |
| B1. `ResourceInventory.ps1` on `<other>`, every billing phase skipped | unchanged |
| B2. `ResourceInventory.ps1` on `<other>`, consumption on | **moved to `<other>`** |
| C1. `Run-AllSubscriptions.ps1`'s `Test-ConsumptionAccess` probe on `<other>` | **moved to `<other>`** |
| D1. One process: the main runspace selects `<home>`, a second runspace selects `<other>`; the main runspace then reads | `<other>` |

So there are two separate effects:

- **In memory, inside one process (D1).**
  The current context is one object for the whole process.
  This is what forces each stream into its own process: two subscriptions in one process would race the same context.
- **On disk, across sessions (B2, C1).**
  Without `-Scope Process`, the switch is also saved as the default.
  The parallel streams are protected because they disable autosave for their process (A3).
  A standalone run, the sequential wrapper path and the wrapper's probe are not.

## Step 2: subscription selection without `Set-AzContext`

### Mechanism

- `Get-RdaSubscriptionProfile` (`Functions/Common.Functions.ps1`) copies the signed-in context into a new `PSAzureContext`, swaps only its subscription, and converts it to the `IAzureContextContainer` that every Az cmdlet's `-DefaultProfile` accepts.
  It throws when the subscription is not visible to the identity, as `Set-AzContext` did, so every caller keeps its existing skip path.
- Each phase that used to call `Set-AzContext` (consumption, Marketplace, Foundry tokens, Foundry coverage, and the consumption and Marketplace re-pin after a reconnect) now does this instead:

```powershell
# once, at the top of the phase function: a copy that lives only as long as the function
$PSDefaultParameterValues = [System.Management.Automation.DefaultParameterDictionary]::new($PSDefaultParameterValues)
# per subscription, where Set-AzContext used to be
$PSDefaultParameterValues['*:DefaultProfile'] = Get-RdaSubscriptionProfile -SubscriptionId $sub.id
```

- `$PSDefaultParameterValues` is resolved through the scope chain at each call, so every Az cmdlet the phase calls, helpers in the function files included, gets the profile.
  It applies to cmdlets and advanced functions, which is what the Az commands are.
  When the phase function returns, the copy goes with it.
- The existing check `(Get-AzContext).Subscription.Id -eq $sub.id` still runs, and now verifies the scoping.
- `Test-DataPlaneAuthReady` removes the key for itself, so a reconnect (`Connect-AzAccount`) still lands in the process profile, and the caller re-pins as before.
- `Test-ConsumptionAccess` in the wrapper scopes its probe the same way.

The alternatives considered were adding `-DefaultProfile` to every Az call by hand, which is easy to miss once and then silently reads the wrong subscription, and calling the billing REST API with the subscription in the path, which changes the data path behind `Consumption_*.csv`.

### Evidence

| Check | Result |
|---|---|
| A per-subscription profile, built in a process whose context is on a DIFFERENT subscription (`Step2-ScopeProbe.ps1`, `Step2-Reverse.ps1`) | `Get-AzContext -DefaultProfile` reads the target; `Get-UsageAggregates -DefaultProfile` returned the target's 372 rows, every resource URI naming only the target; the process context did not move |
| The same billing window via `Set-AzContext` and via the profile | identical rows |
| `ResourceInventory.ps1` on the main subscription with the process context deliberately on an empty one, old code against new (`Step2-DecoyRun.ps1`) | both wrote the same 619 consumption rows with the same content hash; the old code moved the process context, the new code did not |
| Step 1 re-run on the new code | B2 and C1 now leave the saved default unchanged |
| Scenario matrix, all 10 scenarios | all passed, 0 failures (obfuscate: 143 passed) |
| Pester: the 19 files covering these phases and the wrapper probe | 991 passed, 0 failed; analyzer 0 findings |

## Step 3: one process for all streams

### Design

- **One `pwsh` process, one runspace per stream.**
  PowerShell globals are per runspace, so every approved `$Global:` variable stays per stream without a code change.
  Az's .NET assemblies load once; each extra stream costs about 19 MB of PowerShell state instead of about 220 MB for a whole process (measured earlier on this host).
- **Per-subscription context isolation.**
  Before each subscription, the stream runspace sets its own `$PSDefaultParameterValues['*:DefaultProfile'] = Get-RdaSubscriptionProfile -SubscriptionId <id>`.
  That scopes discovery, the collectors and every phase, including `Get-AzComputeResourceSku` in the VM and scale-set collectors, which, as far as the code shows, today read whatever subscription the process context happens to be on (not verified at run time).
  A runspace's `$PSDefaultParameterValues` is part of its own session state, so streams cannot see each other's.
  The phase-local copies from step 2 sit on top of it.
- **Work distribution.**
  A `ConcurrentQueue` of subscriptions replaces the static slices: each stream takes the next subscription when it is free, which the customer replay showed comes within about 1% of the best possible split (8.26-8.30 h against 8.20 h).
  Completion events go to one writer on the main thread, which keeps saving resume state exactly as now, so there is no file contention.
- **Metrics runspace pool.**
  - First version: each stream keeps its own pool in its own `$Global:MetricCallPool`, as today, with `SetMinRunspaces` so it stays warm.
  - Later: one host-owned pool shared by every stream, with a `SemaphoreSlim` enforcing the host-wide limit on calls in flight exactly, instead of dividing it statically per stream.
    This needs an ownership change first: today a stream that finds the pool busy at the end of its metrics phase retires and closes it, which would close it under the other streams.
- **Process-wide state that becomes shared.**
  The billing-library tracing listeners (switch tracing off once per process), PowerShell's type-table cache (its cap becomes shared, which helps), one GC heap (see the measurements), the .NET current directory (set once at start), and environment variables (already identical for every stream).
- **Failure isolation.**
  A crash or out-of-memory error now takes down every stream, where today only one stream dies and is recovered.
  Mitigations: a per-subscription `try`/`catch` (already there), checking free memory before each subscription with stream 0 never waiting, and keeping the process design as an opt-in switch.
- **Console.**
  Runspaces have no host, so each stream writes its output to its own log, and the main thread draws the progress.

### Measurements

Three sandbox subscriptions (one with data, two near-empty), 3 streams, `-ConcurrencyLimit 6`, default flags, macOS, 11 vCPU.
Each run calls `ResourceInventory.ps1 -RunAllSubs` exactly as a stream does (`Step3-Streams.ps1`, `measure.sh`).
CPU is user plus system time for the process and its children (`/usr/bin/time -l`); threads and memory are peaks summed over the whole process tree, sampled every second (`sample-tree.sh`).

| Design | Wall time (s) | CPU (s) | Peak threads | Peak memory, all processes (MB) | Processes |
|---|---|---|---|---|---|
| Processes, as today (3 runs) | 74.0 / 81.1 / 67.7 | 64.2 / 73.9 / 66.4 | 144 / 137 / 133 | 932 / 892 / 940 | 4 |
| One process, runspaces, default GC (4 runs) | 81.2 / 102.2 / 82.1 / 80.8 | 56.4 / 57.0 / 54.1 / 55.1 | 58 / 49 / 47 / 52 | 550 / 579 / 662 / 574 | 1 |
| One process, runspaces, Server GC (4 runs) | 72.2 / 69.3 / 65.6 / 69.5 | 65.7 / 66.1 / 64.2 / 68.2 | 68 / 68 / 67 / 70 | 745 / 728 / 825 / 883 | 1 |
| One process, one stream (sequential floor) | 140.6 | 44.8 | 45 | 441 | 1 |

- Every run of every design counted the same consumption rows per subscription (619, 8 and 0, counted in memory), and none moved the process context.
- **One process, default GC:** median CPU 16% lower, threads 63% fewer, peak memory 38% lower, but wall time about 10% longer.
  One GC heap pauses every stream at once; that is an inference, but Server GC (parallel collection, one heap per core) recovered the time.
- **One process, Server GC:** median wall time 6% shorter, CPU the same, threads 50% fewer, peak memory 16% lower.
  Server GC keeps more memory than the default GC: its peak ranged from 728 to 883 MB.
- **The sequential floor** shows what the parallelism buys: half the wall time, for about 50% more CPU.

### Caveats

- Small sample: 3-4 runs per design, and the wall time is set by the one subscription with data.
  A real tenant has far more data per subscription, which makes the per-process saving (about 200 MB per stream) smaller in proportion but no smaller in MB.
- The process design here mimics the core of `Run-AllSubscriptions.Stream.ps1` (context snapshot, autosave off, the same per-subscription call), not the wrapper's state files, summaries and aggregation.
- These measurements are from macOS; the Windows runs are in their own section below.
- The shared metrics pool was not measured, because of the ownership problem above.
- The prototype checked each subscription's consumption count in memory, not the report folders it wrote.
  Those folders could collide (see Step 4), so the prototype's outputs on disk were not verified.

## Step 4: `-StreamIsolation Runspace` in the real wrapper

`Run-AllSubscriptions.ps1 -StreamIsolation Runspace` runs every parallel stream as a thread job in the wrapper's own process.
`-StreamIsolation Process`, the default, keeps today's separate `pwsh` processes, and nothing on that path changes.

### What changes under `Runspace`

- **Launch.** Each stream is started with `Start-ThreadJob -ThrottleLimit <streams>` instead of `Start-Job`, running the same `Run-AllSubscriptions.Stream.ps1` with `-SharedProcess`.
  The thread-job throttle is process-wide and defaults to 5, so it is raised to the stream count; a stream over it would wait in `NotStarted`.
- **No snapshot.** The streams use the process's own signed-in context, so the wrapper writes no context snapshot and no token cache reaches the disk.
- **Start wait.** A thread job can still be `NotStarted` when `Start-ThreadJob` returns, and the wrapper's monitoring loop watches only `Running`, so it would end at once; the wrapper first waits (at most 60 seconds) for every stream to start.
  A stream that is still queued when that wait ends is stopped and named in the console, so it cannot start later while the wrapper merges the stream state; it is then reported as a stream with no summary.
- **Pool release.** Each stream's metrics worker pool lives in its runspace's `$Global:MetricCallPool`, so the thread job releases it with `Close-RdaMetricWorkerPool` when the stream ends; a stream process releases its pool by exiting.
- **Worker.** With `-SharedProcess` the worker skips the three process-wide steps a stream process takes: moving the .NET process directory to the temp folder, disabling context autosave and importing the snapshot.
- **Fallback.** If a thread job cannot be started, the wrapper falls back to the sequential path, as it does when `Start-Job` is blocked.

Everything else is the same code in both modes: the split of subscriptions across streams, the per-stream state files and summaries, dead-stream recovery and aggregation.
A shared work queue and one metrics pool for all streams are not part of this change.

### The report-stamp collision

`ResourceInventory.ps1` names each report folder and archive with a stamp: the time to the millisecond plus a 4-hex tail that was the PID alone.
Streams in one process share one PID, so two streams that start a subscription in the same millisecond got the same stamp, and so the same report folder.
That is not rare: the streams finish loading the Az modules at nearly the same moment.
In the first macOS run of the switch all three streams stamped their subscription in the same millisecond, and on the Windows box at least 5 stamps were shared between subscriptions during the prototype runs.

The tail now mixes in the runspace id: `($PID -bxor ([long]([runspace]::DefaultRunspace.Id - 1) * 0x9E37)) -band 0xffff`.
The first runspace of a process (id 1, which is what a standalone run, the sequential wrapper and each stream process use) keeps the plain PID value, so nothing changes outside the runspace mode.
The odd multiplier keeps every other runspace id distinct within the 4 hex digits.
`Tests/StampCollision.Tests.ps1` runs the statement for 2,000 runspace ids and in 3 concurrent thread jobs; against the previous statement both checks fail.

### Live runs on macOS

The real wrapper against the 3 sandbox subscriptions, `-ParallelStreams 3 -ConcurrencyLimit 6 -AllowPartialAccess`, 3 runs per mode in the order Process, Runspace, Runspace, Process, Runspace, Process (measured with `/usr/bin/time -l` and the process-tree sampler).

| Mode | Wall time (s) | CPU (s) | Peak threads | Peak memory, all processes (MB) | Processes |
|---|---|---|---|---|---|
| `Process` (default) | 74.3 / 87.2 / 76.1 | 75.1 / 65.4 / 67.8 | 138 / 137 / 138 | 1053 / 939 / 1149 | 4 |
| `Runspace` | 80.4 / 90.4 / 70.2 | 59.1 / 58.4 / 49.1 | 49 / 48 / 47 | 717 / 711 / 550 | 1 |

- **Same output.** All 6 consolidated bundles had the same 29 entries with the same row counts (Consumption 623 / 12 / 0, 34 metric records), and the RunSummary health blocks matched.
  The one difference was a single metric call retried once in the first runspace run; the retry succeeded, the debug log does not record its cause, and no call was retried in the other 5 runs.
- **Medians.** The runspace mode used 65% fewer threads, 32% less peak memory and 14% less CPU, for a wall time 6% longer; the wall-time ranges overlap.
- **Side effects.** Neither mode moved the saved default subscription, and neither left a context snapshot behind.
- **Memory readings.** Under `Runspace` the `Memory (MB, ...)` block in `RunSummary.log` measures the whole shared process, so a stream's readings include the other streams' memory, and its per-resource estimate can come out as 0.

## Windows Server 2022

### Setup

- The owner's Windows test instance: 2 vCPU, 8 GB, unlimited CPU credits, PowerShell 7.4 or later.
  Every command ran as SYSTEM through SSM, signed in from a short-lived ARM token relayed from the macOS session; the token file was deleted after each batch.
- SYSTEM had no `Az.CognitiveServices`, so RDA's six required Az modules were installed into SYSTEM's own module scope.
- `Step3-Windows.ps1` runs each design in a fresh `pwsh` process inside a Windows job object.
  Every process that run starts joins the job, so the CPU figure (the job's user plus kernel time) is exact, stream processes included, and the job's processes are sampled every second for threads and working set.
  `Step3-WinRun.ps1` signs that process in from the relayed token; `Step3-WinSummary.ps1` takes the medians over the runs that collected every subscription.
- The agent's policy blocks reading SSM command output back (`aws-destructive-ssm-get-command-invocation`), so every result below came back as the yes/no exit status of a question asked on the box.
  The exact figures stay on the box in `summary.txt` and `summary.json` under `C:\Windows\Temp\rda-step3\results` and `results2`, and `e2e\e2e-summary.json`.

### The prototype on the code before Step 4 (13 runs)

- The first 3 runs failed because SYSTEM's inventory root did not exist yet: the prototype, unlike the wrapper, does not create it before the processes design saves its context snapshot there.
- From then on every process-design run collected every subscription, but 3 of the 6 in-process runs lost a subscription's report, as had the 2 in-process runs while the root was being created.
  At least 5 report stamps were shared by two subscriptions: the collision Step 4 fixes.
- Over the valid runs (processes 3, runspaces 2, runspaces with Server GC 1, sequential 1), against the processes design:

| Question | Runspaces, default GC | Runspaces, Server GC |
|---|---|---|
| Peak threads at most half? | yes | - |
| Peak working set at most 70%? | yes | lower: yes |
| Peak commit lower? | yes | - |
| CPU at most 80%? | yes | lower: yes |
| Wall time no longer? | yes (but not 10% shorter) | yes, and no longer than default GC |

- The main subscription's consumption row count differed between valid runs (two values over about 45 minutes); the other two subscriptions' counts matched.
  Not explained: the box cannot tell me which runs differed by how much without a run of questions per run.

### The prototype with Step 4 (10 runs)

The same prototype on the Step 4 code: 3 runs per design in the order processes, runspaces, runspaces with Server GC, repeated three times, then the sequential floor.

- All 10 runs collected every subscription, and every run counted the same consumption rows per subscription.
- Medians against the processes design, as brackets (each bound is a separate yes/no question):

| Measure | Runspaces, default GC | Runspaces, Server GC |
|---|---|---|
| Peak threads | 40-50% of processes | at most 60% |
| Peak working set | at most 60% | at most 80% |
| Peak commit | no higher | no higher |
| CPU | 70-80% | at most 90% |
| Wall time | at most 80% | no longer than default GC, so at most 80% too |

- So on this 2-vCPU host the one-process design was better on every measure: at least 20% faster, 20-30% less CPU, at least 40% less peak working set and 50-60% fewer threads.
  Server GC was faster still; how its memory compares with the default GC was not asked.
- The sequential floor took less than 1.5 times the processes design's wall time: with 2 vCPUs, three streams buy less than on macOS.

### The real wrapper

`Run-AllSubscriptions.ps1 -ParallelStreams 3 -ConcurrencyLimit 6 -AllowPartialAccess`, 2 runs per mode in the order Process, Runspace, Process, Runspace.

- All 4 exited 0 and built a bundle, and no context snapshot was left behind.
- Every bundle had the same entries with the same row counts, and the RunSummary health blocks were identical.
  The per-subscription archives appear in the bundle in stamp order, which differs between the modes, so a comparison of the bundles has to sort the entries first.
- Each runspace run was 1 process; each process run peaked at 4 or more.
- Runspace against Process (mean of 2): peak threads at most half, peak working set at most 80%, CPU at most 90%, and wall time no longer.

### Pester on Windows

- The 5 test files that cover the change (`RunAllSubscriptionsReconciliation`, `StampCollision`, `ParamForwardingParity`, `MemoryRelease`, `CollectorBreakerAndVisibility`): every test added for Step 4 passes, and against the code before Step 4 those tests fail, as they should.
- 4 existing tests fail on this box with and without the change (the failing set is the same), so they are not caused by it.
  Three are the two `Write-RdaHostLinesInTranscript` tests that check the colours and the transcript (`appends them to the closed transcript`) and `keeps the markers and retries when the snapshot cannot be removed`; the fourth is named in `e2e\pester.json` on the box.
  Their cause was not established; they involve the host's transcript and a file that cannot be removed, which may well behave differently when PowerShell runs as SYSTEM under SSM with its output redirected.

## Step 5: free-memory admission under `Runspace`

Under `-StreamIsolation Runspace` the streams share one process, so one out-of-memory error ends every stream, and the billing download of a single subscription can take several GB.
Step 5 makes each stream ask for admission before every subscription.

### The check

- **State.** The wrapper creates one admission state, in the `Runspace` branch only (`New-StreamAdmissionState`, a synchronized hashtable), and passes that same instance to every thread job through the worker's new `-AdmissionState` parameter, which the worker uses only with `-SharedProcess`.
  It holds the floor (`-StreamMemoryGB`, default 2 GB, `0` turns the check off), the poll interval (15 seconds), the longest wait (30 minutes), the tokens of the subscriptions in progress, the queue of waiting tokens, when a waiter was last let in for waiting too long, and when the last full collection ran.
- **Lock.** `Enter-StreamAdmission` and `Exit-StreamAdmission` decide and record everything under a `System.Threading.Monitor` lock on the hashtable's own `SyncRoot`, which the state keeps under the key `Lock`, read once when the state is created.
  In a probe where two runspaces read one synchronized hashtable's `PSBase.SyncRoot` at the same moment, 36 of 80 reads returned `$null`, while `$State.SyncRoot` and a key never did.
  With `PSBase.SyncRoot` in the functions, 3 of 30 runs of the two-stream test admitted both streams at once.
  Errors inside the lock are rethrown, because in PowerShell a failed .NET call ends only its own statement, and the function would otherwise carry on without the lock.
- **Queue.** A stream that waits joins a queue, and only the one at its head can be admitted.
  The head is admitted when no other subscription is in progress (so one always runs and the streams cannot wait on each other forever), when free memory is at least the floor, or once it has waited 30 minutes, with a warning.
  That last way lets in at most one stream per 30 minutes.
  Only the head reads free memory, at most every 15 seconds.
  Waiters sleep in `Monitor.Wait` slices of at most a second, so a stop lands quickly, and every admission and release wakes them at once.
  A free-memory reading that throws admits the subscription with a warning instead of failing it.
- **Release.** Before each subscription the worker makes a token, and its `finally` block always passes it to `Exit-StreamAdmission`, whether the subscription was admitted, failed or was stopped; a token that is not recorded is left alone.
  A stream stopped while it waits leaves the queue in `Enter-StreamAdmission`'s own `finally` block.
- **Logging.** A stream logs once when it starts waiting (the subscription, free GB, the floor, the other subscriptions in progress and the streams ahead of it) and once when it is admitted, with the seconds it waited, through its usual `[stream-N]` console lines.
  The waiting line is made from what was read under the lock and written with the lock let go, so a slow log sink cannot hold up the other streams.
  A release in that gap cannot wake this stream, which is not asleep yet, so it looks again before its first sleep, and a stop or a failed write there still leaves the queue.
  With the wrapper's own sink the gain is small: in a thread job started the way the wrapper starts a stream, one `Write-Host` of this line took a median of 27-48 us and at most 9.2 ms, over 32,000 timed calls in two runs on the Mac, whether the parent was idle or relaying every 1.5 s or every 5 ms.
  The first write of a thread job took 85-131 ms, but a stream writes its `processing` line before it asks for admission, so the waiting line never pays it.
  Nothing is added to the Inventory, Metrics or Consumption output.
- **Process mode.** The wrapper creates no state and the worker gets none, so `-StreamIsolation Process` runs as before.
- **Parameters.** `-StreamIsolation` and `-StreamMemoryGB` are declared after every parameter `main`'s wrapper has, so a positional call binds as it does on `main`.
- **Limit.** The check reads the memory free when a subscription starts, not what the subscription will need, so streams that start together can all be admitted on the same free memory.
  It stops a stream from starting new work while memory is short; it cannot stop two subscriptions that are already running from growing together.

### Reading free memory

`Get-GcFreeMemoryGB` reads `[GC]::GetGCMemoryInfo()` after `[GC]::Collect(0)`.
The memory in use, `MemoryLoadBytes`, is measured against the machine's memory or a container's limit, whose size is `HighMemoryLoadThresholdBytes * 100 / GCHighMemPercent` (from `GC.GetConfigurationVariables()`, .NET 7 and later).
The figure is that size less the memory in use, and never more than the heap's room under its own limit, `TotalAvailableMemoryBytes - TotalCommittedBytes`.
Without a heap limit it equals `TotalAvailableMemoryBytes - MemoryLoadBytes`, the figure measured below; without the configuration variables it falls back to that.
A heap hard limit is what .NET sets by default inside a memory-limited container: 75% of the container's memory.
In a child `pwsh` with `DOTNET_GCHeapHardLimit=0x80000000` (2 GiB), the plain `TotalAvailableMemoryBytes - MemoryLoadBytes` read -9.52 GB on the Mac, because the limit replaces the total while the load stays the machine's.
On the Windows box the plain figure stayed between 0 and 2 GiB under the same limit, though not within 0.25 GB of the new one.
The new figure read between 0 and 2 GiB on both, and without a limit it equalled the plain one.
No container could be run here, so the container case itself is untested.

`[GC]::Collect(0)` collects at least generation 0, and the runtime can choose a higher one.
On the Mac 9 readings took 0.5-1.5 ms and one of them ran a gen-1 collection; an independent review measured up to 33 ms with freshly allocated objects on the heap, and a gen-1 or gen-2 collection in 3 of 9 readings.
The runtime keeps the load in whole percent of the total, so the reading moves in steps of 1%: 184 MB on the 18 GB Mac and about 80 MB on the 8 GB Windows box.
`Step5-MemoryReading.ps1` reads it before, while and after holding 400 MB from `Marshal.AllocHGlobal` filled with random bytes, beside the OS's own figure, and answers each check by its exit status.
The tolerance is one reading step plus 150 MB, and a check over several cycles uses the median.

| Check | macOS 26.6, .NET 10.0.5 | Windows Server 2022, PowerShell 7 |
|---|---|---|
| A gen-0 collection alone records the new load | yes: the OS figure fell 369 MB, and the gen-0 reading matched the full collection after it | yes |
| The reading drops by the allocation | yes: median 368 MB over 16 cycles of 400 MB (single cycles from 0 to 922 MB on a busy host) | yes, in a single cycle and as the median of 5 |
| It rises again when the block is freed | yes, within the tolerance: median 277 MB over 16 cycles | yes, in a single cycle and as the median of 5 |
| It matches the OS figure | yes: equal to `kern.memorystatus_level` of `hw.memsize` in 16 of the 18 phases of a 6-cycle run, one step apart in the other 2 | yes, against `Win32_OperatingSystem.FreePhysicalMemory` |
| Negative control: a 4,000 MB drop claimed for the 400 MB block | - | no, as it must be |

The streams share one heap, so memory a finished subscription left as garbage counts as used until a full collection.
The first time a waiting subscription's reading is below the floor it runs one full collection, not on every poll, and it skips it when another stream ran one within the poll interval.
With 400 MB of managed byte arrays dropped:

- On macOS a default full collection (`[GC]::Collect()`) gave the reading back within 2.3 seconds (the GC's committed memory fell from 410 to 137 MB), and an aggressive one did too (410 to 10 MB).
- On Windows a default full collection did not: the check failed in both of its runs.
  One-off probes (not kept) found that the reading did not rise even by 80 MB within 30 seconds, that the GC's committed memory did not fall by 200 MB, and that a compacting collection of the large object heap did not help either.
  An aggressive collection (`GCCollectionMode.Aggressive`, .NET 7 and later) gave it back on the first reading after it.

So `Get-GcFreeMemoryGB -Full` runs an aggressive collection, or a default one on a runtime without that mode.

### Tests

`Tests/RunAllSubscriptionsReconciliation.Tests.ps1` has 28 tests for the check, and each runs the code:

- `Enter-StreamAdmission` with an injected free-memory reader and log: it admits at once above the floor, admits below it when nothing else is in progress, waits and is admitted when memory recovers (one full collection before the first wait, gen-0 readings after), skips the full collection when one ran within the poll interval, is admitted after the longest wait with a warning, never waits with a floor of 0, and admits with a warning when the reading throws.
- A release wakes the waiting stream at once: with a 30 s poll interval it was admitted within 0.5 s of the release.
- The waiting line is written without the lock.
  A release that lands while it is being written still admits the stream at once, before its first 1 s sleep.
- Free memory is read, including the full collection, without the lock, so a slow reading does not stall the streams that are releasing.
  A write that throws, or a stop of the stream's thread job during the write, still leaves the queue and the lock, so the stream behind it is admitted.
  A caller that already holds the lock is refused, and its hold is left alone.
- While the test holds the lock, a stream neither queues nor is admitted, and it is admitted once the lock is free.
- Two thread jobs that always read memory below the floor, through 25 rounds that start together: one is admitted at a time, and the other only after the first releases.
- `Exit-StreamAdmission` releases only the token it is given.
- `Get-GcFreeMemoryGB` reads a figure from 0 up to the memory the runtime may use, stays between 0 and 2 GiB in a child `pwsh` under a 2 GiB heap hard limit, is unchanged there without one, and with `-Full` decommits 300 MB of dropped arrays (on macOS any full collection does that).
- The wrapper's parameter (default 2, accepts 0 to 1024), its parameter positions against `main` (skipped where git or `main` is missing), and its two `Runspace` blocks, lifted from the parsed source.
- The real worker with `-SharedProcess` against a stub inventory that fails one of three subscriptions: each ran as the only subscription admitted, and nothing was left in progress afterwards.
- The real worker as thread jobs, read only through their console lines, their summaries and the order the stub inventory saw, so the same tests run against the previous commit too:
  - a stream stopped while it waits for the lock leaves nothing in progress, so the next stream starts without waiting;
  - streams that wait are admitted in arrival order, so a stream that has just finished goes to the back of the queue;
  - with memory always short and a 1 s longest wait, the two decisions that let in two waiting streams for waiting too long are at least 1 s apart.
    They are timed where they are made, by the `LastOverride` stamp that `Enter-StreamAdmission` sets under the lock, not by the warnings the streams log after leaving it.
    Timed by the warnings, the test failed in 1 or 2 of 20 runs on the Windows box although every pair of decisions was at least 1 s apart: each time, the next stream's aggressive full collection (0.1-0.3 s, which pauses every thread) held the first warning back by more than 0.1 s.

Against a188284, 18 of the 23 fail on the Mac.
The three thread-job tests and the heap-limit test fail on what they check: the stream after the stopped one had to wait, the order was `a-1, a-2, a-3, c-1, b-1`, the two waiters were let in 0.13 s apart, and the figure under the limit was -9.52 GB.
The positions test fails because `-StreamIsolation` and `-StreamMemoryGB` came before `-HeadRoom`.
The other 13 fail because the tokens they use do not exist there, and 5 pass there.
On macOS, `RunAllSubscriptionsReconciliation` passed 259 of 259, `ParamForwardingParity` 12, `StampCollision` 5, `MemoryRelease` 51 and `CollectorBreakerAndVisibility` 97 (`ParallelStreamsAggregation` skips its 13 without a report zip).
On the Windows box all 23 pass, with the positions test skipped because the staged copy has no git history.
Against a188284 there, the three thread-job tests fail, and the heap-limit test passes, because there the plain figure stayed within the limit.
The rest of that file fails the same 3 tests with and without the change, as in Step 4, and `ParamForwardingParity` and `StampCollision` pass.

When the waiting line moved outside the lock, the line test and the release test failed on the code before it, on what they check: the lock was held during the write, and the stream waited 1.002 s.
The failed-write test passes there too, because with the line written under the lock the old cleanup already left the queue; it guards the new code, where the line is written with the lock let go.
The stop test, the probe the review of that change asked for, also passes on 63c9f86, which already took the lock back; the refusal test fails there, because the call returned instead of throwing.
Four mutations of the new code were each caught: writing the line under the lock again, sleeping without looking again first, and dropping the refusal by one test each, and leaving the queue only while holding the lock by both the failed-write and the stop test.
On macOS `RunAllSubscriptionsReconciliation` passed 264 of 264, with the four files above as before.
The branch now sits on the colour and snapshot test fixes, so on the Windows box the whole file passed under Pester 5.7.1 and 6.2.0, with 263 passed and only the positions test skipped each time, and the check's 28 tests gave 27 passed and 1 skipped in 3 of 3 runs.
A live run with `-StreamIsolation Runspace -StreamMemoryGB 64` on the Mac wrote the same waiting and admission lines as the code before, in the same order, and a consolidated bundle with the same 29 entries and row counts.
The same run with the refusal against 63c9f86, both after midnight so the billing window was the same, again gave the same lines and a bundle with no differences.
Runs on either side of midnight are not comparable on consumption rows: the window is 31 local days ending at local midnight, so it moves a day.

### Live runs on macOS

The real wrapper against the 3 sandbox subscriptions with `-ParallelStreams 3 -ConcurrencyLimit 6 -AllowPartialAccess`, one run each.

| Run | Wall time (s) | Peak memory (MB) | Waits |
|---|---|---|---|
| `Runspace -StreamMemoryGB 64` | 159 | 514 | 2 streams waited 43 and 73 s, in arrival order, each admitted when the subscription before it ended |
| `Runspace` (default 2 GB) | 83 | 637 | none |
| `Process` | 85 | - | no check |

- All 3 exited 0, and their bundles had the same 29 entries with the same row counts as in Step 4 (Consumption 623 / 12 / 0, 34 metric records).
- The `RunSummary.log` files differed only in the parameter lines and the memory readings.
- Every run printed the same warnings as the Step 4 runs (Marketplace `BadRequest` and an unsupported Foundry metric for 2 subscriptions each, and the unreadable tenant-root management group).
- Under the 64 GB floor the second stream logged 0 streams ahead of it and the third 1, and each was admitted in the same 1.5 s console batch as the line that ended the subscription before it.
  Before the queue, a waiting stream could sleep up to 15 s past that point: the same run took 184 s, with waits of 60 and 105 s.
- A `-StreamMemoryGB 0` run before the queue (113 s) produced the same bundle.
- Peak memory is the wrapper process's maximum resident set; under `Process` that leaves out the stream processes, so it is not shown.

## Next steps

1. Review step 2 on its own (it is on `fix/memory-per-sub`): it fixes the saved-default side effect and removes the only reason streams must be processes.
   Its user docs still describe `Set-AzContext` there (`docs/architecture-two-scripts.md`, `docs/variables/scaling-sharding-output.md`, `docs/ResourceInventory-line-by-line.md`); this branch updates the first two.
2. Before `Runspace` could become the default: measure the Step 5 admission check on a tenant with real billing volume, and decide whether it should also hold memory back for subscriptions that have just started, which it does not do.
3. Then the parts of the design not in Step 4: a shared work queue instead of the per-stream slices, `SetMinRunspaces` on the metrics pool, and one metrics pool for all streams.
4. Look into the 3 tests that fail on the Windows box with and without this work.
