# Working on This Project

Glad you're here.
This is a short orientation to how the tool is put together, so you can get something working quickly and spend your time on the interesting part rather than guessing at conventions.

[CONTRIBUTING.md](../CONTRIBUTING.md) covers the process side - forking, issues, licensing.
This is the practical side.

Open a draft pull request early if you like, even half-finished.
It's much easier to help at that point than after you've built something on a wrong assumption.
Questions in an issue are always welcome, and "is this the right approach?" is a perfectly good issue.

## Adding a new data source

Anything new is worth a quick chat first, because the tool's output feeds a downstream ingestion service and a shared report, so a new source usually touches more than the code that fetches it.

Open an issue and we'll look at it together.
The things we'll want to think through:

- **Where the data comes from.** Which API, and whether it needs permissions beyond the Reader, Cost Management Reader, and Monitoring Reader set the tool asks for today.
- **Where it lands.** The existing output files are all keyed on an Azure resource ID, so tenant-level or non-Azure data may need a home of its own rather than a row in the inventory.
- **How it gets masked.** See [obfuscation](#obfuscation) below. If the data is about people rather than infrastructure, that's worth extra thought.
- **Who consumes it.** New fields need a heads-up to the folks running the ingestion side so they can bind to them.
- **What it costs to collect.** Extra API calls per resource show up as run time on large tenants.

None of that is a barrier, it's just the checklist so nothing gets discovered late.
Microsoft Graph data such as licences or directory objects is a good example: perfectly reasonable to want, but it sits outside the Azure Resource Graph query everything else is built on, so it needs a slightly different shape than a normal collector.

## How collectors work

Each file under `Services/<Category>/` handles one Azure resource type.
They're picked up by directory scan at runtime, so there's no registry to update - drop the file in and it runs.

They all look like this:

```powershell
param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $MyResources = $Resources | Where-Object { $_.TYPE -eq 'microsoft.example/widgets' }

    if ($MyResources)
    {
        $Tmp = @()

        foreach ($1 in $MyResources)
        {
            $Sub1 = $SUB | Where-Object { $_.Id -eq $1.subscriptionId }
            $Data = $1.PROPERTIES

            $Obj = @{
                'ID'            = $1.id;
                'Subscription'  = $Sub1.Name;
                'ResourceGroup' = $1.RESOURCEGROUP;
                'Name'          = $1.NAME;
                'Location'      = $1.LOCATION;
                'SKU'           = $1.sku.name;
            }

            $Tmp += $Obj
        }

        $Tmp
    }
}
```

`$Resources` is already fetched for you - one Azure Resource Graph query feeds every collector, so you're just filtering and shaping.
Copy the nearest existing collector and adapt it; that's the fastest route and it keeps things consistent.

A few things are load-bearing and worth knowing rather than discovering:

- The parameter signature and the `$Task` check are the same everywhere, because the orchestrator calls all collectors identically.
- The five identity fields (`ID`, `Subscription`, `ResourceGroup`, `Name`, `Location`) are what the rest of the pipeline joins on.
- `ID` should be the real, full Azure resource ID. It's the key used to link this row to its metrics, its cost data, and its masked equivalent, so a row without it gets orphaned.
- The `$1` and `$2` loop variables are an old habit of the codebase. They look odd, they're allowed by the linter, and they're not worth renaming.

## Obfuscation

Runs with `-Obfuscate` produce a report that can be shared without exposing customer names.
It's dictionary-based: the same real value always maps to the same token within a run, which is what keeps references between resources intact after masking.
[docs/obfuscation-and-unmask.md](obfuscation-and-unmask.md) has the full picture.

The good news for a collector author is that most of it is already done for you.
`ID`, `Name`, `Subscription`, `ResourceGroup`, and tag values get rewritten automatically after your collector returns, so emit those as the real values and ignore the masking entirely.

What's left to you is any *other* field that could carry a name or an identifier.
Descriptive things (SKU, tier, state, version) are fine as they are.
For the rest there are three existing patterns, and you can copy whichever fits:

```powershell
# A reference to another resource: look it up so the two rows stay linked.
'AssociatedResource' = if ([string]::IsNullOrEmpty($Data.someResource.id)) { $null }
    elseif ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0)
    {
        if ($ResourceIdDictionary.ContainsKey($Data.someResource.id)) { $ResourceIdDictionary[$Data.someResource.id] } else { 'obfuscated' }
    }
    else { $Data.someResource.id.split('/')[8] };

# Free text that might name a person or system: tokenize it.
'Description' = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { Protect-FreeTextValue $Data.description } else { $Data.description };

# Not useful once masked: just blank it.
'Provider' = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { 'obfuscated' } else { $Data.serviceProviderProperties.serviceProviderName };
```

The `$ResourceIdDictionary` check is how a collector knows it's in a masked run.
`Protect-FreeTextValue` lives in `Functions/ResourceInventory.Functions.ps1`.
Working examples: `PublicIP.ps1` for references, `Purview.ps1` and `AKS.ps1` for free text, `ExpressRoute.ps1` for blanking.

One thing to keep in mind: the same real value needs to keep producing the same token. Minting a fresh one per occurrence would quietly break the links between resources, and that's hard to spot by eye.

## Output fields

Worth flagging separately because it's easy to miss: your collector's output object becomes both the `Inventory_*.json` that the ingestion service reads and the HTML report.
So adding or renaming a field changes what a downstream consumer sees, even when you only meant to change the report.

Mention it in the issue or PR and we'll sort out the ingestion side in parallel.
If you only need something to show up in the report, it can often be derived in the renderer from fields that are already there, which saves the round trip entirely.

## Checking your work

Linting, which is what CI runs:

```powershell
Invoke-ScriptAnalyzer -Path ./Services -Settings ./PSScriptAnalyzerSettings.psd1 -Recurse
```

Errors fail the build, warnings just annotate.
The settings file encodes the house style (Allman braces, four spaces), so you don't need to memorise anything - run it and it'll tell you.

Tests run against a generated output zip rather than live Azure, so make one first.
[Tests/README.md](../Tests/README.md) walks through it.

```powershell
Invoke-Pester ./Tests/ -Output Detailed
```

If your change affects what ends up in the output, there's a matrix that generates a zip per flag combination and runs the right tests against each:

```powershell
pwsh ./Tests/Invoke-ScenarioMatrix.ps1 -Scenarios default,obfuscate
```

The `obfuscate` run is the one that matters most, since masked bundles are the ones that get shared.
Don't worry if you can't run everything locally - say so in the PR and we'll run it.

A note on the linter and the tests: they're mostly there to catch the two things that are genuinely expensive to get wrong, which are leaking a real identifier into a shared report and breaking the joins between the output files. If something they flag looks wrong to you, push back in the PR.

## A couple of practical notes

Keeping a change focused really does help it get reviewed quickly.
Not a rule, just that a small diff is easy to say yes to, and a fix wrapped in a large reformat is hard to read.
If you spot something else worth fixing, an issue for it is great.

Reports and logs from a test run contain real subscription IDs and resource names, so keep those out of commits, issues, and PR descriptions.
Placeholder values in examples are perfect.

That's it. Anything unclear, ask - if something in here was confusing, that's worth fixing too.
