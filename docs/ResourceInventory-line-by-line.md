# ResourceInventory.ps1 - A Line by Line Walkthrough

This document walks through `ResourceInventory.ps1` from the first line to the last, in plain English.
It is a teaching document, not a specification: the goal is that you can read it top to bottom and afterwards understand what every part of the script actually does.

## How to read this document

Each section covers one region of the script and follows the same shape.

1. A heading that names the region and gives its line numbers in the real file.
2. The code itself, copied across so you do not have to switch windows.
3. A table or short prose explaining what each line does and, where it matters, why it is written that way.

Two conventions to be aware of:

- The script is roughly 40 percent comments, and some of those comment blocks run to 20 lines.
  Copying every one of them verbatim would double the length of this document for no benefit.
  So where a comment block is longer than about four lines, it is replaced in the copied code with a placeholder like `# [long comment: why we reject unknown args]` and the substance of that comment is explained in the table underneath instead.
  Every line of *executable* code is copied verbatim.
- Line numbers refer to `ResourceInventory.ps1` as of the version this document was written against (2,854 lines).
  If the file has been edited since, treat the line numbers as approximate and the section headings as authoritative.

## What this script is, in one paragraph

`ResourceInventory.ps1` inventories the Azure resources in **one** subscription (or one resource group), optionally collects performance metrics and billing data for them, optionally masks every identifying value, and packages the whole lot into a single zip file containing a self contained HTML report plus machine readable JSON and CSV.
It is the engine.
The multi subscription wrappers (`Run-AllSubscriptions.ps1` and `Run-AllSubscriptions.Stream.ps1`) do nothing more than call this script once per subscription and then aggregate what it produced.

## The shape of a run

```
                    ┌──────────────────────────────────────────┐
                    │  1. CmdletBinding + parameter block      │  lines 1-111
                    │     Binder rejects typos, load helper    │
                    │     files, set error preferences         │
                    └────────────────────┬─────────────────────┘
                                         │
                    ┌────────────────────▼─────────────────────┐
                    │  2. Variables()                          │  lines 115-154
                    │     Create the empty globals and the     │
                    │     six obfuscation dictionaries         │
                    └────────────────────┬─────────────────────┘
                                         │
                    ┌────────────────────▼─────────────────────┐
                    │  3. RunInventorySetup()                  │  lines 156-966
                    │     version check, Az module check,      │
                    │     platform detect, LOGIN,              │
                    │     Resource Graph discovery,            │
                    │     mint obfuscation tokens              │
                    └────────────────────┬─────────────────────┘
                                         │
                    ┌────────────────────▼─────────────────────┐
                    │  4. ExecuteInventoryProcessing()         │  lines 968-2200
                    │     build file paths, run the metrics    │
                    │     extension, fan out the ~60 service   │
                    │     collectors, pull consumption data    │
                    └────────────────────┬─────────────────────┘
                                         │
                    ┌────────────────────▼─────────────────────┐
                    │  5. FinalizeOutputs()                    │  lines 2202-2249
                    │     render the HTML report               │
                    └────────────────────┬─────────────────────┘
                                         │
                    ┌────────────────────▼─────────────────────┐
                    │  6. Script body / packaging              │  lines 2251-2854
                    │     transcript, call 1-5 in order,       │
                    │     write JSON, decide what goes in the  │
                    │     zip, verify the zip, print summary   │
                    └──────────────────────────────────────────┘
```

The important thing about that diagram is that steps 1 to 5 are only **definitions**.
Nothing runs until the script body at line 2274 starts calling them in order.
PowerShell reads the whole file, registers the functions, and only then executes the top level statements.

## Map of every function in the file

| Line | Name | Nested inside | What it is for |
|---|---|---|---|
| 115 | `Variables` | (top level) | Creates every `$Global:` variable the rest of the run reads |
| 156 | `RunInventorySetup` | (top level) | Everything that has to happen before resources can be collected |
| 158 | `CheckVersion` | `RunInventorySetup` | Compare local version against GitHub, warn only |
| 227 | `CheckCliRequirements` | `RunInventorySetup` | Verify and import the five Az submodules |
| 341 | `CheckPowerShell` | `RunInventorySetup` | Detect platform, build the output folder path |
| 436 | `LoginSession` | `RunInventorySetup` | All authentication paths |
| 619 | `GetSubscriptionsData` | `RunInventorySetup` | Create the report folder, mark session initialised |
| 649 | `ResourceInventoryLoop` | `RunInventorySetup` | Page through Resource Graph for normal resources |
| 746 | `ResourceInventoryAvd` | `RunInventorySetup` | Page through Resource Graph for AVD resources |
| 968 | `ExecuteInventoryProcessing` | (top level) | Turn raw resources into structured inventory |
| 970 | `InitializeInventoryProcessing` | `ExecuteInventoryProcessing` | Compute every output file path |
| 1037 | `Test-DataPlaneAuthReady` | `ExecuteInventoryProcessing` | Prove we still have a usable token before a phase |
| 1111 | `CreateMetricsJob` | `ExecuteInventoryProcessing` | Launch the metrics extension in a runspace |
| 1187 | `ProcessMetricsResult` | `ExecuteInventoryProcessing` | Wait for and collect the metrics runspace |
| 1226 | `CreateResourceJobs` | `ExecuteInventoryProcessing` | Run all the `Services/*` collectors |
| 1540 | `ProcessResourceResult` | `ExecuteInventoryProcessing` | Merge collector output into the inventory object |
| 1558 | `GetResourceConsumption` | `ExecuteInventoryProcessing` | Pull billing / usage data |
| 2202 | `FinalizeOutputs` | (top level) | Render the report |
| 2248 | `ProcessSummary` | `FinalizeOutputs` | Call `Extension/Summary.ps1` |

---

# Part 1: `[CmdletBinding()]` and the parameter block (lines 1-53)

This is the public interface of the script.
Everything an operator can control arrives here.

```powershell
# [long comment: why [CmdletBinding()] is here, and why there is deliberately
#  no [switch]$Debug in the param block below]
[CmdletBinding()]
param ($TenantID,
    $Appid,
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$', ErrorMessage = 'Invalid SubscriptionID; must be a GUID')]
    [string]$SubscriptionID,
    [securestring]$Secret,
    [ValidatePattern('^[A-Za-z0-9._()-]{1,90}$', ErrorMessage = 'Invalid resource group name; must match ^[A-Za-z0-9._()-]{1,90}$')]
    [string]$ResourceGroup,
    [string[]]$Service,
    [string]$ObfuscationDictionary,
    [switch]$SkipMetrics,
    [switch]$SkipConsumption,
    [switch]$DeviceLogin,
    [switch]$Obfuscate,
    [switch]$RunAllSubs,
    # [long comment: -UseMetricsBatch is experimental, default OFF]
    [switch]$UseMetricsBatch,
    # [long comment: the metric volume controls and how they interact]
    [switch]$IncludeStorageMetrics,

    [switch]$SkipDiskMetrics,
    [ValidateSet(0, 5, 15, 30, 60)][int]$MetricsIntervalMinutes = 0,
    $ConcurrencyLimit = 6,
    $MetricsLookbackDays = 31,
    $ReportName = 'ResourcesReport',
    $OutputDirectory)
```

## Line by line

| Line | Code | What it does |
|---|---|---|
| 1-15 | `# [long comment]` | Records why the script is an advanced script and why it must **not** declare its own `Debug`. Both points are explained in full just below this table. |
| 16 | `[CmdletBinding()]` | Makes this an **advanced** script. The single most consequential line in the parameter block: it is what makes the parameter binder reject unrecognised arguments, and it also provides `-?` help and the common parameters for free. |
| 17 | `param ($TenantID,` | Opens the parameter block. It must be the first executable statement in the file, and `[CmdletBinding()]` is allowed to sit immediately above it. `$TenantID` is untyped, so PowerShell will accept anything and treat it as a string. It is the Entra ID (Azure AD) directory GUID to authenticate against. |
| 18 | `$Appid,` | The application (client) ID of a service principal, used for unattended login. Untyped for the same reason. |
| 19 | `[ValidatePattern(...)]` | An attribute attached to the parameter *below* it. PowerShell refuses to start the script at all if the supplied value does not match the regex. The regex is the canonical GUID shape: 8 hex, dash, 4 hex, dash, 4 hex, dash, 4 hex, dash, 12 hex. `ErrorMessage` replaces PowerShell's unreadable default validation error with a sentence a human can act on. |
| 20 | `[string]$SubscriptionID,` | Which single subscription to inventory. Typed `[string]` so the validation attribute has something predictable to test. If omitted, the script inventories everything the identity can see. |
| 21 | `[securestring]$Secret,` | The service principal secret. Typed `[securestring]` deliberately: a `SecureString` is not visible in the process's plain memory in the same way a `String` is, does not land in the PowerShell command history in cleartext, and can be handed straight to a `PSCredential` later without ever being converted back to text. |
| 22 | `[ValidatePattern(...)]` | Same idea as line 19, but for the resource group name. The pattern `^[A-Za-z0-9._()-]{1,90}$` is Azure's own rule for resource group names: letters, digits, dot, underscore, parentheses, hyphen, between 1 and 90 characters. |
| 23 | `[string]$ResourceGroup,` | Narrow the inventory to a single resource group. Only legal together with `$SubscriptionID`, which is enforced later at line 652. |
| 24 | `[string[]]$Service,` | An **array** of strings (note the `[]`). Each entry names a service collector to run, so you can inventory just virtual machines instead of all 60 resource types. An empty or absent value means "run all of them". |
| 25 | `[string]$ObfuscationDictionary,` | Path to a dictionary file saved by a previous run. Supplying it makes this run reuse the same masked tokens as that run, which is what allows two runs to be merged. Covered in detail in Part 3. |
| 26 | `[switch]$SkipMetrics,` | A `[switch]` is a boolean flag: present means true, absent means false. This one skips the whole Azure Monitor metrics phase, which is the slowest and most API hungry part of a run. |
| 27 | `[switch]$SkipConsumption,` | Skip the billing / cost phase. |
| 28 | `[switch]$DeviceLogin,` | Authenticate by showing a code to type into a browser on another machine, instead of opening a browser locally. This is what you use over SSH or in a container. |
| 29 | `[switch]$Obfuscate,` | The big one. Masks every subscription name, resource group name, resource name and resource ID in the output. Explained fully in Part 3. |
| 30 | `[switch]$RunAllSubs,` | Set by the wrapper scripts, never by a human. It tells this script "you are one of many invocations in a single process, so do not print the banner again, do not disconnect the login, and do not re-run one time setup". |
| 31-37 | `# [long comment]` then `[switch]$UseMetricsBatch,` | Opt in to collecting VM CPU and memory through Azure Monitor's `metrics:getBatch` API, which fetches many resources per HTTP call instead of one call per resource and metric. It is experimental and off by default. The comment records that it falls back to the slow path on any failure, so no data is lost if the batch API misbehaves. |
| 38-48 | `# [long comment]` then the two switches | Volume controls for the metrics phase. The comment records the interaction rules, which matter because they are not obvious: `-IncludeStorageMetrics` opts **in** to the storage account `UsedCapacity` metric (it is off by default because it costs one API call per storage account, which dominates the bill on a large estate); `-SkipDiskMetrics` drops managed disk I/O metrics. There is no public `-SkipStorageMetrics` switch - the storage metric is opt-in, so a skip switch would be redundant. `Functions/RunAllSubscriptions.Functions.ps1` keeps an INTERNAL `-SkipStorageMetrics` parameter on the plan-weight helpers, fed the derived effective decision (`-not $IncludeStorageMetrics`); do not re-add a public one. |
| 49 | `[ValidateSet(0, 5, 15, 30, 60)][int]$MetricsIntervalMinutes = 0,` | Two attributes plus a default. `[ValidateSet]` restricts the value to exactly those five numbers and gives a helpful error listing them if you pass anything else. `= 0` is the default and means "use each resource type's native grain", which is 15 minutes for VMs, 30 for SQL, 60 for the open source databases. |
| 50 | `$ConcurrencyLimit = 6,` | How many service collectors run in parallel. Six is a conservative default chosen to stay under Azure's API throttling thresholds. |
| 51 | `$MetricsLookbackDays = 31,` | How far back to pull metrics. 31 days covers a full billing month. |
| 52 | `$ReportName = 'ResourcesReport',` | The stem used in every output filename. Changing it changes the zip name, the HTML name, the JSON names, and the glob patterns downstream still match because they wildcard the timestamp, not the stem. |
| 53 | `$OutputDirectory)` | Where to write the report. If omitted, a platform specific default is computed in `CheckPowerShell` (lines 406-413). The closing parenthesis ends the parameter block. |

## The `-Debug` parameter that is deliberately absent

`-Debug` is a documented, supported flag on this script, and it is used throughout the project's own docs. Yet there is no `$Debug` in the parameter block. That is not an oversight.

`-Debug` is one of PowerShell's **common parameters**, which every advanced script gets automatically. Declaring it yourself *as well* is not merely redundant, it is fatal:

```
MetadataError: A parameter with the name 'Debug' was defined multiple times for the command.
```

The script does not start at all. So an advanced script and a hand declared `-Debug` are mutually exclusive, and this file resolves that by keeping `[CmdletBinding()]` and using the built-in one.

The built-in is equivalent for this script's purposes:

| | Hand declared `[switch]$Debug` | Built-in common `-Debug` |
|---|---|---|
| Tested with | `$Debug.IsPresent` | `$PSBoundParameters.ContainsKey('Debug')` **and** its value |
| Effect on `$DebugPreference` | had to be set manually | binder sets it to `Continue` automatically |
| `Write-Debug` output | appears | appears |
| Rejects `-Obfusacte` | no | **yes** |

Two consequences worth knowing:

- The public flag name is unchanged. `-Debug` still works, `Run-AllSubscriptions.ps1`'s existing passthrough of it still works, and no documentation needed rewording.
- Because this is now an advanced script, the other common parameters (`-Verbose`, `-ErrorAction`, `-WarningAction`, `-ErrorVariable` and the rest) are accepted too. `-ErrorAction` is handled explicitly at line 106; the others have no effect because nothing in the script writes to those streams in a way they govern.

A note on a hazard that does **not** apply here, because it is widely believed to: PowerShell's built-in `-Debug` is often described as setting `$DebugPreference` to `Inquire`, which would make every `Write-Debug` prompt and therefore hang any non interactive run. On PowerShell 7 that is not what happens for a script. It is set to `Continue`, verified across all four invocation paths that matter here: `pwsh -File`, `&` from an advanced wrapper (which is how the wrappers call this script), `&` from `-Command`, and inside an advanced function. `Write-Debug` prints and does not prompt.

## Why some parameters are typed and others are not

It looks inconsistent, and there is a reason.

| Style | Parameters | Effect |
|---|---|---|
| Untyped, e.g. `$TenantID` | `$TenantID`, `$Appid`, `$ConcurrencyLimit`, `$MetricsLookbackDays`, `$ReportName`, `$OutputDirectory` | PowerShell accepts anything and does no conversion. Legacy style, and harmless for values that are only ever interpolated into strings. |
| Typed with validation | `$SubscriptionID`, `$ResourceGroup`, `$MetricsIntervalMinutes` | These are interpolated straight into Resource Graph KQL query strings, so a malformed value is a correctness and injection concern. Validating at the boundary means the query builder further down can trust them. |
| `[switch]` | the nine declared flags | Presence based booleans. Always tested with `.IsPresent` in this script rather than as a plain truthy value. `-Debug` is a tenth flag in practice but comes from `[CmdletBinding()]`, so it is tested differently. |

---

# Part 2: Guards and bootstrap (lines 54-111)

Before any Azure work happens, the script protects itself against four things: typos in flags, contradictory flags, missing helper files, and the wrong error handling mode.
Only three of them need code; the first is handled by the parameter binder.

## 2.1 How unrecognised arguments are rejected (the binder, line 16)

There is no code in this section, and that is the point.
Rejecting a mistyped flag is done by `[CmdletBinding()]` on line 16, not by anything written by hand.

### The problem it solves

PowerShell has two kinds of script.

| Kind | How you get it | What happens to an unknown argument |
|---|---|---|
| Advanced | `[CmdletBinding()]` or any `[Parameter()]` attribute | The binder throws an error naming the bad parameter |
| Simple | Neither of those | PowerShell **silently** collects unknown arguments into the automatic `$args` array and carries on |

Note that `[ValidatePattern]` and `[ValidateSet]` on lines 19, 22 and 49 do **not** promote a script to advanced.
Only `[CmdletBinding()]` or `[Parameter()]` do that.

The danger of being simple is specific and severe.
Type `-Obfusacte` instead of `-Obfuscate` and PowerShell drops the token into `$args`, `$Obfuscate.IsPresent` stays false, and the script produces a complete report containing every real customer name while you believe it was masked.

### What you get now

```
$ pwsh ./ResourceInventory.ps1 -Obfusacte
ResourceInventory.ps1: A parameter cannot be found that matches parameter name 'Obfusacte'.
$ echo $?
1
```

| Behaviour | Source |
|---|---|
| Typo rejected before anything runs | the binder |
| Non zero exit code (1) | the binder |
| Failure visible to the wrapper | the binding error is **terminating**, so the wrapper's `try`/`catch` around its `&` call catches it and marks the subscription failed |
| `-?` prints the parameter list, exit 0 | the binder |
| Bad `-SubscriptionID` still caught | `[ValidatePattern]`, also exit 1 |

The wrapper detail is worth spelling out, because the old hand written guard used an explicit `exit 1` and the binder does not.
Via `&`, a binding failure leaves `$LASTEXITCODE` untouched rather than setting it to 1, so the wrapper's `$LASTEXITCODE` check alone would not notice.
It does not need to: the binding error is a terminating error that propagates out of the `&` and is caught by the `try`/`catch` the wrapper already wraps each invocation in. Failure detection is preserved.

### What used to be here

Roughly 47 lines re-implementing all of the above by hand: a check on `$args.Count`, a list of four help flag spellings, a `Get-Help` call with `WildcardPattern]::Escape` applied to `$PSCommandPath`, three explanatory `Write-Host` lines and two `exit` calls.
It existed only because the script used to declare its own `[switch]$Debug`, which forced it to stay simple.
Dropping that declaration in favour of the built in `-Debug` (see Part 1) let the binder take the job back, and the whole block was deleted.

The lesson generalises: before hand rolling a guard, check whether the platform will do it for you and what is actually blocking that.

## 2.2 Contradictory storage flags - and why that code is gone

This section used to document a `Write-Warning` that fired when both `-IncludeStorageMetrics` and `-SkipStorageMetrics` were passed, picking `-SkipStorageMetrics` as the documented winner.

**Neither the switch nor the warning exists any more**, so do not go looking for them.
`-SkipStorageMetrics` has been removed from every entry point.

The reason is worth keeping, because it is a better outcome than the warning was.
The storage-account `UsedCapacity` metric became **opt-in** via `-IncludeStorageMetrics`, since it costs one API call per storage account and dominates the metrics bill on a large estate.
Once the metric is off by default, a switch whose only job is to turn it off has nothing left to do - and two flags that can contradict each other stop existing rather than needing a documented winner.

An INTERNAL `SkipStorageMetrics` parameter does survive, on the plan-weight helpers in `Functions/RunAllSubscriptions.Functions.ps1` (`Get-PlanWeightKql` / `Get-PlanSubscriptionWeights`).
It is fed the derived effective decision (`-not $IncludeStorageMetrics`) rather than an operator flag.
That file says explicitly not to re-add a public one.

The generalisable lesson is the same shape as 2.1: the cleanest way to resolve a contradiction between two options is often to remove one of them, not to arbitrate between them.

## 2.3 Loading the helper files (lines 62-85)

```powershell
# [long comment: dot-sourced, NOT invoked via &, so the functions land in this
#  script's scope; fail loud rather than a confusing "command not found" later]
$FunctionsFile = Join-Path $PSScriptRoot 'Functions/ResourceInventory.Functions.ps1'
if (-not (Test-Path -Path $FunctionsFile -PathType Leaf))
{
    Write-Host "ERROR: Required functions file not found: $FunctionsFile" -ForegroundColor Red
    Write-Host "Ensure the 'Functions' folder ships alongside this script." -ForegroundColor Yellow
    exit 1
}
. $FunctionsFile

# Shared cross-cutting helpers (Write-RdaProgress). Same dot-source pattern.
$CommonFunctionsFile = Join-Path $PSScriptRoot 'Functions/Common.Functions.ps1'
if (-not (Test-Path -Path $CommonFunctionsFile -PathType Leaf))
{
    Write-Host "ERROR: Required functions file not found: $CommonFunctionsFile" -ForegroundColor Red
    Write-Host "Ensure the 'Functions' folder ships alongside this script." -ForegroundColor Yellow
    exit 1
}
. $CommonFunctionsFile
```

### Line by line

| Line | Code | What it does |
|---|---|---|
| 68 | `Join-Path $PSScriptRoot 'Functions/...'` | `$PSScriptRoot` is the directory containing this script, resolved at runtime. Using it instead of a relative path means the script works no matter what the caller's current directory is. `Join-Path` inserts the correct separator for the platform, so this is one of the places the script stays portable between Windows and Linux or macOS. |
| 69 | `if (-not (Test-Path -Path $FunctionsFile -PathType Leaf))` | `-PathType Leaf` means "must be a file, not a directory". Without it, a directory that happened to share the name would pass the check. |
| 71-73 | the error and `exit 1` | Fail immediately with the exact path that was looked for. The alternative is far worse: the script would continue, then die a few lines later on `Write-Log` with "the term Write-Log is not recognized", which tells the operator nothing about the real cause. |
| 75 | `. $FunctionsFile` | The leading dot is the **dot source** operator. This is the single most important character in the block. |
| 77-85 | the same pattern again | Loads `Functions/Common.Functions.ps1`, which provides the cross cutting helpers `Write-Log` and `Write-RdaProgress`. |

### Dot sourcing versus calling

This distinction trips up almost everyone new to PowerShell.

| Syntax | Name | What happens to functions defined in the file |
|---|---|---|
| `. $File` | Dot source | The file runs **inside the current scope**. Its functions and variables persist afterwards and are callable from here. |
| `& $File` | Call operator | The file runs in a **child scope**. Its functions vanish the moment it finishes. |

Since the entire point is to obtain `Write-Log`, `GetLocalVersion`, `Invoke-AzGraphQuerySafe` and friends, this must be dot sourcing.
Using `&` here would appear to work and then fail on the very next function call.

## 2.4 Error handling mode (lines 87-111)

```powershell
# [long comment: -Debug is the CmdletBinding COMMON parameter. When passed, the
#  binder has ALREADY set $DebugPreference to 'Continue' for this scope, so the
#  old explicit assignment was redundant and was removed.]
$DebugMode = ($PSBoundParameters.ContainsKey('Debug') -and [bool]$PSBoundParameters['Debug'])

# [long comment: production runs deliberately swallow the long tail of trivial
#  per-resource errors so a partial-but-useful inventory still completes. Do NOT
#  "fix" this default - the high-value phases each opt into terminating behavior
#  with their own -ErrorAction Stop + try/catch.
#
#  Becoming an advanced script means -ErrorAction is now ACCEPTED by the binder,
#  which sets $ErrorActionPreference for this scope before the body runs. Honor
#  that when the caller passed it explicitly instead of unconditionally
#  clobbering it, which would accept the flag and silently ignore it.]
if (-not $PSBoundParameters.ContainsKey('ErrorAction'))
{
    $ErrorActionPreference = if ($DebugMode) { 'Continue' } else { 'SilentlyContinue' }
}

Write-Debug ('Debugging Mode: On. ErrorActionPreference is "{0}", every error will be presented.' -f $ErrorActionPreference)
```

| Line | Code | What it does |
|---|---|---|
| the `$DebugMode` assignment | `$DebugMode = ($PSBoundParameters.ContainsKey('Debug') -and [bool]$PSBoundParameters['Debug'])` | `$PSBoundParameters` is an automatic dictionary of the parameters the caller actually supplied, so it is the only way to test for a common parameter. But `ContainsKey` alone is **not** sufficient: `-Debug:$false` is a *bound* parameter whose value is `$false`, so `ContainsKey` returns `$true` and an explicit opt-**out** was read as an opt-**in** - which flipped `$ErrorActionPreference` to `Continue` for the whole run and turned the deliberately-swallowed long tail of per-resource errors into console noise. The **value** has to be read, not just its presence. This also matches the two forwarding sites in `Run-AllSubscriptions.ps1` and `Run-AllSubscriptions.Stream.ps1`, which already use `[bool]` on the value. Note there is no `$DebugPreference = 'Continue'` here any more: the binder has already done it. |
| 106 | `if (-not $PSBoundParameters.ContainsKey('ErrorAction'))` | The guard that keeps `-ErrorAction` honest. Because the script is advanced, `-ErrorAction` is now accepted, and the binder sets `$ErrorActionPreference` for this scope before the body runs. Without this test the next line would overwrite it, so the flag would be accepted and silently ignored. |
| 108 | `$ErrorActionPreference = if ($DebugMode) { 'Continue' } else { 'SilentlyContinue' }` | The default when no `-ErrorAction` was given. This one line decides the whole character of the run. |
| 111 | `Write-Debug (...)` | Prints only when `-Debug` was passed, because of what the binder did to `$DebugPreference`. The message interpolates the resulting preference rather than hard coding `"Continue"`, so it stays truthful if `-ErrorAction` overrode it. |

### Why `SilentlyContinue` is deliberate here

This looks like the classic PowerShell anti pattern of hiding all your errors.
In this script it is a considered decision, and it is documented in the project's own rules as something not to "fix".

The reasoning: a single run touches tens of thousands of resources across roughly 60 collectors.
A meaningful number of individual resources will always fail to yield one field, because of a permission gap on one resource group, a resource mid deletion, a preview API shape, or a property that is null on that particular SKU.
With `Stop` or `Continue`, one such resource aborts or floods the run.
An inventory that covers 99.9 percent of an estate is enormously more useful than no inventory at all, so the trivial long tail is suppressed by default.

The important consequence, and the thing to internalise, is what this does **not** mean.
It does not mean the script hides failure of the things that matter.
The high value phases (resource discovery, metrics, consumption, packaging) each wrap their calls in `try`/`catch` with an explicit `-ErrorAction Stop`, so those failures are caught, logged loudly, and reported in the run summary.
There is a worked example of exactly this at line 2466, and the discovery `catch` at line 799 exists specifically because `SilentlyContinue` would otherwise have let a failed Resource Graph page pass unnoticed.

```
                     ┌─────────────────────────────────────┐
                     │  $ErrorActionPreference =           │
                     │  'SilentlyContinue'  (the default)  │
                     └──────────────┬──────────────────────┘
                                    │
              ┌─────────────────────┴──────────────────────┐
              │                                            │
    ┌─────────▼──────────┐                    ┌────────────▼─────────────┐
    │ Long tail of small │                    │ High value phases        │
    │ per-resource errors│                    │ discovery, metrics,      │
    │                    │                    │ consumption, packaging   │
    │ Swallowed silently │                    │                          │
    │ so the run finishes│                    │ Wrapped in try/catch     │
    │                    │                    │ with -ErrorAction Stop.  │
    │ INTENTIONAL        │                    │ Logged loud + surfaced   │
    └────────────────────┘                    │ in the run summary.      │
                                              └──────────────────────────┘
```

---

# Part 3a: `Variables()` (lines 115-154)

This function does one job: create every `$Global:` variable the rest of the run will read, so nothing later has to guess whether a variable exists.

```powershell
function Variables
{
    $Global:ResourceContainers = @()
    $Global:Resources = @()
    $Global:Subscriptions = ''
    $Global:ReportName = $ReportName
    $Global:Version = GetLocalVersion

    $Global:ResourceIdDictionary = $null
    $Global:ResourceNameDictionary = $null
    $Global:ResourceSubscriptionDictionary = $null
    $Global:ResourceResourceGroupDictionary = $null
    # [long comment: tag VALUES are tokenised deterministically; tag KEYS kept verbatim]
    $Global:TagValueDictionary = $null
    # [long comment: free-text/identity fields used to be dropped and were
    #  unrecoverable; tokenising them keeps them out of the shared report while
    #  letting Reveal restore them locally via FreeTextMap]
    $Global:FreeTextDictionary = $null

    if ($Obfuscate.IsPresent)
    {
        $Global:ResourceIdDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Global:ResourceNameDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Global:ResourceSubscriptionDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Global:ResourceResourceGroupDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Global:TagValueDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Global:FreeTextDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
    }

    $Global:RawRepo = 'https://raw.githubusercontent.com/awslabs/resource-discovery-for-azure/main'
    $Global:TableStyle = "Medium15"
}
```

## Line by line

| Line | Code | What it does |
|---|---|---|
| 117 | `$Global:ResourceContainers = @()` | An empty array for subscription and resource group container objects. `@()` is the empty array literal. |
| 118 | `$Global:Resources = @()` | The single most important variable in the script. Every resource returned by Resource Graph is appended here, and every collector reads from it. |
| 119 | `$Global:Subscriptions = ''` | Initialised to an empty **string**, not an empty array, which is a legacy quirk. It is overwritten with a real array by `LoginSession` before anything reads it. |
| 120 | `$Global:ReportName = $ReportName` | Copies the parameter into a global so nested functions can see it. Parameters are scoped to the script body; the nested collector calls need a global. |
| 121 | `$Global:Version = GetLocalVersion` | Calls a helper from the dot sourced functions file, which reads `Version.json` from disk and returns a `Major.Minor.Build` string. |
| 123-126 | four `$null` assignments | Declares the four identifier dictionaries as null. On a non obfuscated run they **stay** null, and that null is itself meaningful: collectors test for it to decide whether to mask. |
| 131 | `$Global:TagValueDictionary = $null` | Same, for tag values. |
| 138 | `$Global:FreeTextDictionary = $null` | Same, for free text fields such as descriptions, `CreatedBy`, friendly names, container image names and role names. |
| 140 | `if ($Obfuscate.IsPresent)` | Only build real dictionaries when masking was requested. |
| 140-145 | six `New-Object 'System.Collections.Generic.Dictionary[string,string]'` | Creates strongly typed .NET dictionaries rather than PowerShell hashtables. |
| 150 | `$Global:RawRepo = '...'` | The raw GitHub URL used by `CheckVersion` to fetch the published `Version.json`. |
| 151 | `$Global:TableStyle = "Medium15"` | A leftover from when the report was an Excel workbook. Harmless, still passed around, no longer used for rendering. |

## Why `Dictionary[string,string]` and not a hashtable

| Property | PowerShell `@{}` hashtable | `Dictionary[string,string]` |
|---|---|---|
| Key type | anything | strings only, enforced |
| Missing key lookup | returns `$null` | returns `$null` **under PowerShell**, see below |
| Case sensitivity | case *insensitive* by default | whatever comparer is passed in |

Two claims this section used to make were wrong, and both were settled by measurement rather than reasoning.

