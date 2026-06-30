# Obfuscation and Reveal

How the `-Obfuscate` feature in `ResourceInventory.ps1` protects customer data,
and how the local `Reveal-Obfuscation.ps1` helper turns an obfuscated report
back into an ingestible one with only the dimensions you choose un-masked.

> **TL;DR**
> - Run with `-Obfuscate` to produce a shareable report whose subscription,
>   resource group, resource ID, resource name, and tag **values** are replaced
>   with opaque `prod_`/`nonprod_` tokens.
> - The run also writes a **local** `ObfuscationDictionary_*.json` that maps
>   each token back to the real value. **The ZIP is safe to share; the
>   dictionary and the transcript are not.**
> - When you want analytics on real names, run `Reveal-Obfuscation.ps1`
>   **locally** to produce a new ingestible ZIP with only the dimensions you
>   select (Resource Group + Subscription by default) un-masked.

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
- Tag value token prefix is derived from the **tag value**.

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
  *name* in per-run lookup tables. Every resource in `Contoso Production`
  therefore shows the *same* subscription token, and every resource in `rg-app`
  shows the *same* RG token.
- **Resource ID** and **Resource Name** tokens are generated once per real
  resource ID during the build pass, so each resource keeps one stable ID token
  and one stable name token for the rest of the run.
- **Tag values** are looked up by the real value, so the same value always
  yields the same token across every resource that carries it.

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

That is how the reveal step derives the friendly values:
- Resource Group name is parsed from `/resourceGroups/<name>` in the ID.
- Subscription name is read from `SubscriptionNameMap` when present (offline).
  Older dictionaries that predate this map only carry the `/subscriptions/<guid>`
  GUID, so the reveal step falls back to the subscription **GUID**.
- Tag value is read directly from `TagMap`. Older dictionaries that predate tag
  obfuscation have no `TagMap` (it is optional, not part of the required-map
  check), so tag reveal is skipped.

> The `ResourceIdMap` and `ResourceNameMap` are not used by default — Resource
> Ids and names stay masked unless you explicitly add them to `-Fields`, since
> they are the bulk of the identifying surface.

### Handling rules — what is and isn't shareable

| Artifact | Shareable? |
|---|---|
| The report **ZIP** (obfuscated) | ✅ Yes — safe to share with AWS / partners |
| `ObfuscationDictionary_*.json` | ❌ **No — local only** |
| The PowerShell **transcript** | ❌ **No — local only** (captures account UPN + tenant/sub IDs) |
| A `Reveal-Obfuscation.ps1` output ZIP | ⚠️ Only with the party meant to ingest it — it contains the dimensions you chose to reveal |

Delete the dictionary and transcript when they are no longer needed.

---

## 5. Partial reveal for server-side ingestion (`Reveal-Obfuscation.ps1`)

The analytics pipeline is: **scan → obfuscated ZIP → reveal the dimensions you
want → re-ingest into the server → graphs / reports / UI.** `Reveal-Obfuscation.ps1`
is the step that turns a fully-masked ZIP into one your server can ingest with
real names in it.

It takes an obfuscated report ZIP + the matching dictionary and produces a NEW
ZIP in which **only the dimensions you choose are un-obfuscated**, leaving
everything else masked. The output keeps the **same filenames/structure** the
`-Obfuscate` run produced, so it ingests exactly like an obfuscated ZIP — the
server reads the same JSON members, just with (say) real resource group and
subscription names.

It rewrites the selected dimensions' tokens across **every** text member of the
ZIP (Inventory/Metrics JSON, Consumption CSV, the HTML report).

### Selectable dimensions

| Dimension | Revealed to | Default |
|---|---|---|
| `ResourceGroup` | real resource group name | **on** |
| `Subscription` | real subscription **display name** (from `SubscriptionNameMap`) | **on** |
| `Tag` | real tag value (from `TagMap`) | off — must be requested |
| `ResourceName` | real resource short name | off — must be requested |
| `ResourceId` | full real ARM resource Id | off — must be requested |

By default only `ResourceGroup` and `Subscription` are revealed; anything you do
not name in `-Fields` stays masked. Tokens that are not part of a selected
dimension are left untouched, so selecting one dimension never bleeds another.
Revealing `ResourceId` un-masks the full ARM path, which embeds the real
subscription GUID and resource group name for that resource.

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
- `-Fields` — dimensions to reveal: `ResourceGroup`, `Subscription`, `Tag`,
  `ResourceName`, `ResourceId`. Defaults to `ResourceGroup, Subscription`.
- `-OutputZip` — output path (default: the input name with a `_revealed`
  suffix).

> **The output ZIP contains the real values you chose to reveal.** It is no
> longer fully obfuscated — share it only with the party meant to ingest it. The
> dictionary and this script stay local. Older dictionaries that predate
> `SubscriptionNameMap` reveal the subscription **GUID** instead of the name
> (with a warning); those that predate tag obfuscation have no `TagMap`, so
> `-Fields Tag` is skipped with a warning.

---

## 6. Typical workflow

1. Run the inventory obfuscated:
   ```powershell
   ./ResourceInventory.ps1 -TenantID <tenant> -Obfuscate
   ```
2. Share **only** the obfuscated report ZIP with AWS / your partner. Keep the
   dictionary and transcript local.
3. When you want analytics on real names, reveal the dimensions you need into a
   fresh ingestible ZIP — locally, against the matching dictionary:
   ```powershell
   ./Reveal-Obfuscation.ps1 -InputZip ./ResourcesReport_2026....zip -DictionaryPath ./ObfuscationDictionary_2026....json
   ```
   Upload that `_revealed.zip` to the ingestion server the same way you would an
   obfuscated ZIP.
4. Delete the dictionary, transcript, and any revealed ZIP once the engagement
   no longer needs them.

---

## 7. Security notes

- The obfuscation is **one-way for the shared artifact**: the ZIP alone cannot
  be de-obfuscated. Reversal is only possible with the matching dictionary,
  which never leaves the customer environment.
- Because tokens are per-run GUIDs, leaking a ZIP does not expose identity even
  if an attacker has a *different* run's dictionary.
- Keep the dictionary out of any public surface (commits, PRs, tickets, email).
  It maps tokens straight back to real ARM resource IDs.
- A `Reveal-Obfuscation.ps1` output ZIP is **partially de-obfuscated** by design
  (it contains the dimensions you chose to reveal). Treat it like the dimensions
  it exposes — share it only with the intended ingestion party, never on a
  public surface.

*All identifiers in this document are illustrative placeholders, not real
Azure values.*
