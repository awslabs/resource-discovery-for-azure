---
inclusion: fileMatch
fileMatchPattern: '*.ps1,*.psm1,*.psd1'
---

# PowerShell Style Guide

These rules apply to all `.ps1`, `.psm1`, and `.psd1` files in this repo. They
exist both to make the code consistent and to give AI assistants a clear target
to hit when generating or editing PowerShell.

## Naming

Use PascalCase for variables, function names, parameters, and module-scope state.

- Variables: `$ResourceId`, `$FrontDoorType`, `$AllResources`.
- Functions and cmdlets: `Verb-PascalCase` — `Get-Resource`, `New-ObfuscationMap`.
- Parameters: `[Parameter()]$ResourceIdDictionary` not `$resourceIdDictionary`.
- Hashtable keys that become output columns (Excel headers, JSON fields): keep
  the existing PascalCase names unchanged. Renaming a key is a schema change.

Exceptions — leave these alone:

- PowerShell automatic variables: `$_`, `$args`, `$input`, `$PSItem`, `$this`,
  `$MyInvocation`, `$PSBoundParameters`, etc.
- Single-letter loop iterators that are unambiguously local: `$i`, `$j`.
- Short positional loop variables that match surrounding code style (`$1` is
  used pervasively in this repo; new code should prefer a meaningful name like
  `$Resource`, but don't break existing collectors just to rename it).

## Brace Style

Use **Allman** (BSD) brace style — the opening brace goes on its own line,
aligned with the keyword that opened the block. This lets the editor fold the
body while still showing the signature.

Do this:

```powershell
function Get-Something
{
    param(
        [string]$Name
    )

    if ($Name)
    {
        foreach ($Item in $Name)
        {
            # ...
        }
    }
}
```

Not this:

```powershell
function Get-Something {
    param([string]$Name)
    if ($Name) {
        foreach ($Item in $Name) {
            # ...
        }
    }
}
```

Apply the same rule to `if` / `elseif` / `else`, `foreach`, `for`, `while`,
`switch`, `try` / `catch` / `finally`, and script blocks passed as parameters
where readability benefits from it. Short inline script blocks passed to
pipeline cmdlets (`Where-Object { $_.State -eq 'Running' }`) stay one-line —
the rule is about definitions, not every brace.

## Indentation and Whitespace

- Four spaces per level. No tabs.
- One blank line between logical sections inside a function.
- No trailing whitespace.

## Verification

Before declaring a PowerShell change complete:

1. Parse each modified file with the PowerShell parser and confirm zero errors.
2. If `PSScriptAnalyzerSettings.psd1` exists at the repo root, run:
   ```
   Invoke-ScriptAnalyzer -Path <changed files> -Settings ./PSScriptAnalyzerSettings.psd1
   ```
   and resolve any warnings before handing back.

## Safe Refactoring Rules

PowerShell variable reads are case-insensitive, so renaming `$resources` to
`$Resources` is a local change. But some renames are **not** safe and must be
avoided unless the user explicitly asks for a schema change:

- Hashtable keys that feed exported output (Excel column names, JSON field
  names, dictionary keys written to disk).
- Function parameter names that other files pass by name — rename only if you
  add `[Alias('OldName')]` to preserve the public surface.
- Anything consumed by tests under `Tests/` by literal name.

When in doubt, prefer renaming the local usage and leaving the export name
alone.