**The indexer does not throw here.**
A `Dictionary[string,string]` raises `KeyNotFoundException` on a missing key in C#, but PowerShell's indexer adapter swallows it and yields `$null`.
So an unguarded read does not abort the obfuscation pass; it quietly produces a **null masked value**, which is harder to notice and therefore worse.
Every read is still guarded with `.ContainsKey(...)` first and that guard is still exactly right - only the stated reason changed.
You can see it applied where a hand-edited seed dictionary might hold an ID in the resource-ID map but not in the name map.
`Extension/Metrics.ps1` carries the same guard in `Protect-RdaMetrics`, through a `Get-RdaMappedValue` helper that falls back per field to the `'obfuscated'` sentinel.

**The four identifier dictionaries are case-INSENSITIVE**, constructed with `[System.StringComparer]::OrdinalIgnoreCase`.
ARM resource IDs, subscription IDs and resource-group names are case-insensitive identifiers by specification: Azure preserves the casing you created them with, but treats two spellings as the same resource.
A case-sensitive map therefore *missed* on a casing difference, and every consequence was silent - a cross-reference falling through to the `'obfuscated'` sentinel, a consumption row failing to join back to its inventory resource, or a dictionary seeded from a previous run ceasing to match.
This does not weaken determinism: a differently-cased write updates the existing entry rather than adding a second one, so one resource can never carry two tokens.
`TagValueDictionary` and `FreeTextDictionary` stay case-**sensitive** deliberately, because Azure tag values genuinely are - `Env=Prod` and `Env=prod` are two different values, and collapsing them would lose a real distinction in the estate.

## The six dictionaries

| Dictionary | Keyed by | Holds | Masked as |
|---|---|---|---|
| `ResourceIdDictionary` | real resource ID | masked resource ID | `prod_<guid>` or `nonprod_<guid>` |
| `ResourceNameDictionary` | real resource ID | masked resource name | `prod_<guid>`, sometimes with a type hint |
| `ResourceSubscriptionDictionary` | real resource ID | masked subscription | shared by every resource in that subscription |
| `ResourceResourceGroupDictionary` | real resource ID | masked resource group | shared by every resource in that group |
| `TagValueDictionary` | real tag **value** | masked token | tag keys are kept verbatim |
| `FreeTextDictionary` | real free text value | masked token | descriptions, `CreatedBy`, images, role names |

Note that the first four are all keyed by **resource ID**, even the subscription and resource group ones.
That is a deliberate design choice with a consequence that shows up later: because a subscription token is shared by thousands of resources, you cannot reconstruct the "real subscription name to token" mapping from an ID keyed dictionary alone.
That is precisely why the seeding logic at line 838 has to rebuild `$SubLookup` from a separate `SubscriptionNameMap` instead.

---

# Part 3b: `RunInventorySetup()` (lines 156-966)

This is the largest function in the file and it does everything that has to succeed before a single resource can be collected.
It contains seven nested functions plus an orchestration block at the end that calls them in order.

One idea runs through the whole function and is worth understanding before reading any of it: **session idempotency**.

## The `$Global:RdaSessionInitialized` pattern

Under `-RunAllSubs`, the wrapper calls this script once per subscription **inside the same PowerShell process**.
On a large tenant that is 125 invocations.
Some of the setup work is per subscription (each subscription needs its own output folder) but most of it is not: the version banner, the GitHub update check, the Az module import, the platform detection and the "authenticated as" line are all identical every time.

Running them 125 times means 125 network calls to GitHub, 125 module import checks, and a console full of repeated banners that buries the real output.

So the script uses two flags.

| Flag | Set at line | Guards |
|---|---|---|
| `$Global:RdaSessionInitialized` | 657, at the end of the first subscription's setup | The version check, platform detection, the subscription count line, the cloud environment banner, and the "already authenticated as" line |
| `$Global:AzPowerShellLoaded` | 331 on success, 339 on failure | The whole Az module check and import |

Because `Variables()` does not reset either flag, and because parallel streams are separate *processes* that each set their own, the pattern works for both the sequential and the parallel wrapper modes.
Note that `$Global:AzPowerShellLoaded` is deliberately set to `$false` on failure rather than left unset, so a failed load is retried on the next subscription instead of being permanently skipped.

## 3b.1 `CheckVersion()` (lines 158-225)

```powershell
    function CheckVersion()
    {
        # [long comment: idempotent per session; skip the banner and the GitHub
        #  round-trip on subscriptions 2..N of the same process]
        if ($Global:RdaSessionInitialized)
        {
            return
        }

        Write-Log -Message ('Checking Version') -Severity 'Info'
        Write-Log -Message ('Version: {0}' -f $Global:Version) -Severity 'Info'

        # [long comment: the version check is best-effort. On networks that block
        #  raw.githubusercontent.com this WebClient call raised SocketException and
        #  aborted the whole subscription before any inventory work began. See #18.]
        try
        {
            $VersionJson = (New-Object System.Net.WebClient).DownloadString($RawRepo + '/Version.json') | ConvertFrom-Json
        }
        catch
        {
            Write-Log -Message ("Could not reach {0}/Version.json to check for an update: {1}" -f $RawRepo, $_.Exception.Message) -Severity 'Warning'
            Write-Log -Message ('Continuing with local version {0}. If you are on a managed network, this is expected.' -f $Global:Version) -Severity 'Info'
            return
        }

        $VersionNumber = ('{0}.{1}.{2}' -f $VersionJson.MajorVersion, $VersionJson.MinorVersion, $VersionJson.BuildVersion)

        if ($VersionNumber -ne $Global:Version)
        {
            # [long comment: a version difference is informational, not fatal. The old
            #  behaviour (Error + Exit) blocked users slightly behind, and mis-fired for
            #  local builds AHEAD of upstream. Compare as semver so the note is truthful.]
            $LocalParsed = $null
            $UpstreamParsed = $null
            $HaveSemver = [version]::TryParse($Global:Version, [ref]$LocalParsed) -and `
                [version]::TryParse($VersionNumber, [ref]$UpstreamParsed)

            if ($HaveSemver -and $LocalParsed -lt $UpstreamParsed)
            {
                Write-Log -Message ('A newer version ({0}) is available; you are running {1}. Consider updating: https://github.com/awslabs/resource-discovery-for-azure' -f $VersionNumber, $Global:Version) -Severity 'Warning'
            }
            elseif ($HaveSemver -and $LocalParsed -gt $UpstreamParsed)
            {
                Write-Log -Message ('Running a local/pre-release version ({0}); latest published is {1}.' -f $Global:Version, $VersionNumber) -Severity 'Info'
            }
            else
            {
                Write-Log -Message ('Local version ({0}) differs from the latest published version ({1}).' -f $Global:Version, $VersionNumber) -Severity 'Warning'
            }
            # Continue the run regardless [...]
        }
    }
```

### Line by line

| Line | Code | What it does |
|---|---|---|
| 168 | `if ($Global:RdaSessionInitialized) { return }` | The idempotency guard described above. On subscription 2 and later this function does nothing at all. |
| 175-176 | two `Write-Log` calls | `Write-Log` comes from `Functions/Common.Functions.ps1`. It timestamps the message, colours it by severity, and mirrors errors into a separate error only log file. |
| 184 | `(New-Object System.Net.WebClient).DownloadString(...)` | Fetches the published `Version.json` straight from GitHub as a string. `WebClient` is the older .NET HTTP class; it is used here rather than `Invoke-RestMethod` for historical reasons. |
| 184 | `\| ConvertFrom-Json` | Parses that string into a PowerShell object with `MajorVersion`, `MinorVersion` and `BuildVersion` properties. |
| 186-191 | the `catch` | This whole `try`/`catch` exists because of a real reported bug. On a corporate network that blocks `raw.githubusercontent.com`, or in an air gapped environment, `DownloadString` throws `SocketException`. Without the catch, that exception aborted the subscription **before any inventory work started at all**, so a firewall rule silently cost the operator their entire run. The catch logs a warning that explicitly says "if you are on a managed network, this is expected" and then `return`s, continuing with the local version. |
| 193 | `$VersionNumber = ('{0}.{1}.{2}' -f ...)` | Reassembles the three separate JSON fields into a single `1.2.3` style string. |
| 195 | `if ($VersionNumber -ne $Global:Version)` | Plain string inequality, used only as a cheap "is there anything to say" test. The actual comparison happens below. |
| 204-208 | `[version]::TryParse($Global:Version, [ref]$LocalParsed)` | Converts both strings into .NET `Version` objects so they can be compared **numerically**. `TryParse` returns a boolean and writes the result into the `[ref]` variable rather than throwing on a malformed input. The backtick at the end of line 207 is PowerShell's line continuation character, joining lines 207 and 208 into one statement. |
| 210-221 | the three branch messages | This is why the semver parse was worth doing. String comparison can only say "different". Numeric comparison can say which direction, so the message is truthful in all three cases: behind (warn, suggest updating), ahead (informational, you are on a local or pre release build), or unparseable (neutral "differs"). |

### The design point worth taking away

The old behaviour of this function was `Write-Log Error` followed by `Exit` on **any** version mismatch.
That was wrong in three ways: it blocked users who were only slightly behind, it fired incorrectly for local development builds whose version is *ahead* of what is published, and it made an inventory run depend on GitHub being reachable.

Both failure paths in this function now choose "log a clear note and continue".
A version check must never gate the inventory.

## 3b.2 `CheckCliRequirements()` (lines 227-339)

```powershell
    function CheckCliRequirements()
    {
        # [long comment: idempotent per session via $Global:AzPowerShellLoaded;
        #  imported modules persist process-wide, so only load once. On a failed
        #  load the flag stays $false so the next subscription retries.]
        if ($Global:AzPowerShellLoaded)
        {
            return
        }

        # [long comment: resource discovery now uses the native Search-AzGraph, so
        #  the Azure CLI and its resource-graph extension are no longer prerequisites]
        Write-Log -Message ('Checking Azure PowerShell Module...') -Severity 'Info'

        # [long comment: this tool calls cmdlets from only five Az submodules, so it
        #  validates exactly those and does NOT require the ~80-submodule Az rollup.
        #  Checking the submodules rather than the Az umbrella is what lets a slim
        #  install pass - a slim install has no Az meta-module at all.]
        $RequiredAzSubModules = @('Az.Accounts', 'Az.Compute', 'Az.Monitor', 'Az.Billing', 'Az.ResourceGraph')

        $MissingAzSubModules = @($RequiredAzSubModules | Where-Object { $null -eq (Get-Module -Name $_ -ListAvailable -ErrorAction SilentlyContinue | Select-Object -First 1) })

        if ($MissingAzSubModules.Count -eq 0)
        {
            $VarAzPs = Get-Module -Name Az.Accounts -ListAvailable -ErrorAction SilentlyContinue | Select-Object -First 1
            Write-Log -Message ('Azure PowerShell modules present (Az.Accounts {0}); required: {1}' -f $VarAzPs.Version, ($RequiredAzSubModules -join ', ')) -Severity 'Success'
        }
        else
        {
            # [long comment: deliberate behaviour change - do NOT Install-Module from
            #  inside this script. A real field run produced a half-installed Az module
            #  (manifests present, bundled MSAL/Azure.Core assemblies missing) and then
            #  ran for nearly an hour producing ZERO consumption data.]
            Write-Log -Message ('Required Azure PowerShell module(s) not found: {0}' -f ($MissingAzSubModules -join ', ')) -Severity 'Error'
            Write-Log -Message ('This tool needs only these Az submodules. Install them manually before re-running. From an elevated PowerShell 7 prompt:') -Severity 'Error'
            Write-Log -Message ('  Install-Module -Name {0} -Repository PSGallery -Force -AllowClobber -SkipPublisherCheck' -f ($RequiredAzSubModules -join ',')) -Severity 'Error'
            Write-Log -Message ('Or install the full rollup (larger, slower first import): Install-Module -Name Az -Repository PSGallery -Force -AllowClobber -SkipPublisherCheck') -Severity 'Error'
            Write-Log -Message ('Or in Cloud Shell, the Az module is already preinstalled - if it is missing your shell environment is broken.') -Severity 'Error'
            throw ('Required Azure PowerShell submodule(s) not found: {0}. See log above for installation instructions.' -f ($MissingAzSubModules -join ', '))
        }

        # [long comment: import ONLY the five submodules, not the Az rollup. Importing
        #  Az pulls ~80 submodules and stalls 20-40s with no output, which looks like a
        #  hang. This import also doubles as the broken-install probe: -ListAvailable
        #  only checks the manifest, importing actually loads the assemblies.]
        try
        {
            foreach ($AzSubModule in $RequiredAzSubModules)
            {
                Write-Log -Message ('Loading {0}...' -f $AzSubModule) -Severity 'Info'
                Import-Module $AzSubModule -ErrorAction Stop -DisableNameChecking | Out-Null
            }
            $Global:AzPowerShellLoaded = $true
        }
        catch
        {
            Write-Log -Message ('Azure PowerShell module is present on disk but failed to load: {0}' -f $_.Exception.Message) -Severity 'Error'
            Write-Log -Message ('This usually indicates a broken install - the module manifest is present but its bundled assemblies (MSAL, Azure.Core, etc.) are missing or unloadable.') -Severity 'Error'
            Write-Log -Message ('Reinstall with: Install-Module -Name Az -Repository PSGallery -Force -AllowClobber -SkipPublisherCheck') -Severity 'Error'
            Write-Log -Message ('If the broken install was created by a previous run of this script, also run: Get-Module Az* -ListAvailable | Uninstall-Module -Force') -Severity 'Error'
            $Global:AzPowerShellLoaded = $false
            throw "Azure PowerShell (Az) module is broken on disk and cannot be loaded. See log above for remediation."
        }

        # [long comment: the ImportExcel / EPPlus preflight that used to live here was
        #  removed when the report format changed from .xlsx to self-contained HTML]
    }
```

### The five modules and why exactly five

| Module | Cmdlets this script actually calls |
|---|---|
| `Az.Accounts` | `Connect-AzAccount`, `Get-AzContext`, `Set-AzContext`, `Get-AzSubscription`, `Get-AzAccessToken`, `Save-AzContext`, `Import-AzContext` |
| `Az.Compute` | `Get-AzComputeResourceSku` |
| `Az.Monitor` | `Get-AzMetric` |
| `Az.Billing` | `Get-UsageAggregates` |
| `Az.ResourceGraph` | `Search-AzGraph` |

That is the complete Azure cmdlet surface of the entire tool.
This matters practically: a user can install just those five rather than the full `Az` rollup, and the tool works.

### Line by line

| Line | Code | What it does |
|---|---|---|
| 238 | `if ($Global:AzPowerShellLoaded) { return }` | Skip the whole check on subscription 2 and later, since imported modules persist for the life of the process. |
| 260 | `$RequiredAzSubModules = @(...)` | The five names, as an array. |
| 262 | `@($RequiredAzSubModules \| Where-Object { $null -eq (Get-Module -Name $_ -ListAvailable ... \| Select-Object -First 1) })` | Reads right to left: for each required module name, ask PowerShell for the versions installed on disk (`-ListAvailable`), take the first, and keep the name in the output only if that came back null. The result is the list of *missing* modules. `Select-Object -First 1` is needed because multiple versions of a module can be installed side by side. |
| 264 | `if ($MissingAzSubModules.Count -eq 0)` | Nothing missing, so log the version found and fall through to the import. |
| 266 | `$VarAzPs = Get-Module -Name Az.Accounts -ListAvailable ...` | Fetches `Az.Accounts` again purely so its version number can be shown in the log. `Az.Accounts` is used as the representative because every other Az module depends on it. |
| 271-285 | the `else` branch | Reports what is missing and gives three concrete remediation commands: the slim install, the full rollup, and a note that in Cloud Shell it should already be there. Then `throw`s. |
| 285 | `throw (...)` | A terminating error. Because this is called from the script body inside a `try`/`finally` (line 2466), the throw propagates and the run stops. |
| 311-319 | the `foreach` + `Import-Module` | Imports each of the five, one at a time, announcing each. `-ErrorAction Stop` converts any import failure into a catchable terminating error. `-DisableNameChecking` suppresses PowerShell's warnings about cmdlets using unapproved verbs. `\| Out-Null` discards the module objects that `Import-Module` would otherwise emit. |
| 320 | `$Global:AzPowerShellLoaded = $true` | Only reached if all five imported cleanly. |
| 322-329 | the `catch` | Handles the "present but broken" case, described below. |
| 328 | `$Global:AzPowerShellLoaded = $false` | Explicitly false rather than left unset, so the next subscription in the same session retries the full check. |

### Two field bugs this function encodes

Both of these are worth reading closely, because they explain code that otherwise looks over cautious.

**Bug one: do not install modules from inside the script.**
An earlier version called `Install-Module` here when something was missing.
In a real run that produced a half installed `Az`: the `.psd1` manifests were written to disk, so `Get-Module -ListAvailable` reported success, but the bundled MSAL and Azure.Core assemblies were missing.
The script then ran for nearly an hour and produced **zero** consumption data, because every `Get-UsageAggregates` call failed with "Azure PowerShell context has not been properly initialized".
Installing a module in process while that same module is being imported is fragile, and the failure mode is a silent broken install rather than a clean error.
Failing loudly with instructions is strictly safer.

**Bug two: the import is also the health probe.**
`Get-Module -ListAvailable` only reads the manifest file.
`Import-Module` actually loads the assemblies.
So the import loop at line 311 is doing double duty: it is both how the modules get loaded and how a half installed module is detected.
The `catch` message names that specific scenario, because a generic "failed to load" would send the operator looking in the wrong place.

The pattern here is a good general lesson: check a dependency in the way that actually exercises it, not in the cheapest way available.

## 3b.3 `CheckPowerShell()` (lines 341-438)

Two jobs in one function: detect the environment once per session, and compute a fresh output folder per subscription.

```powershell
    function CheckPowerShell()
    {
        # [long comment: session-scoped detection. Variables() does not reset
        #  $Global:PlatformOS, so platform/PS-version detection runs only for the
        #  first sub. The timestamp + report-folder computation below still runs
        #  every invocation so each subscription gets its own output folder.]
        if (-not $Global:RdaSessionInitialized)
        {
            Write-Log -Message ('Checking PowerShell...') -Severity 'Info'

            $Global:PlatformOS = 'PowerShell Desktop'
            $CloudShell = try { Get-CloudDrive }catch {}

            if ($CloudShell)
            {
                Write-Log -Message ('Identified Environment as Azure CloudShell') -Severity 'Success'
                $Global:PlatformOS = 'Azure CloudShell'
            }
            elseif ($PSVersionTable.Platform -eq 'Unix')
            {
                Write-Log -Message ('Identified Environment as PowerShell Unix') -Severity 'Success'
                $Global:PlatformOS = 'PowerShell Unix'
            }
            else
            {
                Write-Log -Message ('Identified Environment as PowerShell Desktop') -Severity 'Success'
                $Global:PlatformOS = 'PowerShell Desktop'

                $PsVersion = $PSVersionTable.PSVersion.Major
                Write-Log -Message ("PowerShell Version {0}" -f $PsVersion) -Severity 'Info'

                if ($PSVersionTable.PSVersion.Major -lt 7)
                {
                    Write-Log -Message ("You must use Powershell 7 to run the inventory script.") -Severity 'Error'
                    Write-Log -Message ("https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-windows?view=powershell-7.3") -Severity 'Error'
                    Exit
                }
            }
        }

        # [long comment: per-subscription fresh report folder. Millisecond precision
        #  plus a per-process discriminator are REQUIRED because parallel streams fan
        #  out N child processes that all run this block concurrently; without it two
        #  workers compute the same folder and the second Compress-Archive fails with
        #  "archive file already exists".]
        $ProcDiscriminator = ('{0:x4}' -f ($PID -band 0xffff))
        $Global:CurrentDateTime = ((Get-Date).ToString('yyyyMMddHHmmssfff', [cultureinfo]::InvariantCulture) + $ProcDiscriminator)
        $Global:FolderName = $Global:ReportName + $CurrentDateTime

        # [long comment: resolve through the SHARED Get-RdaInventoryRoot rather than an
        #  inline "$HOME/InventoryReports", so this run lands in the same directory the
        #  pre-flight already validated and pinned.]
        $RootForRun = Get-RdaInventoryRoot
        if (-not $RootForRun.Ok)
        {
            Write-Log -Message $RootForRun.Message -Severity 'Error'
            Exit
        }
        if ($RootForRun.IsFallback)
        {
            Write-Log -Message $RootForRun.Message -Severity 'Warning'
        }
        $DefaultOutputDir = (Join-Path $RootForRun.Path $Global:FolderName) + [IO.Path]::DirectorySeparatorChar

        if ($OutputDirectory)
        {
            try
            {
                $OutputDirectory = (Resolve-Path $OutputDirectory -ErrorAction Stop).Path + [IO.Path]::DirectorySeparatorChar
            }
            catch
            {
                Write-Log -Message ("Wrong OutputDirectory Path! OutputDirectory Parameter must contain the full path.") -Severity 'Error'
                Exit
            }
        }

        $Global:DefaultPath = if ($OutputDirectory) { $OutputDirectory } else { $DefaultOutputDir }

        if ($platformOS -eq 'Azure CloudShell')
        {
            $Global:Subscriptions = @(Get-AzSubscription -WarningAction SilentlyContinue)
        }
        elseif ($platformOS -eq 'PowerShell Unix' -or $platformOS -eq 'PowerShell Desktop')
        {
            LoginSession
        }
    }
```

### Environment detection

| Line | Code | What it does |
|---|---|---|
| 353 | `$Global:PlatformOS = 'PowerShell Desktop'` | Set a default first, so the variable is never unset even if detection goes wrong. |
| 354 | `$CloudShell = try { Get-CloudDrive }catch {}` | A neat trick. `Get-CloudDrive` is a cmdlet that only exists inside Azure Cloud Shell. Wrapping it in an inline `try`/`catch` with an empty catch means: if the cmdlet exists it returns the drive object and `$CloudShell` is truthy; if it does not exist the "command not found" error is swallowed and `$CloudShell` is null. So the presence of a cmdlet becomes an environment test. |
| 356-360 | `if ($CloudShell)` | Cloud Shell detected. This branch matters because Cloud Shell arrives already authenticated, so it skips the login path entirely at line 431. |
| 361-365 | `elseif ($PSVersionTable.Platform -eq 'Unix')` | `$PSVersionTable` is an automatic hashtable describing the running engine. Its `Platform` property is `Unix` on both Linux and macOS, and `Win32NT` on Windows. |
| 366-379 | the `else` | Windows. Only this branch checks the PowerShell major version. |
| 374-379 | `if ($PSVersionTable.PSVersion.Major -lt 7) { ...; Exit }` | Hard stop on PowerShell 5.1, with a link to the install docs. This check is only on the Windows branch because Windows is the only platform where the old PowerShell 5.1 is present by default and might get used by accident. On Linux or macOS, if `pwsh` is running at all it is version 6 or later. |

### The timestamp, and a real concurrency bug

| Line | Code | What it does |
|---|---|---|
| 398 | `$ProcDiscriminator = ('{0:x4}' -f ($PID -band 0xffff))` | Takes the current process ID, masks it to its low 16 bits with a bitwise AND against `0xffff`, and formats it as exactly 4 lowercase hex digits. The result is a short, fixed length, per process fingerprint. |
| 399 | `$Global:CurrentDateTime = ((Get-Date).ToString('yyyyMMddHHmmssfff', [cultureinfo]::InvariantCulture) + $ProcDiscriminator)` | Builds the run's unique stamp: year, month, day, hour, minute, second, **milliseconds** (`fff`), then the process discriminator. Formatted with `InvariantCulture` so a non-Gregorian host cannot stamp a Buddhist/Hijri year into every output filename. |
| 400 | `$Global:FolderName = $Global:ReportName + $CurrentDateTime` | For example `ResourcesReport202609081432051234a1b2`. |

Both the milliseconds and the discriminator are there because of a real failure.
In parallel streams mode, `Run-AllSubscriptions.ps1` launches N child processes that all execute this block at once.
With only second precision, two workers computed the *same* `$CurrentDateTime`, pointed at the *same* output folder, and the second one's `Compress-Archive` failed with "archive file already exists".
Milliseconds made a collision unlikely; the process discriminator makes it impossible, because two processes cannot share a PID.

The reason it is hex only and fixed length is compatibility.
Every downstream consumer globs for these files with patterns like `*<timestamp>*`, so as long as the segment stays a single unbroken alphanumeric run, nothing downstream needs to change.

### Resolving the output path

| Line | Code | What it does |
|---|---|---|
| the `Get-RdaInventoryRoot` call | resolving the output root | Delegates to the shared resolver in `Functions/Common.Functions.ps1`. There is no longer an inline platform `if`/`else` here, and no hard-coded `$HOME/InventoryReports` or `C:\InventoryReports` string - the resolver walks a candidate chain, write-probes each, and reports `Ok` / `IsFallback` / `Path`. A `$false` `Ok` stops the run; an `IsFallback` of `$true` warns and names where the output actually went. The trailing separator is appended with `[IO.Path]::DirectorySeparatorChar` because `$Global:DefaultPath` is string-concatenated with file names throughout this script. |
| 415-426 | `if ($OutputDirectory)` | Only runs when the caller supplied a path. |
| 419 | `(Resolve-Path $OutputDirectory -ErrorAction Stop).Path + [IO.Path]::DirectorySeparatorChar` | `Resolve-Path` converts a relative path to absolute **and** verifies it exists, throwing if it does not because of `-ErrorAction Stop`. `[IO.Path]::DirectorySeparatorChar` appends the correct separator for the platform, which is the portable alternative to hard coding `\` or `/`. |
| 421-425 | the `catch` | The supplied path does not exist. Logs and `Exit`s rather than silently falling back to the default, which would write the report somewhere the operator is not looking. |
| 428 | `$Global:DefaultPath = if ($OutputDirectory) { $OutputDirectory } else { $DefaultOutputDir }` | PowerShell lets an `if` be used as an expression whose value is assigned. Explicit wins over default. |

### Branching into authentication

| Line | Code | What it does |
|---|---|---|
| 430-433 | `if ($platformOS -eq 'Azure CloudShell')` | In Cloud Shell there is already a valid Azure context, so it just lists subscriptions and never prompts for login. `-WarningAction SilentlyContinue` suppresses the noisy "you have subscriptions in other tenants" warning. |
| 434-437 | `elseif ($platformOS -eq 'PowerShell Unix' -or ... 'PowerShell Desktop')` | Everywhere else, call `LoginSession` to handle authentication. |

Note that lines 430 and 434 read `$platformOS` without the `$Global:` prefix.
That works because PowerShell scope resolution falls back to the global scope when a name is not found locally, so it refers to the same variable.
It is inconsistent with the rest of the function, which writes `$Global:PlatformOS`, but it is not a bug.

## 3b.4 `LoginSession()` (lines 440-617)

The most branch heavy function in the script.
It has to cope with an already authenticated session, a mismatched tenant, an unknown tenant, multiple tenants, a service principal, device code login, browser login, and being called repeatedly by the wrapper.

### The decision tree

```
                    Get-AzContext  (line 458)
                            │
             ┌──────────────┴───────────────┐
     context exists                    no context
             │                              │
    ┌────────┴─────────┐                    │
 tenant matches   tenant differs            │
 (or no -TenantID)      │                   │
        │               └───────────┬───────┘
        │                           │
   RETURN, reuse it        ┌────────┴─────────┐
   (line 486-492)     no -TenantID given   -TenantID given
                           │                    │
                  ┌────────┴────────┐   ┌───────┴────────┐
                  │ Connect, then   │   │ no $Appid ->   │
                  │ discover tenants│   │   interactive  │
                  │       │         │   │ $Appid+$Secret │
                  │  1 tenant ->    │   │   -> service   │
                  │   use it        │   │      principal │
                  │  N tenants ->   │   │ partial ->     │
                  │   interactive?  │   │   ERROR + Exit │
                  │    yes: prompt  │   └────────────────┘
                  │    no:  take[0] │
                  └─────────────────┘
