# Variable / parameter reference

This section documents the parameters exposed by the two entry-point scripts —
`ResourceInventory.ps1` (the inner, single-report script) and
`Run-AllSubscriptions.ps1` (the tenant-wide wrapper) — and, more importantly,
**why** each parameter exists and why the surrounding code behaves the way it
does.

The [top-level README](../../README.md) is the task-oriented "how do I run
this" guide. These pages are the developer-oriented "why is it built this way"
companion: they explain the reasoning behind each switch, the invariants the
code is protecting, and the trade-offs that motivated a given design. Where a
behavioural claim is made it cites the file and approximate line so a reader can
verify it against the source.

> **Parent index:** this reference is one section of the whole documentation
> set. See [docs/README.md](../README.md) for the full index of docs.

## Parameter groups

The parameters are split into three groups, each documented on its own page:

| Group | Page | Covers |
|---|---|---|
| Authentication & execution control | [auth-and-execution.md](auth-and-execution.md) | How you sign in and which scope a run covers: `TenantID`, `Appid`, `Secret`, `DeviceLogin`, `SubscriptionID`, `ResourceGroup`, and the private `RunAllSubs` orchestration switch. |
| Metrics & consumption | [metrics-and-consumption.md](metrics-and-consumption.md) | The data-collection phases and their throttles: `SkipMetrics`, `SkipConsumption`, `MetricsLookbackDays`, `ConcurrencyLimit`. |
| Scaling, sharding, output & obfuscation | [scaling-sharding-output.md](scaling-sharding-output.md) | Wrapper-level scale and resume controls, output location, and privacy: `ParallelStreams`, `Resume`, `ResumeFailedOnly`, `IncludeDisabled`, `AllowPartialAccess`, `OutputDirectory`, `ReportName`, `Obfuscate`, `ObfuscationDictionary`. |

> The `metrics-and-consumption.md` and `scaling-sharding-output.md` pages are
> authored separately. If a link above 404s, that page has not landed yet — the
> auth & execution page below is complete and self-contained on its own.

## Related deep-dives

These existing docs cover specific subsystems in more depth than a parameter
reference can:

- [consumption-data.md](../consumption-data.md) — how the consumption phase
  collects billing/usage data (relevant to `SkipConsumption`).
- [obfuscation-and-unmask.md](../obfuscation-and-unmask.md) — what `-Obfuscate`
  masks and how `Reveal.ps1` selectively un-masks it.
- [recovery-and-diagnostics.md](../recovery-and-diagnostics.md) — transcripts,
  failure logs, and resume behaviour (relevant to `Resume`).
