# Parameters: scaling, sharding, resume, planning, obfuscation, output & service filter

This document explains the parameters that control **how much work runs at
once**, **how a run is split across machines**, **how an interrupted run is
resumed**, **how a run is sized/checked before it starts**, **how output is
masked and named**, and **which collectors run**. For each parameter it gives
the type, which script declares it, the default/validation, what it does, and —
the part a `param()` block never tells you — *why* it exists and when to reach
for it.

The two entry-point scripts are:

- **`ResourceInventory.ps1`** — the inner script. Inventories **one** scope (a
  tenant, a single subscription, or a single resource group) and writes one
  report.
- **`Run-AllSubscriptions.ps1`** — the wrapper. Enumerates a tenant and invokes
  the inner script once per subscription, adding the tenant-wide concerns:
  parallel streams, sharding, resume/coverage, planning/preflight, and the
  consolidated bundle.

Where a parameter exists on both, the wrapper forwards it to the inner script
unchanged. Where it exists on only one, that is called out.

Sibling docs own the parameters this file does **not** cover: authentication and
execution parameters (`-TenantID`, `-Appid`, `-Secret`, `-DeviceLogin`,
`-SubscriptionID`, `-ResourceGroup`, `-RunAllSubs`) and metrics/consumption
parameters (`-SkipMetrics`, `-SkipConsumption`, `-UseMetricsBatch`,
`-MetricsIntervalMinutes`, `-MetricsLookbackDays`, `-IncludeStorageMetrics`,
`-SkipDiskMetrics`, `-MetricsDetailed`) are documented elsewhere under
`docs/variables/`.

Deeper background lives in two existing docs, which this file links to rather
than duplicating:

- [`docs/horizontal-sharding.md`](../horizontal-sharding.md) — the sharding
  model, the rate-limit reasoning, and the multi-machine campaign workflow.
- [`docs/obfuscation-and-unmask.md`](../obfuscation-and-unmask.md) — exactly
  what obfuscation masks, the dictionary format, and `Reveal.ps1`.
- [`docs/Plan.md`](../Plan.md) — the empirical sizing model behind `-Plan`.

> Line citations below point at current `main`. They are approximate and drift
> as the code changes; treat them as "look here," not as exact addresses.

---

## Scaling & throughput

These three control how many Azure API calls are in flight at once — the
knobs that trade wall-clock time against the shared Azure throttle budget.

### `-ConcurrencyLimit`

| | |
|---|---|
| **Type** | `int` |
| **Declared on** | `ResourceInventory.ps1` (line ~23), `Run-AllSubscriptions.ps1` (line ~33) |
| **Default** | `6` |

**What it does.** Caps how many metric queries run in parallel **within a single
subscription**. The inner script passes it straight into the metrics collector
(`ResourceInventory.ps1` line ~827 calls `Extension/Metrics.ps1` with
`-ConcurrencyLimit`), where it becomes the `-ThrottleLimit` of the parallel
`ForEach-Object -Parallel` metric loop (`Extension/Metrics.ps1` line ~1092). It
governs the metrics phase only; inventory discovery (Resource Graph) and the
consumption phase do not fan out on it.

**Why it exists.** Collecting Azure Monitor metrics is the slowest part of a
run: each `Get-AzMetric` call is a 200–500 ms network round-trip, and a
subscription with VMs, disks, SQL and storage produces thousands of them. Doing
them one at a time is needlessly slow; doing all of them at once trips Azure
Resource Manager's per-subscription read throttle (HTTP 429). `6` is a
deliberate middle ground that keeps a single subscription well under the ceiling.

**When to change it.** Raise it (8–12) on a large, metric-heavy subscription when
you are watching the per-run logs and not seeing 429s. Lower it if you *are*
seeing 429s or timeouts. On the wrapper it composes with `-ParallelStreams`:
concurrent ARM calls across the whole tenant is roughly
`ConcurrencyLimit × ParallelStreams`, so keep that product under ~50 per tenant.

**Auto-tuning caveat (wrapper only).** On `Run-AllSubscriptions.ps1`, if you do
**not** pass `-ConcurrencyLimit` explicitly, the wrapper overrides the `6`
default with a host-sized value (`VCpu × 2`, clamped to 6–16) from
`Get-RecommendedParallelism` (`Run-AllSubscriptions.ps1` line ~1063–1067;
`Functions/RunAllSubscriptions.Functions.ps1` line ~106–109). Passing the flag —
even `-ConcurrencyLimit 6` — pins it and disables the auto-override. The run
prints which source won (`auto` vs `explicit`) at startup (line ~1081).

