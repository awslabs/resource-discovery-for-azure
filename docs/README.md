# Documentation index

This directory holds the developer- and operator-oriented documentation for
Resource Discovery for Azure (RDA). The [top-level README](../README.md) is the
task-oriented "how do I run this" guide; the docs below explain **why** the tool
behaves the way it does and go deeper into individual subsystems.

## Parameter reference

The "why behind each parameter" companion to the top-level README's parameter
tables. Start at the index and drill into the group you care about.

- [variables/README.md](variables/README.md) — index of the parameter reference,
  grouped by concern.
- [variables/auth-and-execution.md](variables/auth-and-execution.md) — how a run
  authenticates and which scope it covers (`TenantID`, `Appid`/`Secret`,
  `DeviceLogin`, `SubscriptionID`, `ResourceGroup`, and the private `RunAllSubs`
  switch).
- [variables/metrics-and-consumption.md](variables/metrics-and-consumption.md) —
  the two most expensive phases and their throttles (`SkipMetrics`,
  `SkipConsumption`, `MetricsLookbackDays`, `MetricsDetailed`,
  `MetricsIntervalMinutes`, `IncludeStorageMetrics`, `SkipDiskMetrics`,
  `UseMetricsBatch`, `ConcurrencyLimit`).
- [variables/scaling-sharding-output.md](variables/scaling-sharding-output.md) —
  scale, resume, planning, output location, service filter, and obfuscation
  (`ParallelStreams`, `ShardCount`/`ShardIndex`, `Resume`, `ResumeFailedOnly`,
  `Plan`, `OutputDirectory`, `ReportName`, `Obfuscate`).
- [variables/recipes.md](variables/recipes.md) — copy-paste parameter recipes
  for common scenarios.

## Subsystem deep-dives

Detailed explanations of specific parts of the tool, deeper than a parameter
reference.

- [consumption-data.md](consumption-data.md) — how the consumption phase
  collects billing/usage data, what each CSV column means, and what is
  deliberately excluded.
- [obfuscation-and-unmask.md](obfuscation-and-unmask.md) — what `-Obfuscate`
  masks, the dictionary format, and how `Reveal.ps1` selectively un-masks a
  report.
- [horizontal-sharding.md](horizontal-sharding.md) — splitting a very large
  tenant across independent machines with `-ShardCount`/`-ShardIndex`, and the
  rate-limit reasoning behind it.
- [metrics-batch-trial.md](metrics-batch-trial.md) — the experimental
  `-UseMetricsBatch` (`metrics:getBatch`) data-plane path and how to trial it.
- [recovery-and-diagnostics.md](recovery-and-diagnostics.md) — targeted
  collection, repairing a partly-failed run, transcripts, and failure logs.

## Operations & deployment

- [Plan.md](Plan.md) — the empirical sizing model behind `-Plan`: what drives
  per-subscription run time and how shard counts are grounded in real data.

## Design & internals

For contributors and anyone tracing behaviour back to the source.

- [architecture-two-scripts.md](architecture-two-scripts.md) — why RDA is split
  into an inner per-subscription worker and a tenant-wide wrapper (the
  process-global Az context constraint behind safe parallelism).
- [ResourceInventory-line-by-line.md](ResourceInventory-line-by-line.md) — a
  plain-English, top-to-bottom walkthrough of `ResourceInventory.ps1`.
- [contributing-collectors.md](contributing-collectors.md) — orientation for
  adding or changing a service collector (pairs with the top-level
  [CONTRIBUTING.md](../CONTRIBUTING.md)).
- [design/main-html-summary.md](design/main-html-summary.md) — design spec for
  the aggregate cross-subscription HTML summary (`New-RdaAllSubHtmlSummary`).
