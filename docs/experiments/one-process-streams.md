# Experiment: one `pwsh` process for all parallel streams

Branch `exp/one-process-streams`.
Nothing here is on `main`.
The scripts that produced every number below are in `experiments/one-process-streams/`.

## Summary

- Each parallel stream is a separate `pwsh` process today because the inventory script selected subscriptions with `Set-AzContext`, and that context is shared by every runspace in a process.
- `Set-AzContext` also rewrote the operator's saved default subscription in three places: a standalone run with consumption on, a sequential wrapper run, and the wrapper's up-front consumption probe.
- Step 2 replaces every `Set-AzContext` call with a per-subscription profile passed through a function-local `$PSDefaultParameterValues['*:DefaultProfile']`.
  The outputs are unchanged, and neither the process context nor the saved default moves any more.
- With that in place, three subscriptions ran concurrently in ONE process with correct per-subscription data.
  Against today's one-process-per-stream design it used about half the threads and 16-38% less memory.
  With .NET Server GC it also finished about 6% sooner at the same CPU; with the default GC it used 16% less CPU but took about 10% longer.

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

- Every run of every design wrote the same consumption rows per subscription (619, 8 and 0), and none moved the process context.
- **One process, default GC:** median CPU 16% lower, threads 63% fewer, peak memory 38% lower, but wall time about 10% longer.
  One GC heap pauses every stream at once; that is an inference, but Server GC (parallel collection, one heap per core) recovered the time.
- **One process, Server GC:** median wall time 6% shorter, CPU the same, threads 50% fewer, peak memory 16% lower.
  Server GC keeps more memory than the default GC: its peak ranged from 728 to 883 MB.
- **The sequential floor** shows what the parallelism buys: half the wall time, for about 50% more CPU.

### Caveats

- Small sample: 3-4 runs per design, and the wall time is set by the one subscription with data.
  A real tenant has far more data per subscription, which makes the per-process saving (about 200 MB per stream) smaller in proportion but no smaller in MB.
- The process design here mimics the core of `Run-AllSubscriptions.Stream.ps1` (context snapshot, autosave off, the same per-subscription call), not the wrapper's state files, summaries and aggregation.
- macOS only.
  The one-process design changes process invocation, so it needs the Windows run the cross-OS rule asks for before it is considered verified.
- The shared metrics pool was not measured, because of the ownership problem above.

## Next steps

1. Review and merge step 2 on its own: it fixes the saved-default side effect and removes the only reason streams must be processes.
2. Implement the one-process wrapper behind a switch (`-StreamIsolation Runspace|Process`), with the shared queue, per-runspace scoping, Server GC, per-subscription memory admission and `SetMinRunspaces`.
3. Measure it with the customer replay and on Windows, then decide the default.