### `-ParallelStreams`

| | |
|---|---|
| **Type** | `int` |
| **Declared on** | `Run-AllSubscriptions.ps1` (line ~35) — **wrapper only** |
| **Default** | `1` (but auto-tuned when not passed — see below) |

**What it does.** The number of subscriptions processed **concurrently on one
machine**. Each stream is a separate `pwsh` background job (`Start-Job`) running
`Run-AllSubscriptions.Stream.ps1`. The wrapper splits the in-scope subscriptions
across the streams **round-robin** — subscription *i* goes to stream
`i % StreamCount` (`Run-AllSubscriptions.ps1` line ~1413–1419) — so heavy and
light subscriptions are interleaved rather than clumped.

**Why it exists.** `-ConcurrencyLimit` parallelises *within* one subscription;
`-ParallelStreams` parallelises *across* subscriptions. On a tenant with many
subscriptions the wall-clock win comes from running several subscriptions at
once. Separate processes are used **on purpose**: the inner script's consumption
phase calls `Set-AzContext -Subscription`, which mutates process-global Az state,
so two subscriptions in one process would race contexts and cross-contaminate
billing data. Process isolation makes concurrency safe (see the comment at
`Run-AllSubscriptions.ps1` line ~1307).

**When to change it.** Raise it on a machine with spare cores and RAM (budget
~1 core and ~500–700 MB per stream); the README's sizing table recommends `2`
for Cloud Shell, up to `6` on a 16 GB/8-core box. Leave it at the auto value
otherwise.

**Auto-tuning + fallback caveats.** Like `-ConcurrencyLimit`, if you do not pass
`-ParallelStreams`, the `1` default is overridden by the host-sized recommendation
(`floor(VCpu / 2)`, capped at 6, further capped by RAM as `floor((RamGB-2)/1.5)`;
`Functions/RunAllSubscriptions.Functions.ps1` line ~95–104, applied at
`Run-AllSubscriptions.ps1` line ~1066). Separately, if the host blocks
`Start-Job` (WDAC/AppLocker language-mode policy), the wrapper falls back to the
sequential path and forces `ParallelStreams = 1` with a warning
(line ~1083–1096) — the report content is identical, only slower.

### `-HeadRoom`

| | |
|---|---|
| **Type** | `int`, `[ValidateRange(0, 90)]` |
| **Declared on** | `Run-AllSubscriptions.ps1` (line ~37–38) — **wrapper only** |
| **Default** | `0` (no reduction) |

**What it does.** Reduces the effective `-ConcurrencyLimit` by the given
percentage so the run deliberately leaves API budget unused. The reduction is
`floor(Concurrency × (100 − HeadRoom) / 100)`, clamped to at least 1
(`Get-HeadroomAdjustedConcurrency`,
`Functions/RunAllSubscriptions.Functions.ps1` line ~118–131). It is applied
**after** auto-tuning and **before** the per-subscription passthrough is built
(`Run-AllSubscriptions.ps1` line ~1069–1073), so both the sequential and the
parallel-stream paths inherit the reduced value.

**Why it exists.** RDA runs read-only, but it still competes for the tenant's
shared Azure Resource Manager throttle budget. On a tenant carrying live
production workloads, running RDA at full concurrency can crowd out those
workloads' own API calls. `-HeadRoom 20` tells RDA to use ~80% of the concurrency
it would otherwise use, leaving ~20% in reserve for everything else — trading a
slower inventory for lower blast radius on production.

**Behavioural notes.** `0` is a true no-op (unit-tested). Out-of-range values are
clamped inside the helper (negatives → 0, above 90 → 90) even though the param
validation already bounds the CLI surface to 0–90; the container entrypoint
(`deploy/entrypoint.ps1`) relies on that clamp when reading `HEAD_ROOM` from the
environment. `-HeadRoom` is not forwarded as a flag; it *mutates*
`-ConcurrencyLimit` before forwarding, which is why the run's diagnostics label
the concurrency source as e.g. `auto, -HeadRoom 20` (line ~1079).

---

## Sharding

Sharding splits one tenant across **independent machines**. See
[`docs/horizontal-sharding.md`](../horizontal-sharding.md) for the full model and
campaign workflow; the two parameters below are the surface.

