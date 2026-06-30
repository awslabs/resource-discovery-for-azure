# Obfuscation and Unmasking

How the `-Obfuscate` feature in `ResourceInventory.ps1` protects customer data,
and how the local `Unmask-Obfuscation.ps1` helper reverses it.

> **TL;DR**
> - Run with `-Obfuscate` to produce a shareable report whose subscription,
>   resource group, resource ID, and resource name values are replaced with
>   opaque `prod_`/`nonprod_` tokens.
> - The run also writes a **local** `ObfuscationDictionary_*.json` that maps
>   each token back to the real value. **The ZIP is safe to share; the
>   dictionary and the transcript are not.**
> - Use `Unmask-Obfuscation.ps1` **locally** to look a token back up when a
>   partner asks "what is `prod_a1b2c3d4-...`?"

---

## 1. What gets obfuscated

When `-Obfuscate` is supplied, five identifier classes are replaced everywhere
they appear in the report:

| Class | Example real value | Example obfuscated token |
|---|---|---|
| Resource ID | `/subscriptions/<guid>/resourceGroups/rg-app/providers/.../vm01` | `prod_a1b2c3d4-...` |
| Resource Name | `vm01` | `prod_9f8e7d6c-...` |
| Subscription | `Contoso Production` | `prod_2b2b2b2b-...` |
| Resource Group | `rg-app` | `prod_4c4c4c4c-...` |
| Tag value | `payments` | `prod_7e7e7e7e-...` |

### Tags: keys kept, values tokenized

Resource tags are **not dropped**. Instead:

- The tag **key** (e.g. `environment`, `costCenter`, `owner`) is kept
  **verbatim** — keys are low-risk and are what makes tag-based grouping useful.
- The tag **value** (which frequently carries owner emails, cost-centre codes,
  and free-text PII) is replaced with a deterministic `prod_`/`nonprod_` token,
  exactly like the other identifier classes.

Because tokenization is deterministic within a run, every resource tagged
`environment = production` shows the **same** value token, so the obfuscated
report can still group and correlate by tag value without exposing it. The
real value is recoverable locally via the dictionary's `TagMap` (see §4, §5).

Everything else in a record (location, SKU, sizes, metric values, counts) is
**not** obfuscated — it carries no customer identity and is what makes the
report useful for assessment.

Everything else in a record (location, SKU, sizes, metric values, counts) is
**not** obfuscated — it carries no customer identity and is what makes the
report useful for assessment.

---

## 2. Token format: `prod_` / `nonprod_` + GUID

Every obfuscated token is a prefix followed by a fresh GUID:

```
prod_a1b2c3d4-e5f6-...        (prod_ followed by a GUID)
nonprod_5e6f7a8b-1c2d-...     (nonprod_ followed by a GUID)
```

The **prefix preserves the production / non-production signal** so the report
is still useful for environment-level analysis without revealing names. A value
is classified `nonprod_` when its source name matches either:

- the word-boundary set `dev | test | qa | tst | development | non-prod | uat | nonprod`, or
- a leading/segment hint like `d-`, `t-`, `s-` (regex `(^|-)([dts])-`).

Otherwise it is `prod_`. The classification is computed independently per class:

- Resource ID / Name prefix is derived from the **resource name**.
- Subscription token prefix is derived from the **subscription name**.
- Resource Group token prefix is derived from the **resource group name**.

### Resource-type hints in obfuscated names

To allow server-side grouping of certain managed resources, the obfuscated
**name** (not the ID) embeds a type marker for a few cases:

| Real ID contains | Obfuscated name becomes |
|---|---|
| `databricks` | `prod_databricks_<guid>` |
| `/resourcegroups/mc_` (AKS managed RG) | `prod_aks_<guid>` |
| `virtualmachinescalesets` | `prod_vmss_<guid>` |

---

## 3. Determinism (the important guarantee)

**Within a single run, the same real value always maps to the same token.**
This is what keeps the report internally consistent — relationships survive
obfuscation.

