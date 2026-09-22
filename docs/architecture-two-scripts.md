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

— `ResourceInventory.ps1` line 1124.

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

— `ResourceInventory.ps1` line 1134 (paraphrased; the phrase *"attributing
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

— `Run-AllSubscriptions.ps1` line 1474 (`$WorkerScript` is the inner
`ResourceInventory.ps1`).

The comment that opens the parallel branch states the rationale directly:

> each "stream" is a separate `pwsh` background job (`Start-Job` runs the
> ScriptBlock in a fresh process). Process-level isolation is what makes this
> safe — the inner script's `Set-AzContext -Subscription` (consumption phase)
> mutates PROCESS-GLOBAL Az state, so two streams in one process would race
> contexts and silently cross-contaminate consumption data.

— `Run-AllSubscriptions.ps1` line 1307 (quoted).

**The consequence is the whole design.** Safe parallelism requires that a single
subscription can be inventoried by a standalone, independently-launchable worker
process. That standalone worker is exactly what `ResourceInventory.ps1` (invoked
with `-RunAllSubs`) is.

## Two scripts, two jobs (not a thin loop)

The wrapper is not a small `foreach` around the inner script. It is the **larger**
of the two:

| Script | Lines | Role |
|---|---|---|
| `Run-AllSubscriptions.ps1` | 2462 | Tenant-wide orchestrator |
| `ResourceInventory.ps1` | 1836 | Single-subscription worker |

(`wc -l`, current main.) On top of that, `Functions/RunAllSubscriptions.Functions.ps1`
defines **56 functions** (`grep -c '^function '`) that exist only to orchestrate a
multi-subscription, multi-machine run — work the inner script never does. It
defines only 4 functions of its own by comparison. Representative orchestration
concerns and the functions that implement them:

- **Sharding across machines** — `Get-ShardKeyForSubscription` (line 302),
  `Select-ShardSubscriptions` (line 316), `Get-WeightedInventoryPlan` (line 532).
- **Resume / failure state** — `Save-CompletedSubscriptionIds` (line 853),
  `Get-FailedAttempts` (line 829), `Merge-FailedAttempts` (line 932).
- **Parallel-stream orchestration** — `Test-BackgroundJobSupport` (line 134),
  plus the `Start-Job` fan-out (line 1474).
- **Preflight / tenant resolution** — `Resolve-TenantId` (line 720),
  `Invoke-PreFlightChecks` (line 639).

(All line numbers in `Functions/RunAllSubscriptions.Functions.ps1`.)

The wrapper also **consolidates** every per-subscription ZIP into a single outer
bundle and builds an aggregate cross-subscription summary — neither of which a
per-subscription run produces:

```powershell
$OuterZipFile = Join-Path $InventoryRoot "AllSubscriptions_ResourcesReport_$Timestamp.zip"
```

— `Run-AllSubscriptions.ps1` line 1851; the aggregate `MainSummary.html` is built
by `New-RdaAllSubHtmlSummary` at line 1885.

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
(`Run-AllSubscriptions.ps1` lines 2–48); the wrapper always covers the whole
tenant and passes each subscription's id positionally as `$Sub.Id`. So the two
scripts are genuinely two different entry points with two different jobs, not one
job with a loop bolted on.

## `-RunAllSubs` is the role switch

`-RunAllSubs` is a private switch on the inner script (`ResourceInventory.ps1`
line 20). You never pass it yourself; the wrapper sets it on every child launch:

```powershell
& (Join-Path $PSScriptRoot "ResourceInventory.ps1") -TenantID $TenantID -SubscriptionID $Sub.Id @InventoryPassthrough -RunAllSubs
```

— `Run-AllSubscriptions.ps1` line 1174 (sequential path) and line 1330 (parallel
per-stream path).

Effectively, `-RunAllSubs` signals *"you are a per-subscription worker under the
orchestrator, not a standalone run."* It does two things: it **suppresses the
worker's own authentication** so the child reuses the parent/imported context
rather than tearing it down or logging in again (every relevant login/teardown is
guarded by `if (!$RunAllSubs.IsPresent)` — `ResourceInventory.ps1` lines 295, 303,
353, 375), and it **forces non-interactive tenant selection** so a child never
blocks on a `Read-Host` prompt (`ResourceInventory.ps1` line 341). For the full
authentication detail, see the `RunAllSubs` section in
[variables/auth-and-execution.md](variables/auth-and-execution.md#runallsubs--the-anchor-example).

## Trade-offs

The split is not free, and the costs are real:

- **Parameter duplication.** Both scripts re-declare the passthrough parameters,
  and the wrapper forwards them via a splat hashtable, `@InventoryPassthrough`
  (built at `Run-AllSubscriptions.ps1` line 1130 and forwarded on the child launch
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

## When to use which

- **Whole tenant** (the common case) → `Run-AllSubscriptions.ps1`. See the
  top-level [README](../README.md) and the copy-paste
  [variables/recipes.md](variables/recipes.md).
- **One subscription or one resource group** → call `ResourceInventory.ps1`
  directly with `-SubscriptionID` / `-ResourceGroup`, as shown above and in the
  [README](../README.md).
