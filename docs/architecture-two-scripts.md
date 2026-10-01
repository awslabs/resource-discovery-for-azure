# Why two scripts? (`ResourceInventory.ps1` + `Run-AllSubscriptions.ps1`)

A recurring question when reading the source: why is RDA split into an inner
per-subscription script (`ResourceInventory.ps1`) and a tenant-wide wrapper
(`Run-AllSubscriptions.ps1`), joined by a private `-RunAllSubs` switch, instead
of one script that loops over every subscription with all the logic inside?

The short answer is that a single-process loop **cannot safely collect billing
data for more than one subscription at a time**, because Azure's session context
is process-global. Everything else about the design follows from that one
constraint.

## The hard constraint: Az context is process-global

The consumption (billing) phase must point the Azure session at the subscription
it is about to query. It does this with `Set-AzContext`:

```powershell
$null = Set-AzContext -Subscription $sub.id -ErrorAction Stop
```

— `ResourceInventory.ps1` line 1227.

`Set-AzContext` does **not** set a local variable. It mutates the **process-global**
Azure PowerShell session state, so the *entire* `pwsh` process is now pointed at
`$sub.id`. Any billing query that runs after this — anywhere in the process — is
attributed to whatever subscription the context currently names.

The code immediately downstream is explicit that getting this wrong corrupts the
data rather than erroring. When the context switch cannot be confirmed, the phase
skips the subscription rather than query it under the wrong context:

```powershell
$SkipMessage = ("Consumption SKIPPED: could not switch the Azure context to this
subscription... Skipped to avoid attributing another subscription's billing data
to this one." ...)
```

