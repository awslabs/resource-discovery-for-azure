# Recipes — worked, copy-pasteable invocations

This is the task-oriented companion to the [parameter reference
index](README.md). The reference pages explain **why** each parameter exists and
what invariant it protects; this page shows **how** to string the parameters
together into complete command lines for the scenarios that come up most often.

For the "why" behind any flag used below, follow the link to its reference page:

- [auth-and-execution.md](auth-and-execution.md) — `TenantID`, `Appid`,
  `Secret`, `DeviceLogin`, `SubscriptionID`, `ResourceGroup`, `RunAllSubs`.
- [metrics-and-consumption.md](metrics-and-consumption.md) — `SkipMetrics`,
  `SkipConsumption`, `SkipDiskMetrics`, `MetricsLookbackDays`, `ConcurrencyLimit`.
- [scaling-sharding-output.md](scaling-sharding-output.md) — `ParallelStreams`,
  `Resume`, `ResumeFailedOnly`, `ShardIndex`/`ShardCount`, `OutputDirectory`,
  `ReportName`, `Obfuscate`, `ObfuscationDictionary`, `UploadToBlobContainerUri`,
  `StateBlobContainerUri`.

> **Which script?** `ResourceInventory.ps1` is the inner, single-report script —
> it scans one subscription (or one resource group) and produces one report.
> `Run-AllSubscriptions.ps1` is the tenant-wide wrapper — it fans out over every
> subscription in a tenant and produces one report per subscription. A few
> parameters exist on only one of the two; each recipe notes it where it matters.

> All placeholder values below (`contoso.onmicrosoft.com`, `<subscription-guid>`,
> `<app-id>`, …) are examples — substitute your own. Never paste real credentials
> into a shell where they land in command history.

---

## 1. Inventory a single subscription

**When to use this:** you want one report for exactly one subscription, not the
whole tenant.

```powershell
./ResourceInventory.ps1 -ReportName "Contoso" -TenantID "contoso.onmicrosoft.com" -SubscriptionID "<subscription-guid>"
```

**Parameters that matter:**