```

### Reusing an existing context (lines 447-486)

```powershell
    function LoginSession()
    {
        # [long comment: resolve the Az context once and reuse it for both the banner
        #  and the already-authenticated check. Using the native Az context instead of
        #  `az account show` gives ONE source of truth for auth state.]
        $ExistingContext = Get-AzContext -ErrorAction SilentlyContinue

        # [long comment: display-only banner, printed once per session]
        if (-not $Global:RdaSessionInitialized)
        {
            $CurrentCloudEnvName = if ($ExistingContext) { $ExistingContext.Environment.Name } else { 'AzureCloud' }
            Write-Host "Azure Cloud Environment: " -NoNewline
            Write-Host $CurrentCloudEnvName -ForegroundColor Green
        }

        # Check if already authenticated (a non-null Az context means we are)
        if ($null -ne $ExistingContext)
        {
            # [long comment: display-only, once per session. The tenant comparison
            #  below still runs every sub.]
            if (-not $Global:RdaSessionInitialized)
            {
                Write-Log -Message ("Already authenticated as: {0}" -f $ExistingContext.Account.Id) -Severity 'Success'
            }

            if (!$TenantID -or $ExistingContext.Tenant.Id -eq $TenantID)
            {
                # [long comment: the existing context already matches. Per-subscription
                #  scoping happens later via Set-AzContext / resource-id parameters, so
                #  the context only needs to match the TENANT.]
                $Global:Subscriptions = @(Get-AzSubscription -WarningAction SilentlyContinue)
                if ($TenantID) { $Global:Subscriptions = @($Subscriptions | Where-Object { $_.HomeTenantId -eq $TenantID }) }
                return
            }
            else
            {
                Write-Log -Message ("Current session is for tenant {0}, but requested tenant is {1}. Re-authenticating." -f $ExistingContext.Tenant.Id, $TenantID) -Severity 'Warning'
            }
        }
```

| Line | Code | What it does |
|---|---|---|
| 447 | `$ExistingContext = Get-AzContext -ErrorAction SilentlyContinue` | Asks Az PowerShell for the current authenticated context. Returns null if nobody is logged in. Called **once** and reused, rather than being called separately for the banner and the check. |
| 454 | `if (-not $Global:RdaSessionInitialized)` | Banner is display only, so print it once per session. |
| 456 | `$CurrentCloudEnvName = if ($ExistingContext) { ... } else { 'AzureCloud' }` | Which Azure cloud we are in: commercial `AzureCloud`, `AzureUSGovernment`, `AzureChinaCloud`. Defaults to commercial if there is no context to ask. |
| 457 | `Write-Host "Azure Cloud Environment: " -NoNewline` | `-NoNewline` keeps the cursor on the same line so the next `Write-Host` can print the value in a different colour. |
| 462 | `if ($null -ne $ExistingContext)` | Written as `$null -ne $x` rather than `$x -ne $null`, which is the recommended PowerShell order. If `$x` is an array, `$x -ne $null` performs a filtering operation across the array instead of a comparison. Putting `$null` first forces a scalar comparison. |
| 471 | `if (!$TenantID -or $ExistingContext.Tenant.Id -eq $TenantID)` | Reuse the context when either no specific tenant was requested, or the existing one already matches. |
| 477 | `$Global:Subscriptions = @(Get-AzSubscription ...)` | Fetch every subscription the identity can see. |
| 478 | `if ($TenantID) { $Global:Subscriptions = @($Subscriptions \| Where-Object { $_.HomeTenantId -eq $TenantID }) }` | Filter to just the requested tenant. `HomeTenantId` is where the subscription actually lives, as opposed to a tenant it is merely visible from via a guest relationship. |
| 482 | `return` | Early exit. This is the fast path, and on the wrapper it is the path taken for subscriptions 2 through N. |
| 483 | `Write-Log ... "Re-authenticating."` | Tenant mismatch. Does not return, so execution falls through to the full login below. |

The comment at line 476 answers a question you would reasonably ask: if we only match on *tenant*, how does the script end up scoped to the right *subscription*?
The answer is that per subscription scoping happens later, either through `Set-AzContext` or by passing an explicit resource ID to cmdlets like `Get-AzMetric`.
The context only ever needs to be correct at the tenant level.

### Login with no tenant specified (lines 488-575)

```powershell
        if (!$TenantID)
        {
            Write-Log -Message ('Tenant ID not specified. Use -TenantID parameter if you want to specify directly.') -Severity 'Warning'
            Write-Log -Message ('Authenticating Azure') -Severity 'Info'
            Write-Log -Message ('Clearing account cache') -Severity 'Info'

            if (!$RunAllSubs.IsPresent)
            {
                Disconnect-AzAccount -ErrorAction SilentlyContinue | Out-Null
            }

            $DebugPreference = "SilentlyContinue"

            if (!$RunAllSubs.IsPresent)
            {
                Write-Log -Message ('Calling Login, the browser will open and prompt you to login.') -Severity 'Info'
                if ($DeviceLogin.IsPresent)
                {
                    Write-Log -Message ('Using device login') -Severity 'Info'
                    Connect-AzAccount -UseDeviceAuthentication | Out-Null
                }
                else
                {
                    Write-Log -Message ('Using browser login') -Severity 'Info'
                    Connect-AzAccount | Out-Null
                }
            }

            $DebugPreference = "Continue"

            $Tenants = (Get-AzSubscription -WarningAction SilentlyContinue).HomeTenantId | Sort-Object -Unique

            Write-Log -Message ('Checking number of Tenants') -Severity 'Info'

            if ($Tenants.Count -eq 1)
            {
                Write-Log -Message ('You have privileges only in One Tenant') -Severity 'Success'
                $TenantID = $Tenants
            }
            else
            {
                Write-Log -Message ('Select the the Azure Tenant ID that you want to connect: ') -Severity 'Warning'

                $SequenceID = 1
                foreach ($TenantID in $Tenants)
                {
                    write-host "$SequenceID)  $TenantID"
                    $SequenceID ++
                }

                # [long comment: a read-host here blocks until someone types at a
                #  console. Under the wrapper, a parallel worker, an SSM run-command or
                #  any CI session there IS no console, so the prompt would hang the
                #  entire run forever with no way to answer it.]
                $IsInteractiveSession = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
                if ($RunAllSubs.IsPresent -or -not $IsInteractiveSession)
                {
                    $TenantID = $Tenants[0]
                    Write-Log -Message ("Non-interactive session with multiple tenants and no -TenantID: defaulting to the first tenant ({0}). Pass -TenantID to choose explicitly." -f $TenantID) -Severity 'Warning'
                }
                else
                {
                    [int]$SelectTenant = read-host "Select Tenant (Default 1)"
                    if ($SelectTenant -lt 1) { $SelectTenant = 1 }
                    $TenantID = $Tenants[$SelectTenant - 1]
                }

                if (!$RunAllSubs.IsPresent)
                {
                    if ($DeviceLogin.IsPresent)
                    {
                        Connect-AzAccount -UseDeviceAuthentication -Tenant $TenantID | Out-Null
                    }
                    else
                    {
                        Connect-AzAccount -Tenant $TenantID | Out-Null
                    }
                }
            }

            Write-Log -Message ("Extracting from Tenant $TenantID") -Severity 'Info'
            Write-Log -Message ("Extracting Subscriptions") -Severity 'Info'

            $Global:Subscriptions = @(Get-AzSubscription -WarningAction SilentlyContinue)
            $Global:Subscriptions = @($Subscriptions | Where-Object { $_.HomeTenantId -eq $TenantID })
        }
```

| Line | Code | What it does |
|---|---|---|
| 494-497 | `if (!$RunAllSubs.IsPresent) { Disconnect-AzAccount ... }` | Clear any cached credentials so the login is clean. Skipped under the wrapper for a critical reason: the wrapper authenticated **once** before invoking this script, so disconnecting here would destroy the session the wrapper is relying on for all remaining subscriptions. |
| 499 | `$DebugPreference = "SilentlyContinue"` | Temporarily silences debug output around the login call. `Connect-AzAccount` is extremely chatty in debug mode and can print token material. |
| 501-515 | the login `if`/`else` | Also skipped under the wrapper. `-UseDeviceAuthentication` prints a code and a URL to enter it at, which is what you need when there is no local browser, for example over SSH or in a container. Plain `Connect-AzAccount` opens a browser. `\| Out-Null` discards the context object so it does not print. |
| 516 | `$DebugPreference = "Continue"` | Restores debug output. Note this restores it unconditionally rather than to its previous value, which is a small inconsistency: on a non `-Debug` run, debug output is now on from here onward. Harmless in practice, because nothing after this point calls `Write-Debug`. |
| 518 | `$Tenants = (Get-AzSubscription ...).HomeTenantId \| Sort-Object -Unique` | Gets every visible subscription, projects just the `HomeTenantId` from each, then deduplicates. Accessing a property on an array like this is PowerShell's member enumeration feature: it returns an array of that property from every element. |
| 522-526 | `if ($Tenants.Count -eq 1)` | Only one tenant, so no choice to make. |
| 531-536 | the numbered `foreach` | Prints a numbered menu. Note that the loop variable is `$TenantID`, which **overwrites** the outer `$TenantID`, leaving it holding the last tenant in the list after the loop. That is a latent bug, but it never bites because every path below reassigns `$TenantID` before it is read. |
| 546 | `$IsInteractiveSession = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected` | The important line. `[Environment]::UserInteractive` is false in a service or daemon context. `[Console]::IsInputRedirected` is true when stdin is a pipe or a file rather than a keyboard. Both must be favourable for a prompt to be answerable. |
| 547-552 | `if ($RunAllSubs.IsPresent -or -not $IsInteractiveSession)` | No console, so do not prompt. Take the first tenant, which is exactly the "Default 1" the prompt would have offered, and log loudly that a default was chosen and how to override it. |
| 554-556 | `[int]$SelectTenant = read-host ...` | Real interactive session, so prompt. The `[int]` cast converts the typed string to a number. `if ($SelectTenant -lt 1) { $SelectTenant = 1 }` handles a blank or zero answer, because an empty string casts to 0. The `- 1` converts the 1 based menu number to a 0 based array index. |

The `$IsInteractiveSession` check exists because of one of the nastiest classes of automation bug: a hidden prompt.
When output is redirected or captured, the prompt is not even visible, so the run looks like it is working while it waits forever for input that can never arrive.
Detecting the absence of a console and defaulting instead is the fix.

### Login with a tenant specified (lines 577-616)

```powershell
        else
        {
            if (!$RunAllSubs.IsPresent)
            {
                Disconnect-AzAccount -ErrorAction SilentlyContinue | Out-Null

                if (!$Appid)
                {
                    if ($DeviceLogin.IsPresent)
                    {
                        Connect-AzAccount -UseDeviceAuthentication -Tenant $TenantID | Out-Null
                    }
                    else
                    {
                        Connect-AzAccount -Tenant $TenantID | Out-Null
                    }
                }
                elseif ($Appid -and $Secret -and $tenantid)
                {
                    Write-Log -Message ("Using Service Principal Authentication Method") -Severity 'Success'
                    # [comment: Az PowerShell accepts the SecureString secret directly via
                    #  a PSCredential, so the secret never becomes plaintext]
                    $Credential = New-Object System.Management.Automation.PSCredential($Appid, $Secret)
                    Connect-AzAccount -ServicePrincipal -Credential $Credential -Tenant $TenantID | Out-Null
                }
                else
                {
                    Write-Log -Message ("You are trying to use Service Principal Authentication Method in a wrong way.") -Severity 'Error'
                    Write-Log -Message ("It's Mandatory to specify Application ID, Secret and Tenant ID in Azure Resource Inventory") -Severity 'Error'
                    Write-Log -Message (".\ResourceInventory.ps1 -appid <SP AppID> -secret <SP Secret> -tenant <TenantID>") -Severity 'Error'
                    Exit
                }
            }

            $Global:Subscriptions = @(Get-AzSubscription -WarningAction SilentlyContinue)
            $Global:Subscriptions = @($Subscriptions | Where-Object { $_.HomeTenantId -eq $TenantID })
        }
    }
```

| Line | Code | What it does |
|---|---|---|
| 585 | `if (!$Appid)` | No app ID means a human is logging in, so use interactive or device login scoped to the requested tenant. |
| 596 | `elseif ($Appid -and $Secret -and $tenantid)` | All three service principal ingredients are present. |
| 602 | `$Credential = New-Object System.Management.Automation.PSCredential($Appid, $Secret)` | Wraps the app ID and the `SecureString` secret in a `PSCredential`. This is the security relevant line: `PSCredential` takes a `SecureString` for the password directly, so the secret is **never** converted to plaintext anywhere in this script. The previous implementation shelled out to the Azure CLI with `--password-stdin`, which required exactly that conversion. |
| 603 | `Connect-AzAccount -ServicePrincipal -Credential $Credential -Tenant $TenantID` | Non interactive login as the service principal. |
| 605-611 | the `else` | One or two of the three were supplied but not all three. Rather than guessing, it names the requirement, prints the correct invocation, and `Exit`s. |

## 3b.5 `GetSubscriptionsData()` (lines 619-647)

```powershell
    function GetSubscriptionsData()
    {
        $SubscriptionCount = $Subscriptions.Count

        # [long comment: the subscription count is tenant-wide, so under -RunAllSubs
        #  print it once per session. The folder creation below stays per-subscription.]
        if (-not $Global:RdaSessionInitialized)
        {
            Write-Log -Message ("Number of Subscriptions Found: {0}" -f $SubscriptionCount) -Severity 'Info'
        }

        Write-Log -Message ("Checking report folder: {0}" -f $DefaultPath) -Severity 'Info'

        if ((Test-Path -Path $DefaultPath -PathType Container) -eq $false)
        {
            New-Item -Type Directory -Force -Path $DefaultPath | Out-Null
        }

        # [long comment: session init is complete once the first subscription's setup
        #  has run. This is the SINGLE place the flag is set; nothing resets it
        #  mid-session, and parallel streams are separate processes.]
        $Global:RdaSessionInitialized = $true
    }
