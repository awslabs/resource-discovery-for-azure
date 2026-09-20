# Authentication & execution-control parameters

This page documents the parameters that decide **how a run authenticates to
Azure** and **which scope it covers**. For each one it gives the type, which
script declares it, what it does, and — the point of this document — **why it
exists**.

Every behavioural claim below cites a file and approximate line so it can be
checked against the source. Line numbers are approximate and drift as the code
changes; use them as a starting point, not a guarantee.

## Parameter summary

| Parameter | Type | Declared on | Purpose |
|---|---|---|---|
| [`TenantID`](#tenantid) | `string` | both scripts | Which Azure AD tenant to sign in to and enumerate. |
| [`Appid`](#appid--secret-service-principal-auth) | `string` | `ResourceInventory.ps1` | Service-principal application (client) ID for non-interactive auth. |
| [`Secret`](#appid--secret-service-principal-auth) | `securestring` | `ResourceInventory.ps1` | Service-principal client secret, paired with `Appid`. |
| [`DeviceLogin`](#devicelogin) | `switch` | both scripts | Use the device-code browser flow instead of the default interactive login. |
| [`SubscriptionID`](#subscriptionid) | `string` (GUID) | `ResourceInventory.ps1` | Scope a single-report run to exactly one subscription. |
| [`ResourceGroup`](#resourcegroup) | `string` | `ResourceInventory.ps1` | Scope a single-report run to one resource group (requires `SubscriptionID`). |
| [`RunAllSubs`](#runallsubs--the-anchor-example) | `switch` | `ResourceInventory.ps1` | **Private orchestration switch.** Set only by the wrapper; suppresses the child's own auth handling so it reuses the parent's context. |

---

## `TenantID`

- **Type:** `string`
- **Declared on:** `ResourceInventory.ps1` (`param()`, line ~3) and
  `Run-AllSubscriptions.ps1` (`param()`, line ~3, where it is
  `[Parameter(Mandatory = $true)]`).

**What it does.** Identifies the Azure AD tenant the run authenticates against
and enumerates subscriptions from. On the inner script it steers the login path:
when `TenantID` is supplied the script connects directly to that tenant; when it
is omitted the script logs in first and then discovers which tenant(s) the
identity can see (`ResourceInventory.ps1` lines ~318–345).

**Why it exists.** An identity can have access to more than one tenant, and
`Get-AzSubscription` returns whatever the *current cached context* points at.
Passing `TenantID` removes that ambiguity — the run is pinned to exactly the
tenant you name. Everywhere the script builds its subscription list it filters by
`HomeTenantId -eq $TenantID` (`ResourceInventory.ps1` lines ~278, ~369, ~405), so
subscriptions from other tenants the identity can see are excluded. On the
wrapper it is mandatory precisely because a tenant-wide sweep must never guess
which tenant it is sweeping.

The wrapper additionally accepts a **verified domain** (e.g.
`contoso.onmicrosoft.com`) and resolves it to the tenant GUID via Microsoft's
OIDC discovery endpoint before authenticating; the inner script expects a GUID.
(See the README's "Running Across All Subscriptions" section for the
domain-resolution behaviour.)

---

## `Appid` & `Secret` (service-principal auth)

- **`Appid`** — Type `string`; declared on `ResourceInventory.ps1` (`param()`, line ~4).
- **`Secret`** — Type `securestring`; declared on `ResourceInventory.ps1` (`param()`, line ~7).

**What they do.** Together with `TenantID` they select **service-principal
(non-interactive) authentication**. When all three are present the script
authenticates with the client-credentials flow rather than opening a browser:
it builds a `PSCredential` from `Appid`/`Secret` and calls
`Connect-AzAccount -ServicePrincipal -Credential $Credential -Tenant $TenantID`
(`ResourceInventory.ps1` lines ~391–393). The same service-principal path is
reused by the data-plane reconnect helper `Test-DataPlaneAuthReady` when a token
has to be re-acquired mid-run (`ResourceInventory.ps1` lines ~736–739).

**Why `Secret` is a `securestring`.** Declaring it `[securestring]` keeps the
secret out of plaintext parameter binding and command history, and lets it be
handed straight to `PSCredential`/`Connect-AzAccount` without ever materialising a
plaintext copy in the script.

**Why they exist / when to use them.** Interactive and device-code logins need a
human at a browser. Service-principal auth is the path for **unattended
automation** — CI, scheduled runs, or any context with no console. The script
enforces the all-or-nothing contract: if `Appid` is given without both `Secret`
and `TenantID`, it errors out and prints the correct invocation rather than
half-attempting a login (`ResourceInventory.ps1` lines ~395–400).

There is one important interaction with [`RunAllSubs`](#runallsubs--the-anchor-example):
under `-RunAllSubs` **without** service-principal credentials, the reconnect
helper refuses to prompt (there is no console in that context) and fails the
phase loudly instead (`ResourceInventory.ps1` lines ~741–744). So a fully
non-interactive tenant sweep effectively requires `Appid`/`Secret`, or a context
that was authenticated before the run started.

---

## `DeviceLogin`

- **Type:** `switch`
- **Declared on:** `ResourceInventory.ps1` (`param()`, line ~13) and
  `Run-AllSubscriptions.ps1` (`param()`, line ~4). The wrapper forwards it to the
  inner script when set.

**What it does.** Selects the **device-code** flow
(`Connect-AzAccount -UseDeviceAuthentication`) instead of the default interactive
browser login. Every login site in the inner script branches on
`$DeviceLogin.IsPresent` (`ResourceInventory.ps1` lines ~305–314, ~356–363,
~381–388, and the reconnect helper at ~752–754).

**Why it exists / when to use it.** The default interactive flow tries to open a
local browser, which fails on a headless host, over SSH, or anywhere a browser
cannot be launched on the same machine. Device-code auth instead prints a URL and
a short code you enter from *any* browser, so it is the workaround for those
environments. It is also the documented fix for a common failure mode: when
`Get-AzSubscription` returns nothing because a Conditional Access / MFA gate
blocked a silent token, re-running with `-DeviceLogin` forces an interactive
re-auth (see the README troubleshooting note "Get-AzSubscription returned no
subscriptions").

---

## `SubscriptionID`

- **Type:** `string`, constrained to a GUID by a `ValidatePattern`.
- **Declared on:** `ResourceInventory.ps1` (`param()`, lines ~5–6).

**The GUID `ValidatePattern`.** The parameter carries
`[ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$', ErrorMessage = 'Invalid SubscriptionID; must be a GUID')]`
(`ResourceInventory.ps1` line ~5). PowerShell rejects a malformed value at
parameter-binding time, before any Azure call runs.

**Why the pattern exists.** The subscription ID is passed into Azure Resource
Graph queries (via `Invoke-AzGraphQuerySafe -Subscription $SubscriptionID`,
`ResourceInventory.ps1` lines ~487–491). Validating the shape up front means an
obviously wrong value fails immediately with a clear message rather than
producing a confusing empty result far downstream, and it narrows the surface for
passing a malformed value into query machinery.

**What it does / when to use it.** Scopes a single-report run to exactly one
subscription. The Resource Graph enumeration targets only that subscription
(`ResourceInventory.ps1` lines ~487–500); the metrics phase's failure-accounting
uses the ID to pin the "affected subscription" when it has to record a metrics
skip (`ResourceInventory.ps1` line ~790); and under `-RunAllSubs` the ID is also
woven into the per-subscription log file names so parallel children don't collide
(`ResourceInventory.ps1` lines ~693–694, ~704–705).

**Why it exists.** It is the "just this one subscription" entry point. The
tenant-wide wrapper does **not** expose it as a user option — instead the wrapper
*supplies* it internally, once per subscription, when it fans out
(`Run-AllSubscriptions.ps1` lines ~1174 and ~1330). So the same parameter serves
two roles: a user-facing single-subscription scope, and the wrapper's internal
"which subscription is this child doing" argument.

---

## `ResourceGroup`

- **Type:** `string`, constrained by a `ValidatePattern`.
- **Declared on:** `ResourceInventory.ps1` (`param()`, lines ~8–9).

**The `ValidatePattern`.** The parameter carries
`[ValidatePattern('^[A-Za-z0-9._()-]{1,90}$', ErrorMessage = 'Invalid resource group name; must match ^[A-Za-z0-9._()-]{1,90}$')]`
(`ResourceInventory.ps1` line ~8). The allowed character set and the 1–90 length
bound mirror Azure's own resource-group naming rules, so a name Azure would
reject is rejected here first.

**Why the pattern exists.** As with `SubscriptionID`, the resource-group name is
interpolated directly into Resource Graph query text
(`where resourceGroup == '$ResourceGroup'`, `ResourceInventory.ps1` lines ~455
and ~468). Restricting it to the legal Azure character class keeps a stray quote
or KQL metacharacter from breaking or subverting the query, and rejects typos
before any work is done.

**What it does / when to use it.** Scopes a single-report run to one resource
group. It is only meaningful together with `SubscriptionID`: the script hard-fails
if `ResourceGroup` is set without `SubscriptionID`
(`ResourceInventory.ps1` lines ~439–444), and it lowercases the name before use
(`ResourceInventory.ps1` lines ~446–449) so matching is case-insensitive.

**Why it exists.** It is the narrowest scope the tool offers — useful for a quick
inventory of one application's resource group without walking a whole
subscription, let alone a whole tenant. Like `SubscriptionID`, it is a
single-report concept and is **not** surfaced by the wrapper.

---

## `RunAllSubs` — the anchor example

- **Type:** `switch`
- **Declared on:** `ResourceInventory.ps1` (`param()`, line ~16).

`RunAllSubs` is the most interesting parameter in this group because it is not
really a parameter *for users* at all — it is a private contract between the two
scripts. It is worth understanding in detail because it explains the whole
authentication design.

### It is a private orchestration switch, not a user-facing flag

You never pass `-RunAllSubs` yourself. It is set exactly once, by the wrapper,
each time the wrapper launches the inner script for a subscription:

```powershell
& (Join-Path $PSScriptRoot "ResourceInventory.ps1") -TenantID $TenantID -SubscriptionID $Sub.Id @InventoryPassthrough -RunAllSubs
```

This exact call appears twice — once on the sequential path
(`Run-AllSubscriptions.ps1` line ~1174) and once on the parallel per-stream path
(`Run-AllSubscriptions.ps1` line ~1330). In both, `-RunAllSubs` tells the child
"you are one of many children in a batch the wrapper is orchestrating; behave
accordingly."

### It suppresses the child's own auth handling

Inside `ResourceInventory.ps1`, every place that would otherwise tear down the
cached context or run a login is guarded by `if (!$RunAllSubs.IsPresent)`:

- The `Disconnect-AzAccount` on the no-`TenantID` path is skipped
  (`ResourceInventory.ps1` lines ~294–297).
- The interactive/device browser login on that path is skipped
  (`ResourceInventory.ps1` lines ~302–316).
- The post-tenant-selection re-login is skipped
  (`ResourceInventory.ps1` lines ~352–364).
- The `TenantID`-supplied path — its `Disconnect-AzAccount` and its interactive,
  device, **and** service-principal login branches — is skipped
  (`ResourceInventory.ps1` lines ~374–401).

With the switch present the child performs **no** login of its own. It relies on
the Azure context the wrapper already established — either the parent's live
session (sequential path) or a saved context each stream imports (parallel path;
`Save-AzContext` / `Import-AzContext` in `Run-AllSubscriptions.ps1`). If, despite
that, a child finds no usable token, the reconnect helper deliberately refuses to
prompt under `-RunAllSubs` and fails the phase loudly instead of hanging
(`ResourceInventory.ps1` lines ~741–744).

### It forces non-interactive tenant selection

When no `TenantID` is supplied and the identity can see multiple tenants, the
standalone script prints the tenant list and asks the user to pick one. Under a
batch that prompt would block forever. The switch short-circuits it:

```powershell
$IsInteractiveSession = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
if ($RunAllSubs.IsPresent -or -not $IsInteractiveSession)
{
    $TenantID = $Tenants[0]
    ...
}
```

(`ResourceInventory.ps1` lines ~339–343.) So `-RunAllSubs` (and, independently,
any non-interactive session) defaults to the first tenant instead of issuing a
`Read-Host` that no one is there to answer.

### Why it exists: authenticate once, reuse everywhere

Put the three behaviours together and the reason for the switch is clear. A
tenant with *N* subscriptions is inventoried by launching the inner script *N*
times. If each child did its **own** auth — the standalone behaviour — an
*N*-subscription run would trigger *N* disconnects and *N* interactive logins: *N*
browser or device-code prompts, *N* chances to hit throttling or a Conditional
Access gate, and a batch that stalls the moment one child hits an interactive
prompt with no human present.

`-RunAllSubs` collapses all of that to a single authentication in the wrapper,
reused by every child. The wrapper signs in once (and only if the cached session
can't already acquire a token silently), then every child rides that context.
That is the entire point of the switch: **authenticate once in the parent, reuse
everywhere in the children.**

---

## Why the standalone path disconnects before reconnecting

The flip side of `-RunAllSubs` is what the standalone (non-wrapper) path does
*instead*: it disconnects the cached Azure session before logging in again. In
the code this is `Disconnect-AzAccount -ErrorAction SilentlyContinue | Out-Null`
immediately before the `Connect-AzAccount` block, logged as **"Clearing account
cache"** (`ResourceInventory.ps1` lines ~292→296→305/311 on the no-`TenantID`
path, and again on the `TenantID`-supplied path at lines ~374→376→381/392).
Understanding *why* it does this is what explains why a batch must switch it off.

### Stale or wrong cached context

Az PowerShell persists a context on disk (typically
`~/.Azure/AzureRmContext.json`). A leftover session from a *different* tenant or
identity will make `Get-AzSubscription` return the **wrong** subscriptions —
silently, because the call does not error on a "wrong-but-valid" context. The
script guards against exactly this: before re-authenticating on the mismatch path
it logs

> "Current session is for tenant X, but requested tenant is Y. Re-authenticating."

(`ResourceInventory.ps1` line ~283), then falls through to the
disconnect + login. Disconnecting first guarantees the subsequent enumeration
reflects the tenant you actually asked for, not whatever happened to be cached.

### A clean switch between auth methods

The tool supports several mutually exclusive login methods on this path:
interactive browser, device code (`-DeviceLogin`), and service principal
(`-Appid`/`-Secret`). Tearing the old session down first avoids **mixing** a stale
token from one method with a fresh login from another — e.g. an old interactive
refresh token lingering while you try to switch to a service principal. The
disconnect-then-connect order keeps each run's credential state unambiguous.

### A deterministic subscription set

Right after connecting, the script derives its subscription set from the
freshly-authenticated context, filtered to the requested tenant:
`Get-AzSubscription | Where-Object { $_.HomeTenantId -eq $TenantID }`
(`ResourceInventory.ps1` lines ~369 and ~405; the tenant-discovery read
`(Get-AzSubscription ...).HomeTenantId` at line ~322 works the same way). Those
reads are only trustworthy on a *known-clean* context; a residual session from
another identity would quietly skew them. Disconnecting first makes the result
deterministic.

### The trade-off that motivates `-RunAllSubs`

Disconnect-then-reconnect is exactly right for a **single interactive run**: it
costs one login and buys a guaranteed-correct scope. But it is actively
**harmful for a batch**. If every one of *N* child runs disconnected and
re-authenticated, the wrapper's carefully-established shared context would be
destroyed *N* times over, each destruction triggering a fresh interactive prompt
the batch cannot answer.

So the same behaviour that makes the standalone path correct is what makes it
wrong at scale — and `-RunAllSubs` is precisely the switch that turns it off. The
standalone script disconnects and reconnects to be *safe*; the wrapper sets
`-RunAllSubs` on each child to *reuse* the one good context it already holds. The
two paths are two sides of the same design decision about where authentication
should happen.

---

## See also

- [Top-level README](../../README.md) — the task-oriented "how do I run this"
  guide.
- [docs/README.md](../README.md) — the full documentation index.
- [variables/README.md](README.md) — the parameter-reference index this page
  belongs to.
