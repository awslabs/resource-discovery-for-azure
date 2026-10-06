# Why two scripts? (`ResourceInventory.ps1` + `Run-AllSubscriptions.ps1`)

A recurring question when reading the source: why is RDA split into an inner
per-subscription script (`ResourceInventory.ps1`) and a tenant-wide wrapper
(`Run-AllSubscriptions.ps1`), joined by a private `-RunAllSubs` switch, instead
of one script that loops over every subscription with all the logic inside?

The short answer is that the billing phases once had to point the whole `pwsh` process at one subscription, so two subscriptions could never be collected in one process at the same time.
The rest of the design followed from that constraint.
The constraint is gone now (see the next sections), but the split stays: it is what lets a stream or a shard run as a process of its own.

## The constraint that shaped the design: one Az context per process

Azure PowerShell keeps one current context for the whole process, shared by every runspace in it.
The billing phases (consumption, Marketplace, Foundry tokens and Foundry coverage) used to select each subscription with `Set-AzContext -Subscription $sub.id`, which moves that shared context.
A billing query that ran after another subscription had moved it would have returned that other subscription's data, with no error to flag it.
So each parallel stream had to be a separate `pwsh` process, launched with `Start-Job` and given its own copy of the context.
That in turn needed a single subscription to be inventoried by a standalone, independently launchable worker, which is what `ResourceInventory.ps1` invoked with `-RunAllSubs` is.

`Set-AzContext` had a second effect too.
With context autosave on, it saved the new subscription as the default the operator's next session started on.

## How subscriptions are selected now

The billing phases no longer call `Set-AzContext`.
Each phase copies the signed-in context with only the subscription swapped (`Get-RdaSubscriptionProfile`, in `Functions/Common.Functions.ps1`) and hands that copy to every Az call it makes, through a function-local `$PSDefaultParameterValues`:

```powershell
# once, at the top of the phase function: a copy that lives only as long as the function
$PSDefaultParameterValues = [System.Management.Automation.DefaultParameterDictionary]::new($PSDefaultParameterValues)
# per subscription, where Set-AzContext used to be
$PSDefaultParameterValues['*:DefaultProfile'] = Get-RdaSubscriptionProfile -SubscriptionId $sub.id
```

The wrapper's up-front consumption probe (`Test-ConsumptionAccess`) scopes its call the same way.
`Get-RdaSubscriptionProfile` reads the signed-in context with `-DefaultProfile $null`, so a pin left over from before a reconnect is never copied back.
It looks the subscription up in the signed-in tenant first and then without a tenant, so a subscription in another tenant that the identity can read gets a profile scoped to its own tenant.
The metrics batch provider check (`Initialize-RdaMetricsBatchPrereq` in `Extension/Metrics.ps1`) uses the same profile, once for each subscription it batches.
Neither the process context nor the saved default moves any more.
The existing check that the context matches the target subscription still runs, and a subscription it cannot confirm is still skipped rather than given another subscription's billing data.
The evidence is in [the one-process streams experiment](experiments/one-process-streams.md).

## Streams: separate processes by default, runspaces on request