```

| Line | Code | What it does |
|---|---|---|
| 621 | `$SubscriptionCount = $Subscriptions.Count` | Reads the array that `LoginSession` populated. |
| 627-630 | the guarded count message | Printed once per session. |
| 632 | `Write-Log ("Checking report folder: {0}" ...)` | Not guarded, because each subscription genuinely has its own folder and the operator wants to see each one. |
| 634-637 | `if ((Test-Path -Path $DefaultPath -PathType Container) -eq $false) { New-Item -Type Directory -Force ... }` | Create the output folder if it is not there. `-PathType Container` means "must be a directory". `-Force` on `New-Item` creates any missing intermediate directories, which is what you want when `-OutputDirectory` points several levels deep. |
| 646 | `$Global:RdaSessionInitialized = $true` | The one and only place this flag is set. Everything that reads it, in `CheckVersion`, `CheckPowerShell`, `LoginSession` and this function, is guarded from here onward. Placing it at the *end* of setup rather than the start is what makes the first subscription do the full work while later ones skip it. |

## 3b.6 `ResourceInventoryLoop()` (lines 649-744)

This is where resources are actually discovered.
It queries Azure Resource Graph, which is a KQL queryable index of every resource in the tenant, and it is the reason this tool can inventory a hundred thousand resources in minutes rather than hours.

The function is three nearly identical blocks selected by an `if`/`elseif`/`else`.

| Block | Lines | Runs when | Scope |
|---|---|---|---|
| 1 | 674-699 | both `-ResourceGroup` and `-SubscriptionID` given | One resource group |
| 2 | 701-727 | only `-SubscriptionID` given | One subscription |
| 3 | 728-754 | neither given | Everything the identity can see |

### The upfront validation (lines 651-661)

```powershell
    function ResourceInventoryLoop()
    {
        if (![string]::IsNullOrEmpty($ResourceGroup) -and [string]::IsNullOrEmpty($SubscriptionID))
        {
            Write-Log -Message ("Resource Group Name present, but missing Subscription ID.") -Severity 'Error'
            Write-Log -Message ("If using ResourceGroup parameter you must also put SubscriptionId") -Severity 'Error'
            Exit
        }

        if (![string]::IsNullOrEmpty($ResourceGroup))
        {
            $ResourceGroup = $ResourceGroup.ToLower()
        }
```

| Line | Code | What it does |
|---|---|---|
| 651 | `if (![string]::IsNullOrEmpty($ResourceGroup) -and [string]::IsNullOrEmpty($SubscriptionID))` | Resource group without subscription is meaningless, because resource group names are only unique within a subscription. `[string]::IsNullOrEmpty` is used rather than a plain truthiness test because it handles both null and the empty string in one call. |
| 660 | `$ResourceGroup = $ResourceGroup.ToLower()` | Lowercase the name. This is necessary because the Resource Graph queries below use `-Lowercase` on the results, so the comparison value must be lowercased too or the `where` clause never matches. |

### The paging pattern

All three blocks use the same two step approach, and understanding it once covers all three.

```
     Step 1: COUNT              Step 2: FETCH IN PAGES OF 1000
     ┌──────────────┐           ┌─────────────────────────────────┐
     │ summarize    │           │  Skip 0    First 1000  ──┐      │
     │ count()      │──────►    │  Skip 1000 First 1000  ──┤      │
     │              │  N        │  Skip 2000 First 1000  ──┼──► $Global:Resources
     │ returns N    │           │  ...                     │      │
     └──────────────┘           │  ceiling(N / 1000) times ┘      │
                                │  sleep 2 sec between pages      │
                                └─────────────────────────────────┘
```

### Block 3, the full tenant case, line by line (lines 717-743)

```powershell
        else
        {
            $GraphQuery = "resources | where (isnull(properties.definition.actions) or strlen(properties.definition.actions) < 123000) | summarize count()"
            $EnvSize = Invoke-AzGraphQuerySafe -Query $GraphQuery
            $EnvSizeCount = $EnvSize.data.count_

            Write-Log -Message ("Resources Output: {0} Resources Identified" -f $EnvSizeCount) -Severity 'Success'

            if ($EnvSizeCount -ge 1)
            {
                $Loop = $EnvSizeCount / 1000
                $Loop = [math]::Ceiling($Loop)
                $Looper = 0
                $Limit = 0

                while ($Looper -lt $Loop)
                {
                    $GraphQuery = "resources | where (isnull(properties.definition.actions) or strlen(properties.definition.actions) < 123000) | project id,name,type,tenantId,kind,location,resourceGroup,subscriptionId,managedBy,sku,plan,properties,identity,zones,extendedLocation,tags | order by id asc"
                    $Resource = Invoke-AzGraphQuerySafe -Query $GraphQuery -Skip $Limit -First 1000 -Lowercase

                    $Global:Resources += $Resource.data
                    Start-Sleep 2
                    $Looper++
                    $Limit = $Limit + 1000
                }
            }
        }
```

| Line | Code | What it does |
|---|---|---|
| 719 | `$GraphQuery = "resources \| where (...) \| summarize count()"` | A KQL query. `resources` is the Resource Graph table containing every resource. `summarize count()` returns a single row with the total. This is the cheap counting query. |
| 719 | `(isnull(properties.definition.actions) or strlen(properties.definition.actions) < 123000)` | The most cryptic thing in the function, and it is a workaround. Some resources, notably large Logic App definitions and policy definitions, have an enormous `properties.definition.actions` blob. Resource Graph has a hard response size limit, and a single such resource can blow through it and fail the entire page. This filter excludes any resource whose actions blob exceeds roughly 123,000 characters, keeping the response under the limit. The trade off is explicit: a handful of very large resources are dropped so that the other tens of thousands can be collected. |
| 720 | `$EnvSize = Invoke-AzGraphQuerySafe -Query $GraphQuery` | The project's own wrapper around `Search-AzGraph`, defined in `Functions/ResourceInventory.Functions.ps1`. It adds bounded retry with backoff, and it distinguishes transient failures such as throttling (retry) from permanent ones such as a permission denial (fail fast). |
| 721 | `$EnvSizeCount = $EnvSize.data.count_` | Digs the number out of the response. `count_` with the trailing underscore is Resource Graph's own auto generated column name for an unaliased `count()`. |
| 725 | `if ($EnvSizeCount -ge 1)` | Skip the whole paging loop for an empty subscription. |
| 727-728 | `$Loop = $EnvSizeCount / 1000` then `[math]::Ceiling($Loop)` | How many pages of 1000 are needed. `Ceiling` rounds **up**, so 1 resource more than a whole page gives 2 pages rather than 1. Getting this wrong by using truncation would silently drop the tail of the inventory. |
| 729-730 | `$Looper = 0` and `$Limit = 0` | Two counters: `$Looper` counts pages fetched, `$Limit` is the offset into the result set. |
| 734 | the `project` query | The real fetch. `project` selects columns, which is Resource Graph's equivalent of SQL `SELECT`. The 16 columns listed are the complete raw shape every service collector receives. |
| 734 | `order by id asc` | Absolutely load bearing. Paging with skip and take is only correct if the underlying order is stable between calls. Without an explicit sort, Resource Graph does not guarantee the same order across two requests, so pages could overlap or skip rows. Sorting by `id`, which is unique, makes the paging deterministic. |
| 735 | `Invoke-AzGraphQuerySafe -Query $GraphQuery -Skip $Limit -First 1000 -Lowercase` | `-Skip` and `-First` are the paging window. `-Lowercase` normalises the returned values, which is what makes downstream string comparisons in the collectors reliable regardless of how a resource was originally named. |
| 737 | `$Global:Resources += $Resource.data` | Appends this page's rows to the master array. |
| 738 | `Start-Sleep 2` | A deliberate two second pause between pages, to stay under Resource Graph's rate limits. On a 100,000 resource tenant that is 100 pages and therefore 200 seconds of pure sleeping, which is a real cost but cheaper than being throttled and having to back off. |
| 739-740 | `$Looper++` and `$Limit = $Limit + 1000` | Advance both counters. |

### The columns fetched, and what they are for

| Column | Contains |
|---|---|
| `id` | Full ARM resource ID. The primary key, and the obfuscation dictionary key |
| `name` | Resource name |
| `type` | Resource type such as `microsoft.compute/virtualmachines`. This is what each collector filters on |
| `tenantId` | Owning directory |
| `kind` | Sub type discriminator, for example distinguishing a function app from a web app |
| `location` | Azure region |
| `resourceGroup` | Containing resource group |
| `subscriptionId` | Containing subscription |
| `managedBy` | The parent resource that owns this one. This is how a disk is linked to its VM |
| `sku` | Size and tier |
| `plan` | Marketplace plan |
| `properties` | The big one. The entire type specific payload, which is what collectors dig into |
| `identity` | Managed identity configuration |
| `zones` | Availability zones |
| `extendedLocation` | Edge or Azure Stack location |
| `tags` | Tag key and value pairs |

### One thing to notice about the three blocks

They are almost entirely duplicated: three copies of the count query, three copies of the paging loop, three copies of the sleep.
This is genuine duplication and it would normally be worth factoring into one function taking an optional filter.
The project's own change rules explicitly say not to do that as a drive by refactor, since it is working code and touching it risks the paging correctness for no functional gain.
It is called out here so you know it is duplication by choice, not by oversight.

## 3b.7 `ResourceInventoryAvd()` (lines 746-771)

```powershell
    function ResourceInventoryAvd()
    {
        $AVDSize = Invoke-AzGraphQuerySafe -Query "desktopvirtualizationresources | summarize count()"
        $AVDSizeCount = $AVDSize.data.count_

        Write-Log -Message ("AVD Resources Output: {0} AVD Resources Identified" -f $AVDSizeCount) -Severity 'Success'

        if ($AVDSizeCount -ge 1)
        {
            $Loop = $AVDSizeCount / 1000
            $Loop = [math]::ceiling($Loop)
            $Looper = 0
            $Limit = 0

            while ($Looper -lt $Loop)
            {
                $GraphQuery = "desktopvirtualizationresources | project id,name,type,tenantId,kind,location,resourceGroup,subscriptionId,managedBy,sku,plan,properties,identity,zones,extendedLocation,tags | order by id asc"
                $AVD = Invoke-AzGraphQuerySafe -Query $GraphQuery -Skip $Limit -First 1000 -Lowercase

                $Global:Resources += $AVD.data
                Start-Sleep 2
                $Looper++
                $Limit = $Limit + 1000
            }
        }
```

Structurally identical to the loop above.
The only difference is the table name: `desktopvirtualizationresources` instead of `resources`.

Azure Virtual Desktop objects such as host pools, application groups and session hosts live in a **separate** Resource Graph table and simply do not appear in `resources`.
Without this second function, an AVD estate would be entirely invisible in the report.
The results are appended to the same `$Global:Resources` array, so from every collector's point of view they are just more resources.

Note that this function has no subscription or resource group scoping.
It always queries the whole visible estate, so an AVD only run scoped with `-SubscriptionID` will still pull AVD resources from every subscription.

## 3b.8 The orchestration and the discovery guard (lines 773-808)

```powershell
    CheckVersion
    CheckCliRequirements
    CheckPowerShell
    GetSubscriptionsData

    # [long comment: resource discovery is wrapped because a failed page must NOT be
    #  survivable. Under SilentlyContinue a terminating error with no catch anywhere
    #  up the stack does not stop anything - every frame continues at its next
    #  statement. So a failed page left $Resource holding the PREVIOUS page's object,
    #  appended it a SECOND time, and the run produced a report missing ~1000 real
    #  resources while double-counting another page, with a plausible-looking total
    #  and nothing reported.]
    try
    {
        ResourceInventoryLoop
        ResourceInventoryAvd
    }
    catch
    {
        Write-Log -Message ("FAILED to complete resource discovery: {0}" -f $_.Exception.Message) -Severity 'Error'
        Write-Log -Message ('  The inventory for this subscription would be INCOMPLETE, so it is reported as failed rather than written to a report. Re-run with -Resume to retry it.') -Severity 'Error'
        Write-Log -Message ('  If this is a Resource Graph response-size failure on one specific resource type, exclude that type from the discovery query to let the rest of the subscription complete.') -Severity 'Error'
        exit 1
    }
```

The four calls at lines 773-776 must happen in that order, and each depends on the one before it.

| Order | Call | Depends on |
|---|---|---|
| 1 | `CheckVersion` | nothing, just needs `$Global:Version` from `Variables()` |
| 2 | `CheckCliRequirements` | nothing, but must precede any Az cmdlet call |
| 3 | `CheckPowerShell` | the Az modules being imported, since it calls `Get-AzSubscription` and `LoginSession` |
| 4 | `GetSubscriptionsData` | `$Global:DefaultPath` and `$Global:Subscriptions`, both set by step 3 |

### The bug this `try`/`catch` prevents

This is the single best worked example in the file of *why* `$ErrorActionPreference = 'SilentlyContinue'` needs explicit guards on the important paths, and it is worth reading twice.

The paging loops do this, with no local error handling:

```powershell
$Resource = Invoke-AzGraphQuerySafe ...
$Global:Resources += $Resource.data
```

Now suppose page 5 of 40 fails, and think about what `SilentlyContinue` actually means.
It does not mean "errors are logged quietly".
It means that when a terminating error is raised and **nothing anywhere up the call stack catches it**, every frame simply resumes at its next statement.

So the sequence was:

1. Page 5's `Invoke-AzGraphQuerySafe` throws.
2. Nothing catches it, so the assignment on that line never happens.
3. `$Resource` still holds **page 4's** object, because it was never overwritten.
4. The next line runs anyway and appends page 4's data a second time.
5. The loop continues to page 6 and finishes normally.

The result was a report that was missing about 1,000 real resources while double counting another 1,000.
The total looked entirely plausible.
Nothing was logged.
Nobody could have spotted it from the output.

One `catch` at this level fixes every call site at once, because a terminating error propagates upward until something catches it.
That is why the guard is here rather than being duplicated into all four paging loops.

### Why `exit 1` and not `throw`

| Line | Code | What it does |
|---|---|---|
| 801 | `Write-Log ("FAILED to complete resource discovery: {0}" ...)` | Reports the actual exception message. |
| 802 | the "INCOMPLETE" message | States the reasoning explicitly for the operator: partial discovery means the report would be wrong, so the subscription is failed rather than half reported. |
| 803 | the remediation hint | Points at the most likely specific cause, a Resource Graph response size failure on one resource type, and its workaround. |
| 804 | `exit 1` | The hard fail signal. |

`exit 1` rather than `throw` is deliberate.
`exit` sets the process exit code, and the wrapper scripts check `$LASTEXITCODE` after every invocation.
A non zero code means "this subscription failed", which puts it in the failed list and makes it eligible for retry under `-Resume`.
A `throw` would be caught by the wrapper differently and, more importantly, would not produce the exit code the wrapper's existing check relies on.

The principle at work: **refusing to produce output is better than producing output that is quietly wrong.**

---

# Part 3c: Minting the obfuscation tokens (lines 807-966)

This block runs only when `-Obfuscate` was passed, and it is where every masked value in the entire report is decided.
It runs **once**, right after discovery, before any collector has seen a resource.
That ordering is what guarantees the masking is consistent: by the time a collector runs, every token already exists.

## The four rules of obfuscation in this tool

| Rule | Meaning | Where enforced |
|---|---|---|
| Deterministic | The same real value always yields the same token, within a run | Lookup before mint, lines 905 and 915 |
| Prefixed | Every token starts `prod_` or `nonprod_` | Lines 880-881 |
| Reversible locally | A dictionary file is saved so the owner can unmask | Written at packaging time, never shipped |
| Structure preserving | Cross references still join correctly after masking | Everything keyed by resource ID |

The last one is the subtle one.
If a disk record says it is managed by VM `prod_abc`, then the VM record must also be named `prod_abc`, or the report is useless for anything relational.
Keying everything by resource ID is what makes that work.

## 3c.1 The two real value keyed lookups (lines 807-812)

```powershell
    if ($Obfuscate.IsPresent)
    {
        # [comment: lookup tables keyed by real subscription name / real RG name so the
        #  same real value always maps to the same obfuscated value across resources]
        $SubLookup = @{}
        $RgLookup = @{}
```

These two are ordinary PowerShell hashtables, not the typed dictionaries from `Variables()`, and they are keyed differently.

| Structure | Keyed by | Why |
|---|---|---|
| `$Global:ResourceIdDictionary` etc. | real resource **ID** | one token per resource, so an ID key is exactly right |
| `$SubLookup`, `$RgLookup` | real subscription **name** / real RG **name** | one token shared by thousands of resources, so the key has to be the thing they share |

A hashtable is used here specifically **because** it is case insensitive by default.
Azure resource IDs and resource properties frequently disagree on the casing of a resource group name, so a case sensitive map would mint two different tokens for what is really one resource group.
The four ID-keyed `Dictionary[string,string]` maps are now built with `OrdinalIgnoreCase` for exactly the same reason, so the whole obfuscation path is consistent on this point rather than only the hashtables.
This is the mirror image of the reasoning for the typed dictionaries in `Variables()`, and both choices are correct for their key type.

## 3c.2 Seeding from a previous run's dictionary (lines 814-877)

```powershell
        # [long comment: -ObfuscationDictionary seeding. When a prior run's saved
        #  dictionary is supplied, preload the maps so identical real values yield the
        #  SAME tokens as that earlier run. This is what lets a scoped recovery run be
        #  merged back into the earlier bundle. New values still get fresh tokens, so
        #  determinism is EXTENDED, never broken.
        #
        #  The saved file stores each map INVERTED (token -> real):
        #   - ResourceIdMap / ResourceNameMap: tokens are UNIQUE per resource so the
        #     maps are complete; invert them back to (real ID -> token).
        #   - TagMap / FreeTextMap: token -> real value; seeding the real-value-keyed
        #     dicts suffices.
        #   - Subscription / ResourceGroup tokens are SHARED by every resource in a
        #     sub/RG, so those maps collapse to ONE representative real ID per token and
        #     CANNOT be reused ID-keyed. Rebuild the real-value-keyed lookups instead.]
        if (-not [string]::IsNullOrEmpty($ObfuscationDictionary))
        {
            $SeedDictionary = Get-Content -Path $ObfuscationDictionary -Raw | ConvertFrom-Json

            if ($null -ne $SeedDictionary.ResourceIdMap)
            {
                foreach ($SeedProp in $SeedDictionary.ResourceIdMap.PSObject.Properties) { $ResourceIdDictionary[$SeedProp.Value] = $SeedProp.Name }
            }
            if ($null -ne $SeedDictionary.ResourceNameMap)
            {
                foreach ($SeedProp in $SeedDictionary.ResourceNameMap.PSObject.Properties) { $ResourceNameDictionary[$SeedProp.Value] = $SeedProp.Name }
            }
            if ($null -ne $SeedDictionary.TagMap)
            {
                foreach ($SeedProp in $SeedDictionary.TagMap.PSObject.Properties) { $Global:TagValueDictionary[$SeedProp.Value] = $SeedProp.Name }
            }
            if ($null -ne $SeedDictionary.FreeTextMap)
            {
                foreach ($SeedProp in $SeedDictionary.FreeTextMap.PSObject.Properties) { $Global:FreeTextDictionary[$SeedProp.Value] = $SeedProp.Name }
            }
            if ($null -ne $SeedDictionary.SubscriptionNameMap)
            {
                # property NAME = subscription token, VALUE = real subscription name
                foreach ($SeedProp in $SeedDictionary.SubscriptionNameMap.PSObject.Properties)
                {
                    if (-not [string]::IsNullOrEmpty($SeedProp.Value)) { $SubLookup[$SeedProp.Value] = $SeedProp.Name }
                }
            }
            if ($null -ne $SeedDictionary.ResourceGroupMap)
            {
                # property NAME = RG token, VALUE = representative real resource ID
                foreach ($SeedProp in $SeedDictionary.ResourceGroupMap.PSObject.Properties)
                {
                    if ($SeedProp.Value -match '(?i)/resourcegroups/([^/]+)') { $RgLookup[$Matches[1]] = $SeedProp.Name }
                }
            }

            Write-Log -Message ("Obfuscation dictionary seeded from '{0}': {1} id, {2} name, ..." -f ...) -Severity 'Info'
        }
```

### What problem seeding solves

Suppose a large multi-subscription run finishes but the VM collector failed on three of them.
You want to re-run just that collector for just those subscriptions with `-Service VirtualMachines`, and splice the results into the original bundle.

Without seeding, the recovery run mints brand new random GUID tokens.
Subscription `prod_aaa` in the original bundle becomes `prod_zzz` in the recovery run, and the two datasets cannot be joined.
The recovery is worthless.

Seeding preloads the earlier run's mappings so matching real values get the **same** tokens.
Crucially it only *extends* determinism: any real value not present in the seed still gets a fresh token from the minting logic below, so a recovery run can discover new resources without breaking anything.

### The inversion, which is the confusing part

The saved dictionary file on disk is written **inverted**, as `token -> real value`, because that is the direction a human needs when reading it to unmask something.
The in memory dictionaries need the opposite direction, `real value -> token`, because that is the direction the report generation looks values up in.

So every seeding loop swaps the two.

| In the file | In memory after seeding |
|---|---|
| `"prod_abc123": "/subscriptions/.../vm-web-01"` | `["/subscriptions/.../vm-web-01"] = "prod_abc123"` |

That is what `$SeedProp.Name` and `$SeedProp.Value` are doing.
`.PSObject.Properties` enumerates a parsed JSON object's fields, giving each field's `Name` (the JSON key, which here is the token) and `Value` (the JSON value, which here is the real value).
Writing `$Dictionary[$SeedProp.Value] = $SeedProp.Name` therefore stores real as key and token as value, which is the inversion.

### Line by line

| Line | Code | What it does |
|---|---|---|
| 838 | `if (-not [string]::IsNullOrEmpty($ObfuscationDictionary))` | Only seed when a file was supplied. The pre flight validation at line 2340 has already checked the file exists, parses, and that `-Obfuscate` was also passed. |
| 840 | `Get-Content -Path $ObfuscationDictionary -Raw \| ConvertFrom-Json` | `-Raw` reads the whole file as one string rather than an array of lines, which is much faster and is required for JSON parsing. |
| 842-845 | `ResourceIdMap` seeding | Straight inversion. These tokens are unique per resource so the map is complete and can be inverted losslessly. |
| 846-849 | `ResourceNameMap` seeding | Same. |
| 850-853 | `TagMap` seeding | The saved form is `token -> real tag value`; inverting gives real value as key, which is exactly what the collector loop tests with `ContainsKey`. |
| 854-857 | `FreeTextMap` seeding | Same, for descriptions, `CreatedBy` and similar. |
| 858-865 | `SubscriptionNameMap` seeding | Note it uses `SubscriptionNameMap`, **not** `SubscriptionMap`. This is the whole reason a name keyed map is saved separately. |
| 866-873 | `ResourceGroupMap` seeding | Uses a regex to extract the RG name out of a representative resource ID. `(?i)` makes the match case insensitive; `/resourcegroups/([^/]+)` captures everything after that segment up to the next slash; `$Matches[1]` is the captured group. |
| 875 | the summary `Write-Log` | Reports counts per map so the operator can see the seed actually loaded. `@($Dict.Keys).Count` forces an array before counting, which guards against a single key collapsing to a scalar. |

### Why subscription and resource group need a different treatment

This is the deepest point in the section and worth a diagram.

```
  RESOURCE ID tokens: one token per resource -> INVERTIBLE
  ┌───────────────────────────────────────────────────────┐
  │  /subscriptions/.../vm-01   ->  prod_aaa              │
  │  /subscriptions/.../vm-02   ->  prod_bbb              │
  │  /subscriptions/.../vm-03   ->  prod_ccc              │
  │  Saved as token -> real.  Invert it: nothing is lost.  │
  └───────────────────────────────────────────────────────┘

  SUBSCRIPTION tokens: one token SHARED by thousands -> LOSSY
  ┌───────────────────────────────────────────────────────┐
  │  /subscriptions/.../vm-01   ->  prod_sub1  ┐          │
  │  /subscriptions/.../vm-02   ->  prod_sub1  ├ all the  │
  │  /subscriptions/.../vm-03   ->  prod_sub1  ┘ same     │
  │                                                       │
  │  Saved inverted, prod_sub1 can only point at ONE      │
  │  representative ID. The other 999 are gone.           │
  │  So the ID-keyed map cannot be rebuilt from the file. │
  │                                                       │
  │  FIX: also save SubscriptionNameMap                   │
  │       prod_sub1 -> "Contoso Production"               │
  │  Invert THAT into $SubLookup, keyed by the real NAME,  │
  │  which is exactly the key the mint logic uses.        │
  └───────────────────────────────────────────────────────┘
```

## 3c.3 The minting loop (lines 878-964)

This runs once per discovered resource.

```powershell
        foreach ($resourceItem in $Global:Resources)
        {
            $IsNonProd = $resourceItem.name -match '\b(dev|test|qa|tst|development|non-prod|uat|nonprod)\b' -or $resourceItem.name -match '(^|-)([dts])-'
            $Prefix = if ($IsNonProd) { "nonprod_" } else { "prod_" }

            $ObfuscatedID = $Prefix + [guid]::NewGuid().ToString()
            $ObfuscatedName = $Prefix + [guid]::NewGuid().ToString()

            # Preserve resource type signal in obfuscated name for server-side matching
            # VMs/Disks managed by services have identifiable patterns in their resource ID
            if ($resourceItem.id -match 'databricks')
            {
                $ObfuscatedName = $Prefix + 'databricks_' + [guid]::NewGuid().ToString()
            }
            elseif ($resourceItem.id -match '/resourcegroups/mc_')
            {
                $ObfuscatedName = $Prefix + 'aks_' + [guid]::NewGuid().ToString()
            }
            elseif ($resourceItem.id -match 'virtualmachinescalesets')
            {
                $ObfuscatedName = $Prefix + 'vmss_' + [guid]::NewGuid().ToString()
            }
```

### Step 1: decide prod or nonprod (lines 880-881)

| Line | Code | What it does |
|---|---|---|
| 880 | `$resourceItem.name -match '\b(dev\|test\|qa\|tst\|development\|non-prod\|uat\|nonprod)\b'` | Looks for a non production keyword in the resource name. `\b` is a word boundary, which is what stops `dev` matching inside `device` or `devops`. |
| 880 | `-or $resourceItem.name -match '(^\|-)([dts])-'` | A second, shorter convention: a single letter `d`, `t` or `s` followed by a hyphen, either at the start of the name or after a hyphen. This catches naming schemes like `d-web-01` or `app-t-sql`. |
| 881 | `$Prefix = if ($IsNonProd) { "nonprod_" } else { "prod_" }` | Default is `prod_`. Erring toward "production" is the safe direction: mislabelling production data as test would understate its sensitivity. |

The purpose of this classification is that it survives masking.
The recipient of an obfuscated report cannot see any names, but they can still tell production from non production estate and size them separately.
That is genuinely useful analysis with zero identifying information.

### Step 2: mint the tokens (lines 883-884)

| Line | Code | What it does |
|---|---|---|
| 883 | `$ObfuscatedID = $Prefix + [guid]::NewGuid().ToString()` | A fresh random version 4 GUID. Random, not derived from the real value, which matters: a hash of the real name could be brute forced against a dictionary of likely names, whereas a random GUID carries no information at all. |
| 884 | `$ObfuscatedName = $Prefix + [guid]::NewGuid().ToString()` | A **different** GUID for the name. ID and name are masked independently so that knowing one tells you nothing about the other. |

### Step 3: preserve a type hint for three special cases (lines 886-899)

| Line | Pattern matched | Token becomes |
|---|---|---|
| 888 | `databricks` anywhere in the resource ID | `prod_databricks_<guid>` |
| 892 | `/resourcegroups/mc_` in the resource ID | `prod_aks_<guid>` |
| 896 | `virtualmachinescalesets` in the resource ID | `prod_vmss_<guid>` |

These three exist because Azure creates resources on your behalf whose *identity* is only discoverable from their name or path.
Databricks provisions VMs into a managed resource group.
AKS puts node pool resources into a resource group prefixed `mc_`, which stands for managed cluster.
Scale sets own their instances.

Once you mask the name and path, that relationship disappears and the downstream analysis cannot tell "this is a Databricks worker VM" from "this is somebody's hand built VM".
Injecting a small type marker into the token restores the signal without revealing anything about the customer, since a bare `databricks` or `aks` marker is not identifying.

Note these are `elseif`, so they are mutually exclusive and evaluated in order.
A Databricks VM that happens to be in a scale set gets the `databricks_` marker, because that branch is tested first.

### Step 4: the subscription token (lines 901-909)

```powershell
            # Deterministic subscription obfuscation: derive prefix from sub name, not resource name
            $RealSub = ($Global:Subscriptions | Where-Object { $_.id -eq $resourceItem.subscriptionId }).Name
            if ([string]::IsNullOrEmpty($RealSub)) { $RealSub = $resourceItem.subscriptionId }
            if (-not $SubLookup.ContainsKey($RealSub))
            {
                $SubPrefix = if ($RealSub -match '\b(dev|test|qa|tst|development|non-prod|uat|nonprod)\b' -or $RealSub -match '(^|-)([dts])-') { "nonprod_" } else { "prod_" }
                $SubLookup[$RealSub] = $SubPrefix + [guid]::NewGuid().ToString()
            }
            $ObfuscatedSubscription = $SubLookup[$RealSub]
```

| Line | Code | What it does |
|---|---|---|
| 902 | `$RealSub = ($Global:Subscriptions \| Where-Object { $_.id -eq $resourceItem.subscriptionId }).Name` | Resolve the subscription GUID on the resource into a human readable subscription **name**, by looking it up in the array `LoginSession` populated. |
| 903 | `if ([string]::IsNullOrEmpty($RealSub)) { $RealSub = $resourceItem.subscriptionId }` | Fall back to the GUID if the name cannot be resolved. This happens for real: a resource can belong to a subscription the current identity cannot enumerate. Falling back keeps a stable key rather than letting every unresolvable resource collapse onto the empty string and share one token. |
| 904 | `if (-not $SubLookup.ContainsKey($RealSub))` | **This is the determinism.** Mint only if this real subscription has not been seen before. On a seeded run the key is already present, so the earlier run's token is reused. |
| 907 | `$SubLookup[$RealSub] = $SubPrefix + [guid]::NewGuid().ToString()` | Mint once and store. |
| 909 | `$ObfuscatedSubscription = $SubLookup[$RealSub]` | Read it back. Every resource in the same subscription reaches this line and gets the same token. |

The comment on line 901 flags something easy to get wrong: the prod or nonprod prefix for a **subscription** is derived from the *subscription* name, not from the resource name that happened to trigger the minting.
Using the resource name would be a race: whichever resource happened to be processed first would decide the whole subscription's classification, so a single test VM in a production subscription would label that entire subscription `nonprod_`.

### Step 5: the resource group token (lines 911-919)

```powershell
            # Deterministic RG obfuscation: derive prefix from RG name, not resource name
            $RealRG = $resourceItem.resourceGroup
            if ([string]::IsNullOrEmpty($RealRG)) { $RealRG = '__none__' }
            if (-not $RgLookup.ContainsKey($RealRG))
            {
                $RgPrefix = if ($RealRG -match '\b(dev|test|qa|tst|development|non-prod|uat|nonprod)\b' -or $RealRG -match '(^|-)([dts])-') { "nonprod_" } else { "prod_" }
                $RgLookup[$RealRG] = $RgPrefix + [guid]::NewGuid().ToString()
            }
            $ObfuscatedResourceGroup = $RgLookup[$RealRG]
```

Identical logic, same reasoning.
The one thing worth pointing out is line 913: `'__none__'` is a sentinel for resources that genuinely have no resource group, such as subscription level or management group level resources.
Using an explicit sentinel rather than the empty string means those resources all share one clearly identifiable token instead of hitting an empty key.

### Step 6: honour a seeded ID (lines 921-951)

```powershell
            # [long comment: seeded reuse. If this real resource ID was preloaded from a
            #  prior run's dictionary, reuse its ID and Name tokens so a scoped recovery
            #  run lands in the SAME token space as the bundle it will be merged into.
            #  Gated purely on ContainsKey: on a normal run the dictionary starts empty
            #  and this loop is what first populates it, so ContainsKey is always false
            #  and behaviour is byte-for-byte unchanged. The GUIDs minted above are
            #  harmless throwaway on a seed hit.
            #
            #  Subscription and ResourceGroup tokens are deliberately NOT reused from the
            #  ID-keyed dictionaries here - they come via $subLookup/$rgLookup above,
            #  which the seed block already populated.]
            if ($ResourceIdDictionary.ContainsKey($resourceItem.ID))
            {
                $ObfuscatedID = $ResourceIdDictionary[$resourceItem.ID]
                # [long comment: guard the name-map read. A seeded or hand-edited
                #  dictionary can contain the ID in the ResourceId map but NOT the
                #  ResourceName map, and the generic Dictionary indexer THROWS
                #  KeyNotFoundException (not $null) on a miss, which would abort the
                #  whole obfuscation pass.]
                if ($ResourceNameDictionary.ContainsKey($resourceItem.ID))
                {
                    $ObfuscatedName = $ResourceNameDictionary[$resourceItem.ID]
                }
            }
```

| Line | Code | What it does |
|---|---|---|
| 938 | `if ($ResourceIdDictionary.ContainsKey($resourceItem.ID))` | On a normal run this is **always false**, because the dictionary starts empty and this loop is the first thing to fill it. So the whole block is a no op unless seeding happened. That is why adding it did not change existing behaviour at all. |
| 940 | `$ObfuscatedID = $ResourceIdDictionary[$resourceItem.ID]` | Overwrite the freshly minted GUID from line 883 with the seeded one. The wasted GUID is harmless. |
| 947 | `if ($ResourceNameDictionary.ContainsKey($resourceItem.ID))` | The guard discussed in Part 3a. A `Dictionary[string,string]` **throws** on a missing key rather than returning null, so reading the name map without checking first would crash the whole obfuscation pass on a seed file where the two maps disagree. Since a seed file can be hand edited, that is a realistic input. With the guard, a sparse seed just keeps the freshly minted name. |

### Step 7: commit all four mappings (lines 953-956)

```powershell
            $ResourceIdDictionary[$resourceItem.ID] = $ObfuscatedID
            $ResourceNameDictionary[$resourceItem.ID] = $ObfuscatedName
            $ResourceSubscriptionDictionary[$resourceItem.ID] = $ObfuscatedSubscription
            $ResourceResourceGroupDictionary[$resourceItem.ID] = $ObfuscatedResourceGroup
```

All four keyed by the same real resource ID.
This is the uniformity that makes the collectors simple: a collector holding a resource ID can look up any of the four masked values without needing to know anything else.

Note that lines 955 and 956 write the *shared* subscription and resource group tokens into an ID keyed map.
That is the lossy direction discussed earlier, and it is fine here because in memory both forms exist simultaneously.
It only becomes a problem when the maps are saved to disk, which is exactly why `SubscriptionNameMap` also gets written at packaging time.

### Step 8: what is deliberately *not* done (lines 958-963)

```powershell
            # [long comment: raw tags are intentionally NOT scrubbed here any more. They
            #  must survive on the in-memory $Global:Resources objects so collectors can
            #  surface them; tag VALUES are then obfuscated deterministically (and tag
            #  KEYS kept) in the per-collector obfuscation loop further below.
            #  $Global:Resources itself is never serialized into the report, so leaving
            #  raw tags on it in memory does not leak.]
        }
    }
```

An earlier version wiped tags off the in memory resources right here, on the reasoning that tags often contain identifying information such as owner names, cost centres and project names.
That was too blunt: it destroyed the tags before any collector could use them, so tags were absent from the report entirely.

The current design defers the decision.
Raw tags stay on the in memory objects, and tag values are tokenised later, per collector, at line 1416 onward.
The safety argument for leaving them raw in memory is stated explicitly and is worth checking, because it is the kind of claim that has to actually be true: `$Global:Resources` is never serialized into the report.
Only collector output is.
So raw tags in that array never reach a file.

## 3c.4 The complete obfuscation picture

```
   DISCOVERY                MINTING (this section)          COLLECTORS
   ─────────                ──────────────────────          ──────────
   Resource Graph           for each resource:              each Services/*.ps1
   returns raw rows   ───►  classify prod/nonprod    ───►   reads $Global:Resources
   into                     mint ID + Name GUIDs            looks up its tokens
   $Global:Resources        reuse sub/RG tokens             emits masked rows
                            commit 4 mappings
                                    │
                                    │  tag values + free text
                                    │  tokenised later, per
                                    ▼  collector (line 1472+)
                            ┌──────────────────────┐
                            │ 6 dictionaries, all  │
                            │ in memory            │
                            └──────────┬───────────┘
                                       │
                     ┌─────────────────┴──────────────────┐
                     ▼                                    ▼
          saved INVERTED to                    used to mask every value
          ObfuscationDictionary_*.json         written into the report
          LOCAL ONLY, never zipped             which IS shipped
          in an obfuscated run
```

The single most important property of that diagram: the dictionary file and the report are never in the same place.
The report is safe to share because the only thing that can reverse it stays on the operator's machine.

---

# Part 4: `ExecuteInventoryProcessing()` (lines 968-2200)

The second top level function.
Setup is done and resources are in memory; this function turns them into structured, optionally masked output.
It contains eight nested functions.

## 4.1 `InitializeInventoryProcessing()` (lines 970-1035)

Nothing but path computation.
Every file the run will ever write is named here, in one place, so no other function has to build a path.

```powershell
    function InitializeInventoryProcessing()
    {
        $Global:ZipOutputFile = ($DefaultPath + $Global:ReportName + "_" + $CurrentDateTime + ".zip")
        $Global:HtmlFile = ($DefaultPath + $Global:ReportName + "_" + $CurrentDateTime + ".html")
        $Global:AllResourceFile = ($DefaultPath + "Full_" + $Global:ReportName + "_" + $CurrentDateTime + ".json")
        $Global:JsonFile = ($DefaultPath + "Inventory_" + $Global:ReportName + "_" + $CurrentDateTime + ".json")
        $Global:MetricsJsonFile = ($DefaultPath + "Metrics_" + $Global:ReportName + "_" + $CurrentDateTime + ".json")
        $Global:ConsumptionFileCsv = ($DefaultPath + "Consumption_" + $Global:ReportName + "_" + $CurrentDateTime + ".csv")
```

| Line | Variable | Contents | Ships in the zip? |
|---|---|---|---|
| 972 | `$Global:ZipOutputFile` | The final bundle | it **is** the bundle |
| 973 | `$Global:HtmlFile` | Self contained HTML report | yes, always |
| 974 | `$Global:AllResourceFile` | Full raw resource dump | no, and it is never even written (see line 1553) |
| 975 | `$Global:JsonFile` | `Inventory_*.json`, the machine readable inventory | yes, always |
| 976 | `$Global:MetricsJsonFile` | `Metrics_*.json` | yes, always, empty if skipped |
| 977 | `$Global:ConsumptionFileCsv` | `Consumption_*.csv` | yes, always, header only if skipped |

`$Global:AllResourceFile` is worth a note: it is computed here and the line that would write it, at 1609, is commented out.
It is a debugging aid someone can re-enable, not part of the normal output.

### The two local only log files (lines 979-1032)

```powershell
        # [long comment: the errors-only log is a LOCAL debug artifact, NEVER added to
        #  the shared zip. Under the wrapper $DefaultPath is a per-subscription
        #  subfolder, so writing it there buries one per sub. Put it in the PARENT
        #  InventoryRoot, tagged with the SubscriptionID, so per-sub error logs are
        #  findable and never collide.]
        if ($RunAllSubs.IsPresent)
        {
            $ErrorLogDir = Split-Path -Path ($Global:DefaultPath.TrimEnd([IO.Path]::DirectorySeparatorChar, '/', '\')) -Parent
            $ErrorLogSubTag = if (![string]::IsNullOrEmpty($SubscriptionID)) { $SubscriptionID } else { $Global:CurrentDateTime }
            $Global:ErrorLogFile = (Join-Path $ErrorLogDir ("ErrorLog_" + $Global:ReportName + "_" + $Global:CurrentDateTime + "_" + $ErrorLogSubTag + ".log"))
        }
        else
        {
            $Global:ErrorLogFile = ($DefaultPath + "ErrorLog_" + $Global:ReportName + "_" + $CurrentDateTime + ".log")
        }
```

| Line | Code | What it does |
|---|---|---|
| 989 | `Split-Path -Path ($Global:DefaultPath.TrimEnd(...)) -Parent` | Goes up one directory. `TrimEnd` first strips any trailing separator, and it strips all three of the platform separator, `/` and `\` so it works regardless of which mix of separators the path was built with. Without the trim, `Split-Path -Parent` on a path ending in a separator returns the same directory rather than its parent. |
| 990 | `$ErrorLogSubTag = if (...) { $SubscriptionID } else { $Global:CurrentDateTime }` | Tag the filename with the subscription so that in a large multi-subscription run you can tell at a glance which subscriptions errored, because only those produce a file. Falls back to the timestamp when there is no subscription ID. |
| 991 | `Join-Path $ErrorLogDir (...)` | The final path, in the parent `InventoryRoot` folder. |

The debug log block at lines 1025-1032 is structurally identical.
The difference between the two files is what goes in them and, importantly, whether they ship.

| File | Contents | In an `-Obfuscate` run | In a default run |
|---|---|---|---|
| `ErrorLog_*.log` | Only messages logged at Error severity | **never** zipped | **never** zipped |
| `DebugLog_*.log` | Per collector heartbeat, metrics phase diagnostics | **never** zipped, local only | **is** zipped, with a warning to the operator |

The `DebugLog_*` posture is the interesting one and the comment in the source spells out the reasoning carefully.
The file is **unscrubbed**: the metrics diagnostics interpolate real service and resource names, and a heartbeat failure line can carry raw exception text which might include a signed URL or a token fragment.

So in an obfuscated run it must never ship, because the entire promise of that bundle is that it contains no real identifiers.
In a default run the report already contains real subscription, resource group and resource names, so the debug log adds no *new* class of identifier, and its heartbeat trace is what makes a thin or partial report diagnosable without a second round trip to the operator.
The operator is told at Warning severity that it is in the bundle.

There is also a belt and braces guard: the JSON sweep that collects files into the zip has a `DebugLog_* -notlike` exclusion in **both** packaging branches, so the only way this file can ever ship is the one deliberate explicit add.

## 4.2 `Test-DataPlaneAuthReady()` (lines 1037-1109)

This function exists to prevent a specific and very expensive failure: a phase that runs to completion and produces zero rows.

### The problem

Both `Get-AzMetric` and `Get-UsageAggregates` **silently return nothing** when the Azure context or token has gone stale.
No exception, no warning, just an empty result.
So a run could take an hour, finish successfully, and hand the operator a report with no metrics and no cost data in it, with nothing anywhere saying why.

Since the caller did not pass `-SkipMetrics` or `-SkipConsumption`, they clearly want that data.
Silently producing none is the worst possible outcome.

### The pattern: detect, recover once, fail loud

```powershell
    function Test-DataPlaneAuthReady([string]$Phase)
    {
        # [long comment: verify a live context + token before a data-plane phase. Both
        #  Get-AzMetric and Get-UsageAggregates silently produce ZERO records when the
        #  context/token is missing. Detect the gap, attempt ONE reconnect using the
        #  SAME auth method the script was invoked with, then re-check. Returns $true
        #  only when a usable token is confirmed. Does NOT introduce a new auth path.]
        $TokenOk = {
            $Ctx = $null
            try { $Ctx = Get-AzContext -ErrorAction Stop } catch { return $false }
            if ($null -eq $Ctx -or $null -eq $Ctx.Account) { return $false }
            try
            {
                $Tok = Get-AzAccessToken -ErrorAction Stop -WarningAction SilentlyContinue
                return ($null -ne $Tok -and -not [string]::IsNullOrWhiteSpace($Tok.Token))
            }
            catch { return $false }
        }

        if (& $TokenOk) { return $true }

        Write-Log -Message ("{0}: no usable Azure context/token detected; attempting one reconnect before collecting {0} data." -f $Phase) -Severity 'Warning'
```

| Line | Code | What it does |
|---|---|---|
| 1037 | `function Test-DataPlaneAuthReady([string]$Phase)` | `$Phase` is just a label, `'Metrics'` or `'Consumption'`, used in the log messages so the operator knows which phase is complaining. |
| 1052 | `$TokenOk = { ... }` | Defines a **script block**, which is PowerShell's anonymous function. Stored in a variable, invoked later with `&`. This avoids writing the same three checks twice, once before the reconnect and once after. |
| 1054 | `try { $Ctx = Get-AzContext -ErrorAction Stop } catch { return $false }` | Is there a context at all. |
| 1055 | `if ($null -eq $Ctx -or $null -eq $Ctx.Account) { return $false }` | A context object can exist but have no account attached, which is not usable. Both conditions are checked. |
| 1058 | `$Tok = Get-AzAccessToken -ErrorAction Stop -WarningAction SilentlyContinue` | The real test. A context is metadata; a **token** is what actually authenticates an API call. This forces a token to be issued or refreshed. |
| 1059 | `return ($null -ne $Tok -and -not [string]::IsNullOrWhiteSpace($Tok.Token))` | The token object must exist **and** contain a non blank token string. `IsNullOrWhiteSpace` rather than `IsNullOrEmpty` catches a token that is technically present but is just spaces. |
| 1064 | `if (& $TokenOk) { return $true }` | Fast path. Auth is fine, do nothing, proceed. |

### The reconnect ladder (lines 1068-1106)

```powershell
        try
        {
            if ($Appid -and $Secret -and $TenantID)
            {
                Write-Log -Message ("{0}: reconnecting via Service Principal." -f $Phase) -Severity 'Info'
                $Credential = New-Object System.Management.Automation.PSCredential($Appid, $Secret)
                Connect-AzAccount -ServicePrincipal -Credential $Credential -Tenant $TenantID -ErrorAction Stop | Out-Null
            }
            elseif ($RunAllSubs.IsPresent)
            {
                Write-Log -Message ("{0}: running under -RunAllSubs without Service Principal credentials - cannot prompt for interactive login in this context. Authenticate before the run (e.g. Connect-AzAccount) or supply -appid/-secret/-tenant." -f $Phase) -Severity 'Error'
                return $false
            }
            elseif (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected)
            {
                # [long comment: no interactive console. An interactive Connect-AzAccount
                #  here would block FOREVER waiting on a browser or device prompt that no
                #  one can answer, which manifests as a silent hang. Fail loud instead.]
                Write-Log -Message ("{0}: no usable Azure context and no interactive console to prompt for login (non-interactive session). Authenticate before the run (Connect-AzAccount) or supply -appid/-secret/-tenant, then re-run." -f $Phase) -Severity 'Error'
                return $false
            }
            elseif ($DeviceLogin.IsPresent)
            {
                Write-Log -Message ("{0}: reconnecting via device login." -f $Phase) -Severity 'Info'
                Connect-AzAccount -UseDeviceAuthentication -ErrorAction Stop | Out-Null
            }
            else
            {
                Write-Log -Message ("{0}: reconnecting via interactive browser login." -f $Phase) -Severity 'Info'
                Connect-AzAccount -ErrorAction Stop | Out-Null
            }
        }
        catch
        {
            Write-Log -Message ("{0}: reconnect attempt failed: {1}" -f $Phase, $_.Exception.Message) -Severity 'Error'
            return $false
        }

        return (& $TokenOk)
    }
```

The order of these branches is the whole design, so read it as a ladder from most automatic to least.

| Order | Line | Condition | Action |
|---|---|---|---|
| 1 | 1081 | Service principal credentials available | Reconnect silently. Always safe, never prompts. |
| 2 | 1087 | Running under the wrapper | **Refuse.** Fail loud. |
| 3 | 1093 | No interactive console | **Refuse.** Fail loud. |
| 4 | 1102 | `-DeviceLogin` was requested | Device code reconnect. |
| 5 | 1107 | otherwise | Interactive browser reconnect. |

Branches 2 and 3 are the ones that matter, and they are refusals rather than attempts.

Branch 2 refuses under the wrapper because the phase may be running inside a background job or a parallel stream where a prompt physically cannot reach the operator.
Branch 3 refuses whenever `[Environment]::UserInteractive` is false or stdin is redirected, which covers CI, a container, a detached process, and an SSM run command.

In both cases an interactive `Connect-AzAccount` would block **forever** on a prompt nobody can see or answer.
A hung run is worse than a failed run: a failure tells you what to fix, a hang just burns time and eventually gets killed with no diagnosis.
So the code chooses a loud, immediate, actionable error instead, and both messages name the two concrete remediations.

| Line | Code | What it does |
|---|---|---|
| 1102-1106 | the `catch` | The reconnect itself threw. Log the actual exception and return false. |
| 1108 | `return (& $TokenOk)` | Re-run the same check. Reconnecting is not the same as succeeding, so the result is **verified** rather than assumed. This is the point of having `$TokenOk` in a variable. |

The overall shape here is worth remembering as a pattern: **detect the gap, attempt exactly one targeted recovery using the auth method already in use, then verify, and if it still fails, fail loud and skip only that one phase** so the rest of the inventory still completes.

## 4.3 `CreateMetricsJob()` (lines 1111-1185)

```powershell
    function CreateMetricsJob()
    {
        Write-Log -Message ('Checking if Metrics Job Should be Run.') -Severity 'Info'

        if (!$SkipMetrics.IsPresent)
        {
            # [long comment: -SkipMetrics was NOT passed, so the user wants metrics.
            #  Get-AzMetric runs in parallel runspaces and returns ZERO data silently if
            #  the context/token is missing. Detect + attempt recovery; if it still
            #  cannot authenticate, fail loud and skip ONLY this phase. The end-of-script
            #  empty-metrics-JSON fallback keeps the bundle structurally valid. This is
            #  intentionally NOT a silent skip.]
            if (-not (Test-DataPlaneAuthReady -Phase 'Metrics'))
            {
                Write-Log -Message ('Metrics: SKIPPED - could not establish a usable Azure context/token after one reconnect attempt. [...] The rest of the inventory will continue.') -Severity 'Error'

                $Global:AzMetrics = New-Object PSObject
                $Global:AzMetrics | Add-Member -MemberType NoteProperty -Name Metrics -Value NotSet
                $Global:AzMetrics.Metrics = [System.Collections.Concurrent.ConcurrentBag[psobject]]::new()

                # [long comment: record per-subscription metrics health so the wrapper's
                #  final summary can name exactly which subs are missing metrics. Mirrors
                #  $Global:ConsumptionFailedSubs.]
                if ($null -eq $Global:MetricsFailedSubs) { $Global:MetricsFailedSubs = @() }
                $MetricsSkipMsg = 'Metrics phase skipped: no usable Azure context/token after one reconnect attempt.'
                $AffectedSubs = @(
                    if (![string]::IsNullOrEmpty($SubscriptionID))
                    {
                        $Global:Subscriptions | Where-Object { $_.id -eq $SubscriptionID }
                    }
                    else
                    {
                        $Global:Subscriptions
                    }
                )
                if ($AffectedSubs.Count -eq 0)
                {
                    # [comment: fallback when the sub list is unavailable - still record
                    #  one entry so the failure is never silent]
                    $IdLabel = if (![string]::IsNullOrEmpty($SubscriptionID)) { $SubscriptionID } else { '(unknown)' }
                    $Global:MetricsFailedSubs += [pscustomobject]@{ Name = '(subscription)'; Id = $IdLabel; Message = $MetricsSkipMsg }
                }
                else
                {
                    foreach ($asub in $AffectedSubs)
                    {
                        $Global:MetricsFailedSubs += [pscustomobject]@{ Name = $asub.Name; Id = $asub.Id; Message = $MetricsSkipMsg }
                    }
                }
                return
            }
```

### The auth failure path

| Line | Code | What it does |
|---|---|---|
| 1115 | `if (!$SkipMetrics.IsPresent)` | Only do any of this if metrics were actually requested. |
| 1124 | `if (-not (Test-DataPlaneAuthReady -Phase 'Metrics'))` | Auth could not be established. |
| 1126 | the `Error` severity log | Note the severity. This is not a warning, because the operator asked for data they are not getting. It also states the two remediations and explicitly promises the rest of the inventory continues, so the operator is not left wondering whether the whole run is dead. |
| 1128-1130 | building an empty `$Global:AzMetrics` | Creates the object with a `Metrics` property holding an **empty** `ConcurrentBag`. This is what keeps the downstream code from having to special case a missing metrics phase: everything after this point just reads an empty collection. `ConcurrentBag` is the thread safe collection type used because the real metrics path fills it from parallel runspaces. |
| 1139 | `if ($null -eq $Global:MetricsFailedSubs) { $Global:MetricsFailedSubs = @() }` | Lazily initialise the health list. It has to be lazy because this script is invoked with `&` from the wrapper, so the variable lives in the wrapper's scope and persists across subscriptions. |
| 1141-1152 | `$AffectedSubs = @( if (...) {...} else {...} )` | Works out which subscriptions this skip applies to. The wrapper passes `-SubscriptionID`, so it is that one; a standalone all subscriptions run means every in scope subscription. Note the `if` is used as an expression **inside** the array subexpression `@(...)`, which is a compact PowerShell idiom for conditional array construction. |
| 1153-1159 | the `$AffectedSubs.Count -eq 0` fallback | If even the subscription list is unavailable, still record **one** entry, labelled `(unknown)`. The comment states the principle: the failure must never be silent. This is a good habit to notice, since it is the error path of an error path and would be easy to leave empty. |
| 1162-1165 | the `foreach` | One health record per affected subscription, each a `[pscustomobject]` with `Name`, `Id` and `Message`. |
| 1166 | `return` | Leave the function. Metrics are skipped, everything else continues. |

That health list is not decoration.
`Run-AllSubscriptions.Stream.ps1` aggregates it across parallel streams and `Run-AllSubscriptions.ps1` prints it, per subscription, in the final run summary.
So a metrics auth failure on subscription 87 of 125 is named explicitly at the end of the run rather than being something the operator has to notice by spotting a thin report.

### The success path (lines 1168-1183)

```powershell
            Write-Log -Message ('Running Metrics Jobs') -Severity 'Success'

            if ($PSScriptRoot -like '*\*')
            {
                $MetricPath = Get-ChildItem -Path ($PSScriptRoot + '\Extension\Metrics.ps1') -Recurse
            }
            else
            {
                $MetricPath = Get-ChildItem -Path ($PSScriptRoot + '/Extension/Metrics.ps1') -Recurse
            }

            $MetricsFilePath = ($DefaultPath + "Metrics_" + $Global:ReportName + "_" + $CurrentDateTime + "_")

            $Global:AzMetrics = New-Object PSObject
            $Global:AzMetrics | Add-Member -MemberType NoteProperty -Name Metrics -Value NotSet
            $Global:AzMetrics.Metrics = & $MetricPath -Subscriptions $Subscriptions -Resources $Resources -Task "Processing" ... (see below)
        }
    }
```

| Line | Code | What it does |
|---|---|---|
| 1170-1177 | `if ($PSScriptRoot -like '*\*')` | Detects Windows by asking whether the script's own path contains a backslash, then builds the path with matching separators. This is a slightly crude way to do it; `Join-Path` would handle it without the branch. It works, and it appears in several places in this file. |
| 1179 | `$MetricsFilePath = (... + "Metrics_" + ... + "_")` | Note the **trailing underscore**. This is a filename *prefix*, not a complete filename, because the metrics extension writes its output in numbered chunks: `Metrics_ResourcesReport_<stamp>__1.json`, `__2.json` and so on. Chunking keeps any single JSON file small enough to parse. |
| 1181-1182 | `New-Object PSObject` plus `Add-Member ... -Value NotSet` | Builds a container object with one property. `NotSet` here is not a keyword or a null; it is an unquoted bare string placeholder that is immediately overwritten on the next line. |
| 1183 | `$Global:AzMetrics.Metrics = & $MetricPath -Subscriptions ... ` | Invokes `Extension/Metrics.ps1` with `&`, the call operator, and captures what it returns. |

Line 1183 is a single very long line and it is where all the metrics parameters get forwarded.

| Argument group | What is passed | Note |
|---|---|---|
| Data | `-Subscriptions`, `-Resources` | The already discovered resources are reused; the extension does no discovery of its own |
| Output | `-FilePath $MetricsFilePath` | The chunk filename prefix |
| Concurrency | `-ConcurrencyLimit` | How many parallel runspaces |
| Obfuscation | four dictionaries plus `-Obfuscate` | Each passed as `$(if ($Obfuscate.IsPresent) { $Dict } else { $null })` |
| Volume controls | `-UseMetricsBatch:`, `-IncludeStorageMetrics:`, `-SkipDiskMetrics:`, `-MetricsIntervalMinutes` | Forwarded straight from this script's parameters. There is no public `-SkipStorageMetrics` - see 2.2 |
| Window | `-MetricsLookbackDays` | How far back to query |

Two syntax details on that line are worth learning:

- `$(if ($Obfuscate.IsPresent) { $ResourceIdDictionary } else { $null })` is a subexpression whose value becomes the argument. On a non obfuscated run the extension receives `$null` for all four dictionaries, which is how it knows not to mask.
- `-UseMetricsBatch:$UseMetricsBatch` with an explicit **colon** is how you forward a switch's value rather than just turning it on. Writing `-UseMetricsBatch $UseMetricsBatch` without the colon would pass the value as a positional argument instead, and the switch would be on unconditionally. This is a genuinely common PowerShell bug and this line gets it right.

## 4.4 `ProcessMetricsResult()` (lines 1187-1224)

Despite the name, this function collects no results.
By the time it runs, `Extension/Metrics.ps1` has already returned and written its chunk files.
What this does is force a garbage collection and record a memory snapshot.

```powershell
    function ProcessMetricsResult()
    {
        if (!$SkipMetrics.IsPresent)
        {
            # [long comment: managed-heap + working-set snapshot around the post-metrics
            #  GC, routed to the debug log only. Under the wrapper each subscription runs
            #  in the SAME long-lived process, so comparing these lines across
            #  subscriptions shows whether the footprint is a stable high-water mark or
            #  is creeping (a real leak) over a large tenant. GetTotalMemory is the
            #  GC-managed heap only; WorkingSet64 is the fuller process RSS. Wrapped
            #  defensively: a diagnostic line must never abort a subscription whose
            #  metrics already succeeded. The GC.Collect() stays OUTSIDE the try so
            #  collection happens even if the measurement hiccups.]
            [System.GC]::Collect()
            try
            {
                $MemHeapBeforeMB = [math]::Round([System.GC]::GetTotalMemory($false) / 1MB, 1)
                $MemHeapAfterMB = [math]::Round([System.GC]::GetTotalMemory($true) / 1MB, 1)
                $MemWorkingSetMB = [math]::Round([System.Diagnostics.Process]::GetCurrentProcess().WorkingSet64 / 1MB, 1)
                Write-Log -Message ('[Memory] Post-metrics GC: managed heap {0} MB -> {1} MB after collect; process working set {2} MB.' -f $MemHeapBeforeMB, $MemHeapAfterMB, $MemWorkingSetMB) -Severity 'Info' -NoConsole -ToDebugLog
            }
            catch
            {
                Write-Log -Message ('[Memory] Post-metrics memory snapshot unavailable: {0}' -f $_.Exception.Message) -Severity 'Info' -NoConsole -ToDebugLog
            }
        }
    }
```

| Line | Code | What it does |
|---|---|---|
| 1211 | `[System.GC]::Collect()` | Forces a full .NET garbage collection. Normally you should not do this and let the runtime decide, but the metrics phase has just allocated a very large amount of short lived data across parallel runspaces, and under the wrapper this same process will go on to process many more subscriptions. Reclaiming now keeps the footprint flat instead of climbing. |
| 1211 | `[System.GC]::GetTotalMemory($false) / 1MB` | Managed heap size **without** forcing a collection first. `1MB` is a PowerShell numeric literal suffix equal to 1048576, so the division converts bytes to megabytes. `[math]::Round(..., 1)` gives one decimal place. |
| 1211 | `[System.GC]::GetTotalMemory($true)` | The `$true` argument means "wait for a full collection to finish, then measure". So lines 1214 and 1215 together give a before and after pair. |
| 1216 | `[System.Diagnostics.Process]::GetCurrentProcess().WorkingSet64` | The process's actual resident memory as the OS sees it, which is a broader number than the managed heap because it includes large object heap pages that .NET has not returned to the OS. |
| 1217 | `Write-Log ... -NoConsole -ToDebugLog` | Two custom switches on this project's `Write-Log`. `-NoConsole` keeps it off the terminal, `-ToDebugLog` sends it to `$Global:DebugLogFile`. So this is diagnostic only and never clutters the operator's screen. |
| 1219-1222 | the `catch` | Also logs at `Info` severity, because a missing diagnostic is not an error. |

Two deliberate structural choices here that are good habits:

- The `GC.Collect()` is **outside** the `try`. If the measurement code fails, the collection still happens, because the collection is the useful part and the measurement is only observability.
- The measurements are assigned to variables and then formatted, rather than being emitted bare. A bare expression in PowerShell goes onto the output pipeline, and since this function's output is not captured, a bare value would leak into whatever the caller was accumulating.

The comment also answers "why measure at all". Under the wrapper, every subscription runs in the same long lived process, so lining these log lines up across a long multi-subscription run is how you tell a stable high water mark apart from a genuine leak.

## 4.5 `CreateResourceJobs()` (lines 1226-1538)

The heart of the script.
This is where the roughly 60 files under `Services/` are found and run, one per Azure resource type, and where their output is masked and merged.

### Overall shape

```
  find all Services/*.ps1                        lines 1288-1296
            │
  optional -Service filter + warnings            lines 1309-1361
            │
  set up circuit breaker + progress counters     lines 1381-1419
            │
  ┌─────────  for each collector  ───────────────────────────────┐
  │  Write-Progress bar + heartbeat START                        │
  │  try   { run the collector, reset failure counter, DONE }    │
  │  catch { count it, record health, log LOUD, maybe trip the   │
  │          circuit breaker, set $Result = @() }                │
  │  if -Obfuscate: mask every row of $Result                    │
  │  attach $Result to $Global:SmaResources.<CollectorName>      │
  │  free $Result, force a GC                                    │
  └──────────────────────────────────────────────────────────────┘
            │
  complete the progress bar + heartbeat          lines 1591-1593
```

### Finding the collectors (lines 1228-1240)

```powershell
    function CreateResourceJobs()
    {
        $Global:SmaResources = New-Object PSObject

        Write-Log -Message ('Starting Service Processing Jobs.') -Severity 'Info'

        if ($PSScriptRoot -like '*\*')
        {
            $Modules = Get-ChildItem -Path ($PSScriptRoot + '\Services\*.ps1') -Recurse
        }
        else
        {
            $Modules = Get-ChildItem -Path ($PSScriptRoot + '/Services/*.ps1') -Recurse
        }
```

| Line | Code | What it does |
|---|---|---|
| 1228 | `$Global:SmaResources = New-Object PSObject` | The accumulator for the whole inventory. It starts as a bare object with no properties, and one property is added per collector as the loop runs. This object is what gets serialized to `Inventory_*.json`. |
| 1232-1240 | the platform branch plus `Get-ChildItem ... -Recurse` | Finds every `.ps1` under `Services/`. `-Recurse` is what lets them be organised into the eight category subfolders. Note that the collectors are discovered **by convention**, not from a list: dropping a new file into `Services/Compute/` makes it run, with no registration step anywhere. |

### The `-Service` filter (lines 1253-1305)

```powershell
        if ($Service -and @($Service).Count -gt 0)
        {
            $AvailableServices = @($Modules | ForEach-Object { $_.BaseName } | Sort-Object)
            $Modules = @($Modules | Where-Object { $_.BaseName -in $Service })

            if (@($Modules).Count -eq 0)
            {
                Write-Log -Message ("-Service matched no collectors. Requested: [{0}]. Available: [{1}]." -f ($Service -join ', '), ($AvailableServices -join ', ')) -Severity 'Error'
                throw ("-Service matched no collectors. Requested: [{0}]." -f ($Service -join ', '))
            }

            $MatchedNames = @($Modules | ForEach-Object { $_.BaseName } | Sort-Object)
            Write-Log -Message ("-Service filter active: collecting {0} of {1} collectors: [{2}]" -f @($Modules).Count, @($AvailableServices).Count, ($MatchedNames -join ', ')) -Severity 'Info'
```

| Line | Code | What it does |
|---|---|---|
| 1253 | `if ($Service -and @($Service).Count -gt 0)` | Two conditions, because `$Service` could be null or could be an empty array. `@(...)` normalises to an array before counting. |
| 1255 | `@($Modules \| ForEach-Object { $_.BaseName } \| Sort-Object)` | The names of every available collector, captured **before** filtering, so the error message can list what the operator could have asked for. `BaseName` is the filename without extension, so `VirtualMachines.ps1` becomes `VirtualMachines`. |
| 1256 | `@($Modules \| Where-Object { $_.BaseName -in $Service })` | The filter itself. `-in` is case insensitive by default, so `-Service virtualmachines` matches `VirtualMachines.ps1`. |
| 1258-1262 | the zero match case | `throw`s rather than continuing. This is a good decision: a name that matches nothing is almost always a typo, and continuing would produce a structurally valid but completely **empty** inventory that looks like "this subscription has nothing in it". Failing loud makes the operator notice before shipping a wrong report. The error message lists every available name, which turns a dead end into a self service fix. |

### The advisory warning (lines 1280-1298)

```powershell
            # [long comment: -Service scopes the INVENTORY phase only; metrics and
            #  consumption still run for the WHOLE subscription. Warn, do NOT enforce,
            #  because the recovery recipe that re-collects metrics/consumption for a
            #  later Merge-RecoveryData INTENTIONALLY runs -Service WITHOUT the skips.
            #  Name ONLY the phases still subscription-wide, and suggest ONLY the
            #  switch(es) not already supplied.]
            $UnscopedPhases = @()
            $SuggestedSkips = @()

            if (-not $SkipMetrics.IsPresent)
            {
                $UnscopedPhases += 'metrics'
                $SuggestedSkips += '-SkipMetrics'
            }

            if (-not $SkipConsumption.IsPresent)
            {
                $UnscopedPhases += 'consumption'
                $SuggestedSkips += '-SkipConsumption'
            }

            if (@($UnscopedPhases).Count -gt 0)
            {
                Write-Log -Message ("-Service scopes the INVENTORY phase only; these phases still run for the WHOLE subscription: {0}. For a clean inventory-only run add {1}. [...]") -Severity 'Warning'
            }
```

This exists because `-Service` is easy to misunderstand.
It scopes the **inventory** phase only.
Metrics and consumption keep their own `-Skip*` switches and, unless you pass those too, they still run across the whole subscription.
So `-Service VirtualMachines` on its own is not the fast targeted run people expect; it still spends the metrics and billing time.

The implementation is more careful than it first looks, and the care is the interesting part.

| Behaviour | Why |
|---|---|
| It warns, it does not enforce | The documented recovery recipe deliberately runs `-Service X` *without* the skips, in order to re-pull metrics or consumption for a later `Merge-RecoveryData`. Enforcing the skips would break that supported workflow. |
| It builds the message from two parallel arrays | So it names **only** the phases that are genuinely still unscoped, and suggests **only** the switches not already supplied. |
| The whole message is suppressed when both skips are present | Because then there is nothing to warn about. |

The consequence is that `-Service X -SkipMetrics` is told that only consumption is still subscription wide, and is told to add only `-SkipConsumption`.
It is not told metrics still run, and it is not told to add a switch it already passed.
Advice that tells you something you already did is advice people stop reading, so this is worth the extra ten lines.

| Line | Code | What it does |
|---|---|---|
| 1300 | `$UnmatchedServices = @($Service \| Where-Object { $_ -notin $MatchedNames })` | A separate check from the zero match case at 1314. Handles the **partial** match: `-Service VirtualMachines,VirtualMachinez` runs the first and warns that the second was ignored. Without this, the typo would be silently dropped and the operator would think both ran. |

### The circuit breaker (lines 1309-1326)

```powershell
        $Resource = $Resources
        #$Resource = ($Resource | ConvertTo-Json -Depth 50)

        # [long comment: circuit breaker for collector failures (#22). A single
        #  collector throwing must not silently drop that resource type NOR abort the
        #  whole run - it is recorded loudly and processing continues. But if MANY
        #  collectors fail in a row, the cause is almost never "this one resource type
        #  has a bug" - it is systemic (auth dropped mid-run, network gone, Az module
        #  broken) and every remaining collector is about to fail identically. Limping
        #  through would produce ~50 more identical error lines and an empty report that
        #  looks like "no resources" instead of "the environment broke partway through".]
        $ConsecutiveCollectorFailures = 0
        $CollectorFailureCircuitBreakerThreshold = 5
```

This is one of the better designed pieces of error handling in the script, because it distinguishes two genuinely different situations that look the same at the individual failure level.

| Situation | Cause | Right response |
|---|---|---|
| One collector fails | A null property, a malformed API response, a bug in that one file | Record it loudly, continue. The other 59 resource types are still worth collecting. |
| Five collectors fail in a row | Auth dropped mid run, network gone, Az module broken | **Stop.** Every remaining collector is about to fail for the same reason. |

The reasoning for the threshold, stated in the comment, is about the operator's experience.
Limping through 60 failing collectors produces a wall of 60 near identical error lines and an empty report that looks like an empty environment.
Stopping at five produces **one** clear diagnosis of a systemic problem.
One good error beats sixty repeated ones.

### The collector loop (lines 1365-1414)

```powershell
        $ModuleTotal = @($Modules).Count
        $ModuleIndex = 0

        $HeartbeatSubLabel = if (![string]::IsNullOrEmpty($SubscriptionID)) { $SubscriptionID } else { '(all in-scope subscriptions)' }
        # [long comment: the per-collector heartbeat goes through the shared logger with
        #  -NoConsole (no per-collector console spam - that green line x40+ per sub
        #  scrolled real errors off screen) + -ToDebugLog. -ToDebugLog is a silent no-op
        #  when no debug-log path exists and never throws, so a write failure can never
        #  break collection.]
        Write-Log -Message ("Service processing started for {0}: {1} collectors" -f $HeartbeatSubLabel, $ModuleTotal) -NoConsole -ToDebugLog

        foreach ($Module in $Modules)
        {
            $ModName = $Module.Name.Substring(0, $Module.Name.length - ".ps1".length)
            $ModuleIndex++

            # [long comment: -BarOnly keeps the pre-existing behavior for this
            #  high-frequency loop inside non-interactive stream workers: the bar renders
            #  interactively and is a no-op otherwise, with NO per-collector stdout line]
            Write-RdaProgress -Activity 'Service Processing' -CurrentItem $ModName -Index $ModuleIndex -Total $ModuleTotal -BarOnly

            Write-Log -Message ("START ({0}/{1}) {2}" -f $ModuleIndex, $ModuleTotal, $ModName) -NoConsole -ToDebugLog

            try
            {
                $Result = & $Module -Sub $Subscriptions -Resources $Resource -Task "Processing" -ResourceIdDictionary $(if ($Obfuscate.IsPresent) { $ResourceIdDictionary } else { $null })
                $ConsecutiveCollectorFailures = 0

                Write-Log -Message ("DONE  ({0}/{1}) {2}" -f $ModuleIndex, $ModuleTotal, $ModName) -NoConsole -ToDebugLog
            }
            catch
            {
                $ConsecutiveCollectorFailures++

                Write-Log -Message ("FAIL  ({0}/{1}) {2}: {3}" -f $ModuleIndex, $ModuleTotal, $ModName, $_.Exception.Message) -NoConsole -ToDebugLog

                if ($null -eq $Global:CollectorFailures) { $Global:CollectorFailures = @() }
                $Global:CollectorFailures += [pscustomobject]@{
                    Id      = $SubscriptionID
                    Module  = $ModName
                    Message = $_.Exception.Message
                }

                Write-Log -Message ("Collector FAILED: {0}: {1}" -f $ModName, $_.Exception.Message) -Severity 'Error'
                Write-Log -Message ("The rest of the inventory will continue, but the '{0}' resource type is MISSING from this report - not empty because there are none, but because the collector errored. [...]" -f $ModName) -Severity 'Error'

                if ($ConsecutiveCollectorFailures -ge $CollectorFailureCircuitBreakerThreshold)
                {
                    throw ("Stopping: {0} collectors failed in a row (most recently '{1}': {2}). This pattern indicates a systemic problem [...]")
                }

                # [long comment: $result must still become a defined empty array so
                #  $Global:SmaResources.$ModName is a valid (empty) JSON array rather
                #  than an absent/undefined member.]
                $Result = @()
            }
```

| Line | Code | What it does |
|---|---|---|
| 1367 | `$ModName = $Module.Name.Substring(0, $Module.Name.length - ".ps1".length)` | Strips the `.ps1` extension the long way round. `$Module.BaseName` does exactly this and is used elsewhere in the same function, at line 1255. Harmless duplication. |
| 1375 | `Write-RdaProgress ... -BarOnly` | The project's own progress helper. `-BarOnly` means render the interactive bar but emit **no** text line. That matters because `Write-Progress` is a silent no op in non interactive hosts, which is exactly where the wrapper runs collectors, so a text line would end up in every transcript 60 times per subscription. |
| 1377 | `Write-Log ("START ({0}/{1}) {2}" ...) -NoConsole -ToDebugLog` | The heartbeat. Not on the console, only in the debug log. |
| 1381 | `$Result = & $Module -Sub ... -Resources ... -Task "Processing" -ResourceIdDictionary ...` | **The actual collector call.** Four named arguments, and this is the fixed contract every collector in `Services/` implements: `-Sub`, `-Resources`, `-Task`, `-ResourceIdDictionary`. Every collector gets the same four and returns an array of flat objects. |
| 1382 | `$ConsecutiveCollectorFailures = 0` | Reset on success. This is what makes the counter measure *consecutive* failures rather than total. |
| 1388 | `$ConsecutiveCollectorFailures++` | Increment on failure. |
| 1393-1397 | `$Global:CollectorFailures += [pscustomobject]@{ Id; Module; Message }` | Structured health record, same lazy initialisation pattern as `$Global:MetricsFailedSubs`. Aggregated across streams and surfaced in the wrapper's final summary, and it drives dedicated wrapper exit codes: 3 for an auth skip, 4 for collector failures, 5 for both. |
| 1399-1400 | two `Error` severity logs | The second one is the one to read. It says the resource type is **missing from this report, not empty because there are none**. That distinction is the entire reason this logging exists: a silently absent collector and a genuinely empty resource type look identical in the output, and only one of them is a problem. |
| 1402-1405 | the circuit breaker `throw` | Trips at five. The message names the count, the last collector, its error, the three likely systemic causes, why continuing is worse than stopping, and the total failure count across the whole run so far. |
| 1413 | `$Result = @()` | Critical and easy to miss. Without it, `$Result` would still hold the **previous** collector's output, exactly the aliasing bug described in the discovery section, and that data would be filed under the wrong resource type. Setting it to an explicit empty array also means `$Global:SmaResources.<Name>` exists as an empty JSON array rather than being absent, so downstream parsers see zero rows rather than a missing property. |

### Per row obfuscation (lines 1416-1517)

Now the collector's output rows get masked.
Note this is a **second** obfuscation pass: Part 3c minted the tokens against the raw discovered resources, and this applies them to the flattened collector output.

```powershell
            if ($Obfuscate.IsPresent)
            {
                foreach ($resourceItem in $Result)
                {
                    $OrigID = $resourceItem.ID

                    # [long comment: a null/empty ID would throw on the dictionary key
                    #  ASSIGNMENT below (Dictionary[string,string] rejects a null key with
                    #  "the array index evaluated to null"). Give the row a
                    #  deterministic-within-run fallback and skip the lookups so one
                    #  malformed collector row cannot abort processing.]
                    if ([string]::IsNullOrEmpty($OrigID))
                    {
                        $Fallback = 'obfuscated_' + [guid]::NewGuid().ToString()
                        $resourceItem.ID = $Fallback
                        $resourceItem.Name = $Fallback
                        $resourceItem.Subscription = $Fallback
                        $resourceItem.ResourceGroup = $Fallback
                        # [comment: still scrub tags before skipping - a malformed null-ID
                        #  row must not carry real tag values into the obfuscated output
                        #  just because it bypassed the dictionary path below]
                        if ($resourceItem.ContainsKey('tags')) { $resourceItem.tags = $null }
                        if ($resourceItem.ContainsKey('Tags')) { $resourceItem.Tags = $null }
                        continue
                    }
```

| Line | Code | What it does |
|---|---|---|
| 1420 | `$OrigID = $resourceItem.ID` | Save the real ID, because it is about to be overwritten and is still needed as the dictionary key for the other three lookups. |
| 1427 | `if ([string]::IsNullOrEmpty($OrigID))` | A collector can emit a row with no ID, from a malformed API response or an edge case in that collector. This must not crash the run: `Dictionary[string,string]` rejects a null key with the confusing message "the array index evaluated to null". |
| 1429-1433 | assign the same `$Fallback` to all four fields | The row survives, masked, and is clearly identifiable as anomalous by its `obfuscated_` prefix rather than `prod_` or `nonprod_`. |
| 1437-1438 | scrub `tags` and `Tags` before `continue` | The security relevant line, and a genuinely good catch. This row is about to `continue` and skip the normal tag tokenisation path below, so without these two lines it would carry **real** tag values straight into the obfuscated output. Both casings are checked because collectors are inconsistent about which they emit. |
| 1439 | `continue` | Skip to the next row. |

Then the four identical lookup blocks, one per field:

```powershell
                    if ($ResourceIdDictionary.ContainsKey($OrigID))
                    {
                        $ObfuscatedID = $ResourceIdDictionary[$OrigID]
                        if ([string]::IsNullOrEmpty($ObfuscatedID)) { $ObfuscatedID = 'obfuscated_' + [guid]::NewGuid().ToString() }
                        $resourceItem.ID = $ObfuscatedID
                    }
                    else
                    {
                        $Prefix = if ($OrigID -match '\b(dev|test|qa|tst|development|non-prod|uat|nonprod)\b' -or $OrigID -match '(^|-)([dts])-') { "nonprod_" } else { "prod_" }
                        $Fallback = $Prefix + [guid]::NewGuid().ToString()
                        $ResourceIdDictionary[$OrigID] = $Fallback
                        $resourceItem.ID = $Fallback
                    }

                    $Prefix = $resourceItem.ID.Split('_')[0] + '_'
```

Each of the four blocks follows the same three step shape.

| Step | Code | Purpose |
|---|---|---|
| Look up | `if ($Dict.ContainsKey($OrigID))` | The normal path. The token was minted in Part 3c. |
| Guard | `if ([string]::IsNullOrEmpty($X)) { $X = 'obfuscated_' + guid }` | Defence against a present-but-blank dictionary value, which would otherwise blank a field in the report. |
| Mint | the `else` branch | The ID was never seen during discovery, so mint a token now **and store it**, keeping determinism for any later row with the same ID. |

The `else` branch can genuinely happen: a collector can synthesise child rows that were never returned by Resource Graph, such as one row per AKS node pool or one row per container in a container group.

| Line | Code | What it does |
|---|---|---|
| 1456 | `$Prefix = $resourceItem.ID.Split('_')[0] + '_'` | Clever and worth understanding. The ID has just been masked, so it now looks like `prod_<guid>`. Splitting on `_` and taking element 0 recovers `prod`, and appending `_` reconstructs the prefix. This means the Name, Subscription and ResourceGroup fallbacks below **inherit the same prod or nonprod classification** as the ID, rather than re-deriving it from a different string and possibly disagreeing. |

### Tag value tokenisation (lines 1497-1517)

```powershell
                    # [long comment: collector 'Tags' output is an array of { Name, Value }.
                    #  Keep the KEY (Name) verbatim and obfuscate the VALUE
                    #  deterministically via $Global:TagValueDictionary: the same real
                    #  value always maps to the same token, so the obfuscated report can
                    #  still group and correlate by tag value without exposing it. Prefix
                    #  is derived from the value so an environment-type signal survives.]
                    if ($resourceItem.ContainsKey('Tags') -and $null -ne $resourceItem.Tags)
                    {
                        foreach ($Tag in $resourceItem.Tags)
                        {
                            if ($null -ne $Tag -and -not [string]::IsNullOrEmpty([string]$Tag.Value))
                            {
                                $RealTagValue = [string]$Tag.Value
                                if (-not $Global:TagValueDictionary.ContainsKey($RealTagValue))
                                {
                                    $TagPrefix = if ($RealTagValue -match '\b(dev|test|qa|tst|development|non-prod|uat|nonprod)\b' -or $RealTagValue -match '(^|-)([dts])-') { 'nonprod_' } else { 'prod_' }
                                    $Global:TagValueDictionary[$RealTagValue] = $TagPrefix + [guid]::NewGuid().ToString()
                                }
                                $Tag.Value = $Global:TagValueDictionary[$RealTagValue]
                            }
                        }
                    }
```

This is the payoff for the decision back at line 958 not to wipe tags during discovery.

| What | Treatment | Why |
|---|---|---|
| Tag **key**, for example `CostCentre` | kept **verbatim** | Keys are organisational vocabulary, not customer data, and keeping them is what makes the masked report analysable at all |
| Tag **value**, for example `Finance-EMEA` | tokenised deterministically | Values routinely contain owner names, project names and cost centres |

Because the tokenisation is deterministic, every resource tagged `CostCentre = Finance-EMEA` gets the same token.
So the recipient of a masked report can still answer "how many VMs share a cost centre" and "which cost centre is the largest", without ever learning what any cost centre is called.
That is a much better outcome than the earlier behaviour of dropping tags entirely.

| Line | Code | What it does |
|---|---|---|
| 1503 | `if ($resourceItem.ContainsKey('Tags') -and $null -ne $resourceItem.Tags)` | Both checks needed: the property might be absent, or present and null. |
| 1507 | `-not [string]::IsNullOrEmpty([string]$Tag.Value)` | The `[string]` cast handles a non string tag value, since Azure tag values can arrive as numbers or booleans. |
| 1510-1513 | `if (-not $Global:TagValueDictionary.ContainsKey(...))` then mint | Same lookup-before-mint determinism pattern as everywhere else. |
| 1515 | `$Tag.Value = $Global:TagValueDictionary[$RealTagValue]` | Mutates the row **in place**. This works because `$Tag` is a reference to the object inside `$resourceItem.Tags`. |

### Filing the result (lines 1522-1532)

```powershell
            $Global:SmaResources | Add-Member -MemberType NoteProperty -Name $ModName -Value NotSet
            # [long comment: wrap with @() so the JSON serializer ALWAYS emits an array,
            #  even when the collector returns exactly one resource. Without this,
            #  PowerShell unwraps a single-element pipeline result into a scalar
            #  PSCustomObject, ConvertTo-Json emits {...} instead of [{...}], and
            #  downstream parsers that iterate the resource type as an array silently
            #  see ZERO rows.]
            $Global:SmaResources.$ModName = @($Result)

            $Result = $null
            [System.GC]::Collect()
        }
```

| Line | Code | What it does |
|---|---|---|
| 1522 | `Add-Member -MemberType NoteProperty -Name $ModName -Value NotSet` | Adds a property to the accumulator named after the collector, so `Inventory_*.json` ends up with a top level key per resource type. `NotSet` is a throwaway placeholder overwritten on the next line. |
| 1529 | `$Global:SmaResources.$ModName = @($Result)` | The `@()` wrapper is the important part, and the comment explains a real bug worth internalising as a general PowerShell lesson. |
| 1531 | `$Result = $null` | Release the reference so the collection below can actually reclaim it. |
| 1532 | `[System.GC]::Collect()` | A full GC after **every** collector. Aggressive, but a single collector on a large tenant can produce tens of thousands of objects, and there are dozens of them, followed by many more subscriptions in the same process. |

### The `@()` bug, spelled out

This one catches nearly everyone who writes PowerShell that produces JSON.

| Number of results | Without `@()` | With `@()` |
|---|---|---|
| 0 | `null` | `[]` |
| 1 | `{ "Name": "vm-01" }` | `[ { "Name": "vm-01" } ]` |
| 2 or more | `[ {...}, {...} ]` | `[ {...}, {...} ]` |

PowerShell unwraps a single element pipeline result into a scalar.
`ConvertTo-Json` then faithfully serializes that scalar as a JSON **object** instead of a one element **array**.
A downstream parser that iterates the resource type as an array now sees zero rows, silently.

The failure is invisible until a subscription happens to have exactly one of something.
So it would pass every test on a large estate and break on a small one.
Wrapping in `@()` costs nothing and removes the entire class of bug.

## 4.6 `ProcessResourceResult()` (lines 1540-1556)

```powershell
    function ProcessResourceResult()
    {
        Write-Log -Message ("Starting Reporting Phase.") -Severity 'Info'

        # [long comment: the Inventory JSON is the report's single source of truth. It is
        #  built entirely from $Global:SmaResources, which CreateResourceJobs already
        #  populated. The HTML report renders from this JSON. There is no per-collector
        #  Excel-writing pass any more - the Excel/EPPlus dependency has been removed.]
        $Global:SmaResources | Add-Member -MemberType NoteProperty -Name 'Version' -Value NotSet
        $Global:SmaResources.Version = $Global:Version

        $Global:SmaResources | ConvertTo-Json -depth 100 -compress | Out-File $Global:JsonFile
        #$Global:Resources | ConvertTo-Json -depth 100 -compress | Out-File $Global:AllResourceFile

        Write-Log -Message ('Resource Reporting Phase Done.') -Severity 'Info'
    }
```

Short, and it produces the single most important artifact in the whole run.

| Line | Code | What it does |
|---|---|---|
| 1548-1549 | add a `Version` property | Stamps the tool version into the inventory JSON as a top level key alongside the resource types. This is what lets a consumer know which version of the tool produced a file. It also means anything iterating the JSON's top level keys has to know that `Version` is metadata and not a resource type, which is exactly what the `-Service` scope test asserts. |
| 1552 | `ConvertTo-Json -depth 100 -compress \| Out-File $Global:JsonFile` | Serializes the whole accumulator. |
| 1553 | commented out | The full raw resource dump. Left in place as a debugging aid. |

Two details on line 1552 that matter:

- `-depth 100` is not arbitrary. `ConvertTo-Json` defaults to a depth of **2** and silently truncates anything deeper, replacing it with the type name as a string. Azure `properties` payloads nest far deeper than 2, so without a large depth the inventory would be quietly hollowed out. 100 is effectively "do not truncate".
- `-compress` removes all whitespace. On a large tenant this JSON runs to hundreds of megabytes, and pretty printing would inflate it substantially for no benefit, since nothing reads it by eye.

The architectural point in the comment is worth noting.
This function is the **only** thing that writes the inventory, and `Extension/Summary.ps1` renders the HTML from this JSON rather than from the in memory objects.
That single source of truth is why the machine readable output and the human readable report can never disagree.
It is also why collectors no longer take the five extra Excel era parameters: they stopped writing reports when the report writer stopped being a per collector concern.

## 4.7 `GetResourceConsumption()` (lines 1558-2100)

The longest function in the file, at roughly 540 lines.
It pulls billing and usage data per subscription, and it contains more defensive code than anything else in the script because billing APIs are slow, heavily throttled, shared across the tenant, and return awkwardly shaped data.

### Shape of the function

```
  set culture, compute the 31-day window                 lines 1616-1623
  auth gate (skip whole phase if it fails)               lines 1632-1644
            │
  ┌───── for each subscription ──────────────────────────────────┐
  │  -SubscriptionID filter                       1648-1660      │
  │  Set-AzContext + VERIFY it landed             1675-1704      │
  │  reset per-sub counters and $UsageData        1714-1732      │
  │  ┌── do ... while (ContinuationToken) ───────────────────┐   │
  │  │  build $Params with the token                         │   │
  │  │  ┌── retry up to 30x with backoff ──────────┐         │   │
  │  │  │  Get-UsageAggregates                     │         │   │
  │  │  └──────────────────────────────────────────┘         │   │
  │  │  for each usage record:                               │   │
  │  │     parse InstanceData JSON                           │   │
  │  │     flatten 5 fields onto the row                     │   │
  │  │     rebuild a rich InstanceData object                │   │
  │  │     if -Obfuscate: mask the ARM path, keep structure  │   │
  │  │  append the page to the CSV                           │   │
  │  └───────────────────────────────────────────────────────┘   │
  │  catch: record WHERE it stopped, warn, continue  2120-2140   │
  │  aggregate per-sub health into globals           2142-2154    │
  └──────────────────────────────────────────────────────────────┘
```

### Setup (lines 1560-1567)

```powershell
    function GetResourceConsumption()
    {
        $DebugPreference = "SilentlyContinue"

        #Force the culture here...
        [System.Threading.Thread]::CurrentThread.CurrentUICulture = "en-US";
        [System.Threading.Thread]::CurrentThread.CurrentCulture = "en-US";

        $ReportedStartTime = (Get-Date).AddDays(-31).Date.AddHours(0).AddMinutes(0).AddSeconds(0).DateTime
        $ReportedEndTime = (Get-Date).AddDays(-1).Date.AddHours(0).AddMinutes(0).AddSeconds(0).DateTime
```

| Line | Code | What it does |
|---|---|---|
| 1560 | `$DebugPreference = "SilentlyContinue"` | Silences debug output for the whole function, restored at line 2101. The billing cmdlets are extremely verbose in debug mode. |
| 1563-1564 | force `CurrentUICulture` and `CurrentCulture` to `en-US` | Not cosmetic, this is a correctness fix. Culture controls how dates and decimals are formatted. On a machine set to, for example, German culture, a decimal comma and a `dd.MM.yyyy` date would be written into the CSV, and the billing API would receive dates in a format it rejects. Forcing `en-US` makes the output identical regardless of the operator's locale. Note the trailing semicolons, which are legal in PowerShell but unusual, and a hint that these lines were carried across from C#. |
| 1566 | `(Get-Date).AddDays(-31).Date.AddHours(0)...DateTime` | 31 days ago, at midnight. `.Date` truncates to midnight; the `AddHours(0).AddMinutes(0).AddSeconds(0)` chain is redundant after `.Date` but harmless. |
| 1567 | `(Get-Date).AddDays(-1).Date...` | Yesterday at midnight, not today. This is deliberate: today's billing data is incomplete because the day has not finished, and including a partial day would make the last data point misleadingly low. |

### The auth gate (lines 1576-1588)

Same pattern as the metrics phase.
`Get-UsageAggregates` silently returns zero records when unauthenticated, which would leave an empty consumption sheet that reads as "this tenant has no billing data".

```powershell
        if (-not (Test-DataPlaneAuthReady -Phase 'Consumption'))
        {
            Write-Log -Message ('Consumption: SKIPPED - could not establish a usable Azure context/token after one reconnect attempt. [...]') -Severity 'Error'

            if ($null -eq $Global:ConsumptionRecordCount) { $Global:ConsumptionRecordCount = 0 }
            if ($null -eq $Global:ConsumptionFailedSubs) { $Global:ConsumptionFailedSubs = @() }
            $Global:ConsumptionFailedSubs += [pscustomobject]@{
                Name    = '(all subscriptions)'
                Id      = '(auth)'
                Message = 'Consumption phase skipped: no usable Azure context/token after one reconnect attempt.'
            }
            return
        }
```

### The context switch, and the data leak it prevents (lines 1606-1648)

This is the most important 40 lines in the function.

```powershell
            # [long comment: switch the Azure context to the TARGET subscription before
            #  pulling its billing data. This MUST succeed AND MUST land on $sub.id:
            #  Get-UsageAggregates reads whatever subscription the CURRENT CONTEXT points
            #  at, so a silently-failed switch would leave the context on the PREVIOUS
            #  subscription and attribute THAT subscription's consumption to this one - a
            #  data-integrity bug AND a cross-subscription data leak. The production
            #  SilentlyContinue would swallow the failure, so force it terminating here
            #  and then VERIFY the resulting context actually matches the target.]
            $ContextOk = $false
            $ContextSwitchError = $null
            try
            {
                $null = Set-AzContext -Subscription $sub.id -ErrorAction Stop
                $ContextOk = ((Get-AzContext).Subscription.Id -eq $sub.id)
            }
            catch
            {
                $ContextSwitchError = $_.Exception.Message
            }

            if (-not $ContextOk)
            {
                $SkipMessage = ("Consumption SKIPPED: could not switch the Azure context to this subscription{0}. The signed-in identity likely lacks access to it. Skipped to avoid attributing another subscription's billing data to this one." -f $(...))
                Write-Log -Message ("Consumption: {0} - {1}" -f $sub.Name, $SkipMessage) -Severity 'Error'
                ...
                continue
            }
```

The problem: `Get-UsageAggregates` has **no subscription parameter**.
It bills whatever subscription the current Az context happens to point at.
So the only way to target a subscription is to change the context first.

Now consider what happens if that switch fails, which it will whenever the identity cannot access that subscription.

| Without the guard | With the guard |
|---|---|
| `Set-AzContext` fails and `SilentlyContinue` swallows it | `-ErrorAction Stop` makes it terminating and catchable |
| Context stays pointing at the **previous** subscription | The context is **verified** to match the target |
| `Get-UsageAggregates` returns the previous subscription's billing | The subscription is skipped with a loud error |
| Those rows get written to the CSV attributed to **this** subscription | No wrong data is written |

That is both a data integrity bug and a cross subscription data leak: subscription A's costs appearing under subscription B's name, silently.

Two separate defences are applied, and both are needed:

| Line | Defence | Catches |
|---|---|---|
| 1623 | `-ErrorAction Stop` | A switch that throws |
| 1624 | `$ContextOk = ((Get-AzContext).Subscription.Id -eq $sub.id)` | A switch that returns without error but does not land on the target |

The second is the more interesting one.
It does not trust the cmdlet's silence as evidence of success; it goes and checks the resulting state.
That is a good general habit for anything that mutates ambient state.

### The paging and retry loop (lines 1678-1767)

```powershell
                do
                {
                    $ConsumptionPageIndex++
                    $Params = @{
                        ReportedStartTime      = $ReportedStartTime
                        ReportedEndTime        = $ReportedEndTime
                        AggregationGranularity = 'Daily'
                        ShowDetails            = $true
                    }

                    $Params.ContinuationToken = if ($null -ne $UsageData) { $UsageData.ContinuationToken } else { $null }

                    # [long comment: bounded retry with exponential backoff + jitter. On a
                    #  large tenant this pages through MILLIONS of usage records; a single
                    #  transient HTTP failure would otherwise abort the entire remaining pull
                    #  via the outer catch. Retrying the SAME page is safe: a failed
                    #  assignment leaves $usageData holding the PREVIOUS page's token, so the
                    #  retried call re-requests the same page - no duplicate rows, no skipped
                    #  rows.
                    #
                    #  The Cost Management rate limit is SHARED across all callers in the
                    #  tenant, not per-user. So the retry HONORS the server-directed wait
                    #  when Azure supplies one; absent that, a 429 backs off LONGER than a
                    #  generic transient error. Waits are capped (server-directed 300s,
                    #  computed ~120s) and jittered so parallel streams sharing the same
                    #  tenant bucket do not retry in lockstep.]
                    $ConsumptionMaxRetries = 30
                    $ConsumptionAttempt = 0
                    while ($true)
                    {
                        try
                        {
                            $UsageData = Get-UsageAggregates @Params -ErrorAction Stop
                            break
                        }
                        catch
                        {
                            # [long comment: ABANDON an authorization denial immediately.
                            #  Retrying a 403 cannot make it a 200, and this catch is
                            #  otherwise untyped, so a denial previously consumed the whole
                            #  30-attempt budget - roughly 26 minutes of escalating backoff
                            #  PER SUBSCRIPTION - before propagating to exactly the same
                            #  place it goes now. Deliberately checked FIRST, before the
                            #  loose throttle test below, because a billing exception echoes
                            #  ids and URLs that can contain '429'.]
                            if (Test-RdaConsumptionDenial -ErrorMessage $_.Exception.Message)
                            {
                                Write-Log -Message ("Consumption page query DENIED for {0} after {1} attempt(s): {2}. [...]" -f $sub.Name, ($ConsumptionAttempt + 1), $_.Exception.Message) -Severity 'Error'
                                throw
                            }

                            $ConsumptionAttempt++
                            if ($ConsumptionAttempt -gt $ConsumptionMaxRetries) { throw }

                            $ConsumptionThrottled = $_.Exception.Message -match 'TooManyRequests|\b429\b|throttl|rate limit'

                            $ConsumptionRetryAfter = Get-RdaRetryAfterSeconds -ErrorRecord $_
                            if ($ConsumptionRetryAfter -gt 0)
                            {
                                $ConsumptionThrottled = $true
                                $ConsumptionBackoffSeconds = [math]::Min($ConsumptionRetryAfter, 300)
                            }
                            else
                            {
                                $ConsumptionBackoffSeconds = [math]::Min([math]::Pow(2, $ConsumptionAttempt), 60)
                                if ($ConsumptionThrottled) { $ConsumptionBackoffSeconds = [math]::Min($ConsumptionBackoffSeconds * 2, 120) }
                            }
                            $ConsumptionBackoffSeconds = [math]::Round($ConsumptionBackoffSeconds + ((Get-Random -Minimum 0 -Maximum 1000) / 1000.0), 2)

                            $ConsumptionRetryMarker = if ($ConsumptionRetryAfter -gt 0) { ', throttled, honoring server Retry-After' } elseif ($ConsumptionThrottled) { ', throttled' } else { '' }
                            Write-Log -Message ("Consumption page query failed for {0} (attempt {1}/{2}{3}): {4}. Retrying in {5}s..." -f ...) -Severity 'Warning'
                            Start-Sleep -Seconds $ConsumptionBackoffSeconds
                        }
                    }
```

| Line | Code | What it does |
|---|---|---|
| 1683-1688 | `$Params = @{ ... }` | A hashtable of parameters, later applied with `@Params`, which is PowerShell **splatting**. `AggregationGranularity = 'Daily'` gives one row per resource per meter per day. `ShowDetails = $true` is what makes `InstanceData` populated, and without it there would be no resource IDs to join on at all. |
| 1690 | `$Params.ContinuationToken = if ($null -ne $UsageData) { $UsageData.ContinuationToken } else { $null }` | First page uses `$null`; every later page uses the token from the previous response. |
| the `Test-RdaConsumptionDenial` check | `if (Test-RdaConsumptionDenial -ErrorMessage $_.Exception.Message) { ...; throw }` | The retry loop's **fast-fail**, and the first thing the catch evaluates. `Test-RdaConsumptionDenial` lives in `Functions/Common.Functions.ps1` and is the *same* verdict the wrapper's up-front access gate uses via `Get-ConsumptionAccessOutcome`, so a denial is treated identically whether it is caught before the run or part-way through it. Ordering matters: it must stay ahead of the throttle test below, which is a loose substring match that a `429` inside an echoed resource id would satisfy. Only an unambiguous denial qualifies - throttling, an expired token, a 5xx and the transient "Error while copying content to a stream" all still retry, because abandoning retrievable billing data is the expensive mistake. |
| `$ConsumptionMaxRetries = 30` | A large budget, deliberately. The reason is in the comment: the Cost Management rate limit is **tenant wide and shared**, not per user, so when another billing pipeline is draining the same bucket the throttle can persist for minutes. A short 3 retry, 14 second budget would be exhausted while contention was still ongoing, and this subscription's consumption would be silently truncated. |
| 1729 | `$UsageData = Get-UsageAggregates @Params -ErrorAction Stop` | The actual call, splatted. |
| the budget check | `if ($ConsumptionAttempt -gt $ConsumptionMaxRetries) { throw }` | Budget exhausted. This is now the *second* of two exits from the loop, the first being the denial fast-fail above. Re-throws to the outer per subscription `catch`, which records the failure and moves to the next subscription. |
| 1737 | `$_.Exception.Message -match 'TooManyRequests\|\b429\b\|throttl\|rate limit'` | Text matching to detect throttling. Fragile in principle, since message text can change between SDK versions and locales, which is exactly why the header based check on the next line is preferred over it. |
| 1749 | `$ConsumptionRetryAfter = Get-RdaRetryAfterSeconds -ErrorRecord $_` | A project helper that digs the `x-ms-ratelimit-microsoft.consumption-retry-after` or standard `Retry-After` header out of the thrown `CloudException`. This is the **server telling you exactly how long to wait**, which beats any guess. |
| 1753 | `[math]::Min($ConsumptionRetryAfter, 300)` | Honour the server, but clamp to 5 minutes so a misparsed or pathological header value cannot stall the run indefinitely. Trusting an external input, but bounding it. |
| 1757 | `[math]::Min([math]::Pow(2, $ConsumptionAttempt), 60)` | No header, so fall back to exponential backoff: 2, 4, 8, 16, 32, then capped at 60 seconds. |
| 1758 | `if ($ConsumptionThrottled) { ... * 2, 120 }` | Double it for a throttle, capped at 120 seconds. A throttle needs a longer wait than a generic network blip. |
| 1762 | `+ ((Get-Random -Minimum 0 -Maximum 1000) / 1000.0)` | Sub second **jitter**. Essential when parallel streams share one tenant bucket: without it, every stream released by the same server window retries on the identical tick and immediately re-throttles everyone. |
| 1764 | `$ConsumptionRetryMarker` | Makes the log line say which of the three cases applied, so the operator can tell a server directed wait from a guessed one. |

### Why retrying the same page is safe

This deserves its own note because it is the kind of thing that is easy to get wrong.

The token for the next request is read from `$UsageData`.
When `Get-UsageAggregates` throws, the **assignment does not happen**, so `$UsageData` still holds the previous page's response and therefore the previous page's token.
The retry consequently re-requests the *same* page.

| Outcome | Happens? |
|---|---|
| Duplicate rows | no |
| Skipped rows | no |
| Same page fetched again | yes, which is exactly what is wanted |

Compare that with `$UsageData = $null` at line 1676, which resets the token **per subscription**.
The comment there describes the bug it fixes: a subscription that failed part way through left its live continuation token in place, and the *next* subscription's very first request was issued with a token belonging to a different subscription, either failing or, worse, resuming another subscription's page sequence and attributing its billing rows here.

The same variable, two different lifetimes, two different bugs.
Within a subscription, keeping the stale token is the fix.
Between subscriptions, clearing it is the fix.

### Flattening each usage record (lines 1769-1814)

```powershell
                    $UsageDataExport = $UsageData.UsageAggregations.Properties | Select-Object InstanceData, MeterCategory, MeterId, MeterName, MeterRegion, MeterSubCategory, Quantity, Unit, UsageStartTime, UsageEndTime

                    Write-Log -Message ("Records found: $($UsageDataExport.Count)...") -Severity 'Info'
                    $ConsumptionRecordsThisSub += $UsageDataExport.Count

                    $NewUsageDataExport = [System.Collections.ArrayList]::new()

                    for ($Item = 0; $Item -lt $UsageDataExport.Count; $Item++)
                    {
                        # [long comment: some meters (marketplace purchases, certain
                        #  reservations, tenant-level charges) return a null/empty
                        #  InstanceData. Calling .tolower() on null THROWS, and because this
                        #  loop sits inside the per-subscription try/catch that throw would
                        #  abort the WHOLE subscription's consumption. Such a record has no
                        #  resourceUri to attribute or join anyway, so skip just that one.]
                        $RawInstanceData = $UsageDataExport[$Item].InstanceData
                        if ([string]::IsNullOrEmpty($RawInstanceData))
                        {
                            continue
                        }
                        $InstanceInfo = ($RawInstanceData.tolower() | ConvertFrom-Json)

                        if (![string]::IsNullOrEmpty($ResourceGroup))
                        {
                            if (!$InstanceInfo.'Microsoft.Resources'.resourceUri.toLower().Contains("/" + $ResourceGroup.toLower() + "/"))
                            {
                                continue;
                            }
                        }
```

| Line | Code | What it does |
|---|---|---|
| 1769 | `$UsageData.UsageAggregations.Properties \| Select-Object ...` | Digs down two levels into the response and projects ten fields. `InstanceData` is a **JSON string inside a JSON response**, which is why it has to be parsed separately. |
| 1774 | `[System.Collections.ArrayList]::new()` | An `ArrayList` rather than `@()` because this loop appends thousands of items per page, and `+=` on a PowerShell array copies the whole array every time, which is quadratic. `ArrayList.Add` is constant time. |
| 1776 | `for ($Item = 0; ...)` | An index based `for` rather than `foreach`, because the loop **mutates** `$UsageDataExport[$Item]` in place. |
| 1786-1790 | the null `InstanceData` guard | A real bug fix. Some meters, marketplace purchases and certain reservations and tenant level charges, have no `InstanceData` at all. `.tolower()` on null throws, and because this loop sits inside the per subscription `try`, that single record would abort the **entire** subscription's consumption. Such a record has no resource URI to attribute anyway, so skipping just that one record is exactly right. |
| 1791 | `($RawInstanceData.tolower() \| ConvertFrom-Json)` | Lowercase, then parse. The lowercasing matters far more than it looks: it is what makes the cross dataset join at line 1899 work, because the inventory dictionary is keyed on lowercased resource IDs. |
| 1793-1799 | the resource group filter | Billing cannot be filtered by resource group server side, hence the `Info` log at line 1597 saying so. So it is filtered client side here, by substring match on the resource URI. Every record for the whole subscription is still fetched and paid for in time; only the writing is filtered. |
| 1801-1814 | five `Add-Member` calls then five assignments | Flattens `ResourceId`, `ResourceLocation`, `ConsumptionMeter`, `ReservationId` and `ReservationOrderId` out of the nested `InstanceData` up onto the top level row, so the CSV has them as plain columns. |

### Rebuilding a normalised `InstanceData` (lines 1816-1843)

A `[PSCustomObject]` is constructed with a `Microsoft.Resources` member containing `ResourceUri`, `Location` and an `additionalInfo` block of 17 fields.
Every one of those 17 uses the same pattern:

```powershell
ConsumptionMeter = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.ConsumptionMeter) { "" } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.ConsumptionMeter }
```

Read as: if the field is absent, use an empty string, or `0` for the numeric ones, otherwise use the real value.

The reason is CSV shape stability.
Azure returns a *different* set of `additionalInfo` fields depending on the meter: a VM meter has `NumberOfCores` and `OS`, a SQL meter has `ServerSku` and `SLO`, a marketplace meter has almost nothing.
If the object were built only from what was present, every row would have a different shape and the CSV would be unparseable.

Explicitly defaulting all 17 means every row has all 17, and a missing value is an empty string rather than an absent column.
Verbose, but correct, and it is why the file has a 28 line object literal here.

### Consumption obfuscation: preserving ARM path structure (lines 1845-2044)

This is the most sophisticated obfuscation in the whole tool, and it exists to fix a regression.

**The regression:** the original behaviour replaced the whole resource URI with one flat opaque token.
That was safe but useless.
The downstream dashboard categorises billing rows by **parsing the ARM path**: it reads the resource provider and type to identify AKS, VMSS, Container Instances, Container Registry, Kusto and so on, and it looks for the `mc_` resource group marker to spot AKS managed resources.
A flat token destroyed every one of those signals, and AKS and VMSS rows became invisible on the dashboard.

**The fix:** mask only the identifying segments and keep the path skeleton intact.

```
  REAL
  /subscriptions/1234-abcd/resourcegroups/mc_prod-aks/providers/microsoft.compute/virtualmachinescalesets/aks-nodepool1
   └─ segment ─┘ └── id ──┘ └─ segment ──┘ └── name ─┘ └ segment ┘ └── provider ──┘ └───── type ──────┘ └── name ───┘
                    MASK                     MASK                       KEEP              KEEP             MASK

  MASKED
  /subscriptions/prod_sub_<guid>/resourcegroups/prod_rg_mc_<guid>/providers/microsoft.compute/virtualmachinescalesets/prod_<guid>
                                                        ▲                        ▲                    ▲
                                          mc_ marker preserved        provider kept        type kept
```

The dashboard can still see "this is a scale set under microsoft.compute in an AKS managed resource group", and it cannot see a single real name.

| Line | Code | What it does |
|---|---|---|
| 1850 | `$Prefix = if ($UsageDataExport[$Item].ResourceId -match ...)` | Classify prod or nonprod from the **original** URI. The comment notes the reason for doing it here: after masking there is nothing left to match against. |
| 1866-1867 | `$RawUri` and `$ObfuscatedUri = $RawUri` | Start with the real URI and rebuild it segment by segment. |
| 1877-1879 | three `$script:` caches | `$script:ConsumptionSubCache`, `ConsumptionRgCache` and `ConsumptionNameCache`, lazily created. Deliberately **separate** from `$Global:ResourceIdDictionary`, because that dictionary's public contract, the saved dictionary file, maps full Azure IDs to real values, and it must not be polluted with bare subscription, resource group and name fragments. |
| 1899 | `$InventoryLeafToken = if ($null -ne $Global:ResourceIdDictionary -and $Global:ResourceIdDictionary.ContainsKey($RawUri)) { ... } else { $null }` | **The cross dataset link, and arguably the single most important line in the function.** See below. |
| 1901 | `if ($RawUri -match '^/subscriptions/([^/]+)(/resourcegroups/([^/]+))?(/providers/(.+))?$')` | Parse the ARM path into three optional captures: subscription ID, resource group name, and everything after `/providers/`. |

### The cross dataset link

If a billing row's real resource URI **is** an inventoried resource, then the leaf name segment must reuse the **exact** token that the inventory and metrics phases already assigned to that resource, rather than minting a fresh one.

Otherwise the consumption row cannot be joined back to its inventory or metrics record, which is the entire point of producing all three datasets.

```
   Inventory_*.json      vm-web-01  ->  prod_abc123
   Metrics_*.json        vm-web-01  ->  prod_abc123      (same dictionary)
   Consumption_*.csv     vm-web-01  ->  prod_abc123      (reuses it via line 1955)
                                            │
                                     all three join on this
```

Two properties of the implementation are worth noting.
It is **read only** against the dictionary, so it adds no consumption entries and the saved dictionary contract stays clean.
And it still preserves the path structure around the leaf, so it does not reintroduce the flat token regression.

### Type versus name segments (lines 1929-1994)

After `/providers/`, an ARM path alternates type and name:

```
   index:      0                    1                        2              3        4
            microsoft.compute / virtualmachines /       vm-web-01
            microsoft.sql     / servers         /       my-server   /  databases / my-db
                 ▲                   ▲                      ▲              ▲         ▲
              provider             TYPE                   NAME           TYPE      NAME
              (keep)              (keep)                 (mask)         (keep)    (mask)
```

So within the provider relative index space, odd indices are types and even indices from 2 upward are names.

| Line | Code | What it does |
|---|---|---|
| 1947-1951 | the backward `for` finding `$LeafNameIndex` | Walks from the end down to index 2 looking for the largest even index. That is the **leaf** name, meaning the resource this row is actually about. |
| 1983 | `$IsNameSegment = ($Pi -ge 2 -and ($Pi % 2 -eq 0))` | The parity test. `$Pi % 2 -eq 0` is "even", and `-ge 2` skips the provider at index 0. |
| 1984 | `if ($IsNameSegment -and -not [string]::IsNullOrEmpty($Part) -and $Part -ne '$system')` | `$system` is an Azure reserved placeholder segment, not a customer name, so it is kept verbatim. |
| 1986-1993 | `if ($Pi -eq $LeafNameIndex -and $null -ne $InventoryLeafToken)` | Only the **leaf** reuses the inventory token. Intermediate name segments, which are parent names in a child resource path, use the per name cache instead, because they identify a *different* resource. |
| 2009-2007 | `$RebuiltUri += '/providers/' + ($Rebuilt -join '/')` | Reassemble. |

The AKS marker is handled at lines 1920-1924:

```powershell
                                        $IsMc = $RealRg -match '^mc_'
                                        $Tag = if ($IsMc) { 'mc_' } else { '' }
                                        $V = $Prefix + 'rg_' + $Tag + [guid]::NewGuid().ToString()
```

So an AKS managed resource group becomes `prod_rg_mc_<guid>`, keeping the `mc_` signal the dashboard needs while masking the actual name.

### The case drift early warning (lines 1934-1976)

```powershell
                                    # [long comment: a TOP-LEVEL resource path whose real uri
                                    #  is NOT in $Global:ResourceIdDictionary means the leaf
                                    #  cannot reuse the inventory token. That is legitimate for
                                    #  resources deleted between the graph scan and the billing
                                    #  pull, or for a -Service-narrowed inventory - but it is
                                    #  ALSO the silent signature of a lowercasing regression,
                                    #  because the dictionary is case-SENSITIVE. Child rows
                                    #  legitimately miss and would flood, so only the top-level
                                    #  case is surfaced.]
                                    if ($LeafNameIndex -eq 2 -and $null -eq $InventoryLeafToken)
                                    {
                                        Write-Log -Message ("Consumption cross-link miss: top-level resourceUri not found in inventory dictionary [...]: {0}" -f $RawUri) -Severity 'Info' -NoConsole -ToDebugLog
                                    }
```

This is a nice piece of defensive observability and worth understanding as a pattern.

The dictionary is a `Dictionary[string,string]` built with `[System.StringComparer]::OrdinalIgnoreCase`, so the join no longer depends on every producer having lowercased its input.
That matters: it used to be case **sensitive**, and a casing difference anywhere upstream made the join miss silently - every consumption row minting fresh tokens and the three datasets quietly ceasing to join.
The lowercasing upstream is still there and still desirable for consistency, but it is no longer the single point of failure it was.
Nothing would error.

So the code logs a diagnostic on exactly the condition that would be the **signature** of that regression: a top level resource, meaning `$LeafNameIndex -eq 2`, that is not in the dictionary.

The filter to top level only is what makes it usable.
Child resource rows legitimately miss all the time and would flood the log.
Top level misses are rare and explainable, from a resource deleted between the graph scan and the billing pull, or a `-Service` narrowed inventory, so a burst of them is a real signal.

It goes to the debug log only, with `-NoConsole -ToDebugLog`, because `$RawUri` is a real resource ID.

### Non ARM URIs and reservation IDs (lines 2012-2047)

```powershell
                                if ([string]::IsNullOrEmpty($RawUri))
                                {
                                    $ObfuscatedUri = 'obfuscated'
                                }
                                else
                                {
                                    if (-not $script:ConsumptionNameCache.ContainsKey($RawUri))
                                    {
                                        $script:ConsumptionNameCache[$RawUri] = $Prefix + [guid]::NewGuid().ToString()
                                    }
                                    $ObfuscatedUri = $script:ConsumptionNameCache[$RawUri]
                                }
```

The null check at the top is another real bug fix, and the comment records that it was an obfuscate only bug.
`hashtable.ContainsKey($null)` **throws**, and that throw would be caught by the per subscription handler and abort the rest of that subscription's consumption.
A null resource URI is legitimate for marketplace purchases, certain reservations and tenant level charges, so one such meter row could truncate an entire subscription's billing data.

Reservation identifiers are handled differently from everything else:

```powershell
                            if (![string]::IsNullOrEmpty($UsageDataExport[$Item].ReservationId))
                            {
                                $UsageDataExport[$Item].ReservationId = 'obfuscated'
                            }
```

They are **blanked**, not tokenised.
The comment calls them "customer purchasing fingerprints", and the reasoning holds: a reservation ID is a global identifier of a specific purchase, so even a consistent token would let two reports be correlated as belonging to the same customer.
Nothing downstream needs to join on them, so they are simply destroyed rather than masked.

### Writing the page and looping (lines 2054-2062)

```powershell
                    $NewUsageDataExport | Select-Object InstanceData, MeterCategory, ..., ReservationOrderId | Export-Csv $Global:ConsumptionFileCsv -Encoding utf8 -Append -NoTypeInformation

                } while ('ContinuationToken' -in $UsageData.psobject.properties.name -and $UsageData.ContinuationToken)
```

| Line | Code | What it does |
|---|---|---|
| 2060 | `Export-Csv ... -Append -NoTypeInformation` | Appends **per page**, not once at the end. This is what keeps memory flat over millions of records, and it means a mid pull failure still leaves every completed page on disk. `-NoTypeInformation` suppresses the `#TYPE` comment line that older PowerShell writes and that breaks naive CSV parsers. |
| 2062 | `while ('ContinuationToken' -in $UsageData.psobject.properties.name -and $UsageData.ContinuationToken)` | Two conditions. The first checks the property **exists** using reflection over the object's property names, the second checks it has a value. Both are needed because reading a non existent property in strict mode would error, and a present-but-empty token means the last page. |

### Recording where it stopped (lines 2064-2098)

```powershell
            catch
            {
                # [long comment: the most common cause is a broken Az module install. We
                #  also catch defensively so a transient throttling event or a subscription
                #  the identity cannot bill against does not abort the run for other subs.
                #  Capture WHERE it stopped (page index + records so far) so the truncation
                #  is precise and self-evident downstream, rather than a silently-short CSV
                #  that can only be inferred from a round row count.]
                $ConsumptionFailedThisSub = $true
                $ConsumptionFailureMessage = ("{0} (stopped at consumption page {1}, after {2} record(s); this subscription's consumption is INCOMPLETE)" -f $_.Exception.Message, $ConsumptionPageIndex, $ConsumptionRecordsThisSub)
                Write-Log -Message ("Consumption query failed for {0}: {1}" -f $sub.Name, $ConsumptionFailureMessage) -Severity 'Warning'
            }
```

The health record built at lines 2091-2098 carries six fields, and the last three are the interesting ones.

| Field | Purpose |
|---|---|
| `Name`, `Id` | Which subscription |
| `Message` | What went wrong |
| `Complete` | Explicitly `$false`. Not inferred from anything. |
| `PageAtFailure` | **Which page** it stopped on |
| `RecordsCollected` | How many rows did make it |

The reason for `PageAtFailure` and `RecordsCollected` is stated in the comment and is a good principle.
A truncated CSV is otherwise indistinguishable from a complete one; you could only suspect truncation by noticing the row count looked suspiciously round.
Recording the exact stopping point makes the truncation **self evident** downstream instead of something a human has to infer.

Note also the two different counters at lines 2089 and 2095.

| Counter | Scope | Why both exist |
|---|---|---|
| `$Global:ConsumptionRecordCount` | run wide, accumulates across all subscriptions in the process | What the wrapper's final summary reports |
| `$script:ConsumptionRecordsThisRun` | this invocation only | What the per subscription `Diagnostics_*.log` reports |

Without the script scoped one, a subscription that collected zero records after an earlier one collected millions could not fire its own zero record warning, because the global would be non zero.
Script scope resets naturally per `&` invocation, which is why it is not a new global.

## 4.8 The orchestration block (lines 2104-2200)

The bottom of `ExecuteInventoryProcessing`, where the nested functions get called in order.

```powershell
    InitializeInventoryProcessing

    # [long comment: per-phase timing for the report header. Stored in $script: scope
    #  (NOT a new $Global:) so ProcessSummary can read it without polluting the global
    #  namespace and without persisting across subscriptions. The stopwatches wrap the
    #  existing calls EXACTLY as they were - no reordering. This replaces the single
    #  opaque "Reporting time" (which bundled metrics + collectors + consumption) with a
    #  breakdown so an operator can see which phase dominates a long run.]
    $script:PhaseTimings = [ordered]@{}

    $MetricsPhaseTimer = [System.Diagnostics.Stopwatch]::StartNew()
    CreateMetricsJob
    $MetricsPhaseTimer.Stop()

    $CollectorPhaseTimer = [System.Diagnostics.Stopwatch]::StartNew()
    CreateResourceJobs
    $CollectorPhaseTimer.Stop()

    ProcessMetricsResult
    ProcessResourceResult
```

| Line | Code | What it does |
|---|---|---|
| 2116 | `InitializeInventoryProcessing` | Compute all the output paths first, since everything below writes files. |
| 2126 | `$script:PhaseTimings = [ordered]@{}` | An **ordered** hashtable, so the phases appear in the report in execution order rather than in hash order. |
| 2128-2134 | two `Stopwatch` pairs | `[System.Diagnostics.Stopwatch]::StartNew()` creates and starts a high resolution timer in one call. The comment makes a point worth respecting: the stopwatches wrap the existing calls **without reordering** them, so adding the timing changed no behaviour. |
| 2136-2137 | `ProcessMetricsResult` then `ProcessResourceResult` | GC and memory snapshot, then write `Inventory_*.json`. |

### The VM placement CSV (lines 2155-2186)

```powershell
    # [long comment: VM placement CSV for capacity planning. Deliberately a SEPARATE file
    #  rather than new fields on the VM collector, so Inventory_*.json and the server
    #  ingestion contract it feeds are untouched.
    #
    #  Runs after ProcessResourceResult so $Global:SmaResources is fully populated, and
    #  needs no Azure calls - it joins collector output already in memory.
    #
    #  Placement mirrors $Global:ErrorLogFile rather than the report files: under the
    #  wrapper this is a per-subscription PART that Run-AllSubscriptions.ps1 concatenates
    #  into one tenant-wide VMPlacement.csv, so it goes in the PARENT InventoryRoot
    #  (tagged with the SubscriptionID so parallel streams cannot collide) and NOT into
    #  the report folder, where it would be swept into the per-subscription zip.
    #
    #  A failure here must never fail the run: the inventory, metrics and report are
    #  already written, so it is downgraded to a warning.]
    try
    {
        $PlacementScript = Join-Path $PSScriptRoot 'Extension/VMPlacement.ps1'
        if (Test-Path -LiteralPath $PlacementScript -PathType Leaf)
        {
            if ($RunAllSubs.IsPresent)
            {
                $PlacementDir = Split-Path -Path ($Global:DefaultPath.TrimEnd([IO.Path]::DirectorySeparatorChar, '/', '\')) -Parent
                $PlacementTag = if (![string]::IsNullOrEmpty($SubscriptionID)) { $SubscriptionID } else { $Global:CurrentDateTime }
                $PlacementCsv = Join-Path $PlacementDir ("VMPlacementPart_" + $Global:ReportName + "_" + $Global:CurrentDateTime + "_" + $PlacementTag + ".csv")
            }
            else
            {
                $PlacementCsv = ($DefaultPath + "VMPlacement_" + $Global:ReportName + "_" + $CurrentDateTime + ".csv")
            }

            & $PlacementScript -CsvFile $PlacementCsv
        }
        else
        {
            Write-Log -Message ("VM placement CSV skipped: {0} not found." -f $PlacementScript) -Severity 'Error'
        }
    }
    catch
    {
        Write-Log -Message ("VM placement CSV failed: {0}. The rest of the run is unaffected." -f $_.Exception.Message) -Severity 'Error'
    }
```

Three design decisions here, each worth noting because each is a reasonable pattern to copy.

**A separate file, not new collector fields.**
Adding fields to the VM collector's output object would change `Inventory_*.json`, which is a schema the server ingestion pipeline binds to on fixed field names.
Producing a separate CSV leaves that contract untouched.

**Filename differs by mode, and the location differs too.**
Under the wrapper this is a *part* file, `VMPlacementPart_*`, written to the **parent** `InventoryRoot` and tagged with the subscription ID.
`Run-AllSubscriptions.ps1` later concatenates every part into one tenant wide `VMPlacement.csv`.
Writing it into the report folder instead would let the zip sweep pick it up and silently add a member to every per subscription bundle.
A standalone run has nothing to aggregate, so it just writes `VMPlacement_*` next to its own report.

**Failure is downgraded.**
By this point the inventory, metrics and report are already written.
Letting an optional capacity planning CSV fail the whole subscription would throw away an hour of good work for a nice to have.
So it warns and continues.

Note the missing extension is logged at `Error` severity but does not throw, which is a small inconsistency: it reads as an error but behaves as a warning.

### Recording the timings and running consumption (lines 2187-2199)

```powershell
    if (!$SkipMetrics.IsPresent)
    {
        $script:PhaseTimings['Metrics collection (Azure Monitor)'] = $MetricsPhaseTimer.Elapsed
    }
    $script:PhaseTimings['Resource detail collection (service collectors)'] = $CollectorPhaseTimer.Elapsed

    if (!$SkipConsumption.IsPresent)
    {
        $ConsumptionPhaseTimer = [System.Diagnostics.Stopwatch]::StartNew()
        GetResourceConsumption
        #ProcessResourceConsumption
        $ConsumptionPhaseTimer.Stop()
        $script:PhaseTimings['Consumption / cost collection (billing)'] = $ConsumptionPhaseTimer.Elapsed
    }
}
```

| Line | Code | What it does |
|---|---|---|
| 2187-2190 | conditionally record the metrics timing | The metrics stopwatch always ran, but its elapsed time is only *recorded* when metrics were requested. So a `-SkipMetrics` run shows no metrics row in the report header at all, rather than a misleading "0 seconds". |
| 2190 | the collector timing, unconditional | Collectors always run. |
| 2192-2199 | the consumption phase | Note it is inside its own `if`, so unlike metrics the consumption function is not even called when skipped. The stopwatch is created inside the `if` for the same reason. |

The `#ProcessResourceConsumption` on line 2196 is a commented out call to a function that no longer exists.
Harmless, but it is the kind of leftover worth noticing so you do not go looking for it.

---

# Part 5: `FinalizeOutputs()` (lines 2202-2249)

The third and last top level function.
It renders the HTML report and does nothing else.

```powershell
function FinalizeOutputs
{
    function ProcessSummary()
    {
        Write-Log -Message ('Creating Summary Report') -Severity 'Info'
        Write-Log -Message ('Starting Summary Report Processing Job.') -Severity 'Info'

        if ($PSScriptRoot -like '*\*')
        {
            $SummaryPath = Get-ChildItem -Path ($PSScriptRoot + '\Extension\Summary.ps1') -Recurse
        }
        else
        {
            $SummaryPath = Get-ChildItem -Path ($PSScriptRoot + '/Extension/Summary.ps1') -Recurse
        }

        # [long comment: Tenant ID is shown in the report header for reference, but it is
        #  a REAL Azure identifier and must NOT appear in an obfuscated (shareable)
        #  report. Pass it only when NOT obfuscating.]
        $ReportTenantId = if ($Obfuscate.IsPresent) { $null } else { $TenantID }
        $ReportTitle = ('Azure Resource Inventory - {0}' -f $Global:ReportName)

        # [long comment: unlike a single collector failing, the HTML report IS the
        #  deliverable - there is nothing meaningful to "continue" to after this fails.
        #  Catch purely to give a clear, loud, specific diagnosis (which file, which
        #  stage) instead of a raw exception from deep inside Summary.ps1, then RE-THROW
        #  so this subscription is still correctly marked as failed by the wrapper.]
        try
        {
            $null = & $SummaryPath -JsonFile $Global:JsonFile -HtmlFile $Global:HtmlFile -Title $ReportTitle -TenantId $ReportTenantId -Version $Global:Version -ExtractionRunTime $Runtime -ReportingRunTime $ReportingRunTime -PhaseTimings $script:PhaseTimings -PlatOS $PlatformOS -ConsumptionFile $Global:ConsumptionFileCsv
        }
        catch
        {
            Write-Log -Message ("HTML report generation FAILED: {0}" -f $_.Exception.Message) -Severity 'Error'
            Write-Log -Message ("The Inventory/Metrics/Consumption data files were still written to {0}, but no HTML report or zip was produced for this run." -f $Global:DefaultPath) -Severity 'Error'
            throw
        }
    }

    ProcessSummary
}
```

| Line | Code | What it does |
|---|---|---|
| 2210-2215 | the platform path branch | Locate `Extension/Summary.ps1`. |
| 2223 | `$ReportTenantId = if ($Obfuscate.IsPresent) { $null } else { $TenantID }` | A small line with a real security purpose. The tenant ID is a genuine Azure identifier that uniquely names an organisation, so on an obfuscated run it is passed as `$null` and simply never appears in the HTML. Without this, a report with every name masked would still carry a GUID that identifies the customer. |
| 2224 | `$ReportTitle` | Report header text. |
| 2238 | `$null = & $SummaryPath -JsonFile ... -ConsumptionFile ...` | Invokes the report generator. `$null =` discards whatever it emits so nothing leaks onto the pipeline. Note the inputs: `-JsonFile` is the inventory JSON written at line 1552, not the in memory objects. The report renders from the same single source of truth that ships in the bundle, so the two cannot disagree. |
| 2240-2245 | the `catch` then bare `throw` | Explained below. |

## Why this `catch` re-throws, and the collector `catch` does not

The two error handlers look similar and behave oppositely, and the difference is the useful lesson.

| | Collector failure (line 1385) | Report failure (line 2240) |
|---|---|---|
| Is there useful work left to do? | Yes, 59 other resource types | No, the report **is** the deliverable |
| Response | log loudly, continue | log loudly, **re-throw** |
| Outcome | partial report, clearly flagged | subscription marked failed |

A bare `throw` inside a `catch` re-throws the original exception with its original stack trace preserved.
So the value added here is purely diagnostic: instead of an unqualified PowerShell error surfacing from deep inside `Summary.ps1`, the operator gets two clear log lines naming the stage and, importantly, telling them the inventory, metrics and consumption data files **were** still written and where to find them.
Then the exception continues up so the wrapper still records the subscription as failed.

That second message matters more than it looks.
Without it, an operator seeing a report generation failure would reasonably assume the whole hour of collection was lost.

---

# Part 6: The script body (lines 2251-2854)

Everything up to here was definitions.
Execution starts at line 2251.

## 6.1 Pre flight checks (lines 2251-2452)

```powershell
# === Pre-flight checks ===
#
# [long comment: detect the most common environment problems that make a long run
#  pointless, BEFORE transcript start, authentication, or any per-subscription work.
#
#  When invoked by Run-AllSubscriptions.ps1 (-RunAllSubs), the wrapper has already run
#  the same checks, so the entire block is skipped - otherwise they would re-run once
#  per subscription, adding noise without adding safety.
#
#  Keep in sync with Invoke-PreFlightChecks in
#  Functions/RunAllSubscriptions.Functions.ps1. This copy is deliberately INLINE, not
#  shared, so the environment sanity checks have NO dependency on locating another
#  file - which matters most in exactly the broken environments these checks catch.]
if (-not $RunAllSubs.IsPresent)
{
```

### The deliberate duplication

The comment flags something that would otherwise look like sloppiness: this block is a near copy of `Invoke-PreFlightChecks` in the functions file, and it is duplicated **on purpose**.

The argument is worth understanding because it is a genuinely good reason to duplicate code.
These checks exist to catch broken environments.
If they lived in a shared file, they would depend on finding and loading that file, which is one of the things that can be broken in a broken environment.
Keeping them inline means they run even when nothing else can.

The three intentional differences from the wrapper's copy:

| Difference | This copy | The wrapper's copy |
|---|---|---|
| `-OutputDirectory` | honoured | not exposed or forwarded |
| Hard fail | `throw` or `exit 1` | `Exit-Wrapper` |
| Gating | skipped under `-RunAllSubs` | always runs |

### Check 0: the `-Service` fast fail (lines 2313-2332)

```powershell
    if ($Service -and @($Service).Count -gt 0)
    {
        $PreFlightAvailableServices = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Services') -Filter '*.ps1' -Recurse | ForEach-Object { $_.BaseName } | Sort-Object)
        $PreFlightMatchedServices = @($Service | Where-Object { $_ -in $PreFlightAvailableServices })
        if (@($PreFlightMatchedServices).Count -eq 0)
        {
            # [long comment: hard-fail with exit 1 (NOT throw): $ErrorActionPreference is
            #  'SilentlyContinue' for a normal run, under which a bare throw at SCRIPT
            #  SCOPE is swallowed and execution continues - which would authenticate,
            #  extract, then produce an empty report while still exiting 0.]
            Write-Host ("ERROR: -Service matched no collectors. Requested: [{0}]." -f ($Service -join ', ')) -ForegroundColor Red
            Write-Host ("Valid collector names: [{0}]" -f ($PreFlightAvailableServices -join ', ')) -ForegroundColor Yellow
            exit 1
        }
        Write-Host ("Pre-flight: -Service will collect {0} of {1} collectors: [{2}]" -f ...) -ForegroundColor Green
    }
```

This is the same validation as line 1258, done **earlier**.
The point of doing it twice is that this copy runs before authentication and before any resource extraction, so a typo costs seconds rather than an hour.

The `exit 1` versus `throw` choice here is important and easy to get wrong.

Under `$ErrorActionPreference = 'SilentlyContinue'`, a bare `throw` at **script scope** with no `catch` above it is swallowed and execution simply continues to the next statement.
So a `throw` here would print nothing useful, authenticate, extract every resource, produce an empty report, and **exit 0**.
`exit 1` is unconditional.

This is the same mechanism as the discovery bug in Part 3b, seen from a different angle, and it is worth holding on to: under `SilentlyContinue`, `throw` is only reliable when something up the stack catches it.

Note that a **partial** match is allowed through here.
`CreateResourceJobs` surfaces the unmatched names as a warning at line 1300.

### Check 0b: the `-ObfuscationDictionary` fast fail (lines 2340-2363)

Three separate validations, each with its own `exit 1`.

| Line | Check | Why it must be caught early |
|---|---|---|
| 2342 | `-ObfuscationDictionary` without `-Obfuscate` | The dictionaries are only created when `-Obfuscate` is present, so there would be nothing to seed. |
| 2347 | The file exists | A missing seed file would silently mint fresh tokens, and a later merge would fail to line up. |
| 2354 | The file parses as JSON | Same consequence. |

The reasoning in the comment for catching these before auth is the same as the `-Service` gate: the failure mode is not an error, it is a run that appears to succeed and produces output that cannot be merged.
By the time you discover that, the run is over.

This is also why the seeding code at line 840 can call `Get-Content ... | ConvertFrom-Json` with no error handling of its own: the pre flight already proved it works.

### Check 1: Cloud Shell mount (lines 2365-2383)

```powershell
    if (Get-Command Get-CloudDrive -ErrorAction SilentlyContinue)
    {
        $CheckCloudDrive = Get-CloudDrive 3>$null 2>$null
        if ($null -eq $CheckCloudDrive)
        {
            Write-Host "WARNING: Cloud Shell detected, but no storage account is mounted." -ForegroundColor Yellow
            Write-Host "  Outputs in $PreFlightInventoryRoot will be lost when this Cloud Shell session ends." -ForegroundColor Yellow
            ...
        }
```

| Line | Code | What it does |
|---|---|---|
| 2365 | `if (Get-Command Get-CloudDrive -ErrorAction SilentlyContinue)` | Tests whether the cmdlet **exists**, which is a cleaner way of detecting Cloud Shell than the inline `try`/`catch` used at line 354. |
| 2367 | `Get-CloudDrive 3>$null 2>$null` | Redirects two streams to null: `3>` is the warning stream and `2>` is the error stream. So the call runs quietly and only its return value matters. |

The scenario being caught is a genuinely nasty one.
In Cloud Shell with no storage account mounted, the filesystem is **ephemeral**: everything written disappears when the session ends.
So an operator could run a two hour inventory and lose the output entirely by closing the browser tab.

Note this is a warning, not a hard fail.
Ephemeral mode is a legitimate choice if you download the zip before closing, and the message says exactly that.

### Check 2: disk space (lines 2386-2411)

```powershell
    try
    {
        $RootItem = Get-Item -Path $PreFlightInventoryRoot -ErrorAction Stop
        $Drive = $RootItem.PSDrive
        if ($null -ne $Drive -and $null -ne $Drive.Free)
        {
            $FreeMB = [math]::Round($Drive.Free / 1MB, 0)
            if ($FreeMB -lt 100)
            {
                Write-Host ("ERROR: Free disk space at {0} is {1} MB; the script needs at least 100 MB to start. Free space and re-run." -f $PreFlightInventoryRoot, $FreeMB) -ForegroundColor Red
                exit 1
            }
            elseif ($FreeMB -lt 500)
            {
                Write-Host ("WARNING: Free disk space at {0} is {1} MB. [...]") -ForegroundColor Yellow
            }
            else
            {
                Write-Host ("Free disk space: {0} MB at {1}" -f $FreeMB.ToString('N0', [cultureinfo]::InvariantCulture), $PreFlightInventoryRoot) -ForegroundColor Green
            }
        }
    }
    catch
    {
        Write-Host ("WARNING: Could not determine free disk space at {0}: {1}" -f ...) -ForegroundColor Yellow
    }
```

Three tiers rather than a single pass or fail:

| Free space | Response |
|---|---|
| under 100 MB | hard fail |
| 100 to 500 MB | warn, continue |
| over 500 MB | report and continue |

| Line | Code | What it does |
|---|---|---|
| 2389 | `if ($null -ne $Drive -and $null -ne $Drive.Free)` | `PSDrive.Free` is not populated for every provider, so both are checked and the whole check is skipped rather than guessed at when unavailable. |
| 2408 | `if ($_.Exception.Message -match '^Pre-flight:') { throw }` | The clever bit. This `catch` is meant to handle "could not determine free space", but it would also catch the deliberate hard fail `throw` from line 2394 and downgrade it to a warning. Matching on the `Pre-flight:` message prefix lets the intentional failure through while still swallowing genuine measurement errors. |

The pattern at 2463 is worth remembering: when a `catch` needs to let its own deliberate throws pass, it has to be able to recognise them.
A message prefix is a crude but effective marker. A custom exception type would be the more robust version of the same idea.

### Check 3: the write probe (lines 2414-2431)

```powershell
    $ProbePath = Join-Path $PreFlightInventoryRoot (".write-probe-{0}.tmp" -f ([guid]::NewGuid()))
    try
    {
        Set-Content -Path $ProbePath -Value 'preflight write probe' -Encoding utf8 -ErrorAction Stop
        $ProbeRead = Get-Content -Path $ProbePath -Raw -ErrorAction Stop
        if ($ProbeRead -notmatch 'preflight write probe')
        {
            throw "Write probe content mismatch (read back '$ProbeRead')"
        }
        Remove-Item -Path $ProbePath -Force -ErrorAction Stop
        Write-Host ("Write probe: OK ({0})" -f $PreFlightInventoryRoot) -ForegroundColor Green
    }
    catch
    {
        try { if (Test-Path $ProbePath) { Remove-Item -Path $ProbePath -Force -ErrorAction SilentlyContinue } }
        catch { Write-Verbose ("Probe cleanup failed at {0}: {1}" -f $ProbePath, $_.Exception.Message) }
        Write-Host ("ERROR: cannot write to {0}: {1}" -f $PreFlightInventoryRoot, $_.Exception.Message) -ForegroundColor Red
        Write-Host "  This usually means a readonly directory, denied permissions, an antivirus or DLP product blocking writes, or a stale handle." -ForegroundColor Yellow
        Write-Host "  Verify the directory is writable and re-run, or pass -OutputDirectory with a writable path." -ForegroundColor Yellow
        exit 1
    }
```

This is the strongest check in the block and the one most worth copying as a pattern.

It does not ask whether the directory looks writable.
It **writes a file, reads it back, verifies the content, and deletes it.**

| Line | Step | Catches |
|---|---|---|
| 2417 | write | permissions, read only volume |
| 2418 | read back | a write that appeared to succeed but did not land |
| 2419-2422 | verify content | antivirus or DLP quarantining and replacing the content |
| 2423 | delete | leaves nothing behind |

The read back and content verify are the parts that make it more than a permissions check.
Endpoint security products routinely intercept writes, and the observable symptom is a write that reports success while the file on disk is empty or altered.
Only reading it back detects that.

| Line | Code | What it does |
|---|---|---|
| 2413 | `.write-probe-<guid>.tmp` | A GUID in the name so two concurrent runs cannot collide on the probe file, and a leading dot so it is hidden on Unix. |
| 2427-2428 | cleanup inside the `catch`, itself wrapped | Best effort tidy up, and the nested `try` means a cleanup failure cannot mask the real error. |
| 2430 | the final `throw` | Names four concrete likely causes: read only directory, denied permissions, antivirus or DLP, stale handle. A bare "access denied" would leave the operator guessing. |

## 6.2 Setup, transcript, and the ordering bug (lines 2454-2464)

```powershell
# [long comment: Variables and RunInventorySetup populate $Global:DefaultPath,
#  $Global:ReportName and $Global:CurrentDateTime, which are required to compute the
#  transcript path. Start-Transcript must therefore run AFTER RunInventorySetup.
#  Previously this block placed Start-Transcript above Variables, with the result that
#  all three were $null and the transcript landed in the current working directory named
#  literally "Transcript_Log__.txt" - two underscores, no report name, no timestamp.]
$Global:Runtime = Measure-Command -Expression {
    Variables
    RunInventorySetup

    $Global:PowerShellTranscriptFile = ($Global:DefaultPath + "Transcript_Log_" + $Global:ReportName + "_" + $Global:CurrentDateTime + ".txt")
    Start-Transcript -Path $Global:PowerShellTranscriptFile -UseMinimalHeader
}
```

| Line | Code | What it does |
|---|---|---|
| 2446 | `$Global:Runtime = Measure-Command -Expression { ... }` | `Measure-Command` runs a script block and returns how long it took as a `TimeSpan`. So `$Global:Runtime` becomes the extraction phase duration, and it is passed to the report at line 2238 as `-ExtractionRunTime`. |
| 2455-2456 | `Variables` then `RunInventorySetup` | All of Parts 3a, 3b and 3c happen here. By the end of these two lines, resources are discovered and obfuscation tokens are minted. |
| 2458 | build the transcript path | Depends on three globals that only exist after line 2456. |
| 2451 | `Start-Transcript -Path ... -UseMinimalHeader` | Begins capturing everything written to the console into a file. `-UseMinimalHeader` skips the verbose machine and user block PowerShell normally writes at the top. |

The comment records a small, instructive bug.
`Start-Transcript` used to be above `Variables`.
At that point all three globals were `$null`, so string concatenation with null produced a path of `Transcript_Log__.txt`, with two underscores and no report name or timestamp, written to whatever the current working directory happened to be.

Nothing errored.
PowerShell concatenates null as an empty string quite happily.
It just quietly put the file in the wrong place with the wrong name, and did so for a while before anyone noticed.
A reminder that ordering dependencies between "compute a path" and "use a path" are invisible until you check the artifact.

## 6.3 The transcript stack, and a subtle wrapper bug (lines 2466-2477)

```powershell
# [long comment: wrap in try/finally so this run's transcript frame is ALWAYS stopped -
#  even if ExecuteInventoryProcessing throws (e.g. the collector circuit breaker).
#  PowerShell transcripts are a process-wide STACK, and the wrapper invokes this script
#  via & in the SAME process. A frame left open here is ORPHANED on that stack; the
#  wrapper's own Stop-Transcript then pops THIS orphan instead of the wrapper's frame,
#  leaving the wrapper transcript file held open ("in use", undeletable) for the life of
#  the calling shell. Stopping it here keeps the stack balanced per subscription.]
try
{
    $Global:ReportingRunTime = Measure-Command -Expression {
        ExecuteInventoryProcessing
    }
}
finally
{
    try { Stop-Transcript }
    catch { }
}
```

This is one of the more interesting bugs recorded in the file, because the cause and the symptom are so far apart.

PowerShell transcripts are a process wide **stack**, and `Stop-Transcript` pops the top frame rather than closing a named file.
The wrapper runs this script with `&` in the same process, once per subscription.

```
   Wrapper starts its transcript          stack: [wrapper]
   Sub 1 starts its transcript            stack: [wrapper, sub1]
   Sub 1 THROWS, never stops              stack: [wrapper, sub1]   <-- orphan
   Sub 2 starts its transcript            stack: [wrapper, sub1, sub2]
   Sub 2 finishes, stops                  stack: [wrapper, sub1]
   ... 123 more subscriptions ...
   Wrapper calls Stop-Transcript          pops sub1, NOT the wrapper
                                          stack: [wrapper]         <-- still open
```

The observable symptom is that the **wrapper's** transcript file stays held open, showing as "in use" and undeletable, for the life of the calling shell.
Nothing in that symptom points at a subscription that threw an hour earlier.

The `finally` fixes it by guaranteeing the frame is popped whichever way the `try` exits.

| Line | Code | What it does |
|---|---|---|
| 2468 | `$Global:ReportingRunTime = Measure-Command -Expression { ExecuteInventoryProcessing }` | All of Part 4 runs here, and the duration becomes `-ReportingRunTime` in the report. |
| 2474-2476 | `try { Stop-Transcript } catch { }` | An empty `catch`, which is normally a smell but is right here: if `Start-Transcript` at line 2459 failed, there is no active transcript and `Stop-Transcript` throws. There is nothing to do about that and nothing to report, so swallowing it is correct. |

## 6.4 Render and begin packaging (lines 2479-2481)

```powershell
# Prepare the summary and outputs
FinalizeOutputs

Write-Log -Message ("Compressing Resources Output: {0}" -f $Global:ZipOutputFile) -Severity 'Info'
```

Note `FinalizeOutputs` is **outside** the `try`/`finally`.
That is deliberate: the report generator reads `$Global:Runtime` and `$Global:ReportingRunTime`, and both must be final before it runs.

## 6.5 Saving the obfuscation dictionary (lines 2483-2609)

```powershell
if ($Obfuscate.IsPresent)
{
    $Global:DictionaryFile = ($DefaultPath + "ObfuscationDictionary_" + $Global:ReportName + "_" + $CurrentDateTime + ".json")

    $Dictionary = @{
        GeneratedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss', [cultureinfo]::InvariantCulture)
        ResourceIdMap = @{}
        ResourceNameMap = @{}
        SubscriptionMap = @{}
        ResourceGroupMap = @{}
        # [long comment: maps an obfuscated subscription token to the REAL subscription
        #  DISPLAY NAME so unmasking can resolve the friendly name fully offline. The
        #  other maps store ARM resource Ids, which only contain the subscription GUID -
        #  never the name - so without this map the only way back to a name was an online
        #  Get-AzSubscription call.]
        SubscriptionNameMap = @{}
        # [comment: maps an obfuscated tag-value token back to the REAL tag value]
        TagMap = @{}
        # [comment: maps an obfuscated free-text/identity token back to the REAL value
        #  (Description, FriendlyName, CreatedBy, RoleName, container image, etc.)]
        FreeTextMap = @{}
    }

    foreach ($key in $ResourceIdDictionary.Keys)
    {
        $Dictionary.ResourceIdMap[$ResourceIdDictionary[$key]] = $key
    }
    ...
```

| Line | Code | What it does |
|---|---|---|
| 2485 | `$Global:DictionaryFile = ($DefaultPath + "ObfuscationDictionary_" + ...)` | The unmask key. This file is what makes the masking reversible, and it must **never** leave the operator's machine. |
| 2487-2510 | the `$Dictionary` hashtable | Eight members: a timestamp plus seven maps. |
| 2511-2515 | `$Dictionary.ResourceIdMap[$ResourceIdDictionary[$key]] = $key` | The **inversion**, in the opposite direction from the seeding code in Part 3c. Here the in memory `real -> token` becomes the on disk `token -> real`. |

### Why the file is written inverted

The in memory dictionaries and the saved file are keyed in opposite directions, on purpose.

| Direction | Used by | Why |
|---|---|---|
| `real -> token` | in memory, during the run | The report generator has a real value and needs its token |
| `token -> real` | on disk | A human reading the report has a token and needs the real value |

The saved direction matches the question a human actually asks: "what is `prod_abc123`?"

### Why `SubscriptionNameMap` is a separate map

The comment answers a question that would otherwise be puzzling.
`SubscriptionMap` stores ARM resource IDs, and an ARM resource ID contains only the subscription **GUID**, never its display name.
So without a separate name map, resolving a masked token back to "Contoso Production" required an online `Get-AzSubscription` call, which defeats the point of an offline unmask.

This is also, from the other direction, exactly why the seeding logic at line 858 reads `SubscriptionNameMap` rather than `SubscriptionMap`.
The two features, offline unmask and seedable determinism, both depend on the same extra map.

### Resolving subscription names offline (lines 2530-2544)

```powershell
    # [long comment: populate token -> real subscription name. The dictionary key ($key)
    #  is the real resource Id, which embeds the subscription GUID; resolve that GUID to
    #  its display name via the already-loaded $Global:Subscriptions. Uses ONLY in-memory
    #  data (no extra Azure calls); skips entries whose name cannot be resolved so the map
    #  only ever holds genuine names.]
    foreach ($key in $ResourceSubscriptionDictionary.Keys)
    {
        $SubToken = $ResourceSubscriptionDictionary[$key]
        if ($Dictionary.SubscriptionNameMap.ContainsKey($SubToken)) { continue }
        $SubGuid = if ($key -match '(?i)/subscriptions/([^/]+)') { $Matches[1] } else { $null }
        if (-not [string]::IsNullOrEmpty($SubGuid))
        {
            $SubName = ($Global:Subscriptions | Where-Object { $_.id -eq $SubGuid } | Select-Object -First 1).name
            if (-not [string]::IsNullOrEmpty($SubName))
            {
                $Dictionary.SubscriptionNameMap[$SubToken] = $SubName
            }
        }
    }
```

| Line | Code | What it does |
|---|---|---|
| 2534 | `if ($Dictionary.SubscriptionNameMap.ContainsKey($SubToken)) { continue }` | Thousands of resources share one subscription token, so once the name is recorded for a token there is no need to resolve it again. This turns a loop over every resource into a loop over every distinct subscription. |
| 2535 | `$SubGuid = if ($key -match '(?i)/subscriptions/([^/]+)') { $Matches[1] } else { $null }` | Extract the subscription GUID from the real resource ID with a case insensitive regex. |
| 2538 | `($Global:Subscriptions \| Where-Object { $_.id -eq $SubGuid } \| Select-Object -First 1).name` | Resolve GUID to display name from the already loaded in memory list. No extra Azure calls, which matters because this runs at the end of a long run when the token may be near expiry. |
| 2539-2542 | the `if` before writing | Skip unresolvable names rather than writing an empty string, so the map only ever holds genuine names. A blank entry would be worse than a missing one, because it looks like an answer. |

### The obfuscation notice (lines 2567-2609)

```powershell
    $Dictionary | ConvertTo-Json -depth 5 | Out-File $Global:DictionaryFile -Encoding utf8
    Write-Log -Message ("Obfuscation dictionary saved locally: {0}" -f $Global:DictionaryFile) -Severity 'Success'
    Write-Log -Message ("=== OBFUSCATION NOTICE ===") -Severity 'Warning'
    Write-Log -Message ("The following files are NEVER placed in the shared report zip and must NOT be shared with a report consumer:") -Severity 'Warning'
    Write-Log -Message ("  - Dictionary: {0}" -f $Global:DictionaryFile) -Severity 'Warning'
    Write-Log -Message ("  - Transcript: {0}" -f $Global:PowerShellTranscriptFile) -Severity 'Warning'
    ...
    if ($RunAllSubs.IsPresent)
    {
        Write-Log -Message ("This subscription's ZIP is obfuscated and is one COMPONENT of the run's bundle - it is not the file to send on its own.") -Severity 'Success'
        Write-Log -Message ("Send the single AllSubscriptions_*.zip named at the end of the run ('SEND THIS ONE FILE'); it already contains this zip.") -Severity 'Success'
    }
    else
    {
        Write-Log -Message ("The ZIP file is safe to share with AWS or partners. Send that ZIP only - not the folder it sits in.") -Severity 'Success'
    }
```

| Line | Code | What it does |
|---|---|---|
| 2567 | `ConvertTo-Json -depth 5 \| Out-File ... -Encoding utf8` | Depth 5 is plenty here, because the structure is only two levels deep: seven maps of flat string pairs. Explicit UTF-8 matters because resource names can contain non ASCII characters. |
| 2570-2581 | the notice header and the never share list | Names the dictionary and the transcript by full path, then conditionally adds the error log and the debug log if they exist. |
| 2593-2604 | the two branch sharing message | Explained below. |
| 2608 | `Delete the dictionary and transcript when no longer needed for security.` | The closing instruction. |

The two branch sharing message at line 2593 fixes a genuine field problem, and it is a good example of how a technically true message can still cause harm.

The message used to be an unqualified "the ZIP file is safe to share".
Under the wrapper, this block runs **once per subscription**, so on a large multi-subscription run the operator was told once per subscription that a zip was sendable, while only ever being shown a per subscription zip path.
Meanwhile the consolidated `AllSubscriptions_*.zip` they should actually send was never described that way.

Operators resolved the ambiguity the way people do: they sent the whole folder.
Dictionary included.

The fix scopes the claim to the artifact it is actually about.
Under the wrapper, the per subscription zip is described as a **component** and the operator is pointed at the single consolidated file named at the end of the run.
Only a standalone run gets told its zip is the thing to send.

## 6.6 Structural completeness fallbacks (lines 2611-2661)

Three guards that make the output bundle structurally identical regardless of which phases ran or how much data existed.
All three exist because downstream consumers, dashboard ingestion and the Pester tests, reject a bundle with a missing or unparseable member.

### Metrics JSON (lines 2611-2632)

```powershell
if ($SkipMetrics.IsPresent)
{
    @{ Metrics = @() } | ConvertTo-Json -depth 5 -compress | Out-File $Global:MetricsJsonFile -Encoding utf8
}
else
{
    # [long comment: subscriptions with zero metric-eligible resources never enter the
    #  batched-write loop in Extension/Metrics.ps1, so no Metrics_*.json is produced.
    #  Downstream consumers that expect EVERY per-sub bundle to contain a Metrics JSON
    #  reject the bundle when it is missing. Emit an empty-but-valid one. Use a wildcard
    #  because the batched writer suffixes filenames with "_<rangeIdx>.json".]
    $MetricsPattern = ('Metrics_{0}_{1}*.json' -f $Global:ReportName, $CurrentDateTime)
    $MetricsAny = @(Get-ChildItem -Path $DefaultPath -Filter $MetricsPattern -ErrorAction SilentlyContinue)
    if ($MetricsAny.Count -eq 0)
    {
        @{ Metrics = @() } | ConvertTo-Json -depth 5 -compress | Out-File $Global:MetricsJsonFile -Encoding utf8
    }
}
```

Two ways to end up with no metrics file, and both are handled.

| Case | Line | Fallback |
|---|---|---|
| `-SkipMetrics` was passed | 2669 | Write `{"Metrics":[]}` |
| Metrics ran but the subscription had zero eligible resources | 2686 | Same |

The second case is the subtle one.
The metrics extension writes in chunks and never enters its write loop at all when there is nothing to measure, so it produces no file rather than an empty one.
The wildcard `Metrics_<name>_<stamp>*.json` is required to detect that, because the chunk writer suffixes each file with `_<index>.json`.

### Consumption CSV (lines 2634-2661)

```powershell
$ConsumptionCreated = Test-Path -Path $Global:ConsumptionFileCsv

# [long comment: a subscription with zero billing records produces an empty (0-byte) CSV
#  rather than a header-only one, because Export-Csv -Append with NO input objects writes
#  nothing. Treat 0-byte files as "not created" so the safety net below emits the header.
#  Without this, consumers that parse the CSV by header fail on the empty file and reject
#  the entire per-sub bundle.]
$ConsumptionEmpty = $false
if ($ConsumptionCreated)
{
    try
    {
        $ConsumptionEmpty = ((Get-Item -Path $Global:ConsumptionFileCsv -ErrorAction Stop).Length -eq 0)
    }
    catch
    {
        # [comment: treat unreadable as not-created so the header gets written; safer than
        #  leaving an unparseable file in the bundle]
        $ConsumptionEmpty = $true
    }
}

if ($SkipConsumption.IsPresent -or !$ConsumptionCreated -or $ConsumptionEmpty)
{
    "InstanceData,MeterCategory,MeterId,...,ReservationOrderId" | Out-File $Global:ConsumptionFileCsv -Encoding utf8
}
```

Three conditions on line 2657, any of which triggers writing a header only CSV.

| Condition | Meaning |
|---|---|
| `$SkipConsumption.IsPresent` | The phase never ran |
| `!$ConsumptionCreated` | No file at all |
| `$ConsumptionEmpty` | File exists but is 0 bytes |

The 0 byte case is the interesting one, and it is a genuine `Export-Csv` behaviour worth knowing.
`Export-Csv -Append` with **no** input objects writes **nothing at all**, not even a header row.
So a subscription with zero billing records leaves a 0 byte file, which is not a valid CSV and cannot be parsed by header.

Note the `catch` at line 2650 chooses `$ConsumptionEmpty = $true`, meaning "if I cannot read it, treat it as absent and overwrite it with a header".
The comment gives the reasoning: a valid header only file is safer to ship than an unreadable one.
That is failing toward the definitely parseable state rather than preserving something of unknown validity.

## 6.7 Deciding what goes in the zip (lines 2663-2764)

Two branches, obfuscated and default, that differ in exactly one file.

```powershell
if ($Obfuscate.IsPresent)
{
    $DiagnosticsFile = Write-RdaShareableDiagnosticsLog -DefaultPath $DefaultPath -ReportName ... -Obfuscated:$Obfuscate.IsPresent

    # [long comment: exclude the dictionary and transcript from the obfuscated zip. The
    #  dictionary maps obfuscated values back to REAL identifiers, and the transcript
    #  captures the raw Write-Log stream (auth UPN, tenant GUID, subscription names) that
    #  the obfuscation layer never touches. The shareable Diagnostics_*.log is a .log so
    #  it is NOT swept by this *.json filter and is added EXPLICITLY below because it is
    #  curated + dictionary-scrubbed. The LOCAL-only .log files are also not .json AND are
    #  never added to the Path array; the explicit -notlike guards harden the seam so none
    #  can ship even if this filter is broadened later.]
    $JsonFiles = Get-ChildItem -Path $DefaultPath -Filter "*.json" | Where-Object { $_.Name -notlike "ObfuscationDictionary_*" -and $_.Name -notlike "Full_*" -and $_.Name -notlike "Heartbeat_*" -and $_.Name -notlike "DebugLog_*" -and $_.Name -notlike "ErrorLog_*" } | Select-Object -ExpandProperty FullName

    $ShareableExtras = @()
    if (-not [string]::IsNullOrEmpty($DiagnosticsFile) -and (Test-Path -LiteralPath $DiagnosticsFile)) { $ShareableExtras += $DiagnosticsFile }
    $CompressionOutput = @{
        Path = @($Global:HtmlFile, $Global:ConsumptionFileCsv) + $ShareableExtras + $JsonFiles
        CompressionLevel = 'Fastest'
        DestinationPath = $Global:ZipOutputFile
    }
    Write-Log -Message ('Obfuscate mode: transcript log excluded from zip (kept locally for debug)') -Severity 'Info'
}
```

### What ships and what does not

| File | Obfuscated run | Default run | Reason |
|---|---|---|---|
| `<Report>_*.html` | ships | ships | the deliverable |
| `Inventory_*.json` | ships | ships | the machine readable inventory |
| `Metrics_*.json` | ships | ships | swept by the `*.json` filter |
| `Consumption_*.csv` | ships | ships | added by explicit path |
| `Diagnostics_*.log` | ships | ships | curated and dictionary scrubbed |
| `ObfuscationDictionary_*.json` | **never** | not written | it is the unmask key |
| `Transcript_Log_*.txt` | **never** | **never** | raw auth UPN, tenant GUID, real subscription names |
| `ErrorLog_*.log` | **never** | **never** | raw exception text and local paths |
| `DebugLog_*.log` | **never** | **ships** | see the discussion in section 4.1 |
| `Full_*.json` | never | never | not written anyway |

### Defence in depth on the filter

The exclusion list on line 2688 is worth reading carefully because most of it is technically redundant, and deliberately so.

| Excluded pattern | Actually needed? |
|---|---|
| `ObfuscationDictionary_*` | **Yes.** It genuinely is a `.json` in the same folder, so without this it would be swept in. This is the one that matters. |
| `Full_*` | No, that file is never written. |
| `Heartbeat_*`, `DebugLog_*`, `ErrorLog_*` | No, they are `.log` files and cannot match a `*.json` filter. |

The comment explains why the redundant ones are kept: they **harden the seam**.
If someone later broadens the filter from `*.json` to `*.*`, the guards are already in place.
Given that the failure mode is shipping the file that reverses all the masking, belt and braces is the right call.

The same reasoning drives the symmetry note at line 2739: the default branch uses the **same** hardened list rather than a bare `*.json` wildcard, even though in a default run none of the excluded names exist as `.json`.
Keeping the two branches identical means a future local `.json` artifact cannot be swept into one zip while being filtered out of the other.

### Guarding the diagnostics path

```powershell
    $ShareableExtras = @()
    if (-not [string]::IsNullOrEmpty($DiagnosticsFile) -and (Test-Path -LiteralPath $DiagnosticsFile)) { $ShareableExtras += $DiagnosticsFile }
```

`Write-RdaShareableDiagnosticsLog` returns `$null` if it fails, having already downgraded the failure to a warning internally.
This guard makes sure a `$null` or missing path never enters the `Path` array, because `Compress-Archive` fails on a non existent path and would take the **whole report** down with it.

An optional diagnostic must never be able to break packaging of the actual deliverable.

### The default branch's extra file (lines 2726-2737)

```powershell
    if (-not [string]::IsNullOrEmpty($Global:DebugLogFile) -and (Test-Path -LiteralPath $Global:DebugLogFile))
    {
        $ShareableExtras += $Global:DebugLogFile
        Write-Log -Message ('Debug log INCLUDED in zip (non-obfuscated run): {0}' -f (Split-Path -Path $Global:DebugLogFile -Leaf)) -Severity 'Warning'
        Write-Log -Message ('  It carries real service/resource names and raw exception text. The report in this bundle is already non-obfuscated. Re-run with -Obfuscate to keep the debug log LOCAL.') -Severity 'Warning'
    }
```

The only difference between the two branches.
Note the operator is told at `Warning` severity, is told **what** is in the file, and is told how to change the behaviour.
Adding a file to a bundle without saying so would be the wrong call even when the reasoning is sound.

## 6.8 Packaging and verification (lines 2766-2854)

The last section, and the most heavily defended, because this is the final place a subscription's entire report can be lost silently.

```powershell
# [long comment: packaging is the LAST place a subscription's whole report can be lost
#  without anyone noticing. THREE things previously conspired to hide a failure here:
#
#   1. The run-wide $ErrorActionPreference = 'SilentlyContinue' discarded a
#      NON-TERMINATING Compress-Archive error outright, so the catch never even fired.
#   2. When it did fire, the handler used Write-Error - which under that same preference
#      prints nothing, does not rethrow, and does not set an exit code.
#   3. The 'Reporting Data File' line was UNCONDITIONAL, so the log reported Success
#      naming an archive that was never written.
#
#  The wrapper only fails a subscription on a thrown exception or a non-zero exit code, so
#  it recorded the sub as COMPLETE and consolidated a bundle that was quietly one report
#  short.]
$ZipWriteError = $null
try
{
    Compress-Archive @CompressionOutput -ErrorAction Stop
}
catch
{
    $ZipWriteError = $_.Exception.Message
}
```

### The three layer failure

This is the best cautionary tale in the file, because no single one of the three problems was obviously wrong on its own.

| Layer | The problem | Effect |
|---|---|---|
| 1 | `Compress-Archive` raised a **non terminating** error, and `SilentlyContinue` discarded it | The `catch` never fired |
| 2 | The handler used `Write-Error`, which under `SilentlyContinue` prints nothing, does not rethrow, and does not set an exit code | Even when reached, it did nothing |
| 3 | The "Reporting Data File" success line was unconditional | The log claimed success and named a file that did not exist |

And then the consequence.
The wrapper only fails a subscription on a thrown exception or a non zero exit code.
It got neither.
So it recorded the subscription as complete and consolidated a bundle that was quietly one report short, with a log that said everything worked.

The fixes are one per layer:

| Line | Fix | Layer addressed |
|---|---|---|
| 2785 | `-ErrorAction Stop` | 1, forces it terminating so the `catch` fires |
| 2787-2790 | capture into `$ZipWriteError` instead of `Write-Error` | 2 |
| 2818 | `if (-not $ZipVerified)` gating the success line | 3 |

### Verifying rather than trusting (lines 2792-2813)

```powershell
# [long comment: Test-ReportArchiveUsable (Functions/Common.Functions.ps1) is the SINGLE
#  definition of "the archive is really there": present, a file, and non-empty. The
#  wrapper's per-subscription output verification calls the SAME predicate, so the two
#  sides of this seam cannot drift into disagreeing about what counts as a usable report.]
$ZipVerified = $false
if ($null -eq $ZipWriteError)
{
    $ZipVerified = Test-ReportArchiveUsable -Path $Global:ZipOutputFile
    if (-not $ZipVerified)
    {
        $ZipWriteError = if (Test-Path -LiteralPath $Global:ZipOutputFile -PathType Leaf)
        {
            'the archive was created but is 0 bytes'
        }
        else
        {
            'the archive is absent from disk even though Compress-Archive reported no error'
        }
    }
}
```

| Line | Code | What it does |
|---|---|---|
| 2798 | `$ZipVerified = $false` | Starts false. The archive is guilty until proven innocent. |
| 2801 | `Test-ReportArchiveUsable -Path $Global:ZipOutputFile` | Checks the file is present, is a file, and is non empty. Crucially it does **not** trust `Compress-Archive`'s silence; it goes and looks at the disk. |
| 2803-2812 | the absent versus 0 byte distinction | Only for the operator's message. The verdict itself comes from the shared predicate. |

The comment makes a point worth generalising.
`Test-ReportArchiveUsable` is the **single** definition of "usable report", and the wrapper's own output verification calls the same function.
Two independent implementations of the same predicate on either side of an interface will eventually disagree, and when they do, one side thinks the report exists and the other does not.
One definition, two callers.

Note also the message at line 2810: "the archive is absent from disk even though Compress-Archive reported no error".
That case can actually happen, which is the whole justification for verifying rather than trusting.

### Failing loudly (lines 2815-2851)

```powershell
Write-Log -Message ("Execution Time: {0}" -f $Runtime) -Severity 'Success'
Write-Log -Message ("Reporting Time: {0}" -f $ReportingRunTime) -Severity 'Success'

if (-not $ZipVerified)
{
    Write-Log -Message ("FAILED to write the report archive: {0}" -f $Global:ZipOutputFile) -Severity 'Error'
    Write-Log -Message ("  Reason: {0}" -f $ZipWriteError) -Severity 'Error'
    Write-Log -Message ("  The uncompressed report files are still in {0} - check free disk space first, then an antivirus/DLP quarantine, then write permissions on that folder." -f $DefaultPath) -Severity 'Error'
    Write-Log -Message ('  Reporting this subscription as FAILED so the wrapper does not consolidate a bundle that is missing it. Re-run with -Resume to retry.') -Severity 'Error'

    # [long comment: delete whatever IS at the archive path before leaving. The wrapper
    #  consolidates by globbing *.zip under the inventory root filtered on write time - it
    #  does NOT consult this script's verdict - so a truncated or half-written archive left
    #  here would be swept into the shared bundle as a CORRUPT MEMBER and would inflate the
    #  wrapper's archive count, hiding the very gap this exit is reporting.]
    if (Test-Path -LiteralPath $Global:ZipOutputFile -PathType Leaf)
    {
        try
        {
            Remove-Item -LiteralPath $Global:ZipOutputFile -Force -ErrorAction Stop
            Write-Log -Message ('  Removed the unusable archive so it cannot be folded into the consolidated bundle.') -Severity 'Error'
        }
        catch
        {
            Write-Log -Message ('  WARNING: could not remove the unusable archive at {0} ({1}). Delete it by hand before consolidating, or it will ship as a corrupt member.' -f ...) -Severity 'Error'
        }
    }

    # [long comment: exit code 2 specifically means "the report archive is missing", as
    #  distinct from the generic hard-fail (exit 1). Run-AllSubscriptions.ps1 still treats
    #  ANY non-zero as "this subscription failed", but it reads the 2 to also set its OWN
    #  exit code 2 - the code that already means "per-subscription output gap" - so a lost
    #  report is visible to AUTOMATION and not just in the console summary.]
    exit 2
}

Write-Log -Message ("Reporting Data File: {0}" -f $Global:ZipOutputFile) -Severity 'Success'
```

| Line | Code | What it does |
|---|---|---|
| 2815-2816 | the two timing lines | Printed unconditionally, before the verdict, because the timings are true regardless of whether packaging worked. |
| 2818 | `if (-not $ZipVerified)` | The gate that fixes layer 3. |
| 2820-2823 | four `Error` lines | Name the file, the reason, where the uncompressed files still are, and the three causes to check **in likelihood order**: disk space, then antivirus or DLP quarantine, then permissions. Then state the consequence and the remedy, `-Resume`. |
| 2834-2843 | delete the unusable archive | Explained below. |
| 2851 | `exit 2` | A **distinct** exit code. |

### Why the broken archive must be deleted

This is a subtle interaction between two components and a good example of why you have to know how your caller behaves.

The wrapper consolidates by **globbing `*.zip`** under the inventory root, filtered on write time.
It does not consult this script's verdict at all.

So a truncated or half written archive left on disk would be:

1. Swept into the shared bundle as a **corrupt member**, and
2. Counted toward the wrapper's archive total, which **hides the very gap this exit is reporting**.

Point 2 is the nastier one.
The script would exit 2 saying "this report is missing", while simultaneously leaving behind a file that makes the wrapper's count look complete.
The two signals contradict each other and the count is the one that looks authoritative.

Deleting it is best effort: if the removal fails, the message tells the operator to delete it by hand and explains exactly what happens if they do not.

### The exit code vocabulary

| Code | Meaning | Where set |
|---|---|---|
| 0 | Success | falling off the end of the script, or `exit 0` after help |
| 1 | Generic hard fail | unrecognised args, missing functions file, pre flight gates, discovery failure |
| 2 | The report archive is missing | line 2851 only |

The wrapper treats **any** non zero code as "this subscription failed", so exit 2 is not needed for that.
It exists so the wrapper can read the 2 and set its **own** exit code 2, which already means "per subscription output gap".
That way a lost report is visible to automation and not only in a console summary a human has to read.

The final line, 2910, is the success message.
It is only reachable when `$ZipVerified` is true, which means the archive has been confirmed present and non empty on disk.
The script never claims to have produced a report it has not verified.

---

# Appendix A: Recurring patterns

Nine patterns account for most of the defensive code in this file.
Recognising them makes the rest of the script much faster to read.

| Pattern | Example | Purpose |
|---|---|---|
| Lookup before mint | lines 905, 926, 1565 | Determinism. The same real value always yields the same token. |
| `ContainsKey` before index | lines 938, 958, 1498 | `Dictionary[string,string]` **throws** on a missing key rather than returning null. |
| `@()` wrapping | lines 262, 1312, 1585 | Guarantees an array, so `.Count` always works and JSON always emits `[...]`. |
| Session idempotency flags | `$Global:RdaSessionInitialized`, `$Global:AzPowerShellLoaded` | Run one time setup once per process, not once per subscription. |
| Detect, recover once, verify, fail loud | `Test-DataPlaneAuthReady` | Never let a requested phase silently produce zero rows. |
| Verify state, do not trust silence | lines 1624, 2857 | A cmdlet returning without error is not evidence the state changed. |
| Structured health records | `$Global:MetricsFailedSubs`, `ConsumptionFailedSubs`, `CollectorFailures` | Per subscription failures are named in the final summary, not left to be noticed. |
| Explicit empty artifacts | lines 2613, 2686, 2715 | A bundle has the same members regardless of which phases ran. |
| `exit N` rather than `throw` at script scope | lines 73, 804, 2329, 2851 | Under `SilentlyContinue`, an uncaught `throw` at script scope is swallowed. |

# Appendix B: Every global variable

| Variable | Set in | Holds |
|---|---|---|
| `$Global:Resources` | `ResourceInventoryLoop`, `ResourceInventoryAvd` | Every discovered resource |
| `$Global:ResourceContainers` | `Variables` | Container objects, largely vestigial |
| `$Global:Subscriptions` | `LoginSession`, `CheckPowerShell` | Subscriptions in scope |
| `$Global:ReportName` | `Variables` | Filename stem |
| `$Global:Version` | `Variables` | Local tool version |
| `$Global:ResourceIdDictionary` | `Variables`, filled in Part 3c | real ID to masked ID |
| `$Global:ResourceNameDictionary` | as above | real ID to masked name |
| `$Global:ResourceSubscriptionDictionary` | as above | real ID to masked subscription |
| `$Global:ResourceResourceGroupDictionary` | as above | real ID to masked resource group |
| `$Global:TagValueDictionary` | `Variables`, filled at line 1509 | real tag value to token |
| `$Global:FreeTextDictionary` | `Variables`, filled by collectors | real free text to token |
| `$Global:RawRepo` | `Variables` | GitHub raw URL for the version check |
| `$Global:TableStyle` | `Variables` | Vestigial Excel setting |
| `$Global:PlatformOS` | `CheckPowerShell` | Cloud Shell, Unix or Desktop |
| `$Global:CurrentDateTime` | `CheckPowerShell` | Timestamp plus PID discriminator |
| `$Global:FolderName` | `CheckPowerShell` | Report folder name |
| `$Global:DefaultPath` | `CheckPowerShell` | Output directory |
| `$Global:RdaSessionInitialized` | `GetSubscriptionsData` | One time setup guard |
| `$Global:AzPowerShellLoaded` | `CheckCliRequirements` | Module import guard |
| `$Global:ZipOutputFile` | `InitializeInventoryProcessing` | Final bundle path |
| `$Global:HtmlFile` | as above | HTML report path |
| `$Global:JsonFile` | as above | `Inventory_*.json` path |
| `$Global:MetricsJsonFile` | as above | `Metrics_*.json` path |
| `$Global:ConsumptionFileCsv` | as above | `Consumption_*.csv` path |
| `$Global:AllResourceFile` | as above | Full dump path, never written |
| `$Global:ErrorLogFile` | as above | Local errors only log |
| `$Global:DebugLogFile` | as above | Local heartbeat and metrics diagnostics |
| `$Global:DictionaryFile` | line 2485 | Unmask key path |
| `$Global:PowerShellTranscriptFile` | line 2458 | Transcript path |
| `$Global:AzMetrics` | `CreateMetricsJob` | Metrics results container |
| `$Global:SmaResources` | `CreateResourceJobs` | The inventory accumulator |
| `$Global:MetricsFailedSubs` | `CreateMetricsJob` | Per subscription metrics health |
| `$Global:ConsumptionFailedSubs` | `GetResourceConsumption` | Per subscription consumption health |
| `$Global:ConsumptionRecordCount` | `GetResourceConsumption` | Run wide billing row count |
| `$Global:CollectorFailures` | `CreateResourceJobs` | Per collector failure health |
| `$Global:Runtime` | line 2454 | Extraction duration |
| `$Global:ReportingRunTime` | line 2468 | Processing duration |

Note the deliberate use of `$script:` rather than `$Global:` in a few places: `$script:PhaseTimings`, `$script:ConsumptionRecordsThisRun` and the three `$script:Consumption*Cache` hashtables.
Script scope resets on every `&` invocation, which is exactly what you want for anything that must be per subscription rather than per process.

# Appendix C: Files produced by one run

```
  <OutputDirectory>/
  ├── ResourcesReport<stamp>/                  <-- the per-run report folder
  │   ├── ResourcesReport_<stamp>.zip          <-- THE DELIVERABLE
  │   ├── ResourcesReport_<stamp>.html         in the zip
  │   ├── Inventory_ResourcesReport_<stamp>.json    in the zip
  │   ├── Metrics_ResourcesReport_<stamp>__1.json   in the zip (chunked)
  │   ├── Consumption_ResourcesReport_<stamp>.csv   in the zip
  │   ├── Diagnostics_ResourcesReport_<stamp>.log   in the zip (scrubbed)
  │   ├── Transcript_Log_ResourcesReport_<stamp>.txt    LOCAL ONLY
  │   └── ObfuscationDictionary_..._<stamp>.json       LOCAL ONLY, obfuscated runs
  │
  └── (parent InventoryRoot, under the wrapper only)
      ├── ErrorLog_..._<subid>.log             LOCAL ONLY
      ├── DebugLog_..._<subid>.log             LOCAL in obfuscated, ZIPPED in default
      └── VMPlacementPart_..._<subid>.csv      concatenated by the wrapper
```