- `-SubscriptionID` scopes the run to exactly one subscription. It is declared
  **only on `ResourceInventory.ps1`** — the wrapper does not expose it — and is
  validated as a GUID at parameter-binding time, so a malformed value fails
  immediately (see [`SubscriptionID`](auth-and-execution.md#subscriptionid)).
- `-ReportName` names the output files (`Inventory_<ReportName>_<timestamp>.json`,
  etc.). It defaults to `ResourcesReport`, but set it to your company/customer
  name so the deliverable is self-describing.
- `-TenantID` pins the login to one tenant. The inner script expects a **GUID**
  here; the tenant-*wrapper* additionally accepts a domain name (see recipe 3).

---

## 2. Inventory a single resource group

**When to use this:** a quick inventory of one application's resource group,
without walking the whole subscription.

```powershell
./ResourceInventory.ps1 -ReportName "Contoso" -TenantID "contoso.onmicrosoft.com" -SubscriptionID "<subscription-guid>" -ResourceGroup "Production-RG"
```

**Parameters that matter:**

- `-ResourceGroup` is the narrowest scope the tool offers. It is **only
  meaningful together with `-SubscriptionID`** — the inner script hard-fails if
  `-ResourceGroup` is set without `-SubscriptionID` (see
  [`ResourceGroup`](auth-and-execution.md#resourcegroup)). The name is validated
  against Azure's resource-group naming rules and matched case-insensitively.
- Like `-SubscriptionID`, `-ResourceGroup` is **inner-script only** — the wrapper
  does not surface it.

---

## 3. Inventory an entire tenant

**When to use this:** the normal full-estate run — one report per subscription
across the whole tenant.

```powershell
./Run-AllSubscriptions.ps1 -TenantID "contoso.onmicrosoft.com"
```

**Parameters that matter:**

- `-TenantID` is **required** on the wrapper and accepts **either a tenant GUID
  or a verified domain name** (e.g. `contoso.onmicrosoft.com`); a domain is
  resolved to its GUID via Microsoft's OIDC discovery endpoint before
  authenticating (see [`TenantID`](auth-and-execution.md#tenantid)). The GUID
  form works too:

  ```powershell
  ./Run-AllSubscriptions.ps1 -TenantID "<tenant-guid>"
  ```

- No scope flags are needed — the wrapper enumerates every enabled subscription
  the identity can read and produces a per-subscription report, then bundles them
  into a single `AllSubscriptions_ResourcesReport_<timestamp>.zip`.

---

## 4. Unattended automation with a service principal

**When to use this:** CI, a scheduled job, or any context with no human at a
browser. Service-principal (client-credentials) auth needs no interactive login.

Build the secret as a `securestring` first, then pass it — never inline a
plaintext secret on the command line:

```powershell
# Read the secret without echoing it, as a securestring:
$Secret = Read-Host -AsSecureString -Prompt "Client secret"

./ResourceInventory.ps1 -ReportName "Contoso" `
    -TenantID "<tenant-guid>" `
    -Appid "<app-id>" `
    -Secret $Secret `
    -SubscriptionID "<subscription-guid>"
```

If the secret must come from an environment variable (e.g. a CI secret store),
convert it to a `securestring` rather than passing the plaintext:

```powershell
$Secret = ConvertTo-SecureString $env:AZURE_CLIENT_SECRET -AsPlainText -Force
./ResourceInventory.ps1 -ReportName "Contoso" -TenantID "<tenant-guid>" -Appid "<app-id>" -Secret $Secret -SubscriptionID "<subscription-guid>"
```

**Parameters that matter:**

- `-Appid`, `-Secret`, and `-TenantID` together select service-principal auth.
  All three are required as a set — supplying `-Appid` without both `-Secret` and
  `-TenantID` errors out. `-Secret` is a `[securestring]` so the secret is never
  materialised as plaintext in parameter binding (see
  [`Appid` & `Secret`](auth-and-execution.md#appid--secret-service-principal-auth)).
  (PowerShell binds parameter names case-insensitively, so `-appid` and `-Appid`
  are equivalent.)
- `-Appid` and `-Secret` are declared **only on `ResourceInventory.ps1`** — they
  are not wrapper parameters. For a **non-interactive tenant sweep**, this is the
  key relationship to understand: under the wrapper's internal `-RunAllSubs`
  orchestration, the child reuses the parent's already-authenticated context
  rather than logging in per subscription, and the mid-run reconnect helper
  **will not prompt** in that context. So a fully non-interactive tenant sweep
  needs either service-principal credentials or a context that was authenticated
  before the run started. The full explanation of that auth-reuse contract lives
  in [auth-and-execution.md](auth-and-execution.md#runallsubs--the-anchor-example)
  — see the `RunAllSubs` section rather than duplicating it here.

---

## 5. Headless / SSH / no-browser environment

**When to use this:** you are on a remote host over SSH, a headless VM, or
anywhere the default interactive login cannot open a local browser.

```powershell
# Tenant-wide:
./Run-AllSubscriptions.ps1 -TenantID "contoso.onmicrosoft.com" -DeviceLogin

# Single subscription:
./ResourceInventory.ps1 -ReportName "Contoso" -TenantID "<tenant-guid>" -SubscriptionID "<subscription-guid>" -DeviceLogin
```

**Parameters that matter:**

- `-DeviceLogin` selects the device-code flow: the script prints a URL and a
  short code you enter from *any* browser, instead of trying to launch one
  locally. It is declared on **both scripts**, and the wrapper forwards it to the
  inner script (see [`DeviceLogin`](auth-and-execution.md#devicelogin)).
- It is also the documented fix when `Get-AzSubscription` returns nothing because
  a Conditional Access / MFA gate blocked a silent token — re-run with
  `-DeviceLogin` to force an interactive re-auth.

---

## 6. Faster runs by skipping phases

**When to use this:** you need a quicker run and can accept a less complete
report — for example a first-pass resource census where cost and utilization data
are not yet needed.

```powershell
# Skip both metrics and consumption (fastest; inventory only):
./Run-AllSubscriptions.ps1 -TenantID "contoso.onmicrosoft.com" -SkipMetrics -SkipConsumption

# Keep metrics but drop the heaviest metric source (managed-disk I/O):
./Run-AllSubscriptions.ps1 -TenantID "contoso.onmicrosoft.com" -SkipDiskMetrics
```

**Parameters that matter — and what you lose:**

- `-SkipMetrics` skips Azure Monitor metrics collection entirely. You lose all
  utilization/performance data (CPU, memory, disk I/O), which is usually the
  slowest phase — so this is the biggest single time saving, at the cost of any
  right-sizing signal.
- `-SkipConsumption` skips cost/billing collection. You lose the consumption CSV.
  This greatly reduces the report's usefulness for cost analysis, so skip it only
  when you genuinely don't need billing data.
- `-SkipDiskMetrics` is the middle ground: it drops **only** the managed-disk
  composite I/O metrics (often the single largest metric source — four calls per
  attached disk) while keeping every other metric. Use it when disk I/O is the
  bottleneck but you still want VM/DB utilization.
- All three are declared on **both scripts** and forwarded by the wrapper. See
  [metrics-and-consumption.md](metrics-and-consumption.md) for the full trade-offs
  and for finer volume controls (`-MetricsLookbackDays`, `-MetricsIntervalMinutes`).

---

## 7. Resume an interrupted tenant run

**When to use this:** a tenant run was cut short (a Cloud Shell session timeout,
a dropped network, an accidental Ctrl+C) and you want to finish it without
re-scanning the subscriptions that already completed.

```powershell
# Continue: skip already-completed subs, do the failed + not-yet-attempted ones:
./Run-AllSubscriptions.ps1 -TenantID "contoso.onmicrosoft.com" -Resume

# Retry ONLY the subs that failed last time (skip completed and never-attempted):
./Run-AllSubscriptions.ps1 -TenantID "contoso.onmicrosoft.com" -ResumeFailedOnly
```

**Parameters that matter:**

- `-Resume` reads the state file
  (`InventoryReports/.resume-state-<TenantID>.json`) and skips subscriptions that
  already finished; it re-runs the one that was in progress plus any not yet
  attempted. Without `-Resume`, the wrapper processes every subscription and
  leaves existing state untouched.
- `-ResumeFailedOnly` is the narrower retry: it re-runs **only** subscriptions
  that failed in a prior run (e.g. transient throttling), skipping both completed
  and never-attempted ones. Use it after a run finishes with a handful of
  failures instead of walking the whole tenant again.
- Both are **wrapper-only**. See
  [scaling-sharding-output.md](scaling-sharding-output.md) for the resume-state
  mechanics and [recovery-and-diagnostics.md](../recovery-and-diagnostics.md) for
  the failure logs that tell you which subscriptions to retry.

---

## 8. Large-tenant scale-out: shard across machines

**When to use this:** a very large tenant (thousands of subscriptions) where one
machine — even with parallel streams — is the wall. Split the tenant across N
independent machines, one shard per machine.

Run the **same** command on each machine, with the same `-ShardCount` and a
distinct `-ShardIndex` from `0` to `ShardCount-1`:

```powershell
# Machine 0 of 10:
./Run-AllSubscriptions.ps1 -TenantID "contoso.onmicrosoft.com" -ShardCount 10 -ShardIndex 0 -ParallelStreams 6 -Obfuscate

# Machine 1 of 10:
./Run-AllSubscriptions.ps1 -TenantID "contoso.onmicrosoft.com" -ShardCount 10 -ShardIndex 1 -ParallelStreams 6 -Obfuscate

# ... through -ShardIndex 9
```

**Parameters that matter:**

- `-ShardCount` / `-ShardIndex` split the tenant's subscriptions across
  independent machines by a stable hash of each subscription id — the shards are
  disjoint and together cover every subscription, with no coordination between
  machines. Run one shard per machine, each with its own output directory.
- `-ParallelStreams` is orthogonal: it controls how many subscriptions each
  machine processes concurrently across its own cores. Sharding multiplies that
  across machines.

**Rate-limit caveat:** useful parallelism per machine is capped at roughly **6
streams** by tenant-wide Azure Resource Graph limits, and Resource Graph
*discovery* draws from a single shared tenant budget across all shards — so it
does **not** speed up linearly with machine count. Sharding scales the
per-subscription phases (metrics, consumption), not shared-budget discovery. The
top-level [README](../../README.md) and
[horizontal-sharding.md](../horizontal-sharding.md) carry the authoritative
numbers; see in particular
[horizontal-sharding.md — "Rate limits: why ~6 streams per machine"](../horizontal-sharding.md#rate-limits-why-6-streams-per-machine-and-what-sharding-actually-speeds-up).

---

## 9. Privacy-preserving output (obfuscation)

**When to use this:** the report will be shared externally (e.g. with the AWS
team) and must not expose real resource names, IDs, subscriptions, or tags.

```powershell
# Whole tenant, masked:
./Run-AllSubscriptions.ps1 -TenantID "contoso.onmicrosoft.com" -Obfuscate

# Single consolidated report, masked, with an explicit dictionary path:
./ResourceInventory.ps1 -ReportName "Contoso" -TenantID "<tenant-guid>" -Obfuscate -ObfuscationDictionary "./ObfuscationDictionary_Contoso.json"
```

**Parameters that matter:**

- `-Obfuscate` masks resource IDs, names, subscriptions, resource groups, tag
  values, and free-text/identity fields with deterministic tokens, while
  preserving location, SKU, sizes, metric values, and consumption quantities. It
  is declared on **both scripts** and forwarded by the wrapper.
- `-ObfuscationDictionary` (a path to the reverse-lookup JSON) is declared
  **only on `ResourceInventory.ps1`** — it is not a wrapper parameter. The
  dictionary maps every masked value back to the real one and **stays local** (it
  is never included in the shared ZIP).
- To selectively un-mask specific fields for a recipient, or fully reveal,
  produce a new ingestible ZIP with `Reveal.ps1`. See
  [obfuscation-and-unmask.md](../obfuscation-and-unmask.md) for exactly what is
  masked and how to reveal it.

---

## 10. Controlling output location and name

**When to use this:** you want reports written somewhere other than the default
`InventoryReports` location, or (in a multi-machine campaign) uploaded to a
shared blob container.

```powershell
# Redirect output to a specific full path (inner script):
./ResourceInventory.ps1 -ReportName "Contoso" -TenantID "<tenant-guid>" -SubscriptionID "<subscription-guid>" -OutputDirectory "/data/rda-out"

# Tenant sweep on ephemeral compute: upload each node's ZIP and mirror resume state to blob:
./Run-AllSubscriptions.ps1 -TenantID "contoso.onmicrosoft.com" `
    -UploadToBlobContainerUri "https://acct.blob.core.windows.net/container" `
    -StateBlobContainerUri "https://acct.blob.core.windows.net/container"
```

**Parameters that matter:**

- `-ReportName` names the output files. It defaults to `ResourcesReport`, so set
  it to your company/customer name to keep the deliverable self-describing. It is
  **inner-script only** — the wrapper derives report names per subscription
  itself.
- `-OutputDirectory` is the directory reports are written to. It must be a
  **full** path (the inner script resolves it and errors out if it cannot), and
  defaults to `~/InventoryReports` (or `C:\InventoryReports` on Windows). It is
  **inner-script only** — the wrapper manages its own output root.
- `-UploadToBlobContainerUri` uploads each node's finalized report ZIP to a
  shared blob container (passwordless, via the run's own identity; needs
  `Az.Storage` and `Storage Blob Data Contributor` on the container). It is how a
  multi-machine / AKS campaign gathers shards centrally when there is no shared
  filesystem.
- `-StateBlobContainerUri` mirrors the resume/state file to blob so `-Resume`
  survives loss of a node's local disk (e.g. an AKS pod rescheduled mid-run).
- The two blob parameters are **wrapper-only**. See
  [scaling-sharding-output.md](scaling-sharding-output.md) for their validation
  rules and the "why" behind each.