- **Subscription** and **Resource Group** tokens are looked up by the real
  *name* in per-run lookup tables (`$subLookup`, `$rgLookup`). Every resource in
  `Contoso Production` therefore shows the *same* subscription token, and every
  resource in `rg-app` shows the *same* RG token.
- **Resource ID** and **Resource Name** tokens are generated once per real
  resource ID during the build pass, so each resource keeps one stable ID token
  and one stable name token for the rest of the run.

### Cross-references stay linked

When one resource points at another (e.g. a disk's owning VM, a SQL VM's parent
compute VM, a VM's scale set), the collector resolves the *target's real ID*
through `$ResourceIdDictionary` and emits the **same token** the target resource
uses. So a relationship that existed in the real data still resolves to a single
shared token in the obfuscated report.

- If the cross-reference target is **in scope** (was inventoried) → its shared
  token is used.
- If the target is **out of scope / not in the dictionary** → the literal
  sentinel `obfuscated` is emitted (a deliberate, non-recoverable marker).
- For metric rows whose resource is not in the main dictionary (e.g. a
  transient/deleted resource), a fresh `prod_`/`nonprod_<guid>` is cached so the
  same resource still correlates across its own metrics.

### Determinism does NOT hold across runs

GUIDs are regenerated every run. The same resource will get a **different** token
in tomorrow's run. Tokens are only meaningful together with the dictionary
produced by that *same* run. Do not compare tokens between two different report
ZIPs.

---

## 4. The dictionary file (`ObfuscationDictionary_*.json`)

At the end of an obfuscated run the tool writes:

```
ObfuscationDictionary_<ReportName>_<timestamp>.json
```

It contains six maps. **A subtlety to understand:** the four core maps resolve a
token back to the real **resource ID** (an ARM path), *not* to a bare name. The
`SubscriptionNameMap` stores the subscription **display name** directly so the
subscription can be resolved fully offline; `TagMap` stores the real **tag
value** directly (it is not derived from an ID):

```jsonc
{
  "GeneratedAt": "2026-06-30 12:00:00",
  "ResourceIdMap":      { "prod_a1b2...": "/subscriptions/<guid>/resourceGroups/rg-app/providers/.../vm01" },
  "ResourceNameMap":    { "prod_9f8e...": "/subscriptions/<guid>/resourceGroups/rg-app/providers/.../vm01" },
  "SubscriptionMap":    { "prod_2b2b...": "/subscriptions/<guid>/resourceGroups/rg-app/providers/.../vm01" },
  "ResourceGroupMap":   { "prod_4c4c...": "/subscriptions/<guid>/resourceGroups/rg-app/providers/.../vm01" },
  "SubscriptionNameMap":{ "prod_2b2b...": "Contoso Production" },
  "TagMap":             { "prod_7e7e...": "payments" }
}
```

That is why unmasking derives the friendly values:
- Resource Group name is parsed from `/resourceGroups/<name>` in the ID.
- Subscription name is read from `SubscriptionNameMap` when present (offline). For
  older dictionaries that predate this map, only the `/subscriptions/<guid>` GUID
  is recoverable offline; the name then needs `-ResolveSubscriptionName` (online).
- Resource Name is the last segment of the ID.
- Resource ID is the ID itself.
- Tag value is read directly from `TagMap`. Older dictionaries that predate tag
  obfuscation have no `TagMap` (it is optional, not part of the required-map
  check).

### Handling rules — what is and isn't shareable

| Artifact | Shareable? |
|---|---|
| The report **ZIP** (obfuscated) | ✅ Yes — safe to share with AWS / partners |
| `ObfuscationDictionary_*.json` | ❌ **No — local only** |
| The PowerShell **transcript** | ❌ **No — local only** (captures account UPN + tenant/sub IDs) |
| `Unmask-Obfuscation.ps1` and its output | ❌ **No — local only** |

Delete the dictionary and transcript when they are no longer needed.

---

## 5. Unmasking with `Unmask-Obfuscation.ps1`

`Unmask-Obfuscation.ps1` is a **local, offline** reverse-lookup helper. It reads
an `ObfuscationDictionary_*.json` and resolves tokens back to real values. It
does not contact Azure at all — unless you point it at an *older* dictionary
(without `SubscriptionNameMap`) and ask it to resolve a subscription GUID to its
friendly name via `-ResolveSubscriptionName`.

### How it resolves each field

| Token type | Resolves to | Source |
|---|---|---|
| `ResourceGroup` | the RG name | parsed from `/resourceGroups/<name>` in the ID (offline, exact) |
| `Subscription` | the subscription **name** | from `SubscriptionNameMap` (offline). Older dictionaries lack it → resolves to the GUID; add `-ResolveSubscriptionName` for the name (online) |
| `ResourceId` | the full ARM resource ID | returned directly |
| `ResourceName` | the resource's short name | last `/`-delimited segment of the ID |
| `Tag` | the real tag **value** | from `TagMap` (offline, exact). The tag key is already verbatim in the report |

### Non-recoverable (lossy) values

These are *intentionally* not in the dictionary and the script reports them as
`Lossy`:

- `obfuscated` — the literal sentinel stamped on an out-of-scope cross-reference.
- `obfuscated_<guid>` — the fallback used for a malformed/null-ID row.

### Usage

```powershell
# Resolve a single token (auto-discovers the newest dictionary in the cwd)
./Unmask-Obfuscation.ps1 -Value 'prod_a1b2c3d4-...'

# Point at a specific dictionary
./Unmask-Obfuscation.ps1 -DictionaryPath ./ObfuscationDictionary_Report_2026-06-30.json -Value 'prod_a1b2c3d4-...'

# Resolve several tokens from the pipeline, only treating them as Resource Groups
'prod_4c4c...','nonprod_5d5d...' | ./Unmask-Obfuscation.ps1 -Field ResourceGroup

# Dump every Subscription mapping and resolve GUIDs to friendly names (needs Az sign-in)
./Unmask-Obfuscation.ps1 -All -Field Subscription -ResolveSubscriptionName | Format-Table -AutoSize

# Dump the two identity maps customers care about most (Subscription + Resource Group)
./Unmask-Obfuscation.ps1 -All | Format-Table -AutoSize
```

### Parameters

- `-DictionaryPath` — path to the dictionary JSON. If omitted, the newest
  `ObfuscationDictionary_*.json` under `-SearchDirectory` is used.
- `-SearchDirectory` — where to auto-discover the dictionary (default: current
  directory).
- `-Value` — one or more tokens to unmask (accepts pipeline input).
- `-Field` — restrict to `Subscription`, `ResourceGroup`, `ResourceId`,
  `ResourceName`, `Tag`. Search precedence is ResourceGroup → Subscription →
  ResourceId → ResourceName → Tag.
- `-All` — dump whole maps instead of specific values (defaults to Subscription
  + ResourceGroup when `-Field` is omitted).
- `-ResolveSubscriptionName` — turn subscription GUIDs into friendly names via
  `Get-AzSubscription` (requires the Az module and an authenticated session).

### Output shape

Each result is an object with `ObfuscatedValue`, `Type`
(`ResourceGroup` / `Subscription` / `ResourceId` / `ResourceName` / `Tag` /
`Lossy` / `NotFound`), `RealValue`, `RealResourceId`, and a `Note`.

---

## 6. Partial reveal for server-side ingestion (`Reveal-Obfuscation.ps1`)

`Unmask-Obfuscation.ps1` answers "what is this one token?". The companion
`Reveal-Obfuscation.ps1` answers a different need: **take an obfuscated report
ZIP and produce a NEW ZIP in which only the dimensions you choose are
un-obfuscated, leaving everything else masked**, so it can be ingested by the
same pipeline that ingests an obfuscated ZIP (the server reads the JSON
members) — but now with, say, real resource group and subscription names for
analytics.

It rewrites the selected dimensions' tokens back to their real values across
**every** text member of the ZIP (Inventory/Metrics JSON, Consumption CSV, the
HTML report) and re-packages the result with the **same filenames/structure**
the `-Obfuscate` run produced.

### Selectable dimensions

| Dimension | Revealed to | Default |
|---|---|---|
| `ResourceGroup` | real resource group name | **on** |
| `Subscription` | real subscription **display name** (from `SubscriptionNameMap`) | **on** |
| `Tag` | real tag value (from `TagMap`) | off — must be requested |

Everything else — Resource Ids, Resource Names, and (unless you add
`-Fields Tag`) tag values — **stays masked**. Tokens that are not part of a
selected dimension are left untouched, so selecting one dimension never bleeds
another.

### How it stays valid

Replacements are escaped to match each destination format so a revealed value
with special characters (e.g. a subscription display name containing `&` or a
comma, or a free-text tag value) cannot corrupt the output:
- **JSON** members → value is JSON-string-escaped.
- **CSV** members → revealed in-field then re-written through the CSV writer,
  so a value with a comma/quote is correctly quoted.
- **HTML** report → value is HTML-entity encoded (matching the report's own
  encoding).

### Usage

```powershell
# Default: reveal Resource Group + Subscription name, leave the rest masked
./Reveal-Obfuscation.ps1 -InputZip ./ResourcesReport_2026....zip -DictionaryPath ./ObfuscationDictionary_2026....json

# Also reveal tag values
./Reveal-Obfuscation.ps1 -InputZip ./report.zip -DictionaryPath ./dict.json -Fields ResourceGroup,Subscription,Tag

# Explicit output path
./Reveal-Obfuscation.ps1 -InputZip ./report.zip -DictionaryPath ./dict.json -OutputZip ./report_for_ingest.zip
```

### Parameters

- `-InputZip` — an obfuscated report ZIP from `-Obfuscate` (required).
- `-DictionaryPath` — the matching `ObfuscationDictionary_*.json`. If omitted,
  the newest match under `-SearchDirectory` is used.
- `-SearchDirectory` — where to auto-discover the dictionary (default: current
  directory).
- `-Fields` — dimensions to reveal: `ResourceGroup`, `Subscription`, `Tag`.
  Defaults to `ResourceGroup, Subscription`.
- `-OutputZip` — output path (default: the input name with a `_revealed`
  suffix).

> **The output ZIP contains the real values you chose to reveal.** It is no
> longer fully obfuscated — share it only with the party meant to ingest it. The
> dictionary and this script stay local. Older dictionaries that predate
> `SubscriptionNameMap` reveal the subscription **GUID** instead of the name
> (with a warning); those that predate tag obfuscation have no `TagMap`, so
> `-Fields Tag` is skipped with a warning.

---

## 7. Typical workflow

1. Run the inventory obfuscated:
   ```powershell
   ./ResourceInventory.ps1 -TenantID <tenant> -Obfuscate
   ```
2. Share **only** the report ZIP with AWS / your partner. Keep the dictionary
   and transcript local.
3. When a partner references an obfuscated token (e.g. in a finding), resolve it
   locally:
   ```powershell
   ./Unmask-Obfuscation.ps1 -Value 'prod_a1b2c3d4-...'
   ```
4. Delete the dictionary and transcript once the engagement no longer needs them.

---

## 8. Security notes

- The obfuscation is **one-way for the shared artifact**: the ZIP alone cannot
  be de-obfuscated. Reversal is only possible with the matching dictionary,
  which never leaves the customer environment.
- Because tokens are per-run GUIDs, leaking a ZIP does not expose identity even
  if an attacker has a *different* run's dictionary.
- Keep the dictionary and `Unmask-Obfuscation.ps1` output out of any public
  surface (commits, PRs, tickets, email). They map tokens straight back to real
  ARM resource IDs.
- A `Reveal-Obfuscation.ps1` output ZIP is **partially de-obfuscated** by design
  (it contains the dimensions you chose to reveal). Treat it like the dimensions
  it exposes — share it only with the intended ingestion party, never on a
  public surface.

*All identifiers in this document are illustrative placeholders, not real
Azure values.*