By default each parallel stream is still a separate `pwsh` process (`Start-Job`) that imports a snapshot of the wrapper's context.
The worker each stream runs is `Run-AllSubscriptions.Stream.ps1`, which runs the inner `ResourceInventory.ps1` once for each subscription assigned to that stream.
That boundary isolates the streams: a crash or an out-of-memory error in one stream ends only that stream.
`-StreamIsolation Runspace` runs each stream as a thread job (`Start-ThreadJob`) in the wrapper's own process instead.
Those streams share the process's signed-in context, which no phase moves any more, and each keeps its own `$Global:` run state, because PowerShell globals belong to a runspace.
What each mode costs, and what a shared process gives up, is under [`-StreamIsolation`](variables/scaling-sharding-output.md#-streamisolation).

## Two scripts, two jobs (not a thin loop)

The wrapper is not a small `foreach` around the inner script. On its own it is
over four fifths of the inner script's size, and with the helper file it loads
it is the larger side:

| Script | Lines | Role |
|---|---|---|
| `Run-AllSubscriptions.ps1` | 3270 | Tenant-wide orchestrator |
| `ResourceInventory.ps1` | 3956 | Single-subscription worker |
| `Functions/RunAllSubscriptions.Functions.ps1` | 3113 | Helpers the wrapper loads |

(`wc -l`, current main.) The helper file, `Functions/RunAllSubscriptions.Functions.ps1`,
defines **83 functions** (`grep -c '^function '`) that exist only to orchestrate a
multi-subscription, multi-machine run — work the inner script never does. It
defines only 5 functions of its own by comparison. Representative orchestration
concerns and the functions that implement them:

- **Sharding across machines** - `Get-ShardKeyForSubscription` (line 1002),
  `Select-ShardSubscriptions` (line 1016), `Get-WeightedInventoryPlan` (line 1273).
- **Resume / failure state** - `Save-CompletedSubscriptionIds` (line 1660),
  `Get-FailedAttempts` (line 1636), `Merge-FailedAttempts` (line 1813).
- **Parallel-stream orchestration** - `Test-BackgroundJobSupport` (line 477),
  plus the `Start-Job` fan-out (`Run-AllSubscriptions.ps1` line 1769).
- **Preflight / tenant resolution** - `Resolve-TenantId` (line 1517),
  `Invoke-PreFlightChecks` (line 1380).

(All line numbers in `Functions/RunAllSubscriptions.Functions.ps1`, except the
`Start-Job` fan-out.)

The wrapper also **consolidates** every per-subscription ZIP into a single outer
bundle and builds an aggregate cross-subscription summary — neither of which a
per-subscription run produces:

```powershell
$OuterZipFile = Join-Path $InventoryRoot "AllSubscriptions_ResourcesReport_$Timestamp.zip"
```

That is `Run-AllSubscriptions.ps1` line 2431; the aggregate `MainSummary.html` is built
by `New-RdaAllSubHtmlSummary` at line 2481.

The inner script's job is the inverse: do **one** subscription completely —
discovery, metrics, consumption, obfuscation, and its own per-subscription ZIP.
It is a documented standalone entry point in its own right. The top-level README
shows calling it directly to scope a run to a single subscription or resource
group:

```powershell
./ResourceInventory.ps1 -ReportName "CompanyName" -SubscriptionID "12345678-1234-1234-1234-123456789012"
./ResourceInventory.ps1 -ReportName "CompanyName" -ResourceGroup "MyResourceGroup"
```

Those two switches are **inner-script only** — the wrapper's `param()` block does
not declare `-SubscriptionID`, `-ResourceGroup`, or `-ReportName`
(`Run-AllSubscriptions.ps1` lines 2–65); the wrapper always covers the whole
tenant and passes each subscription's id positionally as `$Sub.Id`. So the two
scripts are genuinely two different entry points with two different jobs, not one
job with a loop bolted on.

## `-RunAllSubs` is the role switch

`-RunAllSubs` is a private switch on the inner script (`ResourceInventory.ps1`
line 26). You never pass it yourself; the wrapper sets it on every child launch:

```powershell
& (Join-Path $PSScriptRoot "ResourceInventory.ps1") -TenantID $TenantID -SubscriptionID $Sub.Id @InventoryPassthrough -RunAllSubs
```

The call is at `Run-AllSubscriptions.ps1` line 1330 (sequential path) and line 1541 (the
single-subscription fallback of the parallel branch). Each parallel stream makes the
same call from `Run-AllSubscriptions.Stream.ps1` line 269.

Effectively, `-RunAllSubs` signals *"you are a per-subscription worker under the
orchestrator, not a standalone run."* It does two things: it **suppresses the
worker's own authentication** so the child reuses the parent/imported context
rather than tearing it down or logging in again (every relevant login/teardown is
guarded by `if (!$RunAllSubs.IsPresent)`, at `ResourceInventory.ps1` lines 308, 316,
366, 388), and it **forces non-interactive tenant selection** so a child never
blocks on a `Read-Host` prompt (`ResourceInventory.ps1` line 354). For the full
authentication detail, see the `RunAllSubs` section in
[variables/auth-and-execution.md](variables/auth-and-execution.md#runallsubs--the-anchor-example).

## Trade-offs

The split is not free, and the costs are real:

- **Parameter duplication.** Both scripts re-declare the passthrough parameters,
  and the wrapper forwards them via a splat hashtable, `@InventoryPassthrough`
  (built at `Run-AllSubscriptions.ps1` line 1275 and forwarded on the child launch
  lines above). Adding a new passthrough parameter therefore touches two files.
- **Two entry points is more to learn than one.** The top-level README spends
  real effort explaining when to use the wrapper versus calling the inner script
  directly.

The split still wins, on two grounds the single-process loop cannot match:

- **Capability.** Real parallelism (`-ParallelStreams`) and horizontal sharding
  across machines (`-ShardCount`/`-ShardIndex`) both depend on an independently
  launchable per-subscription worker.
- **Isolation.** A stream that runs as a process of its own fails alone: a crash
  or an out-of-memory error in one stream does not end the others.

Correctness used to be a third ground. While the billing phases moved the global
Az context, process-per-stream isolation was the only thing that prevented the
silent billing cross-contamination described above. They no longer move it,
which is what lets `-StreamIsolation Runspace` run the streams in one process.

And the clinching point: a merged single script that still wanted isolated
streams or shards would have to **re-launch itself as subprocesses** anyway - which
just reintroduces the same orchestrator/worker split, only hidden behind a mode
flag instead of expressed as two files. The current design makes that split
explicit.

## Inside one worker process: the metrics worker pool

By default the streams are separate processes; under `-StreamIsolation Runspace` they are runspaces of one process.
Inside each stream there is one place that runs runspaces of its own: the metrics phase in `Extension/Metrics.ps1`.
This section explains what that is, why it is safe, and how it keeps memory flat over a long run.

### The analogy: a workshop and its team

Think of the metrics phase as a workshop with a long list of small jobs.
Each job is one Azure Monitor query, that is, one `Get-AzMetric` call.
Before a worker can start, they need a heavy toolbox: the Az modules.
The building never throws a toolbox away, so every toolbox that is brought in stays until the process ends.

- **A new worker for every job (the old design).**
  1,000 jobs meant 1,000 toolboxes left in the building.
- **A small team per subscription (a pool).**
  The same few workers take one job after another, so a toolbox is bought once per worker, not once per job.
- **One team for the whole run (the current design under the wrappers).**
  The next subscription reuses the team the previous one used.
  The building holds one toolbox per worker in total, however many subscriptions the run processes.

Two rules keep this safe.
The foreman only sends the team home once everyone has put their tools down, so nobody is cut off in the middle of a job.
And every worker gets an access badge printed once at the front desk, instead of printing their own on a printer that sometimes jams.
Both rules are explained below.

### The same thing in PowerShell terms

A runspace is a separate PowerShell environment inside the same process, running on its own thread.
It has its own variables, functions and PowerShell-side module state, like an extra `pwsh` window without starting a new program.
The .NET libraries behind the Az modules are loaded only once per process, and every runspace shares them.
A runspace pool is a fixed set of runspaces that take work in turn.
Runspace pools are a standard PowerShell 7 feature on Windows, macOS and Linux.

The metrics phase uses one like this (simplified):

```powershell
# Create and open the pool once (or reuse the open one, see "Who owns the pool")
$MetricCallPool = [runspacefactory]::CreateRunspacePool([initialsessionstate]::CreateDefault2())
[void]$MetricCallPool.SetMaxRunspaces($ConcurrencyLimit * ($MetricMaxRetries + 1))
$MetricCallPool.Open()

# One metric call: hand it to a free worker and do not wait for it
$Call = [powershell]::Create()
$Call.RunspacePool = $MetricCallPool
[void]$Call.AddCommand('Get-AzMetric').AddParameters($MetricArgs)
$Handle = $Call.BeginInvoke()

# Collect the result (or the real Azure error), or abandon a call that is stuck
$Output = $Call.EndInvoke($Handle)
[void]$Call.BeginStop($null, $null)
```

The number of calls in flight is `-ConcurrencyLimit`.
A standalone run defaults to 6.
Under `Run-AllSubscriptions.ps1` each stream gets 2 per vCPU, between 6 and 16, cut back only when the streams together would pass 48 calls in flight, unless you pass `-ConcurrencyLimit`.
The pool may grow to 4 times that only while calls keep timing out, because a stopped call holds its worker until its network read returns.

### Why this does not break the process-global context rule

No phase moves the process's context: the billing phases scope each call to its subscription, as described above, and the metrics phase never calls `Set-AzContext`.
At the start of each subscription's metrics phase it reads the current context once with `Get-AzContext` and passes it to every call through `-DefaultProfile`.
So every call is told exactly which context to use, and nothing about the previous subscription's context is carried into the next one.
Within one stream, subscriptions run one after another; under `-StreamIsolation Runspace` the other streams in the process each run their own pool.

### How the design got here

| Version | Design | Memory effect |
|---|---|---|
| Before 28 Sept 2026 | `Start-ThreadJob` for every call attempt, so every attempt built a new runspace and loaded Az into it. | About 5.5 MB kept per call, never given back. |
| 28 Sept 2026 (`7b4226c`) | One pool per subscription. | About 0.6 MB per call, but the closed pool itself stayed in memory after each subscription. |
| `621232f` | The pool is released with `Dispose()` at the end of each subscription, behind the safety checks below. | The pool is freed, but each new pool still left about six type tables behind (next section). |
| Current | One pool for the whole wrapper run, held in `$Global:MetricCallPool`. | In 6 back-to-back runs in one process against the sandbox: 2.7 MB growth per run, against 9.4 MB on `621232f`. |

### Why one pool for the whole run, and not one per subscription

Every runspace that loads Az builds its own type table.
A type table is PowerShell's list of the extra properties and methods it adds to each object type, and with Az loaded it is about 0.8 MB.
PowerShell also keeps a process-wide cache of how it looked up members such as `$object.Count`, and each entry in that cache points at the type table of the runspace that made it.
So even after a pool is released, its type tables stay alive in that cache.

In the workshop picture, the building keeps a visitor book.
Every worker who ever came in signs it, and the book keeps their toolbox labels on file, even after the worker has gone home.

The cache holds at most about 128 entries per member name, so this growth stops at roughly 100 MB per process.
A 21-subscription stream with 6 workers per subscription reaches that ceiling, and a higher `-ConcurrencyLimit` reaches it sooner.
PowerShell has no supported way for a local runspace pool to share one type table, so the only clean fix is to stop creating new runspaces, which is what reusing the pool does.

### Who owns the pool

- **Standalone `ResourceInventory.ps1` run.**
  It builds its own pool and releases it at the end of the metrics phase, as before.
  `$Global:MetricCallPool` is not used.
- **Under `Run-AllSubscriptions.ps1`, one subscription after another.**
  `ResourceInventory.ps1` passes `-ReuseWorkerPool` to `Extension/Metrics.ps1`, and it does that only when it runs with `-RunAllSubs`.
  The first subscription creates the pool and stores it in `$Global:MetricCallPool`.
  Each later subscription reuses it, but only if it is still open; a pool in any other state is dropped and a new one is built.
  `Close-RdaMetricWorkerPool` in `Functions/Common.Functions.ps1` releases it once when the wrapper exits, called from `Exit-Wrapper` and just before the final `exit` of `Run-AllSubscriptions.ps1`.
  The two in-process runs of `ResourceInventory.ps1` (the sequential loop and the one-subscription fallback) also release it in a `finally`, so a Ctrl+C in an interactive session does not leave the pool open in that session.
- **Parallel streams.**
  Each stream has its own pool, because `$Global:MetricCallPool` belongs to the stream's runspace.
  A stream started with `Start-Job` (the default) is its own `pwsh` process, so its pool ends when the process ends.
  A stream started under `-StreamIsolation Runspace` is a thread job in the wrapper's process, so the thread job releases its pool with `Close-RdaMetricWorkerPool` when the stream ends; otherwise the pool would stay open in the wrapper's process until it exited.

### The safety checks: a worker goes home only when the job is finished

`Close()` and a `Dispose()` on its own both wait for any call that is still blocked in a network read.
That wait could hang the whole run, so the code never calls `Close()`.
At the end of each subscription's metrics phase it does this instead:

1. **Wait up to 10 seconds for every worker to be free.**
   It checks that the pool reports every runspace available (`GetAvailableRunspaces()` equals `GetMaxRunspaces()`) and that every call it stopped after a timeout has really ended.
   An idle pool passes at once; live runs waited 0-6 ms.
2. **Under the wrappers, keep a free pool for the next subscription.**
   If every worker is free and no stopped call is still running, the pool stays open in `$Global:MetricCallPool`.
3. **Otherwise, release it only with proof.**
   The pool is closed with `BeginClose()`, which does not wait.
   It is then released with `Dispose()` only if the pool was idle, no stopped call is still running, the close finished within the time left, and the pool reports `Closed`.
   Under the wrappers, a busy pool is first taken out of `$Global:MetricCallPool`, so a busy pool is never handed to the next subscription.
4. **If any check fails, leave it alone.**
   The pool is not released, and a WARNING goes to the debug log saying what was still busy.
   That pool stays in memory until the process ends, but nothing hangs and no call is cut off mid-job.

`Close-RdaMetricWorkerPool` at wrapper exit follows the same rule: it releases the pool only if no worker is busy, and it never waits for a busy worker.
A pool it leaves open is reported as a warning, because it then stays in the process until the process ends.
A pool in state `Broken` has no running call to protect, so it is disposed without a close.

### The context conversion: the "Cannot convert PSAzureContext" bug

**What went wrong.**
`Get-AzMetric` has a `-DefaultProfile` parameter that tells it which Azure sign-in and subscription to use.
That parameter expects an object of type `IAzureContextContainer`, but `Get-AzContext` returns a different type, `PSAzureContext`.
PowerShell bridges the gap automatically: when a command starts, it looks for a converter that turns one type into the other.
Az.Accounts provides that converter, and every runspace that loads Az.Accounts registers its own copy of it.
Before this fix, the main session passed the raw `PSAzureContext`, so every worker had to do that conversion at the start of every call.

PowerShell remembers how it converted a type for the whole process, not per runspace.
After a process has seen many Az runspaces, that remembered conversion sometimes stops working.
The call then fails before it reaches Azure, with `Cannot bind parameter 'DefaultProfile'. Cannot convert ... PSAzureContext ... to IAzureContextContainer`.
Retrying does not help, because the next attempt uses the same broken conversion, so the metric fails all four attempts.
This explanation fits every measurement below, but the exact cause inside PowerShell is not proven.

**In the workshop picture.**
Every worker has to show an access badge at the door before starting a job.
Before the fix, each worker printed their own badge at a shared printer that sometimes jams, and once it jams it stays jammed for a while.
Now the badge is printed once at the front desk, and every worker is handed a ready-made copy.

**Was the shared pool the cause?**
No.
In the first 6 live runs with the shared pool, 2 runs had one metric fail this way, and the 6 runs on `621232f` (a new pool per subscription) had none.
That was chance, not the pool.
A stress test with no network bound the context several hundred times per round on 6 workers, over 6 rounds per try, in both designs:

| Design | Rounds where nearly every call failed (279-296 failed calls in the round) |
|---|---|
| One shared pool, raw context | 6 of 18 rounds (every round of 1 try out of 3) |
| A new pool every round, raw context | 9 of 18 rounds (in each of the 3 tries) |
| One shared pool, context converted once | 0 of 24 rounds, and no failed calls at all |
| A new pool every round, context converted once | 0 of 24 rounds; 3 rounds had 1-2 failed calls |

So the bug was there before the shared pool, and converting the context once is what stops it.

**What the fix does.**
At the start of each subscription's metrics phase, `Extension/Metrics.ps1` reads the context with `Get-AzContext` and converts it once, in the main session:

```powershell
$ContextContainerType = 'Microsoft.Azure.Commands.Common.Authentication.Abstractions.Core.IAzureContextContainer' -as [type]
$MetricAzContext = [System.Management.Automation.LanguagePrimitives]::ConvertTo($MetricAzContext, $ContextContainerType)
```

The workers receive the converted object (an `AzureRmProfile`), which already has the type `-DefaultProfile` expects, so PowerShell has nothing to convert when each call starts.
It is still the same sign-in and the same subscription; only its wrapper type changes.
If the type cannot be found (for example in a future Az version) or the conversion fails, the phase keeps the raw context, which is the old behaviour, and writes a WARNING to the debug log.

**Result.**
In 6 back-to-back live runs with the fix there were 204 metric calls, 0 retries and 0 conversion failures.
The rare 1-2 failed calls in the last stress-test row only occurred when a process built a new pool after an earlier one, which under the wrappers now happens only after a busy pool is retired.
Such a call goes through the normal metric retry, and if it still fails it is recorded and reported like any other failed metric, never as a silent zero.

### Reading the memory figures

Each run records five memory readings per subscription (`start`, `discovery`, `collectors`, `released`, `end`), shown in the `Memory (MB, ...)` block of `RunSummary.log` and `Diagnostics_*.log`.

- **Heap** is the .NET memory that is still in use after a full garbage collection.
  This is the number that shows a leak: if the heap at `start` keeps climbing from one subscription to the next, something is being kept.
- **Working set** is all the RAM the process holds, including memory .NET has freed but not yet returned to the operating system.
  It jumps around with each phase, so do not read a leak from one working-set value.

Compare the `start` heap of each subscription: in a healthy run it levels off rather than rising by the same amount every time.

### What you see in the debug log

These lines appear in the local `DebugLog_*.log`, after the `[Metrics]` prefix:

| Line | Meaning |
|---|---|
| `Metric worker pool reused from the previous subscription in this process.` | Under the wrappers, this subscription used the existing pool. |
| `Metric worker pool kept open for the next subscription: every worker had finished (waited N ms).` | Under the wrappers, the pool was idle and stays open. |
| `Metric worker pool released: every worker had finished (waited N ms).` | The pool was released at the end of the phase, as in a standalone run. |
| `Metric worker pool was Broken: disposed without a close so it does not stay registered in the process.` | The pool had failed, so it was not asked to close; it is disposed, which is what removes its cleanup timer. |
| `WARNING: metric worker pool NOT released after Ns - idle=..., abandoned calls still running=..., pool state=...` | A worker was still busy, so the pool was left in memory rather than risk a hang. |
| `ERROR: Metrics: the metric worker pool could not be opened (...); N per-call metric definition(s) were not collected for this subscription.` | The pool could not start its runspaces, usually because the host is out of memory. The pool is disposed, the per-call metric collection of this subscription is skipped, and the subscription is listed as metrics-incomplete in the wrapper's summary. The same line is written to the run log at `Error` severity. |
| `WARNING: could not convert the Az context for the metric workers (...)` | The one-time conversion failed, so calls fall back to converting the raw context themselves. |

With `-Verbose`, the wrapper also prints `Metric worker pool at wrapper exit: ...` with the result of the final release.

The behaviour is guarded by `Tests/MemoryRelease.Tests.ps1` (pool reuse, release and the safety checks) and `Tests/MetricsThrottleRetryAfter.Tests.ps1` (the pool lifecycle and the context conversion).

## When to use which

- **Whole tenant** (the common case) → `Run-AllSubscriptions.ps1`. See the
  top-level [README](../README.md) and the copy-paste
  [variables/recipes.md](variables/recipes.md).
- **One subscription or one resource group** → call `ResourceInventory.ps1`
  directly with `-SubscriptionID` / `-ResourceGroup`, as shown above and in the
  [README](../README.md).