— `ResourceInventory.ps1` line 1237 (paraphrased; the phrase *"attributing
another subscription's billing data to this one"* is verbatim).

That guard exists because the failure mode is **silent**: a billing query run
under the wrong context returns another subscription's data with no error. If two
subscriptions were processed concurrently in one process, they would race that
single global context — subscription A's billing query could execute while the
context still named subscription B — and cross-contaminate the consumption data
with nothing to flag it.

So the wrapper does **not** run streams as threads or runspaces inside one
process. Each parallel "stream" is a **separate `pwsh` process**, launched via
`Start-Job`:

```powershell
$Jobs += Start-Job -ScriptBlock {
    param($WorkerScript, $WorkerArgs)
    & $WorkerScript @WorkerArgs
} -ArgumentList @($WorkerScript, $WorkerArgs)
```

— `Run-AllSubscriptions.ps1` line 1618 (`$WorkerScript` is
`Run-AllSubscriptions.Stream.ps1`, which runs the inner `ResourceInventory.ps1` once
for each subscription assigned to that stream).

The comment that opens the parallel branch states the rationale directly:

> each "stream" is a separate `pwsh` background job (`Start-Job` runs the
> ScriptBlock in a fresh process). Process-level isolation is what makes this
> safe — the inner script's `Set-AzContext -Subscription` (consumption phase)
> mutates PROCESS-GLOBAL Az state, so two streams in one process would race
> contexts and silently cross-contaminate consumption data.

— `Run-AllSubscriptions.ps1` line 1402 (quoted).

**The consequence is the whole design.** Safe parallelism requires that a single
subscription can be inventoried by a standalone, independently-launchable worker
process. That standalone worker is exactly what `ResourceInventory.ps1` (invoked
with `-RunAllSubs`) is.

## Two scripts, two jobs (not a thin loop)

The wrapper is not a small `foreach` around the inner script. On its own it is
about three quarters of the inner script's size, and with the helper file it loads
it is the larger side:

| Script | Lines | Role |
|---|---|---|
| `Run-AllSubscriptions.ps1` | 2979 | Tenant-wide orchestrator |
| `ResourceInventory.ps1` | 3850 | Single-subscription worker |
| `Functions/RunAllSubscriptions.Functions.ps1` | 2432 | Helpers the wrapper loads |

(`wc -l`, current main.) The helper file, `Functions/RunAllSubscriptions.Functions.ps1`,
defines **72 functions** (`grep -c '^function '`) that exist only to orchestrate a
multi-subscription, multi-machine run — work the inner script never does. It
defines only 5 functions of its own by comparison. Representative orchestration
concerns and the functions that implement them:

- **Sharding across machines** — `Get-ShardKeyForSubscription` (line 491),
  `Select-ShardSubscriptions` (line 505), `Get-WeightedInventoryPlan` (line 762).
- **Resume / failure state** — `Save-CompletedSubscriptionIds` (line 1120),
  `Get-FailedAttempts` (line 1096), `Merge-FailedAttempts` (line 1257).
- **Parallel-stream orchestration** — `Test-BackgroundJobSupport` (line 300),
  plus the `Start-Job` fan-out (line 1618).
- **Preflight / tenant resolution** — `Resolve-TenantId` (line 977),
  `Invoke-PreFlightChecks` (line 869).

(All line numbers in `Functions/RunAllSubscriptions.Functions.ps1`.)

The wrapper also **consolidates** every per-subscription ZIP into a single outer
bundle and builds an aggregate cross-subscription summary — neither of which a
per-subscription run produces:

```powershell
$OuterZipFile = Join-Path $InventoryRoot "AllSubscriptions_ResourcesReport_$Timestamp.zip"
```

— `Run-AllSubscriptions.ps1` line 2209; the aggregate `MainSummary.html` is built
by `New-RdaAllSubHtmlSummary` at line 2244.

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
(`Run-AllSubscriptions.ps1` lines 2–53); the wrapper always covers the whole
tenant and passes each subscription's id positionally as `$Sub.Id`. So the two
scripts are genuinely two different entry points with two different jobs, not one
job with a loop bolted on.

## `-RunAllSubs` is the role switch

`-RunAllSubs` is a private switch on the inner script (`ResourceInventory.ps1`
line 23). You never pass it yourself; the wrapper sets it on every child launch:

```powershell
& (Join-Path $PSScriptRoot "ResourceInventory.ps1") -TenantID $TenantID -SubscriptionID $Sub.Id @InventoryPassthrough -RunAllSubs
```

— `Run-AllSubscriptions.ps1` line 1265 (sequential path) and line 1450 (the
single-subscription fallback of the parallel branch). Each parallel stream makes the
same call from `Run-AllSubscriptions.Stream.ps1` line 240.

Effectively, `-RunAllSubs` signals *"you are a per-subscription worker under the
orchestrator, not a standalone run."* It does two things: it **suppresses the
worker's own authentication** so the child reuses the parent/imported context
rather than tearing it down or logging in again (every relevant login/teardown is
guarded by `if (!$RunAllSubs.IsPresent)` — `ResourceInventory.ps1` lines 300, 308,
358, 380), and it **forces non-interactive tenant selection** so a child never
blocks on a `Read-Host` prompt (`ResourceInventory.ps1` line 346). For the full
authentication detail, see the `RunAllSubs` section in
[variables/auth-and-execution.md](variables/auth-and-execution.md#runallsubs--the-anchor-example).

## Trade-offs

The split is not free, and the costs are real:

- **Parameter duplication.** Both scripts re-declare the passthrough parameters,
  and the wrapper forwards them via a splat hashtable, `@InventoryPassthrough`
  (built at `Run-AllSubscriptions.ps1` line 1218 and forwarded on the child launch
  lines above). Adding a new passthrough parameter therefore touches two files.
- **Two entry points is more to learn than one.** The top-level README spends
  real effort explaining when to use the wrapper versus calling the inner script
  directly.

The split still wins, on two grounds the single-process loop cannot match:

- **Correctness.** Process-per-subscription isolation is the only thing that
  prevents the silent billing cross-contamination described above. A single
  process cannot run two subscriptions' consumption phases concurrently without
  racing the global Az context.
- **Capability.** Real parallelism (`-ParallelStreams`) and horizontal sharding
  across machines (`-ShardCount`/`-ShardIndex`) both depend on an independently
  launchable per-subscription worker.

And the clinching point: a merged single script that still wanted safe
parallelism would have to **re-launch itself as subprocesses** anyway — which
just reintroduces the same orchestrator/worker split, only hidden behind a mode
flag instead of expressed as two files. The current design makes that split
explicit.

## Inside one worker process: the metrics worker pool

The sections above say that streams are separate processes, never runspaces inside one process.
Inside each process there is one place that does use runspaces: the metrics phase in `Extension/Metrics.ps1`.
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
  The building holds about six toolboxes in total, however many subscriptions the run processes.

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

Normally 6 workers run at once (`-ConcurrencyLimit`).
The pool may grow to 6 x 4 = 24 only while calls keep timing out, because a stopped call holds its worker until its network read returns.

### Why this does not break the process-global context rule

The billing phase has to call `Set-AzContext`, which changes the whole process, so two subscriptions must never run in one process at the same time.
The metrics phase never calls `Set-AzContext`.
At the start of each subscription's metrics phase it reads the current context once with `Get-AzContext` and passes it to every call through `-DefaultProfile`.
So every call is told exactly which context to use, and nothing about the previous subscription's context is carried into the next one.
Subscriptions in one process still run one after another, never at the same time.

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
A 21-subscription stream with 6 workers per subscription reaches that ceiling.
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
- **Parallel streams.**
  Each stream is its own `pwsh` process started with `Start-Job`, so it has its own pool, and that pool ends when the process ends.

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
| `WARNING: metric worker pool NOT released after Ns - idle=..., abandoned calls still running=..., pool state=...` | A worker was still busy, so the pool was left in memory rather than risk a hang. |
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