### `-ShardCount`

| | |
|---|---|
| **Type** | `int` |
| **Declared on** | `Run-AllSubscriptions.ps1` (line ~41) — **wrapper only** |
| **Default** | `1` (no sharding) |

### `-ShardIndex`

| | |
|---|---|
| **Type** | `int` |
| **Declared on** | `Run-AllSubscriptions.ps1` (line ~40) — **wrapper only** |
| **Default** | `0` |

**What they do together.** You split the tenant into `ShardCount` disjoint slices
and run the **same command** on each machine with a distinct `ShardIndex` from
`0` to `ShardCount − 1`. Each machine enumerates the whole tenant, then keeps
only the subscriptions whose shard key equals its `ShardIndex`. The key is a
stable partition of the subscription id: the first four bytes of its SHA-256
hash, taken modulo `ShardCount` (`Get-ShardKeyForSubscription` and
`Select-ShardSubscriptions`, `Functions/RunAllSubscriptions.Functions.ps1`
line ~302–325). The filter is applied at `Run-AllSubscriptions.ps1` line ~729–740;
a shard with no subscriptions assigned exits cleanly with nothing to do.

**Validation.** `ShardCount` must be ≥ 1 and `ShardIndex` must be in
`[0, ShardCount − 1]`, or the wrapper errors out before doing any work
(`Run-AllSubscriptions.ps1` line ~303–312).

**Why they exist.** `-ParallelStreams` scales across the cores of *one* machine,
and is capped at ~6 useful streams by the tenant-wide Resource Graph rate limit.
For very large tenants (thousands of subscriptions) one machine is the wall.
Sharding scales *across machines*: because the partition is a deterministic hash
of the subscription id with no coordination between machines, the shards are
provably **disjoint and complete** — every subscription lands in exactly one
shard, and a subscription added, removed, or invisible on one machine only
affects its own shard. (SHA-256 is used rather than a cheaper hash specifically
so the distribution is even and stable; see the doc's "Why SHA-256" section.)

**When to use.** Only for tenants too large for a single machine to finish within
your window. `-Plan` (below) recommends a shard count. Sharding is orthogonal to
`-ParallelStreams`: each shard still uses parallel streams across its own cores.

**Caveats.** Run **one shard per machine**, each with its own output directory —
two shards sharing a machine and output directory with `-ParallelStreams > 1`
collide on the per-stream working files. Each shard writes its own
shard-namespaced resume-state file (see `-Resume`). It only balances by *count*,
not by *size*, so a shard that happens to draw several heavy subscriptions runs
longer; `-Plan` accounts for this by simulating the real hash partition.

---

## Resume & coverage

These control which subscriptions a run actually processes when re-run, and
whether it insists on seeing the whole tenant.

### `-Resume`

| | |
|---|---|
| **Type** | `switch` |
| **Declared on** | `Run-AllSubscriptions.ps1` (line ~21) — **wrapper only** |
| **Default** | off |

**What it does.** Skips subscriptions already completed in a prior run of the
same tenant/shard. After each subscription's per-subscription ZIP is written, its
id is recorded in a resume-state JSON file
(`InventoryReports/.resume-state-<TenantID>.json`, or
`.resume-state-<TenantID>-shard-<i>of<n>.json` when sharding —
`Run-AllSubscriptions.ps1` line ~339–343). `-Resume` reads that file, reports how
many will be skipped (line ~836–848), and processes the rest. Without `-Resume`
the file is left untouched and every subscription is processed; the wrapper still
notes the file exists so you know the option is available (line ~850–855). When
resuming a previously *parallel* run, it also folds in any stranded per-stream
state files so the skip set is complete (line ~767–796).

**Why it exists.** On large tenants a run can be cut short by an
environment-level limit — most commonly a Cloud Shell session that ends at a
Conditional Access maximum-session-lifetime. Re-running from scratch would redo
hours of finished work. `-Resume` makes the run idempotent at subscription
granularity: only the subscription that was mid-flight when the session died is
redone from the start.

### `-ResumeFailedOnly`

| | |
|---|---|
| **Type** | `switch` |
| **Declared on** | `Run-AllSubscriptions.ps1` (line ~22) — **wrapper only** |
| **Default** | off |

**What it does.** Retries **only** the subscriptions recorded as *failed* in the
resume state, skipping both the already-completed and the never-attempted ones.
It reads the `FailedAttempts` list and filters the in-scope set down to just
those ids (`Run-AllSubscriptions.ps1` line ~817–843). If the failed list is
empty, it exits cleanly saying there is nothing to retry.

**Why it exists — and how it differs from `-Resume`.** `-Resume` continues an
*interrupted* run: it processes everything not yet completed (failed **and**
never-attempted). `-ResumeFailedOnly` is for a run that *finished* but left a
handful of failures — e.g. transient throttling on a few subscriptions. Rather
than walking the whole tenant again, it re-runs just the failures. Use `-Resume`
to finish an interrupted campaign; use `-ResumeFailedOnly` to mop up a completed
one.

### `-IncludeDisabled`

| | |
|---|---|
| **Type** | `switch` |
| **Declared on** | `Run-AllSubscriptions.ps1` (line ~23) — **wrapper only** |
| **Default** | off |

**What it does.** By default the wrapper inventories only subscriptions whose
`State` is `Enabled`, filtering everything else out and printing a per-state
breakdown of what it excluded (`Run-AllSubscriptions.ps1` line ~480–496).
`-IncludeDisabled` turns that filter off and processes every subscription
`Get-AzSubscription` returned, whatever its state.

**Why it exists.** Subscriptions in a non-`Enabled` state (`Disabled`, `Warned`,
`PastDue`, `Deleted`) return little or no data from Resource Graph and most ARM
data-plane calls, so inventorying them produces near-empty reports while still
costing wall-clock time. Excluding them by default keeps a run focused on the
subscriptions that carry data. The flag exists for the rarer case where you
genuinely need a disabled subscription in the report — e.g. an audit that must
show it was seen and was empty.

### `-AllowPartialAccess`

| | |
|---|---|
| **Type** | `switch` |
| **Declared on** | `Run-AllSubscriptions.ps1` (line ~25) — **wrapper only** |
| **Default** | off (hard-stop) |

**What it does.** Changes two up-front gates from *hard-stop* to
*skip-and-continue*:

1. **Coverage gate.** The wrapper reads the true subscription set under the
   tenant-root management group and compares it to what the identity can
   enumerate. If some are missing (or the management group cannot be read at
   all), by default it **stops before any work** (`Run-AllSubscriptions.ps1`
   line ~845–889). With `-AllowPartialAccess` it warns and proceeds with the
   visible subscriptions.
2. **Access gate.** It probes each in-scope subscription for readability. If any
   is unreadable, by default it stops (line ~890–927). With
   `-AllowPartialAccess` it skips the unreadable ones and continues with the
   rest.

**Why it exists.** Azure Resource Graph returns **zero rows rather than an
authorization error** for a subscription the identity has no role on. Without a
gate, a missing Reader assignment is invisible until the finished report turns
out to be silently missing subscriptions. The default hard-stop makes a
verifiably-complete run the norm and forces the operator to fix the missing role.
`-AllowPartialAccess` is the conscious downgrade for the legitimate case where
you *intend* to cover only a subset of the tenant and know the rest is
unreachable. It is the deliberate opposite of "complete by default." (The
required scope for a complete run — Reader at the tenant-root management group —
is described in the README's Prerequisites.)

---

## Planning & preflight

These check or size a run *without* producing a full inventory (or, for
`-CapacityPlan`, add a capacity-planning output to a normal run).

### `-Preflight`

| | |
|---|---|
| **Type** | `switch` |
| **Declared on** | `Run-AllSubscriptions.ps1` (line ~27) — **wrapper only** |
| **Default** | off |

**What it does.** Runs the normal sign-in, tenant-resolution, coverage and Reader
checks, then probes **every** in-scope subscription for the two data-phase
permissions — Cost Management (consumption) and Monitoring (metrics) — prints a
per-subscription permission matrix, and exits without collecting anything
(`Run-AllSubscriptions.ps1` line ~930–991). Each cell is `Ok` (verified),
`Denied` (RBAC denial — makes preflight exit 1), `Unavailable` (probe could not
run — token/transient), `NoResource` (nothing metric-eligible to probe), or
`Skipped` (the matching `-Skip*` switch was passed). The Az context is restored
afterward.

**Why it exists.** The Reader access gate proves only *read* access. The two data
phases each need an additional role, and without them a run otherwise discovers
the gap partway through — sometimes hours in. `-Preflight` surfaces every missing
data-phase role up front, per subscription, with the exact role to grant, so the
operator fixes RBAC once rather than in a slow trial-and-error loop. If coverage
can't be verified, preflight reports that but still probes what it can see,
rather than stopping at the coverage gate.

### `-Plan`

| | |
|---|---|
| **Type** | `switch` |
| **Declared on** | `Run-AllSubscriptions.ps1` (line ~47) — **wrapper only** |
| **Default** | off |

**What it does.** Assess-only sizing. It authenticates, enumerates and filters
the tenant, then sizes the workload from **live metric-query volume** (counting
each subscription's metric-eligible resources via Resource Graph), and prints
either a single-machine recommendation or a shard-count recommendation with
ready-to-paste commands — then exits without inventorying anything
(`Run-AllSubscriptions.ps1` line ~498 onward; model in
`Get-InventoryPlan`/`Get-PlanShardDirective`,
`Functions/RunAllSubscriptions.Functions.ps1` line ~327–397). Crucially it
simulates the **real hash partition** used by sharding, so the recommendation
accounts for the count-not-size imbalance rather than assuming perfectly even
shards.

**Why it exists.** Choosing a shard count by guesswork either wastes machines or
leaves the busiest shard over your time ceiling. `-Plan` grounds the decision in
the tenant's actual metric-eligible resource counts. See
[`docs/Plan.md`](../Plan.md) for the empirical model and
[`docs/horizontal-sharding.md`](../horizontal-sharding.md#choosing-the-shard-count--plan)
for how it feeds the campaign.

### `-PlanPerQuerySeconds`

| | |
|---|---|
| **Type** | `double` |
| **Declared on** | `Run-AllSubscriptions.ps1` (line ~49) — **wrapper only** |
| **Default** | `0` (auto) |

**What it does.** `-Plan` only. Overrides the estimated per-metric-query
wall-time (in seconds) that the sizing model multiplies by the projected query
count. `0` uses the built-in auto estimate; a positive value substitutes a figure
you measured from a prior run's Diagnostics timings, giving a tenant-accurate
estimate.

**Why it exists.** The default per-query time is a representative constant. A
tenant on a slow link, or one whose resources are unusually metric-heavy, will
diverge from it. Feeding back a measured number makes the next `-Plan` estimate
match that specific tenant instead of the generic baseline.

### `-CapacityPlan`

| | |
|---|---|
| **Type** | `switch` |
| **Declared on** | `ResourceInventory.ps1` (line ~20), `Run-AllSubscriptions.ps1` (line ~15) |
| **Default** | off (opt-in) |

**What it does.** Opts into a tenant-wide capacity-planning CSV
(`VMPlacement.csv`) describing the availability-zone, SKU, vCPU/RAM and disk
profile of every VM and scale set. When set, the inner script runs
`Extension/VMPlacement.ps1` after inventory (`ResourceInventory.ps1`
line ~1385–1404); under the wrapper it writes a per-subscription
`VMPlacementPart_*.csv`, and the wrapper concatenates the parts into one
tenant-wide `VMPlacement.csv` folded into the bundle root. Without the switch, no
`VMPlacement*.csv` is produced, aggregated, or bundled.

**Why it exists — and why it is opt-in.** It is for sizing target infrastructure
per availability zone during a migration. It makes **no extra Azure calls** — it
joins data already collected — but it is a **separate** output with its own
schema, so it is off by default to keep the standard report shape stable for
consumers that do not need it. Turn it on only when AZ-level VM capacity is
actually wanted. (Note for sharded runs: because every shard's bundle carries
`VMPlacement.csv` at the same fixed root name, merging shards requires per-shard
extraction to avoid overwriting — see
[`docs/horizontal-sharding.md`](../horizontal-sharding.md).)

### `-MainSummary`

| | |
|---|---|
| **Type** | `switch` |
| **Declared on** | `Run-AllSubscriptions.ps1` (line ~29) — **wrapper only** |
| **Default** | off |

**What it does.** **Nothing — it is a retained no-op.** The wrapper explicitly
prints a note to that effect when the flag is passed
(`Run-AllSubscriptions.ps1` line ~252–255). The aggregate `MainSummary.html` is
built on **every** run and folded into the consolidated bundle regardless
(line ~1866–1891, staged into the bundle at line ~2253–2257), so the flag adds
nothing.

**Why it exists.** It is kept only for backward compatibility, so an existing
script or runbook that still passes `-MainSummary` does not fail parameter
binding. New invocations should omit it.

### `-Detailed`

| | |
|---|---|
| **Type** | `switch` |
| **Declared on** | `Run-AllSubscriptions.ps1` (line ~31) — **wrapper only** |
| **Default** | off |

**What it does.** Forwarded into the aggregate summary builder as
`-Detailed:$Detailed` (`Run-AllSubscriptions.ps1` line ~1885–1891), which selects
a more detailed rendering of the tenant-wide `MainSummary.html`. It affects only
that HTML summary's verbosity; it does not change what is collected or the
per-subscription reports.

**Why it exists.** The default `MainSummary.html` is a concise overview. `-Detailed`
is for when you want the fuller breakdown in the aggregate view without opening
each per-subscription report.

---

## Obfuscation

See [`docs/obfuscation-and-unmask.md`](../obfuscation-and-unmask.md) for the full
list of what is masked, the dictionary format, and `Reveal.ps1`.

### `-Obfuscate`

| | |
|---|---|
| **Type** | `switch` |
| **Declared on** | `ResourceInventory.ps1` (line ~15), `Run-AllSubscriptions.ps1` (line ~6) |
| **Default** | off (opt-in) |

**What it does.** Masks identifying details across all output files — resource
ids and names, subscription and resource-group names, tag values, and free-text
identity fields — replacing them with deterministic `prod_<guid>` / `nonprod_<guid>`
tokens, and writes a **local** reverse-lookup dictionary
(`ObfuscationDictionary_*.json`) that is never included in the shared ZIP. When
set, the inner script allocates the per-dimension lookup dictionaries at startup
(`ResourceInventory.ps1` line ~70–78) and applies them during report generation;
the `prod_`/`nonprod_` prefix is chosen by matching the resource name against
dev/test patterns (line ~626 onward).

**Why it exists.** The full-fidelity report contains real Azure names and ids.
Obfuscation lets the report be shared externally (e.g. with an analysis team)
without exposing the customer's environment. The mapping is **deterministic**
within a run — the same real value always maps to the same token — so grouping,
pivoting and cross-referencing still work on the masked output. It is off by
default because a local run for the operator's own eyes does not need masking,
and masking is irreversible without the dictionary.

### `-ObfuscationDictionary`

| | |
|---|---|
| **Type** | `string` (path to a JSON dictionary) |
| **Declared on** | `ResourceInventory.ps1` (line ~11) — **inner script only** |
| **Default** | none |

**What it does.** Seeds obfuscation with an **existing** dictionary from a prior
run so tokens stay stable across runs. The inner script loads the file and
pre-populates every per-dimension map (resource id, name, subscription, resource
group, tag, free-text) with its real→token entries before collecting, then logs
how many mappings were preloaded (`ResourceInventory.ps1` line ~584–620). Any real
value already in the seed reuses its previous token; new values get fresh ones.

**Why it exists.** Without a seed, each obfuscated run mints fresh random tokens,
so the same subscription would be `prod_A` in one run and `prod_B` in the next —
making it impossible to correlate two masked reports over time. Passing the prior
run's dictionary makes the token assignment stable across runs, so a
month-over-month comparison of masked reports lines up. Use it whenever you need
consecutive obfuscated reports to be comparable. It pairs with `-Obfuscate` (it
seeds the maps that `-Obfuscate` fills).

---

## Output & state

Where the report is written, how it is named, and where node output/state is
mirrored for multi-machine or ephemeral runs.

### `-ReportName`

| | |
|---|---|
| **Type** | `string` |
| **Declared on** | `ResourceInventory.ps1` (line ~25) — **inner script only** |
| **Default** | `'ResourcesReport'` |

**What it does.** The company/customer name woven into every output file name
(`Inventory_<ReportName>_<timestamp>.json`, `ResourcesReport_<timestamp>.html`,
etc.). It is captured into `$Global:ReportName` at startup
(`ResourceInventory.ps1` line ~60) and used throughout report generation and by
the `VMPlacement` file naming shown above.

**Why it exists.** A single consolidated inner-script run produces files a human
later has to identify and hand off; naming them after the customer makes the
deliverable self-describing. The wrapper does not expose `-ReportName` — it
generates per-subscription names itself — which is why this is inner-script only.
`-ReportName` is **required** for a direct `ResourceInventory.ps1` run.

### `-OutputDirectory`

| | |
|---|---|
| **Type** | `string` (full path) |
| **Declared on** | `ResourceInventory.ps1` (line ~26) — **inner script only** |
| **Default** | `~/InventoryReports` (or `C:\InventoryReports` on Windows) |

**What it does.** The directory reports are written to. It must be a **full**
path: the inner script resolves it and errors out if it cannot
(`ResourceInventory.ps1` line ~232–245). When unset, output goes to the default
`InventoryReports` location under the inventory root.

**Why it exists.** The default keeps output in a predictable place, but on a
machine where you want reports on a specific volume (a large data disk, a mounted
share) you need to redirect them. The full-path requirement avoids ambiguity
about where a relative path would resolve — an inventory run may `cd` internally,
so a relative output path would be fragile. The wrapper manages the output root
itself, so this is inner-script only.

### `-UploadToBlobContainerUri`

| | |
|---|---|
| **Type** | `string` (blob container URL) |
| **Declared on** | `Run-AllSubscriptions.ps1` (line ~43) — **wrapper only** |
| **Default** | none (output stays node-local) |

**What it does.** Uploads each node's finalized report ZIP to a shared Azure blob
container, passwordless, via the run's own identity. The wrapper validates the
URI up front — it must be `https`, the host must contain `.blob.`, and there must
be a container path — and requires the `Az.Storage` module, erroring out early if
either check fails (`Run-AllSubscriptions.ps1` line ~314–338). Omit it to keep
output on the node.

**Why it exists.** In a multi-machine / AKS campaign, each node produces its own
bundle but there is no shared filesystem to collect them from. Uploading each
node's ZIP to a common blob container is how the shards' output is gathered
centrally. Each node writes to local disk first and uploads at the end
(local-first is faster than streaming to blob throughout the run). It requires the
identity to hold `Storage Blob Data Contributor` on the container.

### `-StateBlobContainerUri`

| | |
|---|---|
| **Type** | `string` (blob container URL) |
| **Declared on** | `Run-AllSubscriptions.ps1` (line ~45) — **wrapper only** |
| **Default** | none (state stays local) |

**What it does.** Mirrors the resume/state file to a blob container (validated the
same way as `-UploadToBlobContainerUri`; `Run-AllSubscriptions.ps1`
line ~348–373) so resume state survives loss of the node's local disk. The blob
state name is shard- and stream-namespaced so parallel streams and shards do not
collide (`Get-StateBlobName`, referenced at line ~751). Omit it to keep state
local-only.

**Why it exists.** On ephemeral compute — an AKS pod that can be rescheduled to a
new node mid-run — the local resume-state file disappears with the old node, so
`-Resume` on the rescheduled pod would redo finished work. Mirroring state to
blob lets a rescheduled pod read back what it had already completed and continue.
It is the resume-safety counterpart of `-UploadToBlobContainerUri` for
container-based runs.

---

## Service filter

### `-Service`

| | |
|---|---|
| **Type** | `string[]` |
| **Declared on** | `ResourceInventory.ps1` (line ~10), `Run-AllSubscriptions.ps1` (line ~19) |
| **Default** | none (all collectors run) |

**What it does.** Scopes the **inventory** phase to only the named service
collectors — the base names of the `Services/*.ps1` scripts, e.g.
`VirtualMachines`, `Streamanalytics`. The wrapper first normalises the input
(accepting either a comma-separated token or a PowerShell array, trimming and
de-duplicating — `Expand-ServiceFilter`,
`Functions/RunAllSubscriptions.Functions.ps1` line ~1060–1070), then validates
every name against the actual `Services` tree and **fails fast** with the valid
list if any is unknown (`Run-AllSubscriptions.ps1` line ~1101–1112). The inner
script applies the filter by keeping only the matching collector modules
(`ResourceInventory.ps1` line ~865–878).

**Why it exists.** A migration that only cares about certain workloads (say, VMs
and stream analytics) does not need every collector to run. Restricting to the
relevant collectors makes the inventory phase faster and the report smaller.

**Important scope caveat.** `-Service` scopes the **inventory phase only**. The
metrics and consumption phases still run for the **whole** subscription unless you
also pass `-SkipMetrics` / `-SkipConsumption` — both scripts warn about this and
suggest the switches (`ResourceInventory.ps1` line ~880 onward;
`Run-AllSubscriptions.ps1` line ~1113 onward). For a genuinely inventory-only run,
combine `-Service` with the two skip switches. (Re-collecting a single service is
also the input to a later `Merge-RecoveryData`, which the warning notes.)
